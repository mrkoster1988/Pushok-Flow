package shop.pushok.flow

/** Privacy-preserving tunnel status: never include endpoints or keys. */
object TunnelHealth {
    fun uptimeSeconds(connected: Boolean, startedAtMs: Long?, nowMs: Long): Long {
        if (!connected || startedAtMs == null || nowMs < startedAtMs) return 0L
        return (nowMs - startedAtMs) / 1000L
    }

    fun snapshot(connected: Boolean, busy: Boolean, startedAtMs: Long?, nowMs: Long,
                 lastErrorCode: String?): Map<String, Any?> = mapOf(
        "connected" to connected,
        "state" to when { busy -> "transitioning"; connected -> "connected"; else -> "disconnected" },
        "uptimeSeconds" to uptimeSeconds(connected, startedAtMs, nowMs),
        "lastErrorCode" to lastErrorCode
    )
}