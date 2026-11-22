package shop.pushok.flow

import org.json.JSONObject

fun main() {
    val prefix = "vless://11111111-2222-4333-8444-555555555555@server.example:443"
    val tls = JSONObject(XrayConfig.build(VlessProfile.parse(prefix +
        "?type=tcp&security=tls&sni=front.example&fp=firefox&alpn=h2%2Chttp%2F1.1&flow=xtls-rprx-vision"), 77))
    check(tls.getJSONObject("env").getString("xray.tun.fd") == "77")
    check(tls.getJSONObject("log").getString("loglevel") == "none")
    check(tls.getJSONObject("log").getString("access") == "none")
    check(tls.getJSONObject("log").getString("error") == "none")
    check(tls.getJSONArray("inbounds").length() == 1)
    val inbound = tls.getJSONArray("inbounds").getJSONObject(0)
    check(inbound.getString("protocol") == "tun")
    check(!inbound.has("port") && !inbound.has("listen"))
    val settings = inbound.getJSONObject("settings")
    check(settings.getString("name") == "pushok-flow")
    check(!settings.has("autoOutboundsInterface") && !settings.has("autoSystemRoutingTable"))
    check(tls.getJSONArray("outbounds").length() == 1) // No accidental direct/fallback outbound.
    check(!tls.has("routing") && !tls.has("api"))
    val outbound = tls.getJSONArray("outbounds").getJSONObject(0)
    check(outbound.getString("protocol") == "vless")
    val server = outbound.getJSONObject("settings").getJSONArray("vnext").getJSONObject(0)
    check(server.getString("address") == "server.example" && server.getInt("port") == 443)
    val user = server.getJSONArray("users").getJSONObject(0)
    check(user.getString("id") == "11111111-2222-4333-8444-555555555555")
    check(user.getString("encryption") == "none" && user.getString("flow") == "xtls-rprx-vision")
    val stream = outbound.getJSONObject("streamSettings")
    check(stream.getString("network") == "raw" && stream.getString("security") == "tls")
    val security = stream.getJSONObject("tlsSettings")
    check(security.getString("serverName") == "front.example")
    check(security.getString("fingerprint") == "firefox")
    check(security.getJSONArray("alpn").getString(0) == "h2")
    check(security.getJSONArray("alpn").getString(1) == "http/1.1")
    check(!security.has("allowInsecure") && !security.has("insecure"))

    // RFC 7748's public X25519 test vector, not a credential for any server.
    val key = "3p7bfXt9wbTTW2HC7OQ1Nz-DQ8hbeGdNrfx-FG-IK08"
    val reality = JSONObject(XrayConfig.build(VlessProfile.parse(prefix +
        "?type=raw&security=reality&sni=front.example&fp=chrome&pbk=$key&sid=aabb&spx=%2F&flow=xtls-rprx-vision"), 91))
    val realityStream = reality.getJSONArray("outbounds").getJSONObject(0).getJSONObject("streamSettings")
    check(!realityStream.has("tlsSettings"))
    val realitySettings = realityStream.getJSONObject("realitySettings")
    check(realitySettings.getString("password") == key && !realitySettings.has("publicKey"))
    check(realitySettings.getString("shortId") == "aabb")
    check(realitySettings.getString("spiderX") == "/")
    check(realitySettings.getString("fingerprint") == "chrome")
    check(!realitySettings.has("allowInsecure") && !realitySettings.has("show"))
    check(reality.getJSONObject("env").getString("xray.tun.fd") == "91")

    fun transported(query: String): JSONObject {
        val config = JSONObject(XrayConfig.build(VlessProfile.parse(prefix + query), 97))
        check(config.getJSONObject("env").getString("xray.tun.fd") == "97")
        check(config.getJSONObject("log").getString("loglevel") == "none")
        check(config.getJSONObject("log").getString("access") == "none")
        check(config.getJSONObject("log").getString("error") == "none")
        check(config.getJSONArray("inbounds").length() == 1)
        check(config.getJSONArray("inbounds").getJSONObject(0).getString("protocol") == "tun")
        check(config.getJSONArray("outbounds").length() == 1)
        val selected = config.getJSONArray("outbounds").getJSONObject(0)
        check(selected.getString("protocol") == "vless")
        check(!selected.has("mux")) // gRPC has its own transport multiplexing.
        check(!config.has("routing") && !config.has("api"))
        val account = selected.getJSONObject("settings").getJSONArray("vnext").getJSONObject(0)
            .getJSONArray("users").getJSONObject(0)
        check(!account.has("flow")) // This release keeps Vision on RAW/TCP only.
        val transport = selected.getJSONObject("streamSettings")
        check(transport.getString("security") == "tls")
        check(!transport.has("realitySettings"))
        return transport
    }

    val websocket = transported("?type=ws&security=tls&sni=front.example&host=cdn.example%3A8443&" +
        "path=%2Fflow%3Fx%3D1%26y%3D2&alpn=http%2F1.1")
    check(websocket.getString("network") == "ws")
    check(websocket.getJSONObject("wsSettings").getString("path") == "/flow?x=1&y=2")
    check(websocket.getJSONObject("wsSettings").getString("host") == "cdn.example:8443")
    check(!websocket.getJSONObject("wsSettings").has("headers"))
    check(!websocket.has("grpcSettings"))
    check(websocket.getJSONObject("tlsSettings").getString("serverName") == "front.example")
    check(websocket.getJSONObject("tlsSettings").getJSONArray("alpn").toString() == "[\"http/1.1\"]")

    val websocketDefaults = transported("?type=ws&security=tls&path=&host=")
    check(websocketDefaults.getJSONObject("wsSettings").getString("path") == "/")
    check(!websocketDefaults.getJSONObject("wsSettings").has("host"))
    check(!websocketDefaults.getJSONObject("tlsSettings").has("alpn")) // Core selects HTTP/1.1.
    val websocketAlpn = transported("?type=ws&security=tls&alpn=h2%2Chttp%2F1.1")
    check(websocketAlpn.getJSONObject("tlsSettings").getJSONArray("alpn").toString() == "[\"h2\",\"http/1.1\"]")

    val grpc = transported("?type=grpc&security=tls&sni=front.example&serviceName=flow%2Bservice&" +
        "authority=grpc.example%3A8443&mode=multi&alpn=h2%2Chttp%2F1.1")
    check(grpc.getString("network") == "grpc")
    check(grpc.getJSONObject("grpcSettings").getString("serviceName") == "flow+service")
    check(grpc.getJSONObject("grpcSettings").getString("authority") == "grpc.example:8443")
    check(grpc.getJSONObject("grpcSettings").getBoolean("multiMode"))
    check(!grpc.has("wsSettings"))
    check(grpc.getJSONObject("tlsSettings").getString("serverName") == "front.example")
    check(grpc.getJSONObject("tlsSettings").getJSONArray("alpn").toString() == "[\"h2\",\"http/1.1\"]")

    val grpcDefaults = transported("?type=grpc&security=tls&serviceName=flow&authority=")
    check(!grpcDefaults.getJSONObject("grpcSettings").getBoolean("multiMode"))
    check(!grpcDefaults.getJSONObject("grpcSettings").has("authority"))
    check(!grpcDefaults.getJSONObject("tlsSettings").has("alpn")) // Core starts with h2.
    val grpcCustomPath = transported("?type=grpc&security=tls&serviceName=%2Fcustom%2FTun&mode=gun&alpn=h2")
    check(grpcCustomPath.getJSONObject("grpcSettings").getString("serviceName") == "/custom/Tun")
    check(!grpcCustomPath.getJSONObject("grpcSettings").getBoolean("multiMode"))
    check(grpcCustomPath.getJSONObject("tlsSettings").getJSONArray("alpn").toString() == "[\"h2\"]")
    println("Xray RAW/TLS/REALITY, WebSocket/gRPC TLS, transport fields, ALPN, TUN and no-direct-fallback checks passed")
}
