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

bool isLikelyDoubaoSession(String raw) {
  final value = raw.toLowerCase();
  return value.contains('sessionid') || value.contains('session_id') || value.contains('sid_guard') || value.contains('passport_csrf_token');
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

class DoubaoWebProvider implements AiProvider {
  final String cookie;
  final HttpClient _httpClient = HttpClient();
  String? _conversationId;

  DoubaoWebProvider(this.cookie);
  @override
  String get name => '豆包网页版（免费）';

  Uri _endpoint() => Uri.parse('https://www.doubao.com/chat/completion?aid=497858&device_platform=web&doubao_device_platform=web&language=zh&region=CN&sys_region=CN&samantha_web=1&version_code=20800&use_olympus_account=1');

  @override
  Future<void> sendMessageStreaming(String prompt, AiStreamCallbacks callbacks) async {
    if (!isLikelyDoubaoSession(cookie)) {
      callbacks.onError?.call(const FormatException('豆包登录态无效或已过期，请重新打开豆包登录页并读取登录态'));
      return;
    }
    try {
      final request = await _httpClient.postUrl(_endpoint());
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Accept', 'text/event-stream');
      request.headers.set('Origin', 'https://www.doubao.com');
      request.headers.set('Referer', 'https://www.doubao.com/chat/');
      if (cookie.trim().isNotEmpty) request.headers.set('Cookie', cookie.trim());
      final body = {
        'bot_id': '7338286299411103781',
        'conversation_id': _conversationId ?? '',
        'section_id': '',
        'messages': [
          {'role': 'user', 'content_block': [{'block_type': 1001, 'content': {'text_block': {'text': prompt}}}]}
        ],
      };
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();
      if (response.statusCode == 401 || response.statusCode == 403) throw HttpException('豆包登录态已失效（HTTP ${response.statusCode}），请重新登录并读取登录态');
      if (response.statusCode < 200 || response.statusCode >= 300) throw HttpException('豆包网页请求失败（HTTP ${response.statusCode}），请重新登录或检查 Cookie');
      final content = _extractDoubaoText(raw);
      if (content.isEmpty) throw const FormatException('豆包没有返回可读文本；网页协议可能已更新，请改用豆包浏览器页登录后重试');
      callbacks.onText?.call(content, content);
      callbacks.onFinished?.call();
    } catch (error) {
      callbacks.onError?.call(error);
    }
  }

  String _extractDoubaoText(String raw) {
    final briefs = RegExp(r'"brief"\s*:\s*"((?:\\\\.|[^"\\])*)"').allMatches(raw).map((match) {
      try { return jsonDecode('"${match.group(1)}"').toString(); } catch (_) { return match.group(1) ?? ''; }
    }).where((text) => text.trim().isNotEmpty).toList();
    if (briefs.isNotEmpty) return briefs.last;
    final texts = RegExp(r'"text"\s*:\s*"((?:\\\\.|[^"\\])*)"').allMatches(raw).map((match) {
      try { return jsonDecode('"${match.group(1)}"').toString(); } catch (_) { return match.group(1) ?? ''; }
    }).where((text) => text.trim().isNotEmpty).toList();
    return texts.isEmpty ? '' : texts.last;
  }

  @override
  Future<void> sendImageStreaming(Uint8List imageBytes, String prompt, AiStreamCallbacks callbacks) async {
    throw UnsupportedError('豆包网页版当前通过网页会话调用，图片识图请切换到视觉模型');
  }

  @override
  void dispose() => _httpClient.close(force: true);
}

class DeepSeekOfficialProvider extends OpenAiCompatibleProvider {
  DeepSeekOfficialProvider(String apiKey, {String model = 'deepseek-chat'})
      : super(apiKey: apiKey, baseUrl: 'https://api.deepseek.com/v1', model: model, displayName: 'DeepSeek 官方 API');
}

enum AiProviderType { deepSeekWeb, doubaoWeb, deepSeekOfficial, openAiCompatible, siliconFlow }

AiProvider createAiProvider(AiProviderType type, {String token = '', String apiKey = '', String baseUrl = '', String model = ''}) {
  switch (type) {
    case AiProviderType.deepSeekWeb:
      return DeepSeekWebProvider(token);
    case AiProviderType.doubaoWeb:
      return DoubaoWebProvider(token);
    case AiProviderType.deepSeekOfficial:
      return DeepSeekOfficialProvider(apiKey, model: model.isEmpty ? 'deepseek-chat' : model);
    case AiProviderType.openAiCompatible:
      return OpenAiCompatibleProvider(apiKey: apiKey, baseUrl: baseUrl.isEmpty ? 'https://api.openai.com/v1' : baseUrl, model: model.isEmpty ? 'gpt-4.1-mini' : model);
    case AiProviderType.siliconFlow:
      return OpenAiCompatibleProvider(apiKey: apiKey, baseUrl: baseUrl.isEmpty ? 'https://api.siliconflow.cn/v1' : baseUrl, model: model.isEmpty ? 'Qwen/Qwen2.5-VL-32B-Instruct' : model, displayName: 'SiliconFlow 视觉模型');
  }
}
