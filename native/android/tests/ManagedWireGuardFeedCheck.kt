package shop.pushok.flow

import java.util.Base64

// Synthetic keys only. The actual pinned WireGuard parser/crypto classes validate them.
private val PRIVATE_KEY = Base64.getEncoder().encodeToString(ByteArray(32) { 1 })
private const val PEER_KEY = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="
private const val OTHER_KEY = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM="
private const val PROVIDER_ID = "synthetic-device-secret-id"

private fun config(port: Int = 51820) = """
    [Interface]
    PrivateKey = $PRIVATE_KEY
    Address = 10.77.0.2/32, fd00:77::2/128
    DNS = 1.1.1.1, 2606:4700:4700::1111
    [Peer]
    PublicKey = $PEER_KEY
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = 203.0.113.10:$port
    PersistentKeepalive = 25
""".trimIndent()

private fun quote(value: String): String = buildString {
    append('"')
    for (char in value) when (char) {
        '"' -> append("\\\"")
        '\\' -> append("\\\\")
        '\n' -> append("\\n")
        '\r' -> append("\\r")
        '\t' -> append("\\t")
        else -> if (char < ' ') append("\\u" + char.code.toString(16).padStart(4, '0')) else append(char)
    }
    append('"')
}

private fun entry(id: String = PROVIDER_ID, name: String = "Дом 🐈", config: String = config()) =
    "{\"id\":${quote(id)},\"name\":${quote(name)},\"protocol\":\"wireguard\",\"config\":${quote(config)}}"

private fun document(state: String = "active", revision: String = "1", expiry: String = "1800000000",
    profiles: String = if (state == "active") "[${entry()}]" else "[]", version: String = "1") =
    "{\"schema\":\"pushok-flow-subscription\",\"version\":$version,\"revision\":$revision," +
        "\"state\":${quote(state)},\"expires_at\":$expiry,\"profiles\":$profiles}"

private fun parse(text: String) = SubscriptionFeed.parse(text.toByteArray(Charsets.UTF_8))

private fun rejects(code: String = "SUBSCRIPTION_INVALID", action: () -> Any?) {
    try { action(); error("Expected bounded managed-feed rejection") }
    catch (failure: SubscriptionFailure) {
        check(failure.code == code) { "Expected $code but got ${failure.code}" }
        check(failure.message == null && failure.cause == null && failure.suppressed.isEmpty())
        check(failure.toString() == "SubscriptionFailure($code)")
    }
}

private fun statesAndBounds() {
    val original = config()
    val active = SubscriptionFeed.parse(document().toByteArray(),
        "expire=1;upload=999;download=999", "provider-secret-title")
    check(active.format == SubscriptionFeed.MANAGED_WIREGUARD_FORMAT && active.state == "active")
    check(active.revision == 1L && active.expiresAt == 1_800_000_000_000L)
    check(active.title == null && active.usedBytes == null && active.totalBytes == null && active.skippedProfileCount == 0)
    check(active.entries.single().providerId == PROVIDER_ID && active.entries.single().config == original)
    check(active.entries.single().name == "Дом 🐈")
    for (state in listOf("expired", "revoked")) {
        val inactive = parse(document(state = state))
        check(inactive.state == state && inactive.entries.isEmpty() && inactive.revision == 1L)
        SubscriptionFeed.validateManaged(inactive)
        rejects { parse(document(state = state, profiles = "[${entry()}]")) }
    }
    for (state in listOf("", "ACTIVE", "pending", "deleted", " active")) rejects {
        parse(document(state = state, profiles = "[]"))
    }
    rejects { parse(document(profiles = "[]")) }
    for (revision in listOf("1", SubscriptionFeed.MAX_REVISION.toString()))
        check(parse(document(revision = revision)).revision == revision.toLong())
    for (revision in listOf("0", "-1", "9007199254740992", "9223372036854775808", "1.0", "1e0", "true", "null", "\"1\""))
        rejects { parse(document(revision = revision)) }
    for (expiry in listOf("1", (SubscriptionPolicy.MAX_TIMESTAMP_MS / 1000).toString()))
        check(parse(document(expiry = expiry)).expiresAt == expiry.toLong() * 1000)
    for (expiry in listOf("0", "-1", "253402300800", "9223372036854775807", "1.5", "1e3", "false", "null", "\"1800000000\""))
        rejects { parse(document(expiry = expiry)) }
    val maximum = (1..ProfileCatalogStore.MAX_PROFILES).map { entry("device_$it", "Server $it", config(51820 + it)) }
    check(parse(document(profiles = maximum.joinToString(",", "[", "]"))).entries.size == ProfileCatalogStore.MAX_PROFILES)
    rejects { parse(document(profiles = (maximum + entry("overflow", config = config(51999))).joinToString(",", "[", "]"))) }
    check(parse("\uFEFF \n" + document() + "\r\n\t").entries.size == 1)
    for (secret in listOf(PRIVATE_KEY, PEER_KEY, PROVIDER_ID, "203.0.113.10", "[Interface]")) {
        check(!(active.toString() + active.entries.toString()).contains(secret))
    }
    rejects("SUBSCRIPTION_TOO_LARGE") { SubscriptionFeed.parse(ByteArray(SubscriptionPolicy.MAX_BYTES + 1)) }
}

private fun exactEnvelopeAndStrictJson() {
    val valid = document()
    for (field in listOf("schema", "version", "revision", "state", "expires_at", "profiles")) {
        val duplicate = valid.replaceFirst("{", "{${quote(field)}:null,")
        rejects { parse(duplicate) }
    }
    rejects { parse(valid.replaceFirst("{", "{\"\\u0072evision\":2,")) }
    val unknown = listOf(
        valid.dropLast(1) + ",\"url\":\"https://example.invalid/private-token\"}",
        valid.replace("\"state\":\"active\",", ""),
        valid.replace("\"schema\":\"pushok-flow-subscription\"", "\"schema\":null"),
        valid.replace("\"profiles\":[", "\"profiles\":{\"unexpected\":[").dropLast(1) + "}}",
        document(profiles = "null"), document(profiles = "{}"), document(profiles = "[null]"),
        valid.replace("\"state\":\"active\"", "\"state\":true"),
    )
    for (text in unknown) rejects { parse(text) }
    for (key in listOf("id", "name", "protocol", "config")) {
        rejects { parse(document(profiles = "[" + entry().replaceFirst("{", "{${quote(key)}:null,") + "]")) }
    }
    rejects { parse(document(profiles = "[" + entry().replaceFirst("{", "{\"\\u0069d\":\"another\",") + "]")) }
    rejects { parse(document(profiles = "[" + entry().dropLast(1) + ",\"private\":\"unexpected\"}]")) }
    rejects { parse(document(profiles = "[" + entry().replace("\"protocol\":\"wireguard\",", "") + "]")) }
    rejects { parse(document(profiles = "[" + entry().replace("\"wireguard\"", "\"vless\"") + "]")) }
    rejects { parse(document(profiles = "[" + entry().replace("\"wireguard\"", "\"WIREGUARD\"") + "]")) }
    for (version in listOf("2", "0", "9007199254740991")) rejects("SUBSCRIPTION_UNSUPPORTED") {
        parse(document(version = version))
    }
    for (version in listOf("\"1\"", "1.0", "1e0", "true", "null")) rejects { parse(document(version = version)) }
    rejects("SUBSCRIPTION_UNSUPPORTED") { parse(valid.replace("pushok-flow-subscription", "other-vendor")) }
    rejects("SUBSCRIPTION_UNSUPPORTED") { parse("{\"outbounds\":[]}") }
    rejects("SUBSCRIPTION_UNSUPPORTED") { parse(Base64.getEncoder().encodeToString(valid.toByteArray())) }
    rejects("SUBSCRIPTION_UNSUPPORTED") { parse(Base64.getUrlEncoder().withoutPadding().encodeToString(valid.toByteArray())) }
    rejects("SUBSCRIPTION_UNSUPPORTED") { parse(config()) }
    for (text in listOf(
        valid + "{}", valid + "null", valid + " trailing-secret", valid + "\u0000", valid + "\u00a0",
        "\u00a0" + valid, valid.dropLast(1), valid.dropLast(1) + ",}",
        valid.replaceFirst("{", "{/*comment*/"), valid.replaceFirst("{", "{//comment\n"),
        valid.replace("\"revision\":1", "\"revision\":01"),
        valid.replace("\"revision\":1", "\"revision\":+1"),
        valid.replace("\"revision\":1", "\"revision\":NaN"),
        valid.replace("\"revision\":1", "\"revision\":1."),
        valid.replace("\"revision\":1", "\"revision\":1e"),
        valid.replace("\"state\":\"active\"", "state:'active'"),
        valid.replace("\"active\"", "\"act\nive\""),
        valid.replace("\"active\"", "\"act\\x69ve\""),
        valid.replace("\"active\"", "\"\\uD800\""),
        valid.replace("\"active\"", "\"\\uDC00\""),
        valid.replace("\"active\"", "\"\\uD800x\""),
        document(profiles = "[${entry()},]"),
        document(profiles = "[".repeat(50) + "0" + "]".repeat(50)),
    )) rejects { parse(text) }
    val escapedName = entry().replace(quote("Дом 🐈"), "\"\\u0414\\u043e\\u043c \\ud83d\\udc08\"")
    check(parse(document(profiles = "[$escapedName]")).entries.single().name == "Дом 🐈")
    rejects { SubscriptionFeed.parse(byteArrayOf('{'.code.toByte(), 0xc3.toByte(), 0x28)) }
}

private fun entriesAndEffectiveDuplicates() {
    for (id in listOf("A", "0", "device_1-2", "A".repeat(64))) {
        check(SubscriptionFeed.validProviderId(id))
        check(parse(document(profiles = "[${entry(id)}]")).entries.single().providerId == id)
    }
    for (id in listOf("", "A".repeat(65), " leading", "trailing ", "device/1", "device+1", "device.1", "Клиент", "a\n")) {
        check(!SubscriptionFeed.validProviderId(id))
        rejects { parse(document(profiles = "[${entry(id)}]")) }
    }
    for (name in listOf("", " ", " Leading", "Trailing ", "x\nsecret", "x\u0000", "🐈".repeat(65)))
        rejects { parse(document(profiles = "[${entry(name = name)}]")) }
    check(parse(document(profiles = "[${entry(name = "🐈".repeat(64))}]")).entries.size == 1)
    rejects { parse(document(profiles = "[${entry()},${entry(config = config(51821))}]")) }
    val original = config()
    val aliases = listOf(original, "# synthetic comment\r\n" + original.replace("\n", "\r\n"),
        original.replace("PrivateKey =", "privatekey=").replace("[Interface]", "[interface]"),
        original.replace("0.0.0.0/0, ::/0", "::/0, 0.0.0.0/0"),
        original.replace("10.77.0.2/32, fd00:77::2/128", "fd00:0077:0:0:0:0:0:2/128, 10.77.0.2/32"),
        original.replace("Endpoint = 203.0.113.10:51820", "Endpoint = 203.0.113.10:051820"))
    for (alias in aliases) rejects {
        parse(document(profiles = "[${entry()},${entry("different-id", "Renamed", alias)}]"))
    }
    // Curve25519 ignores these encoded private-key bits. Both complete configs
    // are valid, but they still identify the same device and cannot be two entries.
    for ((index, bit) in listOf(0 to 1, 31 to 0x80, 31 to 0x40)) {
        val bytes = ByteArray(32) { 1 }
        bytes[index] = (bytes[index].toInt() xor bit).toByte()
        val aliasKey = Base64.getEncoder().encodeToString(bytes)
        val alias = original.replace(PRIVATE_KEY, aliasKey)
        check(parse(document(profiles = "[${entry(config = alias)}]")).entries.single().config == alias)
        rejects { parse(document(profiles = "[${entry()},${entry("other-device", config = alias)}]")) }
    }
    val domain = original.replace("203.0.113.10", "vpn.example.invalid")
    rejects { parse(document(profiles = "[${entry(config = domain)},${entry("other", config = domain.replace("vpn.example.invalid", "VPN.EXAMPLE.INVALID"))}]")) }
    val ipv6 = original.replace("203.0.113.10", "[2001:db8::1]")
    rejects { parse(document(profiles = "[${entry(config = ipv6)},${entry("other", config = ipv6.replace("2001:db8::1", "2001:0db8:0:0:0:0:0:1"))}]")) }
    for (changed in listOf(config(51821), original.replace(PRIVATE_KEY, OTHER_KEY),
        original.replace(PEER_KEY, OTHER_KEY), original.replace("10.77.0.2", "10.77.0.3"),
        original.replace("1.1.1.1", "1.0.0.1"), original.replace("PersistentKeepalive = 25", "PersistentKeepalive = 30"),
        original.replace("AllowedIPs = 0.0.0.0/0, ::/0", "AllowedIPs = 10.0.0.0/8"),
        original.replace("[Peer]", "MTU = 1380\n[Peer]"), original + "\nPresharedKey = $OTHER_KEY")) {
        check(parse(document(profiles = "[${entry()},${entry("other", config = changed)}]")).entries.size == 2)
    }
}

private fun realWireGuardGrammarAndClientRequirements() {
    val original = config()
    val broken = mutableListOf(
        original.replace(PRIVATE_KEY, "secret-invalid-private-key"),
        original.replace(PEER_KEY, "secret-invalid-public-key"),
        original.replace("PrivateKey = $PRIVATE_KEY\n", ""),
        original.replace("PublicKey = $PEER_KEY\n", ""),
        original.replace("10.77.0.2/32", "999.77.0.2/32"),
        original.replace("10.77.0.2/32", "10.77.0.2/33"),
        original.replace("fd00:77::2/128", "fd00:77::2/129"),
        original.replace("0.0.0.0/0", "0.0.0.0/33"),
        original.replace("203.0.113.10:51820", "vpn.example.invalid"),
        original.replace("203.0.113.10:51820", "vpn.example.invalid:65536"),
        original.replace("203.0.113.10:51820", "vpn.example.invalid:0"),
        original.replace("203.0.113.10:51820", "https://vpn.example.invalid:51820/path"),
        original.replace("PersistentKeepalive = 25", "PersistentKeepalive = 65536"),
        original + "\nPresharedKey = invalid-secret",
        original.replace("Address = 10.77.0.2/32, fd00:77::2/128\n", ""),
        original.replace("AllowedIPs = 0.0.0.0/0, ::/0\n", ""),
        original.replace("Endpoint = 203.0.113.10:51820\n", ""),
        original.substringBefore("[Peer]"), original + "\n[Peer]\nPublicKey = $OTHER_KEY",
        original + "\n[Interface]\nAddress = 10.77.0.3/32",
        original.replace("DNS =", "\u0000DNS ="), original.replace("[Peer]", "[Other]"),
        "https://example.invalid/private-token", "vless://unsupported-in-managed-feed", "",
        original + "x".repeat(ProfileCatalogStore.MAX_CONFIG_LENGTH),
    )
    for (option in listOf("PostUp = echo synthetic-secret", "PostDown = echo synthetic-secret",
        "PreUp = echo synthetic-secret", "PreDown = echo synthetic-secret", "Table = 123",
        "SaveConfig = true", "IncludedApplications = example.app", "ExcludedApplications = example.app",
        "ExcludedApplications =")) {
        broken.add(original.replace("[Peer]", "$option\n[Peer]"))
    }
    for ((index, cfg) in broken.withIndex()) {
        try { rejects { parse(document(profiles = "[${entry(config = cfg)}]")) } }
        catch (_: IllegalStateException) { error("WireGuard invalid fixture $index was not rejected safely") }
    }
    // Valid secondary key, numeric IPv6 and DNS hostnames do not require a live server.
    check(parse(document(profiles = "[${entry(config = original + "\nPresharedKey = $OTHER_KEY")}]")).entries.size == 1)
    check(parse(document(profiles = "[${entry(config = original.replace("203.0.113.10", "[2001:db8::1]"))}]")).entries.size == 1)
}

private fun directParsedObjectsAreNotTrusted() {
    fun parsed(entries: List<SubscriptionFeed.Entry> = listOf(SubscriptionFeed.Entry("Device", config(), "device")),
        expiry: Long? = 1_800_000_000_000L, state: String = "active", revision: Long? = 1,
        format: String = SubscriptionFeed.MANAGED_WIREGUARD_FORMAT, skipped: Int = 0, title: String? = null) =
        SubscriptionFeed.Parsed(entries, title, expiry, null, null, skipped, format, state, revision)
    SubscriptionFeed.validateManaged(parsed())
    val invalid = listOf(parsed(format = "vless"), parsed(expiry = null), parsed(expiry = 0),
        parsed(expiry = 1001), parsed(expiry = SubscriptionPolicy.MAX_TIMESTAMP_MS + 1),
        parsed(revision = null), parsed(revision = 0), parsed(revision = SubscriptionFeed.MAX_REVISION + 1),
        parsed(state = "unknown"), parsed(state = "expired"), parsed(entries = emptyList()),
        parsed(skipped = 1), parsed(title = "secret-title"),
        parsed(entries = listOf(SubscriptionFeed.Entry("Device", config()))),
        parsed(entries = listOf(SubscriptionFeed.Entry(" Device", config(), "device"))),
        parsed(entries = listOf(SubscriptionFeed.Entry("Device", "[Interface]\n[Peer]", "device"))),
        parsed(entries = listOf(SubscriptionFeed.Entry("Device", config(), "device"),
            SubscriptionFeed.Entry("Other", config(), "other"))))
    for (value in invalid) rejects { SubscriptionFeed.validateManaged(value) }
    val entries = mutableListOf(SubscriptionFeed.Entry("Device", config(), "device"))
    val snapshot = parsed(entries)
    entries.clear()
    check(snapshot.entries.size == 1)
    try { (snapshot.entries as MutableList).clear(); error("Mutable managed snapshot") }
    catch (_: UnsupportedOperationException) { }
}

fun main() {
    statesAndBounds()
    exactEnvelopeAndStrictJson()
    entriesAndEffectiveDuplicates()
    realWireGuardGrammarAndClientRequirements()
    directParsedObjectsAreNotTrusted()
    println("Managed WireGuard feed strict JSON, upstream parser and redaction checks passed")
}
