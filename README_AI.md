# ProxyPin AI

基于 [ProxyPin](https://github.com/wanghongenpin/proxypin) 二开的抓包工具，新增 **AI 智能分析**能力：抓包后可直接在域名列表上栏唤起 AI 对话，让 AI 读取全部抓包数据并按需求分析。

## 新增功能

- **AI 对话面板**：域名列表上栏新增 AI 按钮，点击弹出对话面板，AI 自动读取当前抓包数据作为上下文，支持流式回复与推理过程展示。
- **白嫖 DeepSeek（0 token）**：内嵌 WebView 登录 `chat.deepseek.com`，复用网页版登录态（`userToken`）调用网页版 API，无需官方 API Key。
- **官方 API Key 双通道**：像 ccswitch 一样可切换后端——默认走网页版白嫖通道，填写官方 API Key 后自动切换 `api.deepseek.com` 官方通道，预留扩展其他 AI 的抽象接口。

## 技术实现

### 白嫖 DeepSeek 核心协议（1:1 移植自 [deepseek-pp](https://github.com/zhu1090093659/deepseek-pp)）

| 模块 | 文件 | 说明 |
|------|------|------|
| API 端点 | `lib/ai/deepseek_contracts.dart` | 网页版路由（completion / create_session / create_pow_challenge 等） |
| 请求编解码 | `lib/ai/deepseek_request_codec.dart` | 请求体与请求头格式 |
| PoW 求解 | `lib/ai/deepseek_pow.dart` | `X-DS-PoW-Response` 头 |
| 哈希算法 | `lib/ai/deepseek_hash.dart` | DeepSeekHashV1（SHA3-256 跳过 Keccak-f 第 0 轮） |
| SSE 流解析 | `lib/ai/deepseek_stream_codec.dart` | JSON-patch 流式解析，分离回答/推理 |
| 网页版客户端 | `lib/ai/deepseek_client.dart` | 会话创建 → PoW → 流式补全 |
| 后端抽象 | `lib/ai/ai_provider.dart` | 双通道 + 可扩展接口 |
| 配置管理 | `lib/ai/ai_config.dart` | token / API key / 后端类型持久化 |
| WebView 登录 | `lib/ai/login_webview.dart` | 内嵌登录 + 提取 userToken |

### AI 对话面板

- `lib/ui/desktop/request/ai_chat.dart` — 对话面板 UI + 抓包数据序列化（`buildCaptureContext`）
- `lib/ui/desktop/request/list.dart` — 域名列表上栏新增 AI 按钮入口

## 白嫖原理

```
1. WebView 打开 chat.deepseek.com，用户登录
2. 提取 localStorage 的 userToken
3. POST /api/v0/chat_session/create 创建会话
4. POST /api/v0/chat/create_pow_challenge 获取 PoW 挑战
5. 求解 DeepSeekHashV1（SHA3-256 跳过第 0 轮），得到 nonce
6. 请求头带上 X-DS-PoW-Response，POST /api/v0/chat/completion
7. 流式解析 SSE 响应
```

## 构建

```bash
flutter pub get
flutter run
```

> 需 Flutter 3.x（Dart >=3.0.2）。PoW 求解为纯 Dart 实现（Keccak-f[1600]），无需额外 WASM 运行时。

## 安全声明

本项目仅供学习与授权测试使用。白嫖 DeepSeek 网页版依赖其免费策略，请遵守 DeepSeek 服务条款，勿用于违规用途。

## 致谢

- [ProxyPin](https://github.com/wanghongenpin/proxypin) — 抓包基础
- [deepseek-pp](https://github.com/zhu1090093659/deepseek-pp) — 白嫖 DeepSeek 协议与 PoW 思路
- [deepseek-pow](https://github.com/shaohuahuawww/deepseek-pow) — DeepSeekHashV1 算法逆向参考
