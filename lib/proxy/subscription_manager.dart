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
    final uri = Uri.tryParse(value);
    if (uri == null || !['vmess', 'vless', 'trojan', 'ss', 'socks', 'socks5', 'http'].contains(uri.scheme.toLowerCase())) return null;
    final host = uri.host;
    final port = uri.port;
    if (host.isEmpty || port <= 0) return null;
    final scheme = uri.scheme.toLowerCase();
    final name = Uri.decodeComponent(uri.fragment.isEmpty ? '$scheme-$host:$port' : uri.fragment);
    final id = '${scheme}_${host}_$port';
    return ProxyNode(id: id, name: name, scheme: scheme, address: host, port: port, settings: {'raw': value, 'userInfo': uri.userInfo, 'query': uri.queryParameters}, enabled: true);
  }

  Future<int?> testLatency(ProxyNode node, {Duration timeout = const Duration(seconds: 5)}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(node.address, node.port, timeout: timeout);
      await socket.close();
      node.latencyMs = stopwatch.elapsedMilliseconds;
      await save();
      return node.latencyMs;
    } catch (_) {
      node.latencyMs = null;
      await save();
      return null;
    }
  }
}
