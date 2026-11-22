package shop.pushok.flow

import java.util.Base64
import java.net.URLEncoder

// Synthetic client, non-routable example endpoint and made-up keys. Never connect these fixtures.
private const val CLIENT = "11111111-2222-4333-8444-555555555555"
private const val PREFIX = "vless://$CLIENT@server.example.invalid:443?"
private val PUBLIC_KEY = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 1 })
private val REALITY = PREFIX + "encryption=none&type=tcp&security=reality&fp=chrome&" +
    "sni=www.example.invalid&pbk=$PUBLIC_KEY&sid=abcd&spx=%2Fcrawl%3Fa%3Db%2Bc&flow=xtls-rprx-vision"
private const val WS = PREFIX + "security=tls&type=ws"
private const val GRPC = PREFIX + "security=tls&type=grpc&serviceName=FlowService"

private fun queryValue(value: String) = URLEncoder.encode(value, "UTF-8")

private fun rejected(code: String, raw: String) {
    try {
        VlessProfile.parse(raw)
        error("Expected $code")
    } catch (failure: ProfileFormatFailure) {
        check(failure.code == code) { "Expected $code, received ${failure.code}" }
        check(failure.message == null && failure.cause == null)
        check(CLIENT !in failure.toString() && "example.invalid" !in failure.toString())
    }
}

private fun successfulProfiles() {
    val parsed = VlessProfile.parse(REALITY + "#%D0%9C%D0%BE%D0%B9%20%D0%BF%D1%80%D0%BE%D1%84%D0%B8%D0%BB%D1%8C")
    check(parsed.uuid == CLIENT && parsed.host == "server.example.invalid" && parsed.port == 443)
    check(parsed.security == "reality" && parsed.fingerprint == "chrome")
    check(parsed.serverName == "www.example.invalid" && parsed.flow == "xtls-rprx-vision")
    check(parsed.realityPublicKey == PUBLIC_KEY && parsed.realityShortId == "abcd")
    check(parsed.spiderX == "/crawl?a=b+c" && parsed.alpn.isEmpty())
    check(parsed.transport == "raw" && parsed.wsPath == null && parsed.wsHost == null &&
        parsed.grpcServiceName == null && parsed.grpcAuthority == null && !parsed.grpcMultiMode)
    check(parsed.toString() == "VlessProfile.Parsed(<redacted>)")
    check(CLIENT !in parsed.toString() && PUBLIC_KEY !in parsed.toString())
    check(VlessProfile.parse(REALITY.replace("type=tcp", "type=raw")).security == "reality")
    check(VlessProfile.parse(REALITY + "&support-x25519mlkem768=true").security == "reality")
    check(VlessProfile.parse(REALITY.replace("sid=abcd", "sid=")).realityShortId == "")
    check(VlessProfile.parse(REALITY.replace("&sid=abcd", "")).realityShortId == "")
    check(VlessProfile.parse(REALITY.replace("&sni=www.example.invalid", "")).serverName == "server.example.invalid")
    check(VlessProfile.parse(REALITY.replace("spx=%2Fcrawl%3Fa%3Db%2Bc", "spx=%2F%252F")).spiderX == "/%2F")
    // Preserve v0.36 RAW field semantics; only new transport fields use form decoding.
    check(VlessProfile.parse(REALITY.replace("spx=%2Fcrawl%3Fa%3Db%2Bc", "spx=%2Fa+b")).spiderX == "/a+b")
    check(VlessProfile.parse(REALITY.replace("sid=abcd", "sid=ABCDEF")).realityShortId == "abcdef")
    check(VlessProfile.parse(REALITY.replace("pbk=$PUBLIC_KEY", "pbk=$PUBLIC_KEY%3D")).realityPublicKey == PUBLIC_KEY)
    check(VlessProfile.parse("\uFEFF \n" + REALITY + "\r\n").security == "reality")
    val tls = VlessProfile.parse(PREFIX + "security=tls&alpn=h2%2Chttp%2F1.1&allowInsecure=0&headerType=none")
    check(tls.fingerprint == "chrome" && tls.serverName == tls.host && tls.flow == null)
    check(tls.alpn == listOf("h2", "http/1.1") && tls.realityPublicKey == null)
    check(tls.transport == "raw")
    check(VlessProfile.parse(PREFIX + "security=tls&alpn=").alpn.isEmpty())
    check(VlessProfile.parse(PREFIX + "security=tls&flow=").flow == null)
    check(VlessProfile.parse(PREFIX + "security=tls&allowInsecure=false").security == "tls")
    val unicode = VlessProfile.parse("vless://$CLIENT@пример.рф:8443?security=tls&sni=xn--e1afmkfd.xn--p1ai")
    check(unicode.host == "xn--e1afmkfd.xn--p1ai" && unicode.port == 8443)
    for (address in listOf("2001:db8::1", "::1", "::", "1:2:3:4:5:6:7:8", "::ffff:192.0.2.1")) {
        val ipv6 = VlessProfile.parse("vless://$CLIENT@[$address]:443?security=tls")
        check(ipv6.host == address && ipv6.serverName == address)
    }
    check(VlessProfile.parse("vless://$CLIENT@192.0.2.1:65535?security=tls").port == 65535)
    check(VlessProfile.parse("vless://$CLIENT@server.example.invalid.:1?security=tls").port == 1)
}

private fun malformedAndUnsupported() {
    for (bad in listOf("vless://", PREFIX + "security=tls&sni=",
        PREFIX.replace(":443", ":0") + "security=tls", PREFIX.replace(":443", ":65536") + "security=tls",
        PREFIX.replace(":443", ":-1") + "security=tls", PREFIX.replace(":443", ":443.0") + "security=tls",
        PREFIX.replace(":443", "") + "security=tls", PREFIX.replace(CLIENT, "not-a-uuid") + "security=tls",
        PREFIX.replace(CLIENT, "$CLIENT:password") + "security=tls",
        PREFIX.replace("@", "@another@") + "security=tls",
        PREFIX.replace(":443?", ":443/path?") + "security=tls",
        PREFIX + "security=tls&security=reality", PREFIX + "security=tls&%73ecurity=tls",
        PREFIX + "security=tls&&fp=chrome", PREFIX + "security=tls&fp", PREFIX + "security=tls&=chrome",
        PREFIX + "security=tls&fp=%GG", PREFIX + "security=tls&sni=%FF",
        PREFIX + "security=tls&sni=example%00.invalid", PREFIX + "security=tls&sni=example%0A.invalid",
        PREFIX + "security=tls&sni=example%252einvalid", PREFIX + "security=tls&sni=host%40other.invalid",
        PREFIX + "security=tls&alpn=h2,h2",
        PREFIX + "security=tls&alpn=h2,%20http/1.1", PREFIX + "security=tls#%FF",
        PREFIX + "security=tls#%0Ahidden")) {
        rejected("INVALID_VLESS_CONFIG", bad)
    }
    rejected("PROFILE_IMPORT_INVALID", "")
    rejected("PROFILE_IMPORT_INVALID", REALITY + "\uD800")
    rejected("PROFILE_IMPORT_INVALID", REALITY + "\u0000")
    rejected("UNSUPPORTED_PROFILE_OPTION", PREFIX + "security=tls&fp=")
    for (bad in listOf("vless://$CLIENT@[2001:db8:::1]:443?security=tls",
        "vless://$CLIENT@[2001:db8::1%25wlan0]:443?security=tls",
        "vless://$CLIENT@2001:db8::1:443?security=tls",
        "vless://$CLIENT@010.0.0.1:443?security=tls",
        "vless://$CLIENT@999.0.0.1:443?security=tls",
        "vless://$CLIENT@127.1:443?security=tls",
        "vless://$CLIENT@-bad.example:443?security=tls",
        "vless://$CLIENT@bad..example:443?security=tls",
        "vless://$CLIENT@bad_name.example:443?security=tls")) rejected("INVALID_VLESS_CONFIG", bad)
    for (type in listOf("xhttp", "kcp", "httpupgrade", "", "TCP")) {
        rejected("UNSUPPORTED_TRANSPORT", PREFIX + "security=tls&type=$type")
    }
    rejected("UNSUPPORTED_TRANSPORT", PREFIX + "security=tls&headerType=http")
    for (security in listOf("", "none", "xtls", "TLS")) {
        rejected("UNSUPPORTED_SECURITY", PREFIX + "security=$security")
    }
    rejected("UNSUPPORTED_SECURITY", PREFIX + "encryption=none")
    for (encryption in listOf("", "mlkem768x25519plus.1.600s.synthetic")) {
        rejected("UNSUPPORTED_SECURITY", PREFIX + "security=tls&encryption=$encryption")
    }
    for (insecure in listOf("1", "true", "", "False")) {
        rejected("UNSUPPORTED_SECURITY", PREFIX + "security=tls&allowInsecure=$insecure")
    }
    for (option in listOf("path=%2F", "host=example.invalid", "ech=", "pqv=", "foo=bar",
        "socksPort=1080", "flow=xtls-rprx-vision-udp443", "fp=unsafe", "fp=chr+ome",
        "Security=tls", "support-x25519mlkem768=true", "pbk=$PUBLIC_KEY", "sid=", "spx=")) {
        rejected("UNSUPPORTED_PROFILE_OPTION", PREFIX + "security=tls&$option")
    }
    for (scheme in listOf("vmess", "trojan", "ss", "https", "file", "content")) {
        rejected("UNSUPPORTED_PROFILE", REALITY.replaceFirst("vless", scheme))
    }
}

private fun websocketProfiles() {
    for (suffix in listOf("", "&path=&host=", "&path=%2F&host=&alpn=")) {
        val parsed = VlessProfile.parse(WS + suffix)
        check(parsed.transport == "ws" && parsed.wsPath == "/" && parsed.wsHost == null)
        check(parsed.grpcServiceName == null && parsed.grpcAuthority == null && !parsed.grpcMultiMode)
        check(parsed.security == "tls" && parsed.flow == null)
    }
    val encoded = VlessProfile.parse(WS + "&path=%2Fflow%252Fsocket%3Ftoken%3Da%2Bb")
    check(encoded.wsPath == "/flow%2Fsocket?token=a+b")
    check(encoded.toString() == "VlessProfile.Parsed(<redacted>)")
    check("token" !in encoded.toString())
    for (path in listOf("/flow?x=1&y=2", "/flow?x=a%2Fb", "/a+b", "/a%2Bb", "/%E2%98%83")) {
        check(VlessProfile.parse(WS + "&path=" + queryValue(path)).wsPath == path)
    }
    // Both URLSearchParams and encodeURIComponent exports must retain a literal plus.
    check(VlessProfile.parse(WS + "&path=%2Fa%2Bb").wsPath == "/a+b")
    rejected("INVALID_VLESS_CONFIG", WS + "&path=%2Fa+b")
    val hosts = mapOf("CDN.example.invalid:8443" to "cdn.example.invalid:8443",
        "пример.рф" to "xn--e1afmkfd.xn--p1ai", "[2001:DB8::1]:443" to "[2001:db8::1]:443",
        "192.0.2.1" to "192.0.2.1")
    for ((given, expected) in hosts) {
        check(VlessProfile.parse(WS + "&host=" + queryValue(given)).wsHost == expected)
        check(VlessProfile.parse(GRPC + "&authority=" + queryValue(given)).grpcAuthority == expected)
    }
    for (path in listOf("relative", "https://example.invalid/", "/flow#fragment", "/flow\\socket",
        "/space path", "/a\r\nInjected:1", "/bad%", "/bad%GG", "/" + "a".repeat(4096))) {
        rejected("INVALID_VLESS_CONFIG", WS + "&path=" + queryValue(path))
    }
    check(VlessProfile.parse(WS + "&path=" + queryValue("/" + "a".repeat(4095))).wsPath?.length == 4096)
    for (host in listOf("https://example.invalid", "a.invalid/path", "a.invalid?x=1",
        "a.invalid#fragment", "user@a.invalid", "a.invalid,b.invalid", "a.invalid\r\nCookie:secret",
        "a.invalid:0", "a.invalid:65536", "a.invalid:", "a.invalid:-1", "a.invalid:1:2",
        "2001:db8::1", "[2001:db8::1]extra", "[2001:db8::1%wlan0]", "bad_name.invalid")) {
        rejected("INVALID_VLESS_CONFIG", WS + "&host=" + queryValue(host))
        rejected("INVALID_VLESS_CONFIG", GRPC + "&authority=" + queryValue(host))
    }
    for (size in listOf(0, 2560, 8192)) {
        val path = "/flow?token=a%2Bb&ed=$size"
        check(VlessProfile.parse(WS + "&path=" + queryValue(path)).wsPath == path)
    }
    check(VlessProfile.parse(WS + "&path=%2Fflow%3F%2565d%3D2560").wsPath == "/flow?%65d=2560")
    for (path in listOf("/flow?ed=", "/flow?ed", "/flow?ed=-1", "/flow?ed=8193",
        "/flow?ed=999999999999999999", "/flow?ed=1&ed=2", "/flow?ed=1&%65d=2",
        "/flow?ed=+1", "/flow?ed=1;token=x")) {
        rejected("INVALID_VLESS_CONFIG", WS + "&path=" + queryValue(path))
    }
}

private fun grpcProfiles() {
    for (suffix in listOf("", "&mode=gun", "&authority=&alpn=")) {
        val parsed = VlessProfile.parse(GRPC + suffix)
        check(parsed.transport == "grpc" && parsed.grpcServiceName == "FlowService")
        check(parsed.grpcAuthority == null && !parsed.grpcMultiMode)
        check(parsed.wsPath == null && parsed.wsHost == null && parsed.flow == null)
    }
    check(VlessProfile.parse(GRPC + "&mode=multi").grpcMultiMode)
    for (name in listOf("flow+service", "flow service", "служба", "flow%2Fservice",
        "/custom/Tun", "/custom/Tun|TunMulti")) {
        val parsed = VlessProfile.parse(PREFIX + "security=tls&type=grpc&serviceName=" + queryValue(name))
        check(parsed.grpcServiceName == name)
        check(parsed.toString() == "VlessProfile.Parsed(<redacted>)")
    }
    check(VlessProfile.parse(GRPC.replace("FlowService", "flow+service")).grpcServiceName == "flow service")
    check(VlessProfile.parse(GRPC.replace("FlowService", "flow%20service")).grpcServiceName == "flow service")
    check(VlessProfile.parse(GRPC.replace("FlowService", "flow%2Bservice")).grpcServiceName == "flow+service")
    check(VlessProfile.parse(GRPC.replace("FlowService", "flow%252Fservice")).grpcServiceName == "flow%2Fservice")
    for (mode in listOf("", "guna", "Gun", "true", "multi%20")) {
        rejected("UNSUPPORTED_PROFILE_OPTION", GRPC + "&mode=$mode")
    }
    rejected("INVALID_VLESS_CONFIG", PREFIX + "security=tls&type=grpc")
    for (name in listOf("", "/", "/Tun", "/custom/", "/custom/Tun|", "/custom/|TunMulti",
        "/custom/Tun|TunMulti|ignored", "flow\r\nInjected:1", "flow\u0000service", "a".repeat(1025))) {
        rejected("INVALID_VLESS_CONFIG", GRPC.replace("FlowService", queryValue(name)))
    }
    check(VlessProfile.parse(GRPC.replace("FlowService", "a".repeat(1024))).grpcServiceName?.length == 1024)
}

private fun transportCompatibility() {
    for ((prefix, accepted) in listOf(WS to listOf("", "http/1.1", "h2,http/1.1"),
        GRPC to listOf("", "h2", "h2,http/1.1"))) {
        for (alpn in accepted) {
            val parsed = VlessProfile.parse(prefix + "&alpn=" + queryValue(alpn))
            check(parsed.alpn == if (alpn.isEmpty()) emptyList<String>() else alpn.split(','))
        }
    }
    for (alpn in listOf("h2", "http/1.1,h2", "h3", "h2,http/1.1,h3")) {
        rejected("UNSUPPORTED_PROFILE_OPTION", WS + "&alpn=" + queryValue(alpn))
    }
    for (alpn in listOf("http/1.1", "http/1.1,h2", "h3", "h2,h3")) {
        rejected("UNSUPPORTED_PROFILE_OPTION", GRPC + "&alpn=" + queryValue(alpn))
    }
    for (prefix in listOf(WS, GRPC)) {
        rejected("UNSUPPORTED_SECURITY", prefix.replace("security=tls", "security=reality"))
        rejected("UNSUPPORTED_PROFILE_OPTION", prefix + "&flow=xtls-rprx-vision")
        rejected("UNSUPPORTED_PROFILE_OPTION", prefix + "&headerType=none")
        rejected("UNSUPPORTED_PROFILE_OPTION", prefix + "&extra=")
        rejected("UNSUPPORTED_PROFILE_OPTION", prefix + "&pbk=$PUBLIC_KEY")
        rejected("UNSUPPORTED_SECURITY", prefix + "&allowInsecure=1")
        rejected("INVALID_VLESS_CONFIG", prefix + "&alpn=h2,h2")
    }
    for (field in listOf("mode=gun", "serviceName=FlowService", "authority=example.invalid")) {
        rejected("UNSUPPORTED_PROFILE_OPTION", WS + "&$field")
    }
    for (field in listOf("path=%2F", "host=example.invalid")) {
        rejected("UNSUPPORTED_PROFILE_OPTION", GRPC + "&$field")
    }
    rejected("INVALID_VLESS_CONFIG", WS + "&path=%2F&%70ath=%2Fother")
    rejected("INVALID_VLESS_CONFIG", GRPC + "&%73erviceName=OtherService")
    rejected("INVALID_VLESS_CONFIG", WS + "&path=%FF")
    rejected("INVALID_VLESS_CONFIG", GRPC.replace("FlowService", "%C0%AF"))
}

private fun realityValidation() {
    for (bad in listOf(REALITY.replace("&fp=chrome", ""), REALITY.replace("pbk=$PUBLIC_KEY", "pbk="),
        REALITY.replace("&pbk=$PUBLIC_KEY", ""), REALITY.replace("pbk=$PUBLIC_KEY", "pbk=garbage"),
        REALITY.replace("pbk=$PUBLIC_KEY", "pbk=" + "A".repeat(43)),
        REALITY.replace("pbk=$PUBLIC_KEY", "pbk=" + PUBLIC_KEY.dropLast(1) + "F"),
        REALITY.replace("sid=abcd", "sid=abc"), REALITY.replace("sid=abcd", "sid=gg"),
        REALITY.replace("sid=abcd", "sid=0123456789abcdef00"),
        REALITY.replace("spx=%2Fcrawl%3Fa%3Db%2Bc", "spx=https%3A%2F%2Fexample.invalid"),
        REALITY.replace("spx=%2Fcrawl%3Fa%3Db%2Bc", "spx=%2F%23bad"))) {
        rejected("INVALID_VLESS_CONFIG", bad)
    }
    for (option in listOf("alpn=h2", "support-x25519mlkem768=false", "pqv=synthetic")) {
        rejected("UNSUPPORTED_PROFILE_OPTION", REALITY + "&$option")
    }
    rejected("UNSUPPORTED_PROFILE_OPTION", REALITY.replace("fp=chrome", "fp=randomized"))
    for (fp in listOf("chrome", "firefox", "safari")) {
        check(VlessProfile.parse(REALITY.replace("fp=chrome", "fp=$fp")).fingerprint == fp)
    }
}

private fun formatAndBounds() {
    val wg = "[Interface]\nPrivateKey = synthetic\n[Peer]\nPublicKey = synthetic\n"
    check(ConnectionProfile.kind(wg) == ConnectionProfile.Kind.WIREGUARD)
    check(ConnectionProfile.validateShape(wg) == ConnectionProfile.Kind.WIREGUARD)
    check(ConnectionProfile.validateShape(REALITY) == ConnectionProfile.Kind.VLESS)
    check(ConnectionProfile.validateShape(WS) == ConnectionProfile.Kind.VLESS)
    check(ConnectionProfile.validateShape(GRPC) == ConnectionProfile.Kind.VLESS)
    check(ConnectionProfile.kind("vless://incomplete") == ConnectionProfile.Kind.VLESS)
    try { ConnectionProfile.validateShape("[Interface]\nPrivateKey=synthetic")
        error("Missing peer accepted")
    } catch (error: ProfileFormatFailure) { check(error.code == "PROFILE_IMPORT_INVALID") }
    try { ConnectionProfile.kind("https://example.invalid/subscription-secret")
        error("Subscription accepted")
    } catch (error: ProfileFormatFailure) { check(error.code == "UNSUPPORTED_PROFILE") }
    val maximum = PREFIX + "security=tls#" + "a".repeat(ProfileImportReader.MAX_BYTES - PREFIX.length - 13)
    check(maximum.length == ProfileImportReader.MAX_BYTES)
    check(VlessProfile.parse(maximum).security == "tls")
    rejected("PROFILE_IMPORT_TOO_LARGE", maximum + "a")
    rejected("PROFILE_IMPORT_TOO_LARGE", PREFIX + "security=tls#" + "Ж".repeat(ProfileImportReader.MAX_BYTES / 2))
    check(ProfileFormatFailure("secret-value").code == "PROFILE_IMPORT_INVALID")
}

fun main() {
    successfulProfiles()
    malformedAndUnsupported()
    realityValidation()
    websocketProfiles()
    grpcProfiles()
    transportCompatibility()
    formatAndBounds()
    println("VLESS executable checks passed (RAW/TCP, WebSocket, gRPC, strict URI, TLS/REALITY, bounds, redaction)")
}
