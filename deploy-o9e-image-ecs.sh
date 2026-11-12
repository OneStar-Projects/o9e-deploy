#!/usr/bin/env bash
# deploy-o9e-image-ecs.sh — 把 o9e 容器镜像同步到现场 ecs1/ecs2(生产 + 温备)。
#
# 与 deploy-o9e-image.sh 的关系:那个灌 cosl-6456(测试,92 一条 ssh 直灌);这个灌
# 现场 ecs1(生产,10.77.80.193)和 ecs2(温备,10.77.80.53)。
#
# 传输路径(2026-11-09 #27 实战验证过,别改成 Mac 直连):
#   92 ──scp──▶ 139(cosl-vpn,Windows+aTrust)──scp──▶ ecs1 ──cat|ssh──▶ ecs2
#   · 镜像 PUSH=False,只在 92 本机 docker(sudo 才看得到);现场完全不出网。
#   · 92 到不了 10.77.x;Mac 虽能 ssh 到 ecs1,但大镜像(gzip 后几百 MB)经 Mac 的
#     aTrust/Proxifier 链路实测会断 —— 所以必须经 139 这台有 aTrust 的 Windows 中转。
#   · 139→ecs1 免密可直推;139→ecs2 密钥不认,ecs2 只能由 ecs1 再中转一跳。
#
# 职责划分 —— 默认只「同步镜像」,不碰服务:
#   - 默认:传到 ecs1/ecs2 并 docker load、比 rootfs 校验。生产零中断,可反复跑。
#     load 前先给现场同名旧镜像打 bak tag(回滚用)。
#   - --deploy:额外在 PRIMARY(ecs1)`compose up -d --no-deps n9e` + reload nginx + 回归。
#     ecs2 是温备只 load 备着(只跑 o9e-vm、不起 n9e),永不随 --deploy 重启。
#
# 用法:
#   ./deploy-o9e-image-ecs.sh --check-only       # 只预检(连通/aTrust/镜像在不在)
#   ./deploy-o9e-image-ecs.sh                     # 同步到 ecs1+ecs2(不重启服务)
#   ./deploy-o9e-image-ecs.sh --deploy            # 同步 + 在 ecs1 上线(会确认)
#   TARGETS="cosl-ecs1" ./deploy-o9e-image-ecs.sh --deploy -y
#
# 传输约 10~30 分钟,别裸挂交互会话(断了 SIGHUP 掉传输),长跑:
#   nohup ./deploy-o9e-image-ecs.sh --deploy -y > /tmp/deploy-ecs.log 2>&1 &
#
# 前置:ssh 92 / cosl-vpn / cosl-ecs1 / cosl-ecs2 都通;aTrust 在 139 上已连(route 判)。
#       92 docker 要 sudo,口令默认读 .local/.p92(或设 BUILDER_SUDO_PW / 交互输入)。
# ecs1 是生产,--deploy 前各自用户确认。
set -euo pipefail

BUILDER="${BUILDER:-92}"                   # 镜像所在主机(OneIT-n9e-image-v911 构建节点=92)
RELAY="${RELAY:-cosl-vpn}"                 # 139,Windows+aTrust,唯一能到现场的中转
RELAY_DIR="${RELAY_DIR:-C:\\deploy}"       # 139 上的暂存目录(Windows 路径)
IMAGE="${IMAGE:-fuqiangleon/o9e:v911-ci}"
TARGETS="${TARGETS:-cosl-ecs1 cosl-ecs2}"
PRIMARY="${PRIMARY:-cosl-ecs1}"            # 只有它在 --deploy 时重启服务
BUILDER_SSH="${BUILDER_SSH:-ubuntu@192.168.50.92}"  # 139 从这个 user@ip scp 拉镜像(92 用户=ubuntu)
ECS1_IP="${ECS1_IP:-10.77.80.193}"         # 139 经 aTrust 直推 ecs1 的地址(=cosl-ecs1 HostName)
ECS2_INNER="${ECS2_INNER:-192.170.19.27}"  # ecs1 → ecs2 内网直连地址(ecs2 不走 139,密钥不认)
ECS_DIR="${ECS_DIR:-/home/kylin}"          # 现场落包目录
DEPLOY_DIR="${DEPLOY_DIR:-/home/kylin/o9e-deploy}"
SERVICE="${SERVICE:-n9e}"                   # compose 服务名(容器名是 o9e)
SSH_OPTS="-o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6"

CHECK_ONLY=0; ASSUME_YES=0; DO_DEPLOY=0
for a in "$@"; do
    case "$a" in
        --check-only) CHECK_ONLY=1 ;;
        --deploy)     DO_DEPLOY=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        -h|--help)    sed -n '2,44p' "$0"; exit 0 ;;
        *)            echo "未知参数:$a(--check-only / --deploy / -y / -h)" >&2; exit 2 ;;
    esac
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say() { echo "[ecs] $*"; }
die() { echo "[ecs] ✗ $*" >&2; exit 1; }
h()  { ssh $SSH_OPTS "$1" "$2" 2>/dev/null; }   # h <host> <cmd>  丢 stderr(登录横幅噪声)
hv() { ssh $SSH_OPTS "$1" "$2"; }               # 保留 stderr,给会失败的关键步骤

TAG="${IMAGE##*:}"
COMMIT="$(cd "$(dirname "$0")" && git -C . rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)"
PKG="o9e-${TAG}-${COMMIT}.tar.gz"
DATESTAMP="$(date +%Y%m%d)"

# ── 1. 连通性 / aTrust / 92 sudo / 镜像存在 ────────────────────────────────
say "1/6 预检:连通性、aTrust、镜像"
ssh $SSH_OPTS -o BatchMode=yes "$BUILDER" true 2>/dev/null || die "ssh $BUILDER 不通"
ssh $SSH_OPTS -o BatchMode=yes "$RELAY"   'ver' >/dev/null 2>&1 || die "ssh $RELAY($RELAY 中转机)不通"

# aTrust 隧道判活:139 上 route 表里有 2.0.0.4 这条才算通(=14),断了是 0。别用 ping。
ATRUST="$(h "$RELAY" 'route print -4 | find /c "2.0.0.4"' | tr -dc '0-9')"
[ "${ATRUST:-0}" = "0" ] && die "139 的 aTrust 隧道没连(route 无 2.0.0.4)。到 139 重连 aTrust 再跑。"
say "    aTrust 隧道在($RELAY route 命中 2.0.0.4)"

for T in $TARGETS; do
    ssh $SSH_OPTS -o BatchMode=yes "$T" true 2>/dev/null || die "ssh $T 不通(经 aTrust)"
done

# 92 docker 要 sudo。口令:BUILDER_SUDO_PW > .local/.p92 > 交互输入。
SUDO_PW="${BUILDER_SUDO_PW:-}"
if [ -z "$SUDO_PW" ]; then
    P92="$(cd "$(dirname "$0")/.." && pwd)/n9e/.local/.p92"
    [ -f "$P92" ] && SUDO_PW="$(cat "$P92")"
fi
if [ -z "$SUDO_PW" ]; then
    printf '    92 的 sudo 口令: ' >&2; read -rs SUDO_PW < /dev/tty; echo >&2
fi
bsudo() { printf '%s\n' "$SUDO_PW" | ssh $SSH_OPTS "$BUILDER" "sudo -S -p '' $*"; }
bsudo "docker image inspect $IMAGE --format 'created={{.Created}}'"                            > "$TMP/new.txt" 2>/dev/null || true
bsudo "docker image inspect $IMAGE --format '{{range .RootFS.Layers}}{{.}}{{println}}{{end}}'" >> "$TMP/new.txt" 2>/dev/null || true
[ -s "$TMP/new.txt" ] || die "92 上没有 $IMAGE(或 sudo 口令不对)。先在 92 跑 sudo docker images fuqiangleon/o9e 确认。"
NEW_LAST="$(grep -E '^sha256:' "$TMP/new.txt" | tail -1)"
say "    92 镜像 $(head -1 "$TMP/new.txt")  末层 ${NEW_LAST:0:26}…"

# 现场逐台比 rootfs:全一致则无需传。
NEED=""
for T in $TARGETS; do
    OLD_ID="$(h "$T" "docker image inspect $IMAGE --format '{{.Id}}'" || true)"
    if [ -n "$OLD_ID" ]; then
        h "$T" "docker image inspect $IMAGE --format '{{range .RootFS.Layers}}{{.}}{{println}}{{end}}'" > "$TMP/cur.$T"
        CUR_LAST="$(grep -E '^sha256:' "$TMP/cur.$T" | tail -1)"
        if [ "$CUR_LAST" = "$NEW_LAST" ]; then say "    [$T] 已是同一镜像(末层一致),跳过"; continue; fi
        say "    [$T] 现场是旧镜像(末层 ${CUR_LAST:0:26}…),需更新"
    else
        say "    [$T] 现场无同名镜像,需全新灌入"
    fi
    NEED="$NEED $T"
done
NEED="${NEED# }"

if [ "$CHECK_ONLY" = "1" ]; then
    say "--check-only:预检结束。需要同步的目标:${NEED:-无}"
    exit 0
fi
[ -z "$NEED" ] && { say "所有目标已是最新镜像。"; [ "$DO_DEPLOY" = "1" ] || exit 0; }

# ── 2. 92 导出镜像 + sha256 ────────────────────────────────────────────────
if [ -n "$NEED" ]; then
    say "2/6 在 92 导出镜像 → /tmp/$PKG"
    bsudo "docker save $IMAGE | gzip -1 > /tmp/$PKG && chmod 644 /tmp/$PKG"
    SHA="$(bsudo "sha256sum /tmp/$PKG" | awk '{print $1}')"
    [ -n "$SHA" ] || die "92 上算不出包的 sha256"
    say "    $PKG  sha256=${SHA:0:16}…"

    # ── 3. 92 → 139(Windows 中转暂存)─────────────────────────────────────
    say "3/6 92 → 139($RELAY)暂存"
    # 139 从 92 拉(139→92 免密);Windows 目标用反斜杠路径。
    hv "$RELAY" "scp -o StrictHostKeyChecking=no $BUILDER_SSH:/tmp/$PKG \"$RELAY_DIR\\$PKG\"" \
        || die "139 从 92 拉包失败(检查 139→92 ssh 免密、92 上 /tmp/$PKG)"
    h "$RELAY" "certutil -hashfile \"$RELAY_DIR\\$PKG\" SHA256" | tr -d ' \r' | grep -qi "$SHA" \
        || die "139 上的包 sha256 与 92 不一致,传输损坏"
    say "    139 已收,sha256 一致"

    # ── 4. 139 → ecs1,ecs1 → ecs2,各自 load ──────────────────────────────
    want()    { case " $NEED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
    load_on() {   # 先给旧镜像打 bak tag,gunzip|docker load,比末层 digest
        local T="$1" OLD_ID GOT
        OLD_ID="$(h "$T" "docker image inspect $IMAGE --format '{{.Id}}'" || true)"
        [ -n "$OLD_ID" ] && h "$T" "docker tag $IMAGE ${IMAGE}-bak-${DATESTAMP}" \
            && say "    [$T] 旧镜像备份为 ${IMAGE}-bak-${DATESTAMP}"
        hv "$T" "gunzip -c $ECS_DIR/$PKG | docker load" || die "[$T] docker load 失败"
        GOT="$(h "$T" "docker image inspect $IMAGE --format '{{range .RootFS.Layers}}{{.}}{{println}}{{end}}'" | grep -E '^sha256:' | tail -1)"
        [ "$GOT" = "$NEW_LAST" ] || die "[$T] load 后末层 digest 与 92 不一致"
        say "    [$T] load 完成,末层 digest 一致 ✓"
    }

    # ecs2 的包必须经 ecs1 中转 → 只要 ecs2 要更新,ecs1 上就得先有包(即便 ecs1 本身已最新)。
    if want cosl-ecs1 || want cosl-ecs2; then
        say "4/6 139 → ecs1($ECS1_IP)"
        hv "$RELAY" "scp -o StrictHostKeyChecking=no \"$RELAY_DIR\\$PKG\" kylin@$ECS1_IP:$ECS_DIR/$PKG" \
            || die "139 → ecs1 推包失败(检查 139→ecs1 免密、aTrust)"
        [ "$(h cosl-ecs1 "sha256sum $ECS_DIR/$PKG" | awk '{print $1}')" = "$SHA" ] || die "ecs1 上的包 sha256 与源不一致"
        say "    ecs1 收包 sha256 一致"
        want cosl-ecs1 && load_on cosl-ecs1
    fi

    if want cosl-ecs2; then
        say "    ecs1 → ecs2($ECS2_INNER,139→ecs2 密钥不认,只能 ecs1 中转)"
        hv cosl-ecs1 "cat $ECS_DIR/$PKG | ssh $SSH_OPTS kylin@$ECS2_INNER 'cat > $ECS_DIR/$PKG'" || die "ecs1 → ecs2 中转失败"
        [ "$(h cosl-ecs2 "sha256sum $ECS_DIR/$PKG" | awk '{print $1}')" = "$SHA" ] || die "ecs2 上的包 sha256 与源不一致"
        say "    ecs2 收包 sha256 一致"
        load_on cosl-ecs2
    fi
fi

# ── 5. 是否上线 ────────────────────────────────────────────────────────────
if [ "$DO_DEPLOY" != "1" ]; then
    say "5/6 镜像已同步到现场,未加 --deploy,不重启服务(准备部署态)。"
    say "    上线:到 ecs1 跑  cd $DEPLOY_DIR && docker compose up -d --no-deps $SERVICE && docker exec o9e-nginx nginx -s reload"
    say "    回滚:docker tag ${IMAGE}-bak-${DATESTAMP} $IMAGE 后同样 up + nginx reload"
    say "完成。记得按需删现场/139/92 上的 $PKG。"
    exit 0
fi

P="$PRIMARY"
case " $TARGETS " in *" $P "*) ;; *) die "--deploy 需要 PRIMARY($P)在 TARGETS 里" ;; esac
say "5/6 上线前检查($P)"
TPL_MODE="$(h "$P" "stat -c %a $DEPLOY_DIR/etc/o9e/config.toml.tpl" || true)"
[ "$TPL_MODE" = "644" ] || die "[$P] config.toml.tpl 权限 ${TPL_MODE:-缺失},应为 644(容器内非 root 读不到起不来)"
ENV_TAG="$(h "$P" "grep -E '^O9E_TAG=' $DEPLOY_DIR/.env | cut -d= -f2" || true)"
[ "$ENV_TAG" = "$TAG" ] || die "[$P] .env 的 O9E_TAG=${ENV_TAG:-缺失} 与镜像 tag $TAG 对不上"
say "    config.toml.tpl 644 ✓  O9E_TAG=$ENV_TAG ✓"

if [ "$ASSUME_YES" != "1" ]; then
    printf '[ecs] 将在生产 %s 重启 %s(短暂中断,全量 agent 心跳会断几秒)。继续?[y/N] ' "$P" "$SERVICE"
    read -r ans < /dev/tty; case "$ans" in [yY]*) ;; *) say "已取消上线(镜像已同步)。"; exit 0 ;; esac
fi

# ── 6. 上线 + nginx reload + 回归 ──────────────────────────────────────────
say "6/6 重建容器($P)"
hv "$P" "cd $DEPLOY_DIR && docker compose up -d --no-deps $SERVICE" || die "[$P] docker compose up 失败"
say "    等待 healthy..."
NOT_OK=1
for i in $(seq 1 40); do
    NOT_OK="$(h "$P" "docker ps --filter name=o9e --format '{{.Names}} {{.Status}}' | grep -E '^o9e ' | grep -cv healthy" || true)"
    [ "${NOT_OK:-1}" = "0" ] && break; sleep 5
done
[ "${NOT_OK:-1}" = "0" ] || die "[$P] 容器未在 200 秒内 healthy,查 docker logs o9e"

# 重建 o9e 后容器 IP 变,nginx 缓存旧地址 → ecs1 上是全量 agent 心跳+写入中断(不只首页 502)。
say "    reload nginx(必须,否则 agent 心跳/写入全断)"
h "$P" "docker exec o9e-nginx nginx -t"       || die "[$P] o9e-nginx 配置检查未通过,未 reload"
h "$P" "docker exec o9e-nginx nginx -s reload" || die "[$P] o9e-nginx reload 失败"

say "    回归"
VER="$(h "$P" 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:17000/api/n9e/version')"
IDX="$(h "$P" 'curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1/')"
say "    /api/n9e/version=$VER  首页=$IDX"
[ "$VER" = "200" ] && [ "$IDX" = "200" ] || die "[$P] 接口回归失败,考虑回滚"
say "完成。回滚:ssh $P \"docker tag ${IMAGE}-bak-${DATESTAMP} $IMAGE && cd $DEPLOY_DIR && docker compose up -d --no-deps $SERVICE && docker exec o9e-nginx nginx -s reload\""
say "topo-studio 若同镜像需一并更新,核对 compose 后另跑;别忘了往 docs/ops-log.md 记一节,并按需删 $PKG。"
