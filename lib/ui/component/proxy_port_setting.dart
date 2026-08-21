import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin_ai/l10n/app_localizations.dart';
import 'package:proxypin_ai/network/bin/server.dart';

class PortWidget extends StatefulWidget {
  final ProxyServer proxyServer;
  final TextStyle? textStyle;
  final String? title;

  const PortWidget({super.key, required this.proxyServer, this.textStyle, this.title});

  @override
  State<StatefulWidget> createState() {
    return _PortState();
  }
}

class _PortState extends State<PortWidget> {
  final textController = TextEditingController();
  final FocusNode portFocus = FocusNode();

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    textController.text = widget.proxyServer.port.toString();
    portFocus.addListener(() async {
      //失去焦点
      if (!portFocus.hasFocus && textController.text != widget.proxyServer.port.toString()) {
        final port = int.tryParse(textController.text) ?? -1;
        // 端口 0 会让 OS 随机分配端口，但 Configuration 仍保存 0，导致 VPN、
        // Firefox 和外部设备继续连接到错误端口，因此不能作为持久代理监听端口。
        if (port < 1 || port > 65535) {
          textController.text = widget.proxyServer.port.toString();
          FlutterToastr.show("Port out of range 1-65535", context, duration: 3);
          return;
        }

        final lockedFirefoxPort = widget.proxyServer.lockedEmbeddedFirefoxProxyPort;
        if (lockedFirefoxPort != null && port != lockedFirefoxPort) {
          textController.text = lockedFirefoxPort.toString();
          FlutterToastr.show("Firefox 内核已固定使用端口 $lockedFirefoxPort，请重启应用后再修改端口", context, duration: 4);
          return;
        }

        widget.proxyServer.configuration.port = port;

        if (widget.proxyServer.isRunning) {
          String message = localizations.proxyPortRepeat(widget.proxyServer.port);
          widget.proxyServer.restart().catchError((e) => FlutterToastr.show(message, context, duration: 3));
        }
        widget.proxyServer.configuration.flushConfig();
      }
    });
  }

  @override
  void dispose() {
    portFocus.dispose();
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      const Padding(padding: EdgeInsets.only(left: 15)),
      Text(widget.title ?? localizations.port, style: widget.textStyle),
      SizedBox(
          width: 80,
          child: TextFormField(
            focusNode: portFocus,
            controller: textController,
            textAlign: TextAlign.center,
            onTapOutside: (event) => portFocus.unfocus(),
            keyboardType: TextInputType.datetime,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(5),
              FilteringTextInputFormatter.allow(RegExp("[0-9]"))
            ],
            decoration: const InputDecoration(),
          ))
    ]);
  }
}
