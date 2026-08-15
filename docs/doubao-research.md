# doubao-pp 外部审计记录

来源：https://github.com/zhangweildlh/doubao-pp

仓库说明：Doubao-pp 将 Deepseek-pp 浏览器扩展移植到豆包网页版（https://www.doubao.com/chat/），当前仓库以 TypeScript 为主，包含 core、entrypoints、scripts、测试和 CI。

README 页面显示其目标包括记忆、Skill、工具、自动化、MCP、云同步和浮窗。提交记录显示它实现了 ChatProvider、豆包页面感知 fetch 拦截、runtime command bus、sidePanel、MemoryStore、Skill/MCP 工具桥接、浮窗会话以及跨浏览器构建。仓库标注为“非检测路线 A”，因此它主要是复用豆包网页登录态和页面协议，而不是直接提供公开 API。

重要实现线索：

1. `core/` 与 `entrypoints/` 中存在豆包会话读取、消息命令总线、浮窗、MemoryStore 和工具桥接代码。
2. `tests` 提到 ASSISTANT_TEXT 自带会话元信息，MemoryStore 写入串行化，说明对话记忆要按会话 ID 持久化而不能仅保存单个全局列表。
3. 仓库包含 shell-host 注册和 native messaging 相关能力，但这些能力面向浏览器扩展环境，不能直接复制到 Flutter Android；适合提取其会话/记忆/Skill 数据模型和安全边界。
4. 豆包免费通道依赖豆包网页版登录态和网页端协议。应用内接入应设计为用户在 WebView 中登录后复用 Cookie/会话，不能假设有稳定的公开 API，也不能把账号凭据硬编码进 APK。

实现结论：ProxyPin 可以增加 `DoubaoWebProvider`，但第一版应通过用户登录 WebView 获取会话信息，并对网页请求协议做适配；如果网页协议变更，需随版本更新。DeepSeek 和豆包都应共享统一的 `AiConversation`、`AiMessage`、`AiMemoryEntry` 和 `AiSessionStore`，按 provider/sessionId 保存历史。
