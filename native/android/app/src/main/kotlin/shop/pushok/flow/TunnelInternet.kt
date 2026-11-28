package shop.pushok.flow

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.RouteInfo
import android.os.Build
import android.os.Process

/** A bounded check on Flow's captured VPN network, never on the physical fallback. */
internal object TunnelInternet {
    fun check(context: Context, ownsTunnel: () -> Boolean): String {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = manager.activeNetwork ?: return "unknown"
        val properties = manager.getLinkProperties(network) ?: return "unknown"
        fun current(): Boolean {
            val caps = manager.getNetworkCapabilities(network) ?: return false
            return ownsTunnel() && manager.activeNetwork == network &&
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                (Build.VERSION.SDK_INT < 29 || caps.ownerUid == Process.myUid()) &&
                manager.getLinkProperties(network) == properties
        }
        if (!current()) return "unknown"
        val routes = TunnelInternetPolicy.Routes(properties.interfaceName, properties.routes.map { route ->
            TunnelInternetPolicy.Route(route.destination.address, route.destination.prefixLength,
                route.getInterface(),
                // Route types and VpnService.excludeRoute became public in API 33.
                // Older Android adds an UNREACHABLE /0 for a blocked family.
                // isDefaultRoute checks UNICAST as well as /0, so it can reject
                // that entry without a hidden API. Flow's other pre-33 routes
                // come from Builder.addRoute and are positive routes.
                if (Build.VERSION.SDK_INT >= 33) route.type == RouteInfo.RTN_UNICAST
                else route.destination.prefixLength != 0 || route.isDefaultRoute)
        })
        return TunnelInternetProbe().check(::current, routes,
            { host -> network.getAllByName(host).toList() }, network.socketFactory)
    }
}
