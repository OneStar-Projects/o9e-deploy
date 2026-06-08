# n9e 配置模板。entrypoint 会把本文件经 envsubst 渲染为 config.toml。
# ⚠ n9e 的 TOML 加载是「整文件替换」,不是与 etc.default/config.toml 合并 —
#   tpl 没列的字段全部走 Go 零值(int=0, bool=false),会引发隐蔽 bug:
#   - JWTAuth.AccessExpired=0 → token 秒过期 → 登录回跳
#   - APIForAgent.Enable=false → agent 上报全部 401
# 所以本文件必须把所有「Enable=true / 关键阈值」完整列出。
# 修改密码/连接信息请改仓库根的 .env,然后 docker compose up -d n9e。

[Global]
RunMode = "release"

[Log]
Dir    = "logs"
Level  = "INFO"
Output = "stdout"

[HTTP]
Host = "0.0.0.0"
Port = 17000
PrintAccessLog = false
PProf          = false
ExposeMetrics  = true

# JWT token 有效期(分钟)。不写这一段时 n9e 用 Go int 零值,token 一签发就过期 → 登录回跳。
[HTTP.JWTAuth]
AccessExpired  = 1500     # access token 25 小时
RefreshExpired = 10080    # refresh token 7 天
RedisKeyPrefix = "/jwt/"

# agent 上报 API。缺这块默认 false → 所有 categraf 上报全 401。
[HTTP.APIForAgent]
Enable = true

# API token 鉴权(脚本/集成调 API 用)。
[HTTP.TokenAuth]
Enable = true

# RSA 加密登录密码。OpenRSA=false 时前端走明文(走 HTTPS 没问题)。
[HTTP.RSA]
OpenRSA = false

[DB]
DBType = "mysql"
DSN = "${N9E_DB_USER}:${N9E_DB_PASSWORD}@tcp(mysql:3306)/n9e_v6?charset=utf8mb4&parseTime=True&loc=Local"

[Redis]
Address  = "redis:6379"
Password = "${REDIS_PASSWORD}"
DB       = 0
UseTLS   = false
RedisType = "standalone"

[Center]
MetricsYamlFile = "/app/etc.default/metrics.yaml"
# Scanopy 反向代理 — n9e 把 /api/scanopy/* 转发到这里(scanopy 容器内部地址)
# 留空时 /api/scanopy/* 返回 503,前端拓扑页降级展示
ScanopyUrl   = "http://scanopy:60072"
ScanopyToken = "${SCANOPY_TOKEN:-}"

# 部分匿名查询路径(指标查询/告警详情)。缺这块默认 false → 未登录调 API 全 401。
[Center.AnonymousAccess]
PromQuerier = true
AlertDetail = true

[[Pushgw.Writers]]
Url = "http://victoriametrics:8428/api/v1/write"
Headers = ["X-From", "n9e"]

[Ibex]
Enable    = true
RPCListen = "0.0.0.0:20090"
