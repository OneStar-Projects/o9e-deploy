# 分区域隔离设计

> **状态（2026-08-30 更新）**：本文原题「多 VM 方案」，设计的是每区域一套
> VM + n9e server + pushgw 双写。**该架构未采用。**
>
> 实际落地的是 **单 VM 全量库 + 查询侧按 ident 集合注入**：不拆 VM、不加区域
> server、采集侧零改动，隔离全部在查询侧完成。原因见 `ops-log.md` 2026-08-30
> 第一节（多 VM 与 region 标签两条路各自的代价）。
>
> 本文保留不删：多 VM 是将来区域间网络或数据量真撑不住时的退路，那时第 3、5 章
> 的三个坑仍然成立；第 9 章的已知限制与架构无关，至今有效。
>
> | 章节 | 状态 |
> |---|---|
> | 1 目标 | 需求有效，「实现手段」一列已变，见节内更正 |
> | 2 核心链路 / 3 架构 | **作废**（多 VM 专属），留作退路参考 |
> | 4 数据源与授权 | 部分有效，实现形态与设计不同，见节内更正 |
> | 5.1 采集机 region 标签 | **作废** —— 采集侧零改动 |
> | 5.2 / 5.3 区域 server 配置 | **作废**（无区域 server），三个坑留作退路参考 |
> | 6.1 ~ 6.5 代码改造 | **已全部落地**，与设计稿的差异见各节 |
> | 7 迁移路径 | **作废**（阶段 1~3 是多 VM 专属） |
> | 8 验证 | 「当前实测」一列已过时，见节内更正 |
> | 9 已知限制 | **仍然有效**，本文最该读的一节 |
> | 10 待定项 | 部分已定，见节内更正 |
>
> 权威实施记录在 `ops-log.md`（2026-08-27 / 08-28 / 08-30 三条）。
>
> 依据：2026-08-27 现场实测
> 前置：`AnonymousAccess` 已关闭、`EventHistoryGroupView = true`、13 台 target 已全量归组

## 1. 目标

| # | 需求 | 实现手段 |
|---|---|---|
| 1 | 总部查看所有资源 | 共享 MySQL + `CanDoBusiGroup` 的 admin 短路（`user.go:928`），零成本 |
| 2 | 区域只看自己的资源 | 业务组（元数据）+ 数据源授权（指标）+ cfgsync 过滤 |
| 3 | 总部统一设置，分区域使用 | 单一 MySQL = 单一配置源 |
| 4 | 总部跨区域聚合查询 | 总部 VM 双写汇聚 |
| 5 | 区域间网络可达 | 不用 edge，区域 server 走 center 模式直连总部 MySQL |

> **更正（08-30）**：需求 1~3 有效，但实现手段变了。#2 的「数据源授权（指标）」
> 粒度只到整个数据源，单 VM 下等于不隔离，已换成**查询侧注入 `ident=~"…"`**
> （见 `ops-log.md` 08-30）。#4、#5 随多 VM 方案一起作废：只有一个 VM，
> 不存在汇聚与跨区域网络问题。

## 2. 核心链路

> **本章作废。**没有区域 VM、没有区域 server、采集机不打 `region` 标签。
> 留作将来真要拆 VM 时的参考。
>
> 但**立足点活下来了**，只是短了一截：`区域 = 一组采集机 = 业务组`。
> 实际方案用 `target_busi_group` 把业务组翻成 ident 集合注入查询，
> 「由部署保证、不依赖人工维护字段」这条性质原样继承。
> 代价是它同时变成了硬约束：**每个区域必须用自己的采集机**——
> `ident` 是采集者不是被监控资源，SNMP / k8s 联邦 / 代理采集出来的序列
> 全部塌到采集机的 ident 上。

```
区域 = 一组采集机 = region 全局标签 = 业务组 = 数据源
```

每一环由**部署**保证，不依赖任何人工维护的数据字段。

> 这是设计的立足点。现场原有的 `area` 字段（燕郊/泉州/舟山）是临时标注、不可信，
> 因此区域维度改由采集机的 `[global.labels]` 承载——它是部署配置，填错属于运维事故，
> 不会像数据字段那样漂移或过期。

## 3. 架构

> **本章作废。**现场是**一台 n9e + 一个 VM**（cosl-6456），13 台采集机全部
> 直接 writer 到它，没有区域 server、没有区域 VM、没有双写。
> 下面的图和「为什么每个区域需要一个 n9e server」的论证在拆 VM 时仍然成立
> —— `[[Pushgw.Writers]]` 是进程级配置这条没变。

```
总部
  MySQL + Redis                  唯一元数据库,所有区域 server 直连
  n9e center + UI                EngineName = default
  总部 VM                        全量汇聚(带 region 标签),仅 admin 可访问
  scanopy / topo-studio          共享,所有区域可见(已决策,不做隔离)

区域 R(每个)
  categraf × N                   [global.labels] region = "R"
                                 writer → 区域 n9e:17000
  n9e server (center 模式)        EngineName = "R",直连总部 MySQL + Redis
    └ pushgw 双写
        ├→ 区域 VM               同步 + 重试
        └→ 总部 VM               AsyncWrite = true
  区域 VM
```

### 为什么每个区域需要一个 n9e server

`[[Pushgw.Writers]]` 是**进程级**配置，`writer.go:371` 向**所有** backend 扇出，无法按数据来源路由。
所以一个 n9e 只能对应一组固定的 VM。

绕过办法是让 categraf 直连 VM，但会丢掉 pushgw 的 label rewrite（现网 `LabelRewrite = true`，
`pushgw/router/fns.go` 会把 target 的 tags 注入序列），两个 VM 里的数据就不一致了。**不采用。**

## 4. 数据源与授权

| 数据源 | 内容 | `cluster_name` | 关联业务组 |
|---|---|---|---|
| `VM-<区域>` | 该区域数据 | `<区域>` | 对应区域业务组 |
| `VM-总部` | 全区域数据 | `default` | **不关联任何业务组** |
| `ES-1` | 日志 | `default` | 按需 |

**「不关联任何业务组 = 仅 admin」是有意设计的默认值**，与 target 相反：

- target：未归组 → 对所有人可见（`router_target.go:86` 的 `bgids = append(bgids, 0)`）
- datasource：未关联 → 仅 admin

这样总部 VM 不需要任何额外配置就自动私有。

> **更正（08-30）**：上表的 `VM-<区域>` / `VM-总部` 三行作废——只有一个 VM
> （数据源 id=1）。另外现场**没有** Jaeger / VictoriaLogs 数据源，只有它和一个 ES。
>
> **「未关联 = 仅 admin」这条已落地并验证过**，但实现形态与设计不同：
> 没有建 `datasource_busi_group` 表，用的是 `datasource.busi_group_ids` 这个
> JSON 列。判据一字不差：`CanAccessDatasource` 里
> `len(ds.BusiGroupIds) == 0 → return false`，admin 在它之前短路。
> 这是**代码强制的拒绝**，不是靠「碰巧没人去授权」兜住，失败方向是安全的。
>
> 由此推出 ES 的真实风险点：**不是「它现在敞开」，而是「哪天有人给它授权了一个
> 业务组」**——那一刻它就对该组全量可见，且 `dsProxy` 对非 prometheus 类型不注入
> 任何约束。防呆手段（启动时对非 prometheus 数据源被授权给业务组打 WARNING）
> 还没做，记在 `ops-log.md` 08-30 的待办里。

## 5. 关键配置（含实测踩过的坑）

> **5.1 / 5.2 / 5.3 全部作废**——采集侧零改动、无区域 server、无需新建数据源。
> **但坑①②③是真实测出来的，拆 VM 那天原样成立**，这是本章留着不删的唯一理由。

### 5.1 采集机 `config.toml`

```toml
[global.labels]
region = "R"

[[writers]]
url = "http://<区域n9e>:17000/prometheus/v1/write"
```

**注意**：加全局 label 会让该 agent 的所有序列断裂重建（新增维度 = 新序列）。
已确认历史数据可丢弃，故一次性做完即可；但**要把将来可能加的全局标签一起想清楚，一次加到位**。

> **更正（08-30）**：上面这条「注意」在上线前预检里被摊开成四条实际代价，
> 直接导致 region 标签方案被换掉：
>
> 1. 要逐台改 13 台采集机（8 台走 cfgsync + 3 台 windows 手工 + 2 台已死），跨两套部署方式
> 2. 序列 identity 全变，VM 当成全新序列：存储短期近似翻倍、所有 `rate()` 跨切换点断一次
> 3. **开关打开后区域用户永久看不到切换点之前的历史**（旧序列没有 region 标签）
> 4. 漏配一台 = 那台指标对区域用户直接消失，**且不报错**
>
> 换成 ident 集合注入后这四条全部归零：数据侧零改动、零序列变更、历史可见、无漏配面。
> 「历史数据可丢弃」当时的判断也过于轻率——可丢弃的是 admin 的历史，
> 区域用户丢的是**全部**。

### 5.2 区域 n9e `config.toml`

```toml
[Alert.Heartbeat]
IP = "<宿主机IP>"          # 必须显式配,不能留空
EngineName = "R"

[[Pushgw.Writers]]
Url = "http://<区域VM>:8428/api/v1/write"

[[Pushgw.Writers]]
Url = "http://<总部VM>:8428/api/v1/write"
AsyncWrite = true          # 必须,理由见下
```

**坑① `[Alert.Heartbeat] IP` 必须显式配。**
留空时自动探测，在容器里探到的是 docker bridge 地址——现网实测 `alerting_engines.instance`
就是 `172.20.0.6:17000`。而该表**没有唯一约束**（只有普通索引），心跳是按
`(instance, engine_cluster, datasource_id)` 三元组 upsert（`alerting_engine.go:150`）。

第二台机器上的 n9e 大概率也拿到 `172.20.0.x`，一旦撞上，两个 server 往同一行心跳，
哈希环里只看到一个节点，**两边都认为规则归自己 → 同一条告警发两遍**。故障表现只有"告警重复"，
不报错，极难定位。

**坑② 总部 writer 必须 `AsyncWrite = true`。**
`writer.go:279` 里 HTTP writer 默认是 critical backend（同步写 + 重试）。总部 VM 挂了或变慢
会阻塞队列消费，**连累区域 VM 的写入**——区域数据可靠性被一个只用于看汇总的后端绑架。
`AsyncWrite = true` 使其走异步路径（有并发上限，超了丢弃并计数），语义正好：
区域 VM 是主，必须可靠；总部 VM 是聚合视图，丢一点可接受。

**坑③ 区域内所有采集机必须心跳到同一 EngineName 的 server。**
`target.engine_name` 是 agent 心跳到哪个 server 就打成哪个值。而 `alert/process/process.go:558`
在 `target.EngineName != p.EngineName` 时会 `continue` **静默跳过** host 类告警——不报错、不留痕。
表现是"某台采集机的主机告警莫名其妙不触发"。

### 5.3 数据源创建顺序（鸡生蛋）

数据源表单的「关联告警引擎集群」下拉，选项来自 `alerting_engines` 表里 distinct 的
`engine_cluster`（`router_server.go:17`），而该表由 server 心跳时自己写入，10 分钟无心跳会被清理。

**所以顺序不能颠倒：**

1. 先用 `EngineName = "R"` 启动区域 n9e
2. 它心跳后，`alerting_engines` 里才出现 `R`
3. 这时数据源表单里才选得到 `R`

反过来先建数据源会被 `Cluster.tsx:31` 的 validator 拦下（`cluster_not_found`）。

## 6. n9e 侧代码改造

> **本章 6.1 ~ 6.5 已全部落地**（2026-08-27 ~ 08-30，见 `ops-log.md`），
> 各节内的差异见节末更正块。本章是全文唯一与现实基本一致的部分。

### 6.1 数据源授权（~2.5 天）

**新表**

```sql
CREATE TABLE datasource_busi_group (
  datasource_id  bigint NOT NULL,
  busi_group_id  bigint NOT NULL,
  UNIQUE KEY (datasource_id, busi_group_id),
  KEY (busi_group_id)
);
```

**鉴权函数**（仿 `CanDoBusiGroup` 的形状）

```
CanAccessDatasource(user, dsId):
  1. user.IsAdmin()                        → true
  2. ds 未关联任何业务组                    → false      ← 安全默认
  3. MyBusiGroupIds(user) ∩ ds 的 bgids ≠ ∅
```

查询路径调用频繁，需缓存：扩展 `DatasourceCacheType`，在 `SyncDatasources()` 时一并加载关联关系。

**挂载点——两个钩子已预留，默认 no-op，只需替换实现：**

| 钩子 | 位置 | 已接入的端点 |
|---|---|---|
| `DatasourceFilter` / `DatasourceCheckHook` | `memsto/datasource_cache.go:40-41` | `datasourceList`、`datasourceBriefs` 等 7 处 |
| `CheckDsPerm` | `center/router/router_query.go:18` | `/ds-query`、`/logs-query`、`/log-query-batch` |

在 `center.Initialize` 里构造完 `DatasourceCache` 之后覆盖即可。

**三个未接入的缺口，需要自己补：**

| 位置 | 端点 | 说明 |
|---|---|---|
| `router_proxy.go:113` `dsProxy` | `/proxy/:id/*url` | **看板和即时查询的主通道**，且路由上缺 `rt.user()`，一并补 |
| `router_proxy.go:39` | `/query-range-batch`、`/query-instant-batch` | |
| 告警规则保存 | `alertRuleAddByFE` / `alertRulePutByFE` | 校验 `datasource_queries` 解析出的 ds id；不补则可建一条查别人数据源的规则绕过前两条 |

> **落地情况（08-27 ~ 08-30）**：
>
> - **不建新表**，用 `datasource.busi_group_ids` JSON 列；鉴权三条判据与设计一致。
> - `CheckDsPerm` 是个**函数变量**（`var CheckDsPerm CheckDsPermFunc`，在
>   `center/datasource_acl.go` 赋值），不是 `func` 声明——按名字 grep 才找得到。
> - `/ds-query` **不是缺口，根本到不了 VM**：`dscache/sync.go` 对
>   `item.Type == "prometheus"` 直接 `continue`，打过去返回 "cluster not exists"。
>   一度把它当成没堵的旁路，是错的。
> - **`dsProxy` 是唯一的 PromQL 出口**，对非 admin 走路径白名单（白名单外 403），
>   白名单内改写 `query` / `match[]`。ES 等非 prometheus 类型**不注入**，
>   否则那些页面会全部 403。
> - 注入**不能写进 `dsPermCheck`**：那函数在 `AnonymousAccess.PromQuerier=true` 时
>   第一行 return，塞进去等于让隔离继承这个开关的旁路。要在 handler 里平级再调一次。
> - **告警规则那一行仍是缺口**，见 §10 更正。

### 6.2 cfgsync 过滤（~2 天）

**不加 `busi_group_id` 字段**，归属从绑定的采集机推导：

```
instance → cfgsync_host_instance_binding → target → target_busi_group → 业务组
```

好处是归属自动跟随部署——把设备从燕郊采集机迁到泉州采集机，区域归属自动变。

**过滤语义是「该实例在我可见的采集机上有绑定」**，而不是"该实例属于我的区域"。原因是监控实例有两种：

| 类型 | 插件 | 语义 | 区域归属 |
|---|---|---|---|
| 远程采集型 | snmp / ups_snmp / leased_line / modbus_room | 一个实例 = 一个远程目标 | 唯一 |
| 本机采集型 | docker / kubernetes | 一个实例 = 采集模板，绑多台 | 不唯一 |

现场 `docker-hub`（id=3）就同时绑在 215 和 213 两台机器上。按上述语义，它会同时出现在
两个区域的视图里——**这是正确的**，因为它在两边都真的在跑。

**需加过滤的端点**（`router_cfgsync.go:39-78`，约 15 个，核心是一个过滤函数 + 一个"我可见的采集机 ident 列表"）：

```
/instances       list / get / create / update / delete
/bindings        create / delete / by-host / by-instance   ← 双向校验
/hosts           list
/host-state(s)   get / list
/preview/host/:id
/main-config     → 直接限 admin(全局单份,区域不该改)
/secrets         → 直接限 admin(跨实例共享,分组很别扭)
```

`/bindings` 必须**双向校验**：绑定同时涉及实例和主机，两边都要有权，否则可以拿自己的实例
去绑别的区域的采集机。

**另需一条校验**：远程采集型插件的同一实例，在同一区域内只能绑一台采集机——
`cfgsync_host_instance_binding` 的唯一键是 `(host_ident, instance_id)` **组合**，
DB 不拦重复绑定，多采集机时误操作会导致重复采集。本机采集型不受此限。

> **落地情况**：过滤已实现（`models/cfgsync_acl.go` + `router_cfgsync.go`），
> 语义与设计一致。三点补充：
>
> - **「归属靠推导」不是缺陷，是有意设计**，加实存字段并不能改善什么——只是把
>   自动跟随部署换成人工维护、会腐坏，而错位的根因（跨区域采集）还在。
>   它与指标层 `ident` 是**同一个模型的两层表现**，缓解手段也是同一条：
>   每个区域用自己的采集机。
> - `binding_count = 0` 的实例推导不出业务组，**仅 admin 可见**——与 target
>   「未归组 → 对所有人可见」的方向相反，是刻意的不对称。
> - 空切片**不能**当「不限制」用（`cfgsync_acl.go:33`），否则可见集合为空会翻转成全放行。

### 6.3 大屏（~1.5 天）

六个 handler 的数据源全部是 MySQL + Redis，**不碰 VM**，因此与指标隔离解耦，可独立完成。

统计项分三类：

| 统计项 | 处理 |
|---|---|
| Target / Alert / Board / Mute / Subscribe | 加 bgids 过滤，都有 `group_id` |
| Datasource | 复用数据源授权 |
| **User / UserGroup / Role 总数** | **没有业务组维度，过滤不了** → 不给区域用户看 |
| 未归组机器数、业务组横向对比 | 过滤后语义失效 → 同上 |

`ScreenGetBusiGroupStatus`（`models/screen.go:601`）本来就是 per-group 循环，
只需把 `DB(c).Model(&BusiGroup{}).Find(&groups)` 的范围改成用户可见业务组。

> **落地情况**：已实现（`abdc0b41`），处理方式与上表一致。

### 6.4 其余（~1 天）

| 项 | 位置 | 改动 |
|---|---|---|
| 看板越权读 | `router.go:364` `boardGetsByBids` | 裸 `WHERE id IN ?`，补权限过滤 |
| cfgsync 秘钥库 | `router_cfgsync.go:74-77` | 注释写 admin 但无检查，补 `rt.admin()` |
| 三个裸路由 | `router.go:449-452` | `event-notify-records` / `event-detail` / `alert-eval-detail`，补 `rt.auth()` |
| 业务服务 | `biz_systems` 表 | 加 `group_id` + 换 `bgro/bgrw` 中间件（照拓扑画布抄） |

> **落地情况**：四项已全部实现（`7c5d9961` 前三项、`2418f870` 业务服务）。
>
> **但这张表远不完整。**08-30 的全量审计（按 `idsForm` 扫全部 19 处批量端点）
> 又挖出 12 个同类缺陷，已在 `0d8b3b5f` 修完。两个反复出现的模式：
>
> 1. list / detail 端点漏挂 `bgro()`
> 2. **`bgrw()` 只锁 URL 上的 `:id`，从不看 body**——所以「路由带 `:id` +
>    body 带 `ids[]`」的端点全部可绕：在自己有权限的组下发一个别组的 id 即可。
>    修法是新增 `bgidMatchCheck(c, gid)` 逐条比对。
>
> 最严重的一个**不在原清单里**：`POST /alert-cur-events/card/details`
> （`alertCurEventsCardDetails`）**零判权**，直接吃 body 里的 ids，
> 而 event id 自增可枚举——等于把全平台告警详情（tags / annotations / 规则名）敞开。
> 明细见 `ops-log.md` 08-30 第二节的缺陷表。

### 6.5 target 增量兜底（~0.5 天）

全量归组只解决存量。**新机器首次上报时没有业务组记录，会落进"未归组"集合，对所有区域用户可见。**

推荐：建一个 `_未分配` 业务组，target 注册时自动归入，只授权管理员组。
这样未归组集合恒为空，新机器不会丢失（总部能看到并分配），区域用户也看不到尚未确定归属的机器。

> **落地情况**：已实现，组名是 **`_待分配`**（不是 `_未分配`）。
> `pushgw/idents/idents.go:163` 调 `models.BindTargetsToUnassigned`，
> `EnsureUnassignedBusiGroup` 建组、不关联任何用户组 → 仅 admin 可见。
> 现场未归组机器数为 **0**，符合预期。
>
> **坑**：`EnsureUnassignedBusiGroup` 是**按组名**找组的，
> 在 UI 里重命名 `_待分配` 会让它静默再建一个重名组，老组里的机器就此滞留。

## 7. 迁移路径

> **本章作废。**阶段 1~3 是多 VM 专属。实际只做了阶段 4（代码改造）。
> 阶段 0 的「371 个实例逐个定区域」也没做——ident 方案不需要它，
> 归属由绑在哪台采集机上自动推导。

```
阶段 0  确定区域清单与资源归属                        ← 人工,不可自动化
        · 371 个监控实例逐个定区域
        · 14 条专线的归属规则(天然跨区域)
        · 当前 BJ/TJ 各 1 台是实测样本,需按真实情况重划

阶段 1  按区域部署采集机
        · [global.labels] region
        · writer 指向区域 n9e

阶段 2  按区域部署 n9e server + VM
        · 先起 server(EngineName=R)让它心跳
        · 再在 UI 建数据源 VM-R,关联引擎集群选 R
        · 显式配 [Alert.Heartbeat] IP

阶段 3  迁移绑定
        · 371 个 binding 的 host_ident 改指向对应区域采集机
        · cfgsync bundle worker 自动重新渲染下发

阶段 4  代码改造上线(6.1 ~ 6.5)

阶段 5  重建规则与看板
        · 22 条规则重新分配到区域数据源(当前全绑 ds_id=1)
        · 看板按新标签体系重写
        · 历史数据可丢弃 → 趁此时做最便宜
```

## 8. 验证

复用 `ops-log.md` 里的方法：建临时账号（仅某区域业务组 rw），登录后对照下表。

| 端点 | 目标 | 08-27 实测 | 现状（08-30） |
|---|---|---|---|
| `GET /targets` | 仅本区域 | ✅ | ✅ |
| `GET /alert-cur-events/list` | 仅本区域 | ✅ | ✅ |
| `GET /cfgsync/instances` | 仅本区域采集机上的 | ❌ 371 个 | ✅ 已过滤 |
| `GET /screen/busi-group-status` | 仅本区域 | ❌ 7 组 | ✅ 已过滤 |
| `POST /datasource/list` | 仅本区域数据源 | ❌ 全可见 | ✅ 未关联 = 仅 admin |
| `GET /proxy/<别区域ds>/*` | 403 | ❌ 200 | ✅ 数据源级已堵 |
| `GET /boards?bids=<别组>` | 403 | ❌ 可读 | ✅ 已补权限过滤 |

> **更正（08-30）**：上表只覆盖了「资源列表层」，**指标数据层不在其中**，
> 补三行：
>
> | 端点 | 目标 | 现状 |
> |---|---|---|
> | `/proxy/1/api/v1/query?query=count(up)` | 只出自己的机器 | **代码已就绪，开关未开** |
> | `/proxy/1/api/v1/label/ident/values` | 只出自己的机器名 | 同上 |
> | 告警规则里的 PromQL | 按规则所属组收窄 | ❌ **未做**，见 §10 |
>
> `Center.RegionIsolation.Enable` 现场仍是 **false**，指标层隔离**没有生效**。
> 打开前的完整验证矩阵（含「用户自写 `ident` 不能被放大成全部」这条关键回归）
> 在计划文件里，不重复。
>
> **两批修复的行为验证都还没跑过**——上表 08-30 一列是「代码已改、逻辑已审」，
> 不是「已实测通过」。别把它当验收记录读。

## 9. 已知限制

> **本章仍然有效**——这几条都与架构无关，换成 ident 方案后一条没少。
> 末尾按 08-30 的实际情况补了四条。

- **业务组只有 `ro`/`rw` 两档** —— 无法表达"能屏蔽告警但不能改规则"。给 `ro` 则区域连临时静默都做不了；给 `rw` 则能改总部设的规则。
- **用户组成员即可修改用户组** —— `CanModifyUserGroup`（`user.go:907`）注释原文"我是成员，也可以吧，简单搞"，区域能自行拉人扩权。有信任边界时须改。
- **用户账号无区域范围** —— 给 `/users/add` 就是全平台权。账号须总部统一建，或接 SSO（`sso_config` 支持 CAS/LDAP/OAuth2/OIDC）。
- **通知规则 / 事件管道 / 告警聚合视图是全局对象** —— `notify_rule`、`event_pipeline`、`alert_aggr_view` 都无 `group_id`。区域自管会互相看见、互相删改。建议不给区域这些 operation；若要自管，各加 `group_id` 约 0.5 天。
- **业务组无层级继承** —— 前端按名字分隔符伪造树，授权不继承，新增子组要记得补授权。
- **scanopy / topo-studio 共享** —— 区域间在资产清单和物理拓扑层面互相可见（已决策）。
- **cfgsync 绑定静态，无故障转移** —— 采集机挂了，它负责的设备停采，不会自动接管。
- **总部做不了实时跨区域聚合的告警** —— 双写有异步延迟，总部 VM 仅适合看板和分析，不宜承载告警评估。（多 VM 专属，当前无双写）

**08-30 补充的限制：**

- **`ident` 是采集者不是被监控资源** —— SNMP / k8s 联邦 / 代理采集出来的序列
  全部塌到那台采集机的 ident 上。**这是 ident 方案的粒度天花板**，
  缓解只能靠部署约束：每个区域用自己的采集机，沿组织边界最细粒度拆。
- **`AllowIdentlessSeries = true` 让 DeepFlow 数据对所有区域可见** ——
  它往 ident 集合里追加一个空串（PromQL 里标签缺失 == 值为空串），
  是**全放行**不是按区域放行。现场为了不让 DeepFlow 页面变空要开着它，
  **接入第二个区域前必须改回 false**。
- **注入是改写查询，不是物理隔离** —— VM 里仍是一份全量库，
  绕过 n9e 直连 VM（8428）即可看到全部。VM 端口的网络访问控制是另一层的事。
- **跨区域业务组是可见性通道** —— 把一个用户加进两个区域的组，他就同时看两边。
  这是设计如此，但要意识到它没有额外的闸。

## 10. 待定项

| # | 问题 | 阻塞 | 状态（08-30） |
|---|---|---|---|
| 1 | 区域清单与 371 个实例的真实归属 | 阶段 0 | **已消解**：ident 方案由绑定自动推导，不需要逐个定 |
| 2 | 14 条专线归属（归总部 / 归一端 / 两端可见） | 阶段 0；选"两端可见"则 cfgsync 需改多对多 | **已消解**：绑在哪台采集机上就归哪，跨区域采集则两边都出现 |
| 3 | 告警规则给区域 `ro` 还是 `rw` | 权限设计 | **仍未定，且已升级成实际缺口**，见下 |
| 4 | 通知规则是否要让区域自管 | 是否新增 0.5 天改造 | 仍未定 |
| 5 | 告警通知模板是否含 `/alert-cur-event/:eid` 链接 | `AlertDetail=false` 后需改 `__token` 机制 | 仍未定 |
| 6 | 各区域是否需要独立 scanopy / deepflow | 影响区域部署重量 | 仍未定 |

### 第 3 项已经不只是权限设计问题

**告警规则求值时没有用户上下文，PromQL 不注入。**而 `Standard` 角色持有
`/alert-rules/{add,put,del}`——区域用户可以建一条查别的区域指标的规则，
再从告警内容里把数据读出来。这是**指标层隔离的一个可达绕过**，不是理论风险。
（现场规则目前全部由 admin 建立，尚无实际暴露。）

两条路，二选一：

| | 做法 | 代价 | 风险 |
|---|---|---|---|
| **A** | 从 `Standard` 角色收回 `/alert-rules/{add,put,del}` | 一条 SQL，零代码 | 区域用户彻底不能自建规则 |
| **B** | 在 `alert/eval/eval.go` 求值时按 `rule.group_id` 注入（4 处：315/441/648/1305） | 需设计 | **有一个阻断性语义问题**，见下 |

**推荐先做 A**（可逆、当天生效），B 作为后续。

B 的阻断点：规则的 `group_id` 未必是机器组。现场 **rule id=1 挂在组 2「资源清单」**
——那不是一个装机器的组，按它推 ident 集合会得到空集，规则会被**静默打断**。
所以 B 必须先回答「非机器组的规则怎么办」：跳过注入（等于留口子）还是拒绝求值
（等于改现网行为）。**这个语义不定下来就不能动 B。**
