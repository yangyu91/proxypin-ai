import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:proxypin_ai/network/http/http.dart' as proxy_http;

/// ProxyPin 本地 MCP Bridge。
///
/// 只绑定 127.0.0.1，使用内存随机 token 做配对；写操作在当前版本只返回
/// preview/confirmation_required，不会让外部模型静默发包或修改代理配置。
class ProxyPinMcpBridge {
  final List<proxy_http.HttpRequest> Function() requestsProvider;
  final bool Function() proxyRunningProvider;
  final int proxyPort;
  final String token = _randomToken();
  io.HttpServer? _server;

  ProxyPinMcpBridge({required this.requestsProvider, required this.proxyRunningProvider, required this.proxyPort});

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;

  Future<int> start({int port = 0}) async {
    if (_server != null) return _server!.port;
    _server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle, onError: (_) {});
    return _server!.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(io.HttpRequest request) async {
    request.response.headers.contentType = io.ContentType.json;
    if (request.method != 'POST' || request.uri.path != '/mcp') {
      request.response.statusCode = io.HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'not_found'}));
      await request.response.close();
      return;
    }
    if (request.headers.value('x-proxypin-token') != token) {
      request.response.statusCode = io.HttpStatus.unauthorized;
      request.response.write(jsonEncode({'error': 'pairing_required'}));
      await request.response.close();
      return;
    }
    try {
      final body = await request.cast<List<int>>().transform(utf8.decoder).join();
      final message = jsonDecode(body);
      final response = await _dispatch(message is Map<String, dynamic> ? message : <String, dynamic>{});
      request.response.write(jsonEncode(response));
    } catch (error) {
      request.response.statusCode = io.HttpStatus.badRequest;
      request.response.write(jsonEncode({'jsonrpc': '2.0', 'id': null, 'error': {'code': -32700, 'message': '$error'}}));
    }
    await request.response.close();
  }

  Future<Map<String, dynamic>> _dispatch(Map<String, dynamic> message) async {
    final id = message['id'];
    final method = message['method']?.toString() ?? '';
    final params = message['params'] is Map ? Map<String, dynamic>.from(message['params'] as Map) : <String, dynamic>{};
    switch (method) {
      case 'initialize':
        return _result(id, {'protocolVersion': '2025-06-18', 'serverInfo': {'name': 'proxypin-mcp', 'version': '0.1.0'}, 'capabilities': {'tools': {}}});
      case 'notifications/initialized':
        return _result(id, {});
      case 'tools/list':
        return _result(id, {'tools': _tools()});
      case 'tools/call':
        return _callTool(id, params['name']?.toString() ?? '', params['arguments'] is Map ? Map<String, dynamic>.from(params['arguments'] as Map) : {});
      default:
        return {'jsonrpc': '2.0', 'id': id, 'error': {'code': -32601, 'message': 'Unknown MCP method: $method'}};
    }
  }

  List<Map<String, dynamic>> _tools() => [
        {'name': 'proxy_status', 'description': '读取 ProxyPin 代理服务状态和监听端口。', 'inputSchema': {'type': 'object', 'properties': {}}},
        {'name': 'capture_list', 'description': '读取当前抓包列表，可按关键词和数量筛选。', 'inputSchema': {'type': 'object', 'properties': {'query': {'type': 'string'}, 'limit': {'type': 'integer'}}}},
        {'name': 'capture_get', 'description': '读取指定请求的完整结构化数据。', 'inputSchema': {'type': 'object', 'required': ['request_id'], 'properties': {'request_id': {'type': 'string'}}}},
        {'name': 'request_replay_preview', 'description': '生成重放/改包预览，必须由用户确认后才能执行。', 'inputSchema': {'type': 'object', 'required': ['request_id'], 'properties': {'request_id': {'type': 'string'}, 'changes': {'type': 'object'}}}},
      ];

  Future<Map<String, dynamic>> _callTool(Object? id, String name, Map<String, dynamic> arguments) async {
    switch (name) {
      case 'proxy_status':
        return _result(id, {'content': [{'type': 'text', 'text': jsonEncode({'running': proxyRunningProvider(), 'port': proxyPort, 'mcpPort': boundPort, 'transport': 'localhost-http', 'sensitiveData': 'redacted-by-default'})}]});
      case 'capture_list':
        final query = (arguments['query']?.toString() ?? '').toLowerCase();
        final limit = min(max(int.tryParse(arguments['limit']?.toString() ?? '50') ?? 50, 1), 200);
        final items = requestsProvider().where((request) => query.isEmpty || request.requestUrl.toLowerCase().contains(query) || request.method.name.toLowerCase().contains(query)).take(limit).map(_summary).toList();
        return _result(id, {'content': [{'type': 'text', 'text': jsonEncode(items)}]});
      case 'capture_get':
        final request = _find(arguments['request_id']?.toString());
        if (request == null) return _toolError(id, 'request_not_found');
        return _result(id, {'content': [{'type': 'text', 'text': jsonEncode(_redactedRequest(request))}]});
      case 'request_replay_preview':
        final request = _find(arguments['request_id']?.toString());
        if (request == null) return _toolError(id, 'request_not_found');
        return _result(id, {'content': [{'type': 'text', 'text': jsonEncode({'requires_confirmation': true, 'request_id': request.requestId, 'url': request.requestUrl, 'changes': arguments['changes'] ?? {}, 'message': '预览已生成，等待用户在 ProxyPin 中确认后执行'})}]});
      default:
        return _toolError(id, 'Unknown tool: $name');
    }
  }

  proxy_http.HttpRequest? _find(String? id) => requestsProvider().where((request) => request.requestId == id).firstOrNull;

  Map<String, dynamic> _summary(proxy_http.HttpRequest request) => {'request_id': request.requestId, 'method': request.method.name, 'url': _redactUrl(request.requestUrl), 'status': request.response?.status.code};

  Map<String, dynamic> _redactedRequest(proxy_http.HttpRequest request) => {'request_id': request.requestId, 'method': request.method.name, 'url': _redactUrl(request.requestUrl), 'headers': {for (final entry in request.headers.entries) entry.key: _isSensitive(entry.key) ? ['[已隐藏]'] : entry.value}, 'body_size': request.body?.length ?? 0, 'response_status': request.response?.status.code};

  String _redactUrl(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return url;
    final query = parsed.queryParameters.map((key, value) => MapEntry(key, _isSensitive(key) ? '[已隐藏]' : value));
    return parsed.replace(queryParameters: query).toString();
  }

  bool _isSensitive(String key) {
    final value = key.toLowerCase();
    return value == 'authorization' || value == 'cookie' || value == 'set-cookie' || value.contains('token') || value.contains('secret') || value.contains('password') || value.contains('api-key');
  }

  Map<String, dynamic> _result(Object? id, Object result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
  Map<String, dynamic> _toolError(Object? id, String message) => {'jsonrpc': '2.0', 'id': id, 'result': {'isError': true, 'content': [{'type': 'text', 'text': message}]}};

  static String _randomToken() {
    final random = Random.secure();
    return List<int>.generate(24, (_) => random.nextInt(256)).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
