package shop.pushok.flow

import java.util.concurrent.atomic.AtomicLong

class XrayTunnelFailure(val code: String) : Exception(code)

/** Shared by the service's main cancellation path and its serialized native worker. */
class XrayRequestLease(private val nowElapsedMs: () -> Long) {
    data class Completion(
        val generation: Long,
        val deadline: Long,
        val connected: Boolean,
        val error: String? = null,
    )

    private val generation = AtomicLong()
    fun current() = generation.get()
    fun invalidate() = generation.incrementAndGet()
    fun owns(token: Long) = token == generation.get()
    fun requireCurrent(token: Long, deadline: Long) {
        if (!owns(token) || nowElapsedMs() >= deadline) throw XrayTunnelFailure("XRAY_TIMEOUT")
    }

    /** Runs only on the shared native worker, so cleanup precedes the next START. */
    fun runStart(
        token: Long,
        deadline: Long,
        readConnected: () -> Boolean,
        activate: () -> Unit,
        cleanup: () -> Unit,
        errorCode: (Throwable) -> String,
    ): Completion {
        var failure: String? = null
        try {
            requireCurrent(token, deadline)
            if (!readConnected()) activate()
            requireCurrent(token, deadline)
        } catch (error: Throwable) {
            failure = errorCode(error)
        } finally {
            if (failure != null) cleanup()
        }
        return Completion(token, deadline, readConnected(), failure)
    }

    /**
     * Runs on the service main thread, alongside START, STOP, revoke and destroy.
     * Worker snapshots do not authorize a later reply, notification or teardown.
     */
    fun deliver(
        completion: Completion,
        available: () -> Boolean,
        reply: (Boolean, String?) -> Unit,
        onUp: () -> Unit = {},
        onDown: () -> Unit = {},
        onExpired: () -> Unit = {},
    ) {
        fun reject(): Boolean {
            val code = when {
                !owns(completion.generation) || !available() -> "XRAY_STATE_UNAVAILABLE"
                nowElapsedMs() >= completion.deadline -> "XRAY_TIMEOUT"
                else -> return false
            }
            // An expired old command must never stop a newer generation.
            if (code == "XRAY_TIMEOUT") onExpired()
            reply(false, code)
            return true
        }
        if (reject()) return
        if (completion.connected && completion.error == null) onUp()
        // Publishing the foreground notification can itself trigger teardown.
        if (reject()) return
        reply(completion.connected, completion.error)
        if (!completion.connected && owns(completion.generation) && available()) onDown()
    }

    companion object {
        /** An incomplete native teardown is UNKNOWN, never a false DOWN. */
        fun knownState(connected: Boolean, nativeActive: Boolean, coreRunning: Boolean): Boolean {
            if (nativeActive && !connected) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
            return connected && nativeActive && coreRunning
        }
    }
}
