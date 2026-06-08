#!/usr/bin/env bash
# 锁定 scanopy:不再允许任何人 /api/auth/register 自助注册。
# 运维流程:
#   ./init-env.sh           # 生成 .env(默认 SCANOPY_DISABLE_REGISTRATION=false)
#   docker compose up -d
#   ./scanopy-bootstrap.sh  # 注册 admin,创建 API key,写回 .env
#   ./scanopy-lock-registration.sh   ← 在这里跑,锁掉
#
# 锁定后:
#   - POST /api/auth/register → scanopy 拒绝(防止任何人自助注册)
#   - 新用户只能由 admin 通过 POST /api/v1/invites 邀请,加入 admin 所在 org
#   - 任何人都无法新建 org(因为 setup/register 路径被关)
#
# 解锁(如果需要短期开放注册):
#   sed -i 's/^SCANOPY_DISABLE_REGISTRATION=.*/SCANOPY_DISABLE_REGISTRATION=false/' .env
#   docker compose up -d scanopy
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] || { echo "[lock] FAIL: 没 .env,先跑 ./init-env.sh"; exit 1; }

CURRENT=$(awk -F= '/^SCANOPY_DISABLE_REGISTRATION=/{print $2; exit}' .env)
if [ "$CURRENT" = "true" ]; then
    echo "[lock] SCANOPY_DISABLE_REGISTRATION 已经是 true,无需重复锁定"
    exit 0
fi

echo "[lock] 改 .env: SCANOPY_DISABLE_REGISTRATION=false → true"
awk '
/^SCANOPY_DISABLE_REGISTRATION=/ { print "SCANOPY_DISABLE_REGISTRATION=true"; replaced=1; next }
{ print }
END { if (!replaced) print "SCANOPY_DISABLE_REGISTRATION=true" }
' .env > .env.tmp && mv .env.tmp .env
chmod 600 .env

echo "[lock] 重建 scanopy 容器吃新 env..."
docker compose up -d scanopy

sleep 3
echo "[lock] 验证 — /api/config 应该报 disable_registration=true:"
docker compose exec -T n9e curl -sS http://scanopy:60072/api/config | \
    grep -o '"disable_registration":[^,}]*' || true

echo
echo "[lock] 完成 ✓"
echo "[lock] 之后新用户只能 admin 邀请:POST /api/v1/invites"
echo "[lock] 若需重新开放注册,运行:"
echo "       sed -i 's/^SCANOPY_DISABLE_REGISTRATION=.*/SCANOPY_DISABLE_REGISTRATION=false/' .env"
echo "       docker compose up -d scanopy"
