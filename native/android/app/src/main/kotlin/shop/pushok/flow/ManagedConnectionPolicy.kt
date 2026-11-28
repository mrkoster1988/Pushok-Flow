package shop.pushok.flow

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Local cache is a bounded lease, never an extension of the account's entitlement. */
object ManagedConnectionPolicy {
    const val CONNECT_REFRESH_TIMEOUT_MS = 5_000L

    fun canUseCached(errorCode: String, state: String, expiresAtMs: Long?, nowMs: Long): Boolean =
        errorCode in setOf("SUBSCRIPTION_NETWORK_ERROR", "SUBSCRIPTION_TIMEOUT") &&
            state == "active" && expiresAtMs != null && nowMs > 0 && nowMs < expiresAtMs
}

/** Fence a blocking backend UP with the original authority/intent on both sides. */
internal object ManagedActivation {
    fun connect(validate: () -> Unit, activate: () -> Boolean, deactivate: () -> Unit): Boolean {
        validate()
        val connected = try {
            activate()
        } catch (error: Exception) {
            // A failed backend may have produced a TUN before returning or throwing.
            // Loss of the original authority/intent always requests teardown.
            try { validate() } catch (_: Exception) {
                try { deactivate() } catch (_: Exception) { }
            }
            throw error
        }
        try { validate() } catch (error: Exception) {
            try { deactivate() } catch (_: Exception) { }
            throw error
        }
        return connected
    }
}

/** Bounded, cancel-aware acknowledgement of the public Android service binding. */
internal class ManagedServiceHold {
    private val signal = CountDownLatch(1)
    private var lost = false
    @Volatile var ready = false
        private set

    @Synchronized fun connected() {
        if (!lost) ready = true
        signal.countDown()
    }

    @Synchronized fun disconnected() {
        lost = true
        ready = false
        signal.countDown()
    }

    fun awaitReady(current: () -> Boolean, timeoutMs: Long = 2_000L): Boolean {
        require(timeoutMs in 1..2_000L)
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (current()) {
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) return false
            if (signal.await(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(50)), TimeUnit.NANOSECONDS)) {
                return current() && ready
            }
        }
        return false
    }
}

/** Only the service whose builder actually supplied this UP may authorize recovery. */
internal class ManagedServiceIdentity<T : Any> {
    private var service: T? = null
    @Synchronized fun beginBuild() { service = null }
    @Synchronized fun builtBy(instance: T) { service = instance }
    @Synchronized fun destroyed(instance: T) { if (service === instance) service = null }
    @Synchronized fun current(): T? = service
    @Synchronized fun matches(instance: T): Boolean = service === instance
}

/**
 * Failover decisions contain local IDs and fixed states only. Configurations, URLs and
 * account tokens stay in the encrypted store/native adapter. No fallback leaves the
 * originating subscription, and one user connection intent tries each node at most once.
 */
class ManagedFailoverPolicy {
    class Sample(
        val profileId: String,
        val subscriptionId: String,
        val candidates: List<String>,
        val expiresAtMs: Long,
        val nowMs: Long,
        val elapsedMs: Long,
        val authorized: Boolean,
        val physicalNetwork: Boolean,
        val probe: String,
        val guarded: Boolean,
    )

    class Switch internal constructor(
        val generation: Long,
        val fromProfileId: String,
        val toProfileId: String,
        val subscriptionId: String,
        internal val previousSwitchMs: Long?,
    )

    private var generation = 0L
    private var profileId: String? = null
    private var subscriptionId: String? = null
    private val attempted = linkedSetOf<String>()
    private var failures = 0
    private var lastSampleMs: Long? = null
    private var lastSwitchMs: Long? = null
    @Volatile var status: String = "idle"
        private set

    @Synchronized fun start(profile: String, subscription: String): Long {
        generation++
        profileId = profile
        subscriptionId = subscription
        attempted.clear()
        attempted.add(profile)
        failures = 0
        lastSampleMs = null
        lastSwitchMs = null
        status = "checking"
        return generation
    }

    @Synchronized fun stop() {
        generation++
        profileId = null
        subscriptionId = null
        attempted.clear()
        failures = 0
        status = "idle"
    }

    @Synchronized fun current(token: Long): Boolean =
        token == generation && profileId != null && subscriptionId != null

    @Synchronized fun observe(token: Long, sample: Sample): Switch? {
        if (!current(token)) return null
        if (sample.profileId != profileId || sample.subscriptionId != subscriptionId) {
            // A manual choice, account replacement or later connection owns the new state.
            stop()
            return null
        }
        if (status == "switching") return null
        if (!sample.authorized) {
            failures = 0
            status = "authorization_required"
            return null
        }
        if (sample.nowMs <= 0 || sample.expiresAtMs <= sample.nowMs) {
            failures = 0
            status = "subscription_expired"
            return null
        }
        if (!sample.physicalNetwork) {
            failures = 0
            status = "waiting_network"
            return null
        }
        if (sample.probe == "ok") {
            failures = 0
            status = "ready"
            lastSampleMs = sample.elapsedMs
            return null
        }
        if (sample.probe !in setOf("dns", "https", "timeout")) {
            // A failed status read or an unrelated/default network is not a dead WG peer.
            failures = 0
            status = "checking"
            return null
        }
        val previous = lastSampleMs
        if (previous != null && sample.elapsedMs - previous < 5_000L) return null
        lastSampleMs = sample.elapsedMs
        failures++
        status = "checking"
        if (failures < 2) return null
        if (lastSwitchMs?.let { sample.elapsedMs - it < 60_000L } == true) return null
        val next = sample.candidates.distinct().firstOrNull { it != profileId && it !in attempted }
        if (next == null) {
            status = "exhausted"
            return null
        }
        if (!sample.guarded) {
            // GoBackend rebuilds the TUN. Never create a direct-traffic gap automatically.
            status = "guard_required"
            return null
        }
        val previousSwitch = lastSwitchMs
        attempted.add(next)
        lastSwitchMs = sample.elapsedMs
        failures = 0
        status = "switching"
        return Switch(generation, sample.profileId, next, sample.subscriptionId, previousSwitch)
    }

    @Synchronized fun accepts(change: Switch): Boolean =
        current(change.generation) && profileId == change.fromProfileId &&
            subscriptionId == change.subscriptionId && status == "switching"

    /** Local contention/preflight refusal did not attempt this node or consume its cooldown. */
    @Synchronized fun defer(change: Switch) {
        if (!accepts(change)) return
        attempted.remove(change.toProfileId)
        lastSwitchMs = change.previousSwitchMs
        failures = 0
        status = "checking"
    }

    @Synchronized fun complete(change: Switch, success: Boolean) {
        if (!accepts(change)) return
        if (success) profileId = change.toProfileId
        status = if (success) "checking" else "unavailable"
    }
}
