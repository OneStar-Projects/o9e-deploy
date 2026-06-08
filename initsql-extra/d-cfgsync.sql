-- deploy/single-node/initsql-extra/d-cfgsync.sql
-- 本仓库 fork 相对上游的 schema 增量.
-- 上游 nightingale/docker/initsql/*.sql 的副本在 ../initsql/,由 mysql entrypoint 自动执行,
-- 然后本文件作为 d-cfgsync.sql 紧随其后执行(字典序在 c-init.sql 之后).
-- 现阶段 cfgsync MVP 的表已经走 GORM AutoMigrate(`EnableAutoMigrate` 在 n9e 启动时),
-- 所以这里暂时无需 DDL.保留文件作为后续增量 DDL 的固定锚点.

-- 示例(将来需要时):
-- ALTER TABLE host_state ADD INDEX idx_last_poll (last_poll_at);

SELECT 1;
