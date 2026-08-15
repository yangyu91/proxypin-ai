import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:proxypin_ai/network/http/http.dart';
import 'package:proxypin_ai/ui/desktop/request/ai_chat.dart';
/// ProxyPin 内置浏览器。
///
/// 浏览器复用应用当前网络/VPN/代理链路；当 ProxyPin 的抓包服务或 VPN
/// 已启用时，WebView 的请求会进入同一条网络路径并出现在抓包列表中。
class ProxyPinBrowserPage extends StatefulWidget {
  final List<HttpRequest> Function() requestsProvider;

  const ProxyPinBrowserPage({super.key, required this.requestsProvider});

  @override
  State<ProxyPinBrowserPage> createState() => _ProxyPinBrowserPageState();
}

class _ProxyPinBrowserPageState extends State<ProxyPinBrowserPage> {
  static const _homeUrl = 'https://www.google.com';
  late final WebViewController _controller;
  final _addressController = TextEditingController(text: _homeUrl);
  bool _loading = true;
  int _progress = 0;
  String _title = '浏览器';

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
          onPageStarted: (url) => setState(() {
            _loading = true;
            _addressController.text = url;
          }),
          onPageFinished: (url) async {
            final pageTitle = await _controller.getTitle();
            if (!mounted) return;
            setState(() {
              _loading = false;
              _addressController.text = url;
              _title = pageTitle?.trim().isNotEmpty == true ? pageTitle!.trim() : '浏览器';
            });
          },
          onWebResourceError: (_) => setState(() => _loading = false),
        ),
      )
      ..loadRequest(Uri.parse(_homeUrl));
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _openAddress() async {
    final raw = _addressController.text.trim();
    if (raw.isEmpty) return;
    final value = raw.contains('://') ? raw : 'https://$raw';
    await _controller.loadRequest(Uri.tryParse(value) ?? Uri.parse(_homeUrl));
  }

  Future<void> _showBrowserMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(leading: const Icon(Icons.home_outlined), title: const Text('主页'), onTap: () { Navigator.pop(sheetContext); _controller.loadRequest(Uri.parse(_homeUrl)); }),
            ListTile(leading: const Icon(Icons.refresh), title: const Text('刷新页面'), onTap: () { Navigator.pop(sheetContext); _controller.reload(); }),
            ListTile(leading: const Icon(Icons.share_outlined), title: const Text('分享链接'), onTap: () async { Navigator.pop(sheetContext); await SharePlus.instance.share(ShareParams(uri: Uri.tryParse(_addressController.text))); }),
            ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: const Text('清除浏览数据'), onTap: () async { Navigator.pop(sheetContext); await WebViewCookieManager().clearCookies(); }),
          ],
        ),
      ),
    );
  }

  void _openAi() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * .92,
        child: AiChatPanel(requestsProvider: () => widget.requestsProvider()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: Container(
          height: 38,
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
          child: TextField(
            controller: _addressController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _openAddress(),
            decoration: InputDecoration(
              border: InputBorder.none,
              prefixIcon: const Icon(Icons.lock_outline, size: 17),
              suffixIcon: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _addressController.clear()),
              hintText: '搜索或输入网址',
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
            ),
          ),
        ),
        actions: [
          IconButton(tooltip: '返回', icon: const Icon(Icons.chevron_left), onPressed: () async { if (await _controller.canGoBack()) _controller.goBack(); }),
          IconButton(tooltip: '前进', icon: const Icon(Icons.chevron_right), onPressed: () async { if (await _controller.canGoForward()) _controller.goForward(); }),
          IconButton(tooltip: '更多', icon: const Icon(Icons.more_horiz), onPressed: _showBrowserMenu),
        ],
        bottom: _loading ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100)) : null,
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          Positioned(
            right: 18,
            bottom: 22,
            child: FloatingActionButton.small(
              heroTag: 'browser-ai-fab',
              tooltip: 'AI 分析当前抓包',
              onPressed: _openAi,
              child: const Icon(Icons.auto_awesome_rounded),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(tooltip: '主页', icon: const Icon(Icons.home_outlined), onPressed: () => _controller.loadRequest(Uri.parse(_homeUrl))),
            IconButton(tooltip: '标签页', icon: const Icon(Icons.tab_outlined), onPressed: () {}),
            IconButton(tooltip: '书签', icon: const Icon(Icons.bookmark_border), onPressed: () {}),
            Padding(padding: const EdgeInsets.only(right: 8), child: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall)),
          ],
        ),
      ),
    );
  }
}
