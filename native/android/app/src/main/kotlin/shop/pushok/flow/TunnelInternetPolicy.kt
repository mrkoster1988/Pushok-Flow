package shop.pushok.flow

import java.net.InetAddress

/** Route selection for a diagnostic packet, including more-specific VPN exclusions. */
internal object TunnelInternetPolicy {
    data class Route(
        val destination: InetAddress,
        val prefixLength: Int,
        val interfaceName: String?,
        val unicast: Boolean,
    ) {
        init { require(prefixLength in 0..destination.address.size * 8) }

        fun matches(address: InetAddress): Boolean {
            val network = destination.address
            val candidate = address.address
            if (network.size != candidate.size) return false
            val whole = prefixLength / 8
            for (index in 0 until whole) if (network[index] != candidate[index]) return false
            val remaining = prefixLength % 8
            if (remaining == 0) return true
            val mask = (0xff shl (8 - remaining)) and 0xff
            return (network[whole].toInt() and mask) == (candidate[whole].toInt() and mask)
        }
    }

    data class Routes(val interfaceName: String?, val entries: List<Route>)

    fun allows(address: InetAddress, routes: Routes): Boolean {
        val bytes = address.address
        // A mapped Inet6Address may use an IPv4 socket route in the kernel;
        // it must not pass an IPv6-only route check.
        val mappedV4 = bytes.size == 16 && bytes.take(10).all { it == 0.toByte() } &&
            bytes[10] == (-1).toByte() && bytes[11] == (-1).toByte()
        if (routes.interfaceName.isNullOrBlank() || address.isAnyLocalAddress ||
            address.isLoopbackAddress || address.isLinkLocalAddress || address.isMulticastAddress ||
            mappedV4 || bytes.all { it.toInt() and 0xff == 0xff }) return false
        val matching = routes.entries.filter { it.matches(address) }
        val longest = matching.maxOfOrNull { it.prefixLength } ?: return false
        // Reject a tie with an exclusion/another interface instead of guessing
        // which kernel route would win. A broad unicast route must not override it.
        return matching.filter { it.prefixLength == longest }.all {
            it.unicast && it.interfaceName == routes.interfaceName
        }
    }

    fun candidates(addresses: List<InetAddress>, routes: Routes): List<InetAddress> {
        val allowed = addresses.distinct().filter { allows(it, routes) }
        val first = allowed.firstOrNull() ?: return emptyList()
        // Give the other permitted family a chance before trying several failing
        // addresses of the first family. Never introduce addresses from another DNS lookup.
        val other = allowed.firstOrNull { it.address.size != first.address.size }
        return if (other == null) allowed else listOf(first, other) + allowed.filter {
            it != first && it != other
        }
    }
}
