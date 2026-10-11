#!/usr/bin/env bash
# 外部数据库首次部署初始化,按 .env 的 DB_TYPE 适配:
#   mysql    —— 客户提供的 MySQL 8;
#   postgres —— PostgreSQL / 金仓(须 PG 兼容模式、UTF8 编码)。
# 可重复执行,已完成的步骤自动跳过。
#
# 前提(DBA 完成,见 docs/external-db.md):已建 N9E_DB_NAME / TOPO_DB_NAME 两个库与对应业务账号;
# .env 已填 DB_TYPE、DB_HOST、DB_PORT 与两个业务账号口令,COMPOSE_PROFILES 不含 builtin-db。
#
# 做的事:1. 业务账号连通性与编码检查;2. n9e 库无表时导入表结构;3. admin 初始口令占位串替换为
# .env 的 N9E_ADMIN_PASSWORD;4. 写入 n9e 连接串 N9E_DB_DSN(PG);5. 检查 topo-studio 账号
# (其表由 topo-studio 启动时自动建)。口令只经临时 env 文件或标准输入传给客户端容器,不出现在命令行与输出里。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${DIR}"
[ -f .env ] || { echo "[ext-db] 缺 .env,先跑 ./init-env.sh" >&2; exit 1; }
# shellcheck source=/dev/null
set -a; . ./.env; set +a

DB_TYPE="${DB_TYPE:-mysql}"
case "${DB_TYPE}" in mysql|postgres) ;; *) echo "[ext-db] DB_TYPE 只能是 mysql 或 postgres" >&2; exit 1;; esac
[ "${DB_HOST:-mysql}" != mysql ] || { echo "[ext-db] DB_HOST 仍是内置 mysql,内置库无需本脚本" >&2; exit 1; }
: "${DB_HOST:?}" "${DB_PORT:?}" "${N9E_DB_USER:?}" "${N9E_DB_PASSWORD:?}" "${TOPO_DB_USER:?}" "${TOPO_DB_PASSWORD:?}" "${N9E_ADMIN_PASSWORD:?}"
N9E_DB_NAME="${N9E_DB_NAME:-n9e_v6}"; TOPO_DB_NAME="${TOPO_DB_NAME:-topo_studio}"
[ ${#N9E_ADMIN_PASSWORD} -le 31 ] || { echo "[ext-db] N9E_ADMIN_PASSWORD 须 ≤31 位" >&2; exit 1; }
case "${COMPOSE_PROFILES:-}" in *builtin-db*) echo "[ext-db] WARN: COMPOSE_PROFILES 仍含 builtin-db,内置 MySQL 也会启动" >&2;; esac

TMP="$(mktemp -d)"; chmod 700 "${TMP}"; trap 'rm -rf "${TMP}"' EXIT
# 客户端容器加入的 docker 网络:数据库是可路由 IP 时保持默认;数据库也是本机容器时设为它所在的网络
NET_ARGS=(); [ -n "${INIT_DOCKER_NETWORK:-}" ] && NET_ARGS=(--network "${INIT_DOCKER_NETWORK}")
ADMIN_SQL="UPDATE users SET password = '${N9E_ADMIN_PASSWORD}' WHERE username = 'admin' AND LENGTH(password) < 32;"

if [ "${DB_TYPE}" = postgres ]; then
    printf 'PGPASSWORD=%s\n' "${N9E_DB_PASSWORD}"  > "${TMP}/n9e.env"
    printf 'PGPASSWORD=%s\n' "${TOPO_DB_PASSWORD}" > "${TMP}/topo.env"
    IMG="${PSQL_IMAGE:-postgres:17-alpine}"
    q() { # envfile user db [psql 参数...]
        local envf=$1 user=$2 db=$3; shift 3
        docker run --rm -i ${NET_ARGS[@]+"${NET_ARGS[@]}"} --env-file "${envf}" -v "${DIR}/initsql-pg:/initsql:ro" "${IMG}" \
            psql "host=${DB_HOST} port=${DB_PORT} user=${user} dbname=${db} connect_timeout=10" -v ON_ERROR_STOP=1 "$@"
    }
    q_val()   { q "$1" "$2" "$3" -Atc "$4"; }
    q_file()  { q "${TMP}/n9e.env" "${N9E_DB_USER}" "${N9E_DB_NAME}" -q -f "/initsql/$1"; }
    q_stdin() { q "$1" "$2" "$3" -q; }
    ENC_SQL="show server_encoding"; ENC_OK=UTF8
    HAS_USERS_SQL="select (to_regclass('public.users') is not null)::int"
    INIT_FILES="a-n9e.sql b-ibex.sql"
else
    printf 'MYSQL_PWD=%s\n' "${N9E_DB_PASSWORD}"  > "${TMP}/n9e.env"
    printf 'MYSQL_PWD=%s\n' "${TOPO_DB_PASSWORD}" > "${TMP}/topo.env"
    IMG="${MYSQL_CLIENT_IMAGE:-mysql:8.0}"
    q() { # envfile user db [mysql 参数...]
        local envf=$1 user=$2 db=$3; shift 3
        docker run --rm -i ${NET_ARGS[@]+"${NET_ARGS[@]}"} --env-file "${envf}" -v "${DIR}/initsql:/initsql:ro" -v "${DIR}/initsql-extra:/initsql-extra:ro" "${IMG}" \
            mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${user}" --connect-timeout=10 --default-character-set=utf8mb4 "${db}" "$@"
    }
    q_val()   { q "$1" "$2" "$3" -Nse "$4"; }
    # 上游 a-n9e.sql 开头的 create database / use 需要建库权限,业务账号没有,导入时跳过(库已由 DBA 建好)
    q_file()  { grep -viE '^(create database|use )' "$1" | q "${TMP}/n9e.env" "${N9E_DB_USER}" "${N9E_DB_NAME}"; }
    q_stdin() { q "$1" "$2" "$3"; }
    ENC_SQL="select @@character_set_database"; ENC_OK=utf8mb4
    HAS_USERS_SQL="select count(*) from information_schema.tables where table_schema = database() and table_name = 'users'"
    INIT_FILES="initsql/a-n9e.sql initsql-extra/d-cfgsync.sql"
fi
chmod 600 "${TMP}"/*.env

echo "[ext-db] 1. 连通性(${DB_TYPE}):${N9E_DB_USER}@${DB_HOST}:${DB_PORT}/${N9E_DB_NAME}"
q_val "${TMP}/n9e.env" "${N9E_DB_USER}" "${N9E_DB_NAME}" "select version()" | sed 's/^/[ext-db]    /'
enc="$(q_val "${TMP}/n9e.env" "${N9E_DB_USER}" "${N9E_DB_NAME}" "${ENC_SQL}")"
[ "${enc}" = "${ENC_OK}" ] || { echo "[ext-db] 库编码为 ${enc},须为 ${ENC_OK}" >&2; exit 1; }

if [ "$(q_val "${TMP}/n9e.env" "${N9E_DB_USER}" "${N9E_DB_NAME}" "${HAS_USERS_SQL}")" = 1 ]; then
    echo "[ext-db] 2. n9e 表结构已存在,跳过导入"
else
    echo "[ext-db] 2. 导入 n9e 表结构"
    for f in ${INIT_FILES}; do echo "[ext-db]    ${f}"; q_file "${f}"; done
fi

echo "[ext-db] 3. admin 初始密码(只替换未哈希的占位串,已改过的不动;经标准输入传入)"
printf '%s\n' "${ADMIN_SQL}" | q_stdin "${TMP}/n9e.env" "${N9E_DB_USER}" "${N9E_DB_NAME}"

if [ "${DB_TYPE}" = postgres ]; then
    echo "[ext-db] 4. 写入 .env 的 N9E_DB_DSN"
    dsn="host=${DB_HOST} port=${DB_PORT} user=${N9E_DB_USER} password=${N9E_DB_PASSWORD} dbname=${N9E_DB_NAME} sslmode=disable"
    awk -v dsn="${dsn}" 'BEGIN{done=0} /^N9E_DB_DSN=/{print "N9E_DB_DSN=" dsn; done=1; next} {print} END{if(!done) print "N9E_DB_DSN=" dsn}' .env > "${TMP}/env" \
        && cat "${TMP}/env" > .env && chmod 600 .env
else
    echo "[ext-db] 4. MySQL 连接串由 compose 按 DB_HOST / DB_PORT 自动拼接,无需写入"
fi

echo "[ext-db] 5. topo-studio 账号连通性:${TOPO_DB_USER}@${TOPO_DB_NAME}"
q_val "${TMP}/topo.env" "${TOPO_DB_USER}" "${TOPO_DB_NAME}" "select 'ok'" | sed 's/^/[ext-db]    /'

echo "[ext-db] 完成。接着启动(不含内置 MySQL):"
echo "[ext-db]   docker compose up -d redis victoriametrics scanopy-postgres scanopy-daemon scanopy n9e topo-studio nginx"
