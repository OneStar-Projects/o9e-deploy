#!/usr/bin/env bash
# gen-scanopy-daemons.sh — 全自动为每台机器生成一份 scanopy daemon compose。
#
# 做什么:
#   登录 scanopy → 为每个 daemon 名字调 API 创建 daemon(绑同一个网络,汇聚成一张拓扑)
#   → 拿到各自的 daemon api key → 渲染出每台机器独立的 docker-compose 文件。
#
# 为什么:NETWORK_ID / DAEMON_API_KEY 是 scanopy server 签发的,手抄进 compose 易错;
#   本脚本自动签发 + 渲染,USER_ID 也从登录响应自动取,零手填。
#
# 用法:
#   SCANOPY_ADMIN_EMAIL=admin@x.com SCANOPY_ADMIN_PASSWORD=xxx \
#   SCANOPY_URL=http://192.168.50.237:60072 \
#     ./gen-scanopy-daemons.sh office-a office-b dc1
#
# 环境变量:
#   SCANOPY_URL             scanopy server 地址(在能访问它的机器上跑),默认 http://192.168.50.237:60072
#   SCANOPY_ADMIN_EMAIL     *必填* 管理员邮箱(登录)
#   SCANOPY_ADMIN_PASSWORD  *必填* 管理员密码
#   SCANOPY_NETWORK_ID      所有 daemon 绑定的网络(默认 office),汇聚到同一张拓扑
#   DAEMON_IMAGE            daemon 镜像,默认 ghcr.io/scanopy/scanopy/daemon:latest
#   DAEMON_SERVER_URL       写进 compose 的 server 地址(daemon 容器里连的),默认同 SCANOPY_URL
#   OUT_DIR                 产物目录,默认 ./scanopy-daemons
set -euo pipefail

SCANOPY_URL="${SCANOPY_URL:-http://192.168.50.237:60072}"
ADMIN_EMAIL="${SCANOPY_ADMIN_EMAIL:?需设置 SCANOPY_ADMIN_EMAIL}"
ADMIN_PASSWORD="${SCANOPY_ADMIN_PASSWORD:?需设置 SCANOPY_ADMIN_PASSWORD}"
NETWORK_ID="${SCANOPY_NETWORK_ID:-68928351-b0ab-4564-b12d-c8d2677407ec}"   # office
DAEMON_IMAGE="${DAEMON_IMAGE:-ghcr.io/scanopy/scanopy/daemon:latest}"
DAEMON_SERVER_URL="${DAEMON_SERVER_URL:-$SCANOPY_URL}"
OUT_DIR="${OUT_DIR:-./scanopy-daemons}"

if [ $# -lt 1 ]; then
  echo "用法: SCANOPY_ADMIN_EMAIL=.. SCANOPY_ADMIN_PASSWORD=.. $0 <daemon名>..." >&2
  echo "例:   $0 office-a office-b dc1" >&2
  exit 1
fi
command -v jq   >/dev/null 2>&1 || { echo "ERROR: 需要 jq" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: 需要 curl" >&2; exit 1; }

log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---- 登录:拿 session_id(手动从响应头提,绕过 curl 对 Secure-cookie 的处理)+ user_id ----
log "登录 scanopy ($SCANOPY_URL) ..."
LOGIN_BODY=$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{email:$e,password:$p}')
LOGIN_RAW=$(curl -sS -i -X POST -H 'Content-Type: application/json' --max-time 10 \
  -d "$LOGIN_BODY" "$SCANOPY_URL/api/auth/login")
SESSION_ID=$(printf '%s' "$LOGIN_RAW" | tr -d '\r' \
  | sed -n 's/^[Ss]et-[Cc]ookie: *session_id=\([^;]*\).*/\1/p' | head -1)
LOGIN_RESP=$(printf '%s' "$LOGIN_RAW" | tr -d '\r' | awk 'body{print} /^$/{body=1}')
if [ "$(echo "$LOGIN_RESP" | jq -r '.success // false')" != "true" ]; then
  echo "ERROR: 登录失败 — $(echo "$LOGIN_RESP" | head -c 300)" >&2; exit 1
fi
[ -n "$SESSION_ID" ] || { echo "ERROR: 未能从登录响应提取 session_id" >&2; exit 1; }
USER_ID=$(echo "$LOGIN_RESP" | jq -r '.data.id // empty')
[ -n "$USER_ID" ] || { echo "ERROR: 未拿到 user_id" >&2; exit 1; }
log "登录成功 user_id=$USER_ID  network_id=$NETWORK_ID"

mkdir -p "$OUT_DIR"
created=0

for name in "$@"; do
  log "创建 daemon: $name"
  BODY=$(jq -nc --arg n "$name" --arg nid "$NETWORK_ID" \
    '{id:"00000000-0000-0000-0000-000000000000",name:$n,
      created_at:"1970-01-01T00:00:00Z",updated_at:"1970-01-01T00:00:00Z",
      expires_at:null,last_used:null,network_id:$nid,key:"",is_enabled:true,tags:[]}')
  RESP=$(curl -sS -X POST -H 'Content-Type: application/json' \
    -H "Cookie: session_id=${SESSION_ID}" --max-time 10 \
    -d "$BODY" "$SCANOPY_URL/api/v1/auth/daemon")
  KEY=$(echo "$RESP" | jq -r '.data.key // empty')
  if [ -z "$KEY" ]; then
    echo "  ERROR: 创建 daemon '$name' 失败 — $(echo "$RESP" | head -c 300)" >&2
    continue
  fi

  OUT="$OUT_DIR/daemon-$name.yml"
  cat > "$OUT" <<EOF
# scanopy daemon — $name
# 绑定 network_id=$NETWORK_ID(与其它 daemon 汇聚到同一张拓扑)
# 部署:拷到目标机器 → docker compose -f $(basename "$OUT") up -d
services:
  daemon:
    image: $DAEMON_IMAGE
    container_name: scanopy-daemon-$name
    network_mode: host          # 扫描需直接看到宿主网卡
    privileged: true            # daemon 要发 raw socket / ARP
    restart: unless-stopped
    environment:
      - SCANOPY_SERVER_URL=$DAEMON_SERVER_URL
      - SCANOPY_NETWORK_ID=$NETWORK_ID
      - SCANOPY_DAEMON_API_KEY=$KEY
      - SCANOPY_USER_ID=$USER_ID
      - SCANOPY_NAME=scanopy-daemon-$name
      - SCANOPY_MODE=daemon_poll
      - SCANOPY_LOG_FILE=/var/log/scanopy/scanopy-daemon-$name.log
    volumes:
      - daemon-config:/root/.config/daemon
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/log/scanopy:/var/log/scanopy
volumes:
  daemon-config:
EOF
  log "  -> $OUT"
  created=$((created+1))
done

log "完成:生成 $created 份 compose,在 $OUT_DIR/"
log "提醒:产物里含明文 daemon api key,请妥善保管,勿提交到公共仓库。"
