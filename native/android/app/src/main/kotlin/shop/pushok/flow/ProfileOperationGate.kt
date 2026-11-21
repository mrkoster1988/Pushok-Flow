package shop.pushok.flow

/** One process-wide owner across permission UI, tunnel work and profile changes. */
class ProfileOperationGate {
    private var generation = 0L
    private var owner: Long? = null

    @Synchronized fun acquire(): Long? {
        if (owner != null || generation == Long.MAX_VALUE) return null
        return (++generation).also { owner = it }
    }

    @Synchronized fun release(token: Long) {
        if (owner == token) owner = null
    }

    @Synchronized fun get(): Boolean = owner != null
}
