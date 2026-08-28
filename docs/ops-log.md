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

### 剩余改造项优先级

```
1. 数据源授权        /proxy + /datasource/list 一并解决    ~2.5 天
2. cfgsync 过滤      371 个实例全裸,面最大                  ~2 天
3. 大屏 bgids 过滤                                          ~1.5 天
4. boardGetsByBids 补权限                                   ~0.5 天
5. target 增量兜底(方案 C)                                  ~0.5 天
```

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

**② `alert-1` 的归属待定**，取决于正式区域划分和主机的真实分布。

**③ 一个语义提醒**：区域用户看到的告警数量取决于「规则挂在哪个组」，
而不是「告警对象属于哪个区域」。若将来出现"A 区域的规则监控了 B 区域的设备"，
告警会归 A，隔离就错位了。规则的 PromQL 过滤范围必须和它所在的业务组一致——
这条没有任何机制强制，只能靠规范。

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
