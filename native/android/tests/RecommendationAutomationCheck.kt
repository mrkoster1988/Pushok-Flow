package shop.pushok.flow

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private class AutomationMemory : RecommendationAutomationStorage {
    var disk: ByteArray? = null
    var readFailure: Exception? = null
    var failWrite = false
    var readbackFailure: Exception? = null
    var beforeCommit: () -> Unit = {}
    var writes = 0

    override fun read(): ByteArray? {
        readFailure?.let { throw it }
        return disk?.copyOf()
    }

    override fun replace(value: ByteArray, commit: (write: () -> Unit) -> Unit) {
        if (failWrite) throw IOException("private metadata path")
        beforeCommit()
        commit {
            disk = value.copyOf()
            writes++
            readbackFailure?.let { throw it }
        }
    }
}

private fun automationRejected(code: String, action: () -> Any?) {
    try { action(); error("Expected $code") }
    catch (failure: RouteRecommendationFailure) {
        check(failure.code == code && failure.message == code && failure.cause == null)
    }
}

fun checkRecommendationAutomation() {
    val guard: (action: () -> Unit) -> Unit = { it() }
    val hour = RecommendationAutomationStore.RETRY_INTERVAL_MS
    val day = RecommendationAutomationStore.SUCCESS_INTERVAL_MS
    val start = RecommendationClockSample(1_800_000_000_000L, 1_000_000L)
    fun after(delta: Long) = RecommendationClockSample(start.wallMillis + delta, start.elapsedMillis + delta)
    val memory = AutomationMemory()
    val session = RecommendationAutomationSession()
    val first = RecommendationAutomationStore(memory, session)

    // Fresh installs check automatically; an explicit persisted opt-out wins.
    first.restore(guard)
    check(first.snapshot().enabled && memory.writes == 0)
    first.setEnabled(false)
    check(!first.snapshot().enabled && memory.writes == 1)
    check(!first.reserve(start, automatic = true, guard))
    check(memory.writes == 1)
    first.setEnabled(true)
    check(first.snapshot().enabled && first.snapshot().attemptedAtMillis == null)
    check(memory.disk!!.size == RecommendationAutomationStore.STORAGE_BYTES)

    // Two Activity hosts on the production-style single queue cannot both reserve the same check.
    val second = RecommendationAutomationStore(memory, session)
    val executor = Executors.newSingleThreadExecutor()
    try {
        val a = executor.submit<Boolean> { first.reserve(start, automatic = true, guard) }
        val b = executor.submit<Boolean> { second.reserve(start, automatic = true, guard) }
        check(a.get(10, TimeUnit.SECONDS) && !b.get(10, TimeUnit.SECONDS))
    } finally { executor.shutdownNow() }
    check(first.snapshot().attemptedAtMillis == start.wallMillis)

    // An interrupted process has already durably reserved its retry window before touching HTTP.
    val restarted = RecommendationAutomationStore(memory, RecommendationAutomationSession())
    check(!restarted.reserve(after(hour - 1), automatic = true, guard))
    check(restarted.reserve(after(hour), automatic = true, guard))
    restarted.recordSuccess(after(hour), guard)
    val successfulRestart = RecommendationAutomationStore(memory, RecommendationAutomationSession())
    check(!successfulRestart.reserve(after(hour + day - 1), automatic = true, guard))
    check(successfulRestart.reserve(after(hour + day), automatic = true, guard))

    // Forced checks bypass consent/cooldown without changing consent. Their success also delays auto.
    successfulRestart.setEnabled(false)
    check(!successfulRestart.snapshot().enabled)
    check(successfulRestart.reserve(after(hour + day + 1), automatic = false, guard))
    check(successfulRestart.reserve(after(hour + day + 2), automatic = false, guard))
    successfulRestart.recordSuccess(after(hour + day + 2), guard)
    check(!successfulRestart.snapshot().enabled)
    successfulRestart.setEnabled(true)
    check(!successfulRestart.reserve(after(hour + day + 3), automatic = true, guard))

    // Wall-clock rollback cannot flood a live process or suppress checks indefinitely after restart.
    val rollbackMemory = AutomationMemory()
    val rollbackSession = RecommendationAutomationSession()
    val rollback = RecommendationAutomationStore(rollbackMemory, rollbackSession)
    rollback.setEnabled(true)
    check(rollback.reserve(start, automatic = true, guard))
    val back = RecommendationClockSample(start.wallMillis - day * 2, start.elapsedMillis + 1000)
    check(!rollback.reserve(back, automatic = true, guard))
    val afterClockChangeRestart = RecommendationAutomationStore(rollbackMemory, RecommendationAutomationSession())
    check(afterClockChangeRestart.reserve(back, automatic = true, guard))
    val anotherHost = RecommendationAutomationStore(rollbackMemory, RecommendationAutomationSession())
    check(!anotherHost.reserve(back.copy(wallMillis = back.wallMillis + 1), automatic = true, guard))

    // A failed durable reservation prevents automatic HTTP, while manual signed recovery still works.
    for (readFailure in listOf(IOException("private location"),
        RouteRecommendationFailure("RECOMMENDATIONS_INVALID"))) {
        val damaged = AutomationMemory().apply { this.readFailure = readFailure }
        val damagedStore = RecommendationAutomationStore(damaged, RecommendationAutomationSession())
        automationRejected("RECOMMENDATIONS_STORAGE_ERROR") { damagedStore.reserve(start, true, guard) }
        check(damagedStore.reserve(start, false, guard))
        check(damagedStore.snapshot().enabled && damaged.writes == 0)
        // Explicit consent changes repair even an oversized-record error from the bounded adapter.
        damagedStore.setEnabled(true)
        check(damagedStore.snapshot().enabled && damaged.writes == 1)
    }
    val unwritable = AutomationMemory()
    val unwritableStore = RecommendationAutomationStore(unwritable, RecommendationAutomationSession())
    unwritableStore.setEnabled(true)
    val prior = unwritable.disk!!.copyOf()
    unwritable.failWrite = true
    automationRejected("RECOMMENDATIONS_STORAGE_ERROR") { unwritableStore.reserve(start, true, guard) }
    automationRejected("RECOMMENDATIONS_STORAGE_ERROR") { unwritableStore.setEnabled(false) }
    check(unwritableStore.snapshot().enabled && unwritable.disk!!.contentEquals(prior))
    check(unwritableStore.reserve(start, false, guard))
    check(unwritable.disk!!.contentEquals(prior))

    // A malformed read-back after durable replacement is still supplementary metadata failure.
    // Auto must not fetch; manual can proceed; neither path acknowledges an unverified setting write.
    val readback = AutomationMemory()
    val readbackStore = RecommendationAutomationStore(readback, RecommendationAutomationSession())
    readbackStore.setEnabled(true)
    readback.readbackFailure = RouteRecommendationFailure("RECOMMENDATIONS_INVALID")
    automationRejected("RECOMMENDATIONS_STORAGE_ERROR") { readbackStore.reserve(start, true, guard) }
    check(readbackStore.snapshot().attemptedAtMillis == null)
    check(readbackStore.reserve(after(1), false, guard))
    check(readbackStore.snapshot().attemptedAtMillis == start.wallMillis)
    automationRejected("RECOMMENDATIONS_STORAGE_ERROR") { readbackStore.setEnabled(false) }
    check(readbackStore.snapshot().enabled)
    readback.readbackFailure = null
    readbackStore.restore(guard)
    check(!readbackStore.snapshot().enabled)

    // The metadata parser accepts exactly its bounded local format and no accidental opt-in.
    val valid = RecommendationAutomationStore.encode(RecommendationAutomationSettings(true, start.wallMillis, start.wallMillis))
    check(RecommendationAutomationStore.decode(valid).enabled)
    for (bad in listOf(byteArrayOf(), valid.copyOf(valid.size - 1), valid + byteArrayOf(0),
        valid.copyOf().apply { this[0] = 0 }, valid.copyOf().apply { this[4] = 2 },
        valid.copyOf().apply { for (i in 5..12) this[i] = 0xff.toByte() })) {
        automationRejected("RECOMMENDATIONS_STORAGE_ERROR") { RecommendationAutomationStore.decode(bad) }
    }

    // Lifecycle interruption is never converted into manual best-effort permission to fetch/write.
    val inactive: (action: () -> Unit) -> Unit = {
        throw RouteRecommendationFailure("RECOMMENDATIONS_INTERRUPTED")
    }
    automationRejected("RECOMMENDATIONS_INTERRUPTED") { first.reserve(after(day * 4), false, inactive) }
    val requests = RecommendationAutomaticRequests()
    val queuedAutomatic = requests.capture()
    requests.cancel()
    var committed = false
    automationRejected("RECOMMENDATIONS_INTERRUPTED") {
        requests.guarded(queuedAutomatic) { committed = true }
    }
    check(!committed)
    requests.guarded(requests.capture()) { committed = true }
    check(committed)

    // A pause/opt-out between staging and commit must leave durable metadata untouched as well.
    val interruptedMemory = AutomationMemory()
    val interruptedStore = RecommendationAutomationStore(interruptedMemory, RecommendationAutomationSession())
    interruptedStore.setEnabled(true)
    val previous = interruptedMemory.disk!!.copyOf()
    val token = requests.capture()
    interruptedMemory.beforeCommit = { requests.cancel() }
    automationRejected("RECOMMENDATIONS_INTERRUPTED") {
        interruptedStore.reserve(start, true) { action -> requests.guarded(token, action) }
    }
    check(interruptedMemory.disk!!.contentEquals(previous))
    check(interruptedStore.snapshot().attemptedAtMillis == null)

    // OFF is accepted while an automatic request owns IO. Pause/recreation follows immediately.
    // The request cannot commit; the already accepted local OFF must still survive on disk.
    val queuedMemory = AutomationMemory()
    val queuedSession = RecommendationAutomationSession()
    val oldHost = RecommendationAutomationStore(queuedMemory, queuedSession)
    oldHost.setEnabled(true)
    val queuedRequests = RecommendationAutomaticRequests()
    val started = CountDownLatch(1)
    val release = CountDownLatch(1)
    val foreground = AtomicBoolean(true)
    val queue = Executors.newSingleThreadExecutor()
    try {
        val captured = queuedRequests.capture()
        val request = queue.submit {
            val active: (action: () -> Unit) -> Unit = { action ->
                if (!foreground.get()) throw RouteRecommendationFailure("RECOMMENDATIONS_INTERRUPTED")
                queuedRequests.guarded(captured, action)
            }
            check(oldHost.reserve(start, true, active))
            started.countDown()
            check(release.await(10, TimeUnit.SECONDS))
            automationRejected("RECOMMENDATIONS_INTERRUPTED") { active { error("stale commit") } }
        }
        check(started.await(10, TimeUnit.SECONDS))
        check(foreground.get()) // Native accepts the user's setting change in this foreground.
        queuedRequests.cancel()
        val off = queue.submit { oldHost.setEnabled(false) }
        foreground.set(false)
        val recreatedHost = RecommendationAutomationStore(queuedMemory, queuedSession)
        val resumed = queue.submit<Boolean> {
            recreatedHost.restore(guard)
            !recreatedHost.snapshot().enabled && !recreatedHost.reserve(after(hour * 2), true, guard)
        }
        release.countDown()
        request.get(10, TimeUnit.SECONDS)
        off.get(10, TimeUnit.SECONDS)
        check(resumed.get(10, TimeUnit.SECONDS))
        // Subsequent choices retain their queue order; an older host's write cannot land later.
        val laterOn = queue.submit { recreatedHost.setEnabled(true) }
        val latestOff = queue.submit { recreatedHost.setEnabled(false) }
        laterOn.get(10, TimeUnit.SECONDS)
        latestOff.get(10, TimeUnit.SECONDS)
        val finalHost = RecommendationAutomationStore(queuedMemory, RecommendationAutomationSession())
        finalHost.restore(guard)
        check(!finalHost.snapshot().enabled)
    } finally { release.countDown(); queue.shutdownNow() }

    println("Recommendation opt-in, durable cooldowns, restart, clock changes, manual fallback and cancellation checks passed")
}
