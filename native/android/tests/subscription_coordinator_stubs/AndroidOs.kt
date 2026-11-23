package android.os

import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class Looper {
    companion object {
        private val main = Looper()
        fun getMainLooper() = main
    }
}

class Handler(looper: Looper) {
    // Android Handler.post queues work; it must never execute the callback inline.
    fun post(task: Runnable): Boolean { mainQueue.put(task); return true }
    companion object {
        private val mainQueue = LinkedBlockingQueue<Runnable>()
        fun runNext() = (mainQueue.poll(2, TimeUnit.SECONDS) ?: error("Missing main callback")).run()
        fun takeNextForTest(): Runnable = mainQueue.poll(2, TimeUnit.SECONDS) ?: error("Missing main callback")
        fun clearForTest() { mainQueue.clear() }
        fun pendingForTest() = mainQueue.size
    }
}

object SystemClock { fun elapsedRealtime(): Long = System.nanoTime() / 1000000L }
