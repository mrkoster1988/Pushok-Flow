package shop.pushok.flow

import java.net.InetAddress
import java.net.URI
import java.util.Locale

/** Public error codes only: URLs and downloaded credentials must never enter an exception. */
class SubscriptionFailure(code: String) : Exception() {
    val code = code.takeIf { it in CODES } ?: "SUBSCRIPTION_INVALID"
    override fun toString() = "SubscriptionFailure($code)"

    companion object {
        val CODES = setOf("SUBSCRIPTION_URL_INVALID", "SUBSCRIPTION_INVALID", "SUBSCRIPTION_TOO_LARGE",
            "SUBSCRIPTION_EMPTY", "SUBSCRIPTION_UNSUPPORTED", "SUBSCRIPTION_EXISTS",
            "SUBSCRIPTION_NOT_FOUND", "SUBSCRIPTION_CHANGED", "SUBSCRIPTION_LIMIT_REACHED",
            "SUBSCRIPTION_NETWORK_ERROR", "SUBSCRIPTION_TLS_ERROR", "SUBSCRIPTION_TIMEOUT", "SUBSCRIPTION_HTTP_ERROR",
            "SUBSCRIPTION_AUTH_REQUIRED", "SUBSCRIPTION_EXPIRED", "SUBSCRIPTION_REDIRECT_BLOCKED",
            "SUBSCRIPTION_BUSY", "SUBSCRIPTION_CANCELLED", "SUBSCRIPTION_STATE_UNAVAILABLE",
            "SUBSCRIPTION_INTERRUPTED", "SUBSCRIPTION_STORE_FAILED", "SUBSCRIPTION_UNAVAILABLE")
    }
}

/** URL validation is pure; the downloader must separately reject private DNS resolutions. */
object SubscriptionPolicy {
    const val MAX_BYTES = 512 * 1024
    const val MAX_URL_LENGTH = 4096
    const val MAX_SUBSCRIPTIONS = 5
    // Keep provider dates representable by every client/platform (through year 9999).
    const val MAX_TIMESTAMP_MS = 253_402_300_799_000L

    fun validateUrl(raw: String): String = normalizeUrl(raw)

    fun normalizeUrl(raw: String): String {
        try {
            val text = raw.trim()
            if (text.isEmpty() || text.length > MAX_URL_LENGTH ||
                text.any { it.isWhitespace() || Character.isISOControl(it) || it == '\\' }) invalid()
            val uri = URI(text)
            if (uri.isOpaque || !uri.scheme.equals("https", true) || uri.rawUserInfo != null ||
                uri.rawFragment != null || uri.host.isNullOrEmpty() ||
                uri.port !in -1..65535 || uri.port == 0) invalid()
            val host = uri.host.removePrefix("[").removeSuffix("]").lowercase(Locale.ROOT)
            if (!isPublicHost(host)) invalid()
            val authority = if (':' in host) "[$host]" else host
            val port = if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"
            // Keep escaped path/query bytes intact: a subscription token may be case sensitive.
            val path = uri.rawPath.takeUnless { it.isNullOrEmpty() } ?: "/"
            val query = uri.rawQuery?.let { "?$it" } ?: ""
            return "https://$authority$port$path$query".also {
                if (it.length > MAX_URL_LENGTH) invalid()
            }
        } catch (error: SubscriptionFailure) { throw error }
        catch (_: Exception) { invalid() }
    }

    fun host(raw: String): String = URI(normalizeUrl(raw)).host.removePrefix("[").removeSuffix("]")

    fun isPublicAddress(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
            address.isSiteLocalAddress || address.isMulticastAddress) return false
        val bytes = address.address.map { it.toInt() and 255 }
        if (bytes.size == 4) {
            val a = bytes[0]; val b = bytes[1]
            return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                (a == 100 && b in 64..127) || (a == 169 && b == 254) ||
                (a == 172 && b in 16..31) || (a == 192 && (b == 168 || b == 0)) ||
                (a == 198 && b in 18..19))
        }
        if (bytes.size != 16 || bytes[0] and 0xfe == 0xfc) return false
        // IPv4-mapped and compatible addresses are not an alternative spelling for a private target.
        if (bytes.take(10).all { it == 0 } &&
            ((bytes[10] == 255 && bytes[11] == 255) || (bytes[10] == 0 && bytes[11] == 0))) {
            return isPublicAddress(InetAddress.getByAddress(address.address.copyOfRange(12, 16)))
        }
        return true
    }

    private fun isPublicHost(host: String): Boolean {
        if (host.isEmpty() || host.length > 253 || host.endsWith('.') ||
            host == "localhost" || listOf(".localhost", ".local", ".lan", ".home", ".internal")
                .any(host::endsWith)) return false
        if (':' in host) {
            if (host.any { it !in "0123456789abcdef:" } || ':' !in host) return false
            return try { isPublicAddress(InetAddress.getByName(host)) } catch (_: Exception) { false }
        }
        if (host.all { it.isDigit() || it == '.' }) {
            val parts = host.split('.')
            if (parts.size != 4 || parts.any { it.isEmpty() || it.length > 3 ||
                    (it.length > 1 && it.startsWith('0')) || it.toIntOrNull() !in 0..255 }) return false
            return isPublicAddress(InetAddress.getByAddress(parts.map { it.toInt().toByte() }.toByteArray()))
        }
        if (!host.contains('.') || host.startsWith("0x")) return false
        return host.split('.').all { label -> label.isNotEmpty() && label.length <= 63 &&
            label.first() != '-' && label.last() != '-' && label.all { it in 'a'..'z' || it in '0'..'9' || it == '-' } }
    }

    private fun invalid(): Nothing = throw SubscriptionFailure("SUBSCRIPTION_URL_INVALID")
}
