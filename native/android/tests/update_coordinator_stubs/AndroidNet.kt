package android.net

class Network
class NetworkCapabilities {
    companion object { const val TRANSPORT_VPN = 4 }
    fun hasTransport(transport: Int) = false
}
class ConnectivityManager {
    val allNetworks = emptyArray<Network>()
    fun getNetworkCapabilities(network: Network): NetworkCapabilities? = NetworkCapabilities()
}
data class Uri(private val value: String) {
    companion object { fun parse(value: String) = Uri(value) }
}
