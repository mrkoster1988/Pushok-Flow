package shop.pushok.flow

import org.json.JSONArray
import org.json.JSONObject

/** Creates only app-owned routing. User links cannot supply listeners, rules, files or logs. */
object XrayConfig {
    const val MTU = 1500
    const val IPV4 = "172.30.0.1"
    const val IPV6 = "fdfe:dcba:9876::1"
    val DNS = listOf("1.1.1.1", "1.0.0.1")

    fun build(profile: VlessProfile.Parsed, tunFd: Int = 0): String {
        val user = JSONObject().put("id", profile.uuid).put("encryption", "none")
        profile.flow?.takeIf { it.isNotEmpty() }?.let { user.put("flow", it) }
        val server = JSONObject().put("address", profile.host).put("port", profile.port)
            .put("users", JSONArray().put(user))
        val security = JSONObject().put("serverName", profile.serverName)
        security.put("fingerprint", profile.fingerprint)
        val stream = JSONObject().put("network", "raw").put("security", profile.security)
        if (profile.security == "reality") {
            // Current Xray names the server's public key "password"; 3x-ui exports it as pbk.
            security.put("password", profile.realityPublicKey)
                .put("shortId", profile.realityShortId ?: "")
            profile.spiderX?.let { security.put("spiderX", it) }
            stream.put("realitySettings", security)
        } else {
            if (profile.alpn.isNotEmpty()) security.put("alpn", JSONArray(profile.alpn))
            stream.put("tlsSettings", security)
        }
        val outbound = JSONObject().put("tag", "proxy").put("protocol", "vless")
            .put("settings", JSONObject().put("vnext", JSONArray().put(server)))
            .put("streamSettings", stream)
        val inbound = JSONObject().put("tag", "tun").put("protocol", "tun")
            .put("settings", JSONObject().put("name", "pushok-flow").put("mtu", MTU).put("userLevel", 0))
        return JSONObject()
            .put("env", JSONObject().put("xray.tun.fd", tunFd.toString()))
            .put("log", JSONObject().put("loglevel", "none").put("access", "none").put("error", "none"))
            .put("inbounds", JSONArray().put(inbound))
            .put("outbounds", JSONArray().put(outbound))
            .toString()
    }
}
