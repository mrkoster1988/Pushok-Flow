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

    // Config.parse accepts comments after section headers. Preparing an unchanged
    // profile must accept the same headers and retain the original text.
    val interfaceComment = sample.replace("[Interface]", "[Interface] # client")
    check(WireGuardRouting.prepare(interfaceComment, emptySet()) == interfaceComment)
    val peerComment = sample.replace("[Peer]", "[Peer] # server")
    check(WireGuardRouting.prepare(peerComment, setOf("com.example.bank")) ==
        peerComment.replace("[Peer] # server", "ExcludedApplications = com.example.bank\n[Peer] # server"))

    // Insert exclusions before the first commented Peer, never within either
    // peer. Preserve DNS, IPv4/IPv6 routes, key lines, whitespace and comments.
    val commentedProfile = """# [Interface] is only a comment
 [iNtErFaCe] # client settings
PrivateKey = PRIVATE_PLACEHOLDER # keep this comment
Address = 10.8.0.2/32, fd00::2/128
DNS = 1.1.1.1, 2606:4700:4700::1111 # resolver settings
# ExcludedApplications = comment.only

 [pEeR] # first server
PublicKey = FIRST_PUBLIC_PLACEHOLDER
AllowedIPs = 0.0.0.0/0, ::/0 # default routes
Endpoint = first.example:51820

[Peer] # second server
PublicKey = SECOND_PUBLIC_PLACEHOLDER
AllowedIPs = 192.0.2.0/24, 2001:db8::/32 # specific routes
Endpoint = second.example:51820"""
    val expectedCommented = commentedProfile.replace(" [pEeR] # first server",
        "ExcludedApplications = com.example.bank, com.example.chat\n [pEeR] # first server")
    val chosen = setOf("com.example.chat", "com.example.bank")
    check(WireGuardRouting.prepare(commentedProfile, chosen) == expectedCommented)
    check(WireGuardRouting.prepare(commentedProfile, emptySet()) == commentedProfile)
    check(WireGuardRouting.prepare(commentedProfile.replace("\n", "\r\n"), chosen) == expectedCommented)
    check(WireGuardRouting.prepare(commentedProfile.replace("\n", "\r"), chosen) == expectedCommented)

    // A previous inline exclusion is removed as a directive, but standalone
    // comments remain. Clearing the selection leaves all unrelated text intact.
    val previousCommented = commentedProfile.replace("DNS =",
        "  excludedapplications = old.app # obsolete selection\nDNS =")
    check(WireGuardRouting.prepare(previousCommented, chosen) == expectedCommented)
    check(WireGuardRouting.prepare(previousCommented, emptySet()) == commentedProfile)

    // Comments cannot bypass existing restrictions on duplicate Interface
    // sections or application directives outside Interface.
    val invalidCommented = listOf(
        commentedProfile + "\n[INTERFACE] # duplicate\nAddress = 10.9.0.2/32",
        commentedProfile + "\nExcludedApplications = com.example.bank # misplaced",
        commentedProfile.replace("DNS =", "IncludedApplications = com.example.bank # unsupported\nDNS ="),
    )
    for (invalid in invalidCommented) {
        try {
            WireGuardRouting.prepare(invalid, chosen)
            error("Invalid commented application routing accepted")
        } catch (_: IllegalArgumentException) { }
    }
    println("Kotlin WireGuardRouting executable checks passed")
}
