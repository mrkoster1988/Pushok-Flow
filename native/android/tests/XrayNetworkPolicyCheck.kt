package shop.pushok.flow

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private fun candidate(id: Long, validated: Boolean = true, unmetered: Boolean = false) =
    XrayNetworkPolicy.Candidate(id, internet = true, notVpn = true, validated = validated,
        captivePortal = false, notMetered = unmetered, linkReady = true)

fun main() {
    val wifi = candidate(7, unmetered = true)
    val mobile = candidate(9)
    check(XrayNetworkPolicy.select(listOf(mobile, wifi), null) == wifi)
    // Wi-Fi has no hard-coded advantage. Validation outranks cost and current.
    check(XrayNetworkPolicy.select(listOf(wifi.copy(validated = false), mobile), wifi.id) == mobile)
    check(XrayNetworkPolicy.select(listOf(wifi.copy(notMetered = false), mobile), mobile.id) == mobile)
    check(XrayNetworkPolicy.select(listOf(wifi.copy(notMetered = false), mobile), null)?.id == 7L)
    // A filtered Android probe must not prohibit the only usable physical link.
    check(XrayNetworkPolicy.select(listOf(wifi.copy(validated = false)), null)?.id == wifi.id)
    for (rejected in listOf(wifi.copy(internet = false), wifi.copy(notVpn = false),
        wifi.copy(linkReady = false), wifi.copy(captivePortal = true))) {
        check(XrayNetworkPolicy.select(listOf(rejected), rejected.id) == null)
    }

    val state = XrayNetworkState<String>()
    check(!state.view().desired && state.view().selection == null)
    val first = state.begin()
    val a = state.select(first, "wifi")!!
    check(state.isCurrent(a) && state.useCurrent(a) { it == "wifi" })
    // A DNS request accepted on A must not publish on B, nor when A returns.
    check(state.changing(first) && !state.isCurrent(a) && state.view().changing)
    val b = state.select(first, "mobile")!!
    check(!state.isCurrent(a) && state.isCurrent(b))
    val aAgain = state.select(first, "wifi")!!
    check(!state.isCurrent(a) && !state.isCurrent(b) && state.isCurrent(aAgain))
    check(aAgain.revision > b.revision && b.revision > a.revision)
    state.select(first, null)
    check(state.view().desired && !state.view().changing && state.view().selection == null)
    state.fail(first)
    check(state.view().failed && state.view().selection == null)

    state.stop()
    check(!state.owns(first) && !state.view().desired)
    var effects = 0
    check(!state.useCurrent(aAgain) { effects++; true })
    check(!state.update(first) { effects++; true })
    check(state.select(first, "late") == null)
    check(!state.changing(first))
    state.fail(first)
    check(!state.view().failed && effects == 0)
    val second = state.begin()
    check(second != first)
    val current = state.select(second, "new-session")!!
    check(!state.isCurrent(aAgain) && state.isCurrent(current))

    // Actual production callback gate: an in-flight platform bind cannot hold
    // STOP hostage, and its late return cannot authorize the socket's connect.
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    var accepted = true
    val binding = Thread {
        accepted = state.useCurrent(current) { entered.countDown(); release.await(); true }
    }
    binding.start()
    check(entered.await(2, TimeUnit.SECONDS))
    val stopped = CountDownLatch(1)
    val stopping = Thread { state.stop(); stopped.countDown() }
    stopping.start()
    val stoppedPromptly = stopped.await(2, TimeUnit.SECONDS)
    release.countDown()
    binding.join(2_000)
    stopping.join(2_000)
    check(stoppedPromptly && !binding.isAlive && !accepted)
    check(!state.view().desired && state.view().selection == null)
    statusChecks()
    println("Xray physical-network selection, epoch, stale DNS/socket and nonblocking STOP checks passed")
}

private fun statusChecks() {
    fun status(occupied: Boolean = true, blocked: Boolean = false, core: Boolean = true,
        starting: Boolean = false, changing: Boolean = false, network: Boolean = true) =
        XrayServiceStatus.read(occupied, blocked, core, starting, changing, network)
    val up = status()
    check(up.connected && up.ownsTunnel && up.state == "connected" && up.needsNativeProbe)
    val idle = status(occupied = false, core = false, network = false)
    check(!idle.connected && !idle.ownsTunnel && idle.state == "disconnected" && idle.needsNativeProbe)
    val waiting = status(network = false)
    check(!waiting.connected && waiting.ownsTunnel && waiting.state == "waiting_network")
    // The actual STATUS branch uses this property, avoiding native DOWN cleanup
    // and a queue wait which could otherwise prevent a timely manual STOP.
    check(!waiting.needsNativeProbe && waiting.error == null)
    for (reconnecting in listOf(status(changing = true), status(core = false, starting = true))) {
        check(!reconnecting.connected && reconnecting.ownsTunnel && reconnecting.state == "reconnecting")
        check(!reconnecting.needsNativeProbe && reconnecting.error == null)
    }
    for (unknown in listOf(status(blocked = true), status(core = false))) {
        check(!unknown.connected && unknown.ownsTunnel && unknown.state == "unknown")
        check(!unknown.needsNativeProbe && unknown.error == "XRAY_STATE_UNAVAILABLE")
    }
    // A native UP sampled before handover does not bypass a fresh main-thread
    // network read at delivery. User and network generations remain separate.
    val state = XrayNetworkState<String>()
    val epoch = state.begin()
    state.select(epoch, "wifi")
    fun read() = state.view().let { status(occupied = it.desired, changing = it.changing, network = it.selection != null) }
    val nativeProbeQueued = read()
    check(nativeProbeQueued.needsNativeProbe && nativeProbeQueued.connected)
    state.changing(epoch)
    check(read().state == "reconnecting" && !read().connected)
    state.select(epoch, null)
    check(read().state == "waiting_network" && !read().connected && read().ownsTunnel)
    check(!up.withFailure("XRAY_STATE_UNAVAILABLE").connected)
    check(up.withFailure("XRAY_STATE_UNAVAILABLE").ownsTunnel)
}
