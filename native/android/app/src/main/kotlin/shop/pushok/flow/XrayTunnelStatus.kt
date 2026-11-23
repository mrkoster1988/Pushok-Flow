package shop.pushok.flow

/** A local service observation, not evidence that the remote Internet is reachable. */
internal class XrayTunnelStatus private constructor(
    val connected: Boolean,
    val ownsTunnel: Boolean,
    val state: State,
    val lastErrorCode: String?,
) {
    enum class State(val wireName: String) {
        CONNECTED("connected"),
        DISCONNECTED("disconnected"),
        WAITING_NETWORK("waiting_network"),
        RECONNECTING("reconnecting"),
        UNKNOWN("unknown"),
    }

    val known: Boolean get() = state != State.UNKNOWN

    companion object {
        private val safeErrors = setOf("XRAY_CONNECT_FAILED", "XRAY_DISCONNECT_FAILED", "XRAY_STATUS_FAILED", "XRAY_STATE_UNAVAILABLE")

        fun fromWire(value: Map<*, *>): XrayTunnelStatus {
            fun invalid(): Nothing = throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
            val connected = value["connected"] as? Boolean ?: invalid()
            val owned = value["ownsTunnel"] as? Boolean ?: invalid()
            val state = State.entries.firstOrNull { it.wireName == value["state"] } ?: invalid()
            val valid = when (state) {
                State.CONNECTED -> connected && owned
                State.DISCONNECTED -> !connected && !owned
                State.WAITING_NETWORK, State.RECONNECTING -> !connected && owned
                State.UNKNOWN -> !connected
            }
            if (!valid) invalid()
            val error = (value["lastErrorCode"] as? String)?.takeIf { it in safeErrors }
            return XrayTunnelStatus(connected, owned, state, error)
        }
    }
}
