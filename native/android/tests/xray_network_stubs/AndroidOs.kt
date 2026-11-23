package android.os

import java.io.Closeable
import java.io.FileDescriptor

object Build { object VERSION { var SDK_INT = 24 } }

class Handler {
    private data class Task(val at: Long, val order: Int, val runnable: Runnable)
    private val tasks = mutableListOf<Task>()
    private var nextOrder = 0
    var now = 0L
        private set
    val pendingCount get() = tasks.size
    fun post(runnable: Runnable): Boolean = postDelayed(runnable, 0)
    fun postDelayed(runnable: Runnable, delay: Long): Boolean {
        tasks += Task(now + delay, nextOrder++, runnable)
        return true
    }
    fun removeCallbacks(runnable: Runnable) { tasks.removeAll { it.runnable === runnable } }
    fun runCurrent() {
        while (true) {
            val task = tasks.filter { it.at <= now }.minWithOrNull(compareBy<Task> { it.at }.thenBy { it.order }) ?: return
            tasks.remove(task)
            task.runnable.run()
        }
    }
    fun advanceBy(delay: Long) { now += delay; runCurrent() }
}

class ParcelFileDescriptor private constructor(val original: Int) : Closeable {
    val fileDescriptor = FileDescriptor()
    var closed = false
        private set
    override fun close() { closed = true }
    companion object {
        val duplicates = mutableListOf<ParcelFileDescriptor>()
        var failDuplicate = false
        fun fromFd(fd: Int): ParcelFileDescriptor {
            if (failDuplicate) throw java.io.IOException("synthetic")
            return ParcelFileDescriptor(fd).also { duplicates += it }
        }
    }
}
