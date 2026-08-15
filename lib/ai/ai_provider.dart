/// AI 后端抽象：支持 DeepSeek 网页版、DeepSeek API、OpenAI 兼容接口和 SiliconFlow。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'deepseek_client.dart';
import 'deepseek_request_codec.dart';

class AiMessage {
  final String role;
  final String content;
  AiMessage({required this.role, required this.content});
  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

class AiStreamCallbacks {
  final void Function(String delta, String fullText)? onText;
  final void Function(String delta, String fullReasoning)? onReasoning;
  final void Function()? onFinished;
  final void Function(Object error)? onError;
  AiStreamCallbacks({this.onText, this.onReasoning, this.onFinished, this.onError});
}

abstract class AiProvider {
  String get name;
  Future<void> sendMessageStreaming(String prompt, AiStreamCallbacks callbacks);
  Future<void> sendImageStreaming(Uint8List imageBytes, String prompt, AiStreamCallbacks callbacks);
  void dispose();
}

class DeepSeekWebProvider implements AiProvider {
  final String token;
  DeepSeekWebClient? _client;
  String? _chatSessionId;
  int? _parentMessageId;
  DeepSeekWebProvider(this.token);
  @override
  String get name => 'DeepSeek 网页版';
  @override
  Future<void> sendMessageStreaming(String prompt, AiStreamCallbacks callbacks) async {
    _client ??= DeepSeekWebClient(token);
    final client = _client!;
    _chatSessionId ??= await client.createChatSession();
    await client.submitPromptStreaming(
      DeepSeekCompletionInput(chatSessionId: _chatSessionId!, parentMessageId: _parentMessageId, prompt: prompt, thinkingEnabled: true),
      DeepSeekStreamCallbacks(
        onTextChunk: (text, full) => callbacks.onText?.call(text, full),
        onReasoningChunk: (reasoning, full) => callbacks.onReasoning?.call(reasoning, full),
        onFinished: callbacks.onFinished,
        onError: callbacks.onError,
      ),
    );
  }
  @override
  Future<void> sendImageStreaming(Uint8List imageBytes, String prompt, AiStreamCallbacks callbacks) async {
    throw UnsupportedError('DeepSeek 网页版暂不支持直接识图，请切换到 OpenAI 兼容或 SiliconFlow 模型');
  }
  void dispose() { _client?.dispose(); _client = null; }
}

class OpenAiCompatibleProvider implements AiProvider {
  final String apiKey;
  final String baseUrl;
  final String model;
  final String displayName;
  final List<AiMessage> _history = [];
  final HttpClient _httpClient = HttpClient();

  OpenAiCompatibleProvider({required this.apiKey, required this.baseUrl, required this.model, this.displayName = 'OpenAI 兼容模型'});
  @override
  String get name => displayName;

  Uri _endpoint() {
    final normalized = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$normalized/chat/completions');
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> payload) async {
    final request = await _httpClient.postUrl(_endpoint());
    request.headers.set('Authorization', 'Bearer $apiKey');
    request.headers.set('Content-Type', 'application/json');
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('AI 调用失败 (HTTP ${response.statusCode}): $body');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw const FormatException('AI 返回格式无效');
    return decoded;
  }

  @override
  Future<void> sendMessageStreaming(String prompt, AiStreamCallbacks callbacks) async {
    _history.add(AiMessage(role: 'user', content: prompt));
    try {
      final json = await _request({'model': model, 'messages': _history.map((m) => m.toJson()).toList(), 'stream': false});
      final choices = json['choices'] as List?;
      final message = choices?.isNotEmpty == true ? (choices!.first as Map)['message'] as Map? : null;
      final content = message?['content']?.toString() ?? '';
      _history.add(AiMessage(role: 'assistant', content: content));
      callbacks.onText?.call(content, content);
      callbacks.onFinished?.call();
    } catch (error) {
      callbacks.onError?.call(error);
    }
  }

  @override
  Future<void> sendImageStreaming(Uint8List imageBytes, String prompt, AiStreamCallbacks callbacks) async {
    final dataUri = 'data:image/png;base64,${base64Encode(imageBytes)}';
    try {
      final json = await _request({
        'model': model,
        'messages': [
          {'role': 'user', 'content': [
            {'type': 'text', 'text': prompt},
            {'type': 'image_url', 'image_url': {'url': dataUri}},
          ]},
        ],
        'stream': false,
      });
      final choices = json['choices'] as List?;
      final message = choices?.isNotEmpty == true ? (choices!.first as Map)['message'] as Map? : null;
      final content = message?['content']?.toString() ?? '';
      callbacks.onText?.call(content, content);
      callbacks.onFinished?.call();
    } catch (error) {
      callbacks.onError?.call(error);
    }
  }

  void dispose() => _httpClient.close(force: true);
}

class DeepSeekOfficialProvider extends OpenAiCompatibleProvider {
  DeepSeekOfficialProvider(String apiKey, {String model = 'deepseek-chat'})
      : super(apiKey: apiKey, baseUrl: 'https://api.deepseek.com/v1', model: model, displayName: 'DeepSeek 官方 API');
}

enum AiProviderType { deepSeekWeb, deepSeekOfficial, openAiCompatible, siliconFlow }

AiProvider createAiProvider(AiProviderType type, {String token = '', String apiKey = '', String baseUrl = '', String model = ''}) {
  switch (type) {
    case AiProviderType.deepSeekWeb:
      return DeepSeekWebProvider(token);
    case AiProviderType.deepSeekOfficial:
      return DeepSeekOfficialProvider(apiKey, model: model.isEmpty ? 'deepseek-chat' : model);
    case AiProviderType.openAiCompatible:
      return OpenAiCompatibleProvider(apiKey: apiKey, baseUrl: baseUrl.isEmpty ? 'https://api.openai.com/v1' : baseUrl, model: model.isEmpty ? 'gpt-4.1-mini' : model);
    case AiProviderType.siliconFlow:
      return OpenAiCompatibleProvider(apiKey: apiKey, baseUrl: baseUrl.isEmpty ? 'https://api.siliconflow.cn/v1' : baseUrl, model: model.isEmpty ? 'Qwen/Qwen2.5-VL-32B-Instruct' : model, displayName: 'SiliconFlow 视觉模型');
  }
}
