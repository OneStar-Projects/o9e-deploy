# 资源清单仪表盘套件

一套自包含、可移植的仪表盘:1 张**总览盘**(按分类列出被监控资源 + 在线状态 + 一键下钻)+ 多张分型 **detail 盘**。靠固定 `ident` 而非会变的数字 id 互联,导到任何现场跑一条命令即可部署/升级。

## 目录

```
dashboards/
├─ resource-inventory-overview.json   # 总览盘 (ident: resource-overview)
├─ import-dashboards.sh               # 导入/升级脚本 (upsert by ident)
├─ gen-detail.py                      # 开发期: 源模版盘 -> bundle detail 盘
├─ verify-overview.py                 # 开发期: 校验总览盘契约
└─ details/                           # 各分型 detail 盘
   ├─ host-detail.json  net-detail.json  app-detail.json
   ├─ db-mysql.json  db-oracle.json  db-redis.json
   └─ container-docker.json
```

## 首次部署

```bash
# 1. 起容器栈
docker compose up -d

# 2. 导入套件(脚本自动建数据源/用户组/业务组, 无需 UI 手动准备)
N9E_USER=root N9E_PASS=root.2020 ./dashboards/import-dashboards.sh

# 3. 打开总览盘
#    http://<host>:17000/dashboards/resource-overview
```

依赖:部署主机有 `curl` 和 `jq`(`install-docker-kylin.sh` 已自动安装)。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `N9E_ADDR` | `http://localhost:17000` | n9e API 地址 |
| `N9E_USER` / `N9E_PASS` | `root` / `root.2020` | 管理员凭据(本部署 n9e 启动自建 root;initsql 里的 `admin/changeme` 不可用) |
| `VM_URL` | `http://victoriametrics:8428/` | prometheus(VM)数据源地址,非标准现场可覆盖 |
| `BUNDLE_VISIBILITY` | `login` | 可见性四档(声明式,翻转后重跑即生效,不受版本门控):`login`=**所有登录用户可见**(默认,挡匿名);`anonymous`=匿名免登录可读;`private`=仅「资源清单」业务组成员/admin;`busi`=授权给本业务组 |

## 工作机制

- **数据源**:脚本启动先查 prometheus 类数据源,没有则自动 `upsert` 创建(URL=`VM_URL`),取其真实 id 注入到总览盘各 panel 的 `datasourceValue` 占位(源 JSON 里是 `0`)。**不依赖"数据源 id=1"**。
- **归属与可见性**:盘归属一个业务组(全新库已自带「Default Busi Group」;脚本另建专用「资源清单」组并归入其下)。可见性由 `BUNDLE_VISIBILITY` 控制,**默认 `login`(所有登录用户可见、挡匿名)**。n9e 的可见性档对应 `public`/`public_cate`:`login`→`public=1,cate=1`;`anonymous`→`cate=0`;`busi`→`cate=2`(授权本业务组);`private`→`public=0`(仅业务组成员/admin,普通用户需被加入该组)。
- **互联**:总览盘按 type 标签动态拼 `ident` 路径下钻,例如数据库表点 MySQL 行 → `/dashboards/db-mysql?instance=...`,Oracle 行 → `/dashboards/db-oracle?...`。靠 `ident` 不靠数字 id,换现场 id 变了链接照样有效。

## 升级某张盘

1. 改对应 JSON 文件内容。
2. 把该文件 `note` 里的 `bundle-version: N` 数字 **+1**。
3. 重跑 `./import-dashboards.sh` —— 仅该盘按 ident 原地覆盖(`id`/`ident` 不变,链接不断),其余盘版本未变自动跳过。

## 扩展新类型 detail 盘(预留 ident:`db-postgresql` `db-sqlserver` `mw-*` `container-cadvisor`)

```bash
# 1. 从模版中心对应组件复制一张盘的 JSON(或用 integrations/<组件>/dashboards/ 里的源)
# 2. 转成 bundle 格式(加 ident/tags/note、清 datasourceValue 占位)
python3 gen-detail.py <源.json> db-postgresql "integrations/PostgreSQL/dashboards/xxx.json"
# 3. 规范主过滤变量名与契约一致(数据库->instance, 容器->ident, 网络->ipadd)
# 4. 重跑导入脚本(只新盘被建, 总览盘不动)
./import-dashboards.sh
```

### 动态路由命名约定(扩展时必须遵守)

`<指标>_up` 名去掉 `_up` == 总览表派生的 type 标签值 == detail 盘 `ident` 后缀,三者必须严格对齐。
例:`postgresql_up` → type `postgresql` → ident `db-postgresql`。对不齐则下钻 404。

## 注意

- 打了 `managed-by-bundle` 标签的盘**由套件管理**;在 UI 里手改会在下次升级(版本 +1)时被覆盖。要改请改源 JSON 并走升级流程。
- detail 盘是模版中心对应盘的**定格副本**,上游模版更新不会自动同步;每张盘 `note` 记了来源(`src: ...`),需要比对时按此回溯。
- 脚本**幂等**:版本未变重跑全部跳过;单张盘瞬时失败(网络抖动)不中断整体,重跑即补齐。
