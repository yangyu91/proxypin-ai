/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:async';
import 'dart:io';

import 'package:proxypin_ai/network/bin/configuration.dart';
import 'package:proxypin_ai/network/components/hosts.dart';
import 'package:proxypin_ai/network/components/interceptor.dart';
import 'package:proxypin_ai/network/components/network_condition.dart';
import 'package:proxypin_ai/network/components/report_server_interceptor.dart';
import 'package:proxypin_ai/network/components/request_block.dart';
import 'package:proxypin_ai/network/components/request_rewrite.dart';
import 'package:proxypin_ai/network/components/script.dart';
import 'package:proxypin_ai/network/handle/http_proxy_handle.dart';
import 'package:proxypin_ai/network/util/crts.dart';
import 'package:proxypin_ai/utils/platform.dart';

import '../components/request_map.dart';
import '../http/codec.dart';
import '../channel/network.dart';
import '../util/logger.dart';
import '../util/system_proxy.dart';
import 'listener.dart';
import 'package:proxypin_ai/network/components/request_breakpoint.dart';

Future<void> main() async {
  var configuration = await Configuration.instance;
  ProxyServer(configuration).start();
}

/// 代理服务器
class ProxyServer {
  static ProxyServer? current;

  /// GeckoRuntime 的代理偏好只会在首次创建运行时读取。浏览器首次使用本机代理后，
  /// 本进程内必须保持同一端口；端口变更需要完全重启应用并重新创建 GeckoRuntime。
  static int? _embeddedFirefoxProxyPort;

  //socket服务
  Server? server;

  //请求事件监听
  List<EventListener> listeners = [];

  //配置
  final Configuration configuration;

  ProxyServer(this.configuration) {
    current = this;
  }

  //是否启动
  bool get isRunning => server?.isRunning ?? false;

  ///是否启用https抓包
  bool get enableSsl => configuration.enableSsl;

  int get port => configuration.port;

  /// 供内置 Firefox 使用的稳定端口；尚未创建 Firefox 时即为当前代理端口。
  int get embeddedFirefoxProxyPort => _embeddedFirefoxProxyPort ?? port;

  int? get lockedEmbeddedFirefoxProxyPort => _embeddedFirefoxProxyPort;

  /// 在创建 GeckoView 前固化端口。返回 false 表示调用方请求的端口与已运行的
  /// Firefox 运行时不一致，不能继续让 Gecko 静默使用旧端口。
  bool reserveEmbeddedFirefoxProxyPort() {
    final candidate = port;
    final locked = _embeddedFirefoxProxyPort;
    if (locked == null) {
      _embeddedFirefoxProxyPort = candidate;
      return true;
    }
    return locked == candidate;
  }

  bool canUseEmbeddedFirefoxProxyPort(int candidate) {
    final locked = _embeddedFirefoxProxyPort;
    return locked == null || locked == candidate;
  }

  set enableSsl(bool enableSsl) {
    configuration.enableSsl = enableSsl;
    if (server == null || server?.isRunning == false) {
      return;
    }

    if (configuration.enableSystemProxy) {
      SystemProxy.setSslProxyEnable(enableSsl, port);
    }
  }

  /// 启动代理服务
  Future<Server> start() async {
    final lockedFirefoxPort = _embeddedFirefoxProxyPort;
    if (lockedFirefoxPort != null && lockedFirefoxPort != port) {
      throw StateError(
        'Firefox GeckoView 已固定使用本机代理端口 $lockedFirefoxPort；'
        '当前配置请求重绑到 $port。请重启应用后再修改端口。',
      );
    }

    Server server = Server(configuration, listener: CombinedEventListener(listeners));

    List<Interceptor> interceptors = [
      Hosts(),
      RequestMapInterceptor.instance,
      RequestRewriteInterceptor.instance,
      ScriptInterceptor(),
      RequestBlockInterceptor(),
      RequestBreakpointInterceptor.instance, // Register the interceptor
      NetworkConditionInterceptor.instance,
      ReportServerInterceptor()
    ];

    interceptors.sort((a, b) => a.priority.compareTo(b.priority));

    server.initChannel((channel) {
      channel.dispatcher.handle(
        HttpRequestCodec(),
        HttpResponseCodec(),
        HttpProxyChannelHandler(listener: CombinedEventListener(listeners), interceptors: interceptors),
      );
    });

    return server.bind(port).then((serverSocket) {
      logger.i("listen on $port");
      this.server = server;
      if (configuration.enableSystemProxy) {
        setSystemProxyEnable(true);
      }

      //初始化证书
      CertificateManager.initCAConfig();
      return server;
    });
  }

  /// 停止代理服务
  Future<Server?> stop() async {
    if (!isRunning) {
      return server;
    }

    if (configuration.enableSystemProxy) {
      await setSystemProxyEnable(false);
    }
    logger.i("stop on $port");
    await server?.stop();
    return server;
  }

  /// 设置系统代理
  Future<void> setSystemProxyEnable(bool enable) async {
    if (!Platforms.isDesktop()) {
      return;
    }

    //关闭系统代理 恢复成外部代理地址
    if (!enable && configuration.externalProxy?.enabled == true) {
      await SystemProxy.setSystemProxy(configuration.externalProxy!.port!, enableSsl, configuration.proxyPassDomains);
      return;
    }

    await SystemProxy.setSystemProxyEnable(port, enable, enableSsl, passDomains: configuration.proxyPassDomains);
  }

  /// 重启代理服务
  Future<void> restart() async {
    await stop().whenComplete(() => start());
  }

  ///检查是否监听端口 没有监听则启动
  Future<void> retryBind() async {
    try {
      await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 350));
    } catch (e) {
      logger.d('端口未被占用，尝试重新绑定 $port');
      await restart();
    }
  }

  ///添加监听器
  void addListener(EventListener listener) {
    listeners.add(listener);
  }
}
