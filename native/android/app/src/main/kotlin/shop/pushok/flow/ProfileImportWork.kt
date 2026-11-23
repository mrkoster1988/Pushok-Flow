package shop.pushok.flow

import java.io.Closeable
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Fixed process-wide lanes: provider failures cannot occupy local camera validation. */
internal object ProfileImportWork {
    private class Lane(name: String, workers: Int) {
        private val permits = Semaphore(workers)
        private val sequence = AtomicInteger()
        private val executor = ThreadPoolExecutor(workers, workers, 0L, TimeUnit.MILLISECONDS,
            ArrayBlockingQueue<Runnable>(workers), { action ->
                Thread(action, "$name-${sequence.incrementAndGet()}").apply { isDaemon = true }
            }, ThreadPoolExecutor.AbortPolicy())

        fun reserve(): Boolean = permits.tryAcquire()
        fun release() = permits.release()
        fun launch(action: () -> Unit): Boolean = try {
            executor.execute(action)
            true
        } catch (_: RejectedExecutionException) { false }

        fun attempt(action: () -> Unit) {
            if (!reserve()) return
            if (!launch {
                    try { action() } catch (_: Exception) { }
                    finally { release() }
                }) release()
        }
    }

    private val providers = Lane("pushok-profile-provider", 2)
    private val camera = Lane("pushok-profile-camera", 1)
    private val signals = Lane("pushok-profile-signal", 2)
    private val closers = Lane("pushok-profile-close", 2)

    /** Reserve before the picker opens; a full provider lane fails without another picker. */
    fun reserve(localCamera: Boolean, cancelSignal: () -> Unit): Task? {
        val lane = if (localCamera) camera else providers
        if (!lane.reserve()) return null
        return Task(lane::launch, lane::release,
            if (localCamera) null else cancelSignal)
    }

    class Task internal constructor(
        private val launch: (() -> Unit) -> Boolean,
        private val release: () -> Unit,
        private val cancelSignal: (() -> Unit)?,
    ) {
        private val cancelled = AtomicBoolean()
        private val state = Any()
        private var started = false
        private var finished = false
        private var worker: Thread? = null
        private val resourceLock = Any()
        private val resources = mutableListOf<Closeable>()
        private var closing = false
        private val closed = CountDownLatch(1)

        val isCancelled: Boolean get() = cancelled.get()

        /** Called only by the owning worker. A late-opened resource is closed on that lane. */
        fun attach(resource: Closeable): Boolean {
            val accepted = synchronized(resourceLock) {
                if (isCancelled || closing) false
                else { resources.add(resource); true }
            }
            // Never hold our lock during a provider's close: cancellation must stay fast.
            if (!accepted) safelyClose(resource)
            return accepted
        }

        fun <T> start(operation: (Task) -> T, completion: (Result<T>) -> Unit): Boolean {
            synchronized(state) {
                if (started || finished || isCancelled) return false
                started = true
            }
            val accepted = launch {
                synchronized(state) { worker = Thread.currentThread() }
                val outcome = runCatching {
                    if (isCancelled) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
                    operation(this)
                }
                try {
                    closeResources()
                } finally {
                    finishWorker()
                }
                if (!isCancelled) completion(outcome)
            }
            if (!accepted) finishWorker()
            return accepted
        }

        /** UI-safe and idempotent. Provider cancellation and close never wait on one another. */
        fun cancel() {
            var releaseReserved = false
            val abortStarted = synchronized(state) {
                if (!cancelled.compareAndSet(false, true)) return
                if (finished) false
                else if (!started) {
                    finished = true
                    releaseReserved = true
                    false
                } else {
                    // Ownership lock prevents interrupting this worker after it is reused.
                    worker?.interrupt()
                    true
                }
            }
            if (releaseReserved) release()
            if (abortStarted) {
                cancelSignal?.let { signals.attempt(it) }
                closers.attempt(::closeResources)
            }
        }

        private fun finishWorker() {
            val releaseSlot = synchronized(state) {
                worker = null
                if (finished) false else { finished = true; true }
            }
            if (releaseSlot) release()
        }

        /** One closer owns the resources; the provider slot is retained until it truly ends. */
        private fun closeResources() {
            val owned = synchronized(resourceLock) {
                if (closing) null
                else { closing = true; resources.toList().also { resources.clear() } }
            }
            if (owned != null) {
                try { owned.asReversed().forEach(::safelyClose) }
                finally { closed.countDown() }
            } else {
                var interrupted = false
                while (true) {
                    try { closed.await(); break }
                    catch (_: InterruptedException) { interrupted = true }
                }
                if (interrupted) Thread.currentThread().interrupt()
            }
        }

        private fun safelyClose(resource: Closeable) {
            try { resource.close() } catch (_: Exception) { }
        }
    }
}
