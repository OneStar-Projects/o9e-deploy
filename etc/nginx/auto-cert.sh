#!/bin/sh
# nginx 启动前自动证书:挂载到 /docker-entrypoint.d/05-auto-cert.sh 时,
# nginx 官方镜像的主 entrypoint 会自动 source 它,在 nginx -g 启动之前跑。
#
# 行为:
#   - /etc/nginx/tls/{fullchain,privkey}.pem 存在且非空 → 跳过(用户已放真证书)
#   - 否则 → 用 openssl 现签一张 RSA2048/365 天的自签证书
#
# 注意:tls 目录必须以可写挂载(不能 :ro),否则签了写不进去。
set -e

CERT=/etc/nginx/tls/fullchain.pem
KEY=/etc/nginx/tls/privkey.pem

if [ -s "$CERT" ] && [ -s "$KEY" ]; then
    echo "[auto-cert] existing cert found ($CERT), skip"
    exit 0
fi

echo "[auto-cert] no cert detected at $CERT, generating self-signed..."

if ! command -v openssl >/dev/null 2>&1; then
    echo "[auto-cert] openssl not installed, installing via apk..."
    apk add --no-cache openssl >/dev/null
fi

mkdir -p /etc/nginx/tls

CN="${AUTO_CERT_CN:-o9e.local}"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=${CN}" \
    -addext "subjectAltName=DNS:${CN},DNS:localhost,IP:127.0.0.1" 2>&1 | tail -3

chmod 600 "$KEY" 2>/dev/null || true

echo "[auto-cert] generated self-signed cert CN=${CN}, valid 365 days"
echo "[auto-cert] ⚠ self-signed: 浏览器会显示证书警告,生产请换真证书"
