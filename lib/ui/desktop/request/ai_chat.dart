/// AI 对话面板 + 抓包数据序列化。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:proxypin_ai/ai/ai_config.dart';
import 'package:proxypin_ai/ai/ai_provider.dart';
import 'package:proxypin_ai/ai/login_webview.dart';
import 'package:proxypin_ai/network/http/http.dart';

/// 把抓包数据序列化成 AI 可分析的文本。
String buildCaptureContext(List<HttpRequest> requests, {int maxBodyLength = 300}) {
  final buffer = StringBuffer();
  buffer.writeln('当前抓包数据（共 ${requests.length} 条请求）：');
  for (final request in requests) {
    final response = request.response;
    final status = response?.status.code.toString() ?? '-';
    buffer.writeln(
        '${request.method.name} ${request.requestUrl} -> $status');

    // 简要 body（截断）
    final bodyBytes = request.body;
    if (bodyBytes != null && bodyBytes.isNotEmpty) {
      var bodyStr = '';
      try {
        bodyStr = utf8.decode(bodyBytes, allowMalformed: true);
      } catch (_) {
        bodyStr = '<binary ${bodyBytes.length} bytes>';
      }
      if (bodyStr.length > maxBodyLength) {
        bodyStr = '${bodyStr.substring(0, maxBodyLength)}...';
      }
      buffer.writeln('  body: $bodyStr');
    }
  }
  return buffer.toString();
}

/// AI 对话面板
class AiChatPanel extends StatefulWidget {
  final List<HttpRequest> Function() requestsProvider;

  const AiChatPanel({super.key, required this.requestsProvider});

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends State<AiChatPanel> {
  final List<ChatEntry> _entries = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  AiProvider? _provider;
  AiProviderType _providerType = AiProviderType.deepSeekWeb;
  String _token = '';
  String _apiKey = '';
  bool _sending = false;
  bool _configured = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final type = await AiConfig.readProviderType();
    final token = await AiConfig.readToken();
    final apiKey = await AiConfig.readApiKey();
    setState(() {
      _providerType = type;
      _token = token ?? '';
      _apiKey = apiKey ?? '';
      _configured = type == AiProviderType.deepSeekWeb
          ? (_token.isNotEmpty)
          : (_apiKey.isNotEmpty);
    });
    if (_configured) {
      _buildProvider();
    }
  }

  void _buildProvider() {
    if (_providerType == AiProviderType.deepSeekWeb) {
      _provider = createAiProvider(_providerType, token: _token);
    } else {
      _provider = createAiProvider(_providerType, apiKey: _apiKey);
    }
  }

  Future<void> _send() async {
    final prompt = _inputController.text.trim();
    if (prompt.isEmpty || _sending) return;

    _inputController.clear();

    // 抓包数据上下文
    final context = buildCaptureContext(widget.requestsProvider());

    setState(() {
      _entries.add(ChatEntry(role: 'user', content: prompt));
      _entries.add(ChatEntry(role: 'assistant', content: '', reasoning: ''));
      _sending = true;
    });

    final assistantIndex = _entries.length - 1;

    // 系统上下文 + 用户提问
    final fullPrompt = '$context\n\n用户问题：$prompt\n\n请基于上述抓包数据进行分析回答。';

    try {
      await _provider!.sendMessageStreaming(
        fullPrompt,
        AiStreamCallbacks(
          onText: (delta, full) {
            setState(() {
              _entries[assistantIndex].content = full;
            });
            _scrollToBottom();
          },
          onReasoning: (delta, full) {
            setState(() {
              _entries[assistantIndex].reasoning = full;
            });
          },
          onFinished: () {
            setState(() => _sending = false);
          },
          onError: (error) {
            setState(() {
              _entries[assistantIndex].content = '请求失败: $error';
              _sending = false;
            });
          },
        ),
      );
    } catch (e) {
      setState(() {
        _entries[assistantIndex].content = '请求失败: $e';
        _sending = false;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _openLogin() async {
    final token = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => DeepSeekLoginPage(onToken: (token) {
        Navigator.of(context).pop(token);
      })),
    );
    if (token != null && token.isNotEmpty) {
      await AiConfig.saveToken(token);
      await AiConfig.saveProviderType(AiProviderType.deepSeekWeb);
      setState(() {
        _token = token;
        _providerType = AiProviderType.deepSeekWeb;
        _configured = true;
      });
      _buildProvider();
    }
  }

  Future<void> _openSettings() async {
    final apiKeyController = TextEditingController(text: _apiKey);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: apiKeyController,
              decoration: const InputDecoration(labelText: '官方 API Key（可选）'),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            const Text('默认走 chat.deepseek.com 白嫖通道；填写 API Key 后自动切换官方通道。',
                style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final key = apiKeyController.text.trim();
              if (key.isNotEmpty) {
                await AiConfig.saveApiKey(key);
                await AiConfig.saveProviderType(AiProviderType.deepSeekOfficial);
                setState(() {
                  _apiKey = key;
                  _providerType = AiProviderType.deepSeekOfficial;
                  _configured = true;
                });
                _buildProvider();
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        const Divider(height: 1),
        Expanded(
          child: _configured
              ? ListView.builder(
                  controller: _scrollController,
                  itemCount: _entries.length,
                  itemBuilder: (_, index) => _buildEntry(_entries[index]),
                )
              : _buildLoginPrompt(),
        ),
        _buildInput(),
      ],
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final providerName = _providerType == AiProviderType.deepSeekWeb ? 'DeepSeek 网页版' : 'DeepSeek 官方 API';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45))),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.auto_awesome_rounded, size: 19, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI 分析', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  _configured ? providerName : '未配置 AI 服务',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'AI 设置',
            icon: const Icon(Icons.tune_rounded, size: 20),
            onPressed: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildLoginPrompt() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded, size: 32, color: scheme.primary),
              const SizedBox(height: 12),
              Text('开始使用 AI 分析', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 7),
              Text(
                '登录 DeepSeek，或配置官方 API Key，即可让 AI 读取当前抓包数据。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('登录 DeepSeek 网页版'),
                  onPressed: _openLogin,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.key_rounded, size: 17),
                label: const Text('使用官方 API Key'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(ChatEntry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isUser = entry.role == 'user';
    final content = entry.content.isEmpty ? '思考中…' : entry.content;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * (isUser ? .82 : .94)),
        margin: EdgeInsets.fromLTRB(isUser ? 46 : 14, 7, isUser ? 14 : 46, 7),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        decoration: BoxDecoration(
          color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest.withValues(alpha: .72),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome_rounded, size: 15, color: scheme.primary),
                    const SizedBox(width: 5),
                    Text('AI 分析', style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            if (entry.reasoning.isNotEmpty)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 6),
                  dense: true,
                  title: Text('思考过程', style: theme.textTheme.labelSmall),
                  children: [SelectableText(entry.reasoning, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4))],
                ),
              ),
            _buildFormattedText(content, theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _buildFormattedText(String text, TextStyle? baseStyle) {
    final style = baseStyle ?? const TextStyle(fontSize: 14);
    final spans = <TextSpan>[];
    for (final line in text.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) {
        final heading = trimmed.replaceFirst(RegExp(r'^#+\s*'), '');
        spans.add(TextSpan(text: '$heading\n', style: style.copyWith(fontWeight: FontWeight.w700, fontSize: (style.fontSize ?? 14) + 1)));
      } else if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        spans.add(TextSpan(text: '• ', style: style.copyWith(fontWeight: FontWeight.w700)));
        spans.addAll(_inlineSpans(trimmed.substring(2), style));
        spans.add(const TextSpan(text: '\n'));
      } else {
        spans.addAll(_inlineSpans(line, style));
        spans.add(const TextSpan(text: '\n'));
      }
    }
    return SelectableText.rich(TextSpan(style: style.copyWith(height: 1.45), children: spans));
  }

  List<InlineSpan> _inlineSpans(String text, TextStyle style) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(\*\*|__)(.+?)\1');
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) spans.add(TextSpan(text: text.substring(cursor, match.start)));
      spans.add(TextSpan(text: match.group(2), style: style.copyWith(fontWeight: FontWeight.w700)));
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return spans;
  }

  Widget _buildInput() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: '问问 AI 当前抓包情况…',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(alpha: .55),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide(color: scheme.primary, width: 1.4)),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '发送',
              style: IconButton.styleFrom(backgroundColor: scheme.primary, foregroundColor: scheme.onPrimary, minimumSize: const Size(46, 46)),
              icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.arrow_upward_rounded),
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

/// 对话条目
class ChatEntry {
  final String role;
  String content;
  String reasoning;

  ChatEntry({required this.role, this.content = '', this.reasoning = ''});
}
