# initsql-extra

本目录存放**本仓库 fork** 相对上游的 MySQL 增量 schema/DDL.

- `../initsql/` 是上游 `nightingale/docker/initsql/` 的真目录副本(自包含部署需要),
  上游更新时手工同步过来,**不要直接改它**,改了下次同步会丢
- 本目录文件命名以 `d-` `e-` 开头(字典序在上游 `a-n9e.sql` `c-init.sql` 之后)
- mysql 容器 entrypoint 按文件名字典序执行 `/docker-entrypoint-initdb.d/*.sql`,
  本目录文件通过 compose 单文件 bind mount 直接挂到该路径下

加新增量步骤:
1. 在本目录加 `e-something.sql`
2. 在 `../docker-compose.yaml` mysql 服务的 volumes 下加一行:
   `- ./initsql-extra/e-something.sql:/docker-entrypoint-initdb.d/e-something.sql:ro`
3. 销毁 mysql-data volume(`docker compose down -v mysql`)后重启,新库才会执行 init 脚本
   (现有 mysql 实例不会回放 init,需在线 apply)
