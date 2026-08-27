# 分区域隔离设计（多 VM 方案）

> 状态：设计稿　　依据：2026-08-27 现场实测（见 `ops-log.md`）
> 前置：`AnonymousAccess` 已关闭、`EventHistoryGroupView = true`、13 台 target 已全量归组

## 1. 目标

| # | 需求 | 实现手段 |
|---|---|---|
| 1 | 总部查看所有资源 | 共享 MySQL + `CanDoBusiGroup` 的 admin 短路（`user.go:928`），零成本 |
| 2 | 区域只看自己的资源 | 业务组（元数据）+ 数据源授权（指标）+ cfgsync 过滤 |
| 3 | 总部统一设置，分区域使用 | 单一 MySQL = 单一配置源 |
| 4 | 总部跨区域聚合查询 | 总部 VM 双写汇聚 |
| 5 | 区域间网络可达 | 不用 edge，区域 server 走 center 模式直连总部 MySQL |

## 2. 核心链路

```
区域 = 一组采集机 = region 全局标签 = 业务组 = 数据源
```

每一环由**部署**保证，不依赖任何人工维护的数据字段。

> 这是设计的立足点。现场原有的 `area` 字段（燕郊/泉州/舟山）是临时标注、不可信，
> 因此区域维度改由采集机的 `[global.labels]` 承载——它是部署配置，填错属于运维事故，
> 不会像数据字段那样漂移或过期。

## 3. 架构

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

## 5. 关键配置（含实测踩过的坑）

### 5.1 采集机 `config.toml`

```toml
[global.labels]
region = "R"

[[writers]]
url = "http://<区域n9e>:17000/prometheus/v1/write"
```

**注意**：加全局 label 会让该 agent 的所有序列断裂重建（新增维度 = 新序列）。
已确认历史数据可丢弃，故一次性做完即可；但**要把将来可能加的全局标签一起想清楚，一次加到位**。

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

### 6.4 其余（~1 天）

| 项 | 位置 | 改动 |
|---|---|---|
| 看板越权读 | `router.go:364` `boardGetsByBids` | 裸 `WHERE id IN ?`，补权限过滤 |
| cfgsync 秘钥库 | `router_cfgsync.go:74-77` | 注释写 admin 但无检查，补 `rt.admin()` |
| 三个裸路由 | `router.go:449-452` | `event-notify-records` / `event-detail` / `alert-eval-detail`，补 `rt.auth()` |
| 业务服务 | `biz_systems` 表 | 加 `group_id` + 换 `bgro/bgrw` 中间件（照拓扑画布抄） |

### 6.5 target 增量兜底（~0.5 天）

全量归组只解决存量。**新机器首次上报时没有业务组记录，会落进"未归组"集合，对所有区域用户可见。**

推荐：建一个 `_未分配` 业务组，target 注册时自动归入，只授权管理员组。
这样未归组集合恒为空，新机器不会丢失（总部能看到并分配），区域用户也看不到尚未确定归属的机器。

## 7. 迁移路径

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

| 端点 | 目标 | 当前实测 |
|---|---|---|
| `GET /targets` | 仅本区域 | ✅ 已达成 |
| `GET /alert-cur-events/list` | 仅本区域 | ✅ 已达成 |
| `GET /cfgsync/instances` | 仅本区域采集机上的 | ❌ 371 个 |
| `GET /screen/busi-group-status` | 仅本区域 | ❌ 7 组 |
| `POST /datasource/list` | 仅本区域数据源 | ❌ 全可见 |
| `GET /proxy/<别区域ds>/*` | 403 | ❌ 200 |
| `GET /boards?bids=<别组>` | 403 | ❌ 可读 |

## 9. 已知限制

- **业务组只有 `ro`/`rw` 两档** —— 无法表达"能屏蔽告警但不能改规则"。给 `ro` 则区域连临时静默都做不了；给 `rw` 则能改总部设的规则。
- **用户组成员即可修改用户组** —— `CanModifyUserGroup`（`user.go:907`）注释原文"我是成员，也可以吧，简单搞"，区域能自行拉人扩权。有信任边界时须改。
- **用户账号无区域范围** —— 给 `/users/add` 就是全平台权。账号须总部统一建，或接 SSO（`sso_config` 支持 CAS/LDAP/OAuth2/OIDC）。
- **通知规则 / 事件管道 / 告警聚合视图是全局对象** —— `notify_rule`、`event_pipeline`、`alert_aggr_view` 都无 `group_id`。区域自管会互相看见、互相删改。建议不给区域这些 operation；若要自管，各加 `group_id` 约 0.5 天。
- **业务组无层级继承** —— 前端按名字分隔符伪造树，授权不继承，新增子组要记得补授权。
- **scanopy / topo-studio 共享** —— 区域间在资产清单和物理拓扑层面互相可见（已决策）。
- **cfgsync 绑定静态，无故障转移** —— 采集机挂了，它负责的设备停采，不会自动接管。
- **总部做不了实时跨区域聚合的告警** —— 双写有异步延迟，总部 VM 仅适合看板和分析，不宜承载告警评估。

## 10. 待定项

| # | 问题 | 阻塞 |
|---|---|---|
| 1 | 区域清单与 371 个实例的真实归属 | 阶段 0 |
| 2 | 14 条专线归属（归总部 / 归一端 / 两端可见） | 阶段 0；选"两端可见"则 cfgsync 需改多对多 |
| 3 | 告警规则给区域 `ro` 还是 `rw` | 权限设计 |
| 4 | 通知规则是否要让区域自管 | 是否新增 0.5 天改造 |
| 5 | 告警通知模板是否含 `/alert-cur-event/:eid` 链接 | `AlertDetail=false` 后需改 `__token` 机制 |
| 6 | 各区域是否需要独立 scanopy / deepflow | 影响区域部署重量 |
