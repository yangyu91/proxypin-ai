/// DeepSeek 网页版客户端（白嫖通道）。
///
/// 移植自 deepseek-pp 的 core/deepseek/active-client.ts，
/// 复用 chat.deepseek.com 登录态（userToken）调用网页版 API。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'deepseek_contracts.dart';
import 'deepseek_pow.dart';
import 'deepseek_request_codec.dart';
import 'deepseek_stream_codec.dart';

/// DeepSeek 异常
class DeepSeekException implements Exception {
  final String message;
  DeepSeekException(this.message);
  @override
  String toString() => message;
}

/// 流式回调
class DeepSeekStreamCallbacks {
  final void Function(String text, String fullText)? onTextChunk;
  final void Function(String reasoning, String fullReasoning)? onReasoningChunk;
  final void Function()? onFinished;
  final void Function(Object error)? onError;

  DeepSeekStreamCallbacks(
      {this.onTextChunk, this.onReasoningChunk, this.onFinished, this.onError});
}

/// DeepSeek 网页版客户端
class DeepSeekWebClient {
  final String token;
  final HttpClient _httpClient = HttpClient();

  DeepSeekWebClient(this.token);

  /// 创建聊天会话，返回 chat_session_id。
  Future<String> createChatSession() async {
    final headers = createClientHeaders(token);
    final response = await _postJson(
      '$deepSeekWebOrigin${DeepSeekWebRoutes.createSession}',
      headers: headers,
      body: encodeCreateSessionRequest(),
    );
    final json = await _readJson(response);
    final data = json?['data'] as Map<String, dynamic>?;
    final chatSessionId =
        (data?['biz_data']?['chat_session']?['id'])?.toString();
    if (chatSessionId == null || chatSessionId.isEmpty) {
      throw DeepSeekException('创建 DeepSeek 会话失败: ${jsonEncode(data ?? json)}');
    }
    return chatSessionId;
  }

  /// 获取 PoW 头。
  Future<Map<String, String>> _createPowHeaders(String targetPath) async {
    final headers = createClientHeaders(token);
    final response = await _postJson(
      '$deepSeekWebOrigin${DeepSeekWebRoutes.powChallenge}',
      headers: headers,
      body: encodePowChallengeRequest(targetPath),
    );
    final json = await _readJson(response);
    final challengeData =
        (json?['data']?['biz_data']?['challenge']) as Map<String, dynamic>?;
    if (challengeData == null) {
      throw DeepSeekException('获取 DeepSeek PoW 挑战失败: ${jsonEncode(json)}');
    }
    final challenge = DeepSeekPowChallenge.fromJson(challengeData);
    final powResponse = solveDeepSeekPow(challenge, targetPath: targetPath);
    return {'X-DS-PoW-Response': powResponse};
  }

  /// 流式发送补全请求。
  Future<void> submitPromptStreaming(
    DeepSeekCompletionInput input,
    DeepSeekStreamCallbacks callbacks,
  ) async {
    final headers = createClientHeaders(token);
    final powHeaders = await _createPowHeaders(DeepSeekWebRoutes.completion);
    final allHeaders = <String, String>{
      'content-type': 'application/json',
      deepSeekBypassHookHeader: '1',
      ...headers,
      ...powHeaders,
    };

    final client = HttpClient();
    try {
      final request = await client.postUrl(
          Uri.parse('$deepSeekWebOrigin${DeepSeekWebRoutes.completion}'));
      allHeaders.forEach((k, v) => request.headers.set(k, v));
      request.add(utf8.encode(jsonEncode(encodeCompletionRequest(input))));
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        final body = await response.transform(utf8.decoder).join();
        throw DeepSeekException(
            'DeepSeek 补全失败 (HTTP ${response.statusCode}): $body');
      }

      final decoder = DeepSeekStreamDecoder();
      await for (final bytes in response) {
        final chunk = decoder.push(bytes);
        if (chunk.text.isNotEmpty && callbacks.onTextChunk != null) {
          callbacks.onTextChunk!(chunk.text, decoder.answerText);
        }
        if (chunk.reasoning.isNotEmpty && callbacks.onReasoningChunk != null) {
          callbacks.onReasoningChunk!(chunk.reasoning, decoder.reasoningText);
        }
      }
      final finalChunk = decoder.finish();
      if (finalChunk.text.isNotEmpty && callbacks.onTextChunk != null) {
        callbacks.onTextChunk!(finalChunk.text, decoder.answerText);
      }
      if (finalChunk.reasoning.isNotEmpty &&
          callbacks.onReasoningChunk != null) {
        callbacks.onReasoningChunk!(
            finalChunk.reasoning, decoder.reasoningText);
      }
      callbacks.onFinished?.call();
    } catch (e) {
      callbacks.onError?.call(e);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _postJson(
    String url, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
  }) async {
    final request = await _httpClient.postUrl(Uri.parse(url));
    headers.forEach((k, v) => request.headers.set(k, v));
    request.headers.set('content-type', 'application/json');
    request.add(utf8.encode(jsonEncode(body)));
    return request.close();
  }

  Future<dynamic> _readJson(HttpClientResponse response) async {
    final text = await response.transform(utf8.decoder).join();
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _httpClient.close(force: true);
  }
}
