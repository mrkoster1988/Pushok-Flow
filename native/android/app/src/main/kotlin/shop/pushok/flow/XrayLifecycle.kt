package shop.pushok.flow

import java.util.concurrent.atomic.AtomicLong

class XrayTunnelFailure(val code: String) : Exception(code)

/** Shared by the service's main cancellation path and its serialized native worker. */
class XrayRequestLease(private val nowElapsedMs: () -> Long) {
    private val generation = AtomicLong()
    fun current() = generation.get()
    fun invalidate() = generation.incrementAndGet()
    fun owns(token: Long) = token == generation.get()
    fun requireCurrent(token: Long, deadline: Long) {
        if (!owns(token) || nowElapsedMs() >= deadline) throw XrayTunnelFailure("XRAY_TIMEOUT")
    }

    companion object {
        /** An incomplete native teardown is UNKNOWN, never a false DOWN. */
        fun knownState(connected: Boolean, nativeActive: Boolean, coreRunning: Boolean): Boolean {
            if (nativeActive && !connected) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
            return connected && nativeActive && coreRunning
        }
    }
}
