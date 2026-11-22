package shop.pushok.flow

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Only fixed public codes cross the connection boundary, never backend exception text. */
class TunnelConnectionFailure(val code: String) : Exception(code)

/**
 * One instance belongs to the process, not an Activity. Every backend operation,
 * status read and settings mutation uses [io], including clients from an old UI.
 * Backend/service changes outside this queue are reconciled by fresh state reads.
 */
class TunnelConnectionSession(
    private val nowElapsedMs: () -> Long,
    val io: ExecutorService = Executors.newSingleThreadExecutor(),
) {
    data class Observation(val known: Boolean, val connected: Boolean)

    @Volatile var connected = false
        private set
    @Volatile var connectedSinceElapsedMs: Long? = null
        private set
    @Volatile var lastErrorCode: String? = null
        private set

    /** A failed read preserves last-known UP so a deliberate disconnect remains possible. */
    fun observe(readState: () -> Boolean): Observation {
        val actual = try { readState() } catch (_: Exception) {
            return Observation(known = false, connected = connected)
        }
        connected = actual
        if (!actual) connectedSinceElapsedMs = null
        return Observation(known = true, connected = actual)
    }

    fun connect(readState: () -> Boolean, activate: () -> Boolean): Boolean {
        val before = observe(readState)
        if (!before.known) throw TunnelConnectionFailure("VPN_STATE_UNAVAILABLE")
        // GoBackend can tear down/recreate UP when given a newly parsed Config.
        // A repeated Connect is not authorization to replace the existing tunnel.
        if (before.connected) {
            lastErrorCode = null
            return true
        }
        try {
            if (!activate()) throw IllegalStateException()
            connected = true
            connectedSinceElapsedMs = nowElapsedMs()
            lastErrorCode = null
            return true
        } catch (_: Exception) {
            failedConnect(readState)
            throw TunnelConnectionFailure("WG_CONNECT_FAILED")
        }
    }

    /** Also used when preparing a new configuration fails before backend mutation. */
    fun failedConnect(readState: () -> Boolean) {
        lastErrorCode = "WG_CONNECT_FAILED"
        // A failed setState can restore an earlier tunnel. Its exception alone
        // says nothing about the resulting UP/DOWN state.
        observe(readState)
    }

    fun disconnect(readState: () -> Boolean, deactivate: () -> Boolean) {
        try {
            // Do not require a successful preliminary read before trying DOWN.
            // A user must still be able to stop a last-known active connection.
            if (deactivate()) throw IllegalStateException()
            connected = false
            connectedSinceElapsedMs = null
            lastErrorCode = null
        } catch (_: Exception) {
            lastErrorCode = "WG_DISCONNECT_FAILED"
            observe(readState)
            throw TunnelConnectionFailure("WG_DISCONNECT_FAILED")
        }
    }
}
