package shop.pushok.flow

import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.os.Build
import com.wireguard.android.backend.GoBackend
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket

internal object BrowserSites {
    private val catalogue = linkedMapOf("gosuslugi.ru" to "Госуслуги","pochta.ru" to "Почта России",
        "rzd.ru" to "РЖД","2gis.ru" to "2ГИС","ozon.ru" to "Ozon","wildberries.ru" to "Wildberries",
        "tbank.ru" to "Т-Банк","sberbank.ru" to "Сбер","vtb.ru" to "ВТБ","alfabank.ru" to "Альфа-Банк",
        "vk.com" to "ВКонтакте","max.ru" to "MAX")
    private fun settings(c:Context)=c.getSharedPreferences("flow_browser_routes",Context.MODE_PRIVATE)
    fun selected(c:Context):Set<String> = settings(c).getStringSet("domains",catalogue.keys).orEmpty().intersect(catalogue.keys)
    // The previous default implicitly installed a system-wide HTTP proxy.
    // Existing selections are preserved, but activation now requires explicit opt-in.
    fun enabled(c:Context):Boolean = settings(c).getBoolean("proxy_enabled", false)
    fun register(c:Context,messenger:BinaryMessenger) {
        MethodChannel(messenger,"shop.pushok.flow/browser_routes").setMethodCallHandler { call,result ->
            when(call.method){
                "read" -> result.success(mapOf("available" to (Build.VERSION.SDK_INT>=29),"names" to catalogue,"selected" to selected(c).toList(),"enabled" to enabled(c)))
                "setEnabled" -> {
                    val value=call.arguments as? Boolean
                    if(value==null)result.error("INVALID","Некорректная настройка",null)
                    else result.success(settings(c).edit().putBoolean("proxy_enabled",value).commit())
                }
                "set" -> {
                    val names=call.arguments as? List<*>
                    if(names==null||names.any { it !is String || it !in catalogue })result.error("INVALID","Недопустимый сайт",null)
                    else result.success(settings(c).edit().putStringSet("domains",names.filterIsInstance<String>().toSet()).commit())
                }
                else -> result.notImplemented()
            }
        }
    }
}

/** GoBackend starts its service with an explicit intent. Retain its tunnel lifecycle and customise the builder. */
internal class BrowserRoutingContext(base:Context):ContextWrapper(base) {
    override fun startService(service:Intent):ComponentName? {
        val intent=if(service.component?.className==GoBackend.VpnService::class.java.name)
            Intent(service).setClass(this,FlowBrowserVpnService::class.java) else service
        return super.startService(intent)
    }
}

class FlowBrowserVpnService:GoBackend.VpnService() {
    companion object {
        private val recoveryIdentity = ManagedServiceIdentity<FlowBrowserVpnService>()
        internal fun beginTunnelBuild() = recoveryIdentity.beginBuild()
        internal fun recoveryService(): FlowBrowserVpnService? = recoveryIdentity.current()
        internal fun isRecoveryService(service: FlowBrowserVpnService): Boolean =
            recoveryIdentity.matches(service) && !service.destroyed
    }
    @Volatile private var destroyed = false
    private var proxy:DirectBrowserProxy?=null
    override fun getBuilder():android.net.VpnService.Builder {
        val builder=super.getBuilder()
        proxy?.close();proxy=null
        val domains=BrowserSites.selected(this)
        if(BrowserProxyPolicy.shouldInstall(BrowserSites.enabled(this),Build.VERSION.SDK_INT,domains)){
            proxy=DirectBrowserProxy(domains,::openSocket)
            builder.setHttpProxy(ProxyInfo.buildDirectProxy("127.0.0.1",proxy!!.port))
        }
        if (!destroyed) recoveryIdentity.builtBy(this)
        return builder
    }

    @Suppress("DEPRECATION")
    private fun openSocket(host:String,port:Int,direct:Boolean):Socket {
        val cm=getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val candidates=(listOfNotNull(cm.activeNetwork)+cm.allNetworks.toList()).distinct()
        val network=candidates.firstOrNull { n ->
            val cap=cm.getNetworkCapabilities(n)?:return@firstOrNull false
            cap.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                if(direct) cap.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                    cap.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                else cap.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } ?: throw IOException("Network unavailable")
        for(address in network.getAllByName(host)){
            if(address.isAnyLocalAddress||address.isLoopbackAddress||address.isMulticastAddress||
                direct&&(address.isSiteLocalAddress||address.isLinkLocalAddress))continue
            val socket=Socket(Proxy.NO_PROXY)
            try {
                network.bindSocket(socket)
                socket.connect(InetSocketAddress(address,port),4500)
                return socket
            }catch(_:IOException){socket.close()}catch(e:RuntimeException){socket.close();throw e}
        }
        throw IOException("Site unavailable")
    }
    override fun onDestroy(){
        destroyed = true
        recoveryIdentity.destroyed(this)
        proxy?.close();proxy=null;super.onDestroy()
    }
}
