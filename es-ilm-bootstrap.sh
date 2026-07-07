#!/usr/bin/env bash
# es-ilm-bootstrap.sh — 给 netflow-* 日志索引装 ILM 保留策略,超过 N 天自动删除,
# 防 ES 磁盘被 NetFlow 日志无限撑满(VM 有 retentionPeriod,ES 之前没有)。
#
# 幂等(全 PUT),部署后跑一次即可;想改保留天数,改 RETENTION_DAYS 重跑。
#
# 用法:
#   ./es-ilm-bootstrap.sh                 # 默认保留 15 天
#   RETENTION_DAYS=30 ./es-ilm-bootstrap.sh
#
# 前置:elasticsearch 容器已 healthy。
#
# 做三件事:
#   1. ILM policy  netflow-<N>d :delete 阶段 min_age=<N>d(按索引创建时间算)
#   2. index template netflow   :匹配 netflow-*,套该 policy + 单机 0 副本(否则单节点常驻 yellow)
#   3. 给已存在的 netflow-* 补挂 policy(模板只对新建索引生效,不追溯存量)
#
# curl 在 ES 容器内执行:镜像自带 curl,且容器内有 $ELASTIC_PASSWORD,无需读宿主 .env。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${DIR}"

DAYS="${RETENTION_DAYS:-15}"
POLICY="netflow-${DAYS}d"

# 在 ES 容器内 PUT:$1=路径,JSON body 从本函数 stdin(heredoc)读。
# \$ELASTIC_PASSWORD 转义 → 在容器内求值(密码在容器环境里,不在宿主)。
es_put() {
    docker compose exec -T elasticsearch sh -c \
        "curl -sf -u \"elastic:\$ELASTIC_PASSWORD\" -X PUT \"localhost:9200/$1\" -H 'Content-Type: application/json' -d @-"
}

echo "[es-ilm] 检查 ES 就绪..."
if ! docker compose exec -T elasticsearch sh -c \
        'curl -sf -u "elastic:$ELASTIC_PASSWORD" localhost:9200/_cluster/health >/dev/null'; then
    echo "[es-ilm] ES 未就绪,请先确保 elasticsearch 容器 healthy 再重跑。" >&2
    exit 1
fi

echo "[es-ilm] 1/3 创建 ILM policy ${POLICY}(保留 ${DAYS} 天)"
es_put "_ilm/policy/${POLICY}" <<JSON >/dev/null
{
  "policy": {
    "phases": {
      "hot":    { "actions": {} },
      "delete": { "min_age": "${DAYS}d", "actions": { "delete": {} } }
    }
  }
}
JSON

echo "[es-ilm] 2/3 创建 index template netflow(匹配 netflow-*)"
es_put "_index_template/netflow" <<JSON >/dev/null
{
  "index_patterns": ["netflow-*"],
  "template": {
    "settings": {
      "index.lifecycle.name": "${POLICY}",
      "number_of_replicas": 0
    }
  }
}
JSON

echo "[es-ilm] 3/3 给已存在的 netflow-* 补挂 policy(无存量则忽略)"
docker compose exec -T elasticsearch sh -c \
    "curl -s -u \"elastic:\$ELASTIC_PASSWORD\" -X PUT 'localhost:9200/netflow-*/_settings?allow_no_indices=true' -H 'Content-Type: application/json' -d @-" <<JSON >/dev/null || true
{ "index.lifecycle.name": "${POLICY}" }
JSON

echo "[es-ilm] 完成。当前 policy:"
docker compose exec -T elasticsearch sh -c \
    "curl -s -u \"elastic:\$ELASTIC_PASSWORD\" \"localhost:9200/_ilm/policy/${POLICY}?pretty\""
