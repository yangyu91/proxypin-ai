import 'dart:io';

import 'package:flutter/services.dart';

import '../channel/host_port.dart';

class AndroidVpnController {
  static const MethodChannel _channel = MethodChannel('com.proxy/proxyVpn');

  static Future<bool> start(ProxyInfo proxy) async {
    if (!Platform.isAndroid) return false;
    final host = proxy.host;
    final port = proxy.port;
    if (!proxy.enabled || host == null || host.trim().isEmpty || port == null || port <= 0) {
      throw ArgumentError('代理地址或端口无效');
    }
    final prepared = await _channel.invokeMethod<bool>('startVpn', <String, dynamic>{
      'proxyHost': host,
      'proxyPort': port,
      'allowApps': <String>[],
      'disallowApps': <String>[],
      // GeckoView 自身通过 Firefox 代理偏好连接本机 ProxyPin；不向系统下发 127.0.0.1 代理，避免其它应用出现环回异常。
      'setSystemProxy': false,
      'proxyPassDomains': <String>[],
    });
    return prepared ?? false;
  }

  static Future<void> stop() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('stopVpn');
  }

  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }
}
