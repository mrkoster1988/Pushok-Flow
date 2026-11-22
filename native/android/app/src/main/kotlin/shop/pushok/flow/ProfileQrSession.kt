package shop.pushok.flow

/** An editor owns its camera request; stale activities cannot revive or complete a newer request. */
class ProfileQrSession {
    private var current: Int? = null
    private var listener: (() -> Unit)? = null

    @Synchronized fun begin(code: Int): Boolean {
        if (current != null) return false
        current = code
        return true
    }

    @Synchronized fun isActive(code: Int): Boolean = current == code

    @Synchronized fun watch(code: Int, cancellation: () -> Unit): Boolean {
        if (current != code) return false
        listener = cancellation
        return true
    }

    @Synchronized fun unwatch(code: Int, cancellation: () -> Unit) {
        if (current == code && listener === cancellation) listener = null
    }

    fun end(code: Int) {
        val callback = synchronized(this) {
            if (current != code) return
            current = null
            listener.also { listener = null }
        }
        callback?.invoke()
    }
}
