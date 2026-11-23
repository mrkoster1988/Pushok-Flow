package shop.pushok.flow

import java.net.IDN
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.Locale

/**
 * A bounded 3x-ui subset: one VLESS RAW/TCP client using TLS or REALITY (optional
 * Vision), or WebSocket/gRPC using TLS. No subscription fetch or JSON import.
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
        val transport: String,
        val wsPath: String?,
        val wsHost: String?,
        val grpcServiceName: String?,
        val grpcAuthority: String?,
        val grpcMultiMode: Boolean,
    ) {
        override fun toString() = "VlessProfile.Parsed(<redacted>)"
    }

    private val uuidPattern = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    private val commonFields = setOf("type", "encryption", "security", "flow", "sni", "fp", "alpn",
        "pbk", "sid", "spx", "allowInsecure", "support-x25519mlkem768")
    private val transportFields = mapOf("raw" to setOf("headerType"),
        "ws" to setOf("path", "host"), "grpc" to setOf("serviceName", "authority", "mode"))
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
        // A partial subscription may skip an unsupported capability. Do not let that
        // early classification hide damaged values of fields whose syntax we know.
        validateKnownFieldSyntax(fields)
        val transport = when (fields["type"] ?: "tcp") {
            "tcp", "raw" -> "raw"
            "ws" -> "ws"
            "grpc" -> "grpc"
            else -> fail("UNSUPPORTED_TRANSPORT")
        }
        if (transport == "raw" && (fields["headerType"] ?: "none") != "none") {
            fail("UNSUPPORTED_TRANSPORT")
        }
        if (fields.keys.any { it !in commonFields && it !in transportFields.getValue(transport) }) {
            fail("UNSUPPORTED_PROFILE_OPTION")
        }
        if ((fields["encryption"] ?: "none") != "none") fail("UNSUPPORTED_SECURITY")
        val security = fields["security"]
        if (security !in setOf("tls", "reality") || (security == "reality" && transport != "raw")) {
            fail("UNSUPPORTED_SECURITY")
        }
        if (fields["allowInsecure"]?.let { it !in setOf("0", "false") } == true) {
            fail("UNSUPPORTED_SECURITY")
        }
        val flow = fields["flow"]?.takeIf { it.isNotEmpty() }
        if (flow != null && (flow != "xtls-rprx-vision" || transport != "raw")) {
            fail("UNSUPPORTED_PROFILE_OPTION")
        }
        val serverName = fields["sni"]?.let(::normalizeHost) ?: host
        val fingerprint = fields["fp"] ?: if (security == "tls") "chrome" else invalid()
        if (fingerprint !in if (security == "reality") realityFingerprints else tlsFingerprints) {
            fail("UNSUPPORTED_PROFILE_OPTION")
        }
        val alpn = fields["alpn"]?.let { value ->
            if (security != "tls") fail("UNSUPPORTED_PROFILE_OPTION")
            validateAlpn(value)
        } ?: emptyList()
        // The pinned core rewrites other WS lists during its uTLS handshake.
        // Reject incompatible requests rather than pretending their ALPN survives.
        if (transport == "ws" && alpn !in listOf(emptyList(), listOf("http/1.1"), listOf("h2", "http/1.1"))) {
            fail("UNSUPPORTED_PROFILE_OPTION")
        }
        if (transport == "grpc" && alpn !in listOf(emptyList(), listOf("h2"), listOf("h2", "http/1.1"))) {
            fail("UNSUPPORTED_PROFILE_OPTION")
        }
        val wsPath = if (transport == "ws") validateWsPath(fields["path"]) else null
        val wsHost = if (transport == "ws") normalizeAuthority(fields["host"]) else null
        val grpcServiceName = if (transport == "grpc") validateGrpcServiceName(fields["serviceName"]) else null
        val grpcAuthority = if (transport == "grpc") normalizeAuthority(fields["authority"]) else null
        val grpcMultiMode = if (transport == "grpc") when (fields["mode"] ?: "gun") {
            "gun" -> false
            "multi" -> true
            else -> fail("UNSUPPORTED_PROFILE_OPTION")
        } else false
        var publicKey: String? = null
        var shortId: String? = null
        var spiderX: String? = null
        if (security == "reality") {
            publicKey = validPublicKey(fields["pbk"] ?: invalid())
            shortId = validateShortId(fields["sid"] ?: "")
            spiderX = validateSpiderX(fields["spx"] ?: "")
            // 3x-ui emits this capability hint. The bundled current core supports MLKEM;
            // no security parameter is downgraded or inferred from this optional flag.
            if (fields["support-x25519mlkem768"]?.let { it != "true" } == true) {
                fail("UNSUPPORTED_PROFILE_OPTION")
            }
        } else if (listOf("pbk", "sid", "spx", "support-x25519mlkem768").any(fields::containsKey)) {
            fail("UNSUPPORTED_PROFILE_OPTION")
        }
        return Parsed(uuid.lowercase(Locale.ROOT), host, port, security!!, serverName,
            fingerprint, flow, publicKey, shortId, spiderX, alpn, transport,
            wsPath, wsHost, grpcServiceName, grpcAuthority, grpcMultiMode)
    }

    /** Syntax and known required fields only; unsupported combinations get no invented defaults. */
    private fun validateKnownFieldSyntax(fields: Map<String, String>) {
        fields["sni"]?.let(::normalizeHost)
        fields["alpn"]?.let(::validateAlpn)
        fields["pbk"]?.let(::validPublicKey)
        fields["sid"]?.let(::validateShortId)
        fields["spx"]?.let(::validateSpiderX)
        fields["path"]?.let(::validateWsPath)
        fields["host"]?.let(::normalizeAuthority)
        fields["serviceName"]?.let(::validateGrpcServiceName)
        fields["authority"]?.let(::normalizeAuthority)
        val transport = fields["type"] ?: "tcp"
        if (fields["security"] == "reality" && transport in setOf("tcp", "raw")) {
            if (fields["pbk"] == null || fields["fp"] == null) invalid()
        }
        if (fields["security"] == "tls" && transport == "grpc") {
            validateGrpcServiceName(fields["serviceName"])
        }
    }

    private fun validateAlpn(value: String): List<String> {
        // 3x-ui's empty configured list leaves protocol selection to the core.
        if (value.isEmpty()) return emptyList()
        val protocols = value.split(',')
        if (protocols.size > 8 || protocols.size != protocols.distinct().size ||
            protocols.any { item -> item.isEmpty() || item.length > 255 ||
                item.any { it.code !in 33..126 } }) invalid()
        return Collections.unmodifiableList(protocols.toList())
    }

    private fun validateShortId(value: String): String {
        if (value.length > 16 || value.length % 2 != 0 ||
            !value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) invalid()
        return value.lowercase(Locale.ROOT)
    }

    private fun validateSpiderX(value: String): String {
        if (value.length > 2048 || (value.isNotEmpty() && !value.startsWith('/')) ||
            '#' in value || value.any(::unsafeCharacter)) invalid()
        return value
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
            // New transport fields follow 3x-ui's URLSearchParams/url.Values
            // serialization: a space is '+', a literal '+' is '%2B'. Legacy RAW
            // fields keep the existing importer semantics across app upgrades.
            val value = decode(pair.substring(equal + 1), plusAsSpace = key in
                setOf("path", "host", "serviceName", "authority"))
            if (!Regex("^[A-Za-z][A-Za-z0-9-]{0,63}$").matches(key) ||
                value.any(::unsafeCharacter) || result.put(key, value) != null) invalid()
        }
        return result
    }

    /** Decode percent escapes exactly once; malformed UTF-8 always fails closed. */
    private fun decode(raw: String, plusAsSpace: Boolean = false): String {
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
                } else {
                    val next = source[input++]
                    output[count++] = if (plusAsSpace && next == '+'.code.toByte()) ' '.code.toByte() else next
                }
            }
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(output, 0, count)).toString()
        } finally { source.fill(0); output.fill(0) }
    }

    /** HTTP Host/:authority is one host with an optional port, never a URL or a list. */
    private fun normalizeAuthority(value: String?): String? {
        if (value.isNullOrEmpty()) return null
        if (value.length > 320 || value.any { unsafeCharacter(it) || it.isWhitespace() }) invalid()
        val host: String
        val port: String?
        if (value.startsWith('[')) {
            val end = value.indexOf(']')
            if (end <= 1 || !validIpv6(value.substring(1, end))) invalid()
            host = "[${normalizeHost(value.substring(1, end))}]"
            port = if (end == value.lastIndex) null else {
                if (value.getOrNull(end + 1) != ':') invalid()
                value.substring(end + 2)
            }
        } else {
            if (value.count { it == ':' } > 1) invalid()
            host = normalizeHost(value.substringBefore(':'))
            port = if (':' in value) value.substringAfter(':') else null
        }
        if (port != null && (!Regex("^[0-9]{1,5}$").matches(port) ||
                port.toIntOrNull()?.let { it in 1..65535 } != true)) invalid()
        return host + if (port == null) "" else ":$port"
    }

    private fun validateWsPath(value: String?): String {
        val path = value?.takeIf { it.isNotEmpty() } ?: "/"
        if (path.length > 4096 || !path.startsWith('/') ||
            path.any { unsafeCharacter(it) || it.isWhitespace() } || '\\' in path) invalid()
        // Parsing here only validates syntax. Do not use decoded URI.path or
        // rebuild the URI: an escaped slash/query token must survive unchanged.
        val parsed = URI("https://profile.invalid$path")
        if (parsed.rawAuthority != "profile.invalid" || parsed.rawFragment != null) invalid()
        var earlyDataSeen = false
        parsed.rawQuery?.split('&')?.forEach { part ->
            if (';' in part) invalid() // Go's url.Values would discard this query component.
            val key = decode(part.substringBefore('='), plusAsSpace = true)
            if (key == "ed") {
                if (earlyDataSeen || '=' !in part) invalid()
                earlyDataSeen = true
                val amount = decode(part.substringAfter('='), plusAsSpace = true)
                if (!Regex("^[0-9]{1,4}$").matches(amount) || amount.toInt() > 8192) invalid()
            }
        }
        return path
    }

    private fun validateGrpcServiceName(value: String?): String {
        val name = value ?: invalid()
        if (name.isEmpty() || name.length > 1024 || name.any(::unsafeCharacter)) invalid()
        // The current core supports a custom path beginning with '/', where the
        // final component is the stream name. Keep its escaping and punctuation.
        if (name.startsWith('/')) {
            if (name.count { it == '/' } < 2 || name.endsWith('/')) invalid()
            val streamNames = name.substringAfterLast('/').split('|')
            // Xray only reads the first two names (Tun and TunMulti). Do not
            // accept an ignored third name or an empty selected stream name.
            if (streamNames.size > 2 || streamNames.any { it.isEmpty() }) invalid()
        }
        return name
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
