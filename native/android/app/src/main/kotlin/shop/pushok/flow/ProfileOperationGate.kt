package shop.pushok.flow

/** One process-wide owner across permission UI, tunnel work and profile changes. */
class ProfileOperationGate {
    class StopLease internal constructor(val token: Long, val displacedOwner: Long?)
    private var generation = 0L
    private var owner: Long? = null
    private var ownerStop: Long? = null
    private var stopGeneration = 0L
    private val pendingStops = mutableSetOf<Long>()

    @Synchronized fun acquire(): Long? {
        if (owner != null || pendingStops.isNotEmpty() || generation == Long.MAX_VALUE) return null
        return (++generation).also { owner = it }
    }

    @Synchronized fun release(token: Long) {
        if (owner == token) {
            owner = null
            ownerStop = null
        }
    }

    /** Captured before network preflight/permission; a finished Stop still invalidates it. */
    @Synchronized fun captureIntent(): Long? =
        stopGeneration.takeIf { pendingStops.isEmpty() }

    @Synchronized fun isCurrentIntent(intent: Long): Boolean =
        pendingStops.isEmpty() && intent == stopGeneration

    /** Reserve before queueing IO, so later profile/settings work cannot overtake Stop. */
    @Synchronized fun requestStop(): Long {
        check(stopGeneration != Long.MAX_VALUE)
        return (++stopGeneration).also { pendingStops.add(it) }
    }

    /**
     * Called only on the shared connection IO queue, after all earlier backend work.
     * May replace a normal owner still waiting for Android permission in another
     * Activity. Its old intent is invalid, and its late release cannot release Stop.
     */
    @Synchronized fun acquireStop(stop: Long): StopLease? {
        if (stop !in pendingStops || ownerStop != null || generation == Long.MAX_VALUE) return null
        val displaced = owner
        val token = ++generation
        owner = token
        ownerStop = stop
        return StopLease(token, displaced)
    }

    @Synchronized fun finishStop(stop: Long) {
        pendingStops.remove(stop)
    }

    @Synchronized fun stopPending(): Boolean = pendingStops.isNotEmpty()

    @Synchronized fun get(): Boolean = owner != null || pendingStops.isNotEmpty()
}
