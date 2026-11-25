package shop.pushok.flow

import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Collections
import java.util.Locale

/** Bounded legacy VLESS and explicit managed WireGuard feeds; no nested remote imports. */
object SubscriptionFeed {
    const val LEGACY_FORMAT = "vless"
    const val MANAGED_WIREGUARD_FORMAT = "wireguard-v1"
    const val MAX_REVISION = 9_007_199_254_740_991L

    class Entry(val name: String, val config: String, val providerId: String? = null) {
        override fun toString() = "SubscriptionFeed.Entry(<redacted>)"
    }

    class Parsed internal constructor(entries: List<Entry>, val title: String?,
        val expiresAt: Long?, val usedBytes: Long?, val totalBytes: Long?,
        val skippedProfileCount: Int = 0, val format: String = LEGACY_FORMAT,
        val state: String = "active", val revision: Long? = null) {
        val entries: List<Entry> = Collections.unmodifiableList(entries.toList())
        override fun toString() = "SubscriptionFeed.Parsed(<redacted>)"
    }

    private val schemePrefix = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://")
    // These are recognized client-link families, not nested subscriptions or generic URLs.
    // Their credentials remain uninterpreted: no decoding, fetching or conversion occurs.
    private val unsupportedSchemes = setOf("vmess", "trojan", "ss", "ssr", "hysteria",
        "hysteria2", "hy2", "tuic", "wireguard")

    fun parse(body: ByteArray, userInfo: String? = null, profileTitle: String? = null): Parsed {
        if (body.size > SubscriptionPolicy.MAX_BYTES) fail("SUBSCRIPTION_TOO_LARGE")
        val raw = strictUtf8(body).removePrefix("\uFEFF")
        var text = raw.trim()
        if (text.isEmpty()) fail("SUBSCRIPTION_EMPTY")
        if (text.startsWith('{')) return ManagedWireGuardFeed.parse(raw)
        if (!schemePrefix.containsMatchIn(text)) {
            if (text.startsWith('[') || text.startsWith('{')) fail("SUBSCRIPTION_UNSUPPORTED")
            val decoded = decodeBase64(text)
            text = try { strictUtf8(decoded).removePrefix("\uFEFF").trim() } finally { decoded.fill(0) }
            // Managed access states must use their explicit wire format, never a
            // legacy Base64 wrapper or a nested import guessed from its contents.
            if (text.startsWith('{') || text.startsWith('[')) fail("SUBSCRIPTION_UNSUPPORTED")
        }
        if (text.isEmpty()) fail("SUBSCRIPTION_EMPTY")
        val lines = text.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }
            .take(SubscriptionPolicy.MAX_FEED_ENTRIES + 1).toList()
        if (lines.size > SubscriptionPolicy.MAX_FEED_ENTRIES) fail("SUBSCRIPTION_TOO_LARGE")
        val entries = mutableListOf<Entry>()
        var skipped = 0
        for (line in lines) {
            if (!line.startsWith("vless://", true)) {
                if (!isUnsupportedClientUri(line)) fail("SUBSCRIPTION_INVALID")
                skipped++
                continue
            }
            try { VlessProfile.parse(line) }
            catch (error: ProfileFormatFailure) {
                if (error.code.startsWith("UNSUPPORTED_")) {
                    skipped++
                    continue
                }
                fail("SUBSCRIPTION_INVALID")
            }
            if (entries.size == ProfileCatalogStore.MAX_PROFILES) fail("SUBSCRIPTION_TOO_LARGE")
            val rawName = try { URI(line).rawFragment?.let(::decodeLabel) } catch (_: Exception) { null }
            entries.add(Entry(safeName(rawName) ?: "Сервер ${entries.size + 1}", line))
        }
        // A response with no usable servers must never replace the existing catalog.
        if (entries.isEmpty()) fail(if (skipped > 0) "SUBSCRIPTION_UNSUPPORTED" else "SUBSCRIPTION_EMPTY")
        // Different labels or export formatting cannot create another effective connection.
        if (entries.map { identity(it.config) }.distinct().size != entries.size) fail("SUBSCRIPTION_INVALID")
        val info = metadata(userInfo)
        return Parsed(entries, title(profileTitle), info["expire"]
            ?.takeIf { it in 1..(SubscriptionPolicy.MAX_TIMESTAMP_MS / 1000) }?.times(1000),
            if (info["upload"] != null && info["download"] != null) {
                val upload = info.getValue("upload"); val download = info.getValue("download")
                if (upload <= Long.MAX_VALUE - download) upload + download else null
            } else null,
            info["total"]?.takeIf { it > 0 }, skipped)
    }

    private fun isUnsupportedClientUri(line: String): Boolean {
        val scheme = schemePrefix.find(line)?.groupValues?.get(1)?.lowercase(Locale.ROOT)
            ?: return false
        if (scheme !in unsupportedSchemes) return false
        if (line.length > ProfileCatalogStore.MAX_CONFIG_LENGTH || line.any {
                it.isWhitespace() || Character.isISOControl(it) ||
                    it in '\u202A'..'\u202E' || it in '\u2066'..'\u2069'
            }) fail("SUBSCRIPTION_INVALID")
        val uri = try { URI(line) } catch (_: Exception) { fail("SUBSCRIPTION_INVALID") }
        if (uri.isOpaque || uri.rawAuthority.isNullOrEmpty()) fail("SUBSCRIPTION_INVALID")
        return true
    }

    /**
     * Compare the exact settings consumed by XrayConfig, after the existing parser
     * resolves defaults and supported aliases. Keep list ordering, nulls and each
     * field boundary; do not turn credentials/paths into a concatenated log value.
     * This key is transient: the original incoming link remains the stored config.
     */
    internal class Identity(profile: VlessProfile.Parsed) {
        private val fields = listOf(profile.uuid, profile.host, profile.port,
            profile.security, profile.serverName, profile.fingerprint, profile.flow,
            profile.realityPublicKey, profile.realityShortId, profile.spiderX,
            profile.alpn.toList(), profile.transport, profile.wsPath, profile.wsHost,
            profile.grpcServiceName, profile.grpcAuthority, profile.grpcMultiMode)

        override fun equals(other: Any?) = other is Identity && fields == other.fields
        override fun hashCode() = fields.hashCode()
        override fun toString() = "SubscriptionFeed.Identity(<redacted>)"
    }

    internal fun identity(config: String) = Identity(VlessProfile.parse(config))

    fun validProviderId(value: String): Boolean = value.length in 1..64 && value.all {
        it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-'
    }

    /** Recheck a native-only Parsed object before a catalog commit; constructors are not a trust boundary. */
    internal fun validateManaged(feed: Parsed) = ManagedWireGuardFeed.validate(feed)

    private fun metadata(raw: String?): Map<String, Long> {
        if (raw == null || raw.length > 2048) return emptyMap()
        val result = mutableMapOf<String, Long>()
        for (part in raw.split(';')) {
            val pair = part.trim().split('=', limit = 2)
            if (pair.size != 2 || pair[0] !in setOf("upload", "download", "total", "expire")) continue
            val value = pair[1].trim().takeIf { it.isNotEmpty() && it.all { c -> c in '0'..'9' } }
                ?.toLongOrNull() ?: return emptyMap()
            if (result.put(pair[0], value) != null) return emptyMap()
        }
        return result
    }

    private fun title(raw: String?): String? {
        if (raw == null || raw.length > 1024) return null
        val text = if (raw.startsWith("base64:", true)) {
            try {
                val bytes = decodeBase64(raw.substring(7))
                try { strictUtf8(bytes) } finally { bytes.fill(0) }
            } catch (_: SubscriptionFailure) { return null }
        } else raw
        return safeName(text)
    }

    private fun safeName(raw: String?): String? = try {
        raw?.let { ProfileCatalogStore.normalizedName(it) }
    } catch (_: Exception) { null }

    private fun strictUtf8(bytes: ByteArray): String = try {
        StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: Exception) { fail("SUBSCRIPTION_INVALID") }

    private fun decodeLabel(raw: String): String {
        val source = raw.toByteArray(StandardCharsets.UTF_8)
        val output = ByteArray(source.size)
        var input = 0; var count = 0
        try {
            while (input < source.size) {
                if (source[input] == '%'.code.toByte()) {
                    if (input + 2 >= source.size) fail("SUBSCRIPTION_INVALID")
                    val a = source[input + 1].toInt().toChar().digitToIntOrNull(16) ?: fail("SUBSCRIPTION_INVALID")
                    val b = source[input + 2].toInt().toChar().digitToIntOrNull(16) ?: fail("SUBSCRIPTION_INVALID")
                    output[count++] = ((a shl 4) or b).toByte(); input += 3
                } else output[count++] = source[input++]
            }
            return strictUtf8(output.copyOf(count))
        } finally { source.fill(0); output.fill(0) }
    }

    /** Does not rely on java.util.Base64, which is unavailable on Android API 24/25. */
    private fun decodeBase64(raw: String): ByteArray {
        val text = raw.filterNot { it == ' ' || it == '\r' || it == '\n' || it == '\t' }
        if (text.length > SubscriptionPolicy.MAX_BYTES || text.length % 4 == 1) fail("SUBSCRIPTION_INVALID")
        val unpadded = text.trimEnd('=')
        val padding = text.length - unpadded.length
        if (padding > 2 || '=' in unpadded || (padding > 0 && text.length % 4 != 0) ||
            (padding == 1 && unpadded.length % 4 != 3) ||
            (padding == 2 && unpadded.length % 4 != 2)) fail("SUBSCRIPTION_INVALID")
        val result = ByteArray(unpadded.length * 6 / 8)
        var buffer = 0; var bits = 0; var offset = 0
        for (char in unpadded) {
            val value = when (char) {
                in 'A'..'Z' -> char - 'A'
                in 'a'..'z' -> char - 'a' + 26
                in '0'..'9' -> char - '0' + 52
                '+', '-' -> 62
                '/', '_' -> 63
                else -> fail("SUBSCRIPTION_INVALID")
            }
            buffer = (buffer shl 6) or value; bits += 6
            if (bits >= 8) { bits -= 8; result[offset++] = (buffer shr bits).toByte() }
            buffer = buffer and ((1 shl bits) - 1)
        }
        if (buffer != 0) fail("SUBSCRIPTION_INVALID")
        return result
    }

    private fun fail(code: String): Nothing = throw SubscriptionFailure(code)
}
