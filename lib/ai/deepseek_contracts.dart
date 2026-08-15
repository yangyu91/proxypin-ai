/// DeepSeek 网页版 API 端点与常量。
///
/// 移植自 deepseek-pp 的 core/deepseek/contracts.ts，端点与请求头保持 1:1 一致。

const String deepSeekWebOrigin = 'https://chat.deepseek.com';

/// 网页版 API 路由（与 deepseek-pp contracts.ts 完全一致）
class DeepSeekWebRoutes {
  static const String completion = '/api/v0/chat/completion';
  static const String editMessage = '/api/v0/chat/edit_message';
  static const String regenerate = '/api/v0/chat/regenerate';
  static const String history = '/api/v0/chat/history_messages';
  static const String powChallenge = '/api/v0/chat/create_pow_challenge';
  static const String createSession = '/api/v0/chat_session/create';
  static const String fetchSessions = '/api/v0/chat_session/fetch_page';
  static const String uploadFile = '/api/v0/file/upload_file';
  static const String fetchFiles = '/api/v0/file/fetch_files';
}

/// 官方 API 地址（OpenAI 兼容）
const String deepSeekOfficialApiUrl =
    'https://api.deepseek.com/chat/completions';

/// 绕过 hook 头（与 deepseek-pp 一致）
const String deepSeekBypassHookHeader = 'X-DPP-Bypass-Hook';

/// 默认 App 版本
const String deepSeekDefaultAppVersion = '2.0.0';

/// 客户端平台
const String deepSeekClientPlatform = 'web';

/// 默认模型类型
const String deepSeekDefaultModelType = 'default';
