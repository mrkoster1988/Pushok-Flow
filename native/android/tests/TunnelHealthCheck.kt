package shop.pushok.flow

private fun statistics(
    peers: List<TunnelHealth.PeerSample>?,
    nowEpochMs: Long = 100000L,
    connected: Boolean = true,
    busy: Boolean = false,
    stateKnown: Boolean = true
): Map<*, *> = TunnelHealth.snapshot(connected, busy, 1000L, 5000L, null,
    stateKnown = stateKnown, peerSamples = peers, nowEpochMs = nowEpochMs)["statistics"] as Map<*, *>

private fun unavailable(stats: Map<*, *>, expected: String = "unavailable") {
    check(stats["status"] == expected)
    check(stats["rxBytes"] == null && stats["txBytes"] == null)
    check(stats["latestHandshakeAgeSeconds"] == null)
    check(stats["handshakeStatus"] == "unknown")
}

fun main() {
    check(TunnelHealth.uptimeSeconds(false, 100L, 9000L) == 0L)
    check(TunnelHealth.uptimeSeconds(true, null, 9000L) == 0L)
    check(TunnelHealth.uptimeSeconds(true, 2000L, 1999L) == 0L)
    check(TunnelHealth.uptimeSeconds(true, 1000L, 8999L) == 7L)
    val status = TunnelHealth.snapshot(true, false, 1000L, 10500L, null)
    check(status["state"] == "connected")
    check(status["uptimeSeconds"] == 9L)
    check(status.keys == setOf("connected", "state", "uptimeSeconds", "lastErrorCode", "statistics"))
    check(TunnelHealth.snapshot(false, true, null, 500L, "WG_CONNECT_FAILED")["state"] == "transitioning")

    // A failed state query preserves the last known boolean but is not fresh evidence.
    val unknown = TunnelHealth.snapshot(true, false, 1000L, 5000L, null,
        stateKnown = false, peerSamples = listOf(TunnelHealth.PeerSample(10L, 20L, 90000L)),
        nowEpochMs = 100000L)
    check(unknown["state"] == "unknown")
    check(unknown["connected"] == true)
    unavailable(unknown["statistics"] as Map<*, *>)

    // Missing/empty native data must be distinguishable from real zero counters.
    unavailable(statistics(null))
    unavailable(statistics(emptyList()))
    val zero = statistics(listOf(TunnelHealth.PeerSample(0L, 0L, 0L)))
    check(zero["status"] == "available")
    check(zero["rxBytes"] == 0L && zero["txBytes"] == 0L)
    check(zero["handshakeStatus"] == "never")
    check(zero["latestHandshakeAgeSeconds"] == null)

    // Sum all counters, but report only the newest handshake age across peers.
    val peers = listOf(TunnelHealth.PeerSample(1200L, 300L, 95001L),
        TunnelHealth.PeerSample(45L, 10L, 50000L), TunnelHealth.PeerSample(0L, 7L, 0L))
    val observed = statistics(peers)
    check(observed["status"] == "available")
    check(observed["rxBytes"] == 1245L && observed["txBytes"] == 317L)
    check(observed["handshakeStatus"] == "observed")
    check(observed["latestHandshakeAgeSeconds"] == 4L)
    check(observed.keys == setOf("status", "rxBytes", "txBytes", "latestHandshakeAgeSeconds", "handshakeStatus"))

    // A recent handshake is not converted to an Internet-reachability verdict.
    check(statistics(listOf(TunnelHealth.PeerSample(0L, 0L, 100000L)))["latestHandshakeAgeSeconds"] == 0L)
    val old = statistics(listOf(TunnelHealth.PeerSample(1L, 2L, 1L)), Long.MAX_VALUE)
    check(old["handshakeStatus"] == "observed")
    check(old["latestHandshakeAgeSeconds"] == (Long.MAX_VALUE - 1L) / 1000L)

    // Neither an invalid peer timestamp nor a changed wall clock fabricates freshness.
    for (invalid in listOf(-1L, Long.MIN_VALUE, 100001L, Long.MAX_VALUE)) {
        val ambiguous = statistics(peers + TunnelHealth.PeerSample(1L, 2L, invalid))
        check(ambiguous["status"] == "available")
        check(ambiguous["rxBytes"] == 1246L && ambiguous["txBytes"] == 319L)
        check(ambiguous["handshakeStatus"] == "unknown")
        check(ambiguous["latestHandshakeAgeSeconds"] == null)
    }
    for (clock in listOf(0L, -1L, Long.MIN_VALUE)) {
        val ambiguous = statistics(peers, clock)
        check(ambiguous["handshakeStatus"] == "unknown")
        check(ambiguous["latestHandshakeAgeSeconds"] == null)
    }

    // Overflow cannot wrap or saturate into an exact-looking number.
    check(statistics(listOf(TunnelHealth.PeerSample(Long.MAX_VALUE, Long.MAX_VALUE, 0L)))["rxBytes"] == Long.MAX_VALUE)
    for (invalid in listOf(
        listOf(TunnelHealth.PeerSample(-1L, 0L, 0L)),
        listOf(TunnelHealth.PeerSample(0L, -1L, 0L)),
        listOf(TunnelHealth.PeerSample(Long.MAX_VALUE, 0L, 0L), TunnelHealth.PeerSample(1L, 0L, 0L)),
        listOf(TunnelHealth.PeerSample(0L, Long.MAX_VALUE, 0L), TunnelHealth.PeerSample(0L, 1L, 0L))
    )) unavailable(statistics(invalid))

    // A disconnect or transition must not display bytes from a previous session.
    unavailable(statistics(peers, connected = false), "inactive")
    unavailable(statistics(peers, busy = true))
    unavailable(statistics(peers, connected = false, busy = true))
    unavailable(statistics(peers, connected = false, stateKnown = false))
    println("TunnelHealth executable checks passed")
}
