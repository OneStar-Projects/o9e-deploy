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
（本地开发前端 localhost:28765）。需要在浏览器中确认它带登录态、能正常出数。
若 401，应修前端使其携带 session，而不是重新打开本开关。

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
