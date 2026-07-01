# o9e 单机部署仓库

基于 n9e(夜莺)的 **单机 docker-compose 部署方案**,独立部署仓库。
现场只需 `git clone` 本仓库,镜像从 Docker Hub 拉取(`fuqiangleon/o9e`),
**不需要源码、不在现场编译**。后续更新一条 `git pull` 即可。

8 类服务、共 11 个容器:`mysql / redis / victoriametrics / scanopy(3 容器)/ topo-studio / elasticsearch / logstash / n9e / nginx`。
被监控主机的 `categraf` agent **不在 compose 内**,走 n9e 后台的
"配置中心 → 装机令牌(EnrollToken)" 装机。

> 镜像怎么来的:由 [OneStar-Projects/n9e](https://github.com/OneStar-Projects/n9e) monorepo
> 的 `scripts/build-image.sh` 编译(`CGO_ENABLED=0` 静态 + 前端 statik 嵌入)并 push 到
> Docker Hub。本仓库只管"怎么部署",不管"怎么 build"。

## 前置依赖

- Docker 24+,docker compose v2
  - 银河麒麟 V10 (x86_64) 空机器可一键装:`sudo ./install-docker-kylin.sh`
    (装 Docker CE 26.1.2 + compose 插件 + 国内镜像加速,详见脚本头部说明)
- 宿主可用内存 **≥ 8 GB**(含 ES+Logstash 的 JVM heap;不装日志监控可 ≥4 GB),磁盘 ≥ 20 GB
- 能访问 Docker Hub(或配好镜像加速)拉 `fuqiangleon/o9e` 及中间件镜像
- **日志监控(ES/Logstash)额外要求**:
  - 宿主内核 `vm.max_map_count ≥ 262144`(ES 硬性要求;`init-env.sh` 会尝试自动设,免密 sudo 不可用时按它打印的命令手动设)
  - 能拉 `docker.elastic.co` 的 ES/Logstash 镜像(1ms 不代理该源,经代理出网的机器需 gost 能到 docker.elastic.co)

## 首次部署

> 本机若必须经代理才能出网:装 Docker 用 `sudo USE_PROXY=1 ./install-docker-kylin.sh`
> (详见脚本头部)。镜像拉取走 daemon.json 的国内加速器(1ms)。

**严格按顺序执行**,SCANOPY_TOKEN 必须在服务起来后才能生成:

```bash
git clone git@github.com:OneStar-Projects/o9e-deploy.git
cd o9e-deploy

# 1. 初始化:生成 .env(强随机密码 + TOPO_API_TOKEN + MASTER_KEY)、预签 TLS 自签证书、
#    修正 bind 挂载文件权限。此步 SCANOPY_TOKEN 故意留空(第 4 步才生成)。
./init-env.sh
#    想用真证书:把 fullchain.pem / privkey.pem 放进 etc/tls/ 覆盖自签的即可。

# 2. 拉镜像(走 1ms 加速器)
docker compose pull

# 3. 启动全栈(9 个容器)
docker compose up -d
docker compose ps                  # 各服务应逐步 healthy
#    ⚠ 此时 topo-studio 报 "Not authenticated"、scanopy 拓扑页降级 —— 正常,
#       因为 SCANOPY_TOKEN 还没生成,下一步解决。

# 4. 生成 SCANOPY_TOKEN:调 scanopy API 创建并启用 User API Key,写回 .env,
#    并 up -d 重建 n9e + topo-studio 注入新 token(宿主需装 jq)。
./scanopy-bootstrap.sh

# 5. 锁定 scanopy 注册(强烈建议)— 防止任何人自助注册新组织/账号。
#    之后新用户只能通过 admin 的 POST /api/v1/invites 邀请加入现 org。
./scanopy-lock-registration.sh

# 6. 看 n9e 日志确认就绪
docker compose logs -f n9e
```

浏览器打开 `https://${N9E_DOMAIN}/`(把 `${N9E_DOMAIN}` 替换为 `.env` 设的值)。
默认账号 `root` / `root.2020`(首次登录强制改密)。

### 两个 token(易混,务必分清)

| token | 用于哪条鉴权链路 | 谁生成 |
|---|---|---|
| `SCANOPY_TOKEN` | n9e→scanopy **和** topo-studio→scanopy(消费者向 scanopy 鉴权) | `scanopy-bootstrap.sh` 调 scanopy API 创建,写回 `.env` |
| `TOPO_API_TOKEN` | n9e→topo-studio(n9e 向 topo-studio 鉴权) | `init-env.sh` 自动生成 |

> 改了 `.env` 里的 token 后,消费它的容器必须用 **`docker compose up -d <svc>` 重建**才生效
> —— `docker compose restart` 不重新注入 env(容器保留创建时的旧值)。

## 现场更新(本仓库的核心用途)

部署配置(compose/nginx/initsql/脚本)有变更时:

```bash
git pull                           # 拉本仓库最新部署配置
docker compose pull                # 拉最新镜像(若 .env 的 O9E_TAG 指向新版本)
docker compose up -d               # 滚动应用变更,数据卷不动
```

只想升级 n9e 镜像、中间件不动:

```bash
$EDITOR .env                       # 改 O9E_TAG=1.2.3 之类的版本(默认 latest)
docker compose pull n9e
docker compose up -d n9e
docker compose logs -f n9e
```

> `O9E_TAG` 是 Docker Hub 上 `fuqiangleon/o9e` 的镜像 tag。回滚:把 `.env` 改回旧 tag
> 再 `docker compose pull n9e && docker compose up -d n9e`。

## 备份

```bash
# MySQL 全量
docker compose exec mysql sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" \
    --single-transaction --routines n9e_v6' > backup-$(date +%F).sql

# VM 快照(写入到 victoriametrics 的 /vm-data/snapshots)
docker compose exec victoriametrics wget -qO- http://127.0.0.1:8428/snapshot/create
```

Redis 是缓存 + cfgsync 临时态,可不备份。

## 端口暴露

| 端口 | 宿主 | 容器 | 用途 |
|------|:---:|------|------|
| 80 | ✓ | nginx | HTTP → 301 → HTTPS |
| 443 | ✓ | nginx | 业务 + 前端(TLS) |
| 20090 | 可选 | nginx (stream) | ibex RPC;categraf 仅内网时建议改 `127.0.0.1:20090:20090` |
| 17000 | ✗ | n9e | 内部 |
| 8428 | ✗ | victoriametrics | 内部 |
| 3306 | ✗ | mysql | 内部 |
| 6379 | ✗ | redis | 内部 |
| 5044/udp | ✓ | logstash | **NetFlow 入口**;远端 agent 的 nprobe 送到此(`NETFLOW_PORT` 可改) |
| 9200 | ✗ | elasticsearch | 内部(n9e/logstash 走 docker 网络访问) |

## 给被监控主机装 categraf

n9e 起来后,登录后台 → **配置中心 → 装机令牌**,生成一次性 EnrollToken,
在目标主机执行:

```bash
curl -fsSL https://${N9E_DOMAIN}/api/n9e/agent-install/categraf.sh \
    | sudo IDENT=$(hostname) ENROLL_TOKEN=<token> bash
```

脚本会:下载 categraf 二进制 → 注册 systemd → 上报 host_state 到 n9e → 建立 binding。

## 日志监控(Elasticsearch + Logstash)

链路:**agent 的 `nprobe`(NetFlow)→ 部署机 `logstash:5044/udp` → `elasticsearch` → n9e「日志探索」查 `netflow-*`**。

镜像走 `docker.elastic.co`(1ms 不代理),版本由 `.env` 的 `ES_VERSION` 控制;heap 由 `ES_HEAP_SIZE`/`LS_HEAP_SIZE` 控制。`ELASTIC_PASSWORD` 由 `init-env.sh` 生成。

**1. 部署侧**:`init-env.sh` + `docker compose up -d` 会自动带起 elasticsearch/logstash(前提:`vm.max_map_count≥262144`、gost 能到 docker.elastic.co)。单验证:
```bash
docker compose up -d elasticsearch logstash
docker compose ps                    # 两者 healthy
docker exec o9e-elasticsearch curl -s -u elastic:"$ELASTIC_PASSWORD" localhost:9200/_cluster/health
```

**2. agent 侧开 NetFlow**:装机 answers 里设(见 monorepo `agents/n9e-agents`):
```
NPROBE_ENABLE=true
NPROBE_INTERFACE=<采集网卡,如 enp2s0>
NPROBE_COLLECTOR=<部署机IP>:5044     # 指向本部署机 logstash 的 NetFlow 入口
```

**3. n9e 加 ES 数据源**(手动,一次性):登录后台 → **数据源管理 → 新增 Elasticsearch**:
- 地址 `http://elasticsearch:9200`(n9e 与 ES 同 docker 网络,用服务名)
- 账号 `elastic` / 密码 = `.env` 的 `ELASTIC_PASSWORD`
- 之后「日志探索」选该数据源 + 索引 `netflow-*` 即可查流量日志。

> 只收 NetFlow。要接主机/应用日志(syslog/filebeat),在 `etc/logstash/pipeline/` 再加 input/pipeline。

## 故障排查

```bash
# 1. 看各服务 health
docker compose ps

# 2. mysql 没起来,看 init
docker compose logs mysql | tail -50

# 3. n9e 起来但报 DB connect refused
docker compose exec n9e sh -c 'env | grep N9E_'   # 确认密码注入
docker compose exec n9e cat /app/etc/config.toml | grep -E "DSN|Address"

# 4. nginx 502
docker compose exec nginx sh -c 'wget -qO- http://n9e:17000/api/n9e/version'

# 5. 完全重来(会清数据!)
docker compose down -v
```

## 目录结构

~~~
o9e-deploy/
├── install-docker-kylin.sh      # 麒麟 V10 空机器一键装 Docker(装机前置)
├── init-env.sh                  # 生成 .env(强随机密码 + TOPO_API_TOKEN + ELASTIC_PASSWORD)+ 预签 TLS 证书 + 修正挂载权限 + 设 vm.max_map_count
├── scanopy-bootstrap.sh         # 部署后 setup scanopy + 写回 SCANOPY_TOKEN + 重建 n9e/topo-studio
├── scanopy-lock-registration.sh # 锁定 scanopy 注册
├── docker-compose.yaml          # 11 容器编排(n9e/topo-studio 走 fuqiangleon/o9e;ES/Logstash 走 docker.elastic.co;纯 pull)
├── .env.example
├── etc/
│   ├── o9e/config.toml.tpl      # n9e 配置模板(entrypoint envsubst 渲染)
│   ├── nginx/{nginx.conf, conf.d/n9e.conf, auto-cert.sh}
│   ├── mysql/my.cnf
│   ├── logstash/{config/logstash.yml, pipeline/netflow.conf}  # NetFlow → ES 管道
│   └── tls/                     ← 真证书放这;留空则 init-env.sh 预签自签证书(容器内无法联网装 openssl 自签)
├── initsql/                     ← 上游 schema 真目录(自包含)
└── initsql-extra/               ← fork 的增量 SQL
~~~
