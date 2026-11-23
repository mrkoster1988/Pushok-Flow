package shop.pushok.flow

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Only fixed public codes cross the connection boundary, never backend exception text. */
class TunnelConnectionFailure(val code: String) : Exception(code)

/**
 * One instance belongs to the process, not an Activity.
 * [occupied] represents session/resource ownership, including a VLESS network
 * handover. It must never be used as the UI's actual local-UP observation.
 * Every backend operation,
 * status read and settings mutation uses [io], including clients from an old UI.
 * Backend/service changes outside this queue are reconciled by fresh state reads.
 */
class TunnelConnectionSession(
    private val nowElapsedMs: () -> Long,
    val io: ExecutorService = Executors.newSingleThreadExecutor(),
) {
    enum class Protocol(val wireName: String, val connectError: String, val disconnectError: String) {
        WIREGUARD("wireguard", "WG_CONNECT_FAILED", "WG_DISCONNECT_FAILED"),
        VLESS("vless", "XRAY_CONNECT_FAILED", "XRAY_DISCONNECT_FAILED"),
    }

    data class Observation(val known: Boolean, val occupied: Boolean)

    @Volatile var occupied = false
        private set
    @Volatile var connectedSinceElapsedMs: Long? = null
        private set
    @Volatile var lastErrorCode: String? = null
        private set

    /** A failed read preserves last-known ownership so a deliberate disconnect remains possible. */
    fun observe(readState: () -> Boolean): Observation {
        val actual = try { readState() } catch (_: Exception) {
            return Observation(known = false, occupied = occupied)
        }
        occupied = actual
        if (!actual) connectedSinceElapsedMs = null
        return Observation(known = true, occupied = actual)
    }

    fun connect(readState: () -> Boolean, activate: () -> Boolean): Boolean =
        connect(Protocol.WIREGUARD, readState, activate)

    fun connect(protocol: Protocol, readState: () -> Boolean, activate: () -> Boolean): Boolean {
        val before = observe(readState)
        if (!before.known) throw TunnelConnectionFailure("VPN_STATE_UNAVAILABLE")
        // GoBackend can tear down/recreate UP when given a newly parsed Config.
        // A repeated Connect is not authorization to replace the existing tunnel.
        if (before.occupied) {
            lastErrorCode = null
            return true
        }
        try {
            if (!activate()) throw IllegalStateException()
            occupied = true
            connectedSinceElapsedMs = nowElapsedMs()
            lastErrorCode = null
            return true
        } catch (error: Exception) {
            // Only these fixed route diagnoses may survive an activation
            // failure. Other exception types/messages remain private.
            val code = when ((error as? TunnelConnectionFailure)?.code) {
                "ROUTES_APPS_UNAVAILABLE" -> "ROUTES_APPS_UNAVAILABLE"
                "ROUTES_APPS_CHECK_FAILED" -> "ROUTES_APPS_CHECK_FAILED"
                else -> protocol.connectError
            }
            recordFailedConnect(readState, code)
            throw TunnelConnectionFailure(code)
        }
    }

    /** Also used when preparing a new configuration fails before backend mutation. */
    fun failedConnect(readState: () -> Boolean) {
        failedConnect(Protocol.WIREGUARD, readState)
    }

    fun failedConnect(protocol: Protocol, readState: () -> Boolean) {
        recordFailedConnect(readState, protocol.connectError)
    }

    private fun recordFailedConnect(readState: () -> Boolean, code: String) {
        lastErrorCode = code
        // A failed setState can restore an earlier tunnel. Its exception alone
        // says nothing about the resulting UP/DOWN state.
        observe(readState)
    }

    fun disconnect(readState: () -> Boolean, deactivate: () -> Boolean) =
        disconnect(Protocol.WIREGUARD, readState, deactivate)

    fun disconnect(protocol: Protocol, readState: () -> Boolean, deactivate: () -> Boolean) {
        try {
            // Do not require a successful preliminary read before trying DOWN.
            // A user must still be able to stop a last-known active connection.
            if (deactivate()) throw IllegalStateException()
            occupied = false
            connectedSinceElapsedMs = null
            lastErrorCode = null
        } catch (_: Exception) {
            lastErrorCode = protocol.disconnectError
            observe(readState)
            throw TunnelConnectionFailure(protocol.disconnectError)
        }
    }
}
