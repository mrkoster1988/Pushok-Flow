package shop.pushok.flow

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

internal class BoundedNetworkFailure(val kind: Kind) : Exception() {
    enum class Kind { TIMEOUT, CANCELLED, BUSY }
}

/** Create once per feature, never per request. A stuck platform call keeps its admission permit. */
internal class BoundedNetworkPool(
    name: String,
    workers: Int = 2,
    private val afterCompletion: () -> Unit = {},
) {
    init { require(workers > 0) }

    private fun threads(label: String): ThreadFactory {
        val sequence = AtomicInteger()
        return ThreadFactory { task ->
            Thread(task, "$label-${sequence.incrementAndGet()}").apply { isDaemon = true }
        }
    }

    private val permits = Semaphore(workers)
    private val executor = ThreadPoolExecutor(workers, workers, 0L, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue<Runnable>(workers), threads("$name-io"), ThreadPoolExecutor.AbortPolicy())
    private val aborts = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue<Runnable>(2), threads("$name-abort"), ThreadPoolExecutor.AbortPolicy())

    fun <T> newCall(deadlineMs: Long, elapsedMs: () -> Long, onDiscard: (T) -> Unit = {}): BoundedNetworkCall<T> =
        BoundedNetworkCall(this, deadlineMs, elapsedMs, onDiscard)

    internal fun execute(action: () -> Unit, completed: () -> Unit) {
        if (!permits.tryAcquire()) throw BoundedNetworkFailure(BoundedNetworkFailure.Kind.BUSY)
        try {
            executor.execute {
                try { action() }
                finally {
                    // Remote work, cleanup and late-result disposal have all ended.
                    // Release before waking the caller, whose next request can queue
                    // while this fixed worker finishes its short executor epilogue.
                    // Active + queued remote work still holds at most `workers` permits.
                    permits.release()
                    completed()
                    afterCompletion()
                }
            }
        } catch (_: RejectedExecutionException) {
            permits.release()
            throw BoundedNetworkFailure(BoundedNetworkFailure.Kind.BUSY)
        }
    }

    internal fun abort(action: () -> Unit) {
        try {
            aborts.execute { try { action() } catch (_: Exception) { } }
        } catch (_: RejectedExecutionException) {
            // The I/O worker still owns cleanup in its finally block. Never block
            // an Activity/caller or allocate another thread if disconnect itself hangs.
        }
    }
}

/**
 * One response handoff with a caller deadline, even when DNS/socket APIs ignore interruption.
 * The operation may perform remote I/O only: durable state belongs to the waiting caller.
 */
internal class BoundedNetworkCall<T> internal constructor(
    private val pool: BoundedNetworkPool,
    private val deadlineMs: Long,
    private val elapsedMs: () -> Long,
    private val onDiscard: (T) -> Unit,
) {
    private val lock = Any()
    private val finished = CountDownLatch(1)
    @Volatile private var abandoned = false
    private var started = false
    private var worker: Thread? = null
    private var abortAction: (() -> Unit)? = null
    private var outcome: Result<T>? = null

    fun check() { remaining() }

    fun timeout(maxMs: Int = 10_000): Int {
        require(maxMs > 0)
        return remaining().coerceAtMost(maxMs.toLong()).toInt()
    }

    private fun remaining(): Long {
        if (abandoned) throw BoundedNetworkFailure(BoundedNetworkFailure.Kind.CANCELLED)
        val value = deadlineMs - elapsedMs()
        if (value <= 0) throw BoundedNetworkFailure(BoundedNetworkFailure.Kind.TIMEOUT)
        return value
    }

    /** Register only the current connection; a late registration after cancel is also aborted. */
    fun setAbort(action: (() -> Unit)?) {
        val immediate = synchronized(lock) {
            if (abandoned) action else { abortAction = action; null }
        }
        immediate?.let(pool::abort)
    }

    fun cancel() {
        var discarded: Result<T>? = null
        val abort = synchronized(lock) {
            if (abandoned) return
            abandoned = true
            discarded = outcome
            outcome = null
            // Interrupt while holding the ownership lock: the same Thread must
            // not finish this task and be reused for another call before interrupt.
            worker?.interrupt()
            abortAction.also { abortAction = null }
        }
        finished.countDown()
        abort?.let(pool::abort)
        discard(discarded)
    }

    fun run(ensureActive: () -> Unit = {}, operation: (BoundedNetworkCall<T>) -> T): T {
        synchronized(lock) { check(!started) { "Network call already used" }; started = true }
        try {
            // Caller guards can acquire lifecycle locks. Never invoke them under our lock.
            ensureActive()
            check()
            pool.execute({ perform(operation) }, { finished.countDown() })
            while (true) {
                ensureActive()
                check()
                if (finished.await(timeout(100).toLong(), TimeUnit.MILLISECONDS)) break
            }
            ensureActive()
            check()
            val result = synchronized(lock) {
                if (abandoned) throw BoundedNetworkFailure(BoundedNetworkFailure.Kind.CANCELLED)
                val selected = outcome ?: throw IllegalStateException("Network outcome unavailable")
                outcome = null
                selected
            }
            val error = result.exceptionOrNull()
            if (error != null) {
                if (error is Exception) throw error
                throw IllegalStateException("Network task failed")
            }
            val value = result.getOrThrow()
            try {
                ensureActive()
                check()
                return value
            } catch (failure: Throwable) {
                discard(Result.success(value))
                throw failure
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            throw BoundedNetworkFailure(BoundedNetworkFailure.Kind.CANCELLED)
        } finally {
            cancel()
        }
    }

    private fun perform(operation: (BoundedNetworkCall<T>) -> T) {
        synchronized(lock) {
            if (abandoned) return
            worker = Thread.currentThread()
        }
        val result = runCatching { check(); operation(this) }
        val discarded = synchronized(lock) {
            worker = null
            abortAction = null
            if (abandoned) result else { outcome = result; null }
        }
        discard(discarded)
        // The pool releases admission and signals the caller after this cleanup.
    }

    private fun discard(result: Result<T>?) {
        if (result?.isSuccess == true) {
            try { onDiscard(result.getOrThrow()) } catch (_: Exception) { }
        }
    }
}
