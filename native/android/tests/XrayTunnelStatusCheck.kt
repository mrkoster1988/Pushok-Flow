package shop.pushok.flow

private fun wire(state: String, connected: Boolean, owned: Boolean): Map<String, Any?> = mapOf(
    "connected" to connected, "ownsTunnel" to owned, "state" to state,
)

private fun rejects(value: Map<*, *>) {
    try {
        XrayTunnelStatus.fromWire(value)
        error("Malformed status was accepted")
    } catch (error: XrayTunnelFailure) {
        check(error.code == "XRAY_STATE_UNAVAILABLE")
        check(error.message == "XRAY_STATE_UNAVAILABLE")
    }
}

fun main() {
    val up = XrayTunnelStatus.fromWire(wire("connected", true, true))
    check(up.known && up.connected && up.ownsTunnel)
    val down = XrayTunnelStatus.fromWire(wire("disconnected", false, false))
    check(down.known && !down.connected && !down.ownsTunnel)
    for (state in listOf("waiting_network", "reconnecting")) {
        val recovery = XrayTunnelStatus.fromWire(wire(state, false, true))
        check(recovery.known && !recovery.connected && recovery.ownsTunnel)
        check(recovery.state.wireName == state)
    }
    for (owned in listOf(false, true)) {
        val unknown = XrayTunnelStatus.fromWire(wire("unknown", false, owned))
        check(!unknown.known && !unknown.connected && unknown.ownsTunnel == owned)
    }

    // Exhaust every contradictory Boolean/phase pair; never turn malformed data into DOWN.
    val validStates = setOf(
        Triple("connected", true, true), Triple("disconnected", false, false),
        Triple("waiting_network", false, true), Triple("reconnecting", false, true),
        Triple("unknown", false, false), Triple("unknown", false, true),
    )
    for (state in XrayTunnelStatus.State.entries) {
        for (connected in listOf(false, true)) for (owned in listOf(false, true)) {
            if (Triple(state.wireName, connected, owned) !in validStates) {
                rejects(wire(state.wireName, connected, owned))
            }
        }
    }
    for (field in listOf("connected", "ownsTunnel", "state")) {
        rejects(wire("connected", true, true) - field)
        for (bad in listOf(null, 1, "PRIVATE_VALUE", emptyList<Any>())) {
            rejects(wire("connected", true, true) + (field to bad))
        }
    }
    val failure = XrayTunnelStatus.fromWire(wire("unknown", false, true) +
        ("lastErrorCode" to "XRAY_STATUS_FAILED"))
    check(failure.lastErrorCode == "XRAY_STATUS_FAILED")
    for (privateError in listOf("vless://PRIVATE_UUID@example.invalid", 3, mapOf("secret" to "PRIVATE"))) {
        check(XrayTunnelStatus.fromWire(wire("connected", true, true) +
            ("lastErrorCode" to privateError)).lastErrorCode == null)
    }
    println("XrayTunnelStatus ownership, recovery and fail-closed parsing checks passed")
}
