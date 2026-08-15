/// DeepSeek 登录 WebView。
///
/// 内嵌打开 chat.deepseek.com，用户登录后通过 JS 通道提取 localStorage 的 userToken。
/// 移植自 deepseek-pp 的登录态复用机制（userToken 存储键）。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'ai_config.dart';

/// DeepSeek 登录页，登录成功后通过 [onToken] 回调返回 token。
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
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..addJavaScriptChannel('TokenExtractor', onMessageReceived: (message) {
        _handleToken(message.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          if (mounted) {
            setState(() => _loading = false);
          }
          _extractToken();
        },
      ))
      ..loadRequest(Uri.parse(_deepSeekUrl));
  }

  /// 页面加载后提取 userToken。
  Future<void> _extractToken() async {
    if (_controller == null) return;
    try {
      // 读取 localStorage 的 userToken，通过 JS 通道回传。
      await _controller!.runJavaScript('''
        (function() {
          try {
            var token = localStorage.getItem('userToken');
            if (token) {
              TokenExtractor.postMessage(token);
            }
          } catch (e) {}
        })();
      ''');
    } catch (e) {
      debugPrint('提取 DeepSeek token 失败: $e');
    }
  }

  void _handleToken(String raw) {
    final token = AiConfig.parseUserToken(raw);
    if (token == null || token.isEmpty) return;
    widget.onToken(token);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录 DeepSeek'),
        actions: [
          TextButton(
            onPressed: _extractToken,
            child: const Text('提取 Token'),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_controller != null) WebViewWidget(controller: _controller!),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
