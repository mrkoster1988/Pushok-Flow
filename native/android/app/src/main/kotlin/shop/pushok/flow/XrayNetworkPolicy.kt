package shop.pushok.flow

/** Selection does not equate Android's connectivity probe with VLESS reachability. */
internal object XrayNetworkPolicy {
    data class Candidate(
        val id: Long,
        val internet: Boolean,
        val notVpn: Boolean,
        val validated: Boolean,
        val captivePortal: Boolean,
        val notMetered: Boolean,
        val linkReady: Boolean,
    ) {
        val eligible: Boolean get() = internet && notVpn && linkReady && !captivePortal
    }

    fun select(candidates: Collection<Candidate>, currentId: Long?): Candidate? =
        candidates.asSequence().filter { it.eligible }.sortedWith(
            compareByDescending<Candidate> { it.validated }
                .thenByDescending { it.notMetered }
                .thenByDescending { it.id == currentId }
                .thenBy { it.id },
        ).firstOrNull()
}

/**
 * The production socket and DNS callbacks use these exact epoch/identity checks.
 * A network change does not replace the user's START lease or restart native code.
 */
internal class XrayNetworkState<T> {
    class Selection<T> internal constructor(val epoch: Long, val revision: Long, val target: T)
    data class View<T>(
        val epoch: Long,
        val desired: Boolean,
        val selection: Selection<T>?,
        val changing: Boolean,
        val failed: Boolean,
    )

    private var epoch = 0L
    private var revision = 0L
    private var desired = false
    private var selection: Selection<T>? = null
    private var changing = false
    private var failed = false

    @Synchronized fun begin(): Long {
        epoch++
        desired = true
        selection = null
        changing = true
        failed = false
        return epoch
    }

    /** Called before unregistering callbacks or enqueueing native STOP. */
    @Synchronized fun stop() {
        epoch++
        desired = false
        selection = null
        changing = false
        failed = false
    }

    @Synchronized fun owns(expectedEpoch: Long): Boolean = desired && epoch == expectedEpoch

    /** Invalidate old DNS replies and new socket binds while updates are coalesced. */
    @Synchronized fun changing(expectedEpoch: Long): Boolean {
        if (!owns(expectedEpoch)) return false
        selection = null
        changing = true
        failed = false
        return true
    }

    /** Publish only after Android accepted the same underlying network. */
    @Synchronized fun select(expectedEpoch: Long, target: T?): Selection<T>? {
        if (!owns(expectedEpoch)) return null
        revision++
        selection = target?.let { Selection(epoch, revision, it) }
        changing = false
        failed = false
        return selection
    }

    @Synchronized fun fail(expectedEpoch: Long) {
        if (!owns(expectedEpoch)) return
        selection = null
        changing = false
        failed = true
    }

    @Synchronized fun view(): View<T> = View(epoch, desired, selection, changing, failed)

    @Synchronized fun isCurrent(value: Selection<T>): Boolean =
        desired && epoch == value.epoch && selection === value && !failed

    /** Never hold the state lock over platform IPC: STOP must not wait for netd. */
    fun useCurrent(value: Selection<T>, action: (T) -> Boolean): Boolean =
        isCurrent(value) && action(value.target) && isCurrent(value)

    /** A platform operation already in flight cannot publish a stale success. */
    fun update(expectedEpoch: Long, action: () -> Boolean): Boolean =
        owns(expectedEpoch) && action() && owns(expectedEpoch)
}

/** Actual service status producer, also deciding whether STATUS may use the worker. */
internal class XrayServiceStatus private constructor(
    val connected: Boolean,
    val ownsTunnel: Boolean,
    val state: String,
    val error: String? = null,
) {
    val needsNativeProbe: Boolean get() = state == "connected" || state == "disconnected"

    fun withFailure(code: String): XrayServiceStatus = XrayServiceStatus(false, ownsTunnel, "unknown", code)

    companion object {
        fun read(
            occupied: Boolean,
            blocked: Boolean,
            coreReady: Boolean,
            starting: Boolean,
            changing: Boolean,
            networkAvailable: Boolean,
        ): XrayServiceStatus {
            if (!occupied) return XrayServiceStatus(false, false, "disconnected")
            if (blocked) return XrayServiceStatus(false, true, "unknown", "XRAY_STATE_UNAVAILABLE")
            if (!coreReady) return if (starting) XrayServiceStatus(false, true, "reconnecting")
                else XrayServiceStatus(false, true, "unknown", "XRAY_STATE_UNAVAILABLE")
            return when {
                changing -> XrayServiceStatus(false, true, "reconnecting")
                !networkAvailable -> XrayServiceStatus(false, true, "waiting_network")
                else -> XrayServiceStatus(true, true, "connected")
            }
        }
    }
}
