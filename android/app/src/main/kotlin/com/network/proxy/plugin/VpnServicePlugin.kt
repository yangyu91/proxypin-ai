package com.network.proxy.plugin

import android.os.Build
import androidx.core.content.ContextCompat
import com.network.proxy.ProxyVpnService
import com.network.proxy.XrayCoreManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

class VpnServicePlugin : AndroidFlutterPlugin() {
    companion object {
        const val CHANNEL = "com.proxy/proxyVpn"
        const val REQUEST_CODE: Int = 24
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isRunning" -> {
                    result.success(ProxyVpnService.isRunning)
                }

                "startVpn" -> {
                    val host = call.argument<String>("proxyHost")
                    val port = call.argument<Int>("proxyPort")
                    val allowApps = call.argument<ArrayList<String>>("allowApps")
                    val disallowApps = call.argument<ArrayList<String>>("disallowApps")
                    val setSystemProxy = call.argument<Boolean>("setSystemProxy") ?: true
                    val proxyPassDomains = call.argument<ArrayList<String>>("proxyPassDomains")

                    val prepareVpn = ProxyVpnService.prepareVpn(
                        activity,
                        host!!,
                        port!!,
                        allowApps,
                        disallowApps,
                        setSystemProxy,
                        proxyPassDomains
                    )
                    if (prepareVpn) {
                        startVpn(host, port, allowApps, disallowApps, setSystemProxy, proxyPassDomains)
                    }
                    result.success(prepareVpn)
                }

                "stopVpn" -> {
                    stopVpn()
                    result.success(null)
                }

                "startXrayCore" -> {
                    val rawLink = call.argument<String>("rawLink")
                    val name = call.argument<String>("name")
                    if (rawLink.isNullOrBlank()) {
                        result.error("invalid_node", "协议节点链接不能为空", null)
                    } else {
                        val status = XrayCoreManager.start(activity.applicationContext, rawLink, name)
                        if (status["running"] == true) {
                            result.success(status)
                        } else {
                            result.error("xray_start_failed", status["error"]?.toString() ?: "Xray 核心启动失败", status)
                        }
                    }
                }

                "stopXrayCore" -> {
                    result.success(XrayCoreManager.stop())
                }

                "xrayStatus" -> {
                    result.success(XrayCoreManager.status())
                }

                "restartVpn" -> {
                    val host = call.argument<String>("proxyHost")
                    val port = call.argument<Int>("proxyPort")
                    val allowApps = call.argument<ArrayList<String>>("allowApps")
                    val disallowApps = call.argument<ArrayList<String>>("disallowApps")
                    val setSystemProxy = call.argument<Boolean>("setSystemProxy") ?: true
                    val proxyPassDomains = call.argument<ArrayList<String>>("proxyPassDomains")

                    stopVpn()
                    startVpn(host!!, port!!, allowApps, disallowApps, setSystemProxy, proxyPassDomains)
                    result.success(null)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    /**
     * 启动vpn服务
     */
    private fun startVpn(
        host: String,
        port: Int,
        allowApps: ArrayList<String>? = arrayListOf(),
        disallowApps: ArrayList<String>? = arrayListOf(),
        setSystemProxy: Boolean = true,
        proxyPassDomains: ArrayList<String>? = null
    ) {
        val intent = ProxyVpnService.startVpnIntent(
            activity,
            host,
            port,
            allowApps,
            disallowApps,
            setSystemProxy,
            proxyPassDomains
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(activity, intent)
        } else {
            activity.startService(intent)
        }
    }

    /**
     * 停止vpn服务
     */
    private fun stopVpn() {
        // 协议核心仅服务于当前 VPN/ProxyPin 级联；断开时同步释放监听端口和 native 资源。
        XrayCoreManager.stop()
        activity.startService(ProxyVpnService.stopVpnIntent(activity))
    }
}