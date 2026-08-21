# GeckoView 集成外部依据

## Mozilla 官方文档

- GeckoView 快速接入：<https://firefox-source-docs.mozilla.org/mobile/android/geckoview/consumer/geckoview-quick-start.html>
  - GeckoView 是可嵌入 Android 浏览器的 Firefox/Gecko 组件。
  - 官方要求：在 Gradle 配置 Mozilla Maven 仓库；GeckoView 要求 Java 17；添加 `org.mozilla.geckoview:geckoview:<version>` 依赖。
  - 一个进程内 `GeckoRuntime` 只能初始化一次；每个标签页使用独立 `GeckoSession`。
  - 通过 `GeckoView.setSession(session)` 显示页面，通过 `session.loadUri(...)` 导航。

- GeckoSession API：<https://mozilla.github.io/geckoview/javadoc/mozilla-central/org/mozilla/geckoview/GeckoSession.html>
  - `GeckoSession` 是一个浏览器标签或窗口，提供 `NavigationDelegate`、`ProgressDelegate` 与 `ContentDelegate`。
  - 可调用 `loadUri`、`goBack`、`goForward`、`reload`、`stop` 与 `purgeHistory`。
  - 进度与标题事件分别来自 `ProgressDelegate` 和 `ContentDelegate`。

- Flutter Android Platform Views：<https://docs.flutter.dev/platform-integration/android/platform-views>
  - Flutter 可通过 `AndroidView`/PlatformViewFactory 在 widget 树中嵌入原生 Android View。
  - 原生侧应实现 `PlatformView` 并通过 `platformViewsController.registry.registerViewFactory` 注册。

## GeckoView Maven 依赖

- 版本页面：<https://mvnrepository.com/artifact/org.mozilla.geckoview/geckoview/154.0.20260814215756>
- 依赖坐标：`org.mozilla.geckoview:geckoview:154.0.20260814215756`
- Mozilla Maven URL：`https://maven.mozilla.org/maven2/`
- 上述版本页面列出的 AAR 约 229.8 MB；引入完整 Gecko 内核会显著提高 APK 体积。

## 代理与 HTTPS 约束

- GeckoView 的网页加载可以走 Android VPN/TUN 路由；但 HTTPS 明文解密仍要求客户端信任 ProxyPin CA。
- 未安装/未信任 CA 时，合法抓包只能得到连接或主导航元数据，无法查看 HTTPS 请求头与正文。
- HTTP/2 可以通过 TLS/ALPN 透传；若要解密 HTTP/2 明文，同样依赖受信任 CA 与 MITM 代理实现。
- GeckoView 没有公开的通用 HTTP/HTTPS 代理配置 API；应用内代理应继续依赖 Android VPN/TUN 路由或系统网络路由策略。

## 记录时间

2026-08-21（用户时区 GMT+8）

## HTTPS、Android CA 与 Firefox 内核验证

Mozilla 的 GeckoView 架构文档说明：Gecko 使用独立 CA 存储，默认不会读取 Android CA 存储；将 `GeckoRuntimeSettings.Builder.enterpriseRootsEnabled(true)` 设为真后，GeckoView 会导入 Android 系统 CA 存储中由用户或企业添加的第三方根证书。因此，ProxyPin 的 CA 必须先由用户在 Android 系统中安装并信任，Firefox/GeckoView 才能接受 ProxyPin 为站点生成的 MITM 叶证书并解密 HTTPS 内容。官方 API 文档同样明确该设置会将 Android OS CA store 的第三方根证书用于 GeckoView 内部。

参考：

- <https://firefox-source-docs.mozilla.org/mobile/android/geckoview/contributor/geckoview-architecture.html>
- <https://mozilla.github.io/geckoview/javadoc/mozilla-central/org/mozilla/geckoview/GeckoRuntimeSettings.Builder.html>
- <https://support.mozilla.org/en-US/kb/setting-certificate-authorities-firefox>

## 真实自捕获链路修复

审计发现，原订阅连接代码把 Android VPN/TUN 的唯一上游直接设为外部节点；这会绕过 Dart `ProxyServer`，导致 Firefox 仅留下合成导航记录，而不是原始 HTTP/HTTPS 抓包。修复后的链路为：`GeckoView → 127.0.0.1:ProxyPin 本地代理 → HTTPS MITM/HTTP2 解码 → 外部 HTTP 代理节点 → Internet`。GeckoView 通过私有 YAML 配置文件预置 `network.proxy.*` 偏好，避免依赖未公开的 GeckoView 代理 API。

Firefox 内核只有在 ProxyPin CA 已受 Android 信任时才会显示 HTTPS/HTTP/2 明文；未信任时 HTTPS 必然失败或仅能保留客户端导航元数据，不能绕过证书信任。

## HTTP/2 验证结论

ProxyPin 的 TLS 拦截逻辑会在 `Configuration.enabledHttp2` 为真时从 ClientHello 中读取 ALPN 并传给上游；项目同时具有 HTTP/2 编解码实现。Firefox 浏览器入口会自动启用该配置，但每一个站点最终可能协商 HTTP/2 或回落到 HTTP/1.1，因此界面必须标示“HTTP/2 已启用”，而不应声称每个站点都已使用 HTTP/2。

## 配置文件安全边界

Mozilla 将可编程 Gecko 偏好归类为自动化/调试能力，并提醒自定义配置可能降低安全性。此实现将配置文件写入应用私有目录，只写入固定的本机 HTTP/HTTPS 代理偏好，不接受网页或远程内容注入偏好。

参考：<https://firefox-source-docs.mozilla.org/mobile/android/geckoview/consumer/automation.html>
