/// AI 工作台配置管理：模型、提示词、Skill、记忆和调试策略。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_provider.dart';

class AiConfig {
  static const String _tokenKey = 'ai_deepseek_token';
  static const String _apiKeyKey = 'ai_api_key';
  static const String _providerTypeKey = 'ai_provider_type';
  static const String _baseUrlKey = 'ai_base_url';
  static const String _modelKey = 'ai_model';
  static const String _systemPromptKey = 'ai_system_prompt';
  static const String _skillsKey = 'ai_skills';
  static const String _memoryKey = 'ai_memory';
  static const String _includeSensitiveKey = 'ai_include_sensitive';
  static const String _confirmActionsKey = 'ai_confirm_actions';

  static const String defaultSystemPrompt = '''你是 ProxyPin 的网络调试助手。
请基于当前抓包上下文回答问题，优先给出可验证的分析、风险点和下一步操作。
默认隐藏 Authorization、Cookie、Set-Cookie、API Key、密码、Token 等敏感值；只有用户明确确认后才显示指定字段。
对于改包、重放、发包操作，只能先生成变更预览，等待用户确认后执行，不得自行发送。''';

  static Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  static Future<void> saveToken(String token) async => (await _prefs()).setString(_tokenKey, token);
  static Future<String?> readToken() async => (await _prefs()).getString(_tokenKey);

  static Future<void> saveApiKey(String apiKey) async => (await _prefs()).setString(_apiKeyKey, apiKey);
  static Future<String?> readApiKey() async => (await _prefs()).getString(_apiKeyKey);

  static Future<void> saveProviderType(AiProviderType type) async => (await _prefs()).setString(_providerTypeKey, type.name);
  static Future<AiProviderType> readProviderType() async {
    final value = (await _prefs()).getString(_providerTypeKey);
    return AiProviderType.values.firstWhere((t) => t.name == value, orElse: () => AiProviderType.deepSeekWeb);
  }

  static Future<void> saveBaseUrl(String value) async => (await _prefs()).setString(_baseUrlKey, value);
  static Future<String> readBaseUrl() async => (await _prefs()).getString(_baseUrlKey) ?? 'https://api.openai.com/v1';

  static Future<void> saveModel(String value) async => (await _prefs()).setString(_modelKey, value);
  static Future<String> readModel() async => (await _prefs()).getString(_modelKey) ?? 'gpt-4.1-mini';

  static Future<void> saveSystemPrompt(String value) async => (await _prefs()).setString(_systemPromptKey, value);
  static Future<String> readSystemPrompt() async => (await _prefs()).getString(_systemPromptKey) ?? defaultSystemPrompt;

  static Future<void> saveSkills(List<String> skills) async => (await _prefs()).setString(_skillsKey, jsonEncode(skills));
  static Future<List<String>> readSkills() async {
    final raw = (await _prefs()).getString(_skillsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      return value is List ? value.whereType<String>().toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveMemory(List<Map<String, String>> entries) async => (await _prefs()).setString(_memoryKey, jsonEncode(entries));
  static Future<List<Map<String, String>>> readMemory() async {
    final raw = (await _prefs()).getString(_memoryKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is! List) return const [];
      return value.whereType<Map>().map<Map<String, String>>((item) => Map<String, String>.fromEntries(item.entries.map((entry) => MapEntry(entry.key.toString(), entry.value.toString())))).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> clearMemory() async => (await _prefs()).remove(_memoryKey);

  static Future<void> saveIncludeSensitive(bool value) async => (await _prefs()).setBool(_includeSensitiveKey, value);
  static Future<bool> readIncludeSensitive() async => (await _prefs()).getBool(_includeSensitiveKey) ?? false;

  static Future<void> saveConfirmActions(bool value) async => (await _prefs()).setBool(_confirmActionsKey, value);
  static Future<bool> readConfirmActions() async => (await _prefs()).getBool(_confirmActionsKey) ?? true;

  /// 从 userToken 原始字符串解析出 token。
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
