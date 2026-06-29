#!/usr/bin/env bash
# 从 .env.example 派生 .env(自动生成强随机密码);并为 nginx 预生成自签 TLS 证书。
#
# 行为:
#   - .env 已存在 → 跳过 .env 生成(避免覆盖运维改过的值,先 mv 备份再重跑)
#   - .env 不存在 → 拷贝 .env.example 并替换:
#       MYSQL_ROOT_PASSWORD / N9E_DB_PASSWORD / REDIS_PASSWORD
#     用 32 字符 A-Za-z0-9 强随机替换占位符
#   - etc/tls/{fullchain,privkey}.pem 缺失 → 用宿主 openssl 预签自签证书(CN=N9E_DOMAIN)
#     原因:nginx 容器内无出网路径,无法 apk 装 openssl 自签,故移到宿主侧做
#   - 修正 bind 挂载文件权限(initsql*/my.cnf/config.toml.tpl 对 other 可读,跳过 tls 私钥)
#     原因:容器以非 root uid 读这些文件,而 git checkout/pull 会把 o+r 抹掉
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

SKIP_ENV=0
if [ -f "${DST}" ]; then
    echo "[init-env] ${DST} 已存在,跳过 .env 生成(如需重生成,先 mv .env .env.bak.\$(date +%s) 再重跑)。"
    SKIP_ENV=1
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

gen_tls_cert() {
    # nginx 容器内无出网路径(只有宿主有 gost 代理),缺证书时它的 auto-cert.sh 会
    # apk add openssl 自签 → 拉不到 alpine 源而失败。故在宿主预签好放进 etc/tls/,
    # 让容器里 auto-cert.sh 命中"已有证书"分支直接跳过,不再走 apk。
    local cert="${DIR}/etc/tls/fullchain.pem"
    local key="${DIR}/etc/tls/privkey.pem"

    if [ -s "${cert}" ] && [ -s "${key}" ]; then
        echo "[init-env] TLS 证书已存在,跳过 (${cert})"
        return 0
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        echo "[init-env] WARN: 宿主无 openssl,无法预生成自签证书。" >&2
        echo "[init-env]       请手动放入 etc/tls/{fullchain,privkey}.pem,否则 nginx 启动会失败。" >&2
        return 0
    fi

    # CN 取 .env 里的 N9E_DOMAIN,缺省 o9e.local(与 compose 的 AUTO_CERT_CN 默认一致)
    local cn
    cn="$(grep -E '^N9E_DOMAIN=' "${DST}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    cn="${cn:-o9e.local}"

    mkdir -p "${DIR}/etc/tls"
    echo "[init-env] 预生成自签证书 CN=${cn}(容器内无法 apk 装 openssl,故在宿主签好)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -keyout "${key}" -out "${cert}" \
        -subj "/CN=${cn}" \
        -addext "subjectAltName=DNS:${cn},DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
    chmod 600 "${key}"
    echo "[init-env] 已生成 etc/tls/{fullchain,privkey}.pem(自签 RSA2048/365 天);生产请换真证书。"
}

fix_mount_perms() {
    # 容器以非 root uid 读取 bind 挂载的配置/初始化文件, 需对 other 可读。
    # git pull / 重新 checkout 会把 o+r 抹掉(git 只记可执行位), 故每次跑都补一遍, 幂等。
    # 明确跳过 etc/tls: 里面是 nginx 私钥, 不能 world-readable。
    chmod -R o+rX "${DIR}/initsql" "${DIR}/initsql-extra" 2>/dev/null || true
    chmod o+r "${DIR}/etc/mysql/my.cnf" "${DIR}/etc/o9e/config.toml.tpl" 2>/dev/null || true
    echo "[init-env] 已修正 bind 挂载文件权限(initsql*/my.cnf/config.toml.tpl 对 other 可读;tls 私钥不动)"
}

if [ "${SKIP_ENV}" = 0 ]; then
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
fi

# --- TLS 自签证书(容器内无法 apk 装 openssl,故在宿主预生成)---
gen_tls_cert

# --- 修正 bind 挂载文件权限(容器非 root 读取;checkout/pull 会抹掉 o+r)---
fix_mount_perms
