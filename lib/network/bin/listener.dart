import 'package:proxypin_ai/network/channel/channel.dart';
import 'package:proxypin_ai/network/channel/channel_context.dart';
import 'package:proxypin_ai/network/http/http.dart';
import 'package:proxypin_ai/network/http/websocket.dart';

///请求和响应事件监听
abstract class EventListener {
  void onRequest(Channel channel, HttpRequest request);

  void onResponse(ChannelContext channelContext, HttpResponse response);

  void onMessage(Channel channel, HttpMessage message, WebSocketFrame frame) {}
}


class CombinedEventListener extends EventListener {
  final List<EventListener> listeners;

  CombinedEventListener(this.listeners);

  @override
  void onRequest(Channel channel, HttpRequest request) {
    for (var element in listeners) {
      element.onRequest(channel, request);
    }
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    for (var element in listeners) {
      element.onResponse(channelContext, response);
    }
  }

  @override
  void onMessage(Channel channel, HttpMessage message, WebSocketFrame frame) {
    for (var element in listeners) {
      element.onMessage(channel, message, frame);
    }
  }
}
