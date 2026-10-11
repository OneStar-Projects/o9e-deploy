# PostgreSQL / 金仓(PG 兼容模式)初始化 SQL

外部数据库(`DB_TYPE=postgres`)首次部署时,由 `./external-db-init.sh` 以业务账号导入到 n9e 库。

来源:n9e monorepo `nightingale/docker/compose-postgres/initsql_for_postgres/`,本仓库相对上游的改动:

1. `a-n9e.sql` 中 admin 的初始口令由上游默认弱口令改为占位串 `__set_by_init__`,导入后由脚本替换为 `.env` 的 `N9E_ADMIN_PASSWORD`;
2. `component_id` 索引名改为带表名(PG 索引名在 schema 内唯一,上游重名会导入失败)。

从上游同步时**保留以上两处**,否则客户安全审计会扫出默认弱口令。
