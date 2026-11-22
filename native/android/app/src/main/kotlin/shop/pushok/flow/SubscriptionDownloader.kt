package shop.pushok.flow

import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.URI
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** HTTPS only, bounded bytes/time, explicit redirects and constant diagnostics. */
class SubscriptionDownloader(
    private val resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
    private val open: (URL) -> HttpsURLConnection = { it.openConnection() as HttpsURLConnection },
    private val elapsedMs: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    class Response(val body: ByteArray, val userInfo: String?, val title: String?) {
        override fun toString() = "SubscriptionResponse(redacted)"
    }

    @Volatile private var connection: HttpsURLConnection? = null

    fun cancel() {
        try { connection?.disconnect() } catch (_: Exception) { /* Never include a secret URL. */ }
    }

    fun fetch(rawUrl: String, ensureActive: () -> Unit = {}): Response {
        var url = SubscriptionPolicy.normalizeUrl(rawUrl)
        val deadline = elapsedMs() + 40_000L
        try {
            for (redirect in 0..3) {
                ensureActive()
                val parsed = URI(url)
                val addresses = resolve(parsed.host)
                if (addresses.isEmpty() || addresses.any { !SubscriptionPolicy.isPublicAddress(it) }) {
                    throw SubscriptionFailure("SUBSCRIPTION_URL_INVALID")
                }
                ensureActive()
                var current: HttpsURLConnection? = null
                try {
                    current = open(parsed.toURL())
                    connection = current
                    ensureActive()
                    current.instanceFollowRedirects = false
                    current.connectTimeout = remaining(deadline)
                    current.readTimeout = remaining(deadline)
                    current.useCaches = false
                    current.setRequestProperty("Accept", "text/plain, application/octet-stream;q=0.9")
                    current.setRequestProperty("Accept-Encoding", "identity")
                    current.setRequestProperty("Cache-Control", "no-cache")
                    current.setRequestProperty("User-Agent", "Pushok-Flow-Subscriptions")
                    val status = current.responseCode
                    ensureActive()
                    if (status in setOf(301, 302, 303, 307, 308)) {
                        if (redirect == 3) throw SubscriptionFailure("SUBSCRIPTION_NETWORK_ERROR")
                        val location = current.getHeaderField("Location")
                            ?: throw SubscriptionFailure("SUBSCRIPTION_NETWORK_ERROR")
                        if (location.length > SubscriptionLinks.MAX_LINK_LENGTH) {
                            throw SubscriptionFailure("SUBSCRIPTION_URL_INVALID")
                        }
                        url = SubscriptionPolicy.normalizeUrl(parsed.resolve(location).toASCIIString())
                        continue
                    }
                    if (status == 401 || status == 403) throw SubscriptionFailure("SUBSCRIPTION_AUTH_REQUIRED")
                    if (status != 200) throw SubscriptionFailure("SUBSCRIPTION_NETWORK_ERROR")
                    if (current.contentLengthLong > SubscriptionPolicy.MAX_BYTES) {
                        throw SubscriptionFailure("SUBSCRIPTION_TOO_LARGE")
                    }
                    if (current.contentEncoding?.let { it.isNotBlank() && !it.equals("identity", true) } == true) {
                        throw SubscriptionFailure("SUBSCRIPTION_INVALID")
                    }
                    val userInfo = boundedHeader(current.getHeaderField("Subscription-Userinfo"))
                    val title = boundedHeader(current.getHeaderField("Profile-Title"))
                    val active = current
                    val body = active.inputStream.use { input ->
                        val bytes = ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            ensureActive()
                            active.readTimeout = remaining(deadline)
                            val count = input.read(buffer)
                            if (count == -1) break
                            if (count > SubscriptionPolicy.MAX_BYTES - bytes.size()) {
                                throw SubscriptionFailure("SUBSCRIPTION_TOO_LARGE")
                            }
                            bytes.write(buffer, 0, count)
                        }
                        bytes.toByteArray()
                    }
                    ensureActive()
                    return Response(body, userInfo, title)
                } finally {
                    try { current?.disconnect() } catch (_: Exception) { }
                    if (connection === current) connection = null
                }
            }
            throw SubscriptionFailure("SUBSCRIPTION_NETWORK_ERROR")
        } catch (failure: SubscriptionFailure) {
            throw failure
        } catch (_: Exception) {
            // The raw IOException may contain the complete URL and access token.
            ensureActive()
            throw SubscriptionFailure("SUBSCRIPTION_NETWORK_ERROR")
        }
    }

    private fun remaining(deadline: Long): Int {
        val remaining = deadline - elapsedMs()
        if (remaining <= 0) throw SubscriptionFailure("SUBSCRIPTION_NETWORK_ERROR")
        return remaining.coerceAtMost(10_000L).toInt()
    }

    private fun boundedHeader(value: String?): String? = value?.also {
        if (it.length > 4096 || it.any { character -> character.code < 32 || character.code == 127 }) {
            throw SubscriptionFailure("SUBSCRIPTION_INVALID")
        }
    }

}
