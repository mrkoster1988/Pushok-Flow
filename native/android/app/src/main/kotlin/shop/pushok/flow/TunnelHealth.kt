package shop.pushok.flow

/** Privacy-preserving tunnel status: never include endpoints or keys. */
object TunnelHealth {
    /** Numeric values only: peer identities never enter the diagnostic model. */
    data class PeerSample(
        val rxBytes: Long,
        val txBytes: Long,
        val latestHandshakeEpochMillis: Long
    )

    fun uptimeSeconds(connected: Boolean, startedAtMs: Long?, nowMs: Long): Long {
        if (!connected || startedAtMs == null || nowMs < startedAtMs) return 0L
        return (nowMs - startedAtMs) / 1000L
    }

    fun snapshot(connected: Boolean, busy: Boolean, startedAtMs: Long?, nowMs: Long,
                 lastErrorCode: String?, stateKnown: Boolean = true,
                 peerSamples: List<PeerSample>? = null,
                 nowEpochMs: Long = 0L): Map<String, Any?> = mapOf(
        "connected" to connected,
        "state" to when {
            busy -> "transitioning"
            !stateKnown -> "unknown"
            connected -> "connected"
            else -> "disconnected"
        },
        "uptimeSeconds" to uptimeSeconds(connected, startedAtMs, nowMs),
        "lastErrorCode" to lastErrorCode,
        "statistics" to statistics(connected, busy, stateKnown, peerSamples, nowEpochMs)
    )

    private fun unavailableStatistics(status: String): Map<String, Any?> = mapOf(
        "status" to status,
        "rxBytes" to null,
        "txBytes" to null,
        "latestHandshakeAgeSeconds" to null,
        "handshakeStatus" to "unknown"
    )

    private fun statistics(connected: Boolean, busy: Boolean, stateKnown: Boolean,
                           peers: List<PeerSample>?, nowEpochMs: Long): Map<String, Any?> {
        if (busy || !stateKnown) return unavailableStatistics("unavailable")
        if (!connected) return unavailableStatistics("inactive")
        // GoBackend also returns an empty Statistics object when a native read
        // is unavailable. It does not establish a valid zero-traffic sample.
        if (peers.isNullOrEmpty()) return unavailableStatistics("unavailable")

        var rx = 0L
        var tx = 0L
        for (peer in peers) {
            if (peer.rxBytes < 0L || peer.txBytes < 0L ||
                peer.rxBytes > Long.MAX_VALUE - rx || peer.txBytes > Long.MAX_VALUE - tx) {
                return unavailableStatistics("unavailable")
            }
            rx += peer.rxBytes
            tx += peer.txBytes
        }

        // The newest handshake among all peers is an observation, not proof
        // that every route, DNS query or Internet destination is reachable.
        val latestHandshake = peers.maxOf { it.latestHandshakeEpochMillis }
        val invalidHandshake = peers.any {
            it.latestHandshakeEpochMillis < 0L ||
                (it.latestHandshakeEpochMillis > 0L &&
                    (nowEpochMs <= 0L || it.latestHandshakeEpochMillis > nowEpochMs))
        }
        val handshakeStatus = when {
            invalidHandshake -> "unknown"
            latestHandshake == 0L -> "never"
            else -> "observed"
        }
        val handshakeAge = if (handshakeStatus == "observed") {
            (nowEpochMs - latestHandshake) / 1000L
        } else null
        return mapOf(
            "status" to "available",
            "rxBytes" to rx,
            "txBytes" to tx,
            "latestHandshakeAgeSeconds" to handshakeAge,
            "handshakeStatus" to handshakeStatus
        )
    }
}
