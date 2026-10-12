# MySQL → 金仓(PG 兼容模式)迁移问题记录

记录从适配、部署、数据迁移到完整功能测试过程中遇到的全部问题。

**原则:所有问题都通过代码、部署配置或迁移流程解决,不以手工修改数据库的方式处理。**
迁移脚本对源库只读;对目标库只做「清空 → 按表复制 → 重置序列」这一套固定流程;测试只读查询计数。

测试环境:cosl-6456 上自建的金仓容器 `kb-pgtest`(KingbaseES V008R006C008B0014,PG 兼容模式,UTF8),
数据为生产 MySQL 的只读副本(171 张表、约 31.8 万行)。

## 一、数据库实例

| # | 现象 | 根因 | 解决 | 状态 |
|---|---|---|---|---|
| 1 | 客户测试实例上 n9e 建表全部失败 | 实例是 **MySQL 兼容模式**:`information_schema` 为 MySQL 风格(无 `udt_name`),`\|\|` 是逻辑或,不支持 `ON DUPLICATE KEY` / `FROM_UNIXTIME` 等 | 兼容模式在实例初始化时确定、之后无法修改,须由客户新建 **PG 兼容模式**实例 | 待客户提供 |
| 2 | pgx 报 `simple protocol queries must be run with client_encoding=UTF8` | 实例编码不是 UTF8 | 实例初始化时必须 `-E UTF8` | 已写入 [external-db.md](external-db.md) |
| 3 | 搜索区分大小写(MySQL 默认不区分) | 金仓 `--enable-ci` 只允许 Oracle 模式,PG 模式区分大小写 | 代码层:PG 连接池把 `LIKE` 改写为 `ILIKE`(n9e `pkg/ormx/pg_ci_connpool.go`) | 已修复 |
| 4 | 启动时报库不存在 | n9e 检查库是否存在时写死连 `dbname=postgres`,金仓无此库 | 代码层:先直连业务库,能连上即视为存在 | 已修复 |
| 5 | 口令被拒 | 金仓 passwordcheck:长度≥10、数字≥2、字母≥2、符号≥1 | `init-env.sh` 生成的口令满足该规则;`external-db-init.sh` 拒绝含空白、引号、反斜杠、`$`、反引号的口令 | 已修复 |

## 二、代码适配(n9e / topo-studio)

| # | 现象 | 根因 | 解决 | 状态 |
|---|---|---|---|---|
| 6 | 建表失败 | 模型写死 MySQL 类型:`longtext`、`blob`、`binary`/`varbinary`、`tinyint(1)`、`unsigned` | 代码层:PG 方言包装按库翻译类型(`pkg/ormx/pg_dialector.go`) | 已修复 |
| 7 | 建索引失败 | PG 索引名在整个 schema 内唯一,多张表都叫 `idx_component_id` | 代码层与初始化 SQL:改为带表名的索引名 | 已修复 |
| 8 | 主机配置状态更新报 `ON DUPLICATE KEY` 语法错误 | MySQL 专用 upsert | 代码层:改为 GORM 通用 `OnConflict`。顺带修复了 MySQL 下 `dirty_since` 从不刷新的问题 | 已修复 |
| 9 | 同上改造后报 `column reference is ambiguous` | PG 的 `ON CONFLICT DO UPDATE` 中列名须带表名 | 代码层:更新表达式列名加表名 | 已修复 |
| 10 | 大屏日趋势报错 | `FROM_UNIXTIME()` / `DATE()` 为 MySQL 专用 | 代码层:改为 `col - MOD(col + 时区偏移, 86400)` 通用写法 | 已修复 |
| 11 | **大屏告警小时趋势为空,日志报 `syntax error at or near "DIV"`**(完整功能测试发现) | `trigger_time DIV 3600` 为 MySQL 整数除法;报错被吞,接口仍返回成功 | 代码层:改为 `trigger_time - MOD(trigger_time, 3600)` | 已修复(n9e 03ec3f2a;第四轮完整测试验证,全程无数据库报错;MySQL 上新旧 SQL 结果一致) |
| 12 | 事务提交 panic | GORM 用 `reflect.ValueOf(committer).IsNil()` 判断,连接池 / 事务包装须为指针 | 代码层:改为指针类型 | 已修复 |
| 13 | topo-studio 无法使用 PG | 只有 MySQL 存储实现 | 代码层:补 PG 存储(占位符 `$n`、`ON CONFLICT`、`RETURNING id`)与 PG 建表脚本 | 已修复 |
| 14 | **首次部署时日志报 `cached plan must not change result type`**(连接池修正后的完整功能测试发现) | pgx 默认在每条连接上缓存预编译语句;启动时自动迁移先探测列类型、再改列类型、再探测,复用了旧语句。影响 `builtin_metrics`、`dash_annotation`、`event_pipeline`,这些表的自动迁移可能要到下次重启才补齐。之前每条 SQL 都新建连接,所以没暴露 | 代码层:PG 连接默认 `default_query_exec_mode=describe_exec`(仍为参数化查询,只是不缓存;DSN 显式指定时以 DSN 为准) | 已修复(n9e 03ec3f2a;第四轮完整测试验证,全程无数据库报错;MySQL 上新旧 SQL 结果一致) |

## 三、部署

| # | 现象 | 根因 | 解决 | 状态 |
|---|---|---|---|---|
| 15 | 连接串被截断 | `.env` 里 `N9E_DB_DSN` 未加引号,含空格的 PG 连接串被截断 | `external-db-init.sh` 写入时加双引号 | 已修复 |
| 16 | **373 个实例的主机(2.13)渲染配置要 59 秒**(完整功能测试发现) | 部署模板 `[DB]` 段没写连接池参数,`MaxIdleConns=0` → **每条 SQL 都新建连接**。MySQL 建连便宜所以一直没暴露;PG / 金仓每个连接要起后端进程并做 SCRAM 认证。生产 MySQL 当前同样如此 | `etc/o9e/config.toml.tpl` 补 `MaxLifetime=7200`、`MaxOpenConns=50`、`MaxIdleConns=20`(金仓默认 `max_connections=100`,上游默认 150 会超限) | 已修复:2.13 渲染 59s → 1.4s,其余主机 < 0.5s;金仓 CPU 38% → 2% |
| 17 | 安全审计关注到库连接未加密 | — | `DB_SSLMODE`(默认 `prefer`)贯穿 n9e 与 topo-studio;DBA 加固清单见 [external-db.md](external-db.md) | 已提供开关 |

## 四、数据迁移(`migrate-mysql-to-pg.py`)

| # | 现象 | 根因 | 解决 | 状态 |
|---|---|---|---|---|
| 18 | 目标库表结构从哪来 | 两边类型、索引不同,不能照搬 MySQL DDL | 流程:新版 n9e / topo-studio 先连目标库启动一次建表,停服后再迁数据 | 已固化进流程 |
| 19 | 建表时写入的默认数据与源数据冲突 | n9e 首启会写内置数据 | 流程:迁移前 `TRUNCATE ... RESTART IDENTITY` 清空目标表 | 已固化 |
| 20 | 迁移后新建对象撞主键 | 数据带着原 id 复制过去,序列仍从 1 开始 | 流程:迁移后把 160 个自增序列重置到当前最大值 | 已固化 |
| 21 | 布尔、二进制、含制表符/换行的文本导入出错 | MySQL 文本导出与 PG `COPY` 格式不同 | 按目标列类型转换:布尔→`t/f`,二进制→`\x` 十六进制,文本转义 `\`、制表、换行、回车,去掉 PG 不接受的 NUL | 已修复 |
| 22 | 源库有一张 `alert_rule_bak_fixjson`,目标库没有 | 历史手工备份表 | 两边共有的表才迁,其余列出跳过 | 预期行为 |
| 23 | 目标库多出 `sys_stat_statements` 等 | 金仓自带统计视图 | 同上,保持为空 | 预期行为 |
| 24 | 迁移要 20 分钟 | 每次查询都新起一个客户端容器 | 常驻一个客户端容器、空表跳过、序列一次性重置:1225s → 约 160s | 已修复 |
| 25 | 演练时告警两张表行数差几行 | 演练时生产未停,复制期间又写入了新告警 | **正式迁移必须先停 n9e**,源库不再写入 | 流程要求 |
| 26 | 加密的口令迁移后能否解密 | 秘钥库密文依赖主密钥 | 新部署 `.env` 的 `N9E_SECRET_MASTER_KEY` 必须与原环境一致;已验证 agent 能解析迁移来的密钥 | 流程要求 |

## 五、仍需关注

| # | 事项 | 说明 |
|---|---|---|
| 27 | 测试用金仓容器不能承载生产 | `kb-pgtest` 数据未挂数据卷(删容器即丢数据)、重启策略为 no、限 1 核 3G。生产须用客户正式实例或重新规划的容器 |
| 28 | 切换即升级 | 生产 6456 的 o9e 镜像为 2026-09-09 版本,切换到金仓需要用新镜像,等于同时升级约一个月的代码 |
| 29 | 仍有 MySQL | deepflow 自带 MySQL(控制面元数据)未更换。deepflow v7.1 开源版有 PG 支持,但 PG 修复(上游 PR #11678)不在 v7.1,且 PG 无增量升级脚本、连接写死 `sslmode=disable`。若客户要求完全不用 MySQL,需单独评估 |
| 30 | scanopy 自带 PG 17 | 未与平台库合并 |
| 31 | 回切 MySQL 未实际演练 | 源 MySQL 全程只读未改,回切 = `.env` 改回内置库后重启 |

## 六、完整功能测试覆盖(迁移后的生产数据)

- 100 个页面查询接口逐个调用,数据库报错 0 个;
- 迁移对象详情:仪表盘 19、告警规则 25、业务画布 11、网络画布 5、业务组 7、采集实例 60、主机配置预览 10 台、主机收敛状态 15 台;
- 增删改:用户组、业务组、用户(含新用户登录与大小写不敏感搜索)、仪表盘(中文配置回读)、告警规则(复制生产规则)、屏蔽规则、画布(中文图形回读);
- agent 全链路:签发装机令牌 → 注册 → 绑定 → 拉配置包 → 回执收敛 → 解析迁移来的密钥 → 心跳自动注册主机;
- topo-studio 使用 PG 存储;告警引擎在评估迁移来的规则;全程日志检查数据库报错。
