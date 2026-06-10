#!/usr/bin/env bash
# 从 .env.example 派生 .env,自动生成 3 个强随机密码。
#
# 行为:
#   - .env 已存在 → 拒绝覆盖(避免误删运维改过的值,先 mv 备份再重跑)
#   - .env 不存在 → 拷贝 .env.example 并替换:
#       MYSQL_ROOT_PASSWORD / N9E_DB_PASSWORD / REDIS_PASSWORD
#     用 32 字符 A-Za-z0-9 强随机替换占位符
#
# 设计约束:
#   - 默认 initsql 用 N9E_DB_USER=root,所以 MYSQL_ROOT 和 N9E_DB 必须同一个密码
#   - 用 awk 重写整个文件,跨平台一致(macOS/Linux 的 sed -i 行为不一样)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="${DIR}/.env.example"
DST="${DIR}/.env"

if [ ! -f "${SRC}" ]; then
    echo "[init-env] FAIL: 没找到 ${SRC}" >&2
    exit 1
fi

if [ -f "${DST}" ]; then
    echo "[init-env] ${DST} 已存在,不覆盖。"
    echo "[init-env] 如需重新生成,先 mv .env .env.bak.\$(date +%s) 再重跑。"
    exit 0
fi

gen_pwd() {
    # 32 字符,A-Za-z0-9 — 不含 / + = & 等需要 escape 的字符,避免在 URL/DSN 里翻车。
    # 先 head 固定 4 KB 再 tr 过滤(避免 `tr < /dev/urandom | head` 在 pipefail 下被
    # SIGPIPE 失败 — 32 字节远小于 4 KB × ~24% 字母数字命中率,绰绰有余)。
    head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32
}

gen_hex32() {
    # 64 个 hex 字符(= 32 字节,AES-256)。给 N9E_SECRET_MASTER_KEY 用。
    # 纯 coreutils(od),不依赖 openssl;与 n9e center 的 hex.DecodeString 要求一致。
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

MYSQL_ROOT_PWD="$(gen_pwd)"
N9E_DB_PWD="${MYSQL_ROOT_PWD}"   # initsql 默认 user=root,两个密码必须相同
REDIS_PWD="$(gen_pwd)"
SCANOPY_ADMIN_PWD="$(gen_pwd)"   # scanopy 管理员密码,scanopy-bootstrap.sh 用它注册/登录
SCANOPY_PG_PWD="$(gen_pwd)"      # scanopy 后端 postgres 密码(独立于 n9e mysql)
TOPO_API_TOKEN_VAL="$(gen_pwd)"   # topo-studio API 鉴权 token
MASTER_KEY_VAL="$(gen_hex32)"     # cfgsync 秘钥库 master key(AES-256,64 hex);丢失即 DB 密文全废,务必备份

# 用 awk 一次性重写,跨平台一致
# SCANOPY_TOKEN 不在这里生成 — 由部署后跑 ./scanopy-bootstrap.sh 调 scanopy API 拿真 token 后写回
awk -v mysql="${MYSQL_ROOT_PWD}" -v n9e="${N9E_DB_PWD}" -v redis="${REDIS_PWD}" \
    -v scanopy_admin="${SCANOPY_ADMIN_PWD}" -v scanopy_pg="${SCANOPY_PG_PWD}" \
    -v topo_token="${TOPO_API_TOKEN_VAL}" -v master_key="${MASTER_KEY_VAL}" '
/^MYSQL_ROOT_PASSWORD=/       { print "MYSQL_ROOT_PASSWORD=" mysql; next }
/^N9E_DB_PASSWORD=/           { print "N9E_DB_PASSWORD=" n9e; next }
/^REDIS_PASSWORD=/            { print "REDIS_PASSWORD=" redis; next }
/^SCANOPY_ADMIN_PASSWORD=/    { print "SCANOPY_ADMIN_PASSWORD=" scanopy_admin; next }
/^SCANOPY_POSTGRES_PASSWORD=/ { print "SCANOPY_POSTGRES_PASSWORD=" scanopy_pg; next }
/^TOPO_API_TOKEN=/            { print "TOPO_API_TOKEN=" topo_token; next }
/^N9E_SECRET_MASTER_KEY=/     { print "N9E_SECRET_MASTER_KEY=" master_key; next }
{ print }
' "${SRC}" > "${DST}"

chmod 600 "${DST}"

echo "[init-env] 已生成 ${DST} (mode 600)"
echo "[init-env]   6 个密码/token 已替换为 32 字符强随机(A-Za-z0-9):"
echo "[init-env]     MYSQL_ROOT_PASSWORD == N9E_DB_PASSWORD (initsql 用 root 账号,必须一致)"
echo "[init-env]     REDIS_PASSWORD"
echo "[init-env]     SCANOPY_ADMIN_PASSWORD (scanopy-bootstrap.sh 注册/登录用)"
echo "[init-env]     SCANOPY_POSTGRES_PASSWORD (scanopy 后端 postgres)"
echo "[init-env]     TOPO_API_TOKEN (topo-studio API 鉴权,n9e 反代带 Bearer)"
echo "[init-env]   N9E_SECRET_MASTER_KEY 已生成 64 hex(AES-256,cfgsync 秘钥库)"
echo "[init-env]     ⚠ 务必备份此 key:丢失/变更 → DB 里所有 cfgsync 密文永久解不开"
echo "[init-env] SCANOPY_TOKEN 留空 — 部署后跑 ./scanopy-bootstrap.sh,它会调 scanopy API 创 key 后写回这里"
echo "[init-env] 其它字段(端口/域名/admin email)保持模板默认,如需调整请编辑 ${DST}"
