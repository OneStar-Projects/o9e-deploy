# Nginx 基线核查——需人工研判项说明（提交客户等保核查）

面向：客户等保核查/绿盟 RSAS 评估人员。
对应模板：Nginx 配置规范 (Linux)_S3A3G3（V6.0R04F02.0007，等保2.0 三级）。
系统 nginx 版本：**1.25**（容器 nginx:1.25-alpine）。

本次已按基线补齐绝大多数加固项（超时、并发限制、速率、自定义错误页、隐藏文件防护、日志、版本隐藏等）。以下 3 点因**模板规则与当前 nginx 版本/部署架构存在客观差异**，无法以"字面匹配"方式满足，申请**人工研判/合规例外**，并附我方等效实现证据。

---

## 项 11：`limit_zone` —— 指令已废弃，用等效的 `limit_conn_zone` 实现

- 模板检查：`grep limit_zone`。
- 客观情况：`limit_zone` 是 nginx **0.7–1.17 的旧指令，自 nginx 1.18 起已被移除**；当前运行版本 1.25 若写 `limit_zone` 会导致 `nginx -t` 失败、服务无法启动。
- 我方实现（等效且更规范）：已配置其官方替代指令
  ```
  limit_conn_zone $binary_remote_addr zone=perip:10m;   # 定义限制区域
  limit_conn      perip 200;                             # 按源 IP 限制并发
  ```
  即"按客户端 IP 限制并发连接数"的控制目标**已达成**，只是指令名随版本更新。
- 申请：对项 11 按**等效满足**人工通过（证据见上述配置）。

## 项 13：隐藏文件防护 —— 模板正则过时，已用有效写法实现

- 模板检查：`grep "location\s*~\*\s*^\.+"`（即期望出现 `location ~* ^\.`）。
- 客观情况：nginx 的 `location` 匹配的是 **URI（始终以 `/` 开头）**，正则 `^\.`（以点开头）**永远不可能命中**，该模板正则本身不是有效的防护写法。
- 我方实现（有效）：
  ```
  location ~ /\.(?!well-known) { deny all; }
  ```
  即"拒绝访问任何以点开头的隐藏文件/目录（放行 ACME 的 /.well-known）"，**实测 `GET /.env` 返回 403**，防护目标达成。
- 申请：对项 13 按**有效实现**人工通过（实测证据：`.env`→403）。

## 扫描范围说明（影响项 13、项 4/5 的检出）

- RSAS 脚本是对**单个 `nginx.conf` 文件做 grep，不跟随 `include`**。本部署按 nginx 最佳实践将配置拆分为：
  - `nginx.conf`（http 全局：日志、超时、`server_tokens off`、`limit_conn_zone`、`limit_rate` 等）
  - `conf.d/n9e.conf`（443 虚拟主机:`location`、`error_page`、隐藏文件 `deny`、访问控制等——这些指令**语法上只能位于 server/location 块**，不能写在 http 全局）
- 因此 `location`（项 13）、server 内的 `allow/deny`（项 4/5）、`error_page`（项 14）等**必然在 `conf.d/n9e.conf` 中**。
- 申请：核查时请将扫描目标指向**完整合并配置**（可用 `nginx -T` 导出的完整配置），或将 `conf.d/n9e.conf` 一并纳入扫描，否则会误判为"未配置"。

---

## 附：本次已补齐并通过的加固项（供核对）
http 全局（`nginx.conf`）：`client_body_timeout`/`client_header_timeout`/`send_timeout` 60s、`limit_conn_zone`、`limit_rate`、`error_log`、`access_log`、`log_format`、`server_tokens off`、`keepalive_timeout`、TLSv1.2/1.3、安全响应头。
443 虚拟主机（`conf.d/n9e.conf`）：`limit_conn`、`error_page`、隐藏文件 `deny`。
> 说明：对外 17000 为采集 agent 上报专用入口（已按路径白名单放行、其余 403），**未施加并发/速率限制以避免误伤正常上报**；人访问面（443）已施加限制。
