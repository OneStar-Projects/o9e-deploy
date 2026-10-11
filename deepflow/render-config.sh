#!/usr/bin/env bash
# 渲染 server.yaml / mysql init.sql <- *.tmpl:把 .env 的 N9E_REMOTE_WRITE 与自带库口令定点替换进去。
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

# 自带 MySQL / ClickHouse 口令:.env 里为空则生成 32 位随机串并写回 .env(之后保持不变)。
# 只用 A-Za-z0-9,sed/YAML/SQL 都不用转义。口令不回显。
gen_pwd() { head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32; }
for k in DEEPFLOW_MYSQL_PASSWORD DEEPFLOW_CK_PASSWORD; do
  if [ -z "${!k:-}" ]; then
    v=$(gen_pwd)
    if grep -q "^${k}=" .env; then sed -i.bak "s|^${k}=.*|${k}=${v}|" .env && rm -f .env.bak
    else printf '%s=%s\n' "$k" "$v" >> .env; fi
    printf -v "$k" '%s' "$v"
    echo "[render] 已生成 ${k} 并写回 .env"
  fi
done
chmod 600 .env

render() { # tmpl out
  [ -f "$1" ] || { echo "[render] 缺模板 $1" >&2; exit 1; }
  # 用 | 作 sed 分隔符,URL 里的 / 无需转义;占位符唯一,不会误伤别处。
  sed -e "s|__N9E_REMOTE_WRITE__|${N9E_REMOTE_WRITE}|g" \
      -e "s|__DEEPFLOW_MYSQL_PASSWORD__|${DEEPFLOW_MYSQL_PASSWORD}|g" \
      -e "s|__DEEPFLOW_CK_PASSWORD__|${DEEPFLOW_CK_PASSWORD}|g" "$1" > "$2"
  # 含口令;容器内以非 root uid 读取须 o+r,其他用户靠部署目录 750 挡住
  chmod 644 "$2"
}
render common/config/deepflow-server/server.yaml.tmpl common/config/deepflow-server/server.yaml
render common/config/mysql/init.sql.tmpl              common/config/mysql/init.sql
echo "[render] server.yaml / init.sql 已渲染(N9E_REMOTE_WRITE=${N9E_REMOTE_WRITE})"
