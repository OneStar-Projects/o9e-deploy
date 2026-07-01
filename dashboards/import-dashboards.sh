#!/usr/bin/env bash
# 资源清单套件导入/升级脚本。依赖: curl jq。
# 用法: N9E_ADDR=http://localhost:17000 N9E_USER=root N9E_PASS=xxx ./import-dashboards.sh
set -euo pipefail

ADDR="${N9E_ADDR:-http://localhost:17000}"
USER="${N9E_USER:-root}"
PASS="${N9E_PASS:-root.2020}"
VM_URL="${VM_URL:-http://victoriametrics:8428/}"
# 可见性: login(默认,所有登录用户可见) | anonymous(匿名免登录) | private(仅业务组成员/admin) | busi(授权给本业务组)
BUNDLE_VISIBILITY="${BUNDLE_VISIBILITY:-login}"
B="$ADDR/api/n9e"
HERE="$(cd "$(dirname "$0")" && pwd)"

log(){ printf '\033[36m[bundle]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[bundle] WARN:\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[31m[bundle] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null || die "需要 jq"
command -v curl >/dev/null || die "需要 curl"

# api METHOD PATH [DATA] —— 带鉴权, 瞬时失败(超时/5xx)自动重试 3 次, 回显 body。
# 返回非 2xx/404 时回显最后一次 body(调用方按内容判断), 不因单次失败中断整个流程。
api(){
  local m="$1" path="$2" data="${3:-}" i out code
  for i in 1 2 3; do
    if [ -n "$data" ]; then
      out=$(curl -s --max-time 20 -w '\n%{http_code}' -X "$m" "$B$path" "${AUTH[@]}" -d "$data" 2>/dev/null) || { sleep 2; continue; }
    else
      out=$(curl -s --max-time 20 -w '\n%{http_code}' -X "$m" "$B$path" "${AUTH[@]}" 2>/dev/null) || { sleep 2; continue; }
    fi
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    case "$code" in 2*|404) printf '%s' "$out"; return 0;; esac
    sleep 2
  done
  printf '%s' "${out:-}"; return 0
}

# 0. wait-for-ready: 轮询登录接口直到服务可用(最多 ~60s)
# 解析可见性 -> public / public_cate (board.go: 0匿名 1登录 2业务组)
case "$BUNDLE_VISIBILITY" in
  private)   VIS_PUB=0; VIS_CATE=0; VIS_DESC="私有(仅业务组成员/admin)" ;;
  anonymous) VIS_PUB=1; VIS_CATE=0; VIS_DESC="公开-匿名(免登录可读)" ;;
  login)     VIS_PUB=1; VIS_CATE=1; VIS_DESC="公开-登录(所有登录用户)" ;;
  busi)      VIS_PUB=1; VIS_CATE=2; VIS_DESC="公开-授权(本业务组)" ;;
  *) die "BUNDLE_VISIBILITY 取值: private|anonymous|login|busi" ;;
esac
log "可见性: $BUNDLE_VISIBILITY ($VIS_DESC)"
log "等待 n9e 就绪 ..."
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$B/auth/login" \
    -X POST -H 'Content-Type: application/json' -d '{"username":"_probe_","password":"_x_"}' || true)
  case "$code" in 2*|4*) log "n9e 已就绪 (HTTP $code)"; break;; esac
  sleep 2; [ "$i" = 30 ] && die "n9e 未就绪"
done

# 1. 登录拿 token(瞬时失败重试)
TOKEN=""
for i in 1 2 3 4 5; do
  TOKEN=$(curl -s --max-time 10 "$B/auth/login" -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg u "$USER" --arg p "$PASS" '{username:$u,password:$p}')" 2>/dev/null \
    | jq -r '.dat.access_token // empty' 2>/dev/null || true)
  [ -n "$TOKEN" ] && break
  sleep 2
done
[ -n "$TOKEN" ] || die "登录失败(检查 N9E_USER/N9E_PASS, 或服务未就绪)"
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
log "登录成功: $USER"

# 2. 确保 prometheus 数据源存在并取 id(DSID)
DSID=$(api POST /datasource/list '{"p":1,"limit":100}' | jq -r '[.data[]? | select(.plugin_type=="prometheus")][0].id // empty' 2>/dev/null || true)
if [ -z "$DSID" ]; then
  log "无 prometheus 数据源, 自动创建 (url=$VM_URL)"
  api POST /datasource/upsert "$(jq -nc --arg url "$VM_URL" '{
    name:"VictoriaMetrics",plugin_type:"prometheus",cluster_name:"default",status:"enabled",
    is_default:false,force_save:true,settings:{},
    http:{url:$url,timeout:10000,dial_timeout:10000,max_idle_conns_per_host:100},
    auth:{basic_auth:false}}')" >/dev/null
  DSID=$(api POST /datasource/list '{"p":1,"limit":100}' | jq -r '[.data[]? | select(.plugin_type=="prometheus")][0].id // empty' 2>/dev/null || true)
fi
[ -n "$DSID" ] || die "数据源解析/创建失败"
log "prometheus 数据源 id = $DSID"

# 3. 归属链: 全新部署无用户组/业务组, 按需自建
BG_NAME="资源清单"
UG_NAME="资源清单管理"
UGID=$(api GET "/user-groups?limit=200" | jq -r --arg n "$UG_NAME" '(.data.list // .data // .dat // [])[] | select(.name==$n) | .id' 2>/dev/null | head -1 || true)
if [ -z "$UGID" ]; then
  UGID=$(api GET "/user-groups?limit=200" | jq -r '(.data.list // .data // .dat // [])[0].id // empty' 2>/dev/null || true)
  if [ -z "$UGID" ]; then
    UGID=$(api POST /user-groups "$(jq -nc --arg n "$UG_NAME" '{name:$n}')" | jq -r '.dat // empty' 2>/dev/null || true)
    log "建用户组 $UG_NAME -> id=$UGID"
  fi
fi
[ -n "$UGID" ] || die "用户组解析/创建失败"

BGID=$(api GET "/busi-groups" | jq -r --arg n "$BG_NAME" '(.dat // .data // [])[] | select(.name==$n) | .id' 2>/dev/null | head -1 || true)
if [ -z "$BGID" ]; then
  BGID=$(api POST /busi-groups "$(jq -nc --arg n "$BG_NAME" --argjson ug "$UGID" '{name:$n,members:[{user_group_id:$ug,perm_flag:"rw"}]}')" | jq -r '.dat // empty' 2>/dev/null || true)
  log "建业务组 $BG_NAME -> id=$BGID"
fi
[ -n "$BGID" ] || die "业务组解析/创建失败"
log "目标业务组 id = $BGID"

# 4. 逐盘 upsert (总览 + details/*)
ver_of(){ printf '%s' "$1" | sed -n 's/.*bundle-version:[[:space:]]*\([0-9][0-9]*\).*/\1/p'; }

import_one(){ # $1=文件; 返回非0表示本轮该盘失败(调用方记 warn, 不中断)
  local f="$1" ident name note bver configs body cur curid curnote curver
  ident=$(jq -r '.ident' "$f")
  name=$(jq -r '.name' "$f")
  note=$(jq -r '.note // ""' "$f")
  bver=$(ver_of "$note"); bver="${bver:-1}"
  configs=$(jq -c --argjson ds "$DSID" '.configs | (.. | objects | select(.datasourceValue==0) | .datasourceValue) |= $ds' "$f")

  cur=$(api GET "/board/$ident")
  curid=$(printf '%s' "$cur" | jq -r '(.dat // .data // {}).id // empty' 2>/dev/null || true)

  if [ -z "$curid" ]; then
    body=$(jq -nc --arg n "$name" --arg id "$ident" --arg nt "$note" --arg cf "$configs" \
      '{name:$n,ident:$id,tags:"managed-by-bundle",note:$nt,configs:$cf}')
    curid=$(api POST "/busi-group/$BGID/boards" "$body" | jq -r '(.dat // .data // {}).id // empty' 2>/dev/null || true)
    [ -n "$curid" ] || { warn "建盘失败: $ident(重跑可补)"; return 1; }
    log "建 $ident (v$bver) id=$curid"
  else
    curnote=$(printf '%s' "$cur" | jq -r '(.dat // .data // {}).note // ""' 2>/dev/null || true)
    curver=$(ver_of "$curnote"); curver="${curver:-0}"
    if [ "$bver" -gt "$curver" ]; then
      api PUT "/board/$ident/configs" "$(jq -nc --arg cf "$configs" '{configs:$cf}')" >/dev/null
      api PUT "/board/$curid" "$(jq -nc --arg n "$name" --arg id "$ident" --arg nt "$note" '{name:$n,ident:$id,tags:"managed-by-bundle",note:$nt}')" >/dev/null
      log "升 $ident v$curver -> v$bver id=$curid"
    else
      log "跳 $ident (已是 v$curver)"
    fi
  fi
  # 声明式设置可见性: 每次按 BUNDLE_VISIBILITY 强制(翻转重跑即生效, 不受版本门控影响)
  if [ "$VIS_CATE" = 2 ]; then
    api PUT "/board/$curid/public" "$(jq -nc --argjson p "$VIS_PUB" --argjson c "$VIS_CATE" --argjson bg "$BGID" '{public:$p,public_cate:$c,bgids:[$bg]}')" >/dev/null
  else
    api PUT "/board/$curid/public" "$(jq -nc --argjson p "$VIS_PUB" --argjson c "$VIS_CATE" '{public:$p,public_cate:$c}')" >/dev/null
  fi
}

fails=0
import_one "$HERE/resource-inventory-overview.json" || fails=$((fails+1))
for f in "$HERE"/details/*.json; do [ -e "$f" ] && { import_one "$f" || fails=$((fails+1)); }; done
if [ "$fails" -gt 0 ]; then
  warn "$fails 张盘本轮未成功(多为瞬时), 重跑脚本可补齐(幂等)"
else
  log "全部完成。打开 $ADDR/dashboards/resource-overview"
fi
