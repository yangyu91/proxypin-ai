package com.network.proxy

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Base64
import android.util.Log
import go.Seq
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * AndroidLibXrayLite 的最小生命周期封装。
 *
 * 核心仅监听应用私有的 127.0.0.1 入站。ProxyPin 继续负责 HTTPS MITM、抓包记录
 * 和 VPN TUN 转发；其上游指向此 HTTP 入站后，VMess/VLESS/Trojan/Shadowsocks
 * 等协议由 Xray 处理。当前 VPN 会排除宿主应用自身，因此核心的远端连接不会回灌 TUN。
 */
object XrayCoreManager {
    const val LOCAL_SOCKS_PORT = 10808
    const val LOCAL_HTTP_PORT = 10809

    @Volatile
    private var controller: CoreController? = null

    @Volatile
    private var activeProtocol: String? = null

    @Volatile
    private var activeName: String? = null

    @Volatile
    private var lastError: String? = null

    private val callback = object : CoreCallbackHandler {
        override fun startup(): Long {
            Log.i(TAG, "Xray core startup callback")
            return 0
        }

        override fun shutdown(): Long {
            Log.i(TAG, "Xray core shutdown callback")
            return 0
        }

        override fun onEmitStatus(code: Long, message: String?): Long {
            if (!message.isNullOrBlank()) Log.i(TAG, "Xray[$code] $message")
            return 0
        }
    }

    @Synchronized
    fun start(context: Context, rawLink: String, displayName: String? = null): Map<String, Any?> {
        val link = rawLink.trim()
        require(link.contains("://")) { "节点链接格式无效" }
        val protocol = link.substringBefore("://").lowercase()
        require(protocol in SUPPORTED_PROTOCOLS) { "暂不支持的 Xray 节点协议：$protocol" }

        stopLocked()
        lastError = null
        return try {
            val config = XrayConfigFactory.build(link)
            initializeEnvironment(context.applicationContext)
            val newController = Libv2ray.newCoreController(callback)
            newController.startLoop(config, 0)
            if (!newController.isRunning) error("Xray 核心未能启动")
            controller = newController
            activeProtocol = protocol
            activeName = displayName?.takeIf { it.isNotBlank() } ?: protocol
            status()
        } catch (error: Throwable) {
            controller = null
            activeProtocol = null
            activeName = null
            lastError = error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName
            Log.e(TAG, "Unable to start Xray core", error)
            status()
        }
    }

    @Synchronized
    fun stop(): Map<String, Any?> {
        stopLocked()
        return status()
    }

    @Synchronized
    fun status(): Map<String, Any?> {
        val running = controller?.isRunning == true
        return hashMapOf(
            "running" to running,
            "protocol" to activeProtocol,
            "name" to activeName,
            "httpPort" to LOCAL_HTTP_PORT,
            "socksPort" to LOCAL_SOCKS_PORT,
            "error" to lastError,
            "version" to coreVersion(),
        )
    }

    @Synchronized
    private fun stopLocked() {
        val oldController = controller
        controller = null
        activeProtocol = null
        activeName = null
        if (oldController != null) {
            try {
                if (oldController.isRunning) oldController.stopLoop()
            } catch (error: Throwable) {
                Log.w(TAG, "Unable to stop Xray core cleanly", error)
            }
        }
    }

    private fun initializeEnvironment(context: Context) {
        val dataDirectory = File(context.filesDir, "xray").apply { mkdirs() }
        Seq.setContext(context)
        // Xray 使用应用私有目录读取 dat/cert 等可选资产；不从网络下载核心或规则文件。
        Libv2ray.initCoreEnv(dataDirectory.absolutePath, Build.FINGERPRINT.take(64))
    }

    private fun coreVersion(): String? = try {
        Libv2ray.checkVersionX()
    } catch (_: Throwable) {
        null
    }

    private const val TAG = "ProxyPinXray"
    private val SUPPORTED_PROTOCOLS = setOf("vmess", "vless", "trojan", "ss", "socks", "socks5")
}

/** Converts common subscription links into a private Xray proxy-only configuration. */
private object XrayConfigFactory {
    fun build(rawLink: String): String {
        val protocol = rawLink.substringBefore("://").lowercase()
        val proxyOutbound = when (protocol) {
            "vmess" -> vmessOutbound(rawLink)
            "vless" -> vlessOutbound(rawLink)
            "trojan" -> trojanOutbound(rawLink)
            "ss" -> shadowsocksOutbound(rawLink)
            "socks", "socks5" -> socksOutbound(rawLink)
            else -> error("不支持的协议：$protocol")
        }

        val inbounds = JSONArray()
            .put(JSONObject()
                .put("tag", "proxypin-socks")
                .put("listen", "127.0.0.1")
                .put("port", XrayCoreManager.LOCAL_SOCKS_PORT)
                .put("protocol", "socks")
                .put("settings", JSONObject().put("auth", "noauth").put("udp", true)))
            .put(JSONObject()
                .put("tag", "proxypin-http")
                .put("listen", "127.0.0.1")
                .put("port", XrayCoreManager.LOCAL_HTTP_PORT)
                .put("protocol", "http")
                .put("settings", JSONObject()))

        val outbounds = JSONArray()
            .put(proxyOutbound.put("tag", "proxy"))
            .put(JSONObject().put("tag", "direct").put("protocol", "freedom"))
            .put(JSONObject().put("tag", "block").put("protocol", "blackhole"))

        return JSONObject()
            .put("log", JSONObject().put("loglevel", "warning"))
            .put("inbounds", inbounds)
            .put("outbounds", outbounds)
            .put("routing", JSONObject()
                .put("domainStrategy", "AsIs")
                .put("rules", JSONArray().put(JSONObject()
                    .put("type", "field")
                    .put("inboundTag", JSONArray().put("proxypin-socks").put("proxypin-http"))
                    .put("outboundTag", "proxy"))))
            .toString()
    }

    private fun vmessOutbound(link: String): JSONObject {
        val encoded = link.substringAfter("://").substringBefore("#")
        val profile = JSONObject(decodeBase64(encoded))
        val address = profile.string("add", "address")
        val port = profile.port("port")
        val user = JSONObject()
            .put("id", profile.string("id"))
            .put("alterId", profile.intValue("aid", defaultValue = 0))
            .put("security", profile.optString("scy", "auto").ifBlank { "auto" })
        val settings = JSONObject().put("vnext", JSONArray().put(JSONObject()
            .put("address", address)
            .put("port", port)
            .put("users", JSONArray().put(user))))
        return JSONObject().put("protocol", "vmess").put("settings", settings)
            .put("streamSettings", streamSettings(
                network = profile.optString("net", "tcp"),
                security = profile.optString("tls", ""),
                host = profile.optString("host"),
                path = profile.optString("path"),
                sni = profile.optString("sni"),
                fingerprint = profile.optString("fp"),
                publicKey = profile.optString("pbk"),
                shortId = profile.optString("sid"),
                serviceName = profile.optString("serviceName"),
            ))
    }

    private fun vlessOutbound(link: String): JSONObject {
        val uri = Uri.parse(link)
        val user = JSONObject()
            .put("id", decode(uri.encodedUserInfo))
            .put("encryption", uri.query("encryption", "none"))
        uri.query("flow", "").takeIf { it.isNotBlank() }?.let { user.put("flow", it) }
        val settings = JSONObject().put("vnext", JSONArray().put(JSONObject()
            .put("address", uri.host.orEmpty().requireNotBlank("VLESS 地址为空"))
            .put("port", uri.port.requirePositivePort())
            .put("users", JSONArray().put(user))))
        return JSONObject().put("protocol", "vless").put("settings", settings)
            .put("streamSettings", streamSettings(
                network = uri.query("type", "tcp"),
                security = uri.query("security", "none"),
                host = uri.query("host", ""),
                path = uri.query("path", ""),
                sni = uri.query("sni", ""),
                fingerprint = uri.query("fp", ""),
                publicKey = uri.query("pbk", ""),
                shortId = uri.query("sid", ""),
                serviceName = uri.query("serviceName", ""),
            ))
    }

    private fun trojanOutbound(link: String): JSONObject {
        val uri = Uri.parse(link)
        val settings = JSONObject().put("servers", JSONArray().put(JSONObject()
            .put("address", uri.host.orEmpty().requireNotBlank("Trojan 地址为空"))
            .put("port", uri.port.requirePositivePort())
            .put("password", decode(uri.encodedUserInfo))))
        return JSONObject().put("protocol", "trojan").put("settings", settings)
            .put("streamSettings", streamSettings(
                network = uri.query("type", "tcp"),
                security = uri.query("security", "tls"),
                host = uri.query("host", ""),
                path = uri.query("path", ""),
                sni = uri.query("sni", ""),
                fingerprint = uri.query("fp", ""),
                publicKey = uri.query("pbk", ""),
                shortId = uri.query("sid", ""),
                serviceName = uri.query("serviceName", ""),
            ))
    }

    private fun shadowsocksOutbound(link: String): JSONObject {
        val withoutScheme = link.substringAfter("://").substringBefore("#")
        val normalized = if (withoutScheme.contains("@")) withoutScheme else decodeBase64(withoutScheme)
        val uri = Uri.parse("ss://$normalized")
        val encodedUserInfo = uri.encodedUserInfo.orEmpty()
        val userInfo = Uri.decode(encodedUserInfo)
        val credentialsText = if (userInfo.contains(":")) userInfo else decodeBase64(userInfo)
        val credentials = credentialsText.split(":", limit = 2)
        require(credentials.size == 2) { "Shadowsocks 缺少加密方法或密码" }
        val settings = JSONObject().put("servers", JSONArray().put(JSONObject()
            .put("address", uri.host.orEmpty().requireNotBlank("Shadowsocks 地址为空"))
            .put("port", uri.port.requirePositivePort())
            .put("method", credentials[0])
            .put("password", credentials[1])))
        return JSONObject().put("protocol", "shadowsocks").put("settings", settings)
    }

    private fun socksOutbound(link: String): JSONObject {
        val uri = Uri.parse(link)
        val server = JSONObject()
            .put("address", uri.host.orEmpty().requireNotBlank("SOCKS 地址为空"))
            .put("port", uri.port.requirePositivePort())
        val userInfo = decode(uri.encodedUserInfo)
        if (userInfo.isNotBlank()) {
            val user = userInfo.split(":", limit = 2)
            server.put("users", JSONArray().put(JSONObject()
                .put("user", user[0])
                .put("pass", user.getOrElse(1) { "" })))
        }
        return JSONObject().put("protocol", "socks").put("settings", JSONObject().put("servers", JSONArray().put(server)))
    }

    private fun streamSettings(
        network: String,
        security: String,
        host: String,
        path: String,
        sni: String,
        fingerprint: String,
        publicKey: String,
        shortId: String,
        serviceName: String,
    ): JSONObject {
        val normalizedNetwork = network.ifBlank { "tcp" }
        val normalizedSecurity = when (security.lowercase()) {
            "tls", "reality" -> security.lowercase()
            else -> "none"
        }
        return JSONObject().put("network", normalizedNetwork).put("security", normalizedSecurity).also { stream ->
            when (normalizedNetwork) {
                "ws" -> stream.put("wsSettings", JSONObject().put("path", path.ifBlank { "/" }).put("headers", JSONObject().put("Host", host)))
                "grpc" -> stream.put("grpcSettings", JSONObject().put("serviceName", serviceName.ifBlank { path }))
                "httpupgrade" -> stream.put("httpupgradeSettings", JSONObject().put("path", path.ifBlank { "/" }).put("host", host))
            }
            if (normalizedSecurity == "tls") {
                stream.put("tlsSettings", JSONObject()
                    .put("serverName", sni.ifBlank { host })
                    .put("fingerprint", fingerprint.ifBlank { "chrome" }))
            } else if (normalizedSecurity == "reality") {
                stream.put("realitySettings", JSONObject()
                    .put("serverName", sni.ifBlank { host })
                    .put("fingerprint", fingerprint.ifBlank { "chrome" })
                    .put("publicKey", publicKey.requireNotBlank("REALITY 节点缺少 pbk"))
                    .put("shortId", shortId))
            }
        }
    }

    private fun JSONObject.string(vararg keys: String): String {
        keys.forEach { key -> optString(key).takeIf { it.isNotBlank() }?.let { return it } }
        error("节点缺少 ${keys.first()} 参数")
    }

    private fun JSONObject.port(key: String): Int = when (val value = opt(key)) {
        is Number -> value.toInt().requirePositivePort()
        else -> value?.toString()?.toIntOrNull()?.requirePositivePort() ?: error("节点端口无效")
    }

    private fun JSONObject.intValue(key: String, defaultValue: Int): Int = when (val value = opt(key)) {
        is Number -> value.toInt()
        else -> value?.toString()?.toIntOrNull() ?: defaultValue
    }

    private fun Uri.query(key: String, defaultValue: String): String = getQueryParameter(key)?.takeIf { it.isNotBlank() } ?: defaultValue
    private fun decode(value: String?): String = value?.let { Uri.decode(it) }.orEmpty()
    private fun Int.requirePositivePort(): Int = takeIf { it in 1..65535 } ?: error("节点端口无效")
    private fun String.requireNotBlank(message: String): String = takeIf { it.isNotBlank() } ?: error(message)

    private fun decodeBase64(value: String): String {
        val normalized = value.trim().replace('-', '+').replace('_', '/')
        val padded = normalized + "=".repeat((4 - normalized.length % 4) % 4)
        return String(Base64.decode(padded, Base64.DEFAULT), Charsets.UTF_8)
    }
}
