package shop.pushok.flow

import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

/** Local scheduling metadata is separate from the signed catalogue and never authorizes routes. */
data class RecommendationAutomationSettings(
    val enabled: Boolean = false,
    val attemptedAtMillis: Long? = null,
    val succeededAtMillis: Long? = null,
)

data class RecommendationClockSample(val wallMillis: Long, val elapsedMillis: Long)

/** Shared by all Activity hosts; access is serialized on RouteRecommendations' process IO queue. */
class RecommendationAutomationSession {
    private var attemptedAtElapsed: Long? = null
    private var succeededAtElapsed: Long? = null

    fun mayAttempt(now: RecommendationClockSample): Boolean =
        expired(attemptedAtElapsed, now.elapsedMillis, RecommendationAutomationStore.RETRY_INTERVAL_MS) &&
            expired(succeededAtElapsed, now.elapsedMillis, RecommendationAutomationStore.SUCCESS_INTERVAL_MS)

    fun attempted(now: RecommendationClockSample) { attemptedAtElapsed = now.elapsedMillis }
    fun succeeded(now: RecommendationClockSample) { succeededAtElapsed = now.elapsedMillis }

    private fun expired(previous: Long?, now: Long, interval: Long): Boolean =
        previous == null || now < previous || now - previous >= interval
}

interface RecommendationAutomationStorage {
    fun read(): ByteArray?
    fun replace(value: ByteArray, commit: (write: () -> Unit) -> Unit)
}

/** Monotonic time prevents clock changes causing repeated requests in a live process. */
class RecommendationAutomationStore(
    private val storage: RecommendationAutomationStorage,
    private val session: RecommendationAutomationSession,
) {
    @Volatile private var state = RecommendationAutomationSettings()

    companion object {
        const val RETRY_INTERVAL_MS = 60L * 60 * 1000
        const val SUCCESS_INTERVAL_MS = 24L * 60 * 60 * 1000
        const val STORAGE_BYTES = 21
        private const val MAX_TIMESTAMP = 8_640_000_000_000_000L
        private const val MAGIC = 0x46524101 // FRA, local storage schema 1.

        fun encode(value: RecommendationAutomationSettings): ByteArray {
            requireTimestamp(value.attemptedAtMillis)
            requireTimestamp(value.succeededAtMillis)
            return ByteBuffer.allocate(STORAGE_BYTES).putInt(MAGIC)
                .put(if (value.enabled) 1.toByte() else 0.toByte())
                .putLong(value.attemptedAtMillis ?: 0).putLong(value.succeededAtMillis ?: 0).array()
        }

        fun decode(bytes: ByteArray): RecommendationAutomationSettings {
            if (bytes.size != STORAGE_BYTES) storageFailure()
            val buffer = ByteBuffer.wrap(bytes)
            if (buffer.int != MAGIC) storageFailure()
            val enabled = when (buffer.get().toInt()) { 0 -> false; 1 -> true; else -> storageFailure() }
            val attempted = buffer.long.takeUnless { it == 0L }
            val succeeded = buffer.long.takeUnless { it == 0L }
            requireTimestamp(attempted)
            requireTimestamp(succeeded)
            return RecommendationAutomationSettings(enabled, attempted, succeeded)
        }

        private fun requireTimestamp(value: Long?) {
            if (value != null && value !in 1..MAX_TIMESTAMP) storageFailure()
        }

        private fun storageFailure(): Nothing =
            throw RouteRecommendationFailure("RECOMMENDATIONS_STORAGE_ERROR")
    }

    fun snapshot(): RecommendationAutomationSettings = state

    fun restore(guard: (action: () -> Unit) -> Unit) {
        var saved: ByteArray? = null
        try { guard { saved = storage.read() } }
        catch (failure: RouteRecommendationFailure) {
            // The shared bounded file adapter uses INVALID for excessive bytes. For this local
            // metadata that is a storage error, not a bad signed catalogue or a manual-fetch veto.
            if (failure.code == "RECOMMENDATIONS_INTERRUPTED") throw failure
            storageFailure()
        }
        catch (_: Exception) { storageFailure() }
        val value = saved?.let(::decode) ?: RecommendationAutomationSettings()
        guard { state = value }
    }

    /** The host accepts the explicit intent while foreground; its local write survives later pause. */
    fun setEnabled(enabled: Boolean) {
        val guard: (action: () -> Unit) -> Unit = { it() }
        // An explicit setting change can repair malformed local metadata. It cannot repair or
        // modify the separately verified catalogue. Preserve known scheduling history if possible.
        try { restore(guard) }
        catch (failure: RouteRecommendationFailure) {
            if (failure.code != "RECOMMENDATIONS_STORAGE_ERROR") throw failure
        }
        save(state.copy(enabled = enabled), guard)
    }

    /** Called on the shared queue immediately before a request. False means no network is needed. */
    fun reserve(now: RecommendationClockSample, automatic: Boolean,
        guard: (action: () -> Unit) -> Unit): Boolean {
        return try { reserveDurably(now, automatic, guard) }
        catch (failure: RouteRecommendationFailure) {
            if (automatic || failure.code != "RECOMMENDATIONS_STORAGE_ERROR") throw failure
            // Manual refresh remains useful even if its supplementary scheduling record cannot
            // be read or saved. This never bypasses the signed catalogue's storage/verification.
            guard { session.attempted(now) }
            true
        }
    }

    private fun reserveDurably(now: RecommendationClockSample, automatic: Boolean,
        guard: (action: () -> Unit) -> Unit): Boolean {
        requireTimestamp(now.wallMillis)
        if (now.elapsedMillis < 0) storageFailure()
        restore(guard)
        if (automatic && (!state.enabled || !session.mayAttempt(now) ||
                !expired(state.attemptedAtMillis, now.wallMillis, RETRY_INTERVAL_MS) ||
                !expired(state.succeededAtMillis, now.wallMillis, SUCCESS_INTERVAL_MS))) return false
        // A crash after reservation still leaves the retry cooldown on disk.
        save(state.copy(attemptedAtMillis = now.wallMillis), guard)
        session.attempted(now)
        return true
    }

    fun recordSuccess(now: RecommendationClockSample, guard: (action: () -> Unit) -> Unit) {
        requireTimestamp(now.wallMillis)
        // Retain the live-process cooldown even if the supplementary metadata write fails.
        guard { session.succeeded(now) }
        restore(guard)
        save(state.copy(succeededAtMillis = now.wallMillis), guard)
    }

    private fun expired(previous: Long?, now: Long, interval: Long): Boolean =
        previous == null || now < previous || now - previous >= interval

    private fun save(value: RecommendationAutomationSettings, guard: (action: () -> Unit) -> Unit) {
        val encoded = encode(value)
        try {
            storage.replace(encoded) { write ->
                guard { write(); state = value }
            }
        } catch (failure: RouteRecommendationFailure) {
            // The bounded read-back adapter can also signal INVALID after AtomicFile.finishWrite.
            // Keep this supplementary metadata failure distinct from signed-catalogue validation.
            if (failure.code == "RECOMMENDATIONS_INTERRUPTED") throw failure
            storageFailure()
        }
        catch (_: Exception) { storageFailure() }
    }
}

/** Opt-out and an automatic request's final commit share a lock across all Activity instances. */
class RecommendationAutomaticRequests {
    private val lock = Any()
    private val epoch = AtomicLong(0)

    fun capture(): Long = epoch.get()

    fun cancel() = synchronized(lock) { epoch.incrementAndGet(); Unit }

    fun requireCurrent(expected: Long) {
        if (epoch.get() != expected) throw RouteRecommendationFailure("RECOMMENDATIONS_INTERRUPTED")
    }

    fun guarded(expected: Long, action: () -> Unit) = synchronized(lock) {
        requireCurrent(expected)
        action()
    }
}
