-- topo-studio 独立库;表结构由 topo-studio 启动时 TOPO_DB_MIGRATE=true 自动建。
-- 字典序 e- 保证在 a-/c-/d- 之后执行。
CREATE DATABASE IF NOT EXISTS topo_studio
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
