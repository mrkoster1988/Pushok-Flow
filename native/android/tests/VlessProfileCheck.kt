package shop.pushok.flow

import java.util.Base64

// Synthetic client, non-routable example endpoint and made-up keys. Never connect these fixtures.
private const val CLIENT = "11111111-2222-4333-8444-555555555555"
private const val PREFIX = "vless://$CLIENT@server.example.invalid:443?"
private val PUBLIC_KEY = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 1 })
private val REALITY = PREFIX + "encryption=none&type=tcp&security=reality&fp=chrome&" +
    "sni=www.example.invalid&pbk=$PUBLIC_KEY&sid=abcd&spx=%2Fcrawl%3Fa%3Db%2Bc&flow=xtls-rprx-vision"

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
    check(parsed.toString() == "VlessProfile.Parsed(<redacted>)")
    check(CLIENT !in parsed.toString() && PUBLIC_KEY !in parsed.toString())
    check(VlessProfile.parse(REALITY.replace("type=tcp", "type=raw")).security == "reality")
    check(VlessProfile.parse(REALITY + "&support-x25519mlkem768=true").security == "reality")
    check(VlessProfile.parse(REALITY.replace("sid=abcd", "sid=")).realityShortId == "")
    check(VlessProfile.parse(REALITY.replace("&sid=abcd", "")).realityShortId == "")
    check(VlessProfile.parse(REALITY.replace("&sni=www.example.invalid", "")).serverName == "server.example.invalid")
    check(VlessProfile.parse(REALITY.replace("spx=%2Fcrawl%3Fa%3Db%2Bc", "spx=%2F%252F")).spiderX == "/%2F")
    check(VlessProfile.parse(REALITY.replace("sid=abcd", "sid=ABCDEF")).realityShortId == "abcdef")
    check(VlessProfile.parse(REALITY.replace("pbk=$PUBLIC_KEY", "pbk=$PUBLIC_KEY%3D")).realityPublicKey == PUBLIC_KEY)
    check(VlessProfile.parse("\uFEFF \n" + REALITY + "\r\n").security == "reality")
    val tls = VlessProfile.parse(PREFIX + "security=tls&alpn=h2%2Chttp%2F1.1&allowInsecure=0&headerType=none")
    check(tls.fingerprint == "chrome" && tls.serverName == tls.host && tls.flow == null)
    check(tls.alpn == listOf("h2", "http/1.1") && tls.realityPublicKey == null)
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
        PREFIX + "security=tls&alpn=", PREFIX + "security=tls&alpn=h2,h2",
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
    for (type in listOf("ws", "xhttp", "grpc", "kcp", "httpupgrade", "", "TCP")) {
        rejected("UNSUPPORTED_TRANSPORT", PREFIX + "security=tls&type=$type")
    }
    rejected("UNSUPPORTED_TRANSPORT", PREFIX + "security=tls&headerType=http")
    rejected("UNSUPPORTED_TRANSPORT", PREFIX + "security=tls&type=ws&path=%2F")
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
    formatAndBounds()
    println("VLESS executable checks passed (strict URI, TLS/REALITY, unsupported options, bounds, redaction)")
}
