import 'package:flutter/material.dart';
import 'package:proxypin_ai/network/channel/host_port.dart';

import 'package:proxypin_ai/proxy/subscription_manager.dart';
import 'package:proxypin_ai/network/bin/configuration.dart';
import 'package:proxypin_ai/network/bin/server.dart';
import 'package:proxypin_ai/network/vpn/android_vpn.dart';

class ProxySubscriptionsPage extends StatefulWidget {
  final Configuration? configuration;
  final bool autoConnectFastest;
  const ProxySubscriptionsPage({super.key, this.configuration, this.autoConnectFastest = false});
  @override
  State<ProxySubscriptionsPage> createState() => _ProxySubscriptionsPageState();
}

class _ProxySubscriptionsPageState extends State<ProxySubscriptionsPage> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _manager = SubscriptionManager.instance;
  bool _loading = true;
  bool _vpnRunning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _manager.load();
    _vpnRunning = await AndroidVpnController.isRunning();
    if (mounted) setState(() => _loading = false);
    if (widget.autoConnectFastest) await _autoConnectFastest();
  }

  Future<void> _autoConnectFastest() async {
    final nodes = _manager.groups.expand((group) => group.nodes).where((node) => node.enabled && node.scheme == 'http').toList();
    if (nodes.isEmpty) return;
    // 已缓存的“端口可达”延迟不足以证明节点可代理 HTTPS；每次自动连接前
    // 都重新完成 HTTP CONNECT 验证，避免失效节点让 Firefox 全部导航超时。
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在验证可用代理节点…')));
    await Future.wait(nodes.map((node) => _manager.testLatency(node, timeout: const Duration(seconds: 4))));
    final candidates = nodes.where((node) => node.latencyMs != null && node.latencyMs! >= 0).toList();
    if (candidates.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有检测到可用于 HTTPS 解密链路的 HTTP 节点')));
      return;
    }
    candidates.sort((a, b) => a.latencyMs!.compareTo(b.latencyMs!));
    await _connect(candidates.first);
  }

  Future<void> _import() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() { _loading = true; _error = null; });
    try {
      final group = await _manager.importSubscription(url, name: _nameController.text.trim());
      _urlController.clear();
      _nameController.clear();
      if (mounted) setState(() {});
      // 默认对新导入分组的全部节点测速，结果会持久化并实时刷新。
      await _manager.testGroup(group);
      if (mounted) setState(() {});
    } catch (error) {
      _error = '导入失败：$error';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _connect(ProxyNode node) async {
    final configuration = widget.configuration;
    if (configuration == null) return;
    if (node.scheme != 'http') {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该节点需要 Xray/V2Ray 或 SOCKS 核心；当前 HTTPS 解密级联仅支持 HTTP 代理节点')));
      return;
    }
    // 连接按钮也必须复验完整 HTTP CONNECT，而不能相信旧的 TCP 延迟记录。
    final latency = await _manager.testLatency(node, timeout: const Duration(seconds: 4));
    if (latency == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该节点无法完成 HTTPS 代理握手，未连接；浏览器将保持直连抓包。')));
      return;
    }

    final proxyServer = ProxyServer.current;
    if (proxyServer == null || !proxyServer.isRunning) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('本地抓包服务未启动，无法建立 Firefox → 本地 MITM → 外部节点链路')));
      return;
    }
    final userInfo = node.settings['userInfo']?.toString() ?? '';
    final auth = userInfo.isEmpty ? const <String>[] : userInfo.split(':');
    configuration.externalProxy = ProxyInfo()
      ..enabled = true
      ..capturePacket = true
      ..host = node.address
      ..port = node.port
      ..username = auth.isNotEmpty ? Uri.decodeComponent(auth.first) : null
      ..password = auth.length > 1 ? Uri.decodeComponent(auth.sublist(1).join(':')) : null;
    // Firefox/GeckoView 固定请求本机 ProxyPin；本地 MITM 再使用 externalProxy 级联到订阅节点。
    configuration.enableSsl = true;
    configuration.enabledHttp2 = true;
    await configuration.flushConfig();
    try {
      final vpnProxy = ProxyInfo.of('127.0.0.1', proxyServer.port)
        ..enabled = true
        ..capturePacket = true;
      final prepared = await AndroidVpnController.start(vpnProxy);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final running = prepared || await AndroidVpnController.isRunning();
      if (mounted) {
        setState(() => _vpnRunning = running);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(running ? 'VPN 已连接：${node.name}；Firefox 流量将先进入本机 HTTPS MITM，再级联外部节点' : '已请求 VPN 权限，请在系统弹窗中允许后重试')));
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('VPN 启动失败：$error')));
    }
  }

  Future<void> _disconnectVpn() async {
    await AndroidVpnController.stop();
    if (mounted) setState(() => _vpnRunning = false);
  }

  Future<void> _test(ProxyNode node) async {
    setState(() => node.latencyMs = -1);
    await _manager.testLatency(node);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('代理订阅与节点')),
      body: _loading && _manager.groups.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      TextField(controller: _urlController, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: '订阅地址', hintText: 'https://.../subscription.txt')),
                      const SizedBox(height: 8),
                      TextField(controller: _nameController, decoration: const InputDecoration(labelText: '分组名称（可选）')),
                      const SizedBox(height: 12),
                      Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: _loading ? null : _import, icon: const Icon(Icons.download), label: const Text('导入订阅'))),
                      if (_error != null) Align(alignment: Alignment.centerLeft, child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: Icon(_vpnRunning ? Icons.vpn_lock : Icons.vpn_key_off, color: _vpnRunning ? Colors.green : null),
                    title: Text(_vpnRunning ? 'VPN 已连接' : 'VPN 未连接'),
                    subtitle: Text(_vpnRunning ? '系统状态栏应显示 VPN 图标，浏览器和应用流量会进入 VPN' : '连接节点后会申请 Android VPN 权限'),
                    trailing: _vpnRunning ? TextButton(onPressed: _disconnectVpn, child: const Text('断开')) : null,
                  ),
                ),
                ..._manager.groups.map((group) => Card(
                  child: ExpansionTile(
                    title: Text(group.name),
                    subtitle: Text('${group.nodes.length} 个节点${group.sourceUrl == null ? '' : ' · 已保存订阅'}'),
                    children: group.nodes.map((node) => ListTile(
                      leading: Icon(node.enabled ? Icons.cloud_outlined : Icons.cloud_off_outlined),
                      title: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${node.scheme}://${node.address}:${node.port}${node.scheme == 'http' ? ' · 支持 HTTPS 解密级联' : ' · 需要协议核心'}'),
                      trailing: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(node.latencyMs == -1 ? '测速中' : node.latencyMs == null ? '未测速' : '${node.latencyMs} ms'),
                        IconButton(tooltip: '测速', icon: const Icon(Icons.speed_outlined, size: 20), onPressed: () => _test(node)),
                        IconButton(tooltip: '连接', icon: const Icon(Icons.link, size: 20), onPressed: () => _connect(node)),
                      ]),
                      onTap: () => _connect(node),
                    )).toList(),
                  ),
                )),
              ],
            ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }
}
