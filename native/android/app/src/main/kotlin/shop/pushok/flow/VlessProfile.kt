package shop.pushok.flow

import java.net.IDN
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.Locale

/**
 * The deliberately bounded first 3x-ui subset: one VLESS RAW/TCP client using TLS
 * or REALITY, optionally with Vision. There is no subscription fetch or JSON import.
 *
 * Field semantics: https://github.com/XTLS/Xray-core/discussions/716
 * Current 3x-ui export: https://github.com/MHSanaei/3x-ui/blob/main/internal/sub/service.go
 */
object VlessProfile {
    /** Not a data class: generated toString/copy output must never expose credentials. */
    class Parsed internal constructor(
        val uuid: String,
        val host: String,
        val port: Int,
        val security: String,
        val serverName: String,
        val fingerprint: String,
        val flow: String?,
        val realityPublicKey: String?,
        val realityShortId: String?,
        val spiderX: String?,
        val alpn: List<String>,
    ) {
        override fun toString() = "VlessProfile.Parsed(<redacted>)"
    }

    private val uuidPattern = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    private val knownFields = setOf("type", "encryption", "security", "flow", "sni", "fp", "alpn",
        "pbk", "sid", "spx", "headerType", "allowInsecure", "support-x25519mlkem768")
    private val tlsFingerprints = setOf("chrome", "firefox", "safari", "ios", "android", "edge",
        "360", "qq", "random", "randomized")
    // Current REALITY documentation only guarantees MLKEM on these fingerprints.
    private val realityFingerprints = setOf("chrome", "firefox", "safari")
    private const val BASE64_URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    fun parse(raw: String): Parsed {
        try {
            return parseChecked(ConnectionProfile.boundedText(raw))
        } catch (error: ProfileFormatFailure) {
            throw error
        } catch (_: Exception) {
            // URI/IDN/UTF-8 parser messages can contain the complete secret link.
            invalid()
        }
    }

    private fun parseChecked(text: String): Parsed {
        if (!text.startsWith("vless://", ignoreCase = true)) {
            fail("UNSUPPORTED_PROFILE")
        }
        if (text.any { unsafeCharacter(it) || it.isWhitespace() }) invalid()
        val uri = URI(text)
        if (uri.isOpaque || !uri.scheme.equals("vless", ignoreCase = true) ||
            !uri.rawPath.isNullOrEmpty()) invalid()
        val authority = uri.rawAuthority ?: invalid()
        if (authority.count { it == '@' } != 1) invalid()
        val uuid = decode(authority.substringBefore('@'))
        if (!uuidPattern.matches(uuid)) invalid()
        val endpoint = authority.substringAfter('@')
        val endpointHost: String
        val endpointPort: String
        if (endpoint.startsWith('[')) {
            val end = endpoint.indexOf(']')
            if (end <= 1 || endpoint.getOrNull(end + 1) != ':') invalid()
            endpointHost = endpoint.substring(1, end)
            endpointPort = endpoint.substring(end + 2)
            if (!validIpv6(endpointHost)) invalid()
        } else {
            if (endpoint.count { it == ':' } != 1) invalid()
            endpointHost = endpoint.substringBefore(':')
            endpointPort = endpoint.substringAfter(':')
        }
        if (!Regex("^[0-9]{1,5}$").matches(endpointPort)) invalid()
        val port = endpointPort.toIntOrNull()?.takeIf { it in 1..65535 } ?: invalid()
        val host = normalizeHost(endpointHost)
        // Fragments are a label, never native config, a URL to load, or an implicit profile name.
        uri.rawFragment?.let { if (decode(it).any(::unsafeCharacter)) invalid() }
        val fields = parseQuery(uri.rawQuery)
        if ((fields["type"] ?: "tcp") !in setOf("tcp", "raw")) {
            fail("UNSUPPORTED_TRANSPORT")
        }
        if ((fields["headerType"] ?: "none") != "none") fail("UNSUPPORTED_TRANSPORT")
        if (fields.keys.any { it !in knownFields }) fail("UNSUPPORTED_PROFILE_OPTION")
        if ((fields["encryption"] ?: "none") != "none") fail("UNSUPPORTED_SECURITY")
        val security = fields["security"]
        if (security !in setOf("tls", "reality")) fail("UNSUPPORTED_SECURITY")
        if (fields["allowInsecure"]?.let { it !in setOf("0", "false") } == true) {
            fail("UNSUPPORTED_SECURITY")
        }
        val flow = fields["flow"]?.takeIf { it.isNotEmpty() }
        if (flow != null && flow != "xtls-rprx-vision") fail("UNSUPPORTED_PROFILE_OPTION")
        val serverName = fields["sni"]?.let(::normalizeHost) ?: host
        val fingerprint = fields["fp"] ?: if (security == "tls") "chrome" else invalid()
        if (fingerprint !in if (security == "reality") realityFingerprints else tlsFingerprints) {
            fail("UNSUPPORTED_PROFILE_OPTION")
        }
        val alpn = fields["alpn"]?.let { value ->
            if (security != "tls") fail("UNSUPPORTED_PROFILE_OPTION")
            val protocols = value.split(',')
            if (protocols.size > 8 || protocols.size != protocols.distinct().size ||
                protocols.any { item -> item.isEmpty() || item.length > 255 ||
                    item.any { it.code !in 33..126 } }) invalid()
            Collections.unmodifiableList(protocols.toList())
        } ?: emptyList()
        var publicKey: String? = null
        var shortId: String? = null
        var spiderX: String? = null
        if (security == "reality") {
            publicKey = validPublicKey(fields["pbk"] ?: invalid())
            shortId = fields["sid"] ?: ""
            if (shortId.length > 16 || shortId.length % 2 != 0 ||
                !shortId.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) invalid()
            shortId = shortId.lowercase(Locale.ROOT)
            spiderX = fields["spx"] ?: ""
            if (spiderX.length > 2048 || (spiderX.isNotEmpty() && !spiderX.startsWith('/')) ||
                '#' in spiderX || spiderX.any(::unsafeCharacter)) invalid()
            // 3x-ui emits this capability hint. The bundled current core supports MLKEM;
            // no security parameter is downgraded or inferred from this optional flag.
            if (fields["support-x25519mlkem768"]?.let { it != "true" } == true) {
                fail("UNSUPPORTED_PROFILE_OPTION")
            }
        } else if (listOf("pbk", "sid", "spx", "support-x25519mlkem768").any(fields::containsKey)) {
            fail("UNSUPPORTED_PROFILE_OPTION")
        }
        return Parsed(uuid.lowercase(Locale.ROOT), host, port, security!!, serverName,
            fingerprint, flow, publicKey, shortId, spiderX, alpn)
    }

    private fun parseQuery(query: String?): Map<String, String> {
        if (query.isNullOrEmpty()) return emptyMap()
        val pairs = query.split('&')
        if (pairs.size > 32) invalid()
        val result = LinkedHashMap<String, String>()
        for (pair in pairs) {
            val equal = pair.indexOf('=')
            if (equal <= 0) invalid()
            val key = decode(pair.substring(0, equal))
            val value = decode(pair.substring(equal + 1))
            if (!Regex("^[A-Za-z][A-Za-z0-9-]{0,63}$").matches(key) ||
                value.any(::unsafeCharacter) || result.put(key, value) != null) invalid()
        }
        return result
    }

    /** decodeURIComponent semantics: '+' is literal and malformed UTF-8 fails closed. */
    private fun decode(raw: String): String {
        val source = raw.toByteArray(StandardCharsets.UTF_8)
        val output = ByteArray(source.size)
        var input = 0
        var count = 0
        try {
            while (input < source.size) {
                if (source[input] == '%'.code.toByte()) {
                    if (input + 2 >= source.size) invalid()
                    val a = source[input + 1].toInt().toChar().digitToIntOrNull(16) ?: invalid()
                    val b = source[input + 2].toInt().toChar().digitToIntOrNull(16) ?: invalid()
                    output[count++] = ((a shl 4) or b).toByte()
                    input += 3
                } else output[count++] = source[input++]
            }
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(output, 0, count)).toString()
        } finally { source.fill(0); output.fill(0) }
    }

    private fun normalizeHost(raw: String): String {
        if (raw.isEmpty() || raw.length > 253 || raw.any { unsafeCharacter(it) || it.isWhitespace() } ||
            raw.any { it in "%/@\\?#[]" }) invalid()
        if (':' in raw) {
            if (!validIpv6(raw)) invalid()
            return raw.lowercase(Locale.ROOT)
        }
        if (raw.all { it in '0'..'9' || it == '.' }) {
            if (!validIpv4(raw)) invalid()
            return raw
        }
        val ascii = IDN.toASCII(raw, IDN.USE_STD3_ASCII_RULES).lowercase(Locale.ROOT)
        val withoutRoot = ascii.removeSuffix(".")
        if (withoutRoot.isEmpty() || withoutRoot.length > 253 || withoutRoot.split('.').any {
                it.isEmpty() || it.length > 63 || it.startsWith('-') || it.endsWith('-') ||
                    it.any { c -> c !in 'a'..'z' && c !in '0'..'9' && c != '-' }
            }) invalid()
        return ascii
    }

    private fun validIpv4(value: String): Boolean {
        val parts = value.split('.')
        return parts.size == 4 && parts.all { it.isNotEmpty() && it.length <= 3 &&
            it.all { c -> c in '0'..'9' } && (it.length == 1 || it[0] != '0') &&
            it.toInt() in 0..255 }
    }

    /** Numeric grammar only: validation must never perform DNS resolution. */
    private fun validIpv6(value: String): Boolean {
        if (value.length !in 2..45 || value.any { it !in "0123456789abcdefABCDEF:." }) return false
        if (value.count { it == ':' } < 2 || ":::" in value) return false
        val compressed = value.indexOf("::")
        if (compressed >= 0 && value.indexOf("::", compressed + 2) >= 0) return false
        if (compressed < 0 && (value.startsWith(':') || value.endsWith(':'))) return false
        val groups = if (compressed < 0) value.split(':') else {
            val left = value.substring(0, compressed)
            val right = value.substring(compressed + 2)
            (if (left.isEmpty()) emptyList() else left.split(':')) +
                (if (right.isEmpty()) emptyList() else right.split(':'))
        }
        var count = 0
        for ((index, group) in groups.withIndex()) {
            if ('.' in group) {
                if (index != groups.lastIndex || !value.endsWith(group) || !validIpv4(group)) return false
                count += 2
            } else {
                if (group.isEmpty() || group.length > 4 ||
                    group.any { it !in "0123456789abcdefABCDEF" }) return false
                count++
            }
        }
        return if (compressed < 0) count == 8 else count < 8
    }

    private fun validPublicKey(value: String): String {
        val key = if (value.endsWith('=')) value.dropLast(1) else value
        if (key.length != 43 || key.any { it !in BASE64_URL } ||
            BASE64_URL.indexOf(key.last()) and 3 != 0 || key.all { it == 'A' }) invalid()
        return key
    }

    private fun unsafeCharacter(c: Char) = c.code < 32 || c.code in 127..159 ||
        c == '\u2028' || c == '\u2029' || c in '\u202A'..'\u202E' || c in '\u2066'..'\u2069'
    private fun invalid(): Nothing = fail("INVALID_VLESS_CONFIG")
    private fun fail(code: String): Nothing = throw ProfileFormatFailure(code)
}
