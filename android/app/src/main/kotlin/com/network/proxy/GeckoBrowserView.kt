package com.network.proxy

import android.content.Context
import android.util.Log
import android.view.View
import java.io.File
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoRuntimeSettings
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.StorageController

/**
 * Firefox GeckoView 的 Flutter 平台视图。
 *
 * GeckoRuntime 在一个 Android 进程内只能创建一次，因此所有浏览器标签共享
 * 同一运行时，而每个 Flutter 平台视图持有独立 GeckoSession。
 */
class GeckoBrowserViewFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        return GeckoBrowserView(context, messenger, viewId, params)
    }
}

private object GeckoRuntimeHolder {
    private var runtime: GeckoRuntime? = null
    private var configuredProxyPort: Int? = null

    @Synchronized
    fun get(context: Context, localProxyPort: Int): GeckoRuntime {
        if (runtime == null) {
            // Gecko 默认维护独立 CA 库。启用 Enterprise Roots 后会导入 Android
            // 已安装的第三方根证书，使用户明确安装并信任 ProxyPin CA 后可进行 HTTPS MITM。
            // 同时把 Gecko 的 HTTP/HTTPS 偏好指向本机 ProxyPin，避免真实流量绕过 Dart 抓包服务。
            val configFile = File(context.filesDir, "proxypin-gecko-config.yaml")
            configFile.writeText("""
prefs:
  network.proxy.type: 1
  network.proxy.http: "127.0.0.1"
  network.proxy.http_port: $localProxyPort
  network.proxy.ssl: "127.0.0.1"
  network.proxy.ssl_port: $localProxyPort
  network.proxy.share_proxy_settings: true
  network.proxy.no_proxies_on: "localhost, 127.0.0.1"
""".trimIndent())
            val settings = GeckoRuntimeSettings.Builder()
                .enterpriseRootsEnabled(true)
                .configFilePath(configFile.absolutePath)
                .build()
            runtime = GeckoRuntime.create(context.applicationContext, settings)
            configuredProxyPort = localProxyPort
        } else if (configuredProxyPort != localProxyPort) {
            Log.w("GeckoRuntime", "local proxy port changed after runtime startup; restart app to apply $localProxyPort")
        }
        return runtime!!
    }
}

private class GeckoBrowserView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    params: Map<String, Any?>,
) : PlatformView, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val geckoView = GeckoView(context)
    private val session = GeckoSession()
    private val methodChannel = MethodChannel(messenger, "com.proxy/gecko_browser/$viewId")
    private val eventChannel = EventChannel(messenger, "com.proxy/gecko_browser/events/$viewId")
    private var eventSink: EventChannel.EventSink? = null
    private var currentUrl: String = params["initialUrl"]?.toString() ?: "https://www.baidu.com/"
    private val localProxyPort: Int = (params["localProxyPort"] as? Number)?.toInt() ?: 9099

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)

        session.setContentDelegate(object : GeckoSession.ContentDelegate {
            override fun onTitleChange(session: GeckoSession, title: String?) {
                emit("title", mapOf("title" to (title ?: ""), "url" to currentUrl))
            }
        })
        session.setNavigationDelegate(object : GeckoSession.NavigationDelegate {
            override fun onLoadRequest(
                session: GeckoSession,
                request: GeckoSession.NavigationDelegate.LoadRequest,
            ): GeckoResult<AllowOrDeny>? {
                if (isBrokenBaiduRedirect(request.uri)) {
                    emit("navigationBlocked", mapOf("url" to request.uri, "reason" to "baidu_long_redirect"))
                    return GeckoResult.fromValue(AllowOrDeny.DENY)
                }
                return null
            }
        })
        session.setProgressDelegate(object : GeckoSession.ProgressDelegate {
            override fun onPageStart(session: GeckoSession, url: String) {
                currentUrl = url
                emit("pageStart", mapOf("url" to url))
            }

            override fun onProgressChange(session: GeckoSession, progress: Int) {
                emit("progress", mapOf("progress" to progress, "url" to currentUrl))
            }

            override fun onPageStop(session: GeckoSession, success: Boolean) {
                emit("pageStop", mapOf("success" to success, "url" to currentUrl))
            }
        })

        session.open(GeckoRuntimeHolder.get(context, localProxyPort))
        geckoView.setSession(session)
        session.loadUri(currentUrl)
    }

    override fun getView(): View = geckoView

    override fun dispose() {
        eventSink = null
        eventChannel.setStreamHandler(null)
        methodChannel.setMethodCallHandler(null)
        session.close()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadUrl" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("invalid_url", "URL 不能为空", null)
                } else {
                    session.loadUri(url)
                    result.success(true)
                }
            }
            "reload" -> {
                session.reload()
                result.success(true)
            }
            "goBack" -> {
                session.goBack()
                result.success(true)
            }
            "goForward" -> {
                session.goForward()
                result.success(true)
            }
            "stop" -> {
                session.stop()
                result.success(true)
            }
            "clearHistory" -> {
                session.purgeHistory()
                result.success(true)
            }
            "clearData" -> {
                session.purgeHistory()
                GeckoRuntimeHolder.get(geckoView.context, localProxyPort).storageController.clearData(StorageController.ClearFlags.ALL)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        emit("ready", mapOf("url" to currentUrl, "engine" to "Firefox GeckoView", "localProxyPort" to localProxyPort, "enterpriseRootsEnabled" to true))
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun isBrokenBaiduRedirect(url: String): Boolean {
        val lower = url.lowercase()
        val isBaidu = lower.contains("://www.baidu.com/") || lower.contains("://m.baidu.com/")
        val isRedirect = lower.contains("/link?") || lower.contains("/from") || lower.contains("redirect")
        return isBaidu && isRedirect && url.length > 4096
    }

    private fun emit(type: String, payload: Map<String, Any?>) {
        eventSink?.success(mapOf("type" to type, "payload" to payload))
    }
}
