package shop.pushok.flow

import java.io.ByteArrayInputStream
import java.net.URI
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Locale

/**
 * Local classification for a protected import draft. A subscription is only a validated
 * HTTPS address: this class never resolves its host, opens it, saves it, or starts a VPN.
 * ConnectionProfile remains the stricter profile-only gate used when saving/connecting.
 */
object ProfileImportPayload {
    sealed class Draft {
        abstract val text: String
        abstract fun toPlatform(): Map<String, String>
        final override fun toString() = "ProfileImportPayload.Draft(<redacted>)"
    }

    class Profile internal constructor(override val text: String,
        val protocol: ConnectionProfile.Kind) : Draft() {
        override fun toPlatform() = mapOf("kind" to "profile", "config" to text)
    }

    class Subscription internal constructor(override val text: String) : Draft() {
        override fun toPlatform() = mapOf("kind" to "subscription", "url" to text)
    }

    private val schemePrefix = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")
    private val telegramHosts = setOf("t.me", "telegram.me", "www.t.me", "www.telegram.me")

    fun parse(raw: String?, cancelled: () -> Boolean = { false }): Draft {
        val text = boundedText(raw, cancelled)
        val trimmed = text.trim()
        val scheme = schemePrefix.find(trimmed)?.groupValues?.get(1)?.lowercase(Locale.ROOT)
        val result = when (scheme) {
            "tg" -> fail("PROFILE_TELEGRAM_LINK")
            "vmess" -> fail("PROFILE_VMESS_LINK")
            "trojan" -> fail("PROFILE_TROJAN_LINK")
            "ss", "ssr" -> fail("PROFILE_SHADOWSOCKS_LINK")
            "http", "https" -> subscription(trimmed)
            "pushokflow" -> {
                // Reuse the same bounded parser as an Android app link. Do not unwrap
                // arbitrary web/app URLs or decode a credential more than once.
                val draft = SubscriptionLinks.parse(trimmed) ?: fail("SUBSCRIPTION_URL_INVALID")
                subscription(draft.url)
            }
            else -> {
                val protocol = try { ConnectionProfile.validateShape(text) }
                    catch (error: ProfileFormatFailure) { fail(error.code) }
                Profile(text, protocol)
            }
        }
        active(cancelled)
        return result
    }

    private fun subscription(raw: String): Subscription {
        val url = try { SubscriptionPolicy.normalizeUrl(raw) }
            catch (_: SubscriptionFailure) { fail("SUBSCRIPTION_URL_INVALID") }
        // A known Telegram proxy link must not be offered as a subscription, including
        // when carried by the app's own validated import link.
        val uri = URI(url)
        if (uri.host.lowercase(Locale.ROOT) in telegramHosts &&
            uri.path in setOf("/proxy", "/socks")) fail("PROFILE_TELEGRAM_LINK")
        return Subscription(url)
    }

    private fun boundedText(value: String?, cancelled: () -> Boolean): String {
        active(cancelled)
        if (value == null || value.length > ProfileImportReader.MAX_BYTES) {
            fail(if (value == null) "PROFILE_IMPORT_INVALID" else "PROFILE_IMPORT_TOO_LARGE")
        }
        val encoded = try {
            StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value))
        } catch (_: Exception) { fail("PROFILE_IMPORT_INVALID") }
        try {
            if (encoded.remaining() > ProfileImportReader.MAX_BYTES) fail("PROFILE_IMPORT_TOO_LARGE")
            val bytes = ByteArray(encoded.remaining())
            encoded.get(bytes)
            return try { ProfileImportReader.read(ByteArrayInputStream(bytes), cancelled) }
                finally { bytes.fill(0) }
        } finally { if (encoded.hasArray()) encoded.array().fill(0) }
    }

    private fun active(cancelled: () -> Boolean) {
        if (cancelled()) fail("PROFILE_IMPORT_INTERRUPTED")
    }

    private fun fail(code: String): Nothing = throw ProfileImportReader.Failure(code)
}
