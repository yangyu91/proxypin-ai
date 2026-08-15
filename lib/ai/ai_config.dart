/// AI 配置管理（token、API key、后端类型持久化）。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_provider.dart';

class AiConfig {
  static const String _tokenKey = 'ai_deepseek_token';
  static const String _apiKeyKey = 'ai_deepseek_api_key';
  static const String _providerTypeKey = 'ai_provider_type';

  /// 保存 DeepSeek 网页版 token。
  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  /// 读取 DeepSeek 网页版 token。
  static Future<String?> readToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  /// 保存官方 API Key。
  static Future<void> saveApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyKey, apiKey);
  }

  /// 读取官方 API Key。
  static Future<String?> readApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiKeyKey);
  }

  /// 保存当前后端类型。
  static Future<void> saveProviderType(AiProviderType type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerTypeKey, type.name);
  }

  /// 读取当前后端类型。
  static Future<AiProviderType> readProviderType() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_providerTypeKey);
    return AiProviderType.values.firstWhere(
      (t) => t.name == value,
      orElse: () => AiProviderType.deepSeekWeb,
    );
  }

  /// 从 userToken 原始字符串解析出 token。
  /// 兼容 deepseek-pp 的 readDeepSeekUserToken 逻辑：
  /// 可能是纯字符串，或 {"token":...}/{"value":...}/{"accessToken":...} JSON。
  static String? parseUserToken(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'null') return null;
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is String) return parsed.trim().isEmpty ? null : parsed.trim();
      if (parsed is Map) {
        for (final key in ['token', 'value', 'accessToken']) {
          final v = parsed[key];
          if (v is String && v.trim().isNotEmpty) return v.trim();
        }
        return null;
      }
      return null;
    } catch (_) {
      return trimmed;
    }
  }
}
