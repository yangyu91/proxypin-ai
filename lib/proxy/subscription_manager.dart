import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class ProxyNode {
  final String id;
  final String name;
  final String scheme;
  final String address;
  final int port;
  final Map<String, dynamic> settings;
  int? latencyMs;
  bool enabled;

  ProxyNode({required this.id, required this.name, required this.scheme, required this.address, required this.port, this.settings = const {}, this.latencyMs, this.enabled = true});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'scheme': scheme, 'address': address, 'port': port, 'settings': settings, 'latencyMs': latencyMs, 'enabled': enabled};
  factory ProxyNode.fromJson(Map<String, dynamic> json) => ProxyNode(id: json['id']?.toString() ?? '', name: json['name']?.toString() ?? '', scheme: json['scheme']?.toString() ?? '', address: json['address']?.toString() ?? '', port: int.tryParse(json['port']?.toString() ?? '') ?? 0, settings: Map<String, dynamic>.from(json['settings'] is Map ? json['settings'] : const {}), latencyMs: int.tryParse(json['latencyMs']?.toString() ?? ''), enabled: json['enabled'] != false);
}

class ProxyGroup {
  final String id;
  String name;
  String? sourceUrl;
  List<ProxyNode> nodes;

  ProxyGroup({required this.id, required this.name, this.sourceUrl, this.nodes = const []});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'sourceUrl': sourceUrl, 'nodes': nodes.map((node) => node.toJson()).toList()};
  factory ProxyGroup.fromJson(Map<String, dynamic> json) => ProxyGroup(id: json['id']?.toString() ?? '', name: json['name']?.toString() ?? '', sourceUrl: json['sourceUrl']?.toString(), nodes: (json['nodes'] is List ? json['nodes'] as List : const []).whereType<Map>().map((node) => ProxyNode.fromJson(Map<String, dynamic>.from(node))).toList());
}

class SubscriptionManager {
  static const _groupsKey = 'proxy_subscription_groups';
  static final SubscriptionManager instance = SubscriptionManager._();
  SubscriptionManager._();
  List<ProxyGroup> groups = [];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_groupsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final value = jsonDecode(raw);
      groups = value is List ? value.whereType<Map>().map((item) => ProxyGroup.fromJson(Map<String, dynamic>.from(item))).toList() : [];
    } catch (_) {
      groups = [];
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_groupsKey, jsonEncode(groups.map((group) => group.toJson()).toList()));
  }

  Future<ProxyGroup> importSubscription(String url, {String? name}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'ProxyPin/${Platform.operatingSystem}');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) throw HttpException('订阅请求失败：HTTP ${response.statusCode}');
      final raw = await response.transform(utf8.decoder).join();
      final nodes = parseSubscription(raw);
      final group = ProxyGroup(id: DateTime.now().microsecondsSinceEpoch.toString(), name: name?.trim().isNotEmpty == true ? name!.trim() : '订阅 ${groups.length + 1}', sourceUrl: url, nodes: nodes);
      groups = [...groups.where((item) => item.sourceUrl != url), group];
      await save();
      return group;
    } finally {
      client.close(force: true);
    }
  }

  List<ProxyNode> parseSubscription(String raw) {
    final decoded = _decodeSubscription(raw);
    final nodes = <ProxyNode>[];
    for (final line in decoded.split(RegExp(r'\r?\n')).map((line) => line.trim()).where((line) => line.isNotEmpty)) {
      final node = _parseUri(line, nodes.length);
      if (node != null && nodes.every((item) => item.id != node.id)) nodes.add(node);
    }
    return nodes;
  }

  String _decodeSubscription(String raw) {
    final value = raw.trim();
    if (value.contains('://')) return value;
    try {
      final normalized = base64.normalize(value.replaceAll(RegExp(r'\s+'), ''));
      return utf8.decode(base64.decode(normalized));
    } catch (_) {
      return value;
    }
  }

  ProxyNode? _parseUri(String value, int index) {
    final scheme = value.substringBefore('://').toLowerCase();
    if (!['vmess', 'vless', 'trojan', 'ss', 'socks', 'socks5', 'http'].contains(scheme)) return null;
    if (scheme == 'vmess') return _parseVmess(value, index);
    if (scheme == 'ss') return _parseShadowsocks(value, index);

    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty || uri.port <= 0) return null;
    final name = Uri.decodeComponent(uri.fragment.isEmpty ? '$scheme-${uri.host}:${uri.port}' : uri.fragment);
    final id = '${scheme}_${uri.host}_${uri.port}';
    return ProxyNode(id: id, name: name, scheme: scheme, address: uri.host, port: uri.port, settings: {'raw': value, 'userInfo': uri.userInfo, 'query': uri.queryParameters}, enabled: true);
  }

  ProxyNode? _parseVmess(String value, int index) {
    try {
      final encoded = value.substringAfter('://').split('#').first;
      final decoded = jsonDecode(_decodeUrlSafeBase64(encoded));
      if (decoded is! Map) return null;
      final host = decoded['add']?.toString() ?? '';
      final port = int.tryParse(decoded['port']?.toString() ?? '') ?? 0;
      if (host.isEmpty || port <= 0) return null;
      final name = decoded['ps']?.toString().trim();
      return ProxyNode(
        id: 'vmess_${host}_$port',
        name: name == null || name.isEmpty ? 'vmess-$host:$port' : name,
        scheme: 'vmess',
        address: host,
        port: port,
        settings: {'raw': value, 'userInfo': '', 'query': <String, String>{}},
        enabled: true,
      );
    } catch (_) {
      return null;
    }
  }

  ProxyNode? _parseShadowsocks(String value, int index) {
    try {
      final fragmentIndex = value.indexOf('#');
      final fragment = fragmentIndex >= 0 ? value.substring(fragmentIndex + 1) : '';
      final compact = value.substring('ss://'.length, fragmentIndex >= 0 ? fragmentIndex : value.length);
      final normalized = compact.contains('@') ? compact : _decodeUrlSafeBase64(compact);
      final uri = Uri.tryParse('ss://$normalized');
      if (uri == null || uri.host.isEmpty || uri.port <= 0) return null;
      final name = fragment.isEmpty ? 'ss-${uri.host}:${uri.port}' : Uri.decodeComponent(fragment);
      return ProxyNode(
        id: 'ss_${uri.host}_${uri.port}',
        name: name,
        scheme: 'ss',
        address: uri.host,
        port: uri.port,
        settings: {'raw': value, 'userInfo': uri.userInfo, 'query': uri.queryParameters},
        enabled: true,
      );
    } catch (_) {
      return null;
    }
  }

  String _decodeUrlSafeBase64(String value) {
    final normalized = base64.normalize(value.trim().replaceAll('-', '+').replaceAll('_', '/'));
    return utf8.decode(base64.decode(normalized));
  }

  Future<List<int?>> testGroup(ProxyGroup group, {Duration timeout = const Duration(seconds: 5)}) async {
    // HTTP 节点必须完成 CONNECT 握手才可用于 Firefox → MITM 级联；单纯 TCP
    // 端口可连接不足以说明它是一个可工作的代理。其他协议节点暂只探测端口。
    return Future.wait(group.nodes.map((node) => testLatency(node, timeout: timeout)));
  }

  Future<int?> testLatency(ProxyNode node, {Duration timeout = const Duration(seconds: 5)}) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(node.address, node.port, timeout: timeout);
      if (node.scheme == 'http') {
        await _verifyHttpConnectProxy(socket, username: _nodeUsername(node), password: _nodePassword(node), timeout: timeout);
      }
      node.latencyMs = stopwatch.elapsedMilliseconds;
      return node.latencyMs;
    } catch (_) {
      node.latencyMs = null;
      return null;
    } finally {
      socket?.destroy();
      await save();
    }
  }

  String? _nodeUsername(ProxyNode node) {
    final userInfo = node.settings['userInfo']?.toString() ?? '';
    if (userInfo.isEmpty) return null;
    return Uri.decodeComponent(userInfo.split(':').first);
  }

  String? _nodePassword(ProxyNode node) {
    final userInfo = node.settings['userInfo']?.toString() ?? '';
    final separator = userInfo.indexOf(':');
    if (separator < 0) return null;
    return Uri.decodeComponent(userInfo.substring(separator + 1));
  }

  /// 验证一个 HTTP 代理能否真正完成 HTTPS CONNECT，而非仅检查 TCP 端口。
  /// 返回端到端握手延迟；返回 null 表示节点不可用于 Firefox/MITM 级联。
  Future<int?> testHttpProxyEndpoint(
    String host,
    int port, {
    String? username,
    String? password,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      await _verifyHttpConnectProxy(socket, username: username, password: password, timeout: timeout);
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _verifyHttpConnectProxy(
    Socket socket, {
    String? username,
    String? password,
    required Duration timeout,
  }) async {
    final crlf = String.fromCharCode(13) + String.fromCharCode(10);
    final credentials = username == null && password == null ? null : '${username ?? ''}:${password ?? ''}';
    final authorization = credentials == null ? '' : 'Proxy-Authorization: Basic ${base64Encode(utf8.encode(credentials))}$crlf';
    socket.write(
      'CONNECT detectportal.firefox.com:443 HTTP/1.1$crlf'
      'Host: detectportal.firefox.com:443$crlf'
      '$authorization'
      'Connection: close$crlf$crlf',
    );
    await socket.flush();
    final firstLine = await utf8.decoder
        .bind(socket.cast<List<int>>())
        .transform(const LineSplitter())
        .first
        .timeout(timeout);
    if (!firstLine.startsWith('HTTP/1.1 200') && !firstLine.startsWith('HTTP/1.0 200')) {
      throw HttpException('HTTP 代理 CONNECT 验证失败：$firstLine');
    }
  }
}
