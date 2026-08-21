import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:proxypin_ai/ai/ai_workspace.dart';
import 'package:proxypin_ai/network/bin/configuration.dart';
import 'package:proxypin_ai/network/bin/server.dart';
import 'package:proxypin_ai/network/http/http.dart';
import 'package:proxypin_ai/network/vpn/android_vpn.dart';
import 'package:proxypin_ai/proxy/subscription_manager.dart';
import 'package:proxypin_ai/ui/desktop/request/ai_chat.dart';
import 'package:proxypin_ai/ui/mobile/setting/proxy_subscriptions.dart';
import 'package:proxypin_ai/ui/mobile/setting/ssl.dart';
import 'package:proxypin_ai/ui/mobile/browser/gecko_browser.dart';

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
  late final GeckoBrowserController _geckoController;
  late final StreamSubscription<GeckoBrowserEvent> _geckoEventSubscription;
  late final int _localProxyPort;
  final _addressController = TextEditingController(text: _homeUrl);
  final _bookmarks = <String>[];
  final _tabs = <String>[_homeUrl];
  int _activeTabIndex = 0;
  Timer? _proxyStatusTimer;
  bool _loading = true;
  bool _vpnRunning = false;
  int _progress = 0;
  String _title = '浏览器';
  String _proxyLabel = '代理未连接';
  HttpRequest? _activeBrowserRequest;
  bool _http2Enabled = false;
  bool _sslMitmEnabled = false;

  @override
  void initState() {
    super.initState();
    final server = ProxyServer.current;
    // GeckoRuntime 仅在首次创建时读取代理端口；从此处起锁定本机监听端口，
    // 端口修改控件会要求完整重启应用后再生效。
    server?.reserveEmbeddedFirefoxProxyPort();
    _localProxyPort = server?.embeddedFirefoxProxyPort ?? 9099;
    _geckoController = GeckoBrowserController();
    _geckoEventSubscription = _geckoController.events.listen(_onGeckoEvent);
    _ensureCapturePipeline();
    _refreshProxyStatus();
    _proxyStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshProxyStatus());
  }

  @override
  void dispose() {
    _proxyStatusTimer?.cancel();
    _geckoEventSubscription.cancel();
    _geckoController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _ensureCapturePipeline() async {
    final configuration = await Configuration.instance;
    if (!configuration.enabledHttp2) {
      configuration.enabledHttp2 = true;
      await configuration.flushConfig();
    }
    if (mounted) setState(() {
      _http2Enabled = configuration.enabledHttp2;
      _sslMitmEnabled = configuration.enableSsl;
    });
  }

  Future<void> _openHttpsStatus() async {
    final server = ProxyServer.current;
    final configuration = await Configuration.instance;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Firefox HTTPS 抓包状态'),
        content: Text(
          !_sslMitmEnabled
              ? 'HTTPS 解密当前已关闭。开启后仍需在 Android 系统中安装并信任 ProxyPin CA。'
              : 'Firefox Gecko 内核已启用 Android Enterprise Roots。只有在系统中安装并信任 ProxyPin CA 后，HTTPS/HTTP/2 的请求头和正文才能被解密；未信任时只记录导航和连接元数据。HTTP/2 目前已允许通过 ALPN 协商，具体站点仍可能协商为 HTTP/1.1。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('关闭')),
          if (server != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => MobileSslWidget(proxyServer: server)));
              },
              child: const Text('安装 / 管理 CA'),
            ),
          if (!_sslMitmEnabled)
            TextButton(
              onPressed: () async {
                configuration.enableSsl = true;
                await configuration.flushConfig();
                if (mounted) setState(() => _sslMitmEnabled = true);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('开启 HTTPS 解密'),
            ),
        ],
      ),
    );
  }

  void _onGeckoEvent(GeckoBrowserEvent event) {
    final url = event.payload['url']?.toString() ?? '';
    switch (event.type) {
      case 'ready':
        if (url.isNotEmpty && _activeBrowserRequest == null) {
          _onGeckoEvent(GeckoBrowserEvent(type: 'pageStart', payload: {'url': url}));
        }
        break;
      case 'pageStart':
        final parsedUrl = Uri.tryParse(url);
        if (url.isEmpty || (parsedUrl != null && _isBrokenBaiduRedirect(parsedUrl))) return;
        // Gecko 已固定走本机 ProxyServer 时，真实 HTTP/HTTPS 请求会由代理服务写入抓包列表；
        // 仅在服务不可用时回退到元数据导航记录，避免与真实请求重复。
        final liveCapture = ProxyServer.current?.isRunning == true;
        if (!liveCapture) {
          final request = HttpRequest(HttpMethod.get, url);
          request.attributes['source'] = 'builtin_firefox_gecko';
          request.attributes['captureMode'] = 'geckoview_navigation_metadata_fallback';
          request.headers.set('User-Agent', 'ProxyPin-Firefox-GeckoView');
          _activeBrowserRequest = request;
          widget.onCapturedRequest?.call(request);
        } else {
          _activeBrowserRequest = null;
        }
        if (!mounted) return;
        setState(() {
          _loading = true;
          if (!_isTransientBaiduUrl(url)) _addressController.text = url;
          if (_tabs.isEmpty) {
            _tabs.add(url);
            _activeTabIndex = 0;
          } else if (_activeTabIndex < 0 || _activeTabIndex >= _tabs.length) {
            _activeTabIndex = _tabs.length - 1;
          }
          // 每次导航只更新当前激活标签，不能覆盖列表中的最后一个标签。
          _tabs[_activeTabIndex] = url;
          AiWorkspace.instance.setBrowserPage(url: url);
        });
        break;
      case 'progress':
        final progress = event.payload['progress'];
        if (!mounted) return;
        setState(() {
          _progress = progress is num ? progress.toInt().clamp(0, 100).toInt() : _progress;
          _loading = _progress < 100;
        });
        break;
      case 'title':
        final title = event.payload['title']?.toString().trim();
        if (title != null && title.isNotEmpty && mounted) {
          setState(() => _title = title);
          AiWorkspace.instance.setBrowserPage(url: url.isEmpty ? _addressController.text : url, title: title);
        }
        break;
      case 'navigationBlocked':
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Firefox 已拦截无法加载的百度异常中转地址。')));
        break;
      case 'pageStop':
        if (!mounted) return;
        final success = event.payload['success'] == true;
        setState(() {
          _loading = false;
          _progress = success ? 100 : _progress;
          if (_activeBrowserRequest != null && _activeBrowserRequest!.response == null) {
            final response = HttpResponse(success ? HttpStatus.ok : HttpStatus.badGateway);
            response.request = _activeBrowserRequest;
            response.responseTime = DateTime.now();
            _activeBrowserRequest!.response = response;
            widget.onCapturedResponse?.call(response);
          }
          AiWorkspace.instance.setBrowserPage(url: url.isEmpty ? _addressController.text : url, title: _title);
        });
        break;
    }
  }

  Future<void> _refreshProxyStatus() async {
    final running = await AndroidVpnController.isRunning();
    final config = await Configuration.instance;
    final proxy = config.externalProxy;
    final proxyHost = proxy?.host;
    final proxyPort = proxy?.port;
    ProxyNode? matchingNode;
    if (proxyHost != null && proxyPort != null) {
      for (final node in SubscriptionManager.instance.groups.expand((group) => group.nodes)) {
        if (node.address == proxyHost && node.port == proxyPort) {
          matchingNode = node;
          break;
        }
      }
    }
    final label = matchingNode != null
        ? '${matchingNode.name} · ${matchingNode.latencyMs != null && matchingNode.latencyMs! >= 0 ? '${matchingNode.latencyMs} ms' : '${matchingNode.address}:${matchingNode.port}'}'
        : proxyHost != null && proxyPort != null
            ? '$proxyHost:$proxyPort'
            : '代理未连接';
    if (!mounted) return;
    if (_vpnRunning != running || _proxyLabel != label) {
      setState(() {
        _vpnRunning = running;
        _proxyLabel = running ? label : '代理未连接';
      });
    }
  }

  bool _isTransientBaiduUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.host.endsWith('baidu.com')) return false;
    return uri.path == '/link' || uri.path.startsWith('/from') || uri.path.contains('redirect');
  }

  bool _isBrokenBaiduRedirect(Uri uri) {
    final isBaidu = uri.host.endsWith('baidu.com');
    final isRedirect = uri.path == '/link' || uri.path.startsWith('/from') || uri.path.contains('redirect');
    return isBaidu && isRedirect && uri.toString().length > 4096;
  }

  Uri _normalizeAddress(String raw) {
    final value = raw.trim();
    final direct = Uri.tryParse(value);
    if (direct != null && (direct.scheme == 'http' || direct.scheme == 'https') && direct.host.isNotEmpty) return direct;
    if (!value.contains(' ') && value.contains('.')) {
      final withScheme = Uri.tryParse('https://$value');
      if (withScheme != null && withScheme.host.isNotEmpty) return withScheme;
    }
    return Uri.https('www.baidu.com', '/s', {'wd': value});
  }

  Future<void> _openAddress() async {
    final raw = _addressController.text.trim();
    if (raw.isEmpty) return;
    final target = _normalizeAddress(raw);
    if (_isBrokenBaiduRedirect(target)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该百度中转地址过长且无法安全加载，请返回搜索结果页重新打开。')));
      return;
    }
    await _geckoController.loadUrl(target.toString());
  }

  Future<void> _showBrowserMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.home_outlined), title: const Text('主页'), onTap: () { Navigator.pop(sheetContext); _goHome(); }),
          ListTile(leading: const Icon(Icons.refresh), title: const Text('刷新页面'), onTap: () { Navigator.pop(sheetContext); _geckoController.reload(); }),
          ListTile(leading: const Icon(Icons.share_outlined), title: const Text('分享链接'), onTap: () async { Navigator.pop(sheetContext); await SharePlus.instance.share(ShareParams(uri: Uri.tryParse(_addressController.text))); }),
          ListTile(leading: const Icon(Icons.bookmark_add_outlined), title: const Text('收藏当前页面'), onTap: () { Navigator.pop(sheetContext); _addBookmark(); }),
          ListTile(leading: const Icon(Icons.open_in_browser_rounded), title: const Text('使用 Firefox / 系统浏览器打开'), subtitle: const Text('外部浏览器流量不支持内置自捕获'), onTap: () async { Navigator.pop(sheetContext); await _openExternalBrowser(); }),
          ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: const Text('清除 Firefox 浏览数据'), onTap: () async { Navigator.pop(sheetContext); await _geckoController.clearData(); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Firefox Cookie、缓存和站点数据已清除'))); }),
        ]),
      ),
    );
  }

  Future<void> _openExternalBrowser() async {
    final url = _normalizeAddress(_addressController.text);
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未找到可用的外部浏览器，请先安装 Firefox 或设置默认浏览器。')));
  }

  void _goHome() => _geckoController.loadUrl(_homeUrl);

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
                onTap: () { Navigator.pop(sheetContext); _geckoController.loadUrl(url); },
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
            leading: Icon(entry.key == _activeTabIndex ? Icons.check_circle : Icons.tab_outlined),
            title: Text(entry.value, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () {
              final url = entry.value;
              setState(() => _activeTabIndex = entry.key);
              Navigator.pop(sheetContext);
              _geckoController.loadUrl(url);
            },
            trailing: IconButton(
              tooltip: '关闭标签页',
              icon: const Icon(Icons.close),
              onPressed: () => _closeTab(entry.key, sheetContext),
            ),
          )),
        ]),
      ),
    );
  }

  void _newTab() {
    setState(() {
      _activeTabIndex = _tabs.length;
      _tabs.add(_homeUrl);
      _title = '新标签页';
    });
    _geckoController.loadUrl(_homeUrl);
  }

  void _closeTab(int index, BuildContext sheetContext) {
    if (index < 0 || index >= _tabs.length) return;

    String? nextUrl;
    setState(() {
      if (_tabs.length == 1) {
        // 保留至少一个标签，避免浏览器落入无活动标签的非法状态。
        _tabs[0] = _homeUrl;
        _activeTabIndex = 0;
        nextUrl = _homeUrl;
      } else {
        final wasActive = index == _activeTabIndex;
        _tabs.removeAt(index);
        if (index < _activeTabIndex) {
          _activeTabIndex--;
        } else if (wasActive) {
          _activeTabIndex = _activeTabIndex.clamp(0, _tabs.length - 1).toInt();
          nextUrl = _tabs[_activeTabIndex];
        }
      }
    });

    Navigator.pop(sheetContext);
    if (nextUrl != null) {
      _geckoController.loadUrl(nextUrl!);
    }
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
          IconButton(tooltip: '返回', icon: const Icon(Icons.chevron_left), onPressed: _geckoController.goBack),
          IconButton(tooltip: '前进', icon: const Icon(Icons.chevron_right), onPressed: _geckoController.goForward),
          IconButton(tooltip: 'HTTPS / CA 状态', icon: Icon(_sslMitmEnabled ? Icons.verified_user_outlined : Icons.gpp_bad_outlined), onPressed: _openHttpsStatus),
          IconButton(tooltip: '更多', icon: const Icon(Icons.more_horiz), onPressed: _showBrowserMenu),
        ],
        bottom: _loading ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100)) : null,
      ),
      body: Stack(children: [
        GeckoBrowserView(controller: _geckoController, initialUrl: _homeUrl, localProxyPort: _localProxyPort),
        Positioned(
          left: 12,
          bottom: 22,
          child: Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: .94),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: _openHttpsStatus,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _sslMitmEnabled ? Icons.https_outlined : Icons.no_encryption_outlined,
                      size: 16,
                      color: _sslMitmEnabled ? Colors.green : scheme.error,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _sslMitmEnabled ? 'HTTPS 需信任 CA · ${_http2Enabled ? 'HTTP/2 已启用' : 'HTTP/1.1'}' : 'HTTPS 解密已关闭',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(right: 18, bottom: 22, child: FloatingActionButton.small(heroTag: 'browser-ai-fab', tooltip: 'AI 分析当前抓包', onPressed: _openAi, child: const Icon(Icons.auto_awesome_rounded)))
      ]),
      bottomNavigationBar: SafeArea(top: false, child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        IconButton(tooltip: '主页', icon: const Icon(Icons.home_outlined), onPressed: _goHome),
        IconButton(tooltip: '标签页', icon: const Icon(Icons.tab_outlined), onPressed: _openTabs),
        IconButton(tooltip: '书签', icon: const Icon(Icons.bookmark_border), onPressed: _openBookmarks),
        InkWell(onTap: _openProxy, borderRadius: BorderRadius.circular(12), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(_vpnRunning ? Icons.vpn_lock : Icons.vpn_key_off, size: 20, color: _vpnRunning ? Colors.green : null), const SizedBox(width: 5), ConstrainedBox(constraints: const BoxConstraints(maxWidth: 110), child: Text(_vpnRunning ? _proxyLabel : '代理', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall))]))),
      ])),
    );
  }
}
