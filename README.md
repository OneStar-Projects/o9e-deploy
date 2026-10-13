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
>
> scanopy 的 `server` + `daemon` 用 **fork 版**(`fuqiangleon/scanopy-{server,daemon}`,含 SNMP
> 存活兜底改动),由 fork 仓库根的 `build-images.sh` 构建推送。更新只需改 `.env` 的 `SCANOPY_TAG`
> (默认 latest)后:`docker compose pull scanopy scanopy-daemon && docker compose up -d scanopy scanopy-daemon`。

配置中心升级需同时发布服务镜像和主机 Agent 安装包，详见 [配置中心升级说明](docs/cfgsync-upgrade.md)。

自然语言查询与运维周报开关见 [部署说明](docs/ai-analysis-deployment.md)。

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

# 1. 初始化:生成 .env(各账号互不相同的强随机口令 + admin 初始密码 + TOPO_API_TOKEN + MASTER_KEY)、
#    预签 TLS 自签证书、修正 bind 挂载文件权限。此步 SCANOPY_TOKEN 故意留空(第 4 步才生成)。
#    ⚠ 不要手改成简单口令;.env 里残留 please-change-me 时 MySQL 初始化会拒绝执行。
./init-env.sh
#    想用真证书:把 fullchain.pem / privkey.pem 放进 etc/tls/ 覆盖自签的即可。

# 2. 拉镜像(走 1ms 加速器)
docker compose pull

# 3. 启动服务
#    主平台 9 个容器(不含日志监控 ES/logstash;2 核等小规格主机不要起 ES):
docker compose up -d mysql redis victoriametrics scanopy-postgres scanopy-daemon scanopy n9e topo-studio nginx
#    需要日志监控时再加:docker compose up -d elasticsearch logstash
docker compose ps                  # 各服务应逐步 healthy
#    首次启动 MySQL 初始化 + n9e 建表需数分钟(2 核实测约 4 分钟),期间 n9e 显示 starting 属正常。
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

# 7. 部署后安全自检(见下文「部署后安全自检」),全部通过再交付
```

浏览器打开 `https://${N9E_DOMAIN}/`(把 `${N9E_DOMAIN}` 替换为 `.env` 设的值)。
管理员账号 `admin`,初始密码是 `.env` 里的 `N9E_ADMIN_PASSWORD`(20 位,含符号;上游默认密码已在初始化时替换)。
n9e **不会强制改密**,交付前按需在页面修改,任何账号都不要用默认/简单密码(客户安全审计会扫弱口令)。

**使用客户提供的数据库**(MySQL / PostgreSQL / 金仓 PG 兼容模式):不启动内置 MySQL,由 DBA 建库建账号后执行
`./external-db-init.sh`,步骤与要求见 [`docs/external-db.md`](docs/external-db.md)。

全新部署**没有时序库数据源**:用 `dashboards/import-dashboards.sh` 导入仪表盘时会自动创建,
或在页面「数据源」中添加 `http://victoriametrics:8428`。

### 数据库账号(2026-10 安全加固)

| 账号 | 用途 | 权限 |
|---|---|---|
| `root@localhost` | 运维:备份、升级、修复。只能在容器内经 socket 登录(`docker compose exec mysql ...`) | 全部 |
| `n9e_app` | n9e 连库 | 仅 `n9e_v6` |
| `topo_app` | topo-studio 连库 | 仅 `topo_studio` |

新部署由 `init-env.sh` 各自生成口令、`initsql-extra/f-app-users.sh` 建账号,无需手工操作。
**已有部署升级**(初始化脚本不会再跑,按顺序手工做一次;完整升级流程见下文「已有部署的安全加固升级」):

```bash
# 1. .env:N9E_DB_USER=n9e_app,新增 TOPO_DB_USER=topo_app;N9E_DB_PASSWORD / TOPO_DB_PASSWORD 各生成新口令
# 2. mysql 带上新环境变量重建,再建业务账号(含 topo_studio 库)
docker compose up -d --no-deps mysql
docker exec -i o9e-mysql sh < initsql-extra/f-app-users.sh
# 3. n9e / topo-studio 切到新账号(中断约 30~60 秒)
docker compose up -d --no-deps n9e topo-studio
# 4. 确认两者正常后,删掉可远程登录的 root
docker exec -i -e DROP_REMOTE_ROOT=1 o9e-mysql sh < initsql-extra/f-app-users.sh
```

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

## 已有部署的安全加固升级(2026-10)

适用于 2026-10 之前部署、仍用 root 连库的环境。**6456 已按此流程实测通过。**
中断时间:MySQL 重建约 30 秒,应用切换约 1 分钟。

> 几个坑(都踩过):
> - 小规格主机别直接 `docker compose up -d`(会把 ES/logstash 一起拉起),一律写明服务名;
> - 停服务后恢复用 `docker compose up -d --no-recreate <服务名…>`,**不要用 `docker compose start`**(不等依赖健康,只起来一半);
> - `git pull` 会抹掉文件的 o+r,MySQL 读不到 `my.cnf` 时**静默忽略**,所以每次拉代码后都要跑 `./init-env.sh` 修权限。

```bash
cd ~/o9e-deploy
# 0. 备份(.env + MySQL)
B=~/o9e-backup-$(date +%F); mkdir -p $B && chmod 700 $B && cp -p .env $B/env
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot \
    --single-transaction --routines --databases n9e_v6' | gzip > $B/mysql.sql.gz

# 1. 拉代码并修正挂载权限(.env 已存在时只修权限、提示缺失变量,不会覆盖口令)
git pull && ./init-env.sh

# 2. .env 改用业务账号,口令为 32 位随机串且与 root 不同
gen(){ head -c 4096 /dev/urandom | LC_ALL=C tr -dc A-Za-z0-9 | head -c 32; }
sed -i "s/^N9E_DB_USER=.*/N9E_DB_USER=n9e_app/; s/^N9E_DB_PASSWORD=.*/N9E_DB_PASSWORD=$(gen)/" .env
grep -q '^TOPO_DB_USER=' .env     || echo 'TOPO_DB_USER=topo_app' >> .env
grep -q '^TOPO_DB_PASSWORD=' .env || echo "TOPO_DB_PASSWORD=$(gen)" >> .env

# 3. MySQL 带新配置重建(my.cnf / 防暴力破解 / socket 健康检查),再建业务账号与 topo_studio 库
docker compose up -d --no-deps mysql
docker exec -i o9e-mysql sh < initsql-extra/f-app-users.sh

# 4. 应用切到新账号,nginx / scanopy 应用新的端口绑定
docker compose up -d --no-deps n9e topo-studio nginx scanopy

# 5. 确认 n9e、topo-studio 正常(日志无 Access denied,topo-studio 日志为 store=mysql)后,删除可远程登录的 root
docker exec -i -e DROP_REMOTE_ROOT=1 o9e-mysql sh < initsql-extra/f-app-users.sh

# 6. 平台账号:在页面把 admin 及所有共用/简单密码的账号改成复杂密码,删除测试账号

# 7. 若部署了 DeepFlow:生成随机口令并渲染配置;已有数据目录需先在库内改口令(见 deepflow/README.md)
(cd deepflow && ./render-config.sh)

# 8. 执行下文「部署后安全自检」
```

## 部署后安全自检

在部署目录执行,全部符合预期再交付:

```bash
# 1. 数据库账号 —— 预期只有 root@localhost、n9e_app@%、topo_app@%
docker compose exec -T mysql sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; mysql -uroot -N -e \
  "SELECT CONCAT(user,\"@\",host) FROM mysql.user WHERE user NOT LIKE \"mysql.%\""'

# 2. my.cnf 与防暴力破解 —— 预期 100000 和 ACTIVE
docker compose exec -T mysql sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; mysql -uroot -N -e \
  "SELECT @@max_connect_errors; SELECT plugin_status FROM information_schema.plugins WHERE plugin_name=\"CONNECTION_CONTROL\""'

# 3. root 不能经网络登录 —— 预期 Access denied
docker compose exec -T mysql sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; mysql -uroot -h$(hostname -i) -e "select 1"'

# 4. 对外端口 —— 预期只有 22、443、17000(启用日志监控时另有 5044/udp,部署 DeepFlow 时另有 17001/17002);
#    另会看到 60073(scanopy-daemon 用宿主网络、默认监听 0.0.0.0),对外不需要,收敛办法见「端口暴露」
ss -lntH | awk '{print $4}' | grep -vE '^(127\.|\[::1\])' | sed -E 's/.*://' | sort -nu

# 5. 部署目录无弱口令文本 —— 预期无输出(模式里用字符类,避免本文件自身含弱口令字面量)
grep -rInE --exclude-dir=.git -i \
  "(password|passwd|pwd|secret|identified by)[a-z_]*[\"']?[[:space:]]*[=:]?[[:space:]]*[\"']?(12345[6]|123[4]|ch[a]ngeme|r[o]ot\.2020|passw[o]rd|adm[i]n)[\"']?([[:space:];,)]|$)" .

# 6. 17000 只放行 agent 接口 —— 预期 403(登录)和 200(心跳)
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:17000/api/n9e/auth/login -d '{}'
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:17000/v1/n9e/heartbeat -d '{}'

# 7. 平台登录 —— admin 用 .env 的 N9E_ADMIN_PASSWORD(或已改的新密码)能登录;页面「用户管理」无测试账号、无共用密码
```

未处理的安全事项与整改建议见 [`docs/security-backlog.md`](docs/security-backlog.md)。

## 备份

```bash
# MySQL 全量(root 只能容器内登录;口令经 MYSQL_PWD 传,不出现在进程参数里)
docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot \
    --single-transaction --routines --databases n9e_v6 topo_studio' | gzip > backup-$(date +%F).sql.gz
chmod 600 backup-*.sql.gz           # 备份含业务数据,勿留在共享目录

# VM 快照(写入到 victoriametrics 的 /vm-data/snapshots)
docker compose exec victoriametrics wget -qO- http://127.0.0.1:8428/snapshot/create
```

Redis 是缓存 + cfgsync 临时态,可不备份。

## 端口暴露

原则:**对外只开必要端口**。其余默认只绑 127.0.0.1,确需对外时在 `.env` 改对应的 `*_BIND=0.0.0.0`。

| 端口 | 默认绑定 | 容器 | 用途 |
|------|:---:|------|------|
| 443 | 对外 | nginx | Web 与 API(TLS)。用户只从这里访问 |
| 17000 | 对外 | nginx → n9e | agent 上报入口(明文 HTTP)。**只放行 agent 接口**(指标写入、心跳、配置同步),登录与管理 API 返回 403、只走 443。`AGENT_API_ENFORCE=0` 可临时只记录不拦截;日志 `logs/nginx/agent-api.log` |
| 80 | 127.0.0.1(`HTTP_BIND`) | nginx | 仅做跳转 HTTPS |
| 20090 | 127.0.0.1(`IBEX_RPC_BIND`) | nginx (stream) | ibex 远程执行;agent 未启用 |
| 60072 | 127.0.0.1(`SCANOPY_BIND`) | scanopy | 拓扑发现**服务端**。本机 daemon 走 127.0.0.1;**其他机器的 daemon 主动连这个端口**领任务、交结果,有远端 daemon 时才放开(见下文「远端 scanopy daemon」) |
| 60073 | 0.0.0.0(scanopy 默认,未收敛) | scanopy-daemon(宿主网络) | daemon 自身的管理接口。默认「daemon 主动拉任务」模式下**只有本机健康检查用,对外不需要**,其他机器的 daemon 也不连它。daemon 以特权运行并挂载 docker.sock,建议收敛,见表后说明 |
| 17001 / 17002 | 对外(仅部署 DeepFlow 时) | deepflow-server | DeepFlow 控制面 / 数据面(容器内 20035 / 20033),装了 deepflow-agent 的主机连 |
| 5044/udp | 对外(仅启用日志监控时) | logstash | NetFlow 入口(`NETFLOW_PORT`) |
| 8428 / 3306 / 6379 / 5432 / 9200 | 不映射 | VM / MySQL / Redis / PG / ES | 仅容器内部 |

> 宿主 firewalld 对 Docker 映射的端口**不生效**(Docker 自己的 DNAT 规则绕过它),
> 所以端口收敛必须靠上面的绑定地址,不能只改 firewalld。

**按场景需要对外开放的端口**(其余一律不开):

| 端口 | 何时需要 |
|------|------|
| 443 | 始终(Web、登录) |
| 17000 | 始终(agent 上报) |
| 17001、17002 | 部署 DeepFlow 时 |
| 5044/udp | 启用 NetFlow / 日志监控时 |
| 60072 | 接入其他机器的 scanopy daemon 时 |

60073 在任何场景下都不需要对外开放。

**收敛 60073**:scanopy-daemon 用宿主网络,不经 Docker 端口映射,所以上面「firewalld 不生效」的限制**不适用于它**,可直接用宿主防火墙拦掉外部访问;
也可以给 daemon 加环境变量 `SCANOPY_BIND_ADDRESS=127.0.0.1` 让它只监听本机(scanopy 支持此变量;本仓库 compose 尚未加,改动前需确认 daemon 处于默认的「daemon 主动拉任务」模式,否则服务端无法下发任务)。

**远端 scanopy daemon**(在其他采集机上扫描各自网段):

1. 用 `gen-scanopy-daemons.sh` 为每台采集机生成 daemon 配置,`SCANOPY_URL` 填 `http://<本机地址>:60072`
2. 本机 `.env` 把 `SCANOPY_BIND` 改为 `0.0.0.0`(或指定网卡地址)后 `docker compose up -d scanopy`
3. **只允许这些采集机访问 60072**:60072 是明文 HTTP(daemon 凭密钥接入);因它经 Docker 端口映射,firewalld 不生效,需在上游网络设备 / 安全组上限制来源
4. 采集机若经负载均衡 / VIP / NAT 访问本机,转发规则里也要加上 60072
5. 远端 daemon **不能**走 443 的 `/api/scanopy`:那条路径要求平台登录会话,是给浏览器用的

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

**4. 日志保留策略**(手动,一次性;不做则 ES 磁盘会被日志无限撑满):
```bash
./es-ilm-bootstrap.sh              # 默认保留 15 天,超期自动删
RETENTION_DAYS=30 ./es-ilm-bootstrap.sh   # 改保留天数重跑即可(幂等)
```
> 给 `netflow-*` 装 ILM 策略 + index template。前置:elasticsearch 已 healthy。

> 只收 NetFlow。要接主机/应用日志(syslog/filebeat),在 `etc/logstash/pipeline/` 再加 input/pipeline。

## DeepFlow(业务服务拓扑数据源)

n9e「业务服务」拓扑(`application_map`)的数据来自 **DeepFlow server**——一套**独立 compose 栈**,
跑在**采集机**上(不在本主栈内),与本机 `deepflow-agent` 配套,把聚合指标 remote-write 回 n9e。

部署见 [`deepflow/README.md`](deepflow/README.md)。要点:`cd deepflow && cp .env.example .env`
→ 改 `NODE_IP_FOR_DEEPFLOW` + `server.yaml` 的 exporter 上报地址 → `docker compose up -d`
→ **`./deepflow-provision.sh`**(装 deepflow-ctl + 建采集器组/对齐端口 17001/17002/建 agent_sync 资源域——
不做这步 agent 必报 SOCKET_ERROR、拓扑无数据)。

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
├── init-env.sh                  # 生成 .env(各账号互不相同的强随机口令 + admin 初始密码 + 令牌)+ 预签 TLS 证书 + 修正挂载权限 + 设 vm.max_map_count
├── scanopy-bootstrap.sh         # 部署后 setup scanopy + 写回 SCANOPY_TOKEN + 重建 n9e/topo-studio
├── scanopy-lock-registration.sh # 锁定 scanopy 注册
├── gen-scanopy-daemons.sh       # 为多台采集机批量签发 scanopy daemon + 生成各自 compose(可选)
├── es-ilm-bootstrap.sh          # ES ILM 保留策略:netflow-* 索引超期自动删(默认 15 天),防磁盘撑满
├── docker-compose.yaml          # 11 容器编排(n9e/topo-studio 走 fuqiangleon/o9e;ES/Logstash 走 docker.elastic.co;纯 pull)
├── .env.example
├── etc/
│   ├── o9e/config.toml.tpl      # n9e 配置模板(entrypoint envsubst 渲染)
│   ├── nginx/{nginx.conf, conf.d/n9e.conf, auto-cert.sh}
│   ├── mysql/my.cnf
│   ├── logstash/{config/logstash.yml, pipeline/netflow.conf}  # NetFlow → ES 管道
│   └── tls/                     ← 真证书放这;留空则 init-env.sh 预签自签证书(容器内无法联网装 openssl 自签)
├── initsql/                     ← 上游 schema 真目录(自包含;a-n9e.sql 的 admin 初始值已改为占位串,同步上游时保留)
├── initsql-extra/               ← fork 的增量 SQL + f-app-users.sh(建业务账号、替换 admin 初始密码)
├── docs/security-backlog.md     ← 安全问题清单(已处理 / 未处理)
├── docs/external-db.md          ← 使用外部数据库(MySQL / PostgreSQL / 金仓)的 DBA 要求与部署步骤
├── external-db-init.sh          ← 外部数据库首次初始化(按 DB_TYPE 适配)
├── initsql-pg/                  ← PostgreSQL / 金仓版初始化 SQL(外部 PG 库用)
└── deepflow/                    ← 独立 DeepFlow server 栈(采集机部署;业务服务拓扑数据源)
    ├── docker-compose.yaml      #   端口预置 17001/17002
    ├── .env.example
    ├── render-config.sh         #   生成库口令并渲染 server.yaml / init.sql(起栈前必跑)
    ├── common/config/           #   server/clickhouse/mysql/app 配置(vendored;口令为占位符)
    ├── deepflow-provision.sh    #   起栈后跑:装 deepflow-ctl + agent-group 端口对齐
    └── README.md                #   部署步骤 + 端口对齐坑
~~~
