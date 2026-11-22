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

fun main() {
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
    fails("SUBSCRIPTION_UNSUPPORTED") { SubscriptionFeed.parse("$LINK\nss://secret".toByteArray()) }
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
