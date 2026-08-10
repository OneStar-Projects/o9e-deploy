# DeepFlow server 部署(采集机)

n9e「业务服务」拓扑(`application_map`)的**数据源头**。这是一套**独立 docker-compose 栈**,
跑在**采集机**上(和 n9e 管理面 / o9e-deploy 主栈分离,通常不是同一台),与本机的 `deepflow-agent`
配套:agent 抓流量 → deepflow-server 聚合出 `flow_metrics.application_map.1m` → 通过 server.yaml 的
prometheus exporter remote-write 到 n9e → 前端查出拓扑。

> 本目录是从社区版 DeepFlow CE v7.1 all-in-one docker-compose vendored 而来,只做了两处必要改动:
> ① 端口预置成 17001/17002(见下文「端口对齐」);② `mysql/init.sql` 把未渲染的 helm 模板
> `{{ tpl $.Values.password . }}` 渲染成实际口令 `deepflow`(否则全新首启会把 root 口令设成字面
> 模板串,server 连不上 MySQL)。其余 clickhouse/grafana/app 配置均 1:1 照抄。

## 组件

`mysql / clickhouse / deepflow-server / deepflow-app`(4 容器)。镜像走阿里云香港 registry
(`registry.cn-hongkong.aliyuncs.com/deepflow-ce/*`)。

> 上游 all-in-one 自带的 grafana(+3 个 init 容器)已移除:最终消费端是 n9e「业务服务」拓扑,
> 不需要 deepflow 自带看板。`mysql` 保留——它是 deepflow-server 的元数据库(存 agent-group
> 端口等配置),`init.sql` 把 root 改成 mysql_native_password 认证供 server 连接,勿删。

## 部署步骤

```bash
cd deepflow
cp .env.example .env
$EDITOR .env            # 改 NODE_IP_FOR_DEEPFLOW = 本采集机 IP;
                        # 改 N9E_REMOTE_WRITE   = http://<你的 n9e IP>:17000/prometheus/v1/write;
                        # 确认 DEEPFLOW_VERSION

# 从 server.yaml.tmpl 渲染出 server.yaml(把 .env 的 N9E_REMOTE_WRITE 写进出口)。
# server.yaml 是生成物(.gitignore),不再手改、不会被 checkout 打回。必须在 up 之前跑。
#   若内网连不上公网 NTP:先改模板 $EDITOR common/config/deepflow-server/server.yaml.tmpl
#   把 trisolaris.chrony.host 改成内网 NTP(改 .tmpl 而非生成的 server.yaml,否则重渲染会丢),再:
./render-config.sh

docker compose pull
docker compose up -d
docker compose ps       # 各容器逐步 healthy

# 起栈后跑一次:装 deepflow-ctl + 建组/对齐端口/建 agent_sync 域(三件事,见下「做的三件事」)
./deepflow-provision.sh
```

deepflow 侧无本地 UI(grafana 已移除);数据是否通过 `deepflow-ctl agent list` 与 n9e 拓扑验证。

> ⚠ **本机(采集机自身)那个 deepflow-agent 的 `controller-ips` 要填本机真实网卡 IP,别用 `127.0.0.1`**。
> vtap 身份 =(ctrl_ip, ctrl_mac),走 loopback 拿到的 ctrl_mac 是 `00:00:00:00:00:00`,配不上任何
> vinterface → 这台本机 agent 单独注册不进(日志 `vinterface(mac=00:00:00:00:00:00) without finding data`)。
> 填 `NODE_IP_FOR_DEEPFLOW` 同一个真实 IP 即可。别的机器的 agent 本就填采集机 IP,不受影响。

> **重装/重置**:数据落在宿主 `/opt/deepflow/{mysql,clickhouse,clickhouse_storage}`(compose 里 bind mount)。
> `init.sql` 只在 **mysql 卷为空** 时首启执行一次;若这台跑过 deepflow 或想重置 root 口令,须先
> `docker compose down && sudo rm -rf /opt/deepflow/mysql` 再 `up -d`,否则 `init.sql` 不生效、server 连不上库。

## `deepflow-provision.sh` 做的三件事(port / group / domain)

一台全新社区版 deepflow-server 起来后,还差三处配置才能收本项目 agent 的数据。脚本全做了、且 idempotent:

### A. agent-group(采集器组)

deepflow 用「组」归类 agent,端口等配置挂在组上。agent 包在 `/etc/deepflow-agent.yaml` 里
`vtap-group-id-request: g-Ir1cV5gtqA` 请求加入固定组;组不存在则掉进内置 `default` 组、拿不到端口配置。

脚本用 **`deepflow-ctl agent-group create legacy-host --id g-Ir1cV5gtqA`** 建出**指定 id** 的组
(`--id` 须 `g-`+10 位字母数字),与 agent 包烘的 `DEEPFLOW_AGENT_GROUP_ID` 一一对上——所以新机也能直接对齐,
不用再改 agent 包。想换 id:`AGENT_GROUP_ID=g-xxx AGENT_GROUP_NAME=xxx ./deepflow-provision.sh` + agent 包同步改。

### B. agent-group-config(端口对齐 + 本机资源上报,核心坑)

社区版 deepflow-server **默认对 agent 通告控制口 30035 / 数据口 30033**,而 agent 包烘的是 **17001**
(n9e Jenkins ① 的 `DEEPFLOW_CONTROLLER_PORT`)。**四处必须一致**,缺一 agent 必报
`CONTROLLER_SOCKET_ERROR` / `ANALYZER_SOCKET_ERROR`、n9e「业务服务」拓扑无数据:

| # | 位置 | 值 | 谁负责 |
|---|---|---|---|
| 1 | 本目录 `docker-compose.yaml` 的 `ports:` | `17001:20035`(控制)`17002:20033`(数据) | 已就位 |
| 2 | **agent-group-config**(存 server MySQL) | `proxy_controller_port:17001` `ingester_port:17002` | **本脚本 B** |
| 3 | agent 本机 `/etc/deepflow-agent.yaml` | `controller-port:17001` | agent 包 install.sh |
| 4 | `server.yaml` 的 agent 侧端口 | **不用动**(group-config 覆盖优先) | — |
| 5 | `server.yaml` 的 ingester 出口(→ n9e) | `N9E_REMOTE_WRITE` | `render-config.sh`(装机前渲染) |

第 2 处对应的 group-config yaml(脚本写进去、`deepflow-ctl agent-group-config list <gid> -o yaml` 回读一致):

```yaml
global:
  communication:
    proxy_controller_port: 17001
    ingester_port: 17002
inputs:
  resources:
    workload_resource_sync_enabled: true    # 见下,无云平台部署的命门
```

**第 2 处是真正告诉 agent 用哪口的地方**——只改 compose+agent 不改它,server 仍通告默认 30035/30033,
agent 被引去连没发布的口 → 断链。agent-group-config 走 controller HTTP api(30417,改控制口它不变),
所以脚本无需 `--rpc-port`。

**`workload_resource_sync_enabled: true` 比端口更致命**(默认 `false`):本套是纯 agent、无 K8s/云平台,
false 时 agent 不上报本机运行环境 → `agent_sync` 域(下文 C)拿不到 VM,server 日志刷
`invalid vm count (0)` / `domain is not verified, does nothing` → host_device/vinterface 一直空 →
**任何 agent 都注册不进 vtap、拓扑全空**。开启后 server 据 agent 上报抽象出一个 CHOST,死锁才解。
> 脚本对全新组用 `agent-group-config **create**`(旧版误用 `update`,对空组会静默 exit-0 空跑、把整份
> 配置吞掉,端口和 workload sync 都没写进去——这正是"脚本跑完却收不到数据"的老坑)。

> **换端口**:改本目录 `docker-compose.yaml` 的 `ports:` 左值 + `PROXY_CONTROLLER_PORT=/INGESTER_PORT=`
> 环境跑 `deepflow-provision.sh` + agent 包对应改;三处一致即可。别把 `17001:20035`/`17002:20033`
> 的左右接反(容器内 20035=控制/20033=数据是固定的),否则 server 报 `header type 42 is invalid`。

> **⚠ VIP/NAT 场景(agent 够不着 server 网卡 IP,只能走 VIP)**:server 默认对 agent 通告
> `NODE_IP_FOR_DEEPFLOW`(本机网卡 IP);远端 agent 到不了这个 IP 就会死循环——注册进来是 NORMAL,
> 但 `l7_flow_log`/`application_map` 恒空,agent 日志刷 `Dial server(<NODE_IP>:17001) failed: transport error`
> / `grpc client not connected`。解法:跑脚本时设 **`ADVERTISE_IP=<VIP>`**,把 group-config 的
> `proxy_controller_ip/ingester_ip` 覆盖成 VIP,让 server 改通告 VIP:
> ```bash
> ADVERTISE_IP=10.77.64.56 ./deepflow-provision.sh    # VIP 须同时转发 17001+17002
> ```
> `NODE_IP_FOR_DEEPFLOW` 仍保持真实网卡 IP 不动(server 内部 genesis 自寻址要用它),两键解耦不冲突。
> 本机(采集机自身)那个 agent 走 hairpin 回自己 VIP 即可,与远端共用同一组配置,无需单独处理;
> 但它的 `controller-ips`(bootstrap)仍填本机真实 IP,别用 `127.0.0.1`(见上文 zero-MAC 坑)。

### C. domain(agent_sync 资源域)

纯 agent 部署(无 K8s/云平台)靠 **`agent_sync`** 域把 agent 上报的 CHOST/进程注册成资源,
拓扑才有主机/服务标签。脚本用 `deepflow-ctl domain create -f` 建:

```yaml
name: agent_sync
type: agent_sync
config:
  region_uuid: ffffffff-ffff-ffff-ffff-ffffffffffff   # deepflow 默认区域,固定
  sync_timer: 60
```

已有该域时脚本自动跳过;也可 `SKIP_DOMAIN=1 ./deepflow-provision.sh` 强制跳过。

> **deepflow-ctl 从哪来**:脚本默认从 aliyun OSS 按 `DEEPFLOW_VERSION` 下 `deepflow-ctl`(~71MB,
> 故意不入 git;采集机既能拉几百 MB 镜像就能下)。**离线现场**:把对应架构的 `deepflow-ctl` 二进制
> 预放到本目录(`deepflow/deepflow-ctl`),脚本优先用它、不联网(该路径已 gitignore,不会误提交)。

## 端口暴露

| 宿主端口 | 容器 | 用途 |
|---|---|---|
| `17001` | deepflow-server 20035 | 控制面 grpc(agent 拨) |
| `17002` | deepflow-server 20033 | 数据面 ingester(agent 写数据) |
| `30417` | deepflow-server 20417 | controller http api(deepflow-ctl 用) |
| `20416` | deepflow-server | querier |
| `20418/20419` | deepflow-app/server | app tracing / profile |

## 故障排查

```bash
# agent 状态(EXCEPTIONS 空 + STATE=NORMAL 才对;改控制口后带 --rpc-port 17001)
deepflow-ctl --rpc-port 17001 agent list

# 回读 group-config(确认第 2 处已落库:端口 + workload sync)
deepflow-ctl --api-port 30417 agent-group-config list g-Ir1cV5gtqA -o yaml \
  | grep -E "controller_port|ingester_port|workload_resource_sync_enabled"

# agent 注册不进 / 拓扑空,看 server 是不是死在没 VM(workload sync 没开的典型症状)
docker logs deepflow-server 2>&1 | grep -Ei "invalid vm count|not verified"

# server 有没有因端口接反报错
docker logs deepflow-server | grep -i "header type 42"

# agent 本地日志(采集机)
tail -f /var/log/deepflow-agent/deepflow-agent.log | grep -E "succeed|reset|17001|17002"

# n9e 侧是否收到序列(dsId 按现场,query 走 n9e proxy)
curl -sk 'https://<n9e>/api/n9e/proxy/1/api/v1/query' \
  --data-urlencode 'query=count(request{datasource="flow_metrics.application_map.1m"})'
```

> 前端查 `application_map.1m` 走 `avg_over_time[5m]`,链路断 >5min 页面就空。
> 改端口/配置后要 `docker compose up -d deepflow-server`(recreate;`restart` 不重读 `ports:`)。
