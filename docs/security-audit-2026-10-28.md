# 安全审计报告（2026-10-28 客户渗透测试前置自查）

本报告面向：客户安全团队与渗透测试方、本项目运维。
范围：n9e fork（nightingale + 自写 config-sync/agents/topo-studio）、scanopy fork、o9e-deploy 部署配置。
方法：应用代码静态审查（四维并行）+ 142 测试环境运行态只读核验。未做破坏性测试、未编写攻击利用代码。
与既有 `security-backlog.md`（D1–D11、P1–P14）去重，本报告只列其**未覆盖**的新项。

## 证据等级说明
- **[实测]**：在 142 测试环境运行态验证确认（看返回内容，非仅状态码）。
- **[代码]**：静态代码/配置审查发现，未在运行态触发验证。

## 关键背景：危险默认值 vs 生产模板
仓库默认配置 `nightingale/etc/config.toml` 带多个危险默认：`PProf=true`、`[Center.AnonymousAccess] PromQuerier=true`。
生产部署模板 `o9e-deploy/etc/o9e/config.toml.tpl` 已覆盖为安全值（`PProf=false`、`PromQuerier=false`），并有"两者同真拒绝启动"的启动保护。
**因此以下 H1/H2 的真实暴露取决于每个部署是否套用了加固模板。** 142 测试环境（二进制版 17001）未套用，落在危险默认值上，已实测复现。

---

## 一、高危

### H1. 匿名数据源代理 / 查询接口全面未授权（PromQuerier=true 时）— 数据泄露 + 内网 SSRF　[实测]
- 代码：`nightingale/center/router/router.go:297-331`、`router_proxy.go:53-59`（`dsPermCheck` 首行 `if AnonymousAccess.PromQuerier { return }` 直接放行）、`center/datasource_acl.go:30-52`。
- 默认：`etc/config.toml:183 PromQuerier=true`（仓库默认开）。
- 实测：142:17001 未鉴权 `POST /api/n9e/ds-query` 已进入 handler 解析 body（非 401），证明匿名访问开启。约 25 个查询/代理/元数据接口（`/proxy/:id/*url`、`ds-query`、`logs-query`、`db-tables` 等）在此开关下**无鉴权**。
- 影响：未授权读取全部数据源指标/日志；经 `/proxy/:id/*url` 对配置的内网数据源端点发起请求（SSRF）；枚举库表。
- 修复：所有部署强制套用加固模板（`PromQuerier=false`）；建议把仓库默认也改为 false，与上游对齐，避免"默认开放"。

### H2. pprof 未鉴权暴露（PProf=true 时）— 内存/密钥泄露 + DoS　[实测]
- 代码：`nightingale/pkg/httpx/httpx.go:192-193`，`pprof.Register` 在**任何鉴权中间件之前**注册。
- 默认：`etc/config.toml:30 PProf=true`（仓库默认开）。
- 实测：142:17001 `GET /api/debug/pprof/` 返回真实 pprof 页面（非 SPA）。容器版 17000 未暴露（返回前端 SPA）。
- 影响：未授权获取 heap/goroutine 转储（可能含内存中的令牌/口令/查询内容）；profile/trace 可被滥用致 DoS。同时 `/ping /pid /ppid /addr` 也在鉴权前（信息泄露，低）。
- 修复：生产模板已 `PProf=false`；建议仓库默认改 false，或把 pprof 放到鉴权之后 / 仅绑回环。

### H3. topo-studio 鉴权桥接 fail-open：APIToken 为空即完全放行　[代码]
- 代码：`n9e/topo-studio/internal/api/router.go:57-70`，`withAPIAuth` 在 `token==""` 时 `return next`（直接放行）。保护着 `/api/v1/scanopy/*`（凭据/网络/discovery/daemon CRUD）与 `/scanopy-api/*`（注入服务账号 session 的全量反代）。
- 影响：部署时 `APIToken` 未设/为空（常见误配）→ 任何能触达 topo-studio 端口者可导出 scanopy 全部凭据（含 SNMP community、SSH/docker 凭据）、增删网络、对内网发起 discovery 扫描、以管理级服务账号操作 scanopy。结合 daemon 挂 docker.sock → 内网横向 + 潜在宿主 RCE。
- 修复：改为 fail-closed（token 未配置则拒绝启动/拒绝请求）；比较用 `subtle.ConstantTimeCompare`；核查各部署 `APIToken` 已设。

### H4. config-sync enroll 信任模型薄弱：身份自报 + bootstrap token 可重放 + bundle 无签名　[代码]
三条同根因（agent 侧集中式配置下发，以 root/SYSTEM 落盘并重启服务）：
- **H4a 身份(ident)可伪造/抢注**：服务端 `nightingale/center/configsync/agentauth/token.go:100` 的 `hostIdent` 完全来自请求体，仅格式校验、不验证归属，靠"先到先得"兜底。持 bootstrap token 者可抢注任意未注册 ident，拿到其 host_token，进而拉取该机 bundle、解析绑定到该 ident 的全部密钥明文（`secret/service.go`），并 DoS 真实主机。
- **H4b bootstrap token 可无限重放**：`token.go:69/131` 成功后不消费、不撤销（`used_at` 永远 0），TTL 最长 365 天/可永不过期。agent 侧注释（`cmd/config-sync/api.go:199-204`）称"一次性"与实现不符。
- **H4c bundle 无真实性保证**：`cmd/config-sync/bundle_validation.go:29-35`，`content_hash` 只对收到的文件自洽重算、不绑密钥，无法防伪造。被攻陷/中间人的服务端可下发任意 .toml 到所有主机并触发重启 → categraf 加载含 exec/script 类采集 → 全体被监控主机 root RCE。
- 修复：enroll 绑强身份（mTLS / 云实例签名 / 一机一次性 token）或服务端分配 ident；bootstrap token 真正一次性或明确文档化并强制短 TTL；bundle 加服务端 Ed25519 签名、agent 内置公钥校验；或限制可下发插件白名单，禁 exec/script。

---

## 二、中危

### M1. /api/n9e/deploy（ansible 部署）仅 auth 无授权 + playbook 路径穿越　[代码]
- 代码：`nightingale/center/router/router_deploy.go:116-123`，deploy 组只挂 `rt.auth()`，缺 `rt.user()/rt.perm()`（注释称"仅 admin"但未实现；对照 `router_agent_version.go:32` 正确用了 `rt.perm("/components/put")`）。`req.PlaybookName` 来自请求体，`ansible_deploy.go:120` 直接 `filepath.Join` 未清理 `../`，随后 `exec.Command("ansible-playbook", ..., playbookPath)` 执行。
- 影响：任何**已登录**用户可触发对受管主机的 ansible 执行（越权）；`playbook_name` 含 `../` 可引用 PlaybooksPath 外任意 .yml → 结合可落盘 YAML 存在 RCE。
- 修复：补 `rt.user()+rt.perm(...)`；`PlaybookName` 经 `filepath.Clean` 后校验仍在 PlaybooksPath 内，或改白名单。

### M2. config-sync TLS 可一键关闭、SERVER_URL 不强制 https、host_token 可明文落盘　[代码]
- `INSECURE_SKIP_VERIFY`（`config.go:94`、`api.go:33-43`）为真即对 enroll/bundle/secrets/ack 全部请求关闭 TLS 校验，且注释鼓励"自签名内网场景"使用，无"指定自定义 CA"的中间档。
- `SERVER_URL`（`config.go:88`）无 scheme 校验，配成 `http://` 则 token 与密钥明文传输且无告警。
- 无 systemd-creds 时 host_token 以明文 0600 落盘（`credential_store.go:30-48`），`REQUIRE_ENCRYPTED_HOST_TOKEN` 默认关。
- 修复：提供 `SERVER_CA_FILE` 严格校验路径、弱化 INSECURE_SKIP_VERIFY；启动校验 https；生产默认强制加密存储 host_token。

### M3. /v1/n9e 服务管理 API 在 BasicAuth 为空时 fail-open　[代码]
- `nightingale/center/router/router.go:848-968`，`APIForService.Enable=true` 且 BasicAuth 为空时，建用户/读写配置密钥/`conf-prop/decrypt`/`users/phone/decrypt`/dsProxy 等高权限接口**无鉴权且无告警**。默认 `Enable=false`（已缓解），但误配即全开。
- 修复：Enable=true 而 BasicAuth 空时启动失败（fail-closed）。

### M4. DeepFlow 控制面/数据面 17001/17002 绑 0.0.0.0，无来源限制、无 TLS　[代码]
- `o9e-deploy/deepflow/docker-compose.yaml:67-68`（同文件 64-66 的调试端口都加了 `127.0.0.1:` 前缀，唯独这两行没有）。同网段任意主机可直连 DeepFlow server gRPC 控制面与 ingester 数据面。
- 修复：限定来源网段（宿主 firewalld `DOCKER-USER` 链，参照 P6/P14）；评估 TLS/mTLS。

### M5. DeepFlow 初始化 SQL 建可远程登录的 root@'%' 超管　[代码]
- `o9e-deploy/deepflow/common/config/mysql/init.sql.tmpl:1-3`：`CREATE USER 'root'@'%' ... GRANT ALL ON *.* WITH GRANT OPTION`。这是触发整次审计的 D1 弱口令类问题在 DeepFlow 侧的翻版（口令已随机化缓解、MySQL 端口未发布，但同 docker 网络容器被攻陷即拿全库 + GRANT）。
- 修复：删 `root@'%'`，改最小权限业务账号，root 只留 `root@localhost`（与 D2 一致）。

### M6. Logstash NetFlow UDP 5044 绑 0.0.0.0，无认证　[代码]
- `o9e-deploy/docker-compose.yaml:345-346`（无 bind 前缀、不受 `*_BIND` 控制）。任何可达主机可向 ES 注入任意 NetFlow 记录（数据投毒 / 撑爆磁盘）。
- 修复：限定来源网段或文档化为受控入口。

### M7. scanopy-daemon 特权容器 + host 网络 + docker.sock（P14 容器逃逸面未缓解）　[代码]
- `o9e-deploy/docker-compose.yaml:106-119`（`privileged:true` + `network_mode:host` + `docker.sock:ro`）。P14 只处理了 60073 监听地址，未缓解容器逃逸/宿主 root 提权面（privileged 本身等于宿主 root）。
- 另：`daemon /api/initialize` 无鉴权 bootstrap（`scanopy/backend/src/daemon/shared/handlers.rs:27-56`），未初始化的新 daemon 可被先到先得接管；daemon 初始化把 api_key 明文写 INFO 日志（`handlers.rs:88-90`，upstream，建议上报）。
- 修复：若拓扑发现不需要容器发现则去掉 docker.sock 挂载；用 `cap_add`(NET_RAW/NET_ADMIN) 替代全量 privileged；60073 严格仅 server 可达；移除日志中 api_key 明文。

### M8. topo-studio 桥接共享单一管理令牌 + 服务账号反代，scanopy 多租户隔离坍缩　[代码]
- `n9e/topo-studio/internal/adapter/scanopy/{session.go,client.go}`：`DoPassThrough` 对所有上游请求注入固定 `Bearer <cfg.Scanopy.Token>`，session 用固定 admin 账号换取。不透传调用者身份、不做 per-network 授权 → 经 n9e 访问 scanopy 的用户共用管理身份，可见/操作所有 network。
- 修复：n9e center 转发前强制用户鉴权 + network 范围校验；服务账号降为最小权限。

---

## 三、低危 / 观察项

- **L1 密钥经 healthcheck 落入 docker inspect**：`docker-compose.yaml:51/71/320`（mysql `-p$PW`、redis `-a $PW`、es `curl -u elastic:$PW`）写入 `Healthcheck.Test`，`docker inspect` 可见；叠加口令均经 `environment:` 注入（`/proc/<pid>/environ` 可读）。建议 healthcheck 改容器内变量间接引用、敏感服务用 docker secrets。[代码]
- **L2 gen-scanopy-daemons.sh 生成物明文内嵌 daemon api key + 特权 compose**（`:103-126`）。建议产物 chmod 600、key 走 env_file。[代码]
- **L3 DeepFlow render 产物 644 world-readable 且含明文口令**（`deepflow/render-config.sh:43`）。建议 640 + owner 收敛。[代码]
- **L4 主镜像默认 :latest、公共 Docker Hub fork 命名空间、无 digest 固定**（`.env.example:10,13`；对照 voice-gateway/forecast 已强制固定 tag）。与 P13 供应链面呼应。建议生产固定 tag 或 `@sha256:` digest。[代码]
- **L5 topo-studio 复用 scanopy admin(Owner) 账号作服务账号**（`docker-compose.yaml:279-280`）。建议建最小权限服务账号。[代码]
- **L6 categraf 一键安装脚本未鉴权、host 参数回填进 `curl|sudo bash`**（`router.go:492-495`、`router_agent.go:200-213`）。已有 `validAgentHost` 正则防命令注入，残余社工型 RCE（诱导管理员执行指向攻击者主机的安装链接）。建议 host 走白名单或该端点加鉴权。[代码]
- **L7 agent 心跳接口默认未配 BasicAuth**（`router.go:984-993`，上游默认）。影响有限。[代码]
- **L8 config-sync Unix 侧服务名未做白名单**（`service_unix.go`，与 Windows 不对称；因 argv 传参无注入，纯纵深防御）。[代码]
- **L9 ClickHouse `listen_host 0.0.0.0` + default 用户 `networks ::/0`**（仅 deepflow docker 网内可达、口令随机，风险低）；ES 关闭 HTTP TLS（仅内网）；n9e `OpenRSA=false`（依赖 nginx 443 终结）。[代码]

---

## 四、已核实"做得好"的点（排除噪音，供渗透测试方参考）
- 主业务 SQL 走 GORM/xorm 参数化；少数 `fmt.Sprintf` 拼 SQL 均有防护（`aiagent/tools/sql.go` 走 `ValidateIdentifier`、doris 走白名单 + `QuoteBacktick`）。
- 命令执行均用 argv 数组传参（非 shell）；告警脚本/notify-script 写入接口要求 `rt.admin()`。
- config-sync 路径穿越/符号链接防护扎实（`validateBundlePath` 拒绝绝对路径/`..`/`\`/`:`/NUL/非 .toml，`rejectSymlinks` 逐级 Lstat）；密钥仅内存 + tmpfs、runtime 非内存盘时拒绝含密钥的 bundle；凭据经 stdin/HTTP body 不进命令行。
- scanopy SNMP community 用 `Secret`/`expose_secret`，日志只记长度；自定义拓扑 CRUD 走 `Authorized<Member>` + network_ids 校验，未见越权。
- 业务组（busi-group）鉴权较完善（`bgidMatchCheck` 已收敛批量越权）；enroll 错误统一 401 防枚举、token 仅存 sha256、256-bit 随机；密钥 resolve 按 ident→binding→secret_refs 严格授权。
- 部署侧 `.env`/TLS 私钥 chmod 600 且 .gitignore 排除；initsql/f-app-users 的 admin 口令均为占位符；全仓 grep 未发现非占位符的硬编码真实口令/token。

---

## 五、处置优先级建议
1. **H1 + H2**：确认所有部署套用加固模板（`PromQuerier=false`/`PProf=false`）；把仓库默认也改安全值。**142 测试环境需立即关闭或隔离**（当前匿名查询 + pprof 实测可达）。
2. **H3**：topo-studio `withAPIAuth` 改 fail-closed，核查各部署 APIToken 已设。
3. **H4**：config-sync 引入强身份 / 一次性 token + bundle 签名（爆炸半径=全体被监控主机 root）。
4. **M1**：/api/n9e/deploy 补授权 + playbook 路径校验。
5. **M4–M8**：DeepFlow 端口与 root@'%'、NetFlow 5044、scanopy 特权面、桥接越权。
6. 低危随整改批次处理。
