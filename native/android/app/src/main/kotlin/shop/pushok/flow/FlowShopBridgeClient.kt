package shop.pushok.flow

import android.content.Context
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.net.SocketTimeoutException
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** No external account token or personal subscription URL is exposed to Flutter. */
internal class FlowShopBridgeClient(
    private val context: Context,
    private val open: (URL) -> HttpsURLConnection = { it.openConnection() as HttpsURLConnection },
) {
    private companion object {
        // Applies across Activity re-creations in this process. A manual tap and
        // an automatic refresh must not repeatedly hit the same rate limiter.
        @Volatile private var retryNotBeforeMs = 0L
        private const val RATE_LIMIT_PAUSE_MS = 65_000L
    }

    /** Each request has its own TLS connection, fixed first-party host and bounded response. */
    fun exchange(accessToken: String, isCurrent: () -> Unit): FlowShopBridgePolicy.Reply {
        FlowAccountPolicy.requireAccessToken(accessToken)
        val start = SystemClock.elapsedRealtime()
        isCurrent()
        if (start < retryNotBeforeMs) throw FlowShopFailure("SHOP_RATE_LIMITED")
        val ticketResponse = post(FlowShopBridgePolicy.TICKET_URL,
            mapOf("consent" to true), accessToken, start, isCurrent)
        val ticket = FlowShopBridgePolicy.requireTicket(ticketResponse)
        isCurrent()
        // Access is bound to the server-verified Pushok account, not a phone.
        // The one-time ticket is the only identity proof; no client_id is sent.
        val reply = post(FlowShopBridgePolicy.EXCHANGE_URL,
            mapOf("ticket" to ticket), null, start, isCurrent)
        isCurrent()
        return FlowShopBridgePolicy.parseExchange(reply)
    }

    fun telegramAvailable(): Boolean {
        val uri = android.net.Uri.parse("tg://resolve?domain=mtproxy_pushok_bot")
        return android.content.Intent(android.content.Intent.ACTION_VIEW, uri)
            .resolveActivity(context.packageManager) != null
    }

    fun guest(isCurrent: () -> Unit): FlowShopBridgePolicy.Reply {
        val started = SystemClock.elapsedRealtime()
        if (started < retryNotBeforeMs) throw FlowShopFailure("SHOP_RATE_LIMITED")
        val device = android.provider.Settings.Secure.getString(context.contentResolver,
            android.provider.Settings.Secure.ANDROID_ID)?.takeIf { it.isNotBlank() }
            ?: throw FlowShopFailure("SHOP_STORAGE_ERROR")
        val deviceHash = FlowShopBindingStore.fingerprint("pushok-flow-guest-v1:" + device)
        // Derive a distinct high-entropy proof inside this installation. The
        // scoped device identifier by itself never grants access to a feed.
        val proof = try {
            val alias = "pushok-flow-guest-v1"
            val store = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val key = store.getKey(alias, null) ?: javax.crypto.KeyGenerator
                .getInstance("HmacSHA256", "AndroidKeyStore").run {
                    init(android.security.keystore.KeyGenParameterSpec.Builder(alias,
                        android.security.keystore.KeyProperties.PURPOSE_SIGN)
                        .setDigests(android.security.keystore.KeyProperties.DIGEST_SHA256).build())
                    generateKey()
                }
            javax.crypto.Mac.getInstance("HmacSHA256").run {
                init(key)
                doFinal(deviceHash.toByteArray(Charsets.US_ASCII)).joinToString("") {
                    "%02x".format(java.util.Locale.ROOT, it.toInt() and 255)
                }
            }
        } catch (_: Exception) { throw FlowShopFailure("SHOP_STORAGE_ERROR") }
        val reply = post("https://pushok.shop/shop/api/flow/guest", mapOf("device" to deviceHash),
            proof, started, isCurrent)
        return FlowShopBridgePolicy.parseExchange(reply)
    }

    private fun post(address: String, body: Map<String, Any?>, token: String?,
                     started: Long, isCurrent: () -> Unit): Map<String, Any?> {
        var connection: HttpsURLConnection? = null
        val data = FlowAccountJson.encode(body)
        try {
            if (data.size > 4096) throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
            isCurrent()
            val url = URL(address)
            if (url.protocol != "https" || url.userInfo != null ||
                url.host != "pushok.shop" || url.port != -1 ||
                url.ref != null || url.query != null) throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
            connection = open(url)
            val remote = connection
            remote.instanceFollowRedirects = false
            remote.useCaches = false
            remote.connectTimeout = budget(started)
            remote.readTimeout = budget(started)
            remote.requestMethod = "POST"
            remote.doOutput = true
            remote.setRequestProperty("Accept", "application/json")
            remote.setRequestProperty("Accept-Encoding", "identity")
            remote.setRequestProperty("Cache-Control", "no-store")
            remote.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            remote.setRequestProperty("Cookie", "")
            token?.let { remote.setRequestProperty("Authorization", "Bearer $it") }
            remote.setFixedLengthStreamingMode(data.size)
            remote.outputStream.use { output ->
                isCurrent()
                output.write(data)
                isCurrent()
            }
            remote.readTimeout = budget(started)
            val status = remote.responseCode
            isCurrent()
            if (status != 200) throw FlowShopFailure(when (status) {
                401, 403 -> "SHOP_LOGIN_REQUIRED"
                409 -> readConflict(remote, started, isCurrent)
                429 -> {
                    retryNotBeforeMs = SystemClock.elapsedRealtime() + RATE_LIMIT_PAUSE_MS
                    "SHOP_RATE_LIMITED"
                }
                404, 405, 501, 503 -> "SHOP_SERVICE_UNAVAILABLE"
                in 500..599 -> "SHOP_NETWORK_ERROR"
                else -> "SHOP_PROTOCOL_INVALID"
            })
            if (remote.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json" ||
                remote.contentLengthLong > 8192 ||
                remote.contentEncoding?.let { it.isNotBlank() && it != "identity" } == true) {
                throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
            }
            val out = ByteArrayOutputStream()
            remote.inputStream.use { input ->
                val buffer = ByteArray(2048)
                while (true) {
                    isCurrent()
                    remote.readTimeout = budget(started)
                    val count = input.read(buffer)
                    isCurrent()
                    if (count < 0) break
                    if (count > 8192 - out.size()) throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
                    out.write(buffer, 0, count)
                }
            }
            val received = out.toByteArray()
            try {
                if (received.isEmpty()) throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
                return try { FlowAccountJson.parse(received) }
                    catch (_: FlowAccountFailure) { throw FlowShopFailure("SHOP_PROTOCOL_INVALID") }
            } finally { received.fill(0) }
        } catch (failure: FlowShopFailure) { throw failure }
        catch (failure: SubscriptionFailure) { throw failure }
        catch (failure: FlowAccountFailure) { throw FlowShopFailure("SHOP_LOGIN_REQUIRED") }
        catch (_: SocketTimeoutException) { throw FlowShopFailure("SHOP_NETWORK_ERROR") }
        catch (_: Exception) { isCurrent(); throw FlowShopFailure("SHOP_NETWORK_ERROR") }
        finally {
            data.fill(0)
            try { connection?.disconnect() } catch (_: Exception) { }
        }
    }

    /** Only a bounded, whitelisted HTTP 409 reason may reach Flutter. */
    private fun readConflict(remote: HttpsURLConnection, started: Long,
                             isCurrent: () -> Unit): String {
        val fallback = "SHOP_CONFLICT"
        if (remote.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json" ||
            remote.contentLengthLong > 1024L ||
            remote.contentEncoding?.let { it.isNotBlank() && it != "identity" } == true) {
            return fallback
        }
        return try {
            val input = remote.errorStream ?: return fallback
            val output = ByteArrayOutputStream()
            input.use { stream ->
                val buffer = ByteArray(256)
                while (true) {
                    isCurrent()
                    remote.readTimeout = budget(started)
                    val count = stream.read(buffer)
                    if (count < 0) break
                    if (count > 1024 - output.size()) return fallback
                    output.write(buffer, 0, count)
                }
            }
            val bytes = output.toByteArray()
            try {
                if (bytes.isEmpty()) fallback
                else FlowShopBridgePolicy.conflictCode(FlowAccountJson.parse(bytes))
            } finally { bytes.fill(0) }
        } catch (error: Exception) {
            isCurrent()
            fallback
        }
    }

    private fun budget(start: Long): Int {
        val left = 25_000L - (SystemClock.elapsedRealtime() - start)
        if (left <= 0) throw FlowShopFailure("SHOP_NETWORK_ERROR")
        return left.coerceAtMost(10_000L).toInt()
    }
}
