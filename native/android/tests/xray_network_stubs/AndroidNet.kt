package android.net

import java.io.FileDescriptor
import java.net.InetAddress
import android.os.Build

class Network(val networkHandle: Long) {
    val bound = mutableListOf<FileDescriptor>()
    var failBind = false
    fun bindSocket(fd: FileDescriptor) {
        if (failBind) throw java.io.IOException("synthetic")
        bound += fd
    }
}

class NetworkCapabilities() {
    private val capabilities = mutableSetOf<Int>()
    constructor(other: NetworkCapabilities) : this() { capabilities += other.capabilities }
    fun addCapability(value: Int): NetworkCapabilities { capabilities += value; return this }
    fun removeCapability(value: Int): NetworkCapabilities { capabilities -= value; return this }
    fun hasCapability(value: Int) = value in capabilities
    companion object {
        const val NET_CAPABILITY_INTERNET = 12
        const val NET_CAPABILITY_NOT_VPN = 15
        const val NET_CAPABILITY_VALIDATED = 16
        const val NET_CAPABILITY_CAPTIVE_PORTAL = 17
        const val NET_CAPABILITY_NOT_METERED = 11
    }
}

data class LinkAddress(val address: InetAddress, val prefixLength: Int)
class RouteInfo private constructor(private val value: String) {
    override fun equals(other: Any?): Boolean = other is RouteInfo && value == other.value
    override fun hashCode(): Int = value.hashCode()
    companion object { fun fixture(value: String) = RouteInfo(value) }
}
class IpPrefix private constructor(private val value: String) {
    override fun equals(other: Any?): Boolean = other is IpPrefix && value == other.value
    override fun hashCode(): Int = value.hashCode()
    companion object { fun fixture(value: String) = IpPrefix(value) }
}
// API24 exposes no public LinkProperties constructor. Only tests create fixtures;
// production copy/no-arg constructor calls must fail this compilation gate.
class LinkProperties private constructor() {
    var interfaceName: String? = null
    val linkAddresses = mutableListOf<LinkAddress>()
    val dnsServers = mutableListOf<InetAddress>()
    var domains: String? = null
    val routes = mutableListOf<RouteInfo>()
    var privateDnsActiveValue = false
    var privateDnsServerNameValue: String? = null
    var mtuValue = 0
    var nat64PrefixValue: IpPrefix? = null
    val isPrivateDnsActive: Boolean get() { check(Build.VERSION.SDK_INT >= 28); return privateDnsActiveValue }
    val privateDnsServerName: String? get() { check(Build.VERSION.SDK_INT >= 28); return privateDnsServerNameValue }
    val mtu: Int get() { check(Build.VERSION.SDK_INT >= 29); return mtuValue }
    val nat64Prefix: IpPrefix? get() { check(Build.VERSION.SDK_INT >= 30); return nat64PrefixValue }
    companion object { fun fixture() = LinkProperties() }
}

class NetworkRequest(val capabilities: Set<Int>) {
    class Builder {
        private val capabilities = mutableSetOf<Int>()
        fun addCapability(value: Int): Builder { capabilities += value; return this }
        fun build() = NetworkRequest(capabilities.toSet())
    }
}

class ConnectivityManager {
    open class NetworkCallback {
        open fun onAvailable(network: Network) {}
        open fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {}
        open fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {}
        open fun onLost(network: Network) {}
    }
    val capabilities = linkedMapOf<Network, NetworkCapabilities>()
    val links = linkedMapOf<Network, LinkProperties>()
    var callback: NetworkCallback? = null
    var request: NetworkRequest? = null
    var registrations = 0
    var unregisters = 0
    var duringInventory: ((Network) -> Unit)? = null
    val allNetworks: Array<Network> get() = capabilities.keys.toTypedArray()
    fun getNetworkCapabilities(network: Network): NetworkCapabilities? = capabilities[network]
    fun getLinkProperties(network: Network): LinkProperties? {
        duringInventory?.invoke(network)
        return links[network]
    }
    // Intentionally no Handler overload: compile proves the API-24-compatible call.
    fun registerNetworkCallback(request: NetworkRequest, callback: NetworkCallback) {
        this.request = request; this.callback = callback; registrations++
    }
    fun unregisterNetworkCallback(callback: NetworkCallback) {
        check(this.callback === callback)
        unregisters++
        this.callback = null
    }
}
