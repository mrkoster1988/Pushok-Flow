package shop.pushok.flow

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Process
import java.net.Proxy
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** A user-initiated check on Flow's VPN network, never on the physical fallback. */
internal object TunnelInternet {
    fun check(context: Context, ownsTunnel: () -> Boolean): String {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val network = manager.activeNetwork ?: return "unknown"
        fun current(): Boolean {
            val caps = manager.getNetworkCapabilities(network) ?: return false
            return ownsTunnel() && manager.activeNetwork == network &&
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                (Build.VERSION.SDK_INT < 29 || caps.ownerUid == Process.myUid())
        }
        if (!current()) return "unknown"
        val url = URL("https://example.com/")
        val addresses = try { network.getAllByName(url.host) } catch (_: Exception) {
            return if (current()) "dns" else "unknown"
        }
        val props = manager.getLinkProperties(network) ?: return "unknown"
        if (addresses.isEmpty() || addresses.any { ip -> props.routes.none { route ->
                route.matches(ip) && route.getInterface() == props.interfaceName
            } }) return "unknown"
        val result = try {
            val conn = network.openConnection(url, Proxy.NO_PROXY) as HttpsURLConnection
            try {
                conn.instanceFollowRedirects = false
                conn.useCaches = false
                conn.connectTimeout = 4500
                conn.readTimeout = 4500
                if (conn.responseCode == 200) "ok" else "https"
            } finally { conn.disconnect() }
        } catch (_: Exception) { "https" }
        return if (current()) result else "unknown"
    }
}
