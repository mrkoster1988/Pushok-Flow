package android.net

import java.net.InetAddress
import javax.net.SocketFactory

class IpPrefix(val address: InetAddress, val prefixLength: Int)
class RouteInfo(val destination: IpPrefix, private val device: String?, val type: Int = RTN_UNICAST) {
    companion object {
        const val RTN_UNICAST = 1
        const val RTN_UNREACHABLE = 7
        const val RTN_THROW = 9
    }
    fun getInterface(): String? = device
    // This is the public pre-33 AOSP predicate, including route type.
    val isDefaultRoute get() = type == RTN_UNICAST && destination.prefixLength == 0
}
data class LinkProperties(val interfaceName: String?, val routes: List<RouteInfo>)
class NetworkCapabilities(val ownerUid: Int = 12345, private val vpn: Boolean = true) {
    companion object { const val TRANSPORT_VPN = 4 }
    fun hasTransport(transport: Int) = vpn && transport == TRANSPORT_VPN
}
class Network(val socketFactory: SocketFactory, private val resolver: (String) -> List<InetAddress>) {
    fun getAllByName(host: String) = resolver(host).toTypedArray()
}
class ConnectivityManager(
    @Volatile var activeNetwork: Network?,
    @Volatile var properties: LinkProperties?,
    var capabilities: NetworkCapabilities? = NetworkCapabilities(),
) {
    fun getLinkProperties(network: Network) = if (network == activeNetwork) properties else null
    fun getNetworkCapabilities(network: Network) = if (network == activeNetwork) capabilities else null
}
