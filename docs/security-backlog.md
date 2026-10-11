# 安全问题清单(2026-10 客户安全审计后)

起因:客户安全审计扫出 `o9e-mysql` 的 root 存在弱口令(`root@127.0.0.1`,源自上游初始化 SQL),随即删除了 ecs1 上的平台容器。
本文记录已处理项与未处理项,作为后续整改的依据。**任何口令只记录位置与类别,不写入本文。**

## 一、已处理

| # | 问题 | 处理 | 生效范围 |
|---|---|---|---|
| D1 | MySQL `root@127.0.0.1` 默认弱口令 | 删除上游建号语句;已有部署改为强口令后删除;root 仅保留 `root@localhost`(容器内 socket) | 仓库、6456 |
| D2 | n9e / topo-studio 用 root 连库 | 新建 `n9e_app`、`topo_app`,只授权各自库(`initsql-extra/f-app-users.sh`) | 仓库、6456 |
| D3 | 无防暴力破解;my.cnf 因权限 640 从未生效 | 加载 connection_control;修正挂载权限,`init-env.sh` 每次补齐 | 仓库、6456 |
| D4 | 新部署 admin 为上游默认弱口令 | `init-env.sh` 生成 20 位复杂密码,MySQL 初始化阶段替换,n9e 首启即为强口令 | 仓库(6456 全新部署实测通过) |
| D5 | 平台账号:admin 与测试账号共用密码、区域账号共用初始密码 | admin 与 4 个区域账号改为复杂密码;删除测试账号 alert | 6456 |
| D6 | DeepFlow 自带 MySQL 写死弱口令、ClickHouse 空口令 | 改为 `render-config.sh` 随机生成;内部端口只绑 127.0.0.1 | 仓库、6456 |
| D7 | 80 / 20090 / 60072 对外暴露 | 默认只绑 127.0.0.1,可经 `*_BIND` 放开 | 仓库、6456 |
| D8 | 仓库与部署目录中的弱口令文本(含注释、示例、备份文件) | 全部清除;`a-n9e.sql` admin 初始值改为占位串 | 仓库、6456 |
| D9 | 6456 遗留数据:含旧口令的停止容器、带令牌的旧安装包、迁移前的旧 Docker 目录(含旧 MySQL 数据)与 `/opt/deepflow.old` | 已删除;根分区 87% → 24% | 6456 |
| D10 | VoIP 机(10.185.92.18)JBoss 带 JDWP 8787,root 运行、无认证、绑全网卡 | firewalld 原本未放行(末尾 reject);另加显式拒绝规则(IPv4/IPv6,永久),进程未动 | VoIP 机 |
| D11 | 9 台 Linux agent 机配置扫描 | 无弱口令文本;被监控库口令只在 `/run`(tmpfs)以 root 400 渲染 | — |

## 二、未处理(按优先级)

| # | 问题 | 风险 | 建议 | 状态 |
|---|---|---|---|---|
| P1 | 17000 明文 HTTP 暴露 n9e 全部 API(含登录) | 高 | **已处理(2026-10-11,6456)**:nginx 接管 17000,只放行 `/prometheus/v1/write`、`/v1/n9e/heartbeat`、`/api/n9e/agent/*`,登录/管理/前端返回 403,只走 443;14 台 agent 实测无影响。**剩余**:做不了来源网段限制(经 Docker 映射的来源 IP 被替换;宿主网络方案需 firewalld 放行 17000,主机防火墙暂不改,与 P6 一并决策) | 已处理(网段限制待定) |
| P2 | 17000 改 HTTPS | 中 | agent 包已支持自签 https(`N9E_TLS_INSECURE`、config-sync `INSECURE_SKIP_VERIFY`);须逐台改上报地址。**实测 COSLOS×5、IAM、VoIP 到 VIP:443 不通**,只能在 17000 上直接开 TLS,不能改走 443 | 讨论中 |
| P3 | agent 上报接口无认证 | 中高 | 短期:P1 + 来源网段白名单;中期:上报/心跳加 BasicAuth(15 台含 Windows) | 待排期 |
| P4 | **376 个 SNMP 类采集实例(交换机/防火墙/UPS/专线)community 明文存于平台库**,未走加密密钥库 | 中:拿到平台库即拿到全网设备只读口令;且全部共用同一 community | 迁移到密钥库(`secret_refs`);推动网络设备改 SNMPv3 或按区域分 community | 待排期 |
| P5 | ecs1 重新部署 | 高(其旧数据卷仍含弱口令账号) | 以 6456 加固后的数据重新迁移,先只起 MySQL 复测再起服务 | 延后 |
| P6 | 主机层:各机共用 `kylin` 账号且密码已在沟通中明文出现;SSH 允许密码登录;rpcbind(111)开启;firewalld 对 Docker 映射端口无效 | 中高 | 1. 轮换各机 kylin 密码;2. SSH 改密钥登录(先验证);3. 停 rpcbind;4. Docker 端口来源限制放 `DOCKER-USER` 链 | **暂不处理,先记录** |
| P7 | 5 台 Windows agent(YJ-IMC-1/2/3、YJ-DHCP-1/2)未扫描 | 中 | SSH 服务未运行,需现场执行 PowerShell 扫描脚本 | 待执行 |
| P8 | scanopy 用 PostgreSQL 超级用户;Redis/VictoriaMetrics 无细分权限 | 低(均未对外) | 建 `scanopy_app`(需迁移 31 张表属主) | P2 阶段 |
| P9 | 镜像 CVE 与系统补丁未评估 | 未知 | 构建机 92 的流水线加镜像漏洞扫描;系统补丁由客户运维按规范处理 | 待排期 |
| P10 | nginx 使用自签证书 | 低 | 申请客户内部 CA 证书替换 `etc/tls/` | 待客户提供 |
| P11 | topo-studio 连库失败时静默回落内存存储(重启丢数据) | 低(可用性) | 代码改为连库失败即退出,由 `restart: always` 重试 | 待排期 |
| P12 | 6456 上的加固备份目录含 `.env` 副本 | 低 | ecs1 上线稳定后删除 | 待删除 |
| P13 | **构建机 92(192.168.50.92)ubuntu 的 sudo 口令为弱口令** | 中高:92 能推送镜像到 Docker Hub、持有代码仓库凭据,被拿下可污染所有部署的镜像 | 改为强口令;或把 ubuntu 加入 docker 组(`sudo usermod -aG docker ubuntu`),镜像直灌不再需要 sudo | 待处理 |
