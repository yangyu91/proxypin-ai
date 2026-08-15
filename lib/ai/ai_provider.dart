/// AI 后端抽象（支持像 ccswitch 一样切换后端）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'deepseek_client.dart';
import 'deepseek_request_codec.dart';

/// AI 消息
class AiMessage {
  final String role; // user / assistant
  final String content;
  AiMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// AI 流式回调
class AiStreamCallbacks {
  final void Function(String delta, String fullText)? onText;
  final void Function(String delta, String fullReasoning)? onReasoning;
  final void Function()? onFinished;
  final void Function(Object error)? onError;

  AiStreamCallbacks(
      {this.onText, this.onReasoning, this.onFinished, this.onError});
}

/// AI 后端抽象接口
abstract class AiProvider {
  String get name;

  /// 发送消息并流式返回。历史消息由实现自行管理。
  Future<void> sendMessageStreaming(String prompt, AiStreamCallbacks callbacks);
}

/// DeepSeek 网页版白嫖通道（复用 chat.deepseek.com 登录态）
class DeepSeekWebProvider implements AiProvider {
  final String token;
  DeepSeekWebClient? _client;
  String? _chatSessionId;
  int? _parentMessageId;

  DeepSeekWebProvider(this.token);

  @override
  String get name => 'DeepSeek 网页版';

  @override
  Future<void> sendMessageStreaming(
      String prompt, AiStreamCallbacks callbacks) async {
    _client ??= DeepSeekWebClient(token);
    final client = _client!;

    if (_chatSessionId == null) {
      _chatSessionId = await client.createChatSession();
    }

    await client.submitPromptStreaming(
      DeepSeekCompletionInput(
        chatSessionId: _chatSessionId!,
        parentMessageId: _parentMessageId,
        prompt: prompt,
        thinkingEnabled: true,
      ),
      DeepSeekStreamCallbacks(
        onTextChunk: (text, full) => callbacks.onText?.call(text, full),
        onReasoningChunk: (reasoning, full) =>
            callbacks.onReasoning?.call(reasoning, full),
        onFinished: () {
          callbacks.onFinished?.call();
        },
        onError: callbacks.onError,
      ),
    );
  }

  void dispose() {
    _client?.dispose();
    _client = null;
  }
}

/// DeepSeek 官方 API Key 通道（OpenAI 兼容）
class DeepSeekOfficialProvider implements AiProvider {
  final String apiKey;
  final List<AiMessage> _history = [];
  final HttpClient _httpClient = HttpClient();

  DeepSeekOfficialProvider(this.apiKey);

  @override
  String get name => 'DeepSeek 官方 API';

  @override
  Future<void> sendMessageStreaming(
      String prompt, AiStreamCallbacks callbacks) async {
    _history.add(AiMessage(role: 'user', content: prompt));

    final request = await _httpClient
        .postUrl(Uri.parse('https://api.deepseek.com/chat/completions'));
    request.headers.set('Authorization', 'Bearer $apiKey');
    request.headers.set('Content-Type', 'application/json');
    request.add(utf8.encode(jsonEncode({
      'model': 'deepseek-chat',
      'messages': _history.map((m) => m.toJson()).toList(),
      'stream': true,
    })));

    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      final body = await response.transform(utf8.decoder).join();
      throw DeepSeekException(
          '官方 API 调用失败 (HTTP ${response.statusCode}): $body');
    }

    final fullText = StringBuffer();
    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') break;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta = (choices[0] as Map)['delta'] as Map?;
        final content = delta?['content']?.toString();
        if (content != null && content.isNotEmpty) {
          fullText.write(content);
          callbacks.onText?.call(content, fullText.toString());
        }
      } catch (_) {}
    }
    _history.add(AiMessage(role: 'assistant', content: fullText.toString()));
    callbacks.onFinished?.call();
  }

  void dispose() {
    _httpClient.close(force: true);
  }
}

/// AI 后端类型枚举
enum AiProviderType { deepSeekWeb, deepSeekOfficial }

/// AI 后端工厂
AiProvider createAiProvider(AiProviderType type,
    {String token = '', String apiKey = ''}) {
  switch (type) {
    case AiProviderType.deepSeekWeb:
      return DeepSeekWebProvider(token);
    case AiProviderType.deepSeekOfficial:
      return DeepSeekOfficialProvider(apiKey);
  }
}
