import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class GeckoBrowserEvent {
  final String type;
  final Map<String, dynamic> payload;

  const GeckoBrowserEvent({required this.type, required this.payload});
}

/// Flutter 对 Firefox GeckoView 的控制器。
class GeckoBrowserController {
  MethodChannel? _methodChannel;
  StreamSubscription<dynamic>? _eventSubscription;
  final StreamController<GeckoBrowserEvent> _events = StreamController.broadcast();

  Stream<GeckoBrowserEvent> get events => _events.stream;
  bool get isReady => _methodChannel != null;

  void attach(int viewId) {
    _eventSubscription?.cancel();
    _methodChannel = MethodChannel('com.proxy/gecko_browser/$viewId');
    _eventSubscription = EventChannel('com.proxy/gecko_browser/events/$viewId').receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final type = event['type']?.toString() ?? '';
      final rawPayload = event['payload'];
      final payload = rawPayload is Map
          ? rawPayload.map<String, dynamic>((key, value) => MapEntry(key.toString(), value))
          : <String, dynamic>{};
      _events.add(GeckoBrowserEvent(type: type, payload: payload));
    });
  }

  Future<void> loadUrl(String url) async => _invoke('loadUrl', {'url': url});
  Future<void> reload() async => _invoke('reload');
  Future<void> goBack() async => _invoke('goBack');
  Future<void> goForward() async => _invoke('goForward');
  Future<void> stop() async => _invoke('stop');
  Future<void> clearHistory() async => _invoke('clearHistory');
  Future<void> clearData() async => _invoke('clearData');

  Future<void> _invoke(String method, [Map<String, dynamic>? arguments]) async {
    final channel = _methodChannel;
    if (channel == null) return;
    await channel.invokeMethod<void>(method, arguments);
  }

  void dispose() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _methodChannel = null;
    _events.close();
  }
}

/// Android 上承载 Firefox GeckoView 的原生 PlatformView。
class GeckoBrowserView extends StatelessWidget {
  final GeckoBrowserController controller;
  final String initialUrl;

  const GeckoBrowserView({super.key, required this.controller, required this.initialUrl});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const Center(child: Text('Firefox Gecko 内核当前仅支持 Android 版内置浏览器。'));
    }
    return AndroidView(
      viewType: 'com.proxy/gecko_browser',
      layoutDirection: TextDirection.ltr,
      creationParams: {'initialUrl': initialUrl},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: controller.attach,
    );
  }
}
