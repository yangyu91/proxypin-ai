import 'package:flutter/material.dart';

import 'package:proxypin_ai/proxy/subscription_manager.dart';
import 'package:proxypin_ai/network/bin/configuration.dart';
import 'package:proxypin_ai/network/channel/host_port.dart';

class ProxySubscriptionsPage extends StatefulWidget {
  final Configuration? configuration;
  const ProxySubscriptionsPage({super.key, this.configuration});
  @override
  State<ProxySubscriptionsPage> createState() => _ProxySubscriptionsPageState();
}

class _ProxySubscriptionsPageState extends State<ProxySubscriptionsPage> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _manager = SubscriptionManager.instance;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _manager.load();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _import() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() { _loading = true; _error = null; });
    try {
      await _manager.importSubscription(url, name: _nameController.text.trim());
      _urlController.clear();
      _nameController.clear();
    } catch (error) {
      _error = '导入失败：$error';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _connect(ProxyNode node) async {
    final configuration = widget.configuration;
    if (configuration == null) return;
    if (!['http', 'socks', 'socks5'].contains(node.scheme)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该节点需要 Xray/V2Ray 核心，当前版本暂不能直接连接 vmess/vless/trojan')));
      return;
    }
    configuration.externalProxy = ProxyInfo()
      ..enabled = true
      ..capturePacket = true
      ..host = node.address
      ..port = node.port;
    await configuration.flushConfig();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已连接：${node.name}')));
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
                ..._manager.groups.map((group) => Card(
                  child: ExpansionTile(
                    title: Text(group.name),
                    subtitle: Text('${group.nodes.length} 个节点${group.sourceUrl == null ? '' : ' · 已保存订阅'}'),
                    children: group.nodes.map((node) => ListTile(
                      leading: Icon(node.enabled ? Icons.cloud_outlined : Icons.cloud_off_outlined),
                      title: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${node.scheme}://${node.address}:${node.port}'),
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
