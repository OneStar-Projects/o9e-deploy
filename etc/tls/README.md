# TLS 证书放置

把证书文件命名为以下两个名字放本目录:

- `fullchain.pem` — 完整证书链(server cert + intermediate)
- `privkey.pem`   — 私钥

`*.pem` / `*.key` 已在仓库根 `.gitignore` 排除,不会误入库。

## 测试用自签证书(只用于本地验证,不要上生产)

    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
      -keyout privkey.pem -out fullchain.pem \
      -subj "/CN=localhost" \
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

## 生产建议

外接 certbot / acme.sh / 公司 PKI,把签出的两个文件 cp 到本目录,
nginx reload(`docker compose exec nginx nginx -s reload`)即可热加载。
