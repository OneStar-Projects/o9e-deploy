# 使用外部数据库(MySQL / PostgreSQL / 金仓)

平台默认用 compose 内置的 MySQL。客户要求使用自有数据库时(如金仓),按本文由 **DBA 建库建账号**,
再由部署人员执行 `./external-db-init.sh` 完成初始化。n9e 与 topo-studio 用同一个数据库实例、各自独立的库和账号。

## 一、支持的数据库

| 类型 | `DB_TYPE` | 要求 |
|---|---|---|
| MySQL | `mysql` | 8.0+,字符集 `utf8mb4` |
| PostgreSQL | `postgres` | 12+,编码 `UTF8` |
| 金仓 KingbaseES | `postgres` | V8R6+,**必须 PG 兼容模式**(`initdb -m pg`)、**编码 UTF8**(`-E UTF8`) |

> 金仓的兼容模式在实例初始化时确定、之后不可更改。**MySQL 兼容模式不可用**(其 `information_schema` 是 MySQL 风格,
> 平台的表结构迁移无法执行;`||` 也不是字符串拼接)。2026-10-11 已用 V008R006C008B0014 实测。

## 二、DBA 需要准备的

1. **网络**:平台主机能访问数据库端口(金仓默认 54321、PostgreSQL 5432、MySQL 3306)。
2. **两个库 + 两个业务账号**,账号只授权自己的库,口令为复杂口令(大小写+数字+符号,≥16 位,不含 `'` `"` `\` 空格):

| 用途 | 库名 | 账号 |
|---|---|---|
| 平台主库(n9e) | `n9e_v6` | `n9e_app` |
| 网络拓扑(topo-studio) | `topo_studio` | `topo_app` |

**PostgreSQL / 金仓(PG 模式)**,以管理员执行:

```sql
CREATE USER n9e_app  WITH LOGIN PASSWORD '<复杂口令1>';
CREATE USER topo_app WITH LOGIN PASSWORD '<复杂口令2>';
CREATE DATABASE n9e_v6      OWNER n9e_app  ENCODING 'UTF8';
CREATE DATABASE topo_studio OWNER topo_app ENCODING 'UTF8';
-- 业务库只允许各自账号连接
REVOKE CONNECT ON DATABASE n9e_v6      FROM PUBLIC;  GRANT CONNECT ON DATABASE n9e_v6      TO n9e_app;
REVOKE CONNECT ON DATABASE topo_studio FROM PUBLIC;  GRANT CONNECT ON DATABASE topo_studio TO topo_app;
-- 金仓自带的 test 库默认对所有账号开放,建议收回
REVOKE CONNECT ON DATABASE test FROM PUBLIC;
```

**MySQL**:

```sql
CREATE DATABASE n9e_v6      DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE topo_studio DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'n9e_app'@'<平台主机IP>'  IDENTIFIED BY '<复杂口令1>';
CREATE USER 'topo_app'@'<平台主机IP>' IDENTIFIED BY '<复杂口令2>';
GRANT ALL PRIVILEGES ON n9e_v6.*      TO 'n9e_app'@'<平台主机IP>';
GRANT ALL PRIVILEGES ON topo_studio.* TO 'topo_app'@'<平台主机IP>';
```

3. 把 **地址、端口、两个账号的口令** 交给部署人员。

### DBA 安全加固清单(金仓 / PostgreSQL)

2026-10-12 对客户金仓实例(只读)与金仓默认安装的审查结论,交付前逐项确认:

| # | 项 | 要求 | 说明 |
|---|---|---|---|
| 1 | **内置管理员 `sso`、`sao` 的口令** | **必须改为复杂口令** | 金仓默认安装这两个账号口令为公开默认值,可直接登录 `security` 库(已在同版本实测);客户审计必扫 |
| 2 | 其它内置 / 运维账号(如 `kmonitor`) | 确认用途,口令为复杂口令,不用则禁用 | |
| 3 | 口令复杂度与登录失败锁定 | 保持开启(`passwordcheck`、`sys_audlog`) | 客户实例已开启:长度≥10、数字≥2、字母≥2、符号≥1,连续 5 次失败锁定 |
| 4 | **传输加密** | 开启 SSL(`ssl = on` 并配置证书),平台侧随后把 `.env` 的 `DB_SSLMODE` 改为 `require` | 未开启时平台与数据库之间口令和数据均为明文 |
| 5 | **来源地址限制** | `sys_hba.conf` 中 `n9e_v6`、`topo_studio` 只允许平台主机 IP;去掉 `0.0.0.0/0` 的通配 | 默认任何地址都可以尝试登录 |
| 6 | 业务库 public schema | `REVOKE CREATE ON SCHEMA public FROM PUBLIC;`(分别在 `n9e_v6`、`topo_studio` 内执行) | 防止其它账号在业务库里建对象 |
| 7 | 内置库公共连接 | `REVOKE CONNECT ON DATABASE kingbase, security, test FROM PUBLIC;` | 默认所有账号都能连这些库 |
| 8 | 审计与连接日志 | 保持开启(`log_connections`、`sysaudit`) | 客户实例已开启 |

平台侧已做的:业务账号非超级用户、不能建库建角色、只能连自己的库;`init-env.sh` 生成的口令满足上述复杂度
(32 位,含大小写、≥2 位数字、≥1 个符号);`external-db-init.sh` 拒绝含空白 / 引号 / 反斜杠 / `$` / 反引号的口令。

## 三、部署人员操作

```bash
./init-env.sh                       # 新部署:生成 .env(admin 初始密码等)
$EDITOR .env                        # 数据库段改为:
#   COMPOSE_PROFILES=               ← 去掉 builtin-db,不启动内置 MySQL
#   DB_TYPE=postgres                ← 或 mysql
#   DB_HOST=<数据库地址>  DB_PORT=<端口>
#   N9E_DB_PASSWORD=<DBA 给的口令1>  TOPO_DB_PASSWORD=<DBA 给的口令2>
./external-db-init.sh               # 连通性/编码检查 → 导入表结构 → 设 admin 初始密码 → 写 N9E_DB_DSN(PG)
docker compose up -d redis victoriametrics scanopy-postgres scanopy-daemon scanopy n9e topo-studio nginx
./scanopy-bootstrap.sh && ./scanopy-lock-registration.sh
```

`external-db-init.sh` 可重复执行:已有表结构时跳过导入;admin 已改过密码则不动。

## 四、与内置 MySQL 的差异

- **备份**:由客户 DBA 按其规范备份 `n9e_v6`、`topo_studio` 两个库;README「备份」一节的 mysqldump 只适用于内置 MySQL。
- **安全自检**:README「部署后安全自检」第 1~3 条针对内置 MySQL;外部库的账号与权限由 DBA 负责,可按上面第二节核对。
- **大小写**:PG / 金仓下模糊搜索已在平台内统一为不区分大小写(与 MySQL 一致);精确匹配(如登录用户名)区分大小写。
- **拓扑发现(scanopy)** 仍使用自带的 PostgreSQL 容器,不在外部数据库范围内。
