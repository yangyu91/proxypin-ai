# Android Xray 协议核心集成说明

ProxyPin Android 版已内嵌 **AndroidLibXrayLite v26.8.20** 的 `libv2ray.aar`，并通过 GoMobile JNI 在应用进程中启动 Xray Core。该库由 2dust 维护，采用 LGPL-3.0；随 APK 分发时保留其上游来源与许可证信息。[1]

## 支持范围

| 节点协议 | 导入格式 | 运行方式 |
|---|---|---|
| VMess | `vmess://` Base64 JSON | 转换为 Xray outbound |
| VLESS | `vless://` | 转换为 Xray outbound，支持 TCP、WebSocket、gRPC、HTTP Upgrade、TLS、REALITY 基础参数 |
| Trojan | `trojan://` | 转换为 Xray outbound，支持 TLS 与上述传输参数 |
| Shadowsocks | `ss://` | 兼容完整 Base64 和用户信息 Base64 两种常用分享格式 |
| SOCKS5 | `socks://`、`socks5://` | 转换为 Xray SOCKS outbound |
| HTTP | `http://` | 继续使用原有 HTTP CONNECT 级联，不启动 Xray |

## 流量链路

```text
Firefox GeckoView / Android VPN TUN
        ↓
本机 ProxyPin HTTP/HTTPS MITM（负责抓包）
        ↓
127.0.0.1:10809（Xray HTTP inbound）
        ↓
VMess / VLESS / Trojan / Shadowsocks / SOCKS 上游节点
```

协议核心只监听 `127.0.0.1:10808`（SOCKS）和 `127.0.0.1:10809`（HTTP），不会对局域网开放。现有 VPN 在本机 ProxyPin 模式下排除宿主应用自身，因此 Xray 的出站连接不会回灌到 TUN；Firefox 和其他经 VPN 接入的流量仍先经过 ProxyPin，故抓包记录与 HTTPS MITM 保持有效。

选择协议节点时，应用先启动 Xray，再将 ProxyPin 的上游 HTTP 代理指向 `127.0.0.1:10809`，然后启动 Android VPN。断开 VPN、通知栏停止服务或服务销毁时都会停止 Xray 并释放本机端口。

## 已知边界

此版本的内置转换器面向常见链接。订阅中需要其他专用核心的协议，例如 Hysteria、TUIC、WireGuard 或 SSH，不会伪装为可用节点；界面会标记为暂不支持。复杂的路由规则、远程规则集、全局 DNS 策略和多跳链路仍应使用完整的专用客户端配置。

## 参考

[1] [2dust/AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite)（LGPL-3.0，Xray Android GoMobile 绑定）

[2] [2dust/v2rayNG](https://github.com/2dust/v2rayNG)（Xray Android 集成与 VPN 生命周期参考实现）
