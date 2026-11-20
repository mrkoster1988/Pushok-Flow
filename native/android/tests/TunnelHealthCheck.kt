package shop.pushok.flow

fun main() {
    check(TunnelHealth.uptimeSeconds(false, 100L, 9000L) == 0L)
    check(TunnelHealth.uptimeSeconds(true, null, 9000L) == 0L)
    check(TunnelHealth.uptimeSeconds(true, 2000L, 1999L) == 0L)
    check(TunnelHealth.uptimeSeconds(true, 1000L, 8999L) == 7L)
    val status = TunnelHealth.snapshot(true, false, 1000L, 10500L, null)
    check(status["state"] == "connected")
    check(status["uptimeSeconds"] == 9L)
    check(status.keys == setOf("connected", "state", "uptimeSeconds", "lastErrorCode"))
    check(TunnelHealth.snapshot(false, true, null, 500L, "WG_CONNECT_FAILED")["state"] == "transitioning")
    println("TunnelHealth executable checks passed")
}