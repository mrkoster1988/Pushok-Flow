package shop.pushok.flow

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Collections

/** Managed WireGuard feeds. Legacy format names remain readable in saved metadata. */
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

    fun parse(body: ByteArray, userInfo: String? = null, profileTitle: String? = null): Parsed {
        if (body.size > SubscriptionPolicy.MAX_BYTES) fail("SUBSCRIPTION_TOO_LARGE")
        val raw = strictUtf8(body).removePrefix("\uFEFF")
        if (raw.isBlank()) fail("SUBSCRIPTION_EMPTY")
        if (!raw.trimStart().startsWith('{')) fail("SUBSCRIPTION_UNSUPPORTED")
        return ManagedWireGuardFeed.parse(raw)
    }

    fun validProviderId(value: String): Boolean = value.length in 1..64 && value.all {
        it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-'
    }

    /** Recheck a native-only Parsed object before a catalog commit; constructors are not a trust boundary. */
    internal fun validateManaged(feed: Parsed) = ManagedWireGuardFeed.validate(feed)

    private fun strictUtf8(bytes: ByteArray): String = try {
        StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: java.nio.charset.CharacterCodingException) { fail("SUBSCRIPTION_INVALID") }

    private fun fail(code: String): Nothing = throw SubscriptionFailure(code)
}
