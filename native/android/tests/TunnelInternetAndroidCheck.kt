package shop.pushok.flow

import android.content.Context
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.RouteInfo
import android.os.Build
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.util.Collections
import javax.net.SocketFactory

private fun numeric(address: String) = InetAddress.getByName(address)
private fun fixtureRoute(prefix: String, type: Int = RouteInfo.RTN_UNICAST): RouteInfo {
    val pieces = prefix.split('/')
    return RouteInfo(IpPrefix(numeric(pieces[0]), pieces[1].toInt()), "tun0", type)
}
private class ProbeSockets : SocketFactory() {
    val attempts = Collections.synchronizedList(mutableListOf<InetAddress>())
    override fun createSocket(): Socket = object : Socket() {
        override fun connect(endpoint: SocketAddress, timeout: Int) {
            attempts += (endpoint as InetSocketAddress).address
            throw SocketTimeoutException()
        }
    }
    override fun createSocket(host: String, port: Int): Socket = error("Hostname socket is forbidden")
    override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket = error("DNS socket")
    override fun createSocket(host: InetAddress, port: Int): Socket = error("Unbounded socket")
    override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket = error("Unbounded socket")
}

fun main() {
    val ipv4 = numeric("192.0.2.10")
    val ipv6 = numeric("2001:db8::10")
    for (sdk in listOf(24, 28, 29, 32, 33, 36)) {
        Build.VERSION.SDK_INT = sdk
        val sockets = ProbeSockets()
        val properties = LinkProperties("tun0", listOf(fixtureRoute("0.0.0.0/0"),
            fixtureRoute("::/0", RouteInfo.RTN_UNREACHABLE)))
        val ipv6Only = Network(sockets) { listOf(ipv6) }
        val manager = ConnectivityManager(ipv6Only, properties)
        val context = Context(manager)
        // Android itself adds this unreachable IPv6 default with the VPN interface.
        // It must be rejected before connect, even where getType is unavailable.
        check(TunnelInternet.check(context) { true } == "unknown")
        check(sockets.attempts.isEmpty())
        manager.activeNetwork = Network(sockets) { listOf(ipv6, ipv4) }
        check(TunnelInternet.check(context) { true } == "https")
        check(sockets.attempts == listOf(ipv4)) { "API $sdk tried an unreachable address family" }
        sockets.attempts.clear()
        manager.properties = LinkProperties("tun0", listOf(fixtureRoute("0.0.0.0/0", RouteInfo.RTN_UNREACHABLE),
            fixtureRoute("::/0")))
        check(TunnelInternet.check(context) { true } == "https")
        check(sockets.attempts == listOf(ipv6))
        sockets.attempts.clear()

        manager.capabilities = NetworkCapabilities(vpn = false)
        check(TunnelInternet.check(context) { true } == "unknown")
        check(sockets.attempts.isEmpty())
        if (sdk >= 29) {
            manager.capabilities = NetworkCapabilities(ownerUid = 999)
            check(TunnelInternet.check(context) { true } == "unknown")
            check(sockets.attempts.isEmpty())
        }
        manager.capabilities = NetworkCapabilities()
        manager.properties = properties
        manager.activeNetwork = Network(sockets) {
            manager.properties = LinkProperties("tun0", emptyList())
            listOf(ipv4)
        }
        check(TunnelInternet.check(context) { true } == "unknown")
        check(sockets.attempts.isEmpty()) { "LinkProperties changed during DNS but connect still ran" }

        if (sdk >= 33) {
            manager.properties = LinkProperties("tun0", listOf(fixtureRoute("0.0.0.0/0"),
                fixtureRoute("192.0.2.0/24", RouteInfo.RTN_THROW)))
            manager.activeNetwork = Network(sockets) { listOf(ipv4) }
            check(TunnelInternet.check(context) { true } == "unknown")
            check(sockets.attempts.isEmpty())
        }
    }
    println("Android API 24–36 VPN ownership, unreachable defaults, exclusions and route-change checks passed")
}
