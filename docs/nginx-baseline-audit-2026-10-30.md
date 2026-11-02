# Nginx 配置基线核查（等保2.0 三级 RSAS 模板 S3A3G3）

面向：本项目运维 + 客户等保核查人员。
日期：2026-10-30。

## 一、基线来源与核查方法
- 客户提供物：`Nginx_配置规范_(Linux)_S3A3G3.zip`，内含绿盟 **RSAS** 配置核查脚本（.sh + .pl + readme）。
  - 产品 RSAS，模板「Nginx 配置规范 (Linux)_S3A3G3」V6.0R04F02.0007，等保2.0，S3A3G3=三级。
- 核查方式：**不执行客户脚本**（下载的不可信代码，隔离目录只读分析）；从 .pl 提取其 15 条检查项（均为对 `nginx.conf` 的 grep），再拿当前 o9e nginx 配置逐条比对。
- 当前被核查配置：o9e 部署的 nginx（容器 `o9e-nginx`，nginx:1.25-alpine），配置文件：
  - `etc/nginx/nginx.conf`（主配置，http/stream）
  - `etc/nginx/conf.d/n9e.conf`（80→443 跳转、443 主站反代）
  - `etc/nginx/templates/agent-api.conf.template`（17000 agent 入口，启动渲染）

## 二、逐条核查结果（15 项:5 通过 / 10 缺失）

| # | 检查项(grep) | 等保意图 | 结果 | 当前配置 |
|---|---|---|---|---|
| 1 | error_log | 错误日志 | ✅通过 | `error_log /var/log/nginx/error.log warn;` |
| 2 | access_log | 访问日志 | ✅通过 | `access_log /var/log/nginx/access.log main;` |
| 3 | log_format | 自定义日志格式 | ✅通过 | `log_format main ...`(含 remote_addr/user/time/request/status/referer/UA) |
| 15 | server_tokens | 隐藏版本号 | ✅通过 | `server_tokens off;` |
| 8 | keepalive_timeout | 长连接超时 | ✅通过 | `keepalive_timeout 65;` |
| 4 | allow | IP 访问控制(白) | ❌缺失 | 未配(改用 17000 路径过滤 + 443 应用层鉴权) |
| 5 | deny | IP 访问控制(黑) | ❌缺失 | 未配 |
| 6 | client_body_timeout | 请求体超时(防慢速攻击) | ❌缺失 | 未配 |
| 7 | client_header_timeout | 请求头超时(防 slowloris) | ❌缺失 | 未配 |
| 9 | send_timeout | 响应发送超时 | ❌缺失 | 未配 |
| 10 | limit_conn | 并发连接限制 | ❌缺失 | 未配 |
| 11 | limit_zone | 连接区域(注:新版应为 limit_conn_zone) | ❌缺失 | 未配 |
| 12 | limit_rate | 速率限制 | ❌缺失 | 未配 |
| 13 | location ~* ^\. | 禁访隐藏文件(.git/.env 等) | ❌缺失 | 未配 |
| 14 | error_page | 自定义错误页(防信息泄露) | ❌缺失 | 未配 |

> 当前配置另有基线未检但有益的项:TLSv1.2/1.3、`ssl_ciphers HIGH:!aNULL:!MD5`、80→443 强跳、安全响应头(X-Content-Type-Options / X-Frame-Options / Referrer-Policy)、`client_max_body_size 64m`。

## 三、结论
- **5/15 通过，10/15 缺失。** 缺失项均为等保三级要求的「加固型」配置(超时、限流、访问控制、隐藏文件防护、自定义错误页),**不是已存在的漏洞**:
  - 版本隐藏(15)、日志(1/2/3)这几条「信息泄露/审计」硬指标**已满足**。
  - 10 项缺失中,最该补的是**防慢速/DoS 的四个超时与限流**(6/7/9/10/12)——纯防御性、低风险、改动小。
  - allow/deny(4/5):本部署是 **17000 按路径过滤 + 443 走 n9e 应用鉴权**,没用 IP 级 ACL;等保要 IP 白/黑名单则需补(可在管理面/内网来源处加)。
  - 隐藏文件(13)、错误页(14):nginx 全程反代到 n9e、不直接 serve 静态目录,实际风险低;但过基线仍需显式配。
- **扫描器视角的坑**:RSAS 脚本是对**单个 nginx.conf 文件** grep,**不跟随 include**。o9e 配置拆在 nginx.conf + conf.d/ + 模板里。若扫描只传 `/etc/nginx/nginx.conf`,则 conf.d 里的内容(以及未来补在 conf.d 的加固项)扫不到——**建议把要过基线的加固指令补在被扫描的那个文件(http 块)里**,否则即便配了也判不通过。

## 四、整改建议(按性价比)
在 `nginx.conf` 的 `http {}` 块内补(全局生效、也能被扫描器 grep 到):
```nginx
# 防慢速/DoS 超时
client_body_timeout   10s;
client_header_timeout 10s;
send_timeout          10s;
# 限流(新版指令)
limit_conn_zone  $binary_remote_addr zone=perip:10m;
limit_conn       perip 50;
limit_req_zone   $binary_remote_addr zone=reqperip:10m rate=50r/s;
# 自定义错误页(防信息泄露)
error_page 400 401 403 404 500 502 503 504 /blank.html;
```
在 443 server(以及按需 17000)内补:
```nginx
# 隐藏文件防护
location ~ /\.(?!well-known) { deny all; }
# IP 访问控制(按实际来源收敛,示例)
# allow 10.0.0.0/8; deny all;   # 仅在管理/内网入口使用
```
注意:
1. `limit_zone` 是 nginx 旧指令,现版本用 `limit_conn_zone`+`limit_conn`;RSAS 模板措辞偏旧,整改按新指令配即可(核查若死认 `limit_zone` 字面,需与客户说明版本差异)。
2. `limit_req`/`limit_conn` 阈值要结合 agent 上报并发(现场 14+ 采集机 + 批量心跳)压测后定,**别设太低误伤正常上报**;建议先 `limit_req ... burst=N nodelay` 观察。
3. 整改后用 `nginx -t` 校验 + 灰度,避免影响 agent 入口(17000)与 443 业务。
4. 若走容器:改 `etc/nginx/nginx.conf` 后 `docker exec o9e-nginx nginx -s reload` 或重启容器。

## 五、处置与归档
- 本核查为**配置审核**,未改动任何运行配置。
- 整改项建议纳入 `docs/security-backlog.md` 一并跟踪;是否整改、整改到什么程度(全过 vs 只补高价值项)由客户等保要求决定。
