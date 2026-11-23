package shop.pushok.flow

import java.util.concurrent.CountDownLatch
import java.util.ArrayDeque

private fun failure(code: String, action: () -> Unit) {
    try { action(); error("Expected $code") }
    catch (error: XrayTunnelFailure) { check(error.code == code) }
}

fun main() {
    var now = 100L
    val leases = XrayRequestLease { now }
    val first = leases.invalidate()
    leases.requireCurrent(first, 200)
    now = 200
    failure("XRAY_TIMEOUT") { leases.requireCurrent(first, 200) }
    now = 201
    failure("XRAY_TIMEOUT") { leases.requireCurrent(first, 200) }

    // Hold native startup across a concurrent cancellation. A late return cannot publish UP.
    now = 300
    val second = leases.invalidate()
    val entered = CountDownLatch(1)
    val resume = CountDownLatch(1)
    var publishedUp = false
    var rejection: String? = null
    val native = Thread {
        leases.requireCurrent(second, 1000)
        entered.countDown()
        resume.await()
        try { leases.requireCurrent(second, 1000); publishedUp = true }
        catch (error: XrayTunnelFailure) { rejection = error.code }
    }
    native.start()
    entered.await()
    leases.invalidate()
    resume.countDown()
    native.join()
    check(!publishedUp && rejection == "XRAY_TIMEOUT")
    val third = leases.invalidate()
    leases.requireCurrent(third, 1000)
    failure("XRAY_TIMEOUT") { leases.requireCurrent(second, 1000) }

    check(!XrayRequestLease.knownState(false, false, false))
    check(XrayRequestLease.knownState(true, true, true))
    check(!XrayRequestLease.knownState(true, true, false))
    // Native owns a duplicate TUN until stopXray succeeds. Do not call this DOWN.
    failure("XRAY_STATE_UNAVAILABLE") { XrayRequestLease.knownState(false, true, true) }
    failure("XRAY_STATE_UNAVAILABLE") { XrayRequestLease.knownState(false, true, false) }
    check(!XrayRequestLease.knownState(false, false, false))
    queuedCompletionChecks()
    println("Xray deadline, concurrent cancellation, generation and teardown state checks passed")
}

/** Manual worker/main queues exercise the same startup and delivery policy as the service. */
private class DeliveryHarness {
    data class Reply(val id: Int, val connected: Boolean, val error: String?)
    var now = 100L
    val lease = XrayRequestLease { now }
    private val worker = ArrayDeque<() -> Unit>()
    private val main = ArrayDeque<() -> Unit>()
    val replies = mutableListOf<Reply>()
    var connected = false
    var nativeActive = false
    var destroyed = false
    var stopping = false
    var startingId = 0
    var notifications = 0
    var finishes = 0
    var cleanups = 0
    var activations = 0
    var stops = 0
    var notify: (() -> Unit)? = null
    private var nextId = 0

    fun stop() {
        lease.invalidate()
        stopping = true
        startingId = 0
        connected = false
        nativeActive = false
        stops++
    }

    fun start(deadline: Long = 1000, requestId: Int? = null, duringActivation: () -> Unit = {}): Int {
        check(!stopping && !destroyed)
        val id = requestId ?: ++nextId
        val generation = lease.invalidate()
        startingId = id
        worker.addLast {
            val completion = lease.runStart(
                generation, deadline,
                readConnected = { connected },
                activate = {
                    XrayRequestLease.knownState(false, nativeActive, false)
                    activations++
                    duringActivation()
                    connected = true
                    nativeActive = true
                },
                cleanup = { cleanups++; connected = false; nativeActive = false },
                errorCode = { (it as? XrayTunnelFailure)?.code ?: "XRAY_CONNECT_FAILED" },
            )
            main.addLast {
                lease.deliver(
                    completion,
                    available = { available(completion) },
                    reply = { up, error ->
                        if (lease.owns(generation) && startingId == id) startingId = 0
                        replies += Reply(id, up, error)
                    },
                    onUp = { notifications++; notify?.invoke() },
                    onDown = { stopping = true; finishes++; connected = false },
                    onExpired = ::stop,
                )
            }
        }
        return id
    }

    fun status(deadline: Long = 1000): Int {
        val id = ++nextId
        // This is captured before enqueueing, just as in the real IPC receiver.
        val generation = lease.current()
        worker.addLast {
            val completion = try {
                if (!lease.owns(generation)) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
                XrayRequestLease.Completion(generation, deadline,
                    XrayRequestLease.knownState(connected, nativeActive, nativeActive))
            } catch (_: XrayTunnelFailure) {
                XrayRequestLease.Completion(generation, deadline, false, "XRAY_STATE_UNAVAILABLE")
            }
            main.addLast {
                lease.deliver(
                    completion,
                    available = { available(completion) },
                    reply = { up, error -> replies += Reply(id, up, error) },
                    onDown = { if (completion.error == null && startingId == 0) finishes++ },
                )
            }
        }
        return id
    }

    private fun available(completion: XrayRequestLease.Completion) =
        !destroyed && (!completion.connected || (!stopping && connected && nativeActive))

    fun runWorker() { while (worker.isNotEmpty()) worker.removeFirst().invoke() }
    fun deliverOne() { main.removeFirst().invoke() }
    fun deliverAll() { while (main.isNotEmpty()) deliverOne() }
}

private fun queuedCompletionChecks() {
    // A worker-confirmed UP does not survive a revoke before main delivery.
    DeliveryHarness().apply {
        connected = true; nativeActive = true
        val request = status()
        runWorker()
        stop()
        deliverAll()
        check(replies == listOf(DeliveryHarness.Reply(request, false, "XRAY_STATE_UNAVAILABLE")))
        check(finishes == 0 && notifications == 0)
    }

    // Old DOWN must neither adopt a new START's generation nor finish its service.
    for (sampleBeforeStart in listOf(false, true)) DeliveryHarness().apply {
        val oldStatus = status()
        if (sampleBeforeStart) runWorker()
        val latestStart = start()
        runWorker()
        deliverAll()
        check(replies == listOf(
            DeliveryHarness.Reply(oldStatus, false, "XRAY_STATE_UNAVAILABLE"),
            DeliveryHarness.Reply(latestStart, true, null),
        ))
        check(connected && !stopping && finishes == 0 && notifications == 1)
    }

    // A superseded START must not report another START's UP or clear its watchdog.
    DeliveryHarness().apply {
        val oldStart = start()
        runWorker()
        val latestStart = start()
        runWorker()
        deliverOne()
        check(startingId == latestStart && notifications == 0 && finishes == 0)
        check(replies == listOf(DeliveryHarness.Reply(oldStart, false, "XRAY_STATE_UNAVAILABLE")))
        deliverAll()
        check(replies.last() == DeliveryHarness.Reply(latestStart, true, null))
        check(startingId == 0 && connected && activations == 1)
    }
    DeliveryHarness().apply {
        start(requestId = 7)
        runWorker()
        start(requestId = 7) // A replacement UI process can restart its sequence.
        runWorker()
        deliverOne()
        check(startingId == 7 && notifications == 0 && finishes == 0)
        check(replies.single() == DeliveryHarness.Reply(7, false, "XRAY_STATE_UNAVAILABLE"))
        deliverAll()
        check(startingId == 0 && connected && notifications == 1)
        check(replies.last() == DeliveryHarness.Reply(7, true, null))
    }

    // A new receive can interleave while the old native activation fails. The
    // actual worker policy cleans the old attempt before running the queued one;
    // the old main callback cannot set a stopping latch or finish the new core.
    DeliveryHarness().apply {
        var latestStart = 0
        val oldStart = start(duringActivation = {
            latestStart = start()
            throw XrayTunnelFailure("XRAY_CONNECT_FAILED")
        })
        runWorker()
        check(cleanups == 1 && activations == 2 && connected)
        deliverAll()
        check(replies == listOf(
            DeliveryHarness.Reply(oldStart, false, "XRAY_STATE_UNAVAILABLE"),
            DeliveryHarness.Reply(latestStart, true, null),
        ))
        check(!stopping && finishes == 0 && notifications == 1 && connected)
    }

    // Startup is not acknowledged until main delivery. A completed native call
    // whose reply waits past the deadline cannot leave an ownerless active core.
    DeliveryHarness().apply {
        val request = start(deadline = 200)
        runWorker()
        check(startingId == request && connected)
        now = 200
        deliverAll()
        check(replies == listOf(DeliveryHarness.Reply(request, false, "XRAY_TIMEOUT")))
        check(stops == 1 && !connected && startingId == 0 && notifications == 0)
    }

    // Expiration of an older generation cannot run its teardown against a new one.
    DeliveryHarness().apply {
        val old = start(deadline = 200)
        runWorker()
        now = 201
        val latest = start(deadline = 1000)
        runWorker()
        deliverAll()
        check(replies.first() == DeliveryHarness.Reply(old, false, "XRAY_STATE_UNAVAILABLE"))
        check(replies.last() == DeliveryHarness.Reply(latest, true, null))
        check(stops == 0 && finishes == 0 && connected)
    }

    // Foreground-notification failure revokes the lease before success delivery.
    DeliveryHarness().apply {
        notify = { stop() }
        val request = start()
        runWorker(); deliverAll()
        check(replies == listOf(DeliveryHarness.Reply(request, false, "XRAY_STATE_UNAVAILABLE")))
        check(!connected && stops == 1 && finishes == 0)
    }
    for (unavailable in listOf("stopping", "destroyed")) DeliveryHarness().apply {
        val request = start()
        runWorker()
        if (unavailable == "stopping") stopping = true else destroyed = true
        deliverAll()
        check(replies == listOf(DeliveryHarness.Reply(request, false, "XRAY_STATE_UNAVAILABLE")))
        check(notifications == 0 && finishes == 0)
    }

    // Current idle STATUS still completes; unknown state must never authorize finish.
    DeliveryHarness().apply {
        val request = status()
        runWorker(); deliverAll()
        check(replies == listOf(DeliveryHarness.Reply(request, false, null)) && finishes == 1)
    }
    DeliveryHarness().apply {
        val request = status(deadline = 200)
        runWorker()
        now = 200
        deliverAll()
        check(replies == listOf(DeliveryHarness.Reply(request, false, "XRAY_TIMEOUT")))
        check(finishes == 0 && stops == 0)
    }
    DeliveryHarness().apply {
        nativeActive = true
        val request = status()
        runWorker(); deliverAll()
        check(replies == listOf(DeliveryHarness.Reply(request, false, "XRAY_STATE_UNAVAILABLE")))
        check(finishes == 0)
    }
    DeliveryHarness().apply {
        val request = start(duringActivation = { throw XrayTunnelFailure("ROUTES_APPS_UNAVAILABLE") })
        runWorker(); deliverAll()
        check(replies == listOf(DeliveryHarness.Reply(request, false, "ROUTES_APPS_UNAVAILABLE")))
        check(cleanups == 1 && finishes == 1 && stopping && !connected)
    }
}
