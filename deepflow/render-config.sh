#!/usr/bin/env bash
# 渲染 server.yaml <- server.yaml.tmpl:把 .env 的 N9E_REMOTE_WRITE 定点替换进去。
#
# 为什么要这一步:server.yaml 的 ingester exporter 出口(deepflow-server → n9e remote-write)
# 是 server 端配置,agent-group-config 覆盖不到,必须在 server.yaml 里设,且 server 启动时才读。
# 所以在 `docker compose up -d` **之前**跑本脚本,把装机参数一次性渲染进去。
#
# server.yaml 是生成物(见 .gitignore,不入库),故:
#   - 不会被 git checkout/pull 打回默认值(根治了原来手改漂移的坑);
#   - 要改 n9e 入口,改 .env 的 N9E_REMOTE_WRITE 后重跑本脚本 + `docker compose up -d deepflow-server`。
#
# 只对占位符那一行做定点替换,不碰 export-fields 里的 $tag/$metrics。
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "[render] 缺 .env,先 cp .env.example .env 并填 N9E_REMOTE_WRITE" >&2; exit 1; }
# shellcheck source=/dev/null
. ./.env

: "${N9E_REMOTE_WRITE:?请在 deepflow/.env 设 N9E_REMOTE_WRITE=http://<n9e_ip>:17000/prometheus/v1/write}"

TMPL=common/config/deepflow-server/server.yaml.tmpl
OUT=common/config/deepflow-server/server.yaml
[ -f "$TMPL" ] || { echo "[render] 缺模板 $TMPL" >&2; exit 1; }

# 用 | 作 sed 分隔符,URL 里的 / 无需转义;占位符唯一,不会误伤别处。
sed "s|__N9E_REMOTE_WRITE__|${N9E_REMOTE_WRITE}|g" "$TMPL" > "$OUT"
echo "[render] server.yaml <- N9E_REMOTE_WRITE=${N9E_REMOTE_WRITE}"
