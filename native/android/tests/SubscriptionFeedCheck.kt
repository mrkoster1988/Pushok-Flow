package shop.pushok.flow

import java.net.InetAddress
import java.util.Base64

private const val LINK = "vless://00000000-0000-4000-8000-000000000001@example.invalid:443?security=tls&type=tcp"

private fun fails(code: String, block: () -> Any?) {
    try { block(); error("Expected $code") }
    catch (failure: SubscriptionFailure) {
        check(failure.code == code) { "Unexpected public code: ${failure.code}" }
        check(!failure.toString().contains("vless://") && !failure.toString().contains("private-token"))
        check(failure.message == null)
    }
}

private fun equivalentLinksAndEffectiveSettings() {
    val plain = "vless://01234567-89ab-4cde-8f01-23456789abcd@edge.example.invalid:443?security=tls&type=tcp"
    val aliases = listOf(
        plain + "#Changed-label",
        plain.replace("security=tls&type=tcp", "type=tcp&security=tls"),
        plain.replace("vless://01234567-89ab-4cde-8f01-23456789abcd@edge.example.invalid:443",
            "VLESS://01234567-89AB-4CDE-8F01-23456789ABCD@EDGE.EXAMPLE.INVALID:00443"),
        plain.replace("type=tcp", "type=raw"),
        plain.replace("&type=tcp", ""),
        plain + "&encryption=none&allowInsecure=0&fp=chrome&sni=EDGE.EXAMPLE.INVALID&headerType=none&flow=&alpn=",
        plain.replace("security=tls", "security=%74ls"),
    )
    val identity = SubscriptionFeed.identity(plain)
    check(identity.toString() == "SubscriptionFeed.Identity(<redacted>)")
    for (alias in aliases) {
        check(SubscriptionFeed.identity(alias) == identity)
        check(SubscriptionFeed.identity(alias).hashCode() == identity.hashCode())
        fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse((plain + "\n" + alias).toByteArray()) }
        check(SubscriptionFeed.parse(alias.toByteArray()).entries.single().config == alias)
    }
    for (changed in listOf(
        plain.replace("23456789abcd", "23456789abce"),
        plain.replace("edge.example.invalid", "other.example.invalid"),
        plain.replace(":443?", ":444?"),
        plain + "&sni=other.example.invalid",
        plain + "&fp=firefox",
        plain + "&flow=xtls-rprx-vision",
        plain + "&alpn=h2",
        plain.replace("type=tcp", "type=ws"),
        plain.replace("type=tcp", "type=grpc&serviceName=Flow"),
    )) {
        check(SubscriptionFeed.identity(changed) != identity)
        check(SubscriptionFeed.parse((plain + "\n" + changed).toByteArray()).entries.size == 2)
    }
    val ordered = plain + "&alpn=h2%2Chttp%2F1.1"
    check(SubscriptionFeed.identity(ordered) !=
        SubscriptionFeed.identity(plain + "&alpn=http%2F1.1%2Ch2"))

    val key = "B".repeat(42) + "A"
    val reality = plain.replace("security=tls", "security=reality") +
        "&fp=chrome&pbk=$key&sid=abcd&spx=%2Fcrawl&flow=xtls-rprx-vision"
    val realityAlias = reality.replace("type=tcp", "type=raw")
        .replace("pbk=$key", "pbk=$key%3D").replace("sid=abcd", "sid=ABCD") + "&support-x25519mlkem768=true"
    check(SubscriptionFeed.identity(reality) == SubscriptionFeed.identity(realityAlias))
    fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse((reality + "\n" + realityAlias).toByteArray()) }
    check(SubscriptionFeed.identity(reality) != identity)
    for (changed in listOf(
        reality.replace(key, "C".repeat(42) + "A"),
        reality.replace("sid=abcd", "sid=abce"),
        reality.replace("spx=%2Fcrawl", "spx=%2FCrawl"),
    )) check(SubscriptionFeed.identity(reality) != SubscriptionFeed.identity(changed))
    val defaultReality = reality.substringBefore("&sid=")
    check(SubscriptionFeed.identity(defaultReality) == SubscriptionFeed.identity(defaultReality + "&sid=&spx="))
    check(!SubscriptionFeed.identity(reality).toString().contains(key))

    val ws = plain.replace("type=tcp", "type=ws&path=%2Fsocket%3Ftoken%3DPrivate&host=front.example.invalid:443")
    val wsAlias = ws.replace("host=front.example.invalid", "host=FRONT.EXAMPLE.INVALID")
        .replace("path=%2Fsocket", "path=%2fsocket")
    check(SubscriptionFeed.identity(ws) == SubscriptionFeed.identity(wsAlias))
    fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse((ws + "\n" + wsAlias).toByteArray()) }
    for (changed in listOf(ws.replace("socket", "Socket"), ws.replace("token%3DPrivate", "token%3Dprivate"),
        ws.replace("front.example.invalid", "another.example.invalid"), ws.replace("&host=front.example.invalid:443", ""))) {
        check(SubscriptionFeed.identity(ws) != SubscriptionFeed.identity(changed))
    }
    // Encoded path characters survive one import decode; never normalize request bytes again.
    check(SubscriptionFeed.identity(ws.replace("socket", "socket%252Fpart")) !=
        SubscriptionFeed.identity(ws.replace("socket", "socket%2Fpart")))

    val grpc = plain.replace("type=tcp", "type=grpc&serviceName=FlowService&authority=front.example.invalid:443")
    val grpcAlias = grpc.replace("authority=front.example.invalid", "authority=FRONT.EXAMPLE.INVALID") + "&mode=gun"
    check(SubscriptionFeed.identity(grpc) == SubscriptionFeed.identity(grpcAlias))
    fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse((grpc + "\n" + grpcAlias).toByteArray()) }
    for (changed in listOf(grpc.replace("FlowService", "flowService"), grpc + "&mode=multi",
        grpc.replace("front.example.invalid", "another.example.invalid"),
        grpc.replace("&authority=front.example.invalid:443", ""))) {
        check(SubscriptionFeed.identity(grpc) != SubscriptionFeed.identity(changed))
    }
    check(!SubscriptionFeed.identity(ws).toString().contains("Private"))
}

private fun mixedFeedsKeepSupportedProfilesAndReportSkippedEntries() {
    val other = LINK.replace("000000000001", "000000000002") + "#Second"
    val unsupported = listOf("vmess", "trojan", "ss", "ssr", "hysteria", "hysteria2", "hy2", "tuic", "wireguard")
        .map { "$it://synthetic-unsupported-payload" } + listOf(
        LINK.replace("type=tcp", "type=xhttp"),
        LINK.replace("security=tls", "security=none"),
        LINK + "&unknownOption=preserve-it",
    )
    val lines = listOf(unsupported.first(), "$LINK#First") + unsupported.drop(1) + other
    val text = lines.joinToString("\r\n", prefix = "\uFEFF\n", postfix = "\n")
    for (body in listOf(text, Base64.getEncoder().encodeToString(text.toByteArray()),
        Base64.getUrlEncoder().withoutPadding().encodeToString(text.toByteArray()).chunked(40).joinToString("\n"))) {
        val parsed = SubscriptionFeed.parse(body.toByteArray(), "upload=3;download=4;expire=1800000000")
        check(parsed.entries.map { it.config } == listOf("$LINK#First", other))
        check(parsed.entries.map { it.name } == listOf("First", "Second"))
        check(parsed.skippedProfileCount == unsupported.size)
        check(parsed.usedBytes == 7L && parsed.expiresAt == 1_800_000_000_000L)
        check(!parsed.toString().contains("synthetic-unsupported-payload"))
    }
    val uppercase = SubscriptionFeed.parse(("TROJAN://synthetic-unsupported-payload\n$LINK").toByteArray())
    check(uppercase.entries.single().config == LINK && uppercase.skippedProfileCount == 1)
    check(SubscriptionFeed.parse(LINK.toByteArray()).skippedProfileCount == 0)
    for (body in listOf(unsupported.joinToString("\n"),
        Base64.getEncoder().encodeToString(unsupported.joinToString("\n").toByteArray()))) {
        fails("SUBSCRIPTION_UNSUPPORTED") { SubscriptionFeed.parse(body.toByteArray()) }
    }
    // A recognized unsupported protocol is skipped, never repaired, fetched or converted.
    // Unknown schemes, broken VLESS and malformed URI lines still invalidate the whole response.
    for (invalid in listOf("not a connection", "https://example.invalid/not-a-profile", "future://payload",
        "vmess://", "trojan://bad%GG", "ss://payload with spaces", "ss://payload\u0000",
        "vless://broken", LINK.replace("000000000001", "not-a-uuid"), LINK + "&sni=%FF")) {
        for (textValue in listOf("$invalid\n$LINK", "$LINK\n$invalid")) {
            fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(textValue.toByteArray()) }
            fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(Base64.getEncoder().encode(textValue.toByteArray())) }
        }
    }
    for (option in listOf("sni=bad%2Fhost", "alpn=h2,h2", "pbk=invalid", "sid=abc",
        "spx=invalid", "path=not-a-path", "host=bad%2Fhost", "serviceName=", "authority=bad%2Fhost")) {
        for (incompatible in listOf(LINK.replace("type=tcp", "type=xhttp"), LINK + "&unknownOption=1")) {
            val damaged = "$LINK\n$incompatible&$option"
            fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(damaged.toByteArray()) }
            fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(Base64.getEncoder().encode(damaged.toByteArray())) }
        }
    }
    val publicKey = "B".repeat(42) + "A"
    for (damaged in listOf(
        LINK.replace("security=tls", "security=reality") + "&fp=chrome&unknownOption=1",
        LINK.replace("security=tls", "security=reality") + "&pbk=$publicKey&unknownOption=1",
        LINK.replace("type=tcp", "type=grpc") + "&unknownOption=1",
    )) {
        fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(("$LINK\n$damaged").toByteArray()) }
        fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(Base64.getEncoder().encode(("$LINK\n$damaged").toByteArray())) }
    }
    fails("SUBSCRIPTION_INVALID") {
        SubscriptionFeed.parse(("$LINK\nvmess://synthetic\n$LINK#Duplicate").toByteArray())
    }
}

private fun mixedFeedLimitsApplyBeforeFiltering() {
    val supported = (1..ProfileCatalogStore.MAX_PROFILES).map { number ->
        LINK.replace("000000000001", number.toString().padStart(12, '0'))
    }
    val unsupported = "trojan://synthetic-unsupported-payload"
    val atLimit = List(SubscriptionPolicy.MAX_FEED_ENTRIES - supported.size) { unsupported } + supported
    for (body in listOf(atLimit.joinToString("\n").toByteArray(),
        Base64.getEncoder().encode(atLimit.joinToString("\n").toByteArray()))) {
        val parsed = SubscriptionFeed.parse(body)
        check(parsed.entries.map { it.config } == supported)
        check(parsed.skippedProfileCount == SubscriptionPolicy.MAX_FEED_ENTRIES - supported.size)
    }
    val onlyOne = SubscriptionFeed.parse((List(SubscriptionPolicy.MAX_FEED_ENTRIES - 1) { unsupported } + LINK)
        .joinToString("\n\n").toByteArray())
    check(onlyOne.entries.size == 1 && onlyOne.skippedProfileCount == SubscriptionPolicy.MAX_FEED_ENTRIES - 1)
    fails("SUBSCRIPTION_TOO_LARGE") {
        SubscriptionFeed.parse((List(SubscriptionPolicy.MAX_FEED_ENTRIES) { unsupported } + LINK).joinToString("\n").toByteArray())
    }
    fails("SUBSCRIPTION_TOO_LARGE") {
        SubscriptionFeed.parse(Base64.getEncoder().encode(
            List(SubscriptionPolicy.MAX_FEED_ENTRIES + 1) { unsupported }.joinToString("\n").toByteArray()))
    }
    fails("SUBSCRIPTION_TOO_LARGE") {
        SubscriptionFeed.parse((listOf(unsupported) + supported + LINK.replace("000000000001", "000000000021"))
            .joinToString("\n").toByteArray())
    }
    fails("SUBSCRIPTION_UNSUPPORTED") {
        SubscriptionFeed.parse(List(SubscriptionPolicy.MAX_FEED_ENTRIES) { unsupported }.joinToString("\n").toByteArray())
    }
}

fun main() {
    equivalentLinksAndEffectiveSettings()
    mixedFeedsKeepSupportedProfilesAndReportSkippedEntries()
    mixedFeedLimitsApplyBeforeFiltering()
    val first = "$LINK#%D0%94%D0%BE%D0%BC%20%F0%9F%90%88"
    val second = LINK.replace("000000000001", "000000000002") + "#Office+backup"
    val text = "$first\r\n\n$second\n"
    val plain = SubscriptionFeed.parse(text.toByteArray(),
        "upload=10; download=20; total=100; expire=1800000000", "base64:0JzQvtGPINC/0L7QtNC/0LjRgdC60LA=")
    check(plain.entries.map { it.name } == listOf("Дом 🐈", "Office+backup"))
    check(plain.entries.map { it.config } == listOf(first, second))
    check(plain.expiresAt == 1_800_000_000_000L && plain.usedBytes == 30L && plain.totalBytes == 100L)
    check(plain.title == "Моя подписка")
    check(!plain.toString().contains(LINK) && !plain.entries.toString().contains(LINK))
    val encoded = Base64.getEncoder().encodeToString(text.toByteArray())
    check(SubscriptionFeed.parse(encoded.toByteArray()).entries.map { it.config } == listOf(first, second))
    check(SubscriptionFeed.parse(encoded.trimEnd('=').chunked(40).joinToString("\n").toByteArray())
        .entries.map { it.config } == listOf(first, second))
    // This is the current Shop-VPN /sub output: Base64 of one VLESS line and an expiry header.
    val shop = SubscriptionFeed.parse(Base64.getEncoder().encode(("$LINK\n").toByteArray()), "expire=1800000000")
    check(shop.entries.single().config == LINK && shop.expiresAt == 1_800_000_000_000L)
    check(shop.usedBytes == null && shop.totalBytes == null && shop.title == null)
    check(SubscriptionFeed.parse(("\uFEFF$LINK").toByteArray()).entries.size == 1)

    for (body in listOf(byteArrayOf(), " \n ".toByteArray(), "Cg==".toByteArray())) {
        fails("SUBSCRIPTION_EMPTY") { SubscriptionFeed.parse(body) }
    }
    for (body in listOf("<html>login</html>", "!!", "A", "A===", "AB==", "AA=A", "dmxlc3M6Ly8=")) {
        fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(body.toByteArray()) }
    }
    fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(byteArrayOf(0xc3.toByte(), 0x28)) }
    fails("SUBSCRIPTION_TOO_LARGE") { SubscriptionFeed.parse(ByteArray(SubscriptionPolicy.MAX_BYTES + 1)) }
    fails("SUBSCRIPTION_TOO_LARGE") { SubscriptionFeed.parse(List(21) { "$LINK#$it" }.joinToString("\n").toByteArray()) }
    fails("SUBSCRIPTION_UNSUPPORTED") { SubscriptionFeed.parse("vmess://secret".toByteArray()) }
    fails("SUBSCRIPTION_UNSUPPORTED") { SubscriptionFeed.parse("{\"outbounds\":[]}".toByteArray()) }
    check(SubscriptionFeed.parse("$LINK\nss://secret".toByteArray()).skippedProfileCount == 1)
    fails("SUBSCRIPTION_UNSUPPORTED") { SubscriptionFeed.parse(LINK.replace("type=tcp", "type=xhttp").toByteArray()) }
    fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse("$LINK\n$LINK#same-server".toByteArray()) }
    fails("SUBSCRIPTION_INVALID") { SubscriptionFeed.parse(LINK.replace("000000000001", "private-token").toByteArray()) }

    // Untrusted optional headers never create a fake expiry/quota or poison otherwise usable settings.
    for (bad in listOf("expire=-1", "expire=abc", "expire=1;expire=2", "upload=1;download=-2")) {
        val parsed = SubscriptionFeed.parse(LINK.toByteArray(), bad)
        check(parsed.expiresAt == null && parsed.usedBytes == null)
    }
    val unlimited = SubscriptionFeed.parse(LINK.toByteArray(), "upload=0;download=0;total=0;expire=0")
    check(unlimited.usedBytes == 0L && unlimited.totalBytes == null && unlimited.expiresAt == null)
    val overflow = SubscriptionFeed.parse(LINK.toByteArray(), "upload=9223372036854775807;download=1;expire=9223372036854775807")
    check(overflow.usedBytes == null && overflow.expiresAt == null)
    check(SubscriptionFeed.parse(LINK.toByteArray(), "expire=253402300800").expiresAt == null)
    check(SubscriptionFeed.parse(LINK.toByteArray(), profileTitle = "a\nsecret").title == null)
    check(SubscriptionFeed.parse(LINK.toByteArray(), profileTitle = "base64:???").title == null)

    check(SubscriptionPolicy.normalizeUrl(" HTTPS://EXAMPLE.COM:443/sub/AbC%2f?token=private-token ") ==
        "https://example.com/sub/AbC%2f?token=private-token")
    check(SubscriptionPolicy.normalizeUrl("https://example.com") == "https://example.com/")
    check(SubscriptionPolicy.host("https://example.com:8443/sub/private-token") == "example.com")
    check(SubscriptionPolicy.normalizeUrl("https://[2606:4700:4700::1111]/sub/a") ==
        "https://[2606:4700:4700::1111]/sub/a")
    for (url in listOf("http://example.com/sub/a", "file:///tmp/a", "https://user:pass@example.com/sub/a",
        "https://example.com/sub/a#token", "https://localhost/a", "https://server.local/a",
        "https://10.1.2.3/a", "https://127.0.0.1/a", "https://172.20.0.1/a", "https://192.168.1.1/a",
        "https://100.64.0.1/a", "https://169.254.169.254/a", "https://0.0.0.0/a", "https://127.1/a",
        "https://2130706433/a", "https://0x7f000001/a", "https://0177.0.0.1/a",
        "https://[::1]/a", "https://[fc00::1]/a", "https://[fe80::1]/a", "https://[::ffff:7f00:1]/a",
        "https://example.com:0/a", "https://example.com:65536/a", "https://example.com/a\r\nx:y",
        "https://example.com/" + "a".repeat(4096))) {
        fails("SUBSCRIPTION_URL_INVALID") { SubscriptionPolicy.normalizeUrl(url) }
    }
    check(SubscriptionPolicy.isPublicAddress(InetAddress.getByName("1.1.1.1")))
    check(!SubscriptionPolicy.isPublicAddress(InetAddress.getByName("127.0.0.1")))
    check(!SubscriptionPolicy.isPublicAddress(InetAddress.getByName("100.64.0.1")))
    check(!SubscriptionPolicy.isPublicAddress(InetAddress.getByName("fc00::1")))
    println("Subscription feed and URL policy checks passed")
}
