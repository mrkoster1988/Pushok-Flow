package android.os

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

object SystemClock {
    private val elapsedOffset = AtomicLong()
    private val uptimeOffset = AtomicLong()
    fun elapsedRealtime(): Long = System.nanoTime() / 1_000_000 + elapsedOffset.get()
    fun uptimeMillis(): Long = System.nanoTime() / 1_000_000 + uptimeOffset.get()
    fun advanceAwake(ms: Long) { elapsedOffset.addAndGet(ms); uptimeOffset.addAndGet(ms) }
    fun advanceSleep(ms: Long) { elapsedOffset.addAndGet(ms) }
}

class CancellationSignal {
    private val cancelled = AtomicBoolean()
    @Volatile var onCancel: () -> Unit = {}
    @Volatile var cancelledOn: String? = null
    val isCanceled: Boolean get() = cancelled.get()
    fun cancel() {
        if (cancelled.compareAndSet(false, true)) {
            cancelledOn = Thread.currentThread().name
            onCancel()
        }
    }
}

class Looper private constructor() {
    companion object { private val main = Looper(); fun getMainLooper() = main }
}

class Handler(looper: Looper) {
    private data class Pending(val owner: Handler, val runnable: Runnable, val due: Long,
        val sequence: Long, val immediate: Boolean)
    fun post(runnable: Runnable): Boolean = postDelayed(runnable, 0)
    fun postDelayed(runnable: Runnable, delay: Long): Boolean {
        synchronized(queue) { queue += Pending(this, runnable, SystemClock.uptimeMillis() + delay, ++sequence, delay == 0L) }
        return true
    }
    fun removeCallbacks(runnable: Runnable) {
        synchronized(queue) { queue.removeAll { it.owner === this && it.runnable === runnable } }
    }
    companion object {
        private val queue = mutableListOf<Pending>()
        private var sequence = 0L
        fun hasPostedReply(): Boolean = synchronized(queue) {
            queue.any { it.immediate && it.due <= SystemClock.uptimeMillis() }
        }
        fun drain() {
            while (true) {
                val task = synchronized(queue) {
                    queue.filter { it.due <= SystemClock.uptimeMillis() }
                        .minWithOrNull(compareBy<Pending> { it.due }.thenBy { it.sequence })
                        ?.also { queue.remove(it) }
                } ?: return
                task.runnable.run()
            }
        }
        fun advance(ms: Long) { SystemClock.advanceAwake(ms); drain() }
    }
}
