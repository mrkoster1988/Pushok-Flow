package shop.pushok.flow

import com.wireguard.config.Config
import com.wireguard.config.InetAddresses
import java.io.BufferedReader
import java.io.StringReader
import java.util.Locale

/** One explicit, versioned document. The reader accepts strict JSON, not JSONTokener extensions. */
internal object ManagedWireGuardFeed {
    private const val SCHEMA = "pushok-flow-subscription"
    private val fields = setOf("schema", "version", "revision", "state", "expires_at", "profiles")
    private val profileFields = setOf("id", "name", "protocol", "config")

    fun parse(text: String): SubscriptionFeed.Parsed {
        val document = Reader(text).document() as? Map<*, *> ?: invalid()
        // Other JSON formats remain unsupported imports. A document declaring our
        // schema must satisfy the exact contract; missing fields are not defaults.
        if (!document.containsKey("schema")) unsupported()
        val schema = document["schema"] as? String ?: invalid()
        if (schema != SCHEMA) unsupported()
        if (document.keys != fields) invalid()
        if (integer(document["version"]) != 1L) unsupported()
        val revision = integer(document["revision"])
        val state = document["state"] as? String ?: invalid()
        val expiry = integer(document["expires_at"])
        if (expiry !in 1..(SubscriptionPolicy.MAX_TIMESTAMP_MS / 1000)) invalid()
        val profiles = document["profiles"] as? List<*> ?: invalid()
        if (profiles.size > ProfileCatalogStore.MAX_PROFILES) invalid()
        val entries = profiles.map { item ->
            val value = item as? Map<*, *> ?: invalid()
            if (value.keys != profileFields || value["protocol"] != "wireguard") invalid()
            SubscriptionFeed.Entry(value["name"] as? String ?: invalid(),
                value["config"] as? String ?: invalid(), value["id"] as? String ?: invalid())
        }
        return SubscriptionFeed.Parsed(entries, null, expiry * 1000, null, null,
            format = SubscriptionFeed.MANAGED_WIREGUARD_FORMAT, state = state, revision = revision)
            .also(::validate)
    }

    /** Also used when callers construct Parsed directly rather than through the wire reader. */
    fun validate(feed: SubscriptionFeed.Parsed) {
        if (feed.format != SubscriptionFeed.MANAGED_WIREGUARD_FORMAT ||
            feed.state !in setOf("active", "expired", "revoked") ||
            feed.revision == null || feed.revision !in 1..SubscriptionFeed.MAX_REVISION ||
            feed.expiresAt == null || feed.expiresAt !in 1..SubscriptionPolicy.MAX_TIMESTAMP_MS ||
            feed.expiresAt % 1000 != 0L || feed.skippedProfileCount != 0 ||
            feed.title != null || feed.usedBytes != null || feed.totalBytes != null ||
            (feed.state == "active" && feed.entries.size !in 1..ProfileCatalogStore.MAX_PROFILES) ||
            (feed.state != "active" && feed.entries.isNotEmpty())) invalid()
        val ids = mutableSetOf<String>()
        val configurations = mutableSetOf<Identity>()
        for (entry in feed.entries) {
            val providerId = entry.providerId ?: invalid()
            if (!SubscriptionFeed.validProviderId(providerId) || !ids.add(providerId)) invalid()
            try {
                if (ProfileCatalogStore.normalizedName(entry.name) != entry.name ||
                    entry.config.length > ProfileCatalogStore.MAX_CONFIG_LENGTH ||
                    ConnectionProfile.validateShape(entry.config) != ConnectionProfile.Kind.WIREGUARD) invalid()
                if (entry.config.lineSequence().any { line ->
                        val meaningful = line.substringBefore('#')
                        '=' in meaningful && meaningful.substringBefore('=').trim().lowercase(Locale.ROOT) in
                            setOf("includedapplications", "excludedapplications")
                    }) invalid()
                // Match the native connection preflight: one Interface, no imported
                // IncludedApplications, and no misplaced application-routing fields.
                // Only the device controls application routing for a managed feed.
                WireGuardRouting.prepare(entry.config, emptySet())
                val parsed = Config.parse(BufferedReader(StringReader(entry.config)))
                if (parsed.`interface`.addresses.isEmpty() || parsed.peers.size != 1) invalid()
                val peer = parsed.peers.single()
                if (peer.allowedIps.isEmpty() || !peer.endpoint.isPresent || peer.endpoint.get().port <= 0 ||
                    !configurations.add(Identity(parsed))) invalid()
            } catch (_: Exception) {
                // BadConfigException can contain the actual key or configuration line.
                // Never attach it, its message, or its cause to the public failure.
                invalid()
            }
        }
    }

    /** Config.equals includes KeyPair object identity; private keys also have clamping aliases. */
    private class Identity(config: Config) {
        private val fields = config.`interface`.let { value ->
            listOf(value.keyPair.publicKey, value.addresses.toSet(), value.dnsServers.toList(),
                value.dnsSearchDomains.map { it.lowercase(Locale.ROOT) },
                value.listenPort.orElse(0), value.mtu.orElse(null),
                config.peers.map { peer ->
                    listOf(peer.publicKey, peer.preSharedKey.orElse(null), peer.allowedIps.toSet(),
                        peer.persistentKeepalive.orElse(0), peer.endpoint.orElse(null)?.let {
                            listOf(numericOrHostname(it.host), it.port)
                        })
                })
        }

        override fun equals(other: Any?) = other is Identity && fields == other.fields
        override fun hashCode() = fields.hashCode()
        override fun toString() = "ManagedWireGuardFeed.Identity(<redacted>)"
    }

    private fun numericOrHostname(host: String): Any = try {
        // Upstream's numeric parser never resolves a hostname or contacts a peer.
        InetAddresses.parse(host.removePrefix("[").removeSuffix("]"))
    } catch (_: Exception) { host.lowercase(Locale.ROOT) }

    private class Number(val token: String) {
        override fun toString() = "ManagedWireGuardFeed.Number(<redacted>)"
    }

    private fun integer(value: Any?): Long {
        val token = (value as? Number)?.token ?: invalid()
        if (token.isEmpty() || token.any { it !in '0'..'9' }) invalid()
        return token.toLongOrNull() ?: invalid()
    }

    /**
     * Small strict JSON reader with an independent depth/node budget. In particular,
     * duplicate decoded member names, comments, single quotes, coercions, invalid
     * Unicode, trailing commas and trailing documents never become access changes.
     */
    private class Reader(private val input: String) {
        private var offset = 0
        private var nodes = 0

        fun document(): Any? {
            val value = value(0)
            whitespace()
            if (offset != input.length) invalid()
            return value
        }

        private fun value(depth: Int): Any? {
            if (depth > 8 || ++nodes > 1024) invalid()
            whitespace()
            return when (peek()) {
                '{' -> objectValue(depth)
                '[' -> arrayValue(depth)
                '"' -> string()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                '-', in '0'..'9' -> number()
                else -> invalid()
            }
        }

        private fun objectValue(depth: Int): Map<String, Any?> {
            offset++
            whitespace()
            val values = linkedMapOf<String, Any?>()
            if (take('}')) return values
            while (true) {
                if (peek() != '"') invalid()
                val key = string()
                if (values.containsKey(key) || values.size >= 32) invalid()
                whitespace()
                if (!take(':')) invalid()
                values[key] = value(depth + 1)
                whitespace()
                if (take('}')) return values
                if (!take(',')) invalid()
                whitespace()
            }
        }

        private fun arrayValue(depth: Int): List<Any?> {
            offset++
            whitespace()
            val values = mutableListOf<Any?>()
            if (take(']')) return values
            while (true) {
                if (values.size >= SubscriptionPolicy.MAX_FEED_ENTRIES) invalid()
                values.add(value(depth + 1))
                whitespace()
                if (take(']')) return values
                if (!take(',')) invalid()
                whitespace()
            }
        }

        private fun string(): String {
            if (!take('"')) invalid()
            val value = StringBuilder()
            while (offset < input.length) {
                val char = input[offset++]
                if (char == '"') {
                    val result = value.toString()
                    var index = 0
                    while (index < result.length) {
                        val current = result[index++]
                        if (Character.isHighSurrogate(current)) {
                            if (index == result.length || !Character.isLowSurrogate(result[index++])) invalid()
                        } else if (Character.isLowSurrogate(current)) invalid()
                    }
                    return result
                }
                if (char < ' ') invalid()
                if (char != '\\') value.append(char) else {
                    if (offset == input.length) invalid()
                    when (val escape = input[offset++]) {
                        '"', '\\', '/' -> value.append(escape)
                        'b' -> value.append('\b')
                        'f' -> value.append('\u000C')
                        'n' -> value.append('\n')
                        'r' -> value.append('\r')
                        't' -> value.append('\t')
                        'u' -> {
                            if (input.length - offset < 4) invalid()
                            var code = 0
                            repeat(4) {
                                val digit = when (val hex = input[offset++]) {
                                    in '0'..'9' -> hex - '0'
                                    in 'a'..'f' -> hex - 'a' + 10
                                    in 'A'..'F' -> hex - 'A' + 10
                                    else -> invalid()
                                }
                                code = code * 16 + digit
                            }
                            value.append(code.toChar())
                        }
                        else -> invalid()
                    }
                }
                if (value.length > ProfileCatalogStore.MAX_CONFIG_LENGTH) invalid()
            }
            invalid()
        }

        private fun number(): Number {
            val start = offset
            take('-')
            if (!take('0')) {
                if (peek() !in '1'..'9') invalid()
                while (peek() in '0'..'9') offset++
            }
            if (take('.')) {
                if (peek() !in '0'..'9') invalid()
                while (peek() in '0'..'9') offset++
            }
            if (take('e') || take('E')) {
                if (!take('+')) take('-')
                if (peek() !in '0'..'9') invalid()
                while (peek() in '0'..'9') offset++
            }
            if (offset - start > 128) invalid()
            return Number(input.substring(start, offset))
        }

        private fun <T> literal(text: String, value: T): T {
            if (!input.startsWith(text, offset)) invalid()
            offset += text.length
            return value
        }

        private fun whitespace() {
            while (true) when (peek()) {
                ' ', '\t', '\r', '\n' -> offset++
                else -> return
            }
        }

        private fun peek(): Char = input.getOrNull(offset) ?: '\u0000'
        private fun take(char: Char): Boolean {
            if (peek() != char) return false
            offset++
            return true
        }

        override fun toString() = "ManagedWireGuardFeed.Reader(<redacted>)"
    }

    private fun invalid(): Nothing = throw SubscriptionFailure("SUBSCRIPTION_INVALID")
    private fun unsupported(): Nothing = throw SubscriptionFailure("SUBSCRIPTION_UNSUPPORTED")
}
