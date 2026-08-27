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
