package shop.pushok.flow

import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.URI
import java.net.URL
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection

/** HTTPS only, bounded bytes/time, explicit redirects and constant diagnostics. */
class SubscriptionDownloader internal constructor(
    private val resolve: (String) -> Array<InetAddress>,
    private val open: (URL) -> HttpsURLConnection,
    private val elapsedMs: () -> Long,
    private val network: BoundedNetworkPool,
) {
    constructor(
        resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName,
        open: (URL) -> HttpsURLConnection = { it.openConnection() as HttpsURLConnection },
        elapsedMs: () -> Long = { System.nanoTime() / 1_000_000L },
    ) : this(resolve, open, elapsedMs, sharedNetwork)

    class Response(val body: ByteArray, val userInfo: String?, val title: String?) {
        override fun toString() = "SubscriptionResponse(redacted)"
    }

    private val activeCall = AtomicReference<BoundedNetworkCall<Response>?>()

    companion object {
        // Shared across Activity recreation. A non-cooperative resolver/transport
        // occupies one of these fixed slots until the underlying call really ends.
        private val sharedNetwork = BoundedNetworkPool("pushok-subscription")
    }

    fun cancel() {
        activeCall.get()?.cancel()
    }

    fun fetch(rawUrl: String, ensureActive: () -> Unit = {}): Response {
        val call = network.newCall<Response>(elapsedMs() + 40_000L, elapsedMs) { it.body.fill(0) }
        if (!activeCall.compareAndSet(null, call)) throw SubscriptionFailure("SUBSCRIPTION_BUSY")
        try {
            // Includes the resolver and URLConnection's own DNS/connect/header/body
            // work. Socket timeouts alone cannot bound all platform implementations.
            return call.run(ensureActive) { fetchRemote(rawUrl, it) }
        } catch (failure: BoundedNetworkFailure) {
            throw SubscriptionFailure(when (failure.kind) {
                BoundedNetworkFailure.Kind.CANCELLED -> "SUBSCRIPTION_INTERRUPTED"
                BoundedNetworkFailure.Kind.BUSY -> "SUBSCRIPTION_NETWORK_ERROR"
                BoundedNetworkFailure.Kind.TIMEOUT -> "SUBSCRIPTION_NETWORK_ERROR"
            })
        } catch (failure: SubscriptionFailure) {
            throw failure
        } catch (_: Exception) {
            // The raw IOException may contain the complete URL and access token.
            ensureActive()
            throw SubscriptionFailure("SUBSCRIPTION_NETWORK_ERROR")
        } finally {
            call.cancel()
            activeCall.compareAndSet(call, null)
        }
    }

    private fun fetchRemote(rawUrl: String, call: BoundedNetworkCall<Response>): Response {
        var url = SubscriptionPolicy.normalizeUrl(rawUrl)
        for (redirect in 0..3) {
            call.check()
            val parsed = URI(url)
            val addresses = resolve(parsed.host)
            if (addresses.isEmpty() || addresses.any { !SubscriptionPolicy.isPublicAddress(it) }) {
                throw SubscriptionFailure("SUBSCRIPTION_URL_INVALID")
            }
            call.check()
            var current: HttpsURLConnection? = null
            try {
                val opened = open(parsed.toURL())
                current = opened
                call.setAbort { opened.disconnect() }
                call.check()
                current.instanceFollowRedirects = false
                current.connectTimeout = call.timeout()
                current.readTimeout = call.timeout()
                current.useCaches = false
                current.setRequestProperty("Accept", "text/plain, application/octet-stream;q=0.9")
                current.setRequestProperty("Accept-Encoding", "identity")
                current.setRequestProperty("Cache-Control", "no-cache")
                current.setRequestProperty("User-Agent", "Pushok-Flow-Subscriptions")
                val status = current.responseCode
                call.check()
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
                val body = current.inputStream.use { input ->
                    val bytes = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    try {
                        while (true) {
                            call.check()
                            current.readTimeout = call.timeout()
                            val count = input.read(buffer)
                            if (count == -1) break
                            if (count > SubscriptionPolicy.MAX_BYTES - bytes.size()) {
                                throw SubscriptionFailure("SUBSCRIPTION_TOO_LARGE")
                            }
                            bytes.write(buffer, 0, count)
                        }
                        bytes.toByteArray()
                    } finally { buffer.fill(0) }
                }
                try {
                    call.check()
                    return Response(body, userInfo, title)
                } catch (failure: Throwable) {
                    body.fill(0)
                    throw failure
                }
            } finally {
                // Cleanup may itself block in platform code; it stays on the bounded
                // worker and never delays cancellation/timeout on the waiting caller.
                try { current?.disconnect() } catch (_: Exception) { }
                call.setAbort(null)
            }
        }
        throw SubscriptionFailure("SUBSCRIPTION_NETWORK_ERROR")
    }

    private fun boundedHeader(value: String?): String? = value?.also {
        if (it.length > 4096 || it.any { character -> character.code < 32 || character.code == 127 }) {
            throw SubscriptionFailure("SUBSCRIPTION_INVALID")
        }
    }

}
