package shop.pushok.flow

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/** A link only opens a protected draft. It never authorizes fetching or saving. */
object SubscriptionLinks {
    const val MAX_LINK_LENGTH = 16_384

    class Draft(val url: String, val name: String?) {
        fun metadata(): Map<String, Any?> = mapOf("url" to url, "name" to name)
        override fun toString() = "SubscriptionDraft(redacted)"
    }

    fun parse(raw: String?): Draft? {
        if (raw == null || raw.length > MAX_LINK_LENGTH || raw.any { it.code < 32 || it.code == 127 }) return null
        return try {
            val uri = URI(raw)
            if (uri.scheme != "pushokflow" || uri.host != "subscription" || uri.rawUserInfo != null ||
                uri.port != -1 || !uri.rawPath.isNullOrEmpty() || uri.rawFragment != null) return null
            val parameters = linkedMapOf<String, String>()
            val query = uri.rawQuery ?: return null
            if (query.isEmpty()) return null
            for (item in query.split('&')) {
                val separator = item.indexOf('=')
                if (separator <= 0) return null
                val key = decode(item.substring(0, separator))
                if (key !in setOf("url", "name") || parameters.containsKey(key)) return null
                parameters[key] = decode(item.substring(separator + 1))
            }
            val url = SubscriptionPolicy.normalizeUrl(parameters["url"] ?: return null)
            val name = parameters["name"]?.let(ProfileCatalogStore::normalizedName)
            Draft(url, name)
        } catch (_: Exception) { null }
    }

    private fun decode(value: String): String {
        // Form encoding is used by the public import link builder. URLDecoder is strict
        // about percent escapes; the policy rejects decoded controls and credentials.
        return URLDecoder.decode(value, StandardCharsets.UTF_8.name())
    }
}

/** Fixed external destinations. Opening them does not authenticate Flow. */
object PushokExternalLinks {
    enum class Destination(val telegramUrl: String, val webUrl: String) {
        ACCOUNT("tg://resolve?domain=mtproxy_pushok_bot", "https://pushok.shop/"),
        HUB("tg://resolve?domain=pushok_app", "https://t.me/pushok_app"),
    }

    fun open(destination: Destination, startActivity: (String) -> Unit) {
        try {
            // Attempt the custom scheme directly: Android package visibility must not
            // incorrectly hide an installed Telegram handler from resolveActivity.
            startActivity(destination.telegramUrl)
            return
        } catch (_: Exception) {
            // No Telegram handler, or Android could not start it. A browser can still
            // open the existing web cabinet (or the separate ecosystem entry point).
        }
        // Propagate a failed fallback so the method channel reports an error.
        startActivity(destination.webUrl)
    }
}

/** Limits automatic checks without turning a network failure into an empty catalogue. */
object SubscriptionRefreshPolicy {
    const val SUCCESS_INTERVAL_MS = 6 * 60 * 60 * 1000L
    const val RETRY_INTERVAL_MS = 60 * 60 * 1000L

    fun due(now: Long, updatedAt: Long, lastAttemptAt: Long): Boolean {
        if (now <= 0 || updatedAt < 0 || lastAttemptAt < 0) return false
        // A backwards clock must not create an immediate retry loop.
        if (now < updatedAt || now < lastAttemptAt) return false
        return (updatedAt == 0L || now - updatedAt >= SUCCESS_INTERVAL_MS) &&
            (lastAttemptAt == 0L || now - lastAttemptAt >= RETRY_INTERVAL_MS)
    }
}
