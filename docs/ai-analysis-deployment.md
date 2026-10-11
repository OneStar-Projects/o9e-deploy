# 自然语言查询与运维周报部署

功能包含在新 n9e 镜像，复用现有 MySQL 和 Redis，无独立报告/查询容器。`.env.example` 已列出新参数；自然语言查询默认开启并受已启用默认 LLM 控制；报告开关仍默认关闭。现有 `.env` 若明确设置查询为 false，会继续手动关闭，需按本站意愿调整。

启用前必须现场验证 VM 租户路由、所选数据源业务组绑定与 ident 隔离；共享采集器的设备指标不能都使用采集器 ident。自然语言查询默认开启，但只有配置了已启用的默认 LLM 才开放；所有兼容且有权限的数据源自动支持，后端逐次检查数据源、业务组和资源权限，不再配置额外白名单。设 `O9E_NATURAL_QUERY_ENABLED=false` 可手动关闭。旧白名单环境变量不再由 Compose 转发。

```dotenv
O9E_NATURAL_QUERY_ENABLED=true
O9E_NATURAL_QUERY_TTL_SECONDS=900
O9E_NATURAL_QUERY_TIMEOUT_SECONDS=90
O9E_NATURAL_QUERY_MAX_ACTIVE=128
O9E_REPORTS_ENABLED=true
O9E_REPORTS_RETENTION_DAYS=90
```

自然语言入口还要求角色有 `/metric/explorer`；趋势提议需要 `/trend-analysis` 和 `/forecast/modify`；报告查看需要 `/reports`，创建/共享/调度需要 `/reports/modify`，写操作要求所选业务组 rw。角色迁移增加权限项后，管理员需按需授权。

发布使用已有镜像构建/拉取流程；新报告表由 n9e 增量迁移创建。先备份 MySQL，再对真实版本进行迁移验收；本地 SQLite 迁移回归不能代替生产 MySQL 验收。

更新对应镜像和参数后，执行既有 `docker compose pull n9e` 与 `docker compose up -d n9e` 流程。此说明不是已执行部署记录。关闭开关可停止开放新功能，不需要删表。

周报生成和每周调度在 n9e 内完成，AI 摘要复用已配置模型；模型不可用时保留基础报表。站内共享始终与当前数据权限取交；提供 CSV/JSON 和客户端打印 PDF，没有公开附件 URL 或后台自动发送。

Review 修复版本还会为 `local_report_task` 增量增加 `retry_at NOT NULL DEFAULT 0`。迁移前备份数据库，并确认启动迁移成功；该默认值让已有定时任务继续入选。队列暂满或数据库暂时失败后，任务保持启用并在 30 秒后重试原周期；权限被撤销才暂停。

新报告保存告警业务组证据，历史/预测清理不改变快照内容，当前权限或路由变化仍会拒绝读取。旧快照不被改写，旧统计口径需重新生成；旧告警快照缺少组证据且原始历史已被删除时，无法安全恢复读取。
