import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_provider.dart';

class AiConversation {
  final String id;
  String title;
  String provider;
  DateTime createdAt;
  DateTime updatedAt;
  List<AiMessage> messages;
  List<Map<String, String>> memory;

  AiConversation({required this.id, required this.title, required this.provider, DateTime? createdAt, DateTime? updatedAt, List<AiMessage>? messages, List<Map<String, String>>? memory})
      : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        messages = messages ?? [],
        memory = memory ?? [];

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'provider': provider, 'createdAt': createdAt.toIso8601String(), 'updatedAt': updatedAt.toIso8601String(), 'messages': messages.map((message) => message.toJson()).toList(), 'memory': memory};

  factory AiConversation.fromJson(Map<String, dynamic> json) => AiConversation(
        id: json['id']?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString(),
        title: json['title']?.toString() ?? '新对话',
        provider: json['provider']?.toString() ?? AiProviderType.deepSeekWeb.name,
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
        messages: (json['messages'] is List ? json['messages'] as List : const []).whereType<Map>().map((item) => AiMessage(role: item['role']?.toString() ?? 'user', content: item['content']?.toString() ?? '')).toList(),
        memory: (json['memory'] is List ? json['memory'] as List : const []).whereType<Map>().map((item) => {'role': item['role']?.toString() ?? '', 'content': item['content']?.toString() ?? ''}).toList(),
      );
}

class AiConversationStore {
  static const _key = 'ai_conversations_v2';
  static final AiConversationStore instance = AiConversationStore._();
  AiConversationStore._();

  List<AiConversation> conversations = [];
  String? activeId;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final value = jsonDecode(raw);
      conversations = value is List ? value.whereType<Map>().map((item) => AiConversation.fromJson(Map<String, dynamic>.from(item))).toList() : [];
      conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      activeId ??= conversations.isEmpty ? null : conversations.first.id;
    } catch (_) {
      conversations = [];
    }
  }

  AiConversation create({required AiProviderType provider, String? title}) {
    final now = DateTime.now();
    final conversation = AiConversation(id: now.microsecondsSinceEpoch.toString(), title: title?.trim().isNotEmpty == true ? title!.trim() : '新对话', provider: provider.name, createdAt: now, updatedAt: now);
    conversations = [conversation, ...conversations];
    activeId = conversation.id;
    return conversation;
  }

  AiConversation? get active => _find(activeId);

  void select(String id) {
    if (conversations.any((item) => item.id == id)) activeId = id;
  }

  Future<void> append(String id, AiMessage message) async {
    final conversation = _find(id);
    if (conversation == null) return;
    conversation.messages.add(message);
    conversation.updatedAt = DateTime.now();
    if (conversation.title == '新对话' && message.role == 'user') {
      final title = message.content.trim().replaceAll(RegExp(r'\s+'), ' ');
      conversation.title = title.substring(0, min(28, title.length));
    }
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await save();
  }

  Future<void> saveMemory(String id, List<Map<String, String>> memory) async {
    final conversation = _find(id);
    if (conversation == null) return;
    conversation.memory = memory;
    conversation.updatedAt = DateTime.now();
    await save();
  }

  Future<void> remove(String id) async {
    conversations.removeWhere((item) => item.id == id);
    if (activeId == id) activeId = conversations.isEmpty ? null : conversations.first.id;
    await save();
  }

  Future<void> clear() async {
    conversations = [];
    activeId = null;
    await save();
  }

  AiConversation? _find(String? id) {
    if (id == null) return null;
    for (final item in conversations) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(conversations.map((item) => item.toJson()).toList()));
  }
}
