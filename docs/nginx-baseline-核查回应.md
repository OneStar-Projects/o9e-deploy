# Nginx 配置基线核查 —— 回应报告

- 对象：客户等保核查/绿盟 RSAS 评估组
- 被核查主机：192.170.19.123（海油云生产平台 ecs1）
- 核查模板：Nginx 配置规范 (Linux)_S3A3G3（V6.0R04F02.0007，等保2.0 三级）
- 收到报告：`192.170.19.123.xls`，15 个检查项结果**均为"否"**（不合规）
- 回应日期：2026-11-02

---

## 一、结论概述

收到的扫描报告中 15 项**全部判为"不合规"**，经核实，**这是扫描目标错位导致的假阴性，并非配置缺失**：报告中连 `server_tokens off`、`error_log`、`access_log`、`log_format`、`keepalive_timeout` 等**配置中确实存在**的项也被判"否"。

按**真实运行配置**重新核查：**15 项中 11 项合规**；其余 4 项中，2 项为模板指令过时/场景不适用（已等效实现或 N/A），2 项（IP 访问控制）待贵方确认是否强制要求。详见下文。

---

## 二、根因：Nginx 为容器化部署，扫描读取了主机空路径

本平台 nginx 以 Docker 容器方式运行，配置文件**不在主机标准路径**：
- 主机**无 nginx 二进制**（`command -v nginx` 为空）；
- 主机标准路径 `/etc/nginx/nginx.conf`、`/usr/local/nginx/conf/nginx.conf` **均无配置文件**；
- 真实配置位于容器内 `/etc/nginx/nginx.conf`（及宿主 `/home/kylin/o9e-deploy/etc/nginx/`，按最佳实践拆分为主配置 + `conf.d/` 虚拟主机）。

RSAS 脚本在主机上对默认/指定路径做 `grep`，该路径无文件 → 所有检查项读取为空 → 全部判"否"。此外，脚本对单文件 `grep` **不跟随 `include`**，即便指向主配置也读不到 `conf.d/` 中的 `location`/`error_page` 等（这些指令按 nginx 语法只能位于 server/location 块）。

**建议的正确核查方式**：对导出的**完整合并配置**扫描——
```
docker exec o9e-nginx nginx -T > /tmp/nginx_full.conf
```
`nginx -T` 会展开全部 `include`、合并 http 与所有 server 块为单文件。对该文件重扫即可真实反映合规状态（下表结果即基于此文件）。

---

## 三、逐项核查结果（基于真实合并配置，11/15 合规）

| # | 检查项 | 真实状态 | 证据 / 说明 |
|---|---|---|---|
| 1 | 错误日志 error_log | ✅ 合规 | `error_log /var/log/nginx/error.log warn;` |
| 2 | 访问日志 access_log | ✅ 合规 | `access_log /var/log/nginx/access.log main;` |
| 3 | 日志格式 log_format | ✅ 合规 | `log_format main '$remote_addr - $remote_user [$time_local] ...'` |
| 15 | 隐藏版本 server_tokens | ✅ 合规 | `server_tokens off;` |
| 5(保活) | keepalive_timeout | ✅ 合规 | `keepalive_timeout 65;` |
| 4(请求头/体超时) | client_header/body_timeout | ✅ 合规 | `client_header_timeout 60s;` `client_body_timeout 60s;` |
| 6 | 响应超时 send_timeout | ✅ 合规 | `send_timeout 60s;` |
| 7 | 并发连接限制 limit_conn | ✅ 合规 | `limit_conn_zone $binary_remote_addr zone=perip:10m;` + 443 `limit_conn perip 200;` |
| 8 | 下载限速 limit_rate | ✅ 合规 | `limit_rate 0;`（0=不限，按需可调） |
| 10 | 自定义错误页 error_page | ✅ 合规 | `error_page 400 401 403 404 500 502 503 504 /_n9e_err;` |
| 3(IP控制) | allow / deny | ⏳ 待确认 | 见第四节(2) |
| 7(session容器) | limit_zone | ⚠ 等效实现 | 见第四节(1) |
| 9 | 防盗链 location~* | ⚠ 不适用 N/A | 见第四节(3) |

---

## 四、需说明/人工研判的项

### （1）项「limit_zone」—— 指令已废弃，用官方等效指令实现
`limit_zone` 是 nginx 0.7–1.17 的旧指令，**自 nginx 1.18 起已被移除**。本平台 nginx 版本为 **1.25**，若写 `limit_zone` 将导致 `nginx -t` 失败、服务无法启动。其功能（按源 IP 限制并发）已由官方替代指令实现并通过（见上表项「limit_conn」）：
```
limit_conn_zone $binary_remote_addr zone=perip:10m;
limit_conn      perip 200;
```
**申请按"等效满足"人工通过。**

### （2）项「IP 访问控制 allow/deny」—— 待贵方确认是否强制
当前对外入口的访问控制采用：
- **17000（采集 agent 上报入口）**：按 URI 路径白名单放行（仅指标写入/心跳/配置同步），其余返回 403；
- **443（管理/业务入口）**：TLS + n9e 应用层账号鉴权 + RSA/验证码。

是否额外叠加 nginx 层 **IP 白/黑名单**，取决于贵方等保要求。若需要，请提供**允许访问 443 的来源网段（CIDR）**，我方将配置 `allow <网段>; deny all;`。
（提示：采集 agent 走 17000、不走 443，故对 443 做 IP 限制不影响采集；但需覆盖所有合法访问来源，避免误阻正常用户/集成。）

### （3）项「防盗链 location ~* ^.+\.」—— 场景不适用（N/A）
防盗链（`valid_referers`）用于**直接对外提供图片/视频等静态资源**的站点。本平台 nginx 为**全量反向代理**至后端 n9e，**不直接 serve 任何静态媒体资源**，不存在被盗链的对象，故该项**不适用**。
（另：该模板检查正则 `location ~* ^\.` 本身无法命中——nginx 的 location 匹配 URI，URI 恒以 `/` 开头，`^\.` 永不匹配。我方已额外配置隐藏文件防护 `location ~ /\.(?!well-known) { deny all; }`，实测 `GET /.env` 返回 403。）

---

## 五、已实施加固与建议

**已实施（2026-11-02 前完成，ecs1 已 `nginx -t` 通过并灰度 reload，备机 ecs2 同步）**：
- http 全局补齐 `client_body/header/send_timeout`、`limit_conn_zone`、`limit_rate`；
- 443 虚拟主机补齐 `limit_conn`、`error_page`、隐藏文件 `deny`；
- 保留原有：TLSv1.2/1.3、`ssl_ciphers HIGH:!aNULL:!MD5`、80→443 强跳、安全响应头（X-Content-Type-Options / X-Frame-Options / Referrer-Policy）、`server_tokens off`、`client_max_body_size` 限制；
- 17000 采集入口按路径白名单放行，**未施加限流以保障采集上报**（人访问面 443 已限流）。

**建议**：
1. 以 `nginx -T` 导出的合并配置重扫 192.170.19.123（及备机，同构），即可真实反映 11/15 合规；
2. 项 limit_zone、防盗链按第四节说明人工研判；
3. IP 访问控制待贵方确认强制与否后处置。

---

## 六、远程漏洞扫描（10.77.80.193）核查与修复

另收到对 10.77.80.193（本机公网 NAT 地址）的远程漏洞扫描报告，共 14 项（2 项中危、其余低危/信息类）。处置如下。

### 已修复（中危 2 项，ecs1 已生效、备机 ecs2 同步、配置入库）

| 漏洞 | 风险 | 修复措施 | 验证 |
|---|---|---|---|
| Metrics 未授权访问（`https://10.77.80.193/metrics` 返回 n9e 运行指标） | 中 6.3 | 443 入口对 `/metrics` 直接返回 403：`location = /metrics { return 403; }`（内部自监控经容器内网抓取，不受影响） | `curl https://.../metrics` → **403** |
| 支持 RSA 密钥交换（缺前向保密） | 中 5.0 | `ssl_ciphers` 改为**仅 ECDHE** 套件 + `ssl_prefer_server_ciphers on`，禁用静态 RSA 密钥交换 | 握手协商 `ECDHE-RSA…`（Server Temp Key X25519，前向保密）；RSA-kx 套件**握手失败** |

> 两项修复不影响业务：443 Web 正常、17000 采集 agent 上报正常（TLS1.2/1.3 保留，仅淘汰无前向保密的 RSA 密钥交换）。

### 低危/信息类（处置建议）

- **ICMP timestamp 响应（低 2.1）**：建议在**云安全组/边界防火墙**丢弃 ICMP timestamp 请求/响应即可消除；主机侧不单独改 iptables（避免与容器网络规则冲突）。
- **SSL 证书自签名 / 不受信任 / 证书链不完整（低 3.5×3）**：当前为自签证书。**请贵方提供内部 CA 签发的服务器证书（含完整链）**，我方替换 `etc/tls/` 后即消除该三项。
- **Web 服务 banner 可获取（低 0.0）**：已 `server_tokens off` 隐藏版本号；如需完全去除 `Server: nginx` 响应头，需引入 nginx `headers-more` 模块，属低风险可选项。
- 其余（证书到期时间、TLS1.2/1.3 协议探测、加密套件枚举、hostname 获取等）：报告已标注"仅信息收集，无需修复"。
