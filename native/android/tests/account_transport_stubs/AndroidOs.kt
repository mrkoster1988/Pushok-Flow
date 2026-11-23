package android.os

import java.util.concurrent.atomic.AtomicLong

/** Pure transport checks advance the monotonic budget without real network waits. */
object SystemClock {
    private val offset = AtomicLong()
    @JvmStatic fun elapsedRealtime(): Long = System.nanoTime() / 1_000_000L + offset.get()
    fun advance(milliseconds: Long) { offset.addAndGet(milliseconds) }
    fun reset() { offset.set(0) }
}
