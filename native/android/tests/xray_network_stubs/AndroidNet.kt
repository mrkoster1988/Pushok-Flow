package android.net

import java.io.FileDescriptor
import java.net.InetAddress

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

data class LinkAddress(val address: InetAddress)
class LinkProperties() {
    var interfaceName: String? = null
    val linkAddresses = mutableListOf<LinkAddress>()
    val dnsServers = mutableListOf<InetAddress>()
    constructor(other: LinkProperties) : this() {
        interfaceName = other.interfaceName
        linkAddresses += other.linkAddresses
        dnsServers += other.dnsServers
    }
    override fun equals(other: Any?): Boolean = other is LinkProperties && interfaceName == other.interfaceName &&
        linkAddresses == other.linkAddresses && dnsServers == other.dnsServers
    override fun hashCode(): Int = listOf(interfaceName, linkAddresses, dnsServers).hashCode()
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
