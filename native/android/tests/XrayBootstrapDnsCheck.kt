package shop.pushok.flow

import java.net.Inet6Address
import java.net.InetAddress

fun main() {
    // Actual platform address formatting must reach the socket endpoint intact.
    val ipv4 = InetAddress.getByAddress(byteArrayOf(1, 1, 1, 1))
    check(XrayBootstrapDns.endpoint(ipv4.hostAddress) == "1.1.1.1:53")
    val global = InetAddress.getByAddress(byteArrayOf(
        0x20, 0x01, 0x0d, 0xb8.toByte(), 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1,
    ))
    check(XrayBootstrapDns.endpoint(global.hostAddress) == "[${global.hostAddress}]:53")

    val linkLocalBytes = byteArrayOf(
        0xfe.toByte(), 0x80.toByte(), 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1,
    )
    for (scope in listOf(1, 7, 4096)) {
        val scoped = Inet6Address.getByAddress(null, linkLocalBytes, scope)
        check(scoped.isLinkLocalAddress && scoped.hostAddress.endsWith("%$scope"))
        check(XrayBootstrapDns.endpoint(scoped.hostAddress) == "[${scoped.hostAddress}]:53")
    }

    // Android can return a named zone. The Go socket API expects a literal %,
    // not URL encoding, and must retain the interface name rather than guess it.
    check(XrayBootstrapDns.endpoint("fe80::1%wlan0") == "[fe80::1%wlan0]:53")
    check(XrayBootstrapDns.endpoint("fe80::1%rmnet_data0") == "[fe80::1%rmnet_data0]:53")
    check(XrayBootstrapDns.endpoint("2001:db8::1") == "[2001:db8::1]:53")
    check(XrayBootstrapDns.endpoint(null) == XrayBootstrapDns.FALLBACK_ENDPOINT)
    println("Xray bootstrap DNS IPv4, IPv6 and scoped endpoint checks passed")
}
