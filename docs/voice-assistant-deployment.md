# 语音对讲部署

内网 n9e 主动通过 WSS/443 连接独立公网语音网关。部署前更新包含语音功能的 n9e 镜像；公网另部署 `fuqiangleon/o9e-voice` 固定版本镜像。源码和两个镜像的构建由 n9e 仓库负责。网关支持 Google Live 与 OpenAI Realtime 两种适配器，每个网关进程采用一个默认供应商/模型。运维查询仍使用现有文字助手的模型配置，需确认该助手可以正常执行查询；语音模型的密钥只放在网关，普通用户看不到模型配置。

## 公网服务器

复制本仓库 `voice-gateway` 目录到公网机器，复制 `.env.example` 为 `.env`，设置镜像版本、所选供应商 API key 和至少 32 字符的随机网关服务凭据。文件权限建议 600。`O9E_VOICE_CLIENT_ID` 与服务凭据必须与内网配置一致。

OpenAI 配置示例（真实密钥安全填写在该机器的 `.env` 中）：

```dotenv
VOICE_PROVIDER=openai
VOICE_MODEL=gpt-realtime
VOICE_VOICE=marin
OPENAI_API_KEY=
OPENAI_TRANSCRIPTION_MODEL=gpt-4o-mini-transcribe
VOICE_UPSTREAM_PROXY=
```

`gpt-realtime` 与转写模型均须验证当前账号的可用权限。OpenAI 使用官方 GA `wss://api.openai.com/v1/realtime`，不接普通 Chat Completions，也不接受浏览器传入模型或上游地址。输入转写是独立 ASR，可能与实时语音模型的实际理解存在差异。

Google 使用 `VOICE_PROVIDER=google`、`GOOGLE_API_KEY`，通过 `VOICE_MODEL` 指定验收过的真实 Live 模型 ID，`VOICE_VOICE` 可留空。仅所选供应商的 key 必填；使用 OpenAI 不需要 Google key。未设供应商仍使用 Google，默认 Live 模型 `gemini-3.8-live` 已通过本次开发账号的真实连接、中文音频和工具续答验证；部署账号仍需自行核验权限。另设 `VOICE_TRANSCRIPTION_MODEL=gemini-3.5-flash-lite`，用于完整发言的音频转写校验，不接受模型改写的主机名直接执行查询。

在 `voice-gateway/tls` 放置网关域名可信的 `fullchain.pem` / `privkey.pem`。保持 TLS 校验，供应商 key 不放在内网或浏览器。然后在该目录运行：

```bash
docker compose pull
docker compose up -d
docker compose ps
```

健康检查只验证服务进程；模型账号和音频链路还需真实对讲验收。OpenAI 出口必须可达 `api.openai.com:443`，Google 必须可达 `generativelanguage.googleapis.com:443`。两家均支持 `VOICE_UPSTREAM_PROXY=http://代理地址:端口` 显式配置 HTTP CONNECT 代理；默认直接连接，不自动读取其他服务的 HTTP_PROXY。代理须支持 WebSocket，并保持正常 TLS 证书校验。Google 连接适配使用固定官方路径，修正当前 SDK 产生的重复斜杠；不跟随任意上游重定向。

修改供应商、模型、音色或转写模型后，需要重建网关容器。配置在进程启动时冻结，重启会中断现有连接；恢复绑定包含模型配置和凭据变化，配置不匹配时提示重新开始，不把旧恢复句柄用于新模型。当前 OpenAI 适配不提供原生会话恢复，任何已开始会话的断线重连都会提示重新开始，且不重跑旧查询。Google 只有收到有效原生恢复句柄后才可恢复。升级旧版本网关时建议先结束现有对讲，旧格式的恢复句柄将要求重新开始。

## 语音护栏

新版本网关强制启用运维话题检查，新增配置已写入 `voice-gateway/.env.example` 并映射到 Compose：

```dotenv
# 空值默认：OpenAI gpt-4.1-mini / Google gemini-3.5-flash-lite
VOICE_GUARDRAIL_MODEL=
VOICE_GUARDRAIL_TIMEOUT_MS=8000
VOICE_GUARDRAIL_MAX_CHECKS=200
```

分类复用当前供应商的 API key，但需要另外验证文本模型权限和费用。模型 ID 需支持结构化 JSON；超时为 1–30000 毫秒，检查上限为每连接 1–1000 次。模型无权限、检查超时或服务异常均会停止对讲，不绕过检查。OpenAI 分类调用 `/v1/responses`；Google 分类和完整发言转写调用 `generateContent`，均沿用所配置代理。护栏与转写配置变化会使旧恢复绑定失效。旧 Google 默认审核模型 `gemini-2.5-flash-lite` 对本次账号返回 404，新默认模型已完成两项真实话题判断；其他账号仍需验收。

Google 转写按完整 PCM 发言审核，避免依赖 Live 事件中缺失的 `finished` 字段。按住说话使用显式边界，连续模式使用 700ms 静音分段及 300ms 前导音频；单段超过 30 秒结束通话。转写接口超时 15 秒，失败时关闭通话，不使用部分转写放行查询。每个完整发言最多执行一次运维查询，执行问题采用审核后的完整转写。每段会增加一次音频转写请求，其费用不属于 Live token 上限；转写尝试次数也受 `VOICE_GUARDRAIL_MAX_CHECKS` 限制，累计用户费用仍需后续接入。

输入、工具问题和输出转写共同检查话题；只有输入与工具问题通过后才发起 n9e 查询。用户、业务组、数据源和资源权限继续由 n9e 硬校验。OpenAI 等完整输入转写审核后才启动回答；Google 自动生成，不能保证先审核再生成。输出为异步检查，部分违规音频可能在中断前已被听到，两家都不能保证零泄漏。

被拒绝会停止播放、关闭麦克风并结束本次对讲，页面显示可理解的原因；需要更新配套后端及前端识别错误码。`VOICE_MAX_USAGE_TOKENS` 不含新增分类调用费用；每连接检查上限也不是用户日配额。详细机制、官方依据和回归记录见 n9e 的 `docs/ai-analysis/voice-guardrails-implementation.md`。部署前应结束现有会话，更新包含护栏源码的网关固定镜像版本并重建容器，不能仅修改环境变量或推送仓库。

## 内网服务器

在原部署 `.env` 中设置：

```dotenv
O9E_VOICE_ENABLED=true
O9E_VOICE_GATEWAY_URL=wss://voice.example.com/v1/live
O9E_VOICE_CLIENT_ID=o9e
O9E_VOICE_DATASOURCE_ID=3
O9E_VOICE_MAX_SECONDS=1200
```

同时安全配置 `O9E_VOICE_GATEWAY_TOKEN`，值与公网一致。数据源 ID 替换为本项目使用的 Prometheus/VM 来源，验证来源绑定与 ident 隔离后再启用。以上变量映射到 `[Center.Voice]`；供应商、模型和供应商密钥全部在语音网关设置。内网容器如需出口代理，可按现场要求传入 HTTPS_PROXY/NO_PROXY；Go 出站拨号使用 `http.ProxyFromEnvironment`。

按既有流程更新 n9e 镜像、重建 n9e 容器并重新加载 Nginx 配置。语音 WebSocket 使用专用 location；不能只重启 n9e 而保留旧 Nginx 配置。当前内网部署路径为 `/api/n9e/assistant/voice/ws`，企业版宿主需要同时挂载对应的语音路由与 location。

二进制部署需要更新后端二进制及前端静态资源，并沿用 `[Center.Voice]` 的连接配置；新增播放反馈和字幕替换协议需前后端配套更新。仅更新公网网关无法补齐旧前端的 OpenAI 播放截断反馈。

客户端须通过可信 HTTPS 访问系统，从“语音通话”进入独立通话抽屉，选择一个有权限的业务组，再点击电话按钮并允许麦克风。文字聊天保持原会话和状态；语音结果在通话抽屉显示，互不注入上下文。“收起通话”保留连接，关闭抽屉、隐藏助手或页面会释放录音。服务关闭或配置不完整会显示明确提示。自签证书需由客户端信任企业 CA；部分浏览器不会在不可信安全上下文中提供麦克风 API。

## 当前能力与验收

首期开放当前业务组下的指标发现、标签、PromQL 查询与分析；其他运维工具默认拒绝，报告/趋势任务创建留待带页面确认的后续阶段。每用户一个活跃对讲，默认 20 分钟上限；120 秒无用户转写且没有正在执行的查询任务时退出，可用 `VOICE_IDLE_SECONDS` 调整。会话失效或切换业务组后重新开始。

两端时钟须同步，服务签名允许 30 秒时间偏差。公网网关当前支持单实例；扩展多实例前需实现共享 nonce 防重放与会话路由。`VOICE_MAX_USAGE_TOKENS` 是用量保护阈值，OpenAI 按会话累计去重后的 response token 数，Google 按其上报数检查；不是跨供应商统一费用账本，也不包含独立转写和文字助手的全部费用。

参数校验要求：供应商 key 和共享服务凭据不得包含空白，共享凭据至少 32 字符；公网 `VOICE_MAX_SECONDS` 和内网 `O9E_VOICE_MAX_SECONDS` 为 1–3600 秒，两端协调设置，先到的限制生效。未填内网时长或填 0 取默认 1200，显式负数或超过 3600 会禁用语音入口。网关数值参数必须为十进制正整数，`VOICE_IDLE_SECONDS` 上界 2147483 秒，建议低于会话时长。网关地址须为精确的 WSS `/v1/live`，不能附带凭据、查询参数或片段，显式端口为 1–65535。Compose 内部端口、Nginx 转发和镜像健康检查统一为 8090，保持默认。

完整参数核查表见 n9e 仓库 `docs/ai-analysis/voice-openai-implementation.md`。本地检查覆盖参数解析、非法配置拒绝、音频字段、工具协议和部署映射；API 账号、模型/音色、真实出口代理、TLS 和音质还需部署环境验收。

验收中文输入输出、连续对讲/按住说话、打断、静音、取消查询、重复或取消后的工具调用、异步查询期间继续讲话、断网重连、Google 连接轮换、OpenAI 的重新开始提示、修改模型后旧绑定拒绝、退出页面释放麦克风、其他用户访问拒绝、撤权与切组隔离。OpenAI 还需核对播放截断后不续播旧音频、迟到转写不覆盖新问题。关注语音、转写与现有文字助手的用量。关闭 `O9E_VOICE_ENABLED` 并重建 n9e 可停止开放语音入口，文字助手继续可用。

真实账号和公网部署尚未验收时，不将本地模拟测试描述为上线通过。服务凭据、供应商 key、TLS 私钥和原始音频均不提交仓库。
