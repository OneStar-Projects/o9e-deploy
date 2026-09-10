#!/usr/bin/env bash
# deploy-o9e-image.sh — 把 Jenkins 构建机上的 o9e 镜像直灌到 cosl-6456 并上线。
#
# **在开发笔记本上跑**,不是在服务器上:构建机是 192.168.50.92(笔记本侧内网),
# cosl-6456 在 COSL 内网,两边互不可达,必须经笔记本两段 ssh 中转。
#
# 为什么不用 docker compose pull:Docker Hub 整条路是死的(官方 000、加速站 403 /
# 限流 / 9KB\s),cosl-6456 也没有任何 HTTPS 出网。见 docs/ops-log.md 2026-09-08 一节。
#
# 用法:
#   ./deploy-o9e-image.sh --check-only   # 只预检,不改任何东西(发版前先跑这个)
#   ./deploy-o9e-image.sh                # 预检 → 确认 → 传输 → 上线 → 回归
#   ./deploy-o9e-image.sh -y             # 跳过确认(会重启 n9e / topo-studio)
#   BUILDER_SUDO_PW=xxx ./deploy-o9e-image.sh -y
#
# 传输 10~30 分钟。**别裸挂在交互会话里**——会话断了会 SIGHUP 掉传输(曾在 32MB 处
# canceled)。长跑用:
#   nohup ./deploy-o9e-image.sh -y > /tmp/deploy-o9e.log 2>&1 &
#
# 它比手工多做的两件事:
#   1. 传之前先比 rootfs layer——已经是同一个镜像就直接退出,不白传半小时。
#   2. cfgsync 模板漂移预检。给插件打过 DB 热补丁(见 docs/ops-log.md 2026-09-09)时,
#      新镜像若不含对应 commit,n9e 一重启 loader 就会拿磁盘旧模板把 DB 覆盖回去。
#      脚本用「DB / 旧镜像 / 新镜像」三方 checksum 把这件事分成三类,漂移会挡住发版。
#
# 前置:ssh 92 和 ssh cosl-6456 都通;92 的 ubuntu 不在 docker 组且 sudo 要口令
#      (`sudo usermod -aG docker ubuntu` 可一劳永逸,做了本脚本自动免密)。
set -euo pipefail

BUILDER="${BUILDER:-92}"
TARGET="${TARGET:-cosl-6456}"
IMAGE="${IMAGE:-fuqiangleon/o9e:latest}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/kylin/o9e-deploy}"
SERVICES="${SERVICES:-n9e topo-studio}"
SSH_OPTS="-o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6"

CHECK_ONLY=0
ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --check-only) CHECK_ONLY=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *)            echo "未知参数:$a(--check-only / -y / -h)" >&2; exit 2 ;;
    esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say() { echo "[deploy] $*"; }
die() { echo "[deploy] ✗ $*" >&2; exit 1; }

# 在 cosl-6456 上执行。登录横幅和 /etc/profile.d 的报错都在 stderr,查询时丢掉。
t()  { ssh $SSH_OPTS "$TARGET" "$@" 2>/dev/null; }
tv() { ssh $SSH_OPTS "$TARGET" "$@"; }   # 保留 stderr,给会失败的关键步骤用

# ── 1. 连通性 + 构建机 sudo 方式 ───────────────────────────────────────────
say "1/8 连通性与权限"
ssh $SSH_OPTS -o BatchMode=yes "$BUILDER" true 2>/dev/null || die "ssh $BUILDER 不通"
ssh $SSH_OPTS -o BatchMode=yes "$TARGET"  true 2>/dev/null || die "ssh $TARGET 不通"

SUDO_PW=""
SUDO_PFX=""
if ssh $SSH_OPTS "$BUILDER" 'docker info' >/dev/null 2>&1; then
    say "    构建机免 sudo(ubuntu 已在 docker 组)"
elif ssh $SSH_OPTS "$BUILDER" 'sudo -n docker info' >/dev/null 2>&1; then
    SUDO_PFX="sudo -n "
    say "    构建机 sudo 免密"
else
    SUDO_PW="${BUILDER_SUDO_PW:-}"
    if [ -z "$SUDO_PW" ]; then
        printf '    构建机 %s 的 sudo 口令: ' "$BUILDER" >&2
        read -rs SUDO_PW < /dev/tty
        echo >&2
    fi
    printf '%s\n' "$SUDO_PW" | ssh $SSH_OPTS "$BUILDER" "sudo -S -p '' docker info" >/dev/null 2>&1 \
        || die "构建机 sudo 口令不对,或 docker 不可用"
    say "    构建机 sudo 需口令(已验证)"
fi

# 在构建机上跑 docker,自动带上上面探到的提权方式。
b() {
    if [ -n "$SUDO_PW" ]; then
        printf '%s\n' "$SUDO_PW" | ssh $SSH_OPTS "$BUILDER" "sudo -S -p '' $*" 2>/dev/null
    else
        ssh $SSH_OPTS "$BUILDER" "${SUDO_PFX}$*" 2>/dev/null
    fi
}

# ── 2. 比 rootfs layer:已经是同一个镜像就别白传 ─────────────────────────────
# image ID 一定对不上(92 用 containerd image store、6456 用传统 docker,config
# 序列化不同),Size 显示也不同(355MB vs 247MB),都属正常。只有 rootfs layer 作数。
say "2/8 比对构建机与现场的镜像"
b "docker image inspect $IMAGE --format 'created={{.Created}}'"                       > "$TMP/new.txt"
b "docker image inspect $IMAGE --format '{{range .RootFS.Layers}}{{.}}{{println}}{{end}}'" >> "$TMP/new.txt"
[ -s "$TMP/new.txt" ] || die "构建机上没有 $IMAGE"

OLD_ID="$(t "docker image inspect $IMAGE --format '{{.Id}}'" || true)"
if [ -n "$OLD_ID" ]; then
    t "docker image inspect $IMAGE --format 'created={{.Created}}'"                       > "$TMP/cur.txt"
    t "docker image inspect $IMAGE --format '{{range .RootFS.Layers}}{{.}}{{println}}{{end}}'" >> "$TMP/cur.txt"
    if diff -q "$TMP/new.txt" "$TMP/cur.txt" >/dev/null; then
        say "    现场已是同一个镜像($(head -1 "$TMP/new.txt")),无需部署。"
        # --check-only 继续往下走:平时也能拿它查「DB 模板有没有跟镜像漂移」。
        [ "$CHECK_ONLY" = "1" ] || exit 0
        SAME_IMAGE=1
    fi
fi
if [ "${SAME_IMAGE:-0}" != "1" ]; then
    say "    构建机 $(head -1 "$TMP/new.txt")"
    say "    现场     $(head -1 "$TMP/cur.txt" 2>/dev/null || echo '(无同名镜像)')"
fi

# ── 3. cfgsync 模板漂移预检 ────────────────────────────────────────────────
# loader.go 启动时扫磁盘算 sha256(schema.json ‖ 0x00 ‖ render.tmpl),与 DB 的
# checksum 不等就把 DB 覆盖掉。三方比对能分清「正常发版更新」和「热补丁要被冲掉」。
say "3/8 cfgsync 模板漂移预检"
cat > "$TMP/ck.sh" <<'INNER'
for d in /app/integrations/*/collect/*/; do
    [ -f "$d/schema.json" ] && [ -f "$d/render.tmpl" ] || continue
    k=$(sed -n 's/.*"plugin_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$d/schema.json" | head -1)
    c=$( { cat "$d/schema.json"; printf '\0'; cat "$d/render.tmpl"; } | sha256sum | cut -d' ' -f1)
    [ -n "$k" ] && echo "$k $c"
done
INNER

# 新镜像还没传过去,只能在构建机上算。
ssh $SSH_OPTS "$BUILDER" 'cat > /tmp/.o9e-ck.sh && chmod 644 /tmp/.o9e-ck.sh' < "$TMP/ck.sh"
b "docker run --rm -v /tmp/.o9e-ck.sh:/ck.sh:ro --entrypoint sh $IMAGE /ck.sh" | sort > "$TMP/img_new"
ssh $SSH_OPTS "$BUILDER" 'rm -f /tmp/.o9e-ck.sh' 2>/dev/null || true
[ -s "$TMP/img_new" ] || die "算不出新镜像里的插件 checksum"

if [ -n "$OLD_ID" ]; then
    ssh $SSH_OPTS "$TARGET" 'cat > /tmp/.o9e-ck.sh && chmod 644 /tmp/.o9e-ck.sh' < "$TMP/ck.sh"
    t "docker run --rm -v /tmp/.o9e-ck.sh:/ck.sh:ro --entrypoint sh $OLD_ID /ck.sh" | sort > "$TMP/img_old" || true
    t 'rm -f /tmp/.o9e-ck.sh' || true
    [ -s "$TMP/img_old" ] || say "    (算不出旧镜像的 checksum,分不清「正常更新」和「热补丁被冲」,下面一律按正常更新报)"
else
    : > "$TMP/img_old"
fi

# MySQL 口令在 6456 上运行时读,不出笔记本、不落盘。
t 'MP=$(docker inspect o9e-mysql --format "{{range .Config.Env}}{{println .}}{{end}}" | grep ^MYSQL_ROOT_PASSWORD= | cut -d= -f2-);
   docker exec o9e-mysql mysql -uroot -p"$MP" n9e_v6 -N -B -e "SELECT plugin_key, checksum, source FROM cfgsync_monitoring_plugin;"' \
   > "$TMP/db" || true

awk -v NEWF="$TMP/img_new" -v OLDF="$TMP/img_old" -v DBF="$TMP/db" '
BEGIN {
    while ((getline l < NEWF) > 0) { split(l, a, " "); nw[a[1]] = a[2] }
    while ((getline l < OLDF) > 0) { split(l, a, " "); od[a[1]] = a[2]; nod++ }
    while ((getline l < DBF)  > 0) { split(l, a, "\t"); db[a[1]] = a[2]; src[a[1]] = a[3] }
    for (k in db) {
        if (!(k in nw))       continue          # 新镜像里没这个插件
        if (db[k] == nw[k])   { if (k in od && db[k] != od[k]) conv = conv " " k; continue }
        if (src[k] != "builtin") continue       # custom/community,loader 本来就不碰
        if (nod == 0)                  { upd = upd " " k; continue }  # 旧镜像算不出,无从判断
        if (k in od && db[k] == od[k]) upd = upd " " k    # DB 跟旧镜像一致 → 正常更新
        else                           dft = dft " " k    # DB 是手工改的 → 会被覆盖
    }
    if (conv) print "CONVERGE" conv
    if (upd)  print "UPDATE"   upd
    if (dft)  print "DRIFT"    dft
}' > "$TMP/verdict"

DRIFT=""
while read -r kind rest; do
    case "$kind" in
        CONVERGE) say "    ✅ 热补丁将自动收敛(DB 与新镜像一致,loader 跳过):$rest" ;;
        UPDATE)   say "    ·  本次将更新模板:$rest" ;;
        DRIFT)    DRIFT="$rest"; say "    ⚠️  DB 里是手工改过的模板,新镜像不含该修改,上线后会被 loader 覆盖:$rest" ;;
    esac
done < "$TMP/verdict"
[ -s "$TMP/verdict" ] || say "    ·  所有插件模板 DB 与新镜像一致"

# ── 4. 上线前检查 ─────────────────────────────────────────────────────────
say "4/8 上线前检查"
TPL_MODE="$(t "stat -c %a $DEPLOY_DIR/etc/o9e/config.toml.tpl")"
[ "$TPL_MODE" = "644" ] || die "config.toml.tpl 权限是 $TPL_MODE,应为 644(容器内非 root 读不到会起不来)"
ENV_TAG="$(t "grep -E '^O9E_TAG=' $DEPLOY_DIR/.env | cut -d= -f2")"
IMG_TAG="${IMAGE##*:}"
[ "$ENV_TAG" = "$IMG_TAG" ] || die ".env 的 O9E_TAG=$ENV_TAG 与镜像 tag $IMG_TAG 对不上"
DATA_AVAIL="$(t "df -h /data | awk 'NR==2{print \$4}'")"
say "    config.toml.tpl 644 ✓  O9E_TAG=$ENV_TAG ✓  /data 剩 $DATA_AVAIL"

if [ "$CHECK_ONLY" = "1" ]; then
    say "--check-only:预检结束,未做任何改动。"
    [ -n "$DRIFT" ] && say "注意上面的 ⚠️ 漂移项。"
    exit 0
fi
if [ -n "$DRIFT" ] && [ "$ASSUME_YES" != "1" ]; then
    die "存在模板漂移($DRIFT)。先把对应修改提交并等构建出新镜像,或确认要丢弃后加 -y 重跑。"
fi

if [ "$ASSUME_YES" != "1" ]; then
    printf '[deploy] 将传输镜像并重启 %s(生产短暂中断)。继续?[y/N] ' "$SERVICES"
    read -r ans < /dev/tty
    case "$ans" in [yY]*) ;; *) say "已取消。"; exit 0 ;; esac
fi

# ── 5. 传输 ──────────────────────────────────────────────────────────────
say "5/8 传输镜像(约 10~30 分钟)"
if command -v pv >/dev/null 2>&1; then PROG="pv -btrf"; else PROG=cat; fi
START=$(date +%s)
if [ -n "$SUDO_PW" ]; then
    printf '%s\n' "$SUDO_PW" \
        | ssh $SSH_OPTS "$BUILDER" "sudo -S -p '' docker save $IMAGE | gzip -1" \
        | $PROG | ssh $SSH_OPTS "$TARGET" 'docker load'
else
    ssh $SSH_OPTS "$BUILDER" "${SUDO_PFX}docker save $IMAGE | gzip -1" \
        | $PROG | ssh $SSH_OPTS "$TARGET" 'docker load'
fi
say "    用时 $(( ($(date +%s) - START) / 60 )) 分 $(( ($(date +%s) - START) % 60 )) 秒"

# ── 6. 校验 ──────────────────────────────────────────────────────────────
say "6/8 校验 rootfs layer"
t "docker image inspect $IMAGE --format 'created={{.Created}}'"                       > "$TMP/got.txt"
t "docker image inspect $IMAGE --format '{{range .RootFS.Layers}}{{.}}{{println}}{{end}}'" >> "$TMP/got.txt"
diff "$TMP/new.txt" "$TMP/got.txt" || die "灌过去的镜像与构建机不一致"
NEW_ID="$(t "docker image inspect $IMAGE --format '{{.Id}}'")"
say "    created + $(( $(wc -l < "$TMP/new.txt") - 1 )) 层 digest 全部一致 ✓"

# ── 7. 上线 ──────────────────────────────────────────────────────────────
say "7/8 重建容器"
tv "cd $DEPLOY_DIR && docker compose up -d $SERVICES" || die "docker compose up 失败"

say "    等待 healthy..."
for i in $(seq 1 40); do
    NOT_OK="$(t "docker ps --filter name=o9e --format '{{.Names}} {{.Status}}' | grep -E '^(o9e|o9e-topo-studio) ' | grep -cv healthy" || true)"
    [ "${NOT_OK:-1}" = "0" ] && break
    sleep 5
done
[ "${NOT_OK:-1}" = "0" ] || die "容器未在 200 秒内 healthy,查 docker logs o9e"

# o9e-nginx 不在 $SERVICES 里、常年不重启,upstream 的 IP 是它启动那天解析并缓存的那一份。
# 重建 o9e / topo-studio 会重新分配 IP,不 reload 就一直打旧地址,整站 502 —— 2026-09-10
# 实际踩到:两个容器互换了 IP,主 UI 的流量被送进 topo-studio 的 17000,连接被拒。
# 先 -t 再 reload:配置有错时 nginx 保留旧 worker,不会把情况变得更糟。
say "    reload nginx(重建后容器 IP 会变,nginx 缓存的是旧地址)"
t "docker exec o9e-nginx nginx -t"       || die "o9e-nginx 配置检查未通过,未 reload"
t "docker exec o9e-nginx nginx -s reload" || die "o9e-nginx reload 失败"

# ── 8. 回归 ──────────────────────────────────────────────────────────────
say "8/8 回归"
t "docker ps --filter name=o9e --format '    {{.Names}}\t{{.Status}}' | head -2"
VER="$(t 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:17000/api/n9e/version')"
IDX="$(t 'curl -sk -o /tmp/.idx -w "%{http_code}" https://127.0.0.1/')"
BUNDLE="$(t 'grep -oE "assets/index-[a-f0-9]+\.js" /tmp/.idx | head -1' || true)"
t 'rm -f /tmp/.idx' || true
# 告警引擎自监控在 n9e 自己的 /metrics,不在 VM 里,指标名带 n9e_ 前缀。
RULES="$(t 'curl -s http://127.0.0.1:17000/metrics | grep -c n9e_alert_eval_query_series_count' || echo 0)"
say "    /api/n9e/version=$VER  首页=$IDX  bundle=$BUNDLE  告警规则在评估=$RULES 条"
[ "$VER" = "200" ] && [ "$IDX" = "200" ] || die "接口回归失败"
[ "${RULES:-0}" -gt 0 ] || say "    ⚠️ 告警引擎没有在评估任何规则,查 docker logs o9e"

# 漂移复查:上线后 DB 里还剩几个插件与新镜像不一致(正常应为 0 或只剩 custom)。
t 'MP=$(docker inspect o9e-mysql --format "{{range .Config.Env}}{{println .}}{{end}}" | grep ^MYSQL_ROOT_PASSWORD= | cut -d= -f2-);
   docker exec o9e-mysql mysql -uroot -p"$MP" n9e_v6 -N -B -e "SELECT plugin_key, checksum, source FROM cfgsync_monitoring_plugin;"' \
   > "$TMP/db2" || true
STILL="$(awk -v NEWF="$TMP/img_new" '
BEGIN { while ((getline l < NEWF) > 0) { split(l, a, " "); nw[a[1]] = a[2] } }
{ if ($1 in nw && $3 == "builtin" && $2 != nw[$1]) printf " %s", $1 }' "$TMP/db2")"
if [ -n "$STILL" ]; then
    say "    ⚠️ 这些 builtin 插件 DB 与镜像仍不一致:$STILL"
else
    say "    cfgsync 插件模板 DB 与镜像已一致 ✓"
fi

say "完成。现场镜像 $NEW_ID"
say "回滚:ssh $TARGET \"docker tag ${OLD_ID:-<旧镜像ID>} $IMAGE && cd $DEPLOY_DIR && docker compose up -d $SERVICES\""
[ -n "$OLD_ID" ] && say "      (旧镜像 docker load 时已自动转 dangling,还在本地)"
say "别忘了往 docs/ops-log.md 记一节。"
