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

drop_sql=""
[ "${DROP_REMOTE_ROOT:-0}" = 1 ] && drop_sql="DROP USER IF EXISTS 'root'@'%', 'root'@'127.0.0.1';"

# 走本机 socket 以 root@localhost 登录;口令只经环境变量传递
MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS topo_studio DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${N9E_DB_USER}'@'%' IDENTIFIED BY '${N9E_DB_PASSWORD}';
ALTER USER '${N9E_DB_USER}'@'%' IDENTIFIED BY '${N9E_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON n9e_v6.* TO '${N9E_DB_USER}'@'%';
CREATE USER IF NOT EXISTS '${TOPO_DB_USER}'@'%' IDENTIFIED BY '${TOPO_DB_PASSWORD}';
ALTER USER '${TOPO_DB_USER}'@'%' IDENTIFIED BY '${TOPO_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON topo_studio.* TO '${TOPO_DB_USER}'@'%';
${drop_sql}
FLUSH PRIVILEGES;
SQL
echo "[app-users] ${N9E_DB_USER}→n9e_v6, ${TOPO_DB_USER}→topo_studio 已就绪${drop_sql:+;已删除可远程登录的 root}"
