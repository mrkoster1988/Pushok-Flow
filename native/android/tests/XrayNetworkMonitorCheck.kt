package shop.pushok.flow

import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkAddress
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.RouteInfo
import android.os.Build
import android.os.Handler
import android.os.ParcelFileDescriptor
import java.net.InetAddress
import java.net.Inet6Address

private fun caps(validated: Boolean = true, unmetered: Boolean = false) = NetworkCapabilities()
    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).apply {
        if (validated) addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        if (unmetered) addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }
private fun links(name: String, dns: String = "192.0.2.53") = LinkProperties.fixture().apply {
    interfaceName = name
    linkAddresses += LinkAddress(InetAddress.getByName("192.0.2.7"), 24)
    dnsServers += InetAddress.getByName(dns)
}

fun main() {
    val handler = Handler()
    val manager = ConnectivityManager()
    val wifi = Network(7)
    val mobile = Network(9)
    manager.capabilities[wifi] = caps(unmetered = true)
    manager.links[wifi] = links("wlan0")
    manager.capabilities[mobile] = caps()
    manager.links[mobile] = links("rmnet0")
    val state = XrayNetworkState<XrayNetworkMonitor.Snapshot>()
    val epoch = state.begin()
    var changes = 0
    val delivered = mutableListOf<XrayNetworkMonitor.Snapshot?>()
    val monitor = XrayNetworkMonitor(manager, handler,
        onChanging = { changes++; state.changing(epoch) },
        onSelected = { delivered += it; state.select(epoch, it) },
    )
    monitor.start()
    check(manager.registrations == 1)
    check(manager.request!!.capabilities == setOf(NetworkCapabilities.NET_CAPABILITY_INTERNET, NetworkCapabilities.NET_CAPABILITY_NOT_VPN))
    // API24 inventory works even when no initial caps/link callbacks are delivered.
    check(delivered.single()?.network === wifi)
    val oldWifi = state.view().selection!!
    val callback = manager.callback!!
    repeat(50) { callback.onCapabilitiesChanged(wifi, caps(unmetered = true)) }
    check(handler.pendingCount == 1)
    handler.runCurrent()
    check(changes == 0 && delivered.size == 1 && handler.pendingCount == 0)

    // Validated mobile replaces an unvalidated Wi-Fi without a core/TUN restart.
    callback.onCapabilitiesChanged(wifi, caps(validated = false, unmetered = true))
    handler.runCurrent()
    check(changes == 1 && state.view().changing && !state.isCurrent(oldWifi))
    check(handler.pendingCount == 1)
    // More events cannot postpone the original bounded timer or duplicate it.
    repeat(50) { callback.onCapabilitiesChanged(wifi, caps(validated = false, unmetered = true)) }
    handler.runCurrent()
    check(handler.pendingCount == 1)
    handler.advanceBy(250)
    check(delivered.last()?.network === mobile)
    val oldMobile = state.view().selection!!

    // Link/DNS changes on the same Network invalidate accepted DNS work too.
    val changedLinks = links("rmnet0", "198.51.100.53")
    callback.onLinkPropertiesChanged(mobile, changedLinks)
    changedLinks.dnsServers.clear() // framework-owned mutable input is copied
    handler.runCurrent()
    check(!state.isCurrent(oldMobile))
    handler.advanceBy(250)
    check(delivered.last()?.network === mobile && delivered.last()!!.links.dnsServers.size == 1)
    check(state.view().selection!!.revision > oldMobile.revision)

    callback.onLost(mobile)
    manager.capabilities.remove(mobile)
    manager.links.remove(mobile)
    handler.runCurrent()
    handler.advanceBy(250)
    check(delivered.last()?.network === wifi) // sole usable unvalidated network allowed
    callback.onLost(wifi)
    manager.capabilities.remove(wifi)
    manager.links.remove(wifi)
    handler.runCurrent()
    handler.advanceBy(250)
    check(delivered.last() == null && state.view().desired && state.view().selection == null)

    // onAvailable alone never queries capabilities from inside the callback.
    callback.onAvailable(wifi)
    handler.runCurrent()
    handler.advanceBy(250)
    check(delivered.last() == null)
    callback.onCapabilitiesChanged(wifi, caps(unmetered = true))
    callback.onLinkPropertiesChanged(wifi, links("wlan0"))
    handler.runCurrent()
    handler.advanceBy(250)
    check(delivered.last()?.network === wifi)
    // Lost/available coalesced before drain must not reuse the prior link/caps.
    callback.onLost(wifi)
    callback.onAvailable(wifi)
    handler.runCurrent()
    handler.advanceBy(250)
    check(delivered.last() == null)

    callback.onCapabilitiesChanged(wifi, caps())
    callback.onLinkPropertiesChanged(wifi, links("wlan0"))
    handler.runCurrent()
    val countBeforeStop = delivered.size
    state.stop() // service invalidates first
    monitor.stop()
    check(manager.unregisters == 1 && handler.pendingCount == 0)
    callback.onAvailable(mobile)
    callback.onCapabilitiesChanged(mobile, caps())
    callback.onLinkPropertiesChanged(mobile, links("rmnet0"))
    handler.advanceBy(1_000)
    check(delivered.size == countBeforeStop && !state.view().desired && handler.pendingCount == 0)

    // A loss during initial inventory wins over its stale returned properties.
    val raceManager = ConnectivityManager()
    raceManager.capabilities[wifi] = caps()
    raceManager.links[wifi] = links("wlan0")
    raceManager.duringInventory = { raceManager.callback!!.onLost(it) }
    val raceReplies = mutableListOf<XrayNetworkMonitor.Snapshot?>()
    val race = XrayNetworkMonitor(raceManager, Handler(), {}, { raceReplies += it })
    race.start()
    check(raceReplies == listOf(null))
    race.stop()

    // Android 7/7.1: a new network can have only an availability callback.
    val legacyManager = ConnectivityManager()
    val legacyHandler = Handler()
    legacyManager.capabilities[wifi] = caps()
    legacyManager.links[wifi] = links("wlan0")
    val legacyReplies = mutableListOf<XrayNetworkMonitor.Snapshot?>()
    val legacy = XrayNetworkMonitor(legacyManager, legacyHandler, {}, { legacyReplies += it })
    legacy.start()
    val legacyCallback = legacyManager.callback!!
    legacyManager.capabilities.remove(wifi)
    legacyManager.links.remove(wifi)
    legacyCallback.onLost(wifi)
    legacyManager.capabilities[mobile] = caps()
    legacyManager.links[mobile] = links("rmnet0")
    legacyCallback.onAvailable(mobile)
    legacyHandler.runCurrent()
    legacyHandler.advanceBy(250)
    check(legacyReplies.last()?.network === mobile)
    // A loss during this later enrichment must also override the returned data.
    legacyManager.capabilities[wifi] = caps(unmetered = true)
    legacyManager.links[wifi] = links("wlan0")
    legacyManager.duringInventory = { if (it === wifi) legacyCallback.onLost(it) }
    legacyCallback.onAvailable(wifi)
    legacyHandler.runCurrent()
    legacyHandler.advanceBy(250)
    check(legacyReplies.last()?.network === mobile)
    legacy.stop()

    // API24 fallback getters may lag behind already delivered callback data.
    // A valid callback must win over stale capabilities and empty link metadata.
    val staleManager = ConnectivityManager()
    val staleHandler = Handler()
    val staleReplies = mutableListOf<XrayNetworkMonitor.Snapshot?>()
    val staleMonitor = XrayNetworkMonitor(staleManager, staleHandler, {}, { staleReplies += it })
    staleMonitor.start()
    staleManager.capabilities[mobile] = caps().removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    staleManager.links[mobile] = LinkProperties.fixture()
    staleManager.callback!!.onAvailable(mobile)
    staleManager.callback!!.onCapabilitiesChanged(mobile, caps())
    staleManager.callback!!.onLinkPropertiesChanged(mobile, links("rmnet0"))
    staleHandler.runCurrent()
    staleHandler.advanceBy(250)
    check(staleReplies.last()?.network === mobile)
    check(staleReplies.last()!!.candidate.internet && staleReplies.last()!!.candidate.linkReady)
    staleMonitor.stop()

    // Actual production binder: exact selected Network, protect first, duplicate
    // closed on success/failure, no duplicate when protection fails.
    ParcelFileDescriptor.duplicates.clear()
    val protected = mutableListOf<Int>()
    check(XrayNetworkSockets.bind(mobile, 42) { protected += it; true })
    val duplicate = ParcelFileDescriptor.duplicates.single()
    check(protected == listOf(42) && duplicate.original == 42 && duplicate.closed)
    check(mobile.bound.single() === duplicate.fileDescriptor && wifi.bound.isEmpty())
    check(!XrayNetworkSockets.bind(wifi, 43) { false })
    check(ParcelFileDescriptor.duplicates.size == 1)
    wifi.failBind = true
    check(!XrayNetworkSockets.bind(wifi, 44) { true })
    check(ParcelFileDescriptor.duplicates.last().closed)
    check(!XrayNetworkSockets.bind(wifi, -1) { error("must not protect invalid FD") })
    check(!XrayNetworkSockets.bind(wifi, Int.MAX_VALUE.toLong() + 1) { error("must not truncate FD") })
    linkSnapshotChecks()
    println("Xray actual Android monitor: API24 inventory, coalescing, handover, stale callbacks and FD binding checks passed")
}

private fun linkSnapshotChecks() {
    val scopedDns = Inet6Address.getByAddress(null, InetAddress.getByName("fe80::53").address, 7)
    fun metadata() = links("wlan0").apply {
        dnsServers += scopedDns
        domains = "example.test"
        routes += RouteInfo.fixture("192.0.2.0/24 via wlan0")
        privateDnsActiveValue = true
        privateDnsServerNameValue = "dns.example.test"
        mtuValue = 1400
        nat64PrefixValue = IpPrefix.fixture("64:ff9b::/96")
    }
    val previousApi = Build.VERSION.SDK_INT
    try {
        for (api in listOf(24, 28, 29, 30)) {
            Build.VERSION.SDK_INT = api
            val handler = Handler()
            val manager = ConnectivityManager()
            val network = Network(api.toLong())
            val original = metadata()
            manager.capabilities[network] = caps()
            manager.links[network] = original
            val deliveries = mutableListOf<XrayNetworkMonitor.Snapshot?>()
            val monitor = XrayNetworkMonitor(manager, handler, {}, { deliveries += it })
            monitor.start()
            val captured = deliveries.single()!!.links
            // Getter guards in the stub fail if production accesses a newer API.
            check(captured.privateDnsActive == (api >= 28))
            check(captured.privateDnsServerName == if (api >= 28) "dns.example.test" else null)
            check(captured.mtu == if (api >= 29) 1400 else null)
            check(captured.nat64Prefix == if (api >= 30) IpPrefix.fixture("64:ff9b::/96") else null)
            original.interfaceName = "changed"
            original.linkAddresses.clear()
            original.dnsServers.clear()
            original.routes.clear()
            original.domains = "changed.test"
            check(captured.interfaceName == "wlan0")
            check(captured.linkAddresses.single().prefixLength == 24)
            check(captured.dnsServers.size == 2 && (captured.dnsServers.last() as Inet6Address).scopeId == 7)
            check(captured.routes == listOf(RouteInfo.fixture("192.0.2.0/24 via wlan0")))
            check(captured.domains == "example.test")
            try {
                (captured.dnsServers as MutableList<*>).clear()
                error("Snapshot DNS list must be immutable")
            } catch (_: UnsupportedOperationException) {}

            val mutations = mutableListOf<(LinkProperties) -> Unit>(
                { it.dnsServers += InetAddress.getByName("198.51.100.53") },
                { it.domains = "other.test" },
                { it.routes += RouteInfo.fixture("0.0.0.0/0 via 192.0.2.1") },
                { it.linkAddresses[0] = LinkAddress(InetAddress.getByName("192.0.2.7"), 25) },
            )
            if (api >= 28) {
                mutations += { it.privateDnsActiveValue = false }
                mutations += { it.privateDnsServerNameValue = "other-dns.example.test" }
            }
            if (api >= 29) mutations += { it.mtuValue = 1420 }
            if (api >= 30) mutations += { it.nat64PrefixValue = IpPrefix.fixture("2001:db8:64::/96") }
            for (mutate in mutations) {
                // Establish an identical baseline before changing exactly one
                // field. Resetting the previous mutation must not be mistaken
                // for evidence that the new field participates in equality.
                manager.callback!!.onLinkPropertiesChanged(network, metadata())
                handler.runCurrent()
                handler.advanceBy(250)
                val next = metadata().apply(mutate)
                val count = deliveries.size
                manager.callback!!.onLinkPropertiesChanged(network, next)
                next.linkAddresses.clear() // callback captures before queueing
                next.dnsServers.clear()
                next.routes.clear()
                handler.runCurrent()
                handler.advanceBy(250)
                check(deliveries.size == count + 1 && deliveries.last()?.network === network)
            }
            monitor.stop()
        }
    } finally { Build.VERSION.SDK_INT = previousApi }
}
