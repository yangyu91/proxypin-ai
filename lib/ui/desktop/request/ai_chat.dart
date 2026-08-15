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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 18),
          const SizedBox(width: 6),
          const Expanded(child: Text('AI 分析', style: TextStyle(fontWeight: FontWeight.bold))),
          if (_configured)
            Text(
              _providerType == AiProviderType.deepSeekWeb ? 'DeepSeek 网页版' : 'DeepSeek 官方 API',
              style: const TextStyle(fontSize: 12),
            ),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            onPressed: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildLoginPrompt() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('未登录 DeepSeek'),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            icon: const Icon(Icons.login),
            label: const Text('登录 chat.deepseek.com'),
            onPressed: _openLogin,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _openSettings,
            child: const Text('或使用官方 API Key'),
          ),
        ],
      ),
    );
  }

  Widget _buildEntry(ChatEntry entry) {
    final isUser = entry.role == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isUser ? Icons.person : Icons.auto_awesome, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.reasoning.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      entry.reasoning,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                SelectableText(entry.content.isEmpty ? '思考中...' : entry.content),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: '输入问题，AI 将分析抓包数据...',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: _sending ? const CircularProgressIndicator(strokeWidth: 2) : const Icon(Icons.send),
            onPressed: _sending ? null : _send,
          ),
        ],
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
