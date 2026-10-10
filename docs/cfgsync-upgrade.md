# 配置中心与 Agent 升级

配置中心服务和运维助手工具随 o9e 主镜像发布，无需新增容器。被监控主机运行 categraf 和 config-sync，使用独立 Agent 安装包；单独更新 compose 镜像不会更新这些主机上的程序。

## 发布和部署要求

1. 在 n9e 仓库使用相同源码版本构建主镜像，以及 `scripts/build-config-sync.sh`、`scripts/package-agents.sh` 生成的 Agent 安装包。基本 categraf 安装脚本不包含完整配置同步流程。安装包应包含 amd64、arm64 的 categraf 和 config-sync；缺少必要程序时打包会失败。
2. 备份 MySQL 和现有配置；保持配置中心加密主密钥不变，并将其随备份保管。更换密钥会导致历史密码无法解密。
3. 发布主镜像后，更新部署仓库的镜像版本，执行 `docker compose pull n9e` 和 `docker compose up -d n9e`。服务启动通过 GORM 自动迁移表，不要仅依赖首次初始化 SQL。
4. 核对启动日志中迁移成功，新增 `cfgsync_device`、`cfgsync_publication`、`cfgsync_ack_receipt` 表，以及实例 owner/draft、密码 grants/version、主机 generation/render_error/force_publish 字段。保留历史 token 和绑定数据。
5. 更新主机 Agent 安装包。通用装机令牌可以被多个不同 host_ident 的 Agent 复用；既有身份需用当前设备凭据轮换，或由管理员明确替换。管理员替换后通过新客户端 `--import-host-token` 从标准输入导入凭据，不要把 token 放在命令参数中。

Linux 密码配置必须落在真实 tmpfs/ramfs。客户端拒绝将明文写到普通磁盘。支持 systemd-creds 的 Linux 使用主机密钥加密设备凭据；旧系统仍支持权限为 0600 的兼容存储，设置 `REQUIRE_ENCRYPTED_HOST_TOKEN=1` 可禁止新写入的明文回退。Windows 使用 DPAPI 保护设备凭据，但当前不支持下发包含监控密码的配置。

## 验证

在隔离测试环境，用管理员凭据运行 n9e 仓库的 `scripts/cfgsync-smoke.sh`，设置 `N9E_URL`、`ADMIN_TOKEN`；如使用 API token，设置对应的 `ADMIN_TOKEN_HEADER`。脚本创建唯一测试资源，覆盖注册、原子创建绑定、密码引用、版本 ACK 和重复 ACK，并在退出时删除资源、撤销设备及装机凭据；清理失败也会返回失败。

脚本模拟 ACK，只验证接口协议。生产验收还需要一台真实主机完成配置拉取、密码解析、categraf 重启、健康检查，以及实际指标查询。页面“配置已应用”表示配置同步成功，不能替代指标采集验证。

客户端不在线或卸载时保留绑定，避免把离线误判为删除。在线卸载会尝试撤销设备凭据；离线卸载需管理员在配置中心撤销。设备注册或轮换响应丢失时，也使用管理员明确替换来恢复身份。
