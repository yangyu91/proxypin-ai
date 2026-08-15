/// DeepSeek 与豆包网页登录页。
///
/// 登录凭据只在用户设备本地处理；页面不会在加载完成时自动提交任何内容。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'ai_config.dart';
import 'ai_provider.dart';

class DeepSeekLoginPage extends StatefulWidget {
  final ValueChanged<String> onToken;
  const DeepSeekLoginPage({super.key, required this.onToken});
  @override
  State<DeepSeekLoginPage> createState() => _DeepSeekLoginPageState();
}

class _DeepSeekLoginPageState extends State<DeepSeekLoginPage> {
  WebViewController? _controller;
  bool _loading = true;
  static const String _deepSeekUrl = 'https://chat.deepseek.com/';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..addJavaScriptChannel('TokenExtractor', onMessageReceived: (message) => _handleToken(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
          _extractToken();
        },
      ))
      ..loadRequest(Uri.parse(_deepSeekUrl));
  }

  Future<void> _extractToken() async {
    try {
      await _controller?.runJavaScript('''
        (function() {
          try {
            var token = localStorage.getItem('userToken');
            if (token) TokenExtractor.postMessage(token);
          } catch (e) {}
        })();
      ''');
    } catch (e) {
      debugPrint('提取 DeepSeek token 失败: $e');
    }
  }

  void _handleToken(String raw) {
    final token = AiConfig.parseUserToken(raw);
    if (token != null && token.isNotEmpty) widget.onToken(token);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('登录 DeepSeek'), actions: [TextButton(onPressed: _extractToken, child: const Text('提取 Token'))]),
        body: Stack(children: [if (_controller != null) WebViewWidget(controller: _controller!), if (_loading) const Center(child: CircularProgressIndicator())]),
      );
}

/// 豆包网页会话登录页。
///
/// 豆包的网页协议和 Cookie 字段可能变化，因此只有在用户点击“读取登录态”
/// 且检测到 sessionid 等关键字段后才返回给配置层，不会把普通页面 Cookie 当作登录成功。
class DoubaoLoginPage extends StatefulWidget {
  final ValueChanged<String> onCookie;
  const DoubaoLoginPage({super.key, required this.onCookie});
  @override
  State<DoubaoLoginPage> createState() => _DoubaoLoginPageState();
}

class _DoubaoLoginPageState extends State<DoubaoLoginPage> {
  WebViewController? _controller;
  final _cookieController = TextEditingController();
  bool _loading = true;
  String _status = '请在页面中完成豆包登录，然后点击右上角“读取登录态”';
  static const _doubaoUrl = 'https://www.doubao.com/chat/';
  static const _nativeChannel = MethodChannel('com.proxy/doubao');

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 Chrome/131.0.0.0 Mobile Safari/537.36')
      ..setBackgroundColor(const Color(0xFFF7F7F7))
      ..addJavaScriptChannel('CookieExtractor', onMessageReceived: (message) => _handleExtracted(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() { _loading = true; _status = '正在加载豆包登录页…'; });
        },
        onPageFinished: (_) {
          if (mounted) setState(() { _loading = false; _status = '登录完成后，请点击右上角“读取登录态”'; });
        },
        onWebResourceError: (error) {
          if (mounted) setState(() { _loading = false; _status = '页面加载失败：${error.description}；可点击刷新重试'; });
        },
      ))
      ..loadRequest(Uri.parse('$_doubaoUrl?proxy_pin_login=${DateTime.now().millisecondsSinceEpoch}'));
  }

  Future<void> _extractCookie() async {
    setState(() => _status = '正在读取当前页面登录态…');
    try {
      String nativeCookie = '';
      try {
        nativeCookie = await _nativeChannel.invokeMethod<String>('getCookies', {'url': _doubaoUrl}) ?? '';
      } catch (_) {
        // 原生 CookieManager 不可用时仍继续读取网页可见 Cookie 和 LocalStorage。
      }
      await _controller?.runJavaScript('''
        (function() {
          try {
            var values = {};
            for (var i = 0; i < localStorage.length; i++) {
              var key = localStorage.key(i);
              if (key) values[key] = localStorage.getItem(key);
            }
            CookieExtractor.postMessage(JSON.stringify({cookie: document.cookie || '', nativeCookie: ${jsonEncode(nativeCookie)}, localStorage: values}));
          } catch (e) { CookieExtractor.postMessage(''); }
        })();
      ''');
    } catch (error) {
      setState(() => _status = '读取失败：$error');
    }
  }

  void _handleExtracted(String raw) {
    String cookie = raw.trim();
    try {
      final decoded = jsonDecode(cookie);
      if (decoded is Map) {
        final cookiePart = decoded['cookie']?.toString() ?? '';
        final nativeCookie = decoded['nativeCookie']?.toString() ?? '';
        final storage = decoded['localStorage'];
        final candidates = <String>[nativeCookie, cookiePart];
        if (storage is Map) {
          for (final entry in storage.entries) {
            final key = entry.key.toString().toLowerCase();
            if (key.contains('session') || key.contains('token') || key.contains('login')) {
              candidates.add('${entry.key}=${entry.value}');
            }
          }
        }
        cookie = candidates.where((item) => item.trim().isNotEmpty).join('; ');
      }
    } catch (_) {}

    if (!isLikelyDoubaoSession(cookie)) {
      setState(() => _status = '未检测到有效豆包登录态。请确认已登录，并检查页面是否完成跳转；也可以在下方手动粘贴 Cookie。');
      return;
    }
    widget.onCookie(cookie);
    if (mounted) setState(() => _status = '已检测到豆包完整登录态，正在返回 AI 设置…');
  }

  Future<void> _clearAndReload() async {
    await _controller?.clearCache();
    await WebViewCookieManager().clearCookies();
    _cookieController.clear();
    _initWebView();
    if (mounted) setState(() => _status = '已清除豆包网页缓存，请重新登录');
  }

  void _submitManualCookie() {
    final value = _cookieController.text.trim();
    if (!isLikelyDoubaoSession(value)) {
      setState(() => _status = 'Cookie 中未发现 sessionid 等豆包登录字段，请重新复制');
      return;
    }
    widget.onCookie(value);
  }

  @override
  void dispose() {
    _cookieController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('登录豆包网页版'),
          actions: [
            TextButton(onPressed: _extractCookie, child: const Text('读取登录态')),
            IconButton(tooltip: '清除缓存并重新登录', onPressed: _clearAndReload, icon: const Icon(Icons.restart_alt)),
          ],
        ),
        body: Column(
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _controller == null ? const SizedBox.shrink() : WebViewWidget(controller: _controller!)),
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Column(children: [
                    Align(alignment: Alignment.centerLeft, child: Text(_status, style: Theme.of(context).textTheme.bodySmall)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(child: TextField(controller: _cookieController, obscureText: true, decoration: const InputDecoration(isDense: true, labelText: '手动粘贴 Cookie（可选）', border: OutlineInputBorder()))),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _submitManualCookie, child: const Text('保存')),
                    ]),
                  ]),
                ),
              ),
            ),
          ],
        ),
      );
}
