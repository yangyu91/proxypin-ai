import 'dart:io';

import 'package:flutter/services.dart';

import '../channel/host_port.dart';

class XrayCoreStatus {
  final bool running;
  final String? protocol;
  final String? name;
  final int httpPort;
  final int socksPort;
  final String? error;
  final String? version;

  const XrayCoreStatus({required this.running, this.protocol, this.name, this.httpPort = 10809, this.socksPort = 10808, this.error, this.version});

  factory XrayCoreStatus.fromMap(Map<dynamic, dynamic>? value) => XrayCoreStatus(
        running: value?['running'] == true,
        protocol: value?['protocol']?.toString(),
        name: value?['name']?.toString(),
        httpPort: (value?['httpPort'] as num?)?.toInt() ?? 10809,
        socksPort: (value?['socksPort'] as num?)?.toInt() ?? 10808,
        error: value?['error']?.toString(),
        version: value?['version']?.toString(),
      );
}

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

  /// 启动嵌入式 Xray Core。核心只在 127.0.0.1 开放 HTTP/SOCKS 入站；
  /// Firefox 与 VPN 仍先进入本机 ProxyPin HTTPS MITM，随后再级联该入站。
  static Future<XrayCoreStatus> startXrayCore(String rawLink, {String? name}) async {
    if (!Platform.isAndroid) return const XrayCoreStatus(running: false, error: 'Xray 协议核心当前仅支持 Android');
    final result = await _channel.invokeMapMethod<dynamic, dynamic>('startXrayCore', <String, dynamic>{
      'rawLink': rawLink,
      'name': name,
    });
    return XrayCoreStatus.fromMap(result);
  }

  static Future<XrayCoreStatus> xrayStatus() async {
    if (!Platform.isAndroid) return const XrayCoreStatus(running: false, error: 'Xray 协议核心当前仅支持 Android');
    final result = await _channel.invokeMapMethod<dynamic, dynamic>('xrayStatus');
    return XrayCoreStatus.fromMap(result);
  }

  static Future<void> stopXrayCore() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('stopXrayCore');
  }

  static Future<void> stop() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('stopVpn');
  }

  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }
}
