package shop.pushok.flow

interface RouteRecommendationStorage {
    fun read(): ByteArray?
    /** Prepare the file, then let the owner guard the final durable write and state commit together. */
    fun replace(value: ByteArray, commit: (write: () -> Unit) -> Unit)
}

/** Shared with the Android AtomicFile adapter so its dangerous post-finish abort is tested on JVM. */
internal fun replaceRecommendationFile(
    prepare: () -> Unit,
    finish: () -> Unit,
    verifyCommitted: () -> Unit,
    abortUnfinished: () -> Unit,
    commit: (write: () -> Unit) -> Unit,
) {
    var finalized = false
    try {
        prepare()
        commit {
            finish()
            // A failed read-back cannot safely invoke AtomicFile.failWrite after finishWrite.
            finalized = true
            verifyCommitted()
        }
    } finally {
        if (!finalized) abortUnfinished()
    }
}

class RouteRecommendationSnapshot(
    val recommendations: VerifiedRouteRecommendations,
    val checkedAtMillis: Long? = null,
)

/** All writes run on one process queue; readers receive an immutable snapshot. */
class RouteRecommendationStore(
    private val storage: RouteRecommendationStorage,
    private val verify: (ByteArray) -> VerifiedRouteRecommendations,
) {
    @Volatile private var state = RouteRecommendationSnapshot(RouteRecommendationPolicy.empty())

    fun snapshot(): RouteRecommendationSnapshot = state

    fun restore(guard: (action: () -> Unit) -> Unit) {
        var saved: ByteArray? = null
        guard { saved = read() }
        val candidate = saved?.let(verify) ?: return
        guard {
            RouteRecommendationPolicy.requireFresh(state.recommendations, candidate)
            if (!state.recommendations.samePayload(candidate)) {
                // A cache restoration does not claim a successful network check in this session.
                state = RouteRecommendationSnapshot(candidate)
            }
        }
    }

    fun accept(envelope: ByteArray, checkedAtMillis: Long, guard: (action: () -> Unit) -> Unit) {
        val candidate = verify(envelope)
        RouteRecommendationPolicy.requireFresh(state.recommendations, candidate)
        try {
            storage.replace(candidate.envelope()) { write ->
                guard {
                    RouteRecommendationPolicy.requireFresh(state.recommendations, candidate)
                    write()
                    // Never acknowledge new recommendations if durable storage failed.
                    state = RouteRecommendationSnapshot(candidate, checkedAtMillis)
                }
            }
        } catch (failure: RouteRecommendationFailure) {
            throw failure
        } catch (_: Exception) {
            throw RouteRecommendationFailure("RECOMMENDATIONS_STORAGE_ERROR")
        }
    }

    private fun read(): ByteArray? = try { storage.read() }
        catch (_: Exception) { throw RouteRecommendationFailure("RECOMMENDATIONS_STORAGE_ERROR") }
}
