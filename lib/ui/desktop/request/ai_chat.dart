/// AI 对话面板 + 抓包数据序列化。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:proxypin_ai/ai/ai_config.dart';
import 'package:proxypin_ai/ai/builtin_skills.dart';
import 'package:proxypin_ai/ai/ai_provider.dart';
import 'package:proxypin_ai/ai/login_webview.dart';
import 'package:proxypin_ai/network/http/http.dart';

/// 把抓包数据序列化成 AI 可分析的文本。
String buildCaptureContext(List<HttpRequest> requests, {int maxBodyLength = 300, HttpRequest? currentRequest, bool includeSensitive = false}) {
  final buffer = StringBuffer();
  buffer.writeln('当前抓包数据（共 ${requests.length} 条请求）：');
  if (currentRequest != null) {
    buffer.writeln('当前正在查看的请求：${currentRequest.method.name} ${_redactUrl(currentRequest.requestUrl, includeSensitive)}');
  }
  for (final request in requests) {
    final response = request.response;
    final status = response?.status.code.toString() ?? '-';
    buffer.writeln('${request.method.name} ${_redactUrl(request.requestUrl, includeSensitive)} -> $status');
    request.headers.forEach((key, values) {
      final safeValues = includeSensitive || !_isSensitiveHeader(key) ? values : values.map((_) => '[已隐藏]').toList();
      buffer.writeln('  $key: ${safeValues.join(', ')}');
    });

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

bool _isSensitiveHeader(String key) {
  final normalized = key.toLowerCase();
  return normalized == 'authorization' || normalized == 'cookie' || normalized == 'set-cookie' || normalized.contains('token') || normalized.contains('secret') || normalized.contains('api-key') || normalized.contains('password');
}

String _redactUrl(String value, bool includeSensitive) {
  if (includeSensitive) return value;
  try {
    final uri = Uri.parse(value);
    final query = uri.queryParameters.map((key, value) => MapEntry(key, _isSensitiveHeader(key) ? '[已隐藏]' : value));
    return uri.replace(queryParameters: query).toString();
  } catch (_) {
    return value;
  }
}

/// AI 对话面板
class AiChatPanel extends StatefulWidget {
  final List<HttpRequest> Function() requestsProvider;
  final HttpRequest? currentRequest;

  const AiChatPanel({super.key, required this.requestsProvider, this.currentRequest});

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
  String _baseUrl = '';
  String _model = '';
  String _systemPrompt = AiConfig.defaultSystemPrompt;
  List<String> _skills = [];
  List<Map<String, String>> _memory = [];
  bool _includeSensitive = false;
  bool _confirmActions = true;
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
    final baseUrl = await AiConfig.readBaseUrl();
    final model = await AiConfig.readModel();
    final systemPrompt = await AiConfig.readSystemPrompt();
    final skills = await AiConfig.readSkills();
    final memory = await AiConfig.readMemory();
    final includeSensitive = await AiConfig.readIncludeSensitive();
    final confirmActions = await AiConfig.readConfirmActions();
    if (!mounted) return;
    setState(() {
      _providerType = type;
      _token = token ?? '';
      _apiKey = apiKey ?? '';
      _baseUrl = baseUrl;
      _model = model;
      _systemPrompt = systemPrompt;
      _skills = skills;
      _memory = memory;
      _includeSensitive = includeSensitive;
      _confirmActions = confirmActions;
      _configured = type == AiProviderType.deepSeekWeb ? _token.isNotEmpty : _apiKey.isNotEmpty;
    });
    if (_configured) {
      _buildProvider();
    }
  }

  void _buildProvider() {
    _provider?.dispose();
    _provider = createAiProvider(_providerType, token: _token, apiKey: _apiKey, baseUrl: _baseUrl, model: _model);
  }

  Future<void> _send() async {
    final prompt = _inputController.text.trim();
    if (prompt.isEmpty || _sending) return;

    _inputController.clear();

    // 抓包数据上下文
    final context = buildCaptureContext(widget.requestsProvider(), currentRequest: widget.currentRequest, includeSensitive: _includeSensitive);
    final skillsText = '\n\n内置调试 Skill：\n${BuiltinSkills.all.join('\n\n')}\n\n用户 Skill：\n${_skills.map((skill) => '- $skill').join('\n')}';
    final memoryText = _memory.isEmpty ? '' : '\n\n长期记忆：\n${_memory.take(12).map((entry) => '${entry['role']}: ${entry['content']}').join('\n')}';

    setState(() {
      _entries.add(ChatEntry(role: 'user', content: prompt));
      _entries.add(ChatEntry(role: 'assistant', content: '', reasoning: ''));
      _sending = true;
    });

    final assistantIndex = _entries.length - 1;

    // 系统上下文 + 用户提问
    final actionPolicy = _confirmActions ? '\n涉及改包、重放或发包时，只能先输出变更预览并等待用户确认。' : '';
    final fullPrompt = '系统提示词：$_systemPrompt$skillsText$memoryText\n\n$context\n\n用户问题：$prompt\n\n请基于上述抓包数据进行分析回答。$actionPolicy';

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
            final answer = _entries[assistantIndex].content.trim();
            if (answer.isNotEmpty) {
              _memory = [..._memory, {'role': 'user', 'content': prompt}, {'role': 'assistant', 'content': answer}].skip(_memory.length > 18 ? 2 : 0).toList();
              AiConfig.saveMemory(_memory);
            }
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

  String _providerLabel(AiProviderType type) {
    switch (type) {
      case AiProviderType.deepSeekWeb:
        return 'DeepSeek 网页版';
      case AiProviderType.deepSeekOfficial:
        return 'DeepSeek 官方 API';
      case AiProviderType.openAiCompatible:
        return 'OpenAI 兼容模型';
      case AiProviderType.siliconFlow:
        return 'SiliconFlow 视觉模型';
    }
  }

  Future<void> _openSettings() async {
    final apiKeyController = TextEditingController(text: _apiKey);
    final baseUrlController = TextEditingController(text: _baseUrl);
    final modelController = TextEditingController(text: _model);
    final promptController = TextEditingController(text: _systemPrompt);
    final skillsController = TextEditingController(text: _skills.join('\n'));
    var provider = _providerType;
    var includeSensitive = _includeSensitive;
    var confirmActions = _confirmActions;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('AI 工作台设置'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<AiProviderType>(
                    value: provider,
                    decoration: const InputDecoration(labelText: '模型后端'),
                    items: AiProviderType.values.map((item) => DropdownMenuItem(value: item, child: Text(_providerLabel(item)))).toList(),
                    onChanged: (value) => setDialogState(() => provider = value ?? provider),
                  ),
                  const SizedBox(height: 10),
                  TextField(controller: apiKeyController, decoration: const InputDecoration(labelText: 'API Key / 本地凭据'), obscureText: true),
                  const SizedBox(height: 10),
                  TextField(controller: baseUrlController, decoration: const InputDecoration(labelText: 'OpenAI 兼容端点'), keyboardType: TextInputType.url),
                  const SizedBox(height: 10),
                  TextField(controller: modelController, decoration: const InputDecoration(labelText: '模型名称')),
                  const SizedBox(height: 10),
                  TextField(controller: promptController, minLines: 4, maxLines: 8, decoration: const InputDecoration(labelText: '系统提示词（可修改）', alignLabelWithHint: true),),
                  const SizedBox(height: 10),
                  TextField(controller: skillsController, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: '用户 Skill（每行一条）', alignLabelWithHint: true),),
                  const Divider(height: 24),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许显示敏感字段'),
                    subtitle: const Text('仅在明确需要时打开；默认隐藏 Token、Cookie、密码等内容'),
                    value: includeSensitive,
                    onChanged: (value) => setDialogState(() => includeSensitive = value),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('改包/发包必须确认'),
                    subtitle: const Text('建议保持开启，AI 只能先生成预览，不能静默发送'),
                    value: confirmActions,
                    onChanged: (value) => setDialogState(() => confirmActions = value),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final key = apiKeyController.text.trim();
                final skills = skillsController.text.split('\n').map((value) => value.trim()).where((value) => value.isNotEmpty).toList();
                await AiConfig.saveApiKey(key);
                await AiConfig.saveProviderType(provider);
                await AiConfig.saveBaseUrl(baseUrlController.text.trim());
                await AiConfig.saveModel(modelController.text.trim());
                await AiConfig.saveSystemPrompt(promptController.text.trim());
                await AiConfig.saveSkills(skills);
                await AiConfig.saveIncludeSensitive(includeSensitive);
                await AiConfig.saveConfirmActions(confirmActions);
                if (!mounted) return;
                setState(() {
                  _apiKey = key;
                  _providerType = provider;
                  _baseUrl = baseUrlController.text.trim();
                  _model = modelController.text.trim();
                  _systemPrompt = promptController.text.trim().isEmpty ? AiConfig.defaultSystemPrompt : promptController.text.trim();
                  _skills = skills;
                  _includeSensitive = includeSensitive;
                  _confirmActions = confirmActions;
                  _configured = provider == AiProviderType.deepSeekWeb ? _token.isNotEmpty : key.isNotEmpty;
                });
                if (_configured) _buildProvider();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('保存设置'),
            ),
          ],
        ),
      ),
    );
    apiKeyController.dispose();
    baseUrlController.dispose();
    modelController.dispose();
    promptController.dispose();
    skillsController.dispose();
  }

  Future<void> _pickAndAnalyzeImage() async {
    final result = await FilePicker.pickFiles(type: FileType.image, withData: true);
    final bytes = result?.files.single.bytes;
    if (bytes == null || bytes.isEmpty || _provider == null || _sending) return;
    final prompt = _inputController.text.trim().isEmpty ? '请识别并分析这张图片与当前抓包调试的关系。' : _inputController.text.trim();
    _inputController.clear();
    setState(() {
      _entries.add(ChatEntry(role: 'user', content: '识图：$prompt'));
      _entries.add(ChatEntry(role: 'assistant', content: ''));
      _sending = true;
    });
    final index = _entries.length - 1;
    await _provider!.sendImageStreaming(bytes, prompt, AiStreamCallbacks(
      onText: (_, full) => setState(() => _entries[index].content = full),
      onFinished: () => setState(() => _sending = false),
      onError: (error) => setState(() { _entries[index].content = '识图失败: $error'; _sending = false; }),
    ));
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
    final providerName = _providerLabel(_providerType);
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

  List<TextSpan> _inlineSpans(String text, TextStyle style) {
    final spans = <TextSpan>[];
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
            IconButton(
              tooltip: '选择图片并识图',
              icon: const Icon(Icons.image_outlined),
              onPressed: _sending ? null : _pickAndAnalyzeImage,
            ),
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
