package shop.pushok.flow

import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkAddress
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.RouteInfo
import android.os.Build
import android.os.Handler
import android.os.ParcelFileDescriptor
import java.net.InetAddress
import java.util.Collections

/**
 * Observes physical networks even when the app's default network is its VPN.
 * All selection callbacks run on [handler]; only one drain and one settle timer
 * can be pending. The API-21 callback overload also works on Android 7/7.1.
 */
internal class XrayNetworkMonitor(
    private val manager: ConnectivityManager,
    private val handler: Handler,
    private val onChanging: () -> Unit,
    private val onSelected: (Snapshot?) -> Unit,
) {
    data class Snapshot(
        val network: Network,
        val candidate: XrayNetworkPolicy.Candidate,
        val links: LinkSnapshot,
    )

    /** Only public getters; LinkProperties has no public copy constructor. */
    data class LinkSnapshot(
        val interfaceName: String?,
        val linkAddresses: List<LinkAddress>,
        val dnsServers: List<InetAddress>,
        val domains: String?,
        val routes: List<RouteInfo>,
        val privateDnsActive: Boolean,
        val privateDnsServerName: String?,
        val mtu: Int?,
        val nat64Prefix: IpPrefix?,
    ) {
        companion object {
            fun capture(value: LinkProperties): LinkSnapshot = LinkSnapshot(
                interfaceName = value.interfaceName,
                linkAddresses = Collections.unmodifiableList(ArrayList(value.linkAddresses)),
                dnsServers = Collections.unmodifiableList(ArrayList(value.dnsServers)),
                domains = value.domains,
                routes = Collections.unmodifiableList(ArrayList(value.routes)),
                privateDnsActive = Build.VERSION.SDK_INT >= 28 && value.isPrivateDnsActive,
                privateDnsServerName = if (Build.VERSION.SDK_INT >= 28) value.privateDnsServerName else null,
                mtu = if (Build.VERSION.SDK_INT >= 29) value.mtu else null,
                nat64Prefix = if (Build.VERSION.SDK_INT >= 30) value.nat64Prefix else null,
            )
        }
    }

    private data class Entry(
        var capabilities: NetworkCapabilities? = null,
        var links: LinkSnapshot? = null,
        var capabilitiesFromCallback: Boolean = false,
        var linksFromCallback: Boolean = false,
    )
    private data class Update(
        var available: Boolean? = null,
        var fresh: Boolean = false,
        var capabilities: NetworkCapabilities? = null,
        var links: LinkSnapshot? = null,
    )

    private val lock = Any()
    private var active = false
    private var registered = false
    private var drainPosted = false
    private var settling = false
    private val pending = LinkedHashMap<Network, Update>()
    private val entries = LinkedHashMap<Network, Entry>()
    private val refreshNeeded = LinkedHashSet<Network>()
    private var selected: Snapshot? = null
    private val drain = Runnable { drainUpdates() }
    private val settle = Runnable {
        if (isActive()) {
            settling = false
            selected = choose()
            onSelected(selected)
        }
    }
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = enqueue(network) {
            // A reused network notification starts a fresh observation. Data
            // from a lost network must not be combined with a later lifetime.
            Update(available = true, fresh = it.available == false || it.fresh)
        }
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = enqueue(network) {
            if (it.available != false) it.capabilities = NetworkCapabilities(capabilities)
            it
        }
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = enqueue(network) {
            if (it.available != false) it.links = LinkSnapshot.capture(properties)
            it
        }
        override fun onLost(network: Network) = enqueue(network) { Update(available = false) }
    }

    fun start() {
        synchronized(lock) { check(!active); active = true }
        try {
            manager.registerNetworkCallback(
                NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),
                callback,
            )
            registered = true
            // API 24/25 do not guarantee the initial caps/link callbacks. Read an
            // inventory outside callbacks, then overlay already queued events:
            // an onLost during this read must win over a stale inventory entry.
            for (network in manager.allNetworks) {
                val capabilities = manager.getNetworkCapabilities(network) ?: continue
                val links = manager.getLinkProperties(network) ?: continue
                entries[network] = Entry(NetworkCapabilities(capabilities), LinkSnapshot.capture(links))
            }
            mergePending()
            refreshAvailable()
            mergePending()
            scheduleRefreshIfNeeded()
            selected = choose()
            onSelected(selected)
        } catch (failure: Exception) {
            stop()
            throw failure
        }
    }

    fun stop() {
        synchronized(lock) {
            active = false
            pending.clear()
            drainPosted = false
        }
        handler.removeCallbacks(drain)
        handler.removeCallbacks(settle)
        settling = false
        if (registered) {
            registered = false
            try { manager.unregisterNetworkCallback(callback) } catch (_: Exception) {}
        }
        entries.clear()
        refreshNeeded.clear()
        selected = null
    }

    private fun isActive(): Boolean = synchronized(lock) { active }

    private fun enqueue(network: Network, edit: (Update) -> Update) {
        synchronized(lock) {
            if (!active) return
            pending[network] = edit(pending[network] ?: Update())
            if (!drainPosted) {
                drainPosted = true
                handler.post(drain)
            }
        }
    }

    private fun mergePending() {
        val updates = synchronized(lock) {
            handler.removeCallbacks(drain)
            drainPosted = false
            LinkedHashMap(pending).also { pending.clear() }
        }
        for ((network, update) in updates) {
            if (update.available == false) {
                entries.remove(network)
                refreshNeeded.remove(network)
                continue
            }
            val entry = if (update.fresh) Entry().also { entries[network] = it }
                else entries[network] ?: if (update.available == true) Entry().also { entries[network] = it } else continue
            if (update.capabilities != null) {
                entry.capabilities = update.capabilities
                entry.capabilitiesFromCallback = true
            }
            if (update.links != null) {
                entry.links = update.links
                entry.linksFromCallback = true
            }
            if (update.available == true && Build.VERSION.SDK_INT < 26) refreshNeeded += network
        }
    }

    /** API24/25 may emit only onAvailable for networks appearing after start. */
    private fun refreshAvailable() {
        val requested = refreshNeeded.toList()
        refreshNeeded.clear()
        for (network in requested) {
            val entry = entries[network] ?: continue
            val capabilities: NetworkCapabilities?
            val links: LinkProperties?
            try {
                // This runs on the queued handler task, never in onAvailable.
                capabilities = if (entry.capabilitiesFromCallback) null else manager.getNetworkCapabilities(network)
                links = if (entry.linksFromCallback) null else manager.getLinkProperties(network)
            } catch (_: Exception) { continue }
            val unchanged = synchronized(lock) { active && pending[network]?.available == null }
            if (unchanged && entries[network] === entry) {
                // Callback metadata is ordered. Synchronous getter snapshots
                // may lag behind it and must never erase that newer knowledge.
                if (!entry.capabilitiesFromCallback) entry.capabilities = capabilities?.let(::NetworkCapabilities)
                if (!entry.linksFromCallback) entry.links = links?.let { LinkSnapshot.capture(it) }
            }
        }
    }

    private fun scheduleRefreshIfNeeded() {
        synchronized(lock) {
            if (active && refreshNeeded.isNotEmpty() && !drainPosted) {
                drainPosted = true
                handler.post(drain)
            }
        }
    }

    private fun drainUpdates() {
        if (!isActive()) return
        mergePending()
        refreshAvailable()
        // A loss or a newer capability callback during platform reads wins.
        mergePending()
        scheduleRefreshIfNeeded()
        if (!settling && choose() != selected) {
            settling = true
            onChanging()
            // Leading-edge bound: continuous capability changes cannot postpone
            // handover forever. The runnable selects from the newest inventory.
            handler.postDelayed(settle, SETTLE_MS)
        }
    }

    private fun choose(): Snapshot? {
        val snapshots = entries.mapNotNull { (network, entry) ->
            val capabilities = entry.capabilities ?: return@mapNotNull null
            val links = entry.links ?: return@mapNotNull null
            fun has(value: Int) = capabilities.hasCapability(value)
            val candidate = XrayNetworkPolicy.Candidate(
                id = network.networkHandle,
                internet = has(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                notVpn = has(NetworkCapabilities.NET_CAPABILITY_NOT_VPN),
                validated = has(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                captivePortal = has(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
                notMetered = has(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                linkReady = !links.interfaceName.isNullOrEmpty() && links.linkAddresses.any {
                    !it.address.isAnyLocalAddress && !it.address.isLoopbackAddress
                },
            )
            Snapshot(network, candidate, links)
        }
        val candidate = XrayNetworkPolicy.select(snapshots.map { it.candidate }, selected?.candidate?.id) ?: return null
        return snapshots.first { it.candidate.id == candidate.id }
    }

    private companion object { const val SETTLE_MS = 250L }
}

/** A duplicate FD preserves Go's ownership of the original socket on API 24+. */
internal object XrayNetworkSockets {
    fun bind(network: Network, fd: Long, protect: (Int) -> Boolean): Boolean {
        if (fd !in 0..Int.MAX_VALUE.toLong()) return false
        return try {
            if (!protect(fd.toInt())) return false
            ParcelFileDescriptor.fromFd(fd.toInt()).use { network.bindSocket(it.fileDescriptor) }
            true
        } catch (_: Exception) { false }
    }
}
