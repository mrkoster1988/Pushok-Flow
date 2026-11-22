package shop.pushok.flow

import java.util.concurrent.CountDownLatch

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
    println("Xray deadline, concurrent cancellation, generation and teardown state checks passed")
}
