/// DeepSeek SSE 流解析。
///
/// 移植自 deepseek-pp 的 core/deepseek/stream-codec.ts。
/// 解析 JSON-patch 流式响应，分离回答文本（RESPONSE）与推理文本（THINK）。

import 'dart:convert';

/// 流式解析结果增量
class DeepSeekStreamChunk {
  final String text;
  final String reasoning;
  final bool finished;

  DeepSeekStreamChunk({this.text = '', this.reasoning = '', this.finished = false});
}

/// SSE 事件
class DeepSeekSseEvent {
  final String type;
  final String data;
  DeepSeekSseEvent(this.type, this.data);
}

/// DeepSeek SSE 流解码器
class DeepSeekStreamDecoder {
  String _buffer = '';
  final List<String> _fragmentTypes = [];
  int _currentIndex = -1;
  bool _observed = false;

  String answerText = '';
  String reasoningText = '';
  bool finished = false;

  /// 喂入原始字节，返回增量文本。
  DeepSeekStreamChunk push(List<int> bytes) {
    _buffer += utf8.decode(bytes);
    final events = _drain();
    return _consumeEvents(events);
  }

  /// 结束流，处理剩余缓冲。
  DeepSeekStreamChunk finish() {
    final events = _drain();
    if (_buffer.isNotEmpty) {
      events.addAll(_parseBlock(_buffer));
      _buffer = '';
    }
    return _consumeEvents(events);
  }

  List<DeepSeekSseEvent> _drain() {
    final events = <DeepSeekSseEvent>[];
    const boundary = '\n\n';
    var index = _buffer.indexOf(boundary);
    while (index >= 0) {
      final block = _buffer.substring(0, index);
      events.addAll(_parseBlock(block));
      _buffer = _buffer.substring(index + boundary.length);
      // 兼容 \r\n\r\n
      if (_buffer.startsWith('\n')) _buffer = _buffer.substring(1);
      index = _buffer.indexOf(boundary);
    }
    return events;
  }

  List<DeepSeekSseEvent> _parseBlock(String block) {
    if (block.trim().isEmpty) return [];
    final event = <String, String>{};
    for (final line in block.split(RegExp(r'\r\n|\r|\n'))) {
      if (line.startsWith('id:')) {
        event['id'] = line.substring(3).trim();
      } else if (line.startsWith('event:')) {
        event['type'] = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        final data = line.substring(5).trim();
        event['data'] = event['data'] != null ? '${event['data']}\n$data' : data;
      }
    }
    if (event['data'] == null) return [];
    return [DeepSeekSseEvent(event['type'] ?? 'message', event['data']!)];
  }

  DeepSeekStreamChunk _consumeEvents(List<DeepSeekSseEvent> events) {
    final textBuf = StringBuffer();
    final reasoningBuf = StringBuffer();
    var chunkFinished = false;

    for (final event in events) {
      final parsed = _parseJson(event.data);
      if (parsed == null) continue;
      final split = _splitResponseText(parsed);
      if (split.text != null) {
        textBuf.write(split.text);
        answerText += split.text!;
      }
      if (split.reasoning != null) {
        reasoningBuf.write(split.reasoning);
        reasoningText += split.reasoning!;
      }
      if (_isStreamFinished(parsed)) {
        chunkFinished = true;
        finished = true;
      }
    }

    return DeepSeekStreamChunk(
      text: textBuf.toString(),
      reasoning: reasoningBuf.toString(),
      finished: chunkFinished,
    );
  }

  dynamic _parseJson(String data) {
    try {
      return jsonDecode(data);
    } catch (_) {
      return null;
    }
  }

  /// 分离回答文本与推理文本（移植 splitDeepSeekResponseText）
  ({String? text, String? reasoning}) _splitResponseText(dynamic parsed) {
    if (parsed is Map && parsed['o'] == 'BATCH' && parsed['v'] is List) {
      String? text;
      String? reasoning;
      for (final item in parsed['v'] as List) {
        final part = _splitResponseText(item);
        if (part.text != null) text = (text ?? '') + part.text!;
        if (part.reasoning != null) reasoning = (reasoning ?? '') + part.reasoning!;
      }
      return (text: text, reasoning: reasoning);
    }

    final p = parsed is Map ? parsed['p'] : null;
    final o = parsed is Map ? parsed['o'] : null;
    final v = parsed is Map ? parsed['v'] : null;

    // 片段创建：{"p":"response/fragments","o":"APPEND","v":[...]}
    if (p == 'response/fragments' && o == 'APPEND' && v is List) {
      final fragments = v as List;
      final types = fragments
          .map((f) => ((f is Map) ? f['type'] : null)?.toString() ?? 'RESPONSE')
          .toList();
      _fragmentTypes.addAll(types);
      _currentIndex = _fragmentTypes.length - 1;
      _observed = true;
      return _consumeFragmentsInitialContent(fragments, types);
    }

    // 全量快照：{"v":{"response":{...,"fragments":[...]}}}
    final snapshotFragments = _getSnapshotFragments(parsed);
    if (snapshotFragments != null) {
      final firstObservation = !_observed;
      final types = snapshotFragments
          .map((f) => ((f is Map) ? f['type'] : null)?.toString() ?? 'RESPONSE')
          .toList();
      _fragmentTypes
        ..clear()
        ..addAll(types);
      _currentIndex = _fragmentTypes.length - 1;
      _observed = true;
      if (firstObservation) {
        return _consumeFragmentsInitialContent(snapshotFragments, types);
      }
      return (text: null, reasoning: null);
    }

    // 推理补丁路径
    if (_isThinkingPatchPath(p) && v is String) {
      return (text: null, reasoning: v);
    }

    // 内容补丁
    if (p is String && _isResponseTextPatchPath(p) && v is String) {
      final index = _fragmentIndexFromPatchPath(p);
      return _splitByType(_fragmentTypeAt(index), v);
    }

    // 简写 {"v":"text"}
    if (p == null && v is String) {
      return _splitByType(_fragmentTypeAt(_currentIndex), v);
    }

    return (text: null, reasoning: null);
  }

  ({String? text, String? reasoning}) _consumeFragmentsInitialContent(
      List fragments, List<String> types) {
    String? text;
    String? reasoning;
    for (var i = 0; i < fragments.length; i++) {
      final content = _extractFragmentText(fragments[i]);
      if (content == null) continue;
      final part = _splitByType(types[i], content);
      if (part.text != null) text = (text ?? '') + part.text!;
      if (part.reasoning != null) reasoning = (reasoning ?? '') + part.reasoning!;
    }
    return (text: text, reasoning: reasoning);
  }

  String? _fragmentTypeAt(int index) {
    if (index == -1) index = _currentIndex;
    if (index < 0 || index >= _fragmentTypes.length) return null;
    return _fragmentTypes[index];
  }

  ({String? text, String? reasoning}) _splitByType(String? type, String content) {
    return (type ?? '').toUpperCase() == 'THINK'
        ? (text: null, reasoning: content)
        : (text: content, reasoning: null);
  }

  List? _getSnapshotFragments(dynamic parsed) {
    if (parsed is! Map || parsed['p'] != null) return null;
    final v = parsed['v'];
    if (v is! Map) return null;
    final response = v['response'];
    if (response is! Map) return null;
    final fragments = response['fragments'];
    return (fragments is List && fragments.isNotEmpty) ? fragments : null;
  }

  bool _isThinkingPatchPath(dynamic p) {
    if (p is! String) return false;
    final last = p.split('/').last;
    return last == 'reasoning_content' || last == 'thinking_content';
  }

  bool _isResponseTextPatchPath(String path) {
    final last = path.split('/').last;
    return last == 'content' || last == 'text' || last == 'markdown' || last == 'delta';
  }

  int _fragmentIndexFromPatchPath(String path) {
    final match = RegExp(r'^response/fragments/(-?\d+)/').firstMatch(path);
    if (match == null) return -1;
    return int.parse(match.group(1)!);
  }

  String? _extractFragmentText(dynamic fragment) {
    if (fragment is! Map) return null;
    if (fragment['content'] is String) return fragment['content'] as String;
    if (fragment['text'] is String) return fragment['text'] as String;
    return null;
  }

  bool _isStreamFinished(dynamic parsed) {
    if (parsed is Map && parsed['p'] == 'response/status' && parsed['v'] == 'FINISHED') {
      return true;
    }
    if (parsed is Map && parsed['o'] == 'BATCH' && parsed['v'] is List) {
      return (parsed['v'] as List).any((item) =>
          item is Map && item['p'] == 'quasi_status' && item['v'] == 'FINISHED');
    }
    return false;
  }
}
