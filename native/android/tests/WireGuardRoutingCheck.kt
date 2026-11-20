package shop.pushok.flow

/** Executable integration-free tests against the real Kotlin route transformer. */
fun main() {
    val sample = """[Interface]
PrivateKey = PLACEHOLDER
Address = 10.8.0.2/32

[Peer]
PublicKey = PLACEHOLDER
AllowedIPs = 0.0.0.0/0, ::/0"""
    val output = WireGuardRouting.prepare(sample, setOf("ru.ozon.app", "ru.max.app"))
    check(output.contains("ExcludedApplications = ru.max.app, ru.ozon.app"))
    check(output.indexOf("ExcludedApplications") < output.indexOf("[Peer]"))
    check(output.contains("AllowedIPs = 0.0.0.0/0, ::/0"))
    check(output.contains("PrivateKey = PLACEHOLDER"))
    val replacement = WireGuardRouting.prepare(sample.replace("[Peer]", "ExcludedApplications = old.app\n[Peer]"), setOf("ru.max.app"))
    check(replacement.contains("ExcludedApplications = ru.max.app"))
    check(!replacement.contains("old.app"))
    check(replacement.split("ExcludedApplications").size == 2)
    val cleared = WireGuardRouting.prepare(replacement, emptySet())
    check(!cleared.contains("ExcludedApplications"))
    check(WireGuardRouting.prepare(sample, emptySet()) == sample)
    try {
        WireGuardRouting.prepare(sample, setOf("invalid package name"))
        error("Invalid Android package name accepted")
    } catch (_: IllegalArgumentException) { }
    try {
        WireGuardRouting.prepare("[Peer]\nAllowedIPs=0.0.0.0/0", emptySet())
        error("Missing interface accepted")
    } catch (_: IllegalArgumentException) { }
    try {
        WireGuardRouting.prepare(sample.replace("Address =", "IncludedApplications = x.y\nAddress ="), setOf("a.b"))
        error("Conflicting application rules accepted")
    } catch (_: IllegalArgumentException) { }
    // Reject ambiguous duplicate sections instead of installing contradictory routes.
    try {
        WireGuardRouting.prepare(sample + "\n[Interface]\nAddress = 10.0.0.2/32", setOf("ru.max.app"))
        error("Duplicate Interface accepted")
    } catch (_: IllegalArgumentException) { }
    // An unrelated key with a similar prefix must not be silently erased.
    val customKey = sample.replace("[Peer]", "ExcludedApplicationsExtra = keep\n[Peer]")
    check(WireGuardRouting.prepare(customKey, setOf("ru.max.app")).contains("ExcludedApplicationsExtra = keep"))
    // Existing exclusions must be replaced, not appended, even with mixed case keys.
    val mixedCase = sample.replace("[Peer]", "excludedapplications = old.app\n[Peer]")
    val normalized = WireGuardRouting.prepare(mixedCase, setOf("ru.max.app"))
    check(!normalized.contains("old.app"))
    check(normalized.split("ExcludedApplications").size == 2)
    // Invalid placement must fail before asking the OS to establish a tunnel.
    val peerRule = sample + "\nExcludedApplications = com.example.bank"
    try {
        WireGuardRouting.prepare(peerRule, setOf("com.example.bank"))
        error("ExcludedApplications in Peer accepted")
    } catch (_: IllegalArgumentException) { }
    val peerInclude = sample + "\nIncludedApplications = com.example.app"
    try {
        WireGuardRouting.prepare(peerInclude, emptySet())
        error("IncludedApplications in Peer accepted")
    } catch (_: IllegalArgumentException) { }
    val comment = sample.replace("[Peer]", "# ExcludedApplications = comment.only\n[Peer]")
    check(WireGuardRouting.prepare(comment, emptySet()) == comment)
    val repeated = sample.replace("[Peer]", "ExcludedApplications = first.app\nExcludedApplications = second.app\n[Peer]")
    check(WireGuardRouting.prepare(repeated, setOf("third.app")).split("ExcludedApplications").size == 2)
    try {
        WireGuardRouting.prepare(sample, setOf("bad app"))
        error("Invalid package accepted")
    } catch (_: IllegalArgumentException) { }
    println("Kotlin WireGuardRouting executable checks passed")
}