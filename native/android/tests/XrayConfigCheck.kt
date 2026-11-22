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
    println("Xray generated TLS/REALITY config, identity, TUN ownership, strict TLS and no-direct-fallback checks passed")
}
