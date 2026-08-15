import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:proxypin_ai/ai/ai_workspace.dart';
import 'package:proxypin_ai/network/bin/configuration.dart';
import 'package:proxypin_ai/network/http/http.dart';
import 'package:proxypin_ai/network/vpn/android_vpn.dart';
import 'package:proxypin_ai/proxy/subscription_manager.dart';
import 'package:proxypin_ai/ui/desktop/request/ai_chat.dart';
import 'package:proxypin_ai/ui/mobile/setting/proxy_subscriptions.dart';

/// ProxyPin 内置浏览器，浏览器请求可复用当前抓包/VPN 网络链路。
class ProxyPinBrowserPage extends StatefulWidget {
  final List<HttpRequest> Function() requestsProvider;
  final void Function(HttpRequest request)? onCapturedRequest;
  final void Function(HttpResponse response)? onCapturedResponse;

  const ProxyPinBrowserPage({super.key, required this.requestsProvider, this.onCapturedRequest, this.onCapturedResponse});

  @override
  State<ProxyPinBrowserPage> createState() => _ProxyPinBrowserPageState();
}

class _ProxyPinBrowserPageState extends State<ProxyPinBrowserPage> {
  static const _homeUrl = 'https://www.baidu.com/';
  late final WebViewController _controller;
  final _addressController = TextEditingController(text: _homeUrl);
  final _bookmarks = <String>[];
  final _tabs = <String>[_homeUrl];
  Timer? _proxyStatusTimer;
  bool _loading = true;
  bool _vpnRunning = false;
  int _progress = 0;
  String _title = '浏览器';
  String _proxyLabel = '代理未连接';
  HttpRequest? _activeBrowserRequest;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(ThemeData.dark().scaffoldBackgroundColor)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => setState(() {
            _progress = progress;
            _loading = progress < 100;
          }),
          onPageStarted: (url) {
            final request = HttpRequest(HttpMethod.get, url);
            request.attributes['source'] = 'builtin_browser';
            request.attributes['captureMode'] = 'webview_navigation';
            request.headers.set('User-Agent', 'ProxyPin-BuiltInBrowser');
            _activeBrowserRequest = request;
            widget.onCapturedRequest?.call(request);
            setState(() {
              _loading = true;
              _addressController.text = url;
              if (_tabs.isEmpty) _tabs.add(url);
              _tabs[_tabs.length - 1] = url;
              AiWorkspace.instance.setBrowserPage(url: url);
            });
          },
          onPageFinished: (url) async {
            final pageTitle = await _controller.getTitle();
            if (!mounted) return;
            setState(() {
              _loading = false;
              _addressController.text = url;
              _title = pageTitle?.trim().isNotEmpty == true ? pageTitle!.trim() : '浏览器';
              if (_activeBrowserRequest?.requestUrl == url) {
                final response = HttpResponse(HttpStatus.ok);
                response.request = _activeBrowserRequest;
                response.responseTime = DateTime.now();
                _activeBrowserRequest!.response = response;
                widget.onCapturedResponse?.call(response);
              }
              AiWorkspace.instance.setBrowserPage(url: url, title: _title);
            });
          },
          onWebResourceError: (_) => setState(() => _loading = false),
        ),
      )
      ..loadRequest(Uri.parse(_homeUrl));
    _refreshProxyStatus();
    _proxyStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshProxyStatus());
  }

  @override
  void dispose() {
    _proxyStatusTimer?.cancel();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _refreshProxyStatus() async {
    final running = await AndroidVpnController.isRunning();
    final config = await Configuration.instance;
    final proxy = config.externalProxy;
    ProxyNode? matchingNode;
    if (proxy?.host != null && proxy?.port != null) {
      for (final node in SubscriptionManager.instance.groups.expand((group) => group.nodes)) {
        if (node.address == proxy.host && node.port == proxy.port) {
          matchingNode = node;
          break;
        }
      }
    }
    final label = matchingNode != null
        ? '${matchingNode.name} · ${matchingNode.latencyMs != null && matchingNode.latencyMs! >= 0 ? '${matchingNode.latencyMs} ms' : '${matchingNode.address}:${matchingNode.port}'}'
        : proxy?.host != null && proxy?.port != null
            ? '${proxy!.host}:${proxy.port}'
            : '代理未连接';
    if (!mounted) return;
    if (_vpnRunning != running || _proxyLabel != label) {
      setState(() {
        _vpnRunning = running;
        _proxyLabel = running ? label : '代理未连接';
      });
    }
  }

  Future<void> _openAddress() async {
    final raw = _addressController.text.trim();
    if (raw.isEmpty) return;
    final value = raw.contains('://')
        ? raw
        : (raw.contains('.') && !raw.contains(' ')
            ? 'https://$raw'
            : 'https://www.baidu.com/s?wd=${Uri.encodeComponent(raw)}');
    await _controller.loadRequest(Uri.tryParse(value) ?? Uri.parse(_homeUrl));
  }

  Future<void> _showBrowserMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.home_outlined), title: const Text('主页'), onTap: () { Navigator.pop(sheetContext); _goHome(); }),
          ListTile(leading: const Icon(Icons.refresh), title: const Text('刷新页面'), onTap: () { Navigator.pop(sheetContext); _controller.reload(); }),
          ListTile(leading: const Icon(Icons.share_outlined), title: const Text('分享链接'), onTap: () async { Navigator.pop(sheetContext); await SharePlus.instance.share(ShareParams(uri: Uri.tryParse(_addressController.text))); }),
          ListTile(leading: const Icon(Icons.bookmark_add_outlined), title: const Text('收藏当前页面'), onTap: () { Navigator.pop(sheetContext); _addBookmark(); }),
          ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: const Text('清除浏览数据'), onTap: () async { Navigator.pop(sheetContext); await WebViewCookieManager().clearCookies(); }),
        ]),
      ),
    );
  }

  void _goHome() => _controller.loadRequest(Uri.parse(_homeUrl));

  void _addBookmark() {
    final url = _addressController.text.trim();
    if (url.isEmpty || _bookmarks.contains(url)) return;
    setState(() => _bookmarks.add(url));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已添加到书签')));
  }

  void _openBookmarks() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: _bookmarks.isEmpty
            ? const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('暂无书签，先收藏当前页面吧')))
            : ListView(shrinkWrap: true, children: _bookmarks.map((url) => ListTile(
                leading: const Icon(Icons.bookmark), title: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () { Navigator.pop(sheetContext); _controller.loadRequest(Uri.parse(url)); },
                trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { setState(() => _bookmarks.remove(url)); Navigator.pop(sheetContext); _openBookmarks(); },),
              )).toList()),
      ),
    );
  }

  void _openTabs() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('标签页（${_tabs.length}）'), trailing: IconButton(icon: const Icon(Icons.add), onPressed: () { Navigator.pop(sheetContext); _newTab(); })),
          ..._tabs.asMap().entries.map((entry) => ListTile(
            leading: Icon(entry.key == _tabs.length - 1 ? Icons.check_circle : Icons.tab_outlined),
            title: Text(entry.value, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () { Navigator.pop(sheetContext); _controller.loadRequest(Uri.parse(entry.value)); },
          )),
        ]),
      ),
    );
  }

  void _newTab() {
    setState(() => _tabs.add(_homeUrl));
    _controller.loadRequest(Uri.parse(_homeUrl));
  }

  void _openProxy() async {
    final config = await Configuration.instance;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProxySubscriptionsPage(configuration: config, autoConnectFastest: true)));
    _refreshProxyStatus();
  }

  void _openAi() {
    AiWorkspace.instance.setBrowserPage(url: _addressController.text, title: _title);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SizedBox(height: MediaQuery.of(context).size.height * .92, child: AiChatPanel(requestsProvider: () => widget.requestsProvider())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: Container(height: 38, decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)), child: TextField(
          controller: _addressController, keyboardType: TextInputType.url, textInputAction: TextInputAction.go, onSubmitted: (_) => _openAddress(),
          decoration: const InputDecoration(border: InputBorder.none, prefixIcon: Icon(Icons.lock_outline, size: 17), hintText: '搜索或输入网址', contentPadding: EdgeInsets.symmetric(vertical: 9)),
        )),
        actions: [
          IconButton(tooltip: '返回', icon: const Icon(Icons.chevron_left), onPressed: () async { if (await _controller.canGoBack()) _controller.goBack(); }),
          IconButton(tooltip: '前进', icon: const Icon(Icons.chevron_right), onPressed: () async { if (await _controller.canGoForward()) _controller.goForward(); }),
          IconButton(tooltip: '更多', icon: const Icon(Icons.more_horiz), onPressed: _showBrowserMenu),
        ],
        bottom: _loading ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100)) : null,
      ),
      body: Stack(children: [WebViewWidget(controller: _controller), Positioned(right: 18, bottom: 22, child: FloatingActionButton.small(heroTag: 'browser-ai-fab', tooltip: 'AI 分析当前抓包', onPressed: _openAi, child: const Icon(Icons.auto_awesome_rounded)))]),
      bottomNavigationBar: SafeArea(top: false, child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        IconButton(tooltip: '主页', icon: const Icon(Icons.home_outlined), onPressed: _goHome),
        IconButton(tooltip: '标签页', icon: const Icon(Icons.tab_outlined), onPressed: _openTabs),
        IconButton(tooltip: '书签', icon: const Icon(Icons.bookmark_border), onPressed: _openBookmarks),
        InkWell(onTap: _openProxy, borderRadius: BorderRadius.circular(12), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(_vpnRunning ? Icons.vpn_lock : Icons.vpn_key_off, size: 20, color: _vpnRunning ? Colors.green : null), const SizedBox(width: 5), ConstrainedBox(constraints: const BoxConstraints(maxWidth: 110), child: Text(_vpnRunning ? _proxyLabel : '代理', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall))]))),
      ])),
    );
  }
}
