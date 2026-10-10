#!/bin/sh
# 业务专用数据库账号:n9e 与 topo-studio 各一个,只授权各自的库,不再用 root 连库。幂等,可重复执行。
#
# - 新部署:mysql 镜像首次初始化时自动执行(挂在 /docker-entrypoint-initdb.d/,字典序 f- 在建库 SQL 之后)。
#   root 只建 root@localhost(compose 设 MYSQL_ROOT_HOST=localhost),不会有可远程登录的 root。
# - 已有数据(初始化脚本不会再跑):mysql 容器带上新环境变量后手工执行一次
#     docker exec -i o9e-mysql sh < initsql-extra/f-app-users.sh
#   n9e/topo-studio 切到新账号并验证后,再删掉可远程登录的 root:
#     docker exec -i -e DROP_REMOTE_ROOT=1 o9e-mysql sh < initsql-extra/f-app-users.sh
set -eu
: "${MYSQL_ROOT_PASSWORD:?}" "${N9E_DB_USER:?}" "${N9E_DB_PASSWORD:?}" "${TOPO_DB_USER:?}" "${TOPO_DB_PASSWORD:?}"
for u in "$N9E_DB_USER" "$TOPO_DB_USER"; do
    [ "$u" = root ] && { echo "[app-users] 业务账号不能是 root,请按 .env.example 改 N9E_DB_USER/TOPO_DB_USER" >&2; exit 1; }
done
# 模板占位符没被 init-env.sh 替换就等于弱口令,拒绝执行
for p in "$N9E_DB_PASSWORD" "$TOPO_DB_PASSWORD" "${N9E_ADMIN_PASSWORD:-}"; do
    [ "$p" = please-change-me ] && { echo "[app-users] .env 里还有占位符 please-change-me,先跑 ./init-env.sh 生成口令" >&2; exit 1; }
done

# 新部署:a-n9e.sql 给 admin 写的是上游默认的明文弱口令(n9e 首启 InitRoot 会把不足 32 位的明文哈希存下)。
# 在 n9e 首启前把它换成 .env 的随机复杂密码,上游默认口令永远不生效。已哈希过的(老部署,32 位哈希)不动。
# 条件用长度判断而不写口令字面量,避免本文件被安全审计扫成弱口令。
admin_sql=""
if [ -n "${N9E_ADMIN_PASSWORD:-}" ]; then
    [ ${#N9E_ADMIN_PASSWORD} -le 31 ] || { echo "[app-users] N9E_ADMIN_PASSWORD 须 ≤31 位(InitRoot 只哈希短于 32 位的明文)" >&2; exit 1; }
    admin_sql="UPDATE n9e_v6.users SET password='${N9E_ADMIN_PASSWORD}' WHERE username='admin' AND LENGTH(password) < 32;"
fi

drop_sql=""
[ "${DROP_REMOTE_ROOT:-0}" = 1 ] && drop_sql="DROP USER IF EXISTS 'root'@'%', 'root'@'127.0.0.1';"

# 走本机 socket 以 root@localhost 登录;口令只经环境变量传递
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS topo_studio DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${N9E_DB_USER}'@'%' IDENTIFIED BY '${N9E_DB_PASSWORD}';
ALTER USER '${N9E_DB_USER}'@'%' IDENTIFIED BY '${N9E_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON n9e_v6.* TO '${N9E_DB_USER}'@'%';
CREATE USER IF NOT EXISTS '${TOPO_DB_USER}'@'%' IDENTIFIED BY '${TOPO_DB_PASSWORD}';
ALTER USER '${TOPO_DB_USER}'@'%' IDENTIFIED BY '${TOPO_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON topo_studio.* TO '${TOPO_DB_USER}'@'%';
${admin_sql}
${drop_sql}
FLUSH PRIVILEGES;
SQL
echo "[app-users] ${N9E_DB_USER}→n9e_v6, ${TOPO_DB_USER}→topo_studio 已就绪${drop_sql:+;已删除可远程登录的 root}"
