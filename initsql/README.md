# initsql

mysql 容器首次启动时跑的 schema。**这是 `nightingale/docker/initsql/` 的副本**,
不是 symlink。

## 为什么不用 symlink

之前是 symlink `→ ../../nightingale/docker/initsql`,看起来零冗余,但部署侧
经常把 `deploy/single-node/` 单独 scp/rsync 到目标机(不带兄弟目录 `nightingale/`),
symlink 直接断,docker 把它当空目录挂,mysql initdb 不跑任何 schema → 库里没表。

改成真目录后 `deploy/single-node/` 整个是自包含的部署单元,scp 整个目录就能跑。
代价是需要在上游变更时手动同步过来。

## 上游变更同步

如果 `nightingale/docker/initsql/*.sql` 改了,把改动 copy 过来:

```bash
cd $(git rev-parse --show-toplevel)
cp -a nightingale/docker/initsql/*.sql deploy/single-node/initsql/
git diff deploy/single-node/initsql/   # 看变化
git add deploy/single-node/initsql/
```

## 加 fork 的增量 schema

不要改这个目录里的文件 — 直接覆盖会丢同步。
fork 自己的增量改动放 `deploy/single-node/initsql-extra/d-*.sql`,字典序在
上游 `a-/c-*.sql` 之后跑。docker-compose 已经把两套都 mount 进
`/docker-entrypoint-initdb.d/`,mysql 按文件名顺序自然执行。
