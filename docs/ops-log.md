# 生产配置变更记录

记录 cosl-6456（192.169.219.215）上的配置类变更，供后续分析与回溯。

格式：每次变更一节，包含**背景 / 变更前实测 / 变更内容 / 执行步骤 / 变更后验证 / 回滚方法 / 遗留项**。
"实测"一律记录命令和原始输出，不记结论性描述——结论会过期，数据不会。

---

## 2026-08-27　关闭 Center.AnonymousAccess

### 背景

排查"分区域隔离"方案时发现，n9e 有两个匿名访问开关处于打开状态，导致**未登录即可读取指标数据和告警详情**。
这使得任何基于业务组/数据源的隔离方案都失去意义——鉴权代码根本不会被执行：

```go
// center/router/router_query.go 的四处调用点
if !anonymousAccess && !CheckDsPerm(ctx, f.DatasourceId, f.Cate, q) { ... }
//  ^^^^^^^^^^^^^^^^ 为 true 时整个鉴权被短路跳过

// center/router/router_funcs.go:183
func HasPermission(ctx, c, sourceType, sourceId string, isAnonymousAccess bool) bool {
	if sourceType == "event" && isAnonymousAccess {
		return true      // 告警详情直接放行
	}
```

### 变更前调研

**配置来源**：`etc/o9e/config.toml.tpl:66-68`，容器 entrypoint 用 envsubst 渲染成 `/app/etc/config.toml`。

**git 溯源**：这三行从初始提交 `bfa6285`（2026-06-08「init: o9e single-node 部署仓库」）就存在，
中间两次改动都只涉及相邻的 `TopoStudioUrl`。上游 n9e 自带的示例配置 `nightingale/etc/config.toml:135-137`
同样是 `true`。

> 结论：**这是上游示例配置的惯性，不是为了让某个功能跑起来而特意打开的**。降低了关闭的风险评估。

**调用方调研**（nginx access log，容器重启后约 6 小时窗口，共 11948 行）：

| 端点 | 调用次数 |
|---|---|
| `/api/n9e/proxy/1/*`（指标查询） | 9841 |
| `alert-cur-event` / `alert-his-event` | 0 |
| `event-notify-records` / `event-detail` / `alert-eval-detail` | 0 |
| `query-range-batch` / `ds-query` / `logs-query` | 0 |

User-Agent 分布：`Mozilla/5.0 (Macintosh ... Chrome/151)` 11937 次，`curl/8.7.1` 1 次。
全部 9952 次 `/proxy/1` 来自 `172.20.0.1`（docker 网关 = 宿主机），Referer 为 `http://localhost:28765/biz-wall`
——**是本地开发前端的业务墙页面，不是生产用户或免登录集成**。

直连 17000 的连接（绕过 nginx）只有 `deepflow-server`（172.23.0.4），走 remote-write，不受本开关影响。

> **证据局限**：nginx 容器 6 小时前重启过，日志窗口只有 6 小时，且恰好是本地开发时段，样本有偏。
> 不能排除其他时段存在别的调用方。若需更强证据，可先打开 `PrintAccessLog`（当前 `false`）观察 1-2 天。

### 变更前实测（基线）

直连 n9e，不带任何认证：

```bash
for p in "proxy/1/api/v1/query?query=up" "alert-cur-event/1" "alert-his-event/1" "event-notify-records/1"; do
  printf "%-42s %s\n" "$p" "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:17000/api/n9e/$p")"
done
```

```
proxy/1/api/v1/query?query=up               200
alert-cur-event/1                           200
alert-his-event/1                           200
event-notify-records/1                      200
```

### 变更内容

`etc/o9e/config.toml.tpl`：

```diff
 [Center.AnonymousAccess]
-PromQuerier = true
-AlertDetail = true
+PromQuerier = false
+AlertDetail = false
```

### 执行步骤

服务器上的 `/home/kylin/o9e-deploy` 是 git checkout，但**落后本地一个 commit 且有未提交改动**
（`deepflow/common/config/deepflow-server/server.yaml`）。为避免 `git pull` 把 deepflow 的变更
一并带入，**直接修改服务器上的文件**，本地仓库另行提交保持一致。

```bash
# 1. 备份
cd /home/kylin/o9e-deploy
cp etc/o9e/config.toml.tpl /tmp/config.toml.tpl.bak.20260827-203412

# 2. 按行号精确替换（避免误伤同名字段）
sed -i "67s/^PromQuerier = true$/PromQuerier = false/; \
        68s/^AlertDetail = true$/AlertDetail = false/" etc/o9e/config.toml.tpl

# 3. 重启（entrypoint 重新 envsubst 渲染 config.toml）
docker restart o9e
```

重启耗时约 20 秒（7 次 3 秒轮询后转 healthy）。

### 变更后验证

**① 渲染结果**

```
[Center.AnonymousAccess]
PromQuerier = false
AlertDetail = false
```

**② 匿名访问**

```
proxy/1/api/v1/query?query=up               401   ← 已封堵（原 200）
alert-cur-event/1                           401   ← 已封堵（原 200）
alert-his-event/1                           401   ← 已封堵（原 200）
event-notify-records/1                      200   ← 仍开放（裸路由，不受本开关控制）
event-detail/abc123                         400   ← 仍开放，仅被 hash 格式校验拦下
```

**③ 采集链路未受影响**

```
count(up)                    = 61
time()-max(timestamp(up))    = 1.355 秒        ← 数据实时在写
```

**④ 告警引擎重新注册**

```
instance          engine_cluster  datasource_id  last_beat
172.20.0.6:17000  default         1              2026-08-27 20:38:04
172.20.0.6:17000  default         2              2026-08-27 20:38:04
172.20.0.6:17000  default         99999999       2026-08-27 20:38:04
```

**⑤ 日志**

`docker logs o9e --since 5m` 中仅有 alert_eval_3 的既有噪音
（`unmarshal annotations json failed`、`fill event target error, ident: 10.185.252.x doesn't exist in cache`），
与本次变更无关——那是 snmp 设备 IP 未注册为 target 导致的既有问题。

### 回滚方法

```bash
cd /home/kylin/o9e-deploy
cp /tmp/config.toml.tpl.bak.20260827-203412 etc/o9e/config.toml.tpl
docker restart o9e
```

### 遗留项

**① 需人工验证的页面**

本次变更后，未登录的取数调用会返回 401。**唯一已知的高频调用方是业务墙页面 `/biz-wall`**
（本地开发前端 localhost:28765）。

> **2026-08-27 已验证：业务墙正常出数**，说明该页面携带登录态，不依赖匿名通道。
> 本项关闭。

**② 三个不受开关控制的裸路由（仍然完全开放，需改代码）**

`center/router/router.go:449-452`，均无 `rt.auth()`，handler 内部也无鉴权：

| 路由 | 泄露内容 |
|---|---|
| `GET /event-notify-records/:eid` | 通知记录：谁被通知、通过什么渠道 |
| `GET /event-detail/:hash` | 事件日志 HTML 页 |
| `GET /alert-eval-detail/:id` | 告警评估详情 |

**③ 告警通知链接**

`AlertDetail = false` 后，若告警通知模板中包含指向 `/alert-cur-event/:eid` 的链接，
收件人点开会要求登录。代码中已有替代机制 `ValidateSourceToken`（`__token` 查询参数，
见 `center/router/router_funcs.go:199`），可为通知链接签发一次性 token。
**当前未确认通知模板是否包含此类链接。**

**④ 本地仓库同步**

服务器已改，本地仓库需提交同样变更以避免漂移。
> 已完成：commit `bae2ae3`，两边文件内容（含注释）已对齐。

---

## 2026-08-27　区域业务组资源归属（测试样本）

### 背景

区域业务组框架已由人工建好（BJ / TJ / YJ / ZJ 四组，各配同名用户组，`perm_flag = rw`），
但四个组**零资源**，无法验证隔离效果。本次挑三台机器分别归入三个区域，
留 ZJ 为空组，用于后续实测下列行为：

- 区域用户能否只看到本区域机器
- **未归组机器是否对所有用户可见**（`router_target.go:82-87` 的 `bgids = append(bgids, 0)`）
- 空业务组用户会看到什么

### 变更前状态

```
业务组             机器  告警规则  看板
Default Busi Group   0      0       9
资源清单             0     22      10
network              1      0       0
BJ / TJ / YJ / ZJ    0      0       0
未归组机器：12 台
```

### 变更内容

```sql
INSERT IGNORE INTO target_busi_group (target_ident, group_id, update_at) VALUES
  ('YJ-IMC-1', 4, UNIX_TIMESTAMP()),   -- → BJ
  ('YJ-IMC-2', 5, UNIX_TIMESTAMP()),   -- → TJ
  ('YJ-IMC-3', 6, UNIX_TIMESTAMP());   -- → YJ
```

直接写库而非走 API：该表的过滤在查询期做 SQL join，无需等缓存刷新。
表有唯一键 `(target_ident, group_id)`，用 `INSERT IGNORE` 保证幂等。

### 变更后验证

```
id  name                targets                    cnt
 3  network             yjcollect2.13-10.185.2.13    1
 4  BJ                  YJ-IMC-1                     1
 5  TJ                  YJ-IMC-2                     1
 6  YJ                  YJ-IMC-3                     1
 7  ZJ                  (空)                         0
仍未归组：9 台
```

三台机器均为 windows / categraf v0.5.13 / 10.185.2.x：
`YJ-IMC-1` = 10.185.2.1，`YJ-IMC-2` = 10.185.2.2，`YJ-IMC-3` = 10.185.2.3。

### 回滚方法

```sql
DELETE FROM target_busi_group WHERE target_ident IN ('YJ-IMC-1','YJ-IMC-2','YJ-IMC-3');
```

### 遗留项

- 仍有 **9 台机器未归组**，按"未归组 = 对所有人可见"的语义，它们对任何登录用户都可见。
  正式启用区域隔离前必须全部归组，且需要新机器上线时的归组流程或代码兜底。
- 22 条告警规则仍全部挂在"资源清单"组，19 个看板在 Default / 资源清单，均未按区域拆分。

---

## 2026-08-27　隔离效果实测（临时账号，已删除）

### 方法

建临时账号 `test-bj`（`Standard` 角色，仅加入 `BJ` 用户组 → 对 `BJ` 业务组有 `rw`，
该组含唯一机器 `YJ-IMC-1`），登录取 JWT 后逐个调 API，与"正确隔离下应该看到什么"对照。

账号创建走 SQL（`CryptoPass = MD5(salt + "<-*Uk30^96eY*->" + 明文)`，salt 取自 `configs` 表
的 `salt` 键）。**测试完毕已删除账号及其成员关系，残留检查为 0。**

### 结果

| 端点 | 正确隔离应看到 | 实际看到 | 结论 |
|---|---|---|---|
| `GET /targets` | 1 台（YJ-IMC-1） | **10 台** | ❌ 未归组的 9 台全部可见 |
| `GET /alert-cur-events/list` | 0 条 | **54 条**（全属"资源清单"组） | ❌ 告警不按业务组过滤 |
| `GET /cfgsync/instances` | 0 个 | **371 个** | ❌ 监控资源零隔离 |
| `GET /screen/busi-group-status` | 1 个业务组 | **7 个全部**（含 BJ/TJ/YJ/ZJ） | ❌ 大屏零隔离 |
| `POST /datasource/list` | 受限 | **VM-1 + ES-1 全可见** | ❌ 数据源无授权机制 |
| `GET /proxy/1/api/v1/query` | 403 | **200**，`count(up)` 返回 61 | ❌ 指标查询无鉴权 |
| `GET /boards?bids=22,23,17` | 403 | **3 个别组看板** | ❌ 看板可越权读 |
| `GET /busi-groups` | 仅 BJ | **仅 BJ** | ✅ 唯一正确的一项 |
| `GET /biz-systems` | — | 0 个（表为空） | ⚠️ 无样本，未验证 |
| `GET /cfgsync/secrets` | 403 | 0 个（表为空） | ⚠️ 无样本，未验证 |

**8 项可验证的推断中，7 项被证实存在，1 项（业务组列表本身）隔离正确。**

### 关键佐证

对照数据库真实分布，可排除"恰好没数据"的干扰：

```
alert_cur_event   group_id=2  55 条        ← 全部属于"资源清单"组
alert_his_event   group_id=2  25224 条（近7天）
```

test-bj 对 `group_id=2` **没有任何权限**，却读到了其中 54 条。

`GET /proxy/1/api/v1/query?query=count(up)` 返回 61 —— 拿到了全部 61 个 target 的指标，
包含其他区域的机器。

### 结论对方案的影响

此前列出的漏洞清单由**代码推断**升级为**实测证实**，改造优先级不变：

1. 数据源授权（`/proxy`、`/datasource/list` 两项一并解决）
2. cfgsync 过滤（371 个实例全裸）
3. 大屏 bgids 过滤
4. `EventHistoryGroupView = true`（告警事件，仅配置，最便宜）
5. `boardGetsByBids` 补权限
6. 全量归组（消除"未归组 = 公开"）

其中 **第 4 项是纯配置**，应最先做。

### 复现方法

如需再次验证，重建账号：

```sql
-- 密码 TestBJ@2026tmp，hash 依赖 configs.salt，换环境需重算
INSERT INTO users (username,nickname,password,roles,create_at,create_by,update_at,update_by)
VALUES ('test-bj','临时测试账号BJ','<MD5(salt+"<-*Uk30^96eY*->"+明文)>','Standard',
        UNIX_TIMESTAMP(),'ops-verify',UNIX_TIMESTAMP(),'ops-verify');
INSERT INTO user_group_member (group_id,user_id) VALUES (2, LAST_INSERT_ID());
```

---

## 2026-08-27　EventHistoryGroupView = true + 全量归组验证

### 背景

上一轮实测证实两个漏洞：区域账号能看到全平台告警（54 条）和全部未归组机器（9 台）。
本轮一次性修掉这两个——前者是配置项，后者由人工完成资源归组。

### 变更内容

**① 配置**：`etc/o9e/config.toml.tpl` 的 `[Center]` 段新增

```toml
EventHistoryGroupView = true
```

注意必须放在 `[Center.AnonymousAccess]` 子表**之前** —— TOML 语义下，子表之后的键会归入子表。

**② 数据**：13 台 target 全部归组（人工在界面完成）

```
network   1 台   yjcollect2.13-10.185.2.13
BJ        1 台   YJ-IMC-1
TJ        1 台   YJ-IMC-2
YJ       10 台   COSLOS-116/124/147/18/188/IAM、ecs-wlxxjk、YJ-DHCP-1/2、YJ-IMC-3
ZJ        0 台
未归组    0 台
```

### 执行

```bash
# 本地改好后同步到服务器(服务器 git checkout 落后且有未提交改动,不走 git pull)
scp etc/o9e/config.toml.tpl cosl-6456:/tmp/config.toml.tpl.new
ssh cosl-6456 'cd /home/kylin/o9e-deploy \
  && cp etc/o9e/config.toml.tpl /tmp/config.toml.tpl.bak.$(date +%Y%m%d-%H%M%S) \
  && cp /tmp/config.toml.tpl.new etc/o9e/config.toml.tpl'
docker restart o9e     # 第 6 次轮询(约 18 秒)转 healthy
```

渲染确认：

```
EventHistoryGroupView = true
PromQuerier = false
AlertDetail = false
```

### 验证（临时账号 test-bj，仅 BJ 组 rw，该组含 1 台 YJ-IMC-1）

**修复项**

| 端点 | 修复前 | 修复后 | |
|---|---|---|---|
| `GET /targets` | 10 台 | **1 台（YJ-IMC-1）** | ✅ |
| `GET /alert-cur-events/list` | 54 条（资源清单组） | **0 条** | ✅ |

**未修复项（基线对照，确认仍漏，等代码改造）**

| 端点 | 结果 |
|---|---|
| `GET /cfgsync/instances` | 371 个实例 |
| `GET /screen/busi-group-status` | 7 个业务组 |
| `POST /datasource/list` | ES-1, VM-1 |
| `GET /proxy/1` `count(up)` | 61 |
| `GET /boards?bids=22,23,17` | 3 个别组看板 |

账号验证后已删除。

### 回滚方法

```bash
# 配置
ssh cosl-6456 'cd /home/kylin/o9e-deploy && cp /tmp/config.toml.tpl.bak.<时间戳> etc/o9e/config.toml.tpl'
docker restart o9e
# 归组(如需)
DELETE FROM target_busi_group WHERE target_ident IN (...);
```

### 遗留项

**targets 的增量问题未解决。** 本次只清了存量：13 台全部归组后，未归组集合为空，
`router_target.go:86` 的 `bgids = append(bgids, 0)` 匹配不到东西，所以不再泄露。

但**新机器首次上报时没有业务组记录**，又会落进"未归组"集合，对所有区域用户可见。
三种解法：

- **A 每次人工归组** —— 靠流程，迟早漏
- **B 去掉 `append(0)`** —— 一行改动，但新机器对区域用户完全不可见，违背上游"防止新机器丢失"的设计意图
- **C 建一个 `_未分配` 业务组，target 注册时自动归入，只授权管理员组** —— 推荐。
  未归组集合恒为空，新机器不丢失，区域用户看不到尚未确定归属的机器

> **更正（08-30）**：C 已落地，但组名是 **`_待分配`**（不是 `_未分配`）。
> 现场未归组机器数为 0。注意 `EnsureUnassignedBusiGroup` 是**按组名**找组的，
> 在 UI 里重命名这个组会静默再建一个重名组，老组里的机器就此滞留。

### 剩余改造项优先级

```
1. 数据源授权        /proxy + /datasource/list 一并解决    ~2.5 天
2. cfgsync 过滤      371 个实例全裸,面最大                  ~2 天
3. 大屏 bgids 过滤                                          ~1.5 天
4. boardGetsByBids 补权限                                   ~0.5 天
5. target 增量兜底(方案 C)                                  ~0.5 天
```

> **更正（08-30）**：这 5 项**已全部完成**。另外 08-30 的全量审计又挖出 12 个
> 同类越权（`bgrw()` 只锁 URL 的 `:id`、不看 body 里的 `ids[]`），
> 含一个零判权的 `POST /alert-cur-events/card/details`，已一并修完。
> 见本文件 08-30 条目第二节。

---

## 2026-08-27　告警规则归属区域业务组

### 背景

上一轮把 `EventHistoryGroupView` 打开后，区域账号看到 0 条告警。**这不是隔离做对了**——
是区域用户对告警所在的业务组没有权限。结果看着一样，原因完全不同。

根因：告警事件的业务组**来自规则所在的组，不是被监控对象的归属**。
`models/alert_rule.go:1268`：

```go
event.GroupId = ar.GroupId
```

当时 22 条规则全挂在「资源清单」组（该组 0 台机器、只授权管理员组），
而被监控的 371 个设备归 `YJ`。**规则和它监控的对象不在同一个业务组**，
导致区域用户能看到自己的设备，却看不到这些设备的任何告警。

另一个佐证：54 条告警的 `target_ident` 全是 snmp 设备 IP（10.185.103.x / 10.185.240.x），
这些 IP 根本不在 `target` 表里，所以没有业务组——这也解释了 n9e 日志里那批
`fill event target error, ident: 10.185.252.x doesn't exist in cache`。

### 变更前调研

**22 条规则的 PromQL 全是全局的，没有区域维度：**

```
net-icmp-down      snmp_icmp_up == 0
net-port-down      snmp_interface_status_ifOperStatus == 2 and on(...)
机房温度过高        room_temperature{site!=""} > 35
UPS负载过高         ups_output_load_percent{site!=""} > 95
alert-1            cpu_usage_active > 99
```

`site` 标签的值是具体机房名（`vip汇聚`、`机关227`、`科技园A座1层大屏操作室`…），
是楼栋/房间级别，**不是区域维度**。

**但指标上已有可用的区域代理 —— `ident` 标签：**

```
snmp_icmp_up{ ..., ident="yjcollect2.13-10.185.2.13", area="燕郊", location="汇聚机房" }
room_temperature{ ..., ident="yjcollect2.13-10.185.2.13", site="vip汇聚" }
```

`ident` 是采集机身份，由 categraf 全局配置提供。而按设计「区域 = 采集机」，
所以在打 `region` 标签之前，`ident` 就是现成的区域代理。

**当前所有数据都来自同一台采集机 `yjcollect2.13`，它归 `YJ` 组** ——
因此这批规则整体归 YJ 即可，无需改任何 PromQL。

### 例外：一条规则跨区域

`alert-1`（`cpu_usage_active > 99`）是唯一的主机类规则。实测
`count(cpu_usage_active) by (ident)` 覆盖 `YJ-IMC-1`(BJ组)、`YJ-IMC-2`(TJ组)
及 YJ 组的机器，**跨三个区域**。

保持在「资源清单」组不动。理由：BJ/TJ 当前各 1 台是实测样本，正式区域划分未定，
等定了再决定是拆成多份还是留总部统管。

### 变更内容

```sql
UPDATE alert_rule SET group_id = 6 WHERE group_id = 2 AND id <> 1;        -- 21 条
UPDATE alert_cur_event e JOIN alert_rule r ON r.id = e.rule_id            -- 59 条存量事件
  SET e.group_id = r.group_id WHERE e.group_id <> r.group_id;
```

结果：

```
变更前   group_id=2  22 条规则
变更后   group_id=2   1 条(alert-1)
         group_id=6  21 条
当前告警 group_id=6  59 条
```

### 验证（临时账号 test-bj / test-yj，测后已删除）

```
账号       机器        告警         可见业务组   监控资源
test-bj    1 台        0 条         BJ           371 个   ← 仍漏
test-yj    11 台       55 条        YJ           371 个   ← 仍漏
```

**告警隔离已正确工作**：YJ 用户看到自己设备的 55 条告警，BJ 用户看到 0 条
（BJ 组确实没有网络设备）。59→55 是期间有告警恢复的正常波动。

监控资源两个账号都看到 371 个，符合预期——cfgsync 过滤尚未改造。

### 回滚方法

```sql
UPDATE alert_rule SET group_id = 2 WHERE group_id = 6;
UPDATE alert_cur_event e JOIN alert_rule r ON r.id = e.rule_id SET e.group_id = r.group_id;
```

### 遗留项

**① 拆采集机后规则要按区域复制。** 一条规则只能挂一个 `group_id`，
所以每个区域一套。届时 PromQL 加 `{region="R"}` 过滤。

**`region` 比 `ident` 更适合做这个过滤**：一个区域可能有多台采集机，
用 `ident` 得写 `{ident=~"a|b|c"}`，加机器就要改规则；用 `region` 则新采集机自动纳入。

> **更正（08-30）**：上面这段结论反了，最终走的是 ident。
> 反对 ident 的理由是「加机器就要改规则」——那只在**人手写死** regex 时成立。
> 实际实现是**查询时从 `target_busi_group` 现算** ident 集合，新采集机一进组就
> 自动纳入，规则本身不含 ident。这条反对意见因此不成立，而 region 标签那边的代价
> （改 13 台采集机、序列全断、历史不可见）是实打实的。详见 08-30 条目第一节。

**② `alert-1` 的归属待定**，取决于正式区域划分和主机的真实分布。

**③ 一个语义提醒**：区域用户看到的告警数量取决于「规则挂在哪个组」，
而不是「告警对象属于哪个区域」。若将来出现"A 区域的规则监控了 B 区域的设备"，
告警会归 A，隔离就错位了。规则的 PromQL 过滤范围必须和它所在的业务组一致——
这条没有任何机制强制，只能靠规范。

> **更正（08-30）**：③ 不只是「靠规范」的问题，它是**指标层隔离的一个可达绕过**。
> `Standard` 角色持有 `/alert-rules/{add,put,del}`，区域用户能建一条查别的区域指标
> 的规则，再从告警内容里把数据读出来。求值时没有用户上下文，注入不到那一层。
> 处置方案 A/B 见 `design-multi-region.md` §10。

---

## 2026-08-28　数据源授权列迁移（先于代码部署）

### 背景

数据源授权改造（n9e commit `bf219f1a`）新增 `datasource.busi_group_ids` 列。
该列由 n9e 启动时的 `AutoMigrate` 自动创建，但**如果等代码部署时才建列，
会出现一个白屏窗口**：

```
新版启动 → AutoMigrate 建列(全 NULL) → 按「未授权 = 仅 admin」规则,
所有区域用户瞬间查不到任何指标 → 直到 UPDATE 执行完才恢复
```

故先于部署手工加列并赋值。旧版二进制不认识这一列，加了完全无感。

### 变更内容

```sql
ALTER TABLE datasource
  ADD COLUMN busi_group_ids varchar(1024) NULL
  COMMENT "authorized busi group ids as json array, empty means admin only";

UPDATE datasource SET busi_group_ids = "[6]" WHERE id = 1;   -- VM-1 → YJ
-- ES-1 保持 NULL = 仅 admin
```

列定义与 `models/migrate/migrate.go` 的 `Datasource.BusiGroupIds` 逐字一致，
新版启动时 `AutoMigrate` 认为列已存在，是 no-op。

**授权依据**：当前 371 个监控实例全部由 `yjcollect2.13-10.185.2.13` 采集，
该机归 `YJ`（id=6），所以 VM-1 里的数据都属于 YJ。将来按区域拆 VM 时，
每个新数据源关联对应区域组；总部汇聚 VM 留 NULL 即自动私有。

### 变更后验证

```
Field           Type            Null  Default
busi_group_ids  varchar(1024)   YES   NULL

id  name  plugin_type    busi_group_ids
 1  VM-1  prometheus     [6]
 2  ES-1  elasticsearch  (NULL = 仅 admin)
```

现网未受影响：`count(up)` = 61，告警引擎心跳正常（00:35:26），
`docker logs o9e` 中涉及新列的错误 **0 条**。

### 回滚方法

```sql
ALTER TABLE datasource DROP COLUMN busi_group_ids;
```

注意：回滚列之后必须同时回滚代码，否则新版 `AutoMigrate` 会再把列建回来（全 NULL），
反而造成区域用户全部查不到指标。

### 遗留项

**代码部署后需验证**（临时账号法，见前文）：

| 检查项 | test-yj | test-bj |
|---|---|---|
| `POST /datasource/list` | 仅 VM-1 | 空 |
| `GET /proxy/1/api/v1/query?query=count(up)` | 200 | **403**（此前 200/61） |
| `GET /proxy/2/*`（ES-1） | 403 | 403 |
| `GET /cfgsync/instances` | 371 | **0**（此前两者都是 371） |

回归项：admin 的看板、即时查询、22 条告警规则求值正常；`count(up)` 在 admin 下仍为 61。

**一个待观察点**：`busi_group_ids` 为 NULL 时 GORM 的 json serializer 走
「dbValue 为 nil → 零值」分支，是安全的；但若有任何路径写入空字符串 `''`，
`json.Unmarshal([]byte(""))` 会报错。`models/` 下已有 7 处同样的 `serializer:json`
用法在生产跑着（`alert_rule.NotifyRuleIds` 等），风险很低，部署后留意日志即可。

---

## 2026-08-28　数据源授权 + cfgsync 隔离部署验证

### 部署

n9e `feat/cfgsync-mvp` 推送触发 Jenkins 构建，容器于 `2026-08-28T00:58:18Z` 起新镜像。
`AutoMigrate` 对 `busi_group_ids` 无报错（列已由前一条迁移建好，是 no-op），
列值保持 `VM-1 → [6]`、`ES-1 → NULL`。

### 验证（临时账号 test-yj / test-bj，测后已删除，残留检查 0）

| 检查项 | test-yj (YJ 组) | test-bj (BJ 组) |
|---|---|---|
| `POST /datasource/list` | `["VM-1"]` | `[]` |
| `GET /datasource/brief` | `["VM-1"]` | `[]` |
| `GET /proxy/1` (VM-1) | **200** | **403** |
| `GET /proxy/2` (ES-1) | **403** | **403** |
| `POST /query-instant-batch` ds=2 | **403** | **403** |
| `GET /cfgsync/instances` | 371 | **0** |
| `GET /targets` | 11 台 | 1 台 |
| `GET /alert-cur-events/list` | 55 条 | 0 条 |
| `GET /busi-groups` | `["YJ"]` | `["BJ"]` |

对比改造前：`test-bj` 的 `proxy/1 count(up)` 从 **200/61** 变为 **403**，
`cfgsync/instances` 从 **371** 变为 **0**，`datasource/list` 从全部可见变为空。

`test-yj` 能查 VM-1 但查不了 ES-1（后者 NULL = 仅 admin），
说明授权是**按数据源逐个生效**的，不是"有权限就全放开"。

### 回归

```
告警引擎心跳     三行均刷新至 09:00:21
指标写入新鲜度   0.32 秒
当前告警         57 条,全部 group_id=6
```

### 过程中发现并修复:告警规则缓存陈旧

部署后一度出现「规则在 group 6,但事件的 group_id 是 2」的不一致。按时间切分后清楚：

```
事件组 6   49 条   最新 09:01:05   ← 重启后新产生,正确
事件组 2    6 条   最新 08:57:45   ← 重启前残留
```

**根因**：2026-08-27 那次直接 `UPDATE alert_rule SET group_id` 改库时**没有同时
更新 `update_at`**。告警规则缓存和数据源缓存一样有 stat 门（count + max(update_at)），
运行中的引擎因此一直用着 `group_id=2` 的旧规则，新产生的事件继续打成 2。
本次部署重启后缓存重载，事件立刻转为 6。

已把残留的 6 条同步过来，现在 57 条全部在 group 6。

**这是一条通用教训**：n9e 的 memsto 缓存普遍用「count + max(update_at)」判断是否重载，
**任何绕过 API 直接改库的操作，都必须同时 touch 该表的 `update_at`，否则改动要等到
下次重启才生效**。数据源授权当初选 JSON 列而不是关联表，正是为了规避这一点；
告警规则这次踩到了。

后续所有直接改库的运维操作，SQL 里都应带上：

```sql
UPDATE alert_rule SET group_id = ?, update_at = UNIX_TIMESTAMP() WHERE ...;
```

### 遗留项

- **前端「授权业务组」字段尚未人工验证** —— 后端行为已确认，但管理员在数据源
  编辑页能否正常选择和保存，需要在界面上实际点一遍。
- `busi_group_ids` 为 NULL 走 GORM json serializer 的零值分支，已在生产验证无异常。

---

## 2026-08-28　大屏 / 看板 / 告警详情 / 业务服务隔离部署验证

### 部署

```
镜像       fuqiangleon/o9e:latest  c066c3c47e77
容器启动   2026-08-28 17:19:10
代码       feat/cfgsync-mvp @ 2418f870（4 个 commit：0066bc4a / 7c5d9961 / abdc0b41 / 2418f870）
```

**部署确认踩了个坑**：第一次检查时容器还是 16 小时前的镜像（`e0a53cdae773`，
启动于 00:58），行为侧 `/event-notify-records/1` 未登录仍返回 200。
**判断代码是否真上线，看容器启动时间比看 commit 时间可靠** ——
推送成功不等于部署完成。重新部署后 `c066c3c47e77` 才带上本批改动。

### 验证方法

沿用临时账号法，这次建三个（测后全删，残留检查 0）：

| 账号 | 角色 | 用户组 | 对应业务组 |
|---|---|---|---|
| `test-bj` | Standard | BJ(2) | BJ(4)，含 1 台机器 |
| `test-yj` | Standard | YJ(4) | YJ(6)，含 11 台机器 |
| `test-adm` | **Admin** | — | 全部（用于回归对照） |

密码同上次 `TestBJ@2026tmp`，salt 未变（`856bd2e1…`），hash 沿用
`e40c48e00c2e1a94a92715e08218d6dd`。

> 建 `test-adm` 而不是登录 `admin`，是为了不碰生产管理员口令；
> 回归对照必须有 admin 视角，否则只能证明"看得少了"，证明不了"该看的还在"。

### 结果 1：大屏收敛

`GET /screen/busi-group-status`

| | 改动前 | 现在 |
|---|---|---|
| test-bj | 7 个业务组（含 BJ/TJ/YJ/ZJ 全部） | **1 个（BJ）** |
| test-yj | 7 个 | **1 个（YJ）** |
| test-adm | 7 个 | 6 个（全部，正确） |

`GET /screen/overview`

| 指标 | test-bj | test-yj | test-adm |
|---|---|---|---|
| 机器 total | 1 | 11 | **13** |
| 告警 p1 | 0 | 53 | 53 |
| 告警 rule_total | 0 | 21 | **22** |
| 数据源 total | 0 | 1 | **2** |
| 业务组 total | 1 | 1 | **6** |
| 看板 total / public | 0 / 10 | 0 / 10 | **19** / 10 |
| **用户 total** | **0** | **0** | **5** |
| **event_pipeline** | **全 0** | **全 0** | 全 0（表本就空） |
| no_busi_group | 0 | 0 | 0 |

用户 / 用户组 / 角色 / 管道 / 通知这几项对非 admin 直接返回 0 ——
`users`、`event_pipeline`、`notification_record` 三张表**没有任何业务组维度**，
过滤不了，只能整块隐藏。admin 侧数值完整，说明没误伤全局视图。

### 结果 2：看板批量读

`GET /boards?bids=`（board 10~23 属 Default Busi Group 且 `public=0`，
board 1~13 属"资源清单"且 `public=1`）

| 请求 | test-bj | test-yj | test-adm |
|---|---|---|---|
| `bids=22,23,17`（别组 private） | **0**（原 3 个） | **0** | 3 |
| `bids=1,2`（public） | 2 | 2 | 2 |

public 看板仍可读 —— 确认没有过度收紧。

### 结果 3：三个原本裸奔的路由

事件 171805 属 group 6(YJ)；规则 3 属 group 6，规则 1 属 group 2(资源清单)。

| 端点 | 无 token | test-bj | test-yj | test-adm |
|---|---|---|---|---|
| `/event-notify-records/171805` | **401**（原 200） | **403** | 200 | 200 |
| `/alert-eval-detail/3` (group 6) | 401 | **403** | 200 | 200 |
| `/alert-eval-detail/1` (group 2) | 401 | **403** | **403** | 200 |
| `/event-detail/<32位hex>` | **401** | 500* | 500* | 500* |

\* 500 是 hash 不存在导致 `getEventLogs` 报错，属原有行为，非本次引入。
该接口按设计只要求登录、不做业务组判定（按 hash 查日志拿不到事件 id）。

顺带确认上游原有的两个（`AnonymousAccess.AlertDetail=false` 后生效）：

| `/alert-cur-event/171805` | 401 | **403** | 200 | 200 |
| `/alert-his-event/146976` | 401 | **403** | **403** | 200 |

> 排查中一度以为 `/alert-cur-events/171805`（复数）无鉴权全返回 200，
> 实际是**路径写错**落到了前端 SPA fallback，返回的是 HTML。
> 真实路由是单数 `/alert-cur-event/:eid`。测 API 时若拿到 HTML，先怀疑路径。

### 结果 4：新机器自动进「待分配」组（唯一改了写路径的改动）

**触发路径要点**：`GetHeartbeatFromMetric` 默认 false（现场未配置），
所以**推指标不会注册机器**，最初用 `/opentsdb/put` 探测毫无反应。
真实注册路径是 `POST /v1/n9e/heartbeat`（categraf agent 心跳），
它调 `identSet.MSet` → `UpdateTargets` → `BindTargetsToUnassigned`。

用一台假机器实测：

```bash
curl -X POST http://127.0.0.1:17000/v1/n9e/heartbeat -H 'Content-Type: application/json' \
  -d '{"hostname":"TEST-UNASSIGNED-PROBE","host_ip":"10.99.99.254","unixtime":<ms>}'
```

注册前基线：无 `_待分配` 业务组，未归组机器 **0** 台。

心跳后 6 秒：

```
busi_group          id=8  name=_待分配  create_by=system      ← 自动创建
target              TEST-UNASSIGNED-PROBE                     ← 注册成功
target_busi_group   TEST-UNASSIGNED-PROBE → 8                 ← 自动归组
busi_group_member   业务组 8 关联用户组数 = 0                 ← 只有 admin 可见
```

可见性：

| | test-bj | test-yj | test-adm |
|---|---|---|---|
| `GET /targets` total | 1 | 11 | **14**（13+探针） |
| 列表含 PROBE | 否 | 否 | **是** |

探针机器测后已删除（`target` + `target_busi_group` 各 1 行），
**`_待分配` 业务组 id=8 保留** —— 这是正常产物，后续新机器都会落进来。

### 结果 5：业务服务（biz_systems）

表原为空，造两条样本验证（测后已删）：`probe-yj`(group 6)、`probe-orphan`(group 0)。

`group_id` 列迁移成功：`bigint NOT NULL DEFAULT 0`，带索引。

| 操作 | test-bj | test-yj | test-adm |
|---|---|---|---|
| `GET /biz-systems` | `[]` | `[probe-yj]` | `[probe-yj, probe-orphan]` |
| `PUT /biz-systems/1`（group 6） | **403** | 200 | 200 |
| `PUT /biz-systems/2`（group 0，未归组） | **403** | **403** | 200 |
| `POST` 不带 group_id | — | **400** `group_id is required` | — |
| `POST` 到别人组（group_id=4） | — | **403** | — |

未归组（`group_id=0`）只有 admin 可见可改 —— 与数据源同语义，
与 target 的「未归组对所有人可见」**相反**，这是有意的。

### 回归（确认没改坏）

| 检查 | 结果 |
|---|---|
| 数据源列表 | bj `[]` / yj `[VM-1]` / admin `[ES-1, VM-1]` |
| `/proxy/1` `count(up)` | bj **403** / yj 200 值 61 / admin 200 值 61 |
| `/cfgsync/instances` | bj 0 / yj 371 / admin 371 |
| 告警引擎心跳 | 三行均刷新至 19:15:25 |
| 当前告警 | 57 条，全部 group_id=6 |
| 指标写入新鲜度 | 0.20 秒 |

### 回滚方法

回滚镜像到 `e0a53cdae773` 即可（本批无数据库结构变更之外的破坏性操作）。
`biz_systems.group_id` 列保留无害（默认 0）；`_待分配` 业务组删掉即可，
删后新机器退回"未归组 = 对所有登录用户可见"的旧行为。

### 遗留项

- **前端「授权业务组」字段仍未人工验证** —— 后端已两轮确认，界面未点过。
  这是唯一一个跨了两次部署都没消掉的遗留项。
- `_待分配` 组目前只在有新机器时才被创建（惰性）。已建出 id=8，后续不再触发建组逻辑。
- 大屏的用户/管道/通知三项对非 admin 直接归零，是**隐藏**而非过滤。
  若将来区域需要看自己的通知记录，得先给 `notification_record` 加业务组维度。

---

## 2026-08-28　cfgsync 绑定权限补测

### 背景

上一轮部署验证只测了 `/cfgsync/instances` 的列表过滤，**主机下拉和绑定接口没单独验**。
这两个是「区域用户绑定时只能看到自己的 host」的直接实现，补测。

临时账号同前（`test-bj` / `test-yj` / `test-adm`），测后已删，残留检查 0。

### 基线

| 业务组 | 机器 | 其中 cfgsync 采集机 |
|---|---|---|
| BJ(4) | 1 台 `YJ-IMC-1` | **0**（该机不是采集机） |
| YJ(6) | 11 台 | 8 台在 `cfgsync_host_token` |

绑定分布：`yjcollect2.13` 370 条、`COSLOS-147` 1 条、`ecs-wlxxjk…215` 1 条，共 372。

### 结果：主机下拉

`GET /cfgsync/hosts`

| test-bj | test-yj | test-adm |
|---|---|---|
| **0 台** | 8 台 | 8 台 |

test-bj 为空是正确的 —— BJ 组唯一那台机器不是采集机。

### 结果：越权绑定/解绑

test-bj 打 YJ 的采集机 `yjcollect2.13-10.185.2.13`、实例 3(`docker-hub`)：

```
POST   /cfgsync/bindings → 403  无权访问采集机 yjcollect2.13-10.185.2.13
DELETE /cfgsync/bindings → 403  无权访问采集机 yjcollect2.13-10.185.2.13
```

`cfgsyncCheckBindScope` 是**双向**校验（主机可见 + 实例有权）。少任何一边都是洞：
只校验主机 → 能把别区域的实例绑到自己机器上读它的配置（含 secret_refs）；
只校验实例 → 能把自己的实例绑到别区域采集机上污染对方采集配置。

### 结果：越权读

| 端点 | bj | yj | admin |
|---|---|---|---|
| `/cfgsync/bindings/host/<YJ采集机>` | **403** | 200 | 200 |
| `/cfgsync/bindings/instance/3` | **403** | 200 | 200 |
| `/cfgsync/instances/3` | **403** | 200 | 200 |
| `/cfgsync/host-state/<YJ采集机>` | **403** | 200 | 200 |
| `/cfgsync/preview/host/<YJ采集机>` | **403** | 200 | 200 |
| `/cfgsync/main-config/categraf` | **403** | **403** | 200 |
| `/cfgsync/secrets` | **403** | **403** | 200 |
| `/cfgsync/host-states`（列表） | 200 / **0 条** | 200 / 8 条 | 200 / 8 条 |
| `/cfgsync/instances`（列表） | 200 / **0 条** | 200 / 371 条 | 200 / 371 条 |

列表类接口返回 200 但内容为空，详情类直接 403 —— 符合设计。

### 过程中的操作失误：误建空的主配置模板

测 `PUT /cfgsync/main-config/categraf` 时，为了凑齐三列对照，**对 admin 也发了空 body 的
PUT**。这是不该做的 —— 写接口的 admin 成功路径不属于权限验证范围。

结果在 `cfgsync_main_config_template` 建出一行 `agent_type=categraf, content=''`。

**实际影响为零**，两个独立原因：

1. 该行 `create_at == update_at == 20:48:28`（即操作时刻）、`revision=1` ——
   是**新建**而非覆盖，表原本 0 行，没有内容被破坏。
2. `bundle.go:112` 注释明确：**主配置 config.toml 尚未接入下发链路**（留 Phase 2.5）。
   全仓库只有 router 的 GET/PUT 引用该表，bundle 生成不读它。托管机上的
   `/run/categraf/conf/config.toml` 是 install.sh 放的静态文件，与该表无关。

已 `DELETE FROM cfgsync_main_config_template WHERE update_by='test-adm'`，表回到 0 行。
复核：绑定总数仍 372、无孤儿成员、无残留账号。

### 由此暴露的一个真实风险（已修）

`PUT /main-config/:agent_type` **不校验 content 非空**，空 body 会静默写入空模板。
现在无害，但 **Phase 2.5 把主配置接进下发链路之后，这一个请求会把所有 categraf 的
主配置清空**，且该表只存最新版（`agent_type` 唯一键）、无历史，**回滚无源**。

修法：保存前用渲染器现成的 `render.Compile()` 编译一遍（`router_cfgsync.go`
`cfgsyncMainConfigPut`，`ginx.BindJSON` 之后）。不自己写校验，是为了让保存时的判据和
渲染时**完全一致**，不会出现"存得进去、下发时才炸"。一次挡掉三类：

| 输入 | 结果 |
|---|---|
| 空内容 | 400 `render.tmpl 内容为空` |
| 模板语法错（未闭合引号等） | 400 `template: ...: unterminated quoted string` |
| 沙箱白名单外的函数 | 400 `function "xxx" not defined` |
| 正常 toml / 带 `{{ .ident }}` 的 toml | 通过 |

未做**历史版本表**：那是跟 Phase 2.5 下发接入一起设计更合适的功能，现在单独加会
先有一张没人读的表。

### 测试方法的教训

**测写接口时，只测「应当被拒」的路径，不测 admin 的成功路径。**
成功路径会真的改生产数据，而权限验证根本不需要它 —— 403 与否才是被测对象。
本次是空 body 撞上"不存在就创建"的逻辑，恰好落在无害的表上，是运气不是设计。

---

## 2026-08-28　机器归属清理 + 指标层区域隔离方案确定

### 清理：YJ-IMC-1 / YJ-IMC-2 移回 YJ 组

`target_busi_group.update_at` 显示这两条绑定建于 **2026-08-27 20:58:06**，与 YJ-IMC-3
（同一秒、归 YJ）是同一批操作 —— 即隔离改造当天为了验证「BJ 用户只看得到 BJ 机器」
而人为把三台同批机器（10.185.2.1/2/3，windows，同 agent 版本）拆到三个组。
不是真实业务归属。

```sql
update target_busi_group set group_id=6, update_at=unix_timestamp()
where target_ident in ('YJ-IMC-1','YJ-IMC-2') and group_id in (4,5);
-- 回滚：group_id 分别改回 4 / 5
```

改后各组机器数：YJ 13、BJ/TJ/ZJ/资源清单/Default/_待分配 均 0。

告警影响为零：n9e 的 `alert_rule.group_id` 是「规则归属哪个业务组」，目标由 PromQL
决定，与机器归属无关。

**顺带发现**：VM 里还有 `TEST-UNASSIGNED-PROBE` 的序列（8/27 测 `_待分配` 自动归组
用的探针）。target 行已删，时序数据等 retention 自然过期，不处理。

### 由此暴露的问题：两层隔离的粒度不一致

隔离实际上是两套独立过滤：

| 层 | 依据 | 结果 |
|---|---|---|
| 资源列表层 | `target_busi_group` | BJ 用户能看到归在 BJ 组的机器 |
| 指标数据层 | `datasource.busi_group_ids` | VM-1 只授权 `[6]`(YJ)，BJ 用户查它 403 |

清理前的 `YJ-IMC-1` 就是活样本：BJ 用户**看得见机器、所有图都是空的**。

更根本的是 **VM-1 是全量库，数据源授权粒度只到「整个数据源」** ——
授权给 YJ 等于 YJ 能查全平台指标。今天恰好无害（3 台采集机全在 YJ，库里 100% 是
YJ 数据，「YJ 看全部」== 「YJ 看 YJ」），**但接入第二个区域的那一刻就破**。

### 方案：categraf 打 region 标签 + 查询侧注入

> ⚠️ **本节的「方案」已于 2026-08-30 作废，别照着做。**
> region 标签这条路在上线前预检里被判定不划算（要改 13 台采集机跨两套部署方式、
> 序列 identity 全变、**区域用户永久看不到切换点之前的历史**、漏配一台静默丢数据），
> 已改为 **按用户可见的 ident 集合注入**：`MyBusiGroupIds` → `target_busi_group`
> → ident 列表 → `ident=~"a|b|…"`，采集侧零改动。见本文件 2026-08-30 条目第一节。
>
> **下面「调研确认的三个事实」仍然有效**（100% 数据经过 categraf、`area` 标签不可用、
> 注入必须用 metricsql 而非 promql parser），只有「设计」往下的部分作废。
>
> 另有一处语义**反转**了：本节设计的是「先剔掉用户写的 region filter 再注入」，
> 搬到 ident 上必须改成**纯追加**——用户写 `up{ident="host-a"}` 想看一台机器，
> 剔掉后会被放大成他名下的全部机器，那是错误结果，不是泄露。

调研确认的三个事实：

1. **VM 里 100% 数据都经过 categraf** —— deepflow 指标在 ClickHouse 不在 VM
   （`{auto_service_id!=""}` 空结果）；k8s 联邦指标带 `ident=COSLOS-147`，
   走的是 categraf 的 prometheus 插件。**没有绕过 global labels 的旁路。**
2. **现成的 `area` 标签不能用** —— 只覆盖 20 个 `snmp_*` 指标（网络设备），
   值域是 泉州/燕郊/舟山，与业务组不对应。`agent_host` 同样只在 snmp 上。
3. n9e 已依赖 `prometheus/promql/parser` 和 `VictoriaMetrics/metricsql`
   （`pkg/promql/parser.go`），但现有代码只**读** selector，没有改写先例。
   后端是 VM，注入应该用 `metricsql`，否则用户手写的 MetricsQL 扩展语法会解析失败。

设计：

- **采集侧**：categraf `[global.labels]` 加 `region = "YJ"`。
  短期手工改 3 台采集机；长期走 cfgsync 主配置模板 `region = "{{ .region }}"`，
  渲染时按 host 所属业务组注入 —— 这正是主配置模板存在的意义，Phase 2.5 接上即自动。
- **存储**：`busi_group` 加 `region varchar(64)` 可空。区域组填 YJ/BJ/TJ/ZJ，
  用途组（`资源清单` / `_待分配`）留空。**不直接用业务组名** —— 组名可改可增，
  而 region 一旦写进时序库就不可改，两者生命周期不同必须解耦。
- **查询侧**：解析 → 遍历 AST 给每个 selector 追加 `region=~"YJ|BJ"` → 重新序列化。
  admin 不注入；用户 region 集合为空直接拒。
- **历史数据**：接受断层。改造前的数据区域用户查不到，等 retention 过期。
  不开 `region=~"YJ|"` 的空值后门 —— 那是个会持续到 retention 结束的真洞。
  代价仅为 YJ 用户看不到改造前的历史，admin 不受影响。

> **更正（08-30）**：最后这条**做了相反的决定，必须知道。**
> ident 方案下无 ident 的序列（DeepFlow 全部如此）注入后会整体消失，
> 所以加了 `Center.RegionIsolation.AllowIdentlessSeries`，开启时往 ident 集合
> 追加一个空串，拼出 `ident=~"host-a|"` —— **正是这里说的空值后门**。
> 区别在于：region 版开它是为了保历史（洞会持续到 retention 结束），
> ident 版开它是为了保 DeepFlow 页面（现场必须开，否则那些页面对区域用户全空）。
> 它是**全放行**不是按区域放行，**接入第二个区域前必须改回 false**。
> 「历史断层」这条代价本身则已消失——ident 方案不改数据，历史照常可见。

**易漏点**：`dsProxy` 是通用代理，还转发 `/api/v1/label/*/values`、`/api/v1/series`、
`/api/v1/labels`。这些必须同样注入 `match[]`，否则区域用户能直接枚举出别的区域的
机器名 —— 漏了等于前面全白做。

---

## 2026-08-30　跨模块业务组隔离审计 + 指标层机制改为 ident 注入

### 一、更正 8/28 的指标层方案：region 标签 → ident 集合注入

**8/28 记的 region 方案已废弃**，不要照那条执行。上线前把代价逐条摊开后判定不划算：

- 要逐台改 13 台采集机（8 台走 cfgsync + 3 台 windows 手工 + 2 台已死），跨两套部署方式
- 加 global label 会改变**所有**时间序列的 identity，VM 当成全新序列：
  存储短期近似翻倍、所有 `rate()` 在切换点断一次
- 开关打开后区域用户**永久看不到切换点之前的历史**
- 漏配一台 = 那台的指标对区域用户直接消失，且不报错

改成 `MyBusiGroupIds` → `target_busi_group` → 该用户可见的机器 ident 列表 →
注入 `ident=~"host-a|host-b|…"`。上面四条代价全部归零：数据侧零改动、零序列变更、
历史可见、无漏配面。且与资源列表层用的是**同一张表**，不会再出现 8/28 记的
「看得见机器、图是空的」。

两处语义反转，与 region 版不同，别搞混：

1. **纯追加，不剔用户自写的 filter。** region 版是「先剔掉用户写的 region filter
   再注入」。搬到 ident 上必须改掉：用户写 `up{ident="host-a"}` 想看一台机器，
   剔掉后会被放大成他名下的**全部**机器 —— 那是错误结果，不是泄露。
   纯追加后两个 filter 天然 AND 取交集。
2. **`AllowIdentlessSeries` 是给 DeepFlow 留的临时门。** DeepFlow 的序列不带 ident，
   注入后对区域用户全部消失。该开关往 ident 集合里追加一个空串，拼出
   `ident=~"host-a|"`，PromQL 里标签缺失 == 标签值为空串，于是无 ident 的序列被放行。
   这是**全放行**不是按区域放行，**接第二个区域前必须改回 false**。

代价是粒度天花板：**`ident` 是采集者不是被监控资源**，SNMP / k8s 联邦 / 代理采集
出来的序列全部塌到那台采集机的 ident 上。部署约束因此变成一条：
**每个区域用自己的采集机，沿组织边界最细粒度拆。**

配置项名 `Center.RegionIsolation` 与文件名 `router_region.go` 故意保留 —— 对外的
功能名还是「区域隔离」，且改名会让现场 config.toml 里已有的配置段**静默失效**
（TOML 反序列化不认的段直接丢，不报错）。

### 二、跨模块越权审计与修复

审计范围是业务组维度的全部资源：告警规则、记录规则、屏蔽、订阅、看板、自愈模板、
机器、cfgsync。两批修复**均已提交，尚未 push，因此尚未部署、行为验证一次未跑**。

反复出现的是同两个缺陷模式：

1. 列表 / 详情端点漏挂 `bgro()`
2. **`bgrw()` 只锁 URL 上的 `:id`，从不校验 body** —— 任何「路由 `:id` + body `ids[]`」
   的端点都可绕过：在自己有权限的组下塞一个别组的 id 即可

`5504860d` 补的六处读写：`/target/list` 追加业务组范围（5 条前端路径在用，
是功能缺口不只是 API 洞）、`targetDel` 补 ident 校验、三条 `/busi-group/:id/` 路由
补 `bgro()`/`bgrw()`、告警规则与记录规则与订阅的详情按记录自身 `group_id` 判权。

`0d8b3b5f` 按 `idsForm`（body 带 `ids[]`）模式全量扫了 19 处，补完剩余的：

| 端点 | 问题 |
|---|---|
| `POST /alert-cur-events/card/details` | **本轮最严重**。路由上只有 `auth()`、连 `user()` 都没有，body 给一批 event id 就返回完整事件（tags / annotations / 规则名）。event id 自增可枚举。同组的 `/card` 列表接口本就有 `GetBusinessGroupIds` 收窄，只有它漏了 |
| `GET /trace-logs/:traceid` | 与 `eventDetailPage` 同类页面却无任何兜底 |
| `POST /busi-groups/alert-rules/clones` | 只校验目标组，克隆别组规则即可读其数据源与查询语句 |
| `alertMuteDel` / `alertSubscribeDel` | 删除不带 bgid 过滤 |
| `alertMutePutFields` / `alertRulePutFields` / `recordingRulePutFields` | 批量改字段不校验归属 |
| `alertSubscribePut` | 拿 body 里的 group_id 判权（调用方可控） |
| `taskTplGet/Put/Del/BindTags/UnbindTags` | 五处均不校验归属 |
| `GET /busi-group/:id/alert-mute/:amid` | 缺 nil 检查，500 而非 404 |
| `PUT /recording-rule/:rrid` | 写操作挂在读权限点 `/recording-rules` 上 |

新增 `bgidMatchCheck` 统一这类端点的判据（记录的 `group_id` 必须等于 URL 的 `:id`）。
判据取「必须相等」而非「有权限即可」，与 `AlertRuleDels` 里既有的
`param(busiGroupId) for protect` 口径一致；前端批量操作本就要先选中具体业务组，
收严不影响正常路径。

model 层 `AlertMuteDel` / `AlertSubscribeDel` 加可选 `bgid` 参数，照 `AlertRuleDels`
的现成签名，两者各只有一个调用方，无波及面。

**扫描结论**：端点级遗漏基本清了，剩下的是设计层面的缺口（见第四节）。
`alert/` 与 `pushgw/` 两个目录未扫 —— 它们是后台任务、没有用户上下文，
理论上不属于「用户越权」范畴，但该假设未验证。

### 三、现场核实的事实（只读查询）

```sql
select id,name,plugin_type,busi_group_ids from datasource;
select operation from role_operation where role_name='Standard' and operation like '%alert-rules%';
select id,name from busi_group;  select id,group_id,name,public from board;
```

- **数据源只有两个**：`VM-1`(prometheus，授权 `[6]`=YJ)、`ES-1`(elasticsearch，
  `busi_group_ids` 为 **NULL**)。**没有 Jaeger / VictoriaLogs 数据源。**
- `CanAccessDatasource` 里 `len(BusiGroupIds)==0 → return false`，
  即**空授权是代码强制拒绝**，不是靠配置习惯。ES-1 当前对所有非 admin 是 403。
  ES 的真实风险因此不是「现在敞开」，而是「哪天给它授权了某个业务组，
  那个组就能看 ES 全量」—— ES 没有查询注入这一层。
- **Standard 角色持有 `/alert-rules/add`、`/alert-rules/put`、`/alert-rules/del`。**
  区域用户能自建告警规则。这使第四节第一条从理论缺口变成可达路径。
- 业务组 7 个：`_待分配`(8)、BJ(4)、TJ(5)、YJ(6)、ZJ(7)、资源清单(2)、
  Default Busi Group(1)。
- 看板 20 个。组 2「资源清单」下 10 个 `public=1`，全是通用模板
  （主机 / MySQL / Oracle / Redis / Docker / 网络设备 / 机房动环等），
  **泄露面是「有哪些监控模板」，不含业务数据** —— 数据走 VM-1，只授权组 6。
  组 1 下 11 个 `public=0`。

### 四、已知缺口与处理决策

| 缺口 | 今天可利用 | 决策 |
|---|---|---|
| **告警规则的 PromQL 不注入**。求值在后台、无用户上下文，`isolationScope` 完全不参与。区域用户可建规则查别区域指标，从告警内容把数据读出来 | **是**（Standard 有 add/put/del） | **待定，见下** |
| `AllowIdentlessSeries=true` 是全放行不是按区域放行 | 否（单区域） | 接第二区域前必须改 false，写进上线清单 |
| `ident` 是采集者不是被监控资源 | 否 | 靠部署约束缓解：每区域独立采集机 |
| ES 无查询级隔离 | 否（空授权=拒绝） | 加启动守卫：非 prometheus 数据源被授权业务组时打 WARNING |
| public 看板绕过业务组 | 是，但泄露面是通用模板 | 不改代码。组 2 已盘点，10 个模板看板确认可公开 |
| 跨区域业务组是可见性通道（用户加进两个区域的组即可同时看两边） | 是 | 功能不是漏洞，文档化 |
| 注入是改写查询不是物理隔离，VM 里仍是全量库 | — | 接受 |
| 重命名 `_待分配` 会静默建出重名组（自动归属按名字找） | 否 | 极低频运维事故，加 id 持久化不划算，接受 + 文档 |
| 未归组机器对区域用户可见（`/target/list` 与 `GET /targets` 均含未归组兜底） | 否（现场计数 0） | 保持现状。新机器由 `BindTargetsToUnassigned` 自动进 `_待分配`(admin-only)，「未归组」是该自动归属**失败**时的兜底异常态 |
| 接第二个 k8s 集群需 join key 加 cluster 前缀 | 否 | 越早做越便宜（画布越多越贵），属多集群议题不在本次范围 |
| `docker-hub` 实例名接第二区域时撞 `uk_instance_name` | 否 | 写进上线清单 |

**告警规则那条的两个选项**（需产品决策，未执行）：

- **A. 收权限** —— 把 `/alert-rules/{add,put,del}` 从 Standard 删掉只留 admin。
  一条 SQL、零代码、零回归。现场 22 条规则全由 admin 建，今天无人受影响。
  代价：区域用户不能自建告警规则。
- **B. 求值时注入** —— 在 `alert/eval/eval.go` 按 `rule.GroupId` 注入，复用现成的
  `pkg/promql/inject.go` 与 `IdentsByBusiGroupIds`。是正解（动态查，不像「保存时
  注入」那样随机器归属变化而过期），但求值点有 **4 处**（`eval.go` 315/441/648/1305）、
  是核心路径，且**有一个必须先定的语义**：业务组无机器时注入空集合会让规则恒不触发 ——
  现场规则 id=1 就在组 2（「资源清单」，非机器组），一注入即失效。

建议 A 现在做、B 等接第二区域且确实需要区域用户自建规则时再做：
用一条权限配置换掉一次核心路径改造，今天的收益完全相同。

### 五、待办

1. **5 个 commit 未 push**。push 会连带另一会话的 room-monitor 改动一起上生产，须先协调。
2. **行为验证一次未跑**。权限判断只有真实的非 admin 会话能测，代码还在本地。
   部署后建临时账号（Standard + 加入区域用户组）重跑 8/27 那张表，
   预期全部翻成 403 或空集；**只测「应当被拒」的路径，不测 admin 成功路径**；测后全删、残留检查 0。
   同时回归 admin 与区域用户的正常出数 —— `appendTargetBgScope` 改的是查询构造，值得实测。
3. `Center.RegionIsolation.Enable` 仍为 **false**，即**指标层隔离在生产上尚未生效**，
   今天真正起作用的只有资源列表层的业务组过滤。打开时现场需先设
   `AllowIdentlessSeries=true`，否则 DeepFlow 相关页面对区域用户全空。
4. 告警规则权限（第四节 A/B）待决策。
5. 测试账号 `alert` 与 admin 共享密码 hash，确认为测试账号，待删。

---

## 2026-08-31　隔离改造上线与部署核验

08-30 条目第五节的待办 1、2 在本次闭合。5 个 commit 已 push，Jenkins 构建镜像
（`fuqiangleon/o9e:latest`，08-30 23:41）、08-31 14:00 重建容器完成部署。

**push 前核实：这 5 个 commit 不含 room-monitor 文件**，无需跨会话协调。
08-30 待办 1 写的「会连带另一会话的改动」是凭记忆写的，不准确，以本条为准。

### 一、部署核验（只读，未改任何配置）

| 检查项 | 结果 | 判据 |
|---|---|---|
| 容器健康 | o9e / o9e-nginx / o9e-topo-studio 全部 Up，o9e `healthy` | `docker ps` |
| 版本已换 | 启动日志出现 `center/center.go:67` 的 `metric isolation is DISABLED` WARNING | 该行是本次改动新增，旧版本不会打 |
| **判权收严无误伤** | **403 = 0**（1 小时真实流量，417 个 200） | `docker logs o9e-nginx` 状态码分布 |
| 无崩溃 | **panic = 0**，`forbidden` 计数 0 | `docker logs o9e` |
| `RegionIsolation.Enable` | false，符合预期 | 上述 WARNING |
| UI 功能验证 | **通过** | 人工点击：告警规则批量删除／批量改字段／克隆、屏蔽与订阅规则的编辑与批量删除、自愈脚本编辑与绑标签 |

**403 = 0 且 UI 点击全部正常，是本次最想要的结果。**`bgidMatchCheck` 的判据是
「必须等于 URL 的 `:id`」而非「有权限即可」，比原逻辑严，最大的风险就是挡到正常路径；
现在正反两侧都验证过了。

一个诊断教训：部署窗口期查容器状态会看到 `created`，那是 Jenkins 重建容器的
20 秒瞬时态，不是故障。**隔 30 秒复查再下结论。**

### 二、顺带定位的存量故障：31 个 502

502 全部是拓扑画布的 DeepFlow 查询（`flow_metrics.application_map.1m`），
打到 `proxy/1`，集中成批出现（22 个在 14:27、9 个在 15:05）。

**根因：**

```
VM-1 数据源 http.timeout = 10000ms   (10 秒)
该查询在 VM 上实测耗时              = 23.5 秒
→ ResponseHeaderTimeout 触发
→ router_proxy.go:225 的 ReverseProxy ErrorHandler
→ 502(body 仅 44 字节，且不写日志，所以 nginx 与 o9e 两侧日志都查不到成因)
```

排除过程逐环收窄：nginx 无 `[error]` 行（不是 nginx→upstream 失败）→ o9e 无 panic
（不是本次改动）→ 从 o9e 容器内直连 `http://victoriametrics:8428` 跑同一条查询，
**返回 200、9937 字节、23.5 秒**（查询本身是对的，只是慢）。

**与本次部署无关，是存量性能问题。**

**更正 08-28 的一条事实认定：** 之前记「deepflow 指标在 ClickHouse 不在 VM」，
据此判断这批查询「打错了后端」。**错了。** `flow_metrics.application_map.1m` 的数据
确实在 VM 里，上面那条查询返回了真实结果（PostgreSQL / HTTP 协议、一批 `ip4_1` ClusterIP）。
08-28 那句结论的成立范围仅限当时用 `{auto_service_id!=""}` 探测的那组指标。

处置选项（均未执行）：

| | 做法 | 评价 |
|---|---|---|
| A | VM-1 timeout 10s → 60s | 一条 SQL 止血。但用户仍要干等 23 秒 |
| B | 前端降基数（缩窗口 / `topk` / 拆查询），改 `fe/src/services/deepflow.ts` | 治本 |
| C | VM 侧调优或加资源 | 最重，收益不确定 |

建议 A 止血 + B 跟进。

**与隔离的关联**：DeepFlow 序列**没有 `ident`**，打开 `RegionIsolation.Enable` 后
这些图会对区域用户直接变空 —— 这正是 `AllowIdentlessSeries` 存在的理由，
开关打开时必须同时设 true。

### 三、顺带核对的配置（与文档一致）

```
VM-1  plugin_type=prometheus  busi_group_ids=[6]     ← 授权给 YJ
ES-1  plugin_type=elasticsearch  busi_group_ids=NULL ← 仅 admin
```

### 四、待办（更新 08-30 第五节）

已闭合：待办 1（已 push）、待办 2 的 UI 正向验证部分。

仍未做：

1. ~~**B 类越权验证**~~ —— **09-01 已完成**，见下一条目。
2. ~~**告警规则权限 A/B 待决策**~~ —— **09-01 已选 A 并执行**，见下一条目。
3. `Center.RegionIsolation.Enable` 仍为 **false**，指标层隔离在生产上未生效。
4. 测试账号 `alert` 待删。
5. ES 防呆守卫未加：非 prometheus 数据源被授权给业务组时启动打 WARNING。
6. VM-1 timeout 止血未做（第二节 A）。

---

## 2026-09-01　B 类越权验证 + 告警规则权限收回

### 一、越权验证（临时账号 `test-bj-tmp`，Standard 角色 + 用户组 2「BJ」→ 业务组 4）

方法沿用 8/27：**只测「应当被拒」的路径，不测 admin 的成功路径**；写路径把字段设成
**当前值**，即使拦截失效数据也不变。测后全删。

**读路径（目标组 6 = YJ，账号无权）**

| 请求 | 结果 | 判定 |
|---|---|---|
| `GET targets?gids=6` | 403 | ✅ `bgroCheck` |
| `GET busi-group/6/alert-rules` | 403 | ✅ `bgrw` |
| `GET busi-group/6` | 403 | ✅ |
| `GET cfgsync/instances?gids=6` | 200 `[]` | ✅ 过滤语义（不是判权端点） |
| `GET cfgsync/hosts?gids=6` | 200 `[]` | ✅ 同上 |
| `POST proxy/1`（VM-1，授权给 [6]） | 403 | ✅ `CanAccessDatasource` |
| `POST proxy/2`（ES-1，`busi_group_ids` NULL） | 403 | ✅ 空授权 = 代码强制拒绝 |
| `GET boards?bids=10,11,12`（组 1，`public=0`） | 200 `[]` | ✅ 已过滤 |
| `GET board/10` | 403 | ✅ |
| **对照组（自己的组 4）** `GET targets?gids=4` | 200 `{"total":0}` | ✅ 没挡错人 |
| **对照组** `GET busi-group/4/alert-rules` | 200 `[]` | ✅ |

**告警事件（本次改造新补的判权点，重点验证）**

| 请求 | 结果 | 判定 |
|---|---|---|
| `POST alert-cur-events/card/details` `ids=[182487,182483]`（组 6） | **403** | ✅ 逐 group_id 判权生效 |
| `GET alert-cur-event/182487` | **403** | ✅ |
| `GET alert-cur-events/list`（不带 gids） | 200 `[]` | ✅ 默认收窄到自己的组 |

> ⚠️ **踩过的坑：第一轮用了已恢复消失的事件 id（182340/182358），拿到 `200 {"dat":[]}`。**
> 那不是「未拦截」，而是**记录不存在、判权循环根本没执行** —— 等于没测到。
> 同理 `GET alert-cur-event/182340` 的 **500** 也是记录缺失导致，不是缺陷。
> **教训：测事件类判权必须先 `SELECT` 确认 id 当前存在**（告警会自动恢复，
> id 的有效期只有几小时）。

**写路径（`bgidMatchCheck`，本次新增）**

| 请求 | 结果 | 判定 |
|---|---|---|
| `PUT busi-group/4/alert-rules/fields` `ids=[3]`（规则 3 在组 6） | **403** | ✅ `bgidMatchCheck` 挡住「借自己有权的壳改别人的记录」 |
| `PUT busi-group/6/alert-rules/fields` `ids=[3]` | 403 | ✅ `bgrw` 在更外层就挡了 |
| `DELETE busi-group/4/alert-rules` `ids=[3]` | **200** | ⚠️ 见下 |

**`DELETE` 返回 200 是上游的另一种防护形态，不是漏洞。**
`models.AlertRuleDels`（`models/alert_rule.go:1010`）的 SQL 自带
`WHERE id = ? AND group_id = ?`（handler 注释原文 "param(busiGroupId) for protect"），
跨组删除**删 0 行**，`Delete` 不报错所以返回 200。已核验规则 3 仍在、组 6 仍 21 条。

所以现在库里并存两种防护：**判权型返 403**（`bgidMatchCheck`，本次加的）与
**WHERE 兜底型返 200**（上游原生）。**不动上游逻辑** —— 数据是安全的，改成 403
需要先查再判，是把一层防护换成另一层，不划算。但要知道这个差异：
**看到 200 不等于操作生效**，判断写路径是否被挡必须查数据，不能只看状态码。

**清理与核验**

```
DELETE FROM user_group_member WHERE user_id=18;
DELETE FROM users WHERE id=18 AND username='test-bj-tmp';
```

残留 0；数据未被改动：`alert_rule` 22 条 / 组 6 21 条 / `busi_group` 7 / `target` 13，
与测试前基线一致。

### 二、告警规则权限：选 A，已执行

08-30 摊开的 A/B 二选一，选 **A：收回 Standard 角色的建/改/删规则权**。
B（保存时按 `group_id` 持久化注入 PromQL）语义上会卡住 —— 规则 id=1 属于组 2
「资源清单」，那不是机器组，注不出 ident 集合。

```sql
DELETE FROM role_operation
 WHERE role_name='Standard'
   AND operation IN ('/alert-rules/add','/alert-rules/del','/alert-rules/put');
```

收回后 Standard 剩 `/alert-rules`、`/alert-rules-built-in` 两条**只读**；Guest 6 条未动。

**影响面为零**：全站只有 2 个用户 —— `admin`（Admin 角色，不受 `role_operation` 约束）
和 `alert`（Standard，测试账号）。现场规则本就全部由 admin 建立。

**回滚**：把上面三行 `INSERT` 回去即可。

**这条堵的是**：区域用户建的规则在求值时没有用户上下文、会对**全量数据**求值 ——
指标层隔离管不到告警规则这条路径。收回建规则权后，该缺口从「敞着」变成
「只有 admin 能碰」，与 ES / Jaeger / VictoriaLogs 的兜底方式一致。

**代价**：区域用户从此不能自建告警规则，加规则要走 admin。接入第二个区域、
区域方要自治时这条会变成痛点，届时再做 B。

### 三、待办（更新 08-31 第四节）

1. ~~`Center.RegionIsolation.Enable` 仍为 **false**~~ —— **同日已打开**，见下一条目。
2. 测试账号 `alert` 待删。
3. ES 防呆守卫未加。
4. VM-1 timeout 止血未做（08-31 第二节 A）。

---

## 2026-09-01（晚）　指标层隔离正式开启 + 四个区域账号

### 〇、触发原因：BJ 组有机器了

白天还是「13 台全在 YJ」，晚上发现新注册的 `cosl-bqj-10.185.226.14` 已从
`_待分配` 分到了 **BJ 组**。现场从此是 **YJ 13 台 + BJ 1 台**，
「授权即全量」不再是理论风险 —— VM-1 只要授权给 BJ，BJ 就能查 YJ 的全部指标。

### 一、配置怎么上服务器：先手工同步，后恢复成 git

改配置时 `git fetch` 报
`Failed to connect to 127.0.0.1 port 8080: Connection refused`，
于是当场判断「cosl-6456 连不上 GitHub，只能手工同步」，走了备份 + 传 /tmp + diff + 覆盖。
**这个判断是错的**：代理是临时断的，当天稍后已恢复，`git fetch` 正常
（`09a3c20..c12be82`）。服务器**能**走 git，正常流程仍是 push 后到服务器 pull。

手工同步本身没做错（配置确实按预期上线了），保留下来作为代理挂掉时的应急手段。
**其中「覆盖前必须先 diff」这一条与代理无关，永远要做**：服务器上那个文件当时带着
**未提交的手工改动**（8/27 关 `AnonymousAccess`、加 `EventHistoryGroupView` 是直接在
服务器上改的，从没提交），直接 cp 会丢现场配置。本次 diff 结果是「只多了
RegionIsolation 段、零其它差异」，确认手工改动与 git 版本已等价，才敢覆盖。

```bash
# 应急路径（代理挂了时用）
ssh cosl-6456 'cp .../config.toml.tpl .../config.toml.tpl.bak.$(date +%Y%m%d)'
cat etc/o9e/config.toml.tpl | ssh cosl-6456 'cat > /tmp/config.toml.tpl.new'
ssh cosl-6456 'diff .../config.toml.tpl /tmp/config.toml.tpl.new'   # ← 关键，别直接 cp
ssh cosl-6456 'cp /tmp/config.toml.tpl.new .../config.toml.tpl'
# 重启：compose 服务名是 n9e，容器名才是 o9e，`restart o9e` 会报 no such service
ssh cosl-6456 'cd /home/kylin/o9e-deploy && docker compose restart n9e'
```

#### ⚠️ 收尾时踩的坑：`git checkout --` 恢复的是 HEAD，不是 origin/main

代理恢复后想把服务器交回 git 管理，跑了
`git checkout -- etc/o9e/config.toml.tpl && git pull origin main`。
前半句执行了，后半句**失败**：

```
error: cannot pull with rebase: You have unstaged changes.
```

（服务器配了 `pull.rebase`，`deepflow/.../server.yaml` 的手工改动挡住了 pull。）
结果停在半截状态 —— 而服务器 HEAD 当时还是旧的 `09a3c20`，
所以 checkout 把文件**打回了旧版本**：`RegionIsolation` 段没了，
更糟的是 `PromQuerier = true` 回来了，等于 8/27 关匿名访问的加固被撤销。

三条教训：

1. **`git checkout -- <file>` 恢复到 HEAD，不是 `origin/main`。**
   fetch 过不等于 HEAD 前进了。要按远端内容恢复得写
   `git checkout origin/main -- <file>`。
2. **`&&` 串起来的两条命令，前一条的破坏性不会因为后一条失败而回滚。**
   涉及生产配置文件时拆开跑、逐条看结果。
3. **容器行为正常 ≠ 磁盘配置正确。** bind mount 绑的是 inode，
   `git checkout` 是「换掉整个文件」（新 inode），
   所以容器内 `/app/etc/config.toml.tpl` 仍是被换掉前那份正确内容、隔离照常生效，
   磁盘上却已经是错的。**这种故障只在下次重启时才爆发，中间毫无征兆。**
   核验必须是 `diff <(docker exec o9e cat /app/etc/config.toml.tpl) etc/o9e/config.toml.tpl`，
   不能只看功能是否正常。

恢复过程：重新把正确内容写回磁盘 → stash `server.yaml` → `git pull origin main`
（HEAD 到 `c12be82`，文件内容与手工版一致）→ 处理 stash 冲突（见下）。
终态：HEAD 与 `origin/main` 同步，两个容器的运行配置与磁盘一致。

#### 顺带清掉的历史悬挂：`server.yaml` 的手工改动

`deepflow/common/config/deepflow-server/server.yaml` 那处未提交改动
（把 remote-write 出口手改成 `http://192.169.219.215:17000/prometheus/v1/write`）
在这次 pull 里撞上了上游改动 —— 上游把它改成了
`server.yaml.tmpl` + `render-config.sh`，`server.yaml` 进 `.gitignore` 变成生成物，
正是为了根治「手改被 git 打回」这个坑。

按上游意图解的：冲突取模板侧，现场值挪进 `deepflow/.env` 的 `N9E_REMOTE_WRITE`
（该键是上游新加的，现场 `.env` 建于 8/3 还没有），再跑 `./deepflow/render-config.sh`
生成 `server.yaml`。生成物与 deepflow-server 容器内正在用的配置**非注释内容完全一致**，
无需重启。

以后改 deepflow 的 n9e 出口：改 `.env` → 重跑 `render-config.sh` →
`docker compose up -d deepflow-server`，**别再手改 `server.yaml`**。

`initsql/d-cfgsync.sql`、`initsql/e-topo-studio.sql` 两个未跟踪文件**仍然悬着**，本次没碰。

### 二、开启的配置

`etc/o9e/config.toml.tpl` 新增（提交 `7ff717d`）：

```toml
[Center.RegionIsolation]
Enable = true
AllowIdentlessSeries = true
```

启动守卫按预期输出：

```
WARNING center/center.go:80 metric isolation: AllowIdentlessSeries is true,
series without an ident label (e.g. DeepFlow) are visible to EVERY business group.
Turn it off before onboarding a second region
```

容器 healthy，**0 panic，0 个真实用户撞到的 403**。

### 三、数据源授权

`VM-1` 从 `[6]` 扩到 **`[4,5,6,7]`**（BJ/TJ/YJ/ZJ 四个区域组）。
`ES-1` 保持 `NULL` = 仅 admin。

**顺序很重要，本次是「先开开关，再扩授权」** —— 反过来的话，中间那段时间
BJ/TJ/ZJ 能查到 YJ 的全部指标。

### 四、四个区域账号

团队骨架早就搭好了（`user_group` 2=BJ / 3=TJ / 4=YJ / 5=ZJ，各自已 `rw` 授权对应业务组），
缺的只是成员。新建 4 个 `Standard` 账号并入对应团队：

| id | 账号 | 团队 | 业务组 | 机器数 |
|---|---|---|---|---|
| 19 | `bj-ops` | BJ | BJ | 1 |
| 20 | `tj-ops` | TJ | TJ | **0** |
| 21 | `yj-ops` | YJ | YJ | 13 |
| 22 | `zj-ops` | ZJ | ZJ | **0** |

统一初始密码，**约定各区域首次登录后自行修改**（n9e 的 `users` 表没有强制改密字段，
设成什么就是什么，改不改只能靠约定）。

密码 hash 用 MySQL 现算，避开手工拼接：

```sql
SET @salt = (SELECT cval FROM configs WHERE ckey='salt');
SET @pw   = MD5(CONCAT(@salt, '<-*Uk30^96eY*->', '<明文>'));
```

### 五、验证：隔离确实生效

用 `cpu_usage_idle`（12 台都有）做判据，直连 VM 拿基线对照：

| 账号 | 能看到的 ident | 判定 |
|---|---|---|
| `yj-ops` | 11 个（12 台减去 BJ 那台） | ✅ |
| `bj-ops` | 1 个（只有 `cosl-bqj-10.185.226.14`） | ✅ |
| `tj-ops` / `zj-ops` | **403 `no visible resource for the current user`** | ✅ 名下无机器，设计如此 |
| `bj-ops` 自写 `{ident="COSLOS-147..."}` | **空结果**（交集为空） | ✅ 越权拿不到 |
| `bj-ops` 自写 `{ident="cosl-bqj..."}` | **正常出数** | ✅ 没被放大成全部 |

最后一条是**纯追加语义**的关键回归：注入不剔用户自写的 filter，
两个 filter 天然 AND 取交集。若沿用第一版「先剔再注入」，这里会被放大成 BJ 的全部机器。

### 六、验证过程中差点误判的一次

第一轮用 `count(up)` 测，结果 `yj-ops` 拿到 **61 = 全量基线**，
且 `count(count by(ident)(up))` **= 1**。第一反应是「隔离没生效」。

实情相反：`up` 的 61 条序列**全部来自 k8s 联邦**（`source="k8s-federate"`），
ident 全是同一台采集机 `COSLOS-147-10.75.25.147` —— 它在 YJ 组，
所以 yj-ops 看到全部 61 条**正是正确行为**；`bj-ops` 对同一查询返回空，也是正确的。

**这是「`ident` 是采集者不是被监控资源」最直白的现场证据**：
一个 k8s 集群里 61 个联邦指标序列，在隔离视角下塌成 **1 台机器**。

**教训**：验证指标隔离**不能用 `up`**（它在本环境几乎全是联邦来源、ident 高度集中）。
要用 `cpu_usage_idle` 这种 categraf 直采、ident 分散的指标，
并且**必须直连 VM `:8428` 拿全量基线做对照** —— 只看单个账号的返回值判断不了收窄。

### 七、当前隔离全景

| 模块 | 机制 | 状态 |
|---|---|---|
| 机器 / 实例 / cfgsync 列表 | 业务组过滤 + `bgroCheck` | ✅ |
| 告警规则 / 事件 / 屏蔽 / 订阅 | `bgro`/`bgrw` + `bgidMatchCheck` | ✅ |
| 看板 / 大屏 | 业务组过滤 + 数据源授权 | ✅ |
| **指标查询（PromQL）** | **ident 注入** | ✅ **本次开启** |
| 告警规则**求值** | 无 | ⚠️ 靠收回 Standard 建规则权兜底 |
| ES / Jaeger / VictoriaLogs | 无 | ⚠️ 靠只授权 admin 兜底 |
| 无 ident 的序列（DeepFlow） | `AllowIdentlessSeries=true` | ⚠️ **对所有区域可见** |

### 八、待办

1. **UI 点击验证**：用 `yj-ops` / `bj-ops` 过一遍看板、大屏、业务服务、告警页，
   确认没有页面变空或报错。API 层已验证，**UI 层未验证**。
2. **`tj-ops` / `zj-ops` 登录后指标查询全部 403** —— 这是设计行为（名下无机器），
   但对使用者是困惑。给 TJ/ZJ 分配机器后自动恢复，不需要改配置。
3. **新发现的上游洞**：`GET /busi-groups?all=true` 对**任何登录用户**返回全部业务组
   （[models/user.go:1012](../../n9e/nightingale/models/user.go) 的
   `u.IsAdmin() || (len(all) > 0 && all[0])`）。前端 `BusinessGroupSelectWithAll`
   写死 `all: true`，被告警事件、历史告警、看板列表等 **9 个页面**使用 ——
   区域用户打开告警页就能看到全部区域的组名。
   **是元数据泄露不是数据泄露**（拿到 id 后 `busi-group/:id` 仍 403）。
   修法：`busiGroupGets` 把 `all` 限制成 admin-only。
4. **方案 X（未归组的第二道防线）**：删 `router_target.go:119` 的 `append(bgids, 0)`、
   把 `:105` 的 `gids=0` 免判权豁免限制成 admin。现在 `_待分配` 让未归组集合恒为空，
   但 `BindTargetsToUnassigned` 失败只记日志，失败即静默复活两个洞。
   在此之前，**`未归组 = 0` 应进巡检**：
   ```sql
   SELECT COUNT(*) FROM target t LEFT JOIN target_busi_group g
     ON g.target_ident = t.ident WHERE g.target_ident IS NULL;
   ```
5. 测试账号 `alert` 待删（它不属于任何团队，现在什么都看不到）。
6. ES 防呆守卫未加；VM-1 timeout 止血未做。
7. **接入第二个 DeepFlow 数据来源前，`AllowIdentlessSeries` 必须改回 `false`。**
