#!/usr/bin/env bash
# 调 scanopy 真实 API,一键完成首次注册 + 创建 User API Key,写回 .env,重建 n9e + topo-studio。
#
# 已在真实 scanopy 0.15.6 上端到端验证过的流程:
#   1. POST /api/auth/setup    {organization_name, network}            ← 设组织 + 默认网络
#   2. POST /api/auth/register {email, password, terms_accepted}       ← 创建 admin(已存在会失败,继续 login)
#   3. POST /api/auth/login    {email, password}                       ← 拿 session cookie
#   4. GET  /api/v1/auth/keys                                          ← 检查 KEY_NAME 是否已有
#   5. POST /api/v1/auth/keys  {name, organization_id, user_id, ...}   ← 创建,响应 data.key 是 scp_u_ 前缀的 plaintext
#      或:POST /api/v1/auth/keys/{id}/rotate                            ← 已存在则 rotate 拿新 plaintext
#   6. PUT  /api/v1/auth/keys/{id} {is_enabled:true, ...}              ← ⚠ 关键:刚创建的 key 默认 disabled,必须 enable
#   7. awk 写回 .env 的 SCANOPY_TOKEN
#   8. docker compose up -d n9e topo-studio  ← 必须 recreate 才注入新 token(restart 不重读 env);topo-studio 也消费此 token
#
# 为什么 user_api_key 而不是 daemon_api_key:
#   - scanopy OpenAPI 里 /api/v1/{topology,networks,credentials,discovery} 的 security 都是
#     [user_api_key, session],daemon_api_key 不在列(daemon key 还要 X-Daemon-ID header)
#   - n9e 是 API 消费者,需要拿全数据,user_api_key 是正确选择
#
# .env 必填:
#   SCANOPY_ADMIN_EMAIL     scanopy 管理员邮箱
#   SCANOPY_ADMIN_PASSWORD  scanopy 管理员密码(init-env.sh 自动生成)
# .env 可选:
#   SCANOPY_ORG_NAME        组织名,默认 "o9e"
#   SCANOPY_KEY_NAME        API key 名,默认 "n9e-integration"

set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] || { echo "[scanopy-bootstrap] FAIL: 没 .env"; exit 1; }
# shellcheck source=/dev/null
. .env

: "${SCANOPY_ADMIN_EMAIL:?需要 .env 里 SCANOPY_ADMIN_EMAIL}"
: "${SCANOPY_ADMIN_PASSWORD:?需要 .env 里 SCANOPY_ADMIN_PASSWORD}"

SCANOPY_HOST="${SCANOPY_BOOTSTRAP_HOST:-http://scanopy:60072}"
SCANOPY_ORG_NAME="${SCANOPY_ORG_NAME:-o9e}"
SCANOPY_NETWORK_NAME="${SCANOPY_NETWORK_NAME:-default}"
KEY_NAME="${SCANOPY_KEY_NAME:-n9e-integration}"

log() { printf '[scanopy-bootstrap] %s\n' "$*"; }

command -v jq >/dev/null || { log "FAIL: 需要 jq(sudo apt install jq / yum install jq)"; exit 1; }

# scanopy 0.16.2 起登录返回的 session_id cookie 强制带 Secure 标志(即便
# SCANOPY_USE_SECURE_SESSION_COOKIES=false 也无视)。curl 在容器内走 http://scanopy 明文直连时
# 既不存也不回传 Secure cookie → cookie jar 永远空 → 所有 /api/v1/* 返回 401。
# 故不用 cookie jar:登录后从响应头手动提取 session_id,后续用 -H "Cookie: session_id=..." 显式带,
# 绕过 curl 的 Secure-cookie 策略。
SESSION_ID=""

# curl 走 n9e 容器(它跟 scanopy 同 docker network,scanopy:60072 直通)
sc_curl() {
    local method="$1" path="$2" body="${3:-}"
    local cmd=(docker compose exec -T n9e curl -sS -X "$method"
        -H 'Content-Type: application/json' --max-time 10)
    [ -n "$SESSION_ID" ] && cmd+=(-H "Cookie: session_id=${SESSION_ID}")
    [ -n "$body" ] && cmd+=(-d "$body")
    cmd+=("${SCANOPY_HOST}${path}")
    "${cmd[@]}"
}

# ============ 1. 等 scanopy 健康 ============
log "等 scanopy 健康..."
for i in $(seq 1 30); do
    if docker compose exec -T n9e curl -sSf --max-time 2 "$SCANOPY_HOST/health" >/dev/null 2>&1; then
        log "scanopy ready"; break
    fi
    [ "$i" = "30" ] && { log "FAIL: 60s scanopy 未就绪"; exit 1; }
    sleep 2
done

# ============ 2. setup(组织 + 默认网络)============
log "POST /api/auth/setup(org=$SCANOPY_ORG_NAME, network=$SCANOPY_NETWORK_NAME)"
SETUP_BODY=$(jq -nc --arg o "$SCANOPY_ORG_NAME" --arg n "$SCANOPY_NETWORK_NAME" \
    '{organization_name:$o, network:{name:$n, snmp_enabled:false}}')
sc_curl POST /api/auth/setup "$SETUP_BODY" >/dev/null || true   # 已 setup 过会失败,无所谓

# ============ 3. register(admin 账号,idempotent)============
log "POST /api/auth/register email=$SCANOPY_ADMIN_EMAIL"
REG_BODY=$(jq -nc --arg e "$SCANOPY_ADMIN_EMAIL" --arg p "$SCANOPY_ADMIN_PASSWORD" \
    '{email:$e, password:$p, terms_accepted:true, marketing_opt_in:false}')
REG_RESP=$(sc_curl POST /api/auth/register "$REG_BODY" || echo '{}')
if [ "$(echo "$REG_RESP" | jq -r '.success // false')" = "true" ]; then
    log "注册成功"
else
    log "注册失败(可能账号已存在,继续 login)"
fi

# ============ 4. login(提取 session_id + user/org id)============
log "POST /api/auth/login"
LOGIN_BODY=$(jq -nc --arg e "$SCANOPY_ADMIN_EMAIL" --arg p "$SCANOPY_ADMIN_PASSWORD" \
    '{email:$e, password:$p}')
# -i 同时拿响应头(含 Set-Cookie: session_id=...)和 body;header/body 以空行分隔。
# 不经 sc_curl,因为这一步要解析 header 而非只取 body。
LOGIN_RAW=$(docker compose exec -T n9e curl -sS -i -X POST \
    -H 'Content-Type: application/json' --max-time 10 \
    -d "$LOGIN_BODY" "${SCANOPY_HOST}/api/auth/login")
SESSION_ID=$(printf '%s' "$LOGIN_RAW" | tr -d '\r' \
    | sed -n 's/^[Ss]et-[Cc]ookie: *session_id=\([^;]*\).*/\1/p' | head -1)
LOGIN_RESP=$(printf '%s' "$LOGIN_RAW" | tr -d '\r' | awk 'body{print} /^$/{body=1}')
if [ "$(echo "$LOGIN_RESP" | jq -r '.success // false')" != "true" ]; then
    log "FAIL: 登录失败 — 响应: $(echo "$LOGIN_RESP" | head -c 300)"
    exit 1
fi
[ -n "$SESSION_ID" ] || { log "FAIL: 未能从登录响应头提取 session_id"; exit 1; }

USER_ID=$(echo "$LOGIN_RESP" | jq -r '.data.id // empty')
ORG_ID=$(echo "$LOGIN_RESP" | jq -r '.data.organization_id // empty')
[ -n "$USER_ID" ] && [ -n "$ORG_ID" ] || { log "FAIL: 没 user_id/org_id"; exit 1; }
log "登录成功 user_id=$USER_ID org_id=$ORG_ID"

# ============ 4.5 取 org 下所有网络 id(写进 key 的 network_ids)============
# scanopy 的 API key 即便 permissions=Owner,访问"网络级资源"(topology)仍按 key 自身的
# network_ids 过滤;不设则 key 看不到任何拓扑 → n9e/topo 取到 0 个 source(「请先选择 source」)。
# 这里授权 org 下全部现有网络。(之后新增的网络需重跑本脚本刷新。)
log "GET /api/v1/networks 收集网络 id(用于 key 网络授权)"
NETWORK_IDS_JSON=$(sc_curl GET "/api/v1/networks?limit=0" | jq -c '[.data[]?.id]')
case "$NETWORK_IDS_JSON" in ""|null) NETWORK_IDS_JSON='[]' ;; esac
log "网络 id: $NETWORK_IDS_JSON"

# ============ 5. 看是否已有同名 key,有就 rotate,无则 create ============
log "GET /api/v1/auth/keys 检查同名 key($KEY_NAME)"
KEYS_RESP=$(sc_curl GET /api/v1/auth/keys)
EXIST_KEY_ID=$(echo "$KEYS_RESP" | jq -r --arg n "$KEY_NAME" '.data[]? | select(.name==$n) | .id' | head -1)

if [ -n "$EXIST_KEY_ID" ]; then
    log "同名 key 已存在(id=$EXIST_KEY_ID),rotate 拿新 plaintext"
    KEY_RESP=$(sc_curl POST "/api/v1/auth/keys/$EXIST_KEY_ID/rotate")
    KEY_ID="$EXIST_KEY_ID"
else
    log "POST /api/v1/auth/keys 创建新 key"
    KEY_BODY=$(jq -nc \
        --arg n "$KEY_NAME" --arg u "$USER_ID" --arg o "$ORG_ID" --argjson nids "$NETWORK_IDS_JSON" \
        '{name:$n, organization_id:$o, user_id:$u, tags:[], permissions:"Owner", network_ids:$nids}')
    KEY_RESP=$(sc_curl POST /api/v1/auth/keys "$KEY_BODY")
    KEY_ID=$(echo "$KEY_RESP" | jq -r '.data.api_key.id // empty')
fi

# rotate 返回 {"data":"scp_u_..."}(.data 直接是明文字符串);create 返回 {"data":{"api_key":{"key":...}}}。
# .data 是字符串就直接用,是对象就取 .key/.api_key.key。(旧写法 .data.key 在 rotate 下 jq 会报错中断。)
API_TOKEN=$(echo "$KEY_RESP" | jq -r '(.data | if type=="string" then . else (.key // .api_key.key // empty) end) // empty')
if [ -z "$API_TOKEN" ] || [ "$API_TOKEN" = "null" ] || [ -z "$KEY_ID" ]; then
    log "FAIL: 没拿到 plaintext token 或 key id"
    log "  响应: $(echo "$KEY_RESP" | head -c 400)"
    exit 1
fi
log "API token OK(scp_u_..., 长度 ${#API_TOKEN})  key_id=$KEY_ID"

# ============ 6. ⚠ 关键:启用 key + 授权网络(默认 is_enabled=false 且 network_ids 空)============
# 此 PUT 对 create 和 rotate 两条路径都跑,所以把 network_ids 一并设进来,
# 已存在的旧 key(rotate 路径)也会被补上网络授权 → 修好「200 但空拓扑」。
log "PUT /api/v1/auth/keys/$KEY_ID 启用 key + 授权网络"
ENABLE_BODY=$(jq -nc \
    --arg n "$KEY_NAME" --arg u "$USER_ID" --arg o "$ORG_ID" --argjson nids "$NETWORK_IDS_JSON" \
    '{name:$n, organization_id:$o, user_id:$u, tags:[], permissions:"Owner", is_enabled:true, network_ids:$nids}')
ENABLE_RESP=$(sc_curl PUT "/api/v1/auth/keys/$KEY_ID" "$ENABLE_BODY")
if [ "$(echo "$ENABLE_RESP" | jq -r '.success // false')" != "true" ]; then
    log "FAIL: 启用 key 失败 — 响应: $(echo "$ENABLE_RESP" | head -c 300)"
    exit 1
fi
log "key 已启用"

# ============ 7. 写回 .env ============
awk -v tok="$API_TOKEN" '
/^SCANOPY_TOKEN=/ { print "SCANOPY_TOKEN=" tok; replaced=1; next }
{ print }
END { if (!replaced) print "SCANOPY_TOKEN=" tok }
' .env > .env.tmp && mv .env.tmp .env
chmod 600 .env
log ".env 已更新 SCANOPY_TOKEN"

# ============ 8. 重建消费 SCANOPY_TOKEN 的服务,注入新 token ============
# 用 up -d 而非 restart:restart 不重新注入 env(容器保留创建时的 SCANOPY_TOKEN),
# 必须 recreate 才能让刚写回 .env 的 token 生效。topo-studio 同样消费此 token,一并重建。
log "docker compose up -d n9e topo-studio(注入新 SCANOPY_TOKEN)..."
docker compose up -d n9e topo-studio
log "完成 ✓ — 浏览器进 n9e 拓扑页验证"
