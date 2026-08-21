package com.network.proxy

import android.content.Context
import android.view.View
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

    @Synchronized
    fun get(context: Context): GeckoRuntime {
        if (runtime == null) {
            runtime = GeckoRuntime.create(context.applicationContext)
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

        session.open(GeckoRuntimeHolder.get(context))
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
                GeckoRuntimeHolder.get(geckoView.context).storageController.clearData(StorageController.ClearFlags.ALL)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        emit("ready", mapOf("url" to currentUrl, "engine" to "Firefox GeckoView"))
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
