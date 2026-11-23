package shop.pushok.flow

/** Formats a platform-derived InetAddress.hostAddress for libXray's SetDNS. */
internal object XrayBootstrapDns {
    const val FALLBACK_ENDPOINT = "1.1.1.1:53"

    fun endpoint(hostAddress: String?): String = when {
        hostAddress == null -> FALLBACK_ENDPOINT
        // A link-local IPv6 address needs its interface zone. This is a socket
        // endpoint, not a URL: preserve both numeric and named %zones verbatim.
        ':' in hostAddress -> "[$hostAddress]:53"
        else -> "$hostAddress:53"
    }
}
