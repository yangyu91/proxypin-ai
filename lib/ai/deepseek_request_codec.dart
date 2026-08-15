/// DeepSeek 网页版请求编解码。
///
/// 移植自 deepseek-pp 的 core/deepseek/request-codec.ts，请求体与头保持 1:1 一致。

import 'dart:convert';

import 'deepseek_contracts.dart';

/// 补全请求输入
class DeepSeekCompletionInput {
  final String chatSessionId;
  final int? parentMessageId;
  final String? modelType;
  final String prompt;
  final List<String> refFileIds;
  final bool thinkingEnabled;
  final bool searchEnabled;

  DeepSeekCompletionInput({
    required this.chatSessionId,
    this.parentMessageId,
    this.modelType,
    required this.prompt,
    this.refFileIds = const [],
    this.thinkingEnabled = false,
    this.searchEnabled = false,
  });
}

/// 创建会话请求体
Map<String, dynamic> encodeCreateSessionRequest() => <String, dynamic>{};

/// PoW 挑战请求体
Map<String, dynamic> encodePowChallengeRequest(String targetPath) =>
    <String, dynamic>{'target_path': targetPath};

/// 补全请求体（与 deepseek-pp encodeCompletionRequest 一致）
Map<String, dynamic> encodeCompletionRequest(DeepSeekCompletionInput input) =>
    <String, dynamic>{
      'chat_session_id': input.chatSessionId,
      'parent_message_id': input.parentMessageId,
      'model_type': normalizeModelType(input.modelType),
      'prompt': input.prompt,
      'ref_file_ids': input.refFileIds,
      'thinking_enabled': input.thinkingEnabled,
      'search_enabled': input.searchEnabled,
      'action': null,
      'preempt': false,
    };

/// 规范化模型类型
String normalizeModelType(String? modelType) {
  if (modelType == null || modelType.isEmpty) return deepSeekDefaultModelType;
  const supported = <String>{'DEFAULT', 'default', 'expert', 'vision'};
  if (supported.contains(modelType)) return modelType;
  if (modelType == 'chat' || modelType == 'deepseek_chat')
    return deepSeekDefaultModelType;
  if (modelType == 'reasoner' || modelType == 'deepseek_reasoner')
    return 'expert';
  return deepSeekDefaultModelType;
}

/// 构建网页会话 URL
String buildDeepSeekWebSessionUrl(String chatSessionId) =>
    '$deepSeekWebOrigin/a/chat/s/$chatSessionId';

/// 构造客户端请求头（Authorization 等）
Map<String, String> createClientHeaders(String token) => <String, String>{
      'Authorization': 'Bearer $token',
      'X-App-Version': deepSeekDefaultAppVersion,
      'x-client-platform': deepSeekClientPlatform,
      'x-client-version': deepSeekDefaultAppVersion,
      'x-client-locale': 'zh-CN',
      'x-client-timezone-offset':
          '${-DateTime.now().timeZoneOffset.inMinutes * 60}',
    };

/// 对 JSON 请求体做 UTF-8 编码
List<int> jsonBody(Map<String, dynamic> body) => utf8.encode(jsonEncode(body));
