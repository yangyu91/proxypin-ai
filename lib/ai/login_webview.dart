/// DeepSeek 登录页。
///
/// 移动端在内置 WebView 中登录并读取本地 token；Windows 没有可用的
/// webview_flutter 实现，因此改为打开系统浏览器并让用户粘贴自己的登录 token。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'ai_config.dart';

class DeepSeekLoginPage extends StatefulWidget {
  final ValueChanged<String> onToken;
  final Future<void> Function()? onReset;

  const DeepSeekLoginPage({super.key, required this.onToken, this.onReset});

  @override
  State<DeepSeekLoginPage> createState() => _DeepSeekLoginPageState();
}

class _DeepSeekLoginPageState extends State<DeepSeekLoginPage> {
  WebViewController? _controller;
  final TextEditingController _manualTokenController = TextEditingController();
  bool _loading = true;
  bool _showExtractedToken = false;
  String _extractedToken = '';
  String _status = '请完成 DeepSeek 登录，再点击右上角“提取 Token”。提取后可先复制，再决定是否保存。';
  static const String _deepSeekUrl = 'https://chat.deepseek.com/';

  bool get _usesExternalBrowser => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    if (_usesExternalBrowser) {
      _loading = false;
      _status = '桌面版会使用系统浏览器登录 DeepSeek；登录后将 Token 粘贴回来保存。';
      return;
    }
    _initMobileWebView();
  }

  void _initMobileWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..addJavaScriptChannel('TokenExtractor', onMessageReceived: (message) => _handleToken(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
          // 登录过程会经过多个跳转页。仅静默尝试读取，不因中间页没有 localStorage
          // 而改写“已提取”状态或自动退出，避免不同页面出现相互矛盾的鉴权提示。
          _extractToken(userInitiated: false);
        },
        onWebResourceError: (error) {
          if (mounted) setState(() {
            _loading = false;
            _status = '页面加载失败：${error.description}。可重置登录态后重试。';
          });
        },
      ))
      ..loadRequest(Uri.parse('$_deepSeekUrl?proxy_pin_login=${DateTime.now().millisecondsSinceEpoch}'));
  }

  Future<void> _openExternalLogin() async {
    final opened = await launchUrl(Uri.parse(_deepSeekUrl), mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      setState(() => _status = '无法打开系统浏览器。请手动访问 $_deepSeekUrl 后粘贴 Token。');
    }
  }

  Future<void> _extractToken({bool userInitiated = true}) async {
    if (_usesExternalBrowser) return;
    if (userInitiated && mounted) setState(() => _status = '正在读取当前 DeepSeek 页面与会话存储中的登录态…');
    try {
      final includeFallbackKeys = userInitiated ? 'true' : 'false';
      await _controller?.runJavaScript('''
        (function() {
          try {
            var storages = [window.localStorage, window.sessionStorage];
            var preferredKeys = ['userToken', 'user_token', 'accessToken', 'access_token', 'token'];
            function emit(value) {
              if (value) { TokenExtractor.postMessage(value); return true; }
              return false;
            }
            for (var s = 0; s < storages.length; s++) {
              var storage = storages[s];
              for (var i = 0; i < preferredKeys.length; i++) {
                if (emit(storage.getItem(preferredKeys[i]))) return;
              }
              if ($includeFallbackKeys) {
                for (var j = 0; j < storage.length; j++) {
                  var key = storage.key(j) || '';
                  if (/token|auth/i.test(key) && emit(storage.getItem(key))) return;
                }
              }
            }
            TokenExtractor.postMessage('');
          } catch (e) { TokenExtractor.postMessage(''); }
        })();
      ''');
    } catch (error) {
      if (mounted) setState(() => _status = '提取失败：$error。可重置登录态后重试。');
    }
  }

  void _handleToken(String raw) {
    final token = AiConfig.parseUserToken(raw);
    if (token != null && token.isNotEmpty) {
      if (mounted) {
        setState(() {
          _extractedToken = token;
          _manualTokenController.text = token;
          _status = '已从当前登录态提取 Token。请先复制备份，或保存后由 AI 工作台验证。';
        });
      }
    } else if (mounted && _extractedToken.isEmpty) {
      // 自动探测遇到登录中转页时不覆盖提示；用户手动点击提取后仍会得到明确反馈。
      setState(() => _status = '当前页面尚未发现可用 Token。请完成登录后重试，或手动粘贴。');
    }
  }

  Future<void> _copyToken() async {
    final token = AiConfig.parseUserToken(_extractedToken.isNotEmpty ? _extractedToken : _manualTokenController.text);
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _status = '暂无可复制 Token，请先提取或手动粘贴。');
      return;
    }
    await Clipboard.setData(ClipboardData(text: token));
    if (mounted) setState(() => _status = 'Token 已复制到系统剪贴板。请妥善保管，不要分享给他人。');
  }

  void _saveManualToken() {
    final token = AiConfig.parseUserToken(_extractedToken.isNotEmpty ? _extractedToken : _manualTokenController.text);
    if (token == null || token.isEmpty) {
      setState(() => _status = 'Token 格式为空或无效，请重新提取或粘贴。');
      return;
    }
    widget.onToken(token);
  }

  Future<void> _resetLoginState() async {
    await widget.onReset?.call();
    _manualTokenController.clear();
    if (_usesExternalBrowser) {
      if (mounted) setState(() => _status = '本应用保存的登录态已清除。可重新打开浏览器登录并粘贴新 Token。');
      return;
    }
    try {
      await _controller?.runJavaScript('localStorage.clear(); sessionStorage.clear();');
      _extractedToken = '';
      _showExtractedToken = false;
      await _controller?.clearCache();
      await WebViewCookieManager().clearCookies();
      await _controller?.loadRequest(Uri.parse('$_deepSeekUrl?proxy_pin_login=${DateTime.now().millisecondsSinceEpoch}'));
      if (mounted) setState(() => _status = 'Cookie、缓存和本地 Token 已清除，请重新登录。');
    } catch (error) {
      if (mounted) setState(() => _status = '已清除应用保存的 Token，但网页缓存清除失败：$error');
    }
  }

  @override
  void dispose() {
    _manualTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('登录 DeepSeek'),
          actions: [
            if (!_usesExternalBrowser) TextButton(onPressed: () => _extractToken(userInitiated: true), child: const Text('提取 Token')),
            IconButton(tooltip: '重置 Cookie 与登录态', onPressed: _resetLoginState, icon: const Icon(Icons.restart_alt)),
          ],
        ),
        body: _usesExternalBrowser ? _buildDesktopLogin() : _buildMobileLogin(),
      );

  Widget _buildMobileLogin() => Column(children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _controller == null ? const SizedBox.shrink() : WebViewWidget(controller: _controller!)),
        _buildManualTokenPanel(),
      ]);

  Widget _buildDesktopLogin() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Icon(Icons.open_in_browser_rounded, size: 48),
              const SizedBox(height: 16),
              Text('在浏览器登录 DeepSeek', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('Windows 版使用系统浏览器完成网页登录。登录后，将你自己的 DeepSeek Token 粘贴到下方保存。', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 18),
              FilledButton.icon(onPressed: _openExternalLogin, icon: const Icon(Icons.open_in_new_rounded), label: const Text('打开 DeepSeek 登录页')),
              const SizedBox(height: 12),
              _buildManualTokenPanel(),
            ]),
          ),
        ),
      );

  Widget _buildManualTokenPanel() => Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(alignment: Alignment.centerLeft, child: Text(_status, style: Theme.of(context).textTheme.bodySmall)),
              const SizedBox(height: 8),
              if (_extractedToken.isNotEmpty) ...[
                Row(children: [
                  Expanded(
                    child: SelectableText(
                      _showExtractedToken ? _extractedToken : '${_extractedToken.substring(0, _extractedToken.length.clamp(0, 8).toInt())}••••••••',
                      maxLines: 2,
                    ),
                  ),
                  IconButton(
                    tooltip: _showExtractedToken ? '隐藏 Token' : '显示 Token',
                    icon: Icon(_showExtractedToken ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _showExtractedToken = !_showExtractedToken),
                  ),
                  IconButton(tooltip: '复制 Token', icon: const Icon(Icons.copy_outlined), onPressed: _copyToken),
                ]),
                const SizedBox(height: 6),
              ],
              Row(children: [
                Expanded(child: TextField(controller: _manualTokenController, obscureText: !_showExtractedToken, decoration: const InputDecoration(isDense: true, labelText: '手动粘贴 DeepSeek Token', border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _copyToken, child: const Text('复制')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _saveManualToken, child: const Text('保存并验证')),
              ]),
              const SizedBox(height: 4),
              TextButton.icon(onPressed: _resetLoginState, icon: const Icon(Icons.restart_alt, size: 17), label: const Text('重置 Cookie / Token 后重新登录')),
            ]),
          ),
        ),
      );
}
