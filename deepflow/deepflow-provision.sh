#!/usr/bin/env bash
# deepflow-server 起栈后跑一次。把一台全新 deepflow-server 补齐到「能收本项目 agent 数据」的三件事：
#   A. agent-group   建采集器组 legacy-host，id 固定 g-Ir1cV5gtqA(= agent 包烘的 DEEPFLOW_AGENT_GROUP_ID)
#   B. group-config  给该组写 ① 对外端口 proxy_controller_port=17001 / ingester_port=17002
#                    ② workload_resource_sync_enabled=true(无云平台时抽象 CHOST，否则 agent 注册不进)
#                    ③ 若设 ADVERTISE_IP(VIP/NAT 场景)：proxy_controller_ip/ingester_ip=VIP，
#                       否则 server 通告够不着的 NODE_IP、远端 agent 死循环采不到数据
#   C. domain        建 agent_sync 资源域，否则 CHOST 工作负载不注册、拓扑缺资源标签
#
# 为什么 B 是核心坑：
#   社区版 deepflow-server 默认对 agent 通告控制口 30035 / 数据口 30033，但本项目 agent 包烘的是
#   17001(n9e Jenkins ① 的 DEEPFLOW_CONTROLLER_PORT)。端口四处必须一致，缺一 agent 必报
#   CONTROLLER_SOCKET_ERROR / ANALYZER_SOCKET_ERROR、「业务服务」拓扑无数据：
#     1) compose 的 ports:            17001:20035 / 17002:20033   ← 本目录 docker-compose.yaml 已就位
#     2) agent-group-config(本步 B)： proxy_controller_port / ingester_port ← 真正告诉 agent 用哪口的地方
#     3) agent 本地 /etc/deepflow-agent.yaml: controller-port 17001            ← agent 包 install.sh 负责
#     4) server.yaml 的 agent 侧端口:  不用动(group-config 覆盖优先)
#   本脚本走 controller HTTP api(默认 30417，改控制口它不变)，故无需 --rpc-port。全部 idempotent，可重复跑。
#
#   注:server.yaml 的 ingester 出口(deepflow-server → n9e remote-write)group-config 覆盖不到,
#       由 up 之前的 ./render-config.sh 从 .env 的 N9E_REMOTE_WRITE 渲染,不在本脚本管辖内。
#
# 用法：
#   cd deepflow && cp .env.example .env && $EDITOR .env && ./render-config.sh && docker compose up -d && ./deepflow-provision.sh
#
# 可覆盖(env)：
#   AGENT_GROUP_ID / AGENT_GROUP_NAME   默认 g-Ir1cV5gtqA / legacy-host(与 agent 包一致，勿轻改)
#   PROXY_CONTROLLER_PORT / INGESTER_PORT  默认 17001 / 17002
#   ADVERTISE_IP                        VIP/NAT 场景填 VIP;空=不覆盖(server 通告 NODE_IP,同网段直连够用)
#   API_PORT                            默认 30417(compose 发布的 controller http api 口)
#   DEEPFLOW_VERSION                    deepflow-ctl 版本；不设则读同目录 .env
#   SKIP_DOMAIN=1                       跳过步骤 C(已有 agent_sync 域时可设)

set -euo pipefail
cd "$(dirname "$0")"

AGENT_GROUP_ID="${AGENT_GROUP_ID:-g-Ir1cV5gtqA}"
AGENT_GROUP_NAME="${AGENT_GROUP_NAME:-legacy-host}"
PROXY_CONTROLLER_PORT="${PROXY_CONTROLLER_PORT:-17001}"
INGESTER_PORT="${INGESTER_PORT:-17002}"
API_PORT="${API_PORT:-30417}"
# VIP/NAT 场景:server 对 agent 通告的长连地址。空=沿用默认(通告 NODE_IP_FOR_DEEPFLOW,同网段直连够用);
# 设为 VIP 则写进 group-config 的 proxy_controller_ip/ingester_ip,让远端 agent 走 VIP 而非够不着的 NODE_IP。
ADVERTISE_IP="${ADVERTISE_IP:-}"

if [ -z "${DEEPFLOW_VERSION:-}" ] && [ -f .env ]; then
    # shellcheck source=/dev/null
    . .env
fi
DEEPFLOW_VERSION="${DEEPFLOW_VERSION:-v7.1}"

log() { printf '[deepflow-provision] %s\n' "$*"; }
ctl() { deepflow-ctl --api-port "$API_PORT" "$@"; }

# ============ 1. 装 deepflow-ctl(缺失或版本不符才装)============
# deepflow-ctl 是 ~71MB 二进制,故意不入 git;默认从 aliyun OSS 下(采集机既能拉镜像就能下)。
# 离线现场:把对应架构的 deepflow-ctl 二进制预放到本目录(./deepflow-ctl),脚本优先用它、不联网。
NEED_CTL=1
if command -v deepflow-ctl >/dev/null 2>&1; then
    CUR="$(deepflow-ctl -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | head -1 || true)"
    [ "$CUR" = "$DEEPFLOW_VERSION" ] && NEED_CTL=0
fi
if [ "$NEED_CTL" = 1 ]; then
    SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"
    if [ -x ./deepflow-ctl ]; then
        log "用本地 vendored 二进制 ./deepflow-ctl 安装(离线)"
        $SUDO cp ./deepflow-ctl /usr/bin/deepflow-ctl
    else
        ARCH="$(uname -m | sed 's|x86_64|amd64|; s|aarch64|arm64|')"
        URL="https://deepflow-ce.oss-cn-beijing.aliyuncs.com/bin/ctl/${DEEPFLOW_VERSION}/linux/${ARCH}/deepflow-ctl"
        log "下载 deepflow-ctl ${DEEPFLOW_VERSION} (${ARCH}) <- $URL"
        $SUDO curl -fsSL -o /usr/bin/deepflow-ctl "$URL"
    fi
    $SUDO chmod a+x /usr/bin/deepflow-ctl
fi
log "deepflow-ctl: $(deepflow-ctl -v 2>/dev/null | head -1 || echo '?')"

# ============ 2. 等 controller api 就绪 ============
# 全新首启：空卷 mysql initdb + clickhouse 起 + server 等它们可用才拉 api，常需 1~2 分钟，故给足 180s。
log "等 controller api(127.0.0.1:${API_PORT})就绪(最多 180s)..."
for i in $(seq 1 90); do
    if ctl agent-group list >/dev/null 2>&1; then log "api ready"; break; fi
    [ "$i" = 90 ] && { log "FAIL: 180s 内 api 未就绪，查 docker compose ps 与 docker logs deepflow-server"; exit 1; }
    sleep 2
done

# ============ A. 建 agent-group(id 固定，匹配 agent 包)============
# --id 须为 g- + 10 位字母数字。已存在则跳过(重复 create 会报 already exists)。
if ctl agent-group list 2>/dev/null | awk '{print $2}' | grep -qx "$AGENT_GROUP_ID"; then
    log "agent-group ${AGENT_GROUP_ID} 已存在，跳过建组"
else
    log "建 agent-group ${AGENT_GROUP_NAME}(--id ${AGENT_GROUP_ID})"
    ctl agent-group create "$AGENT_GROUP_NAME" --id "$AGENT_GROUP_ID"
fi

# ============ B. 写 agent-group-config：对齐端口 + 开启本机资源上报 ============
# workload_resource_sync_enabled 是本套(无云平台/agent-only)部署的命门：默认 false 时 agent 不上报
# 本机运行环境，agent_sync 域拿不到 VM(日志刷 "invalid vm count (0)"/"data is not verified"),
# 于是任何 agent 都注册不进 vtap、「业务服务」拓扑全空。开启后 server 据 agent 上报抽象出 CHOST 资源。
# ADVERTISE_IP 非空(VIP/NAT 场景)才写 proxy_controller_ip/ingester_ip：server 默认通告 NODE_IP,
# 远端 agent 够不着时会死循环(见 memory deepflow-agent-behind-vip-proxy-ip);设成 VIP 让 server 改通告 VIP。
# 空则不写这两键,沿用默认——同网段直连场景无需覆盖。两键与 NODE_IP_FOR_DEEPFLOW 解耦、不冲突。
ADV_LINES=""
HAD_ADV=""
if [ -n "$ADVERTISE_IP" ]; then
    ADV_LINES="    proxy_controller_ip: ${ADVERTISE_IP}
    ingester_ip: ${ADVERTISE_IP}
"
else
    # 没带 ADVERTISE_IP：先探原组是否已有 advertise 覆盖。update 是整份替换,若原来有、这次不带,
    # 会把 VIP 抹掉、server 退回通告 NODE_IP → 经 VIP/NAT 接入的远端 agent 立刻断流。跑后 WARN 提醒。
    HAD_ADV="$(ctl agent-group-config list "$AGENT_GROUP_ID" -o yaml 2>/dev/null \
        | grep -E "proxy_controller_ip|ingester_ip" || true)"
fi
GC="$(mktemp)"; trap 'rm -f "$GC"' EXIT
cat > "$GC" <<EOF
global:
  communication:
${ADV_LINES}    proxy_controller_port: ${PROXY_CONTROLLER_PORT}
    ingester_port: ${INGESTER_PORT}
inputs:
  resources:
    workload_resource_sync_enabled: true
EOF
log "对 group ${AGENT_GROUP_ID} 写端口 control=${PROXY_CONTROLLER_PORT} data=${INGESTER_PORT} + workload_resource_sync${ADVERTISE_IP:+ + advertise=${ADVERTISE_IP}}"
# create 优先：全新组必须 create(此时 update 会静默 exit-0 空跑、把配置吞掉——老 bug);已存在再 update。
if ctl agent-group-config create "$AGENT_GROUP_ID" -f "$GC" 2>/dev/null; then
    log "已 create group-config"
else
    ctl agent-group-config update "$AGENT_GROUP_ID" -f "$GC"
    log "已 update 现有 group-config"
fi
log "回读校验："
ctl agent-group-config list "$AGENT_GROUP_ID" -o yaml 2>/dev/null \
    | grep -E "proxy_controller_ip|ingester_ip|proxy_controller_port|ingester_port|workload_resource_sync_enabled" || true
if [ -n "$HAD_ADV" ]; then
    log "WARN: 原 group-config 含 advertise 覆盖(proxy_controller_ip/ingester_ip),但本次未设 ADVERTISE_IP"
    log "WARN: → 已将其清除,server 改回通告 NODE_IP。若本环境 agent 经 VIP/NAT 接入,远端将断流!"
    log "WARN: → 如需保留,请用 ADVERTISE_IP=<VIP> 重跑本脚本。"
fi

# ============ C. 建 agent_sync 资源域 ============
# 纯 agent(无 K8s/云平台)部署靠此域把 agent 上报的 CHOST/进程注册成资源，拓扑才有主机/服务标签。
if [ "${SKIP_DOMAIN:-0}" = 1 ]; then
    log "SKIP_DOMAIN=1，跳过 agent_sync 域"
elif ctl domain list 2>/dev/null | awk '{print $1}' | grep -qx "agent_sync"; then
    log "domain agent_sync 已存在，跳过"
else
    DM="$(mktemp)"; trap 'rm -f "$GC" "$DM"' EXIT
    cat > "$DM" <<EOF
name: agent_sync
type: agent_sync
config:
  region_uuid: ffffffff-ffff-ffff-ffff-ffffffffffff
  sync_timer: 60
EOF
    log "建 domain agent_sync"
    ctl domain create -f "$DM"
fi

log "完成 ✓ —— agent 侧几分钟内应转 NORMAL(deepflow-ctl --rpc-port ${PROXY_CONTROLLER_PORT} agent list 看 STATE/EXCEPTIONS)"
