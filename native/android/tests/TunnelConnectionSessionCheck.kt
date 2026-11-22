package shop.pushok.flow

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private fun rejects(code: String, action: () -> Unit) {
    try {
        action()
        error("Expected $code")
    } catch (failure: TunnelConnectionFailure) {
        check(failure.code == code)
        check(failure.message == code && failure.cause == null)
    }
}

private fun withSession(action: (TunnelConnectionSession, (Long) -> Unit) -> Unit) {
    var now = 1000L
    val session = TunnelConnectionSession(nowElapsedMs = { now })
    try { action(session) { now = it } }
    finally { session.io.shutdownNow() }
}

fun main() {
    // The same actual-UP Connect from a replacement screen is idempotent. Its
    // fresh Config must never tear down/recreate the already-running backend.
    withSession { session, advance ->
        var actual = false
        var starts = 0
        val read = { actual }
        check(session.connect(read) { starts++; actual = true; true })
        check(session.connected && session.connectedSinceElapsedMs == 1000L)
        advance(9000L)
        check(session.connect(read) { starts++; actual = true; true })
        check(starts == 1 && session.connectedSinceElapsedMs == 1000L)

        // Failure while preparing a configuration cannot mark the live tunnel
        // DOWN or discard its existing uptime.
        session.failedConnect(read)
        check(session.connected && session.connectedSinceElapsedMs == 1000L)
        check(session.lastErrorCode == "WG_CONNECT_FAILED")
        session.failedConnect { error("PRIVATE_PROFILE") }
        check(session.connected && session.connectedSinceElapsedMs == 1000L)
        val unavailable = session.observe { error("PRIVATE_ENDPOINT") }
        check(!unavailable.known && unavailable.connected)

        rejects("VPN_STATE_UNAVAILABLE") {
            session.connect({ error("PRIVATE_KEY") }) { starts++; true }
        }
        check(starts == 1 && session.connected && session.connectedSinceElapsedMs == 1000L)

        // Disconnect remains callable when status cannot currently be read.
        var reads = 0
        session.disconnect({ reads++; error("PRIVATE_PROFILE") }) { actual = false; false }
        check(reads == 0 && !actual && !session.connected)
        check(session.connectedSinceElapsedMs == null && session.lastErrorCode == null)
    }

    // Unknown at startup does not authorize a new connection and must not be
    // treated as confirmed DOWN by the caller.
    withSession { session, _ ->
        var starts = 0
        rejects("VPN_STATE_UNAVAILABLE") {
            session.connect({ error("PRIVATE_BACKEND") }) { starts++; true }
        }
        check(starts == 0 && !session.observe { error("PRIVATE_BACKEND") }.known)
    }

    // A backend may restore/report UP while still throwing from setState. Keep
    // the observed active state; do not invent a precise start time for it.
    withSession { session, _ ->
        var actual = false
        rejects("WG_CONNECT_FAILED") {
            session.connect({ actual }) {
                actual = true
                error("PRIVATE_ROLLBACK_CONFIG")
            }
        }
        check(session.connected && session.connectedSinceElapsedMs == null)
        check(session.lastErrorCode == "WG_CONNECT_FAILED")
        session.disconnect({ actual }) { actual = false; false }
        check(!session.connected && session.lastErrorCode == null)
    }

    // A thrown activation and a non-UP return are both failures. Reconciliation
    // preserves confirmed DOWN instead of claiming an established connection.
    for (throws in listOf(true, false)) withSession { session, _ ->
        rejects("WG_CONNECT_FAILED") {
            session.connect({ false }) {
                if (throws) error("PRIVATE_FAILURE") else false
            }
        }
        check(!session.connected && session.connectedSinceElapsedMs == null)
    }

    // If both activation and its subsequent state read fail after known DOWN,
    // there is no evidence of UP. Retain the boolean but expose unknown, never
    // a confirmed disconnect or a fabricated last-known active connection.
    withSession { session, _ ->
        var readable = true
        val read = { if (readable) false else error("PRIVATE_READ_FAILURE") }
        rejects("WG_CONNECT_FAILED") {
            session.connect(read) { readable = false; error("PRIVATE_ACTIVATION_FAILURE") }
        }
        val ambiguous = session.observe(read)
        check(!ambiguous.known && !ambiguous.connected)
        check(session.connectedSinceElapsedMs == null && session.lastErrorCode == "WG_CONNECT_FAILED")
    }

    withSession { session, _ ->
        var actual = false
        session.connect({ actual }) { actual = true; true }
        rejects("WG_DISCONNECT_FAILED") {
            session.disconnect({ actual }) { error("PRIVATE_FAILURE") }
        }
        check(session.connected && session.connectedSinceElapsedMs == 1000L)
        check(session.lastErrorCode == "WG_DISCONNECT_FAILED")
        // The returned state itself must also confirm DOWN.
        rejects("WG_DISCONNECT_FAILED") {
            session.disconnect({ actual }) { true }
        }
        check(session.connected)
        rejects("WG_DISCONNECT_FAILED") {
            session.disconnect({ error("PRIVATE_FAILURE") }) { error("PRIVATE_FAILURE") }
        }
        check(session.connected && session.connectedSinceElapsedMs == 1000L)
        // If DOWN really happened before the exception, the subsequent read is
        // valid evidence even though the operation still reports failure.
        rejects("WG_DISCONNECT_FAILED") {
            session.disconnect({ actual }) { actual = false; error("PRIVATE_FAILURE") }
        }
        check(!session.connected && session.connectedSinceElapsedMs == null)
    }

    withSession { session, _ ->
        var actual = false
        session.connect({ actual }) { actual = true; true }
        actual = false // Android/service stopped the tunnel independently.
        val stopped = session.observe { actual }
        check(stopped.known && !stopped.connected && session.connectedSinceElapsedMs == null)
    }

    // Two Activity-like clients use the production session queue. Hold an old
    // DOWN observation in flight, enqueue a replacement client's Connect, then
    // prove the old observation cannot complete after the new connection.
    withSession { session, _ ->
        val actual = AtomicBoolean(false)
        val oldReadStarted = CountDownLatch(1)
        val finishOldRead = CountDownLatch(1)
        val newConnectStarted = CountDownLatch(1)
        var oldThread: Thread? = null
        var newThread: Thread? = null
        val oldClient = session.io
        val newClient = session.io
        val oldStatus = oldClient.submit<TunnelConnectionSession.Observation> {
            oldThread = Thread.currentThread()
            session.observe {
                val capturedDown = actual.get()
                oldReadStarted.countDown()
                check(finishOldRead.await(5, TimeUnit.SECONDS))
                capturedDown
            }
        }
        check(oldReadStarted.await(5, TimeUnit.SECONDS))
        val newConnection = newClient.submit<Boolean> {
            newThread = Thread.currentThread()
            newConnectStarted.countDown()
            session.connect({ actual.get() }) { actual.set(true); true }
        }
        try {
            check(!newConnectStarted.await(100, TimeUnit.MILLISECONDS))
        } finally { finishOldRead.countDown() }
        check(!oldStatus.get(5, TimeUnit.SECONDS).connected)
        check(newConnection.get(5, TimeUnit.SECONDS))
        check(oldThread != null && oldThread === newThread)
        check(actual.get() && session.connected && session.connectedSinceElapsedMs == 1000L)
    }
    println("TunnelConnectionSession state, failure recovery and shared queue checks passed")
}
