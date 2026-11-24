package shop.pushok.flow

import android.content.Context
import android.os.SystemClock
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.net.SocketTimeoutException
import java.net.URL
import java.security.SecureRandom
import javax.net.ssl.HttpsURLConnection

/** No external account token or personal subscription URL is exposed to Flutter. */
internal class FlowShopBridgeClient(
    context: Context,
    private val open: (URL) -> HttpsURLConnection = { it.openConnection() as HttpsURLConnection },
) {
    private val prefs = context.applicationContext.getSharedPreferences("flow_shop_bridge", Context.MODE_PRIVATE)
    private val lock = Any()

    /** Random client binding, not a user identifier. Restored app backups are disabled. */
    fun clientId(): String = synchronized(lock) {
        val known = try { prefs.getString("client_id", null) }
            catch (_: Exception) { throw FlowShopFailure("SHOP_STORAGE_ERROR") }
        if (known != null) {
            if (!FlowShopBridgePolicy.validClientId(known)) throw FlowShopFailure("SHOP_STORAGE_ERROR")
            return@synchronized known
        }
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        val value = try { "pfc_" + Base64.encodeToString(bytes,
            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP) }
            finally { bytes.fill(0) }
        if (!FlowShopBridgePolicy.validClientId(value)) throw FlowShopFailure("SHOP_STORAGE_ERROR")
        val saved = try { prefs.edit().putString("client_id", value).commit() }
            catch (_: Exception) { false }
        if (!saved) throw FlowShopFailure("SHOP_STORAGE_ERROR")
        value
    }

    /** Each request has its own TLS connection, fixed first-party host and bounded response. */
    fun exchange(accessToken: String, isCurrent: () -> Unit): FlowShopBridgePolicy.Reply {
        FlowAccountPolicy.requireAccessToken(accessToken)
        val start = SystemClock.elapsedRealtime()
        isCurrent()
        val ticketResponse = post(FlowShopBridgePolicy.TICKET_URL,
            mapOf("consent" to true), accessToken, start, isCurrent)
        val ticket = FlowShopBridgePolicy.requireTicket(ticketResponse)
        isCurrent()
        val device = clientId()
        val reply = post(FlowShopBridgePolicy.EXCHANGE_URL,
            mapOf("ticket" to ticket, "client_id" to device), null, start, isCurrent)
        isCurrent()
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
                429 -> "SHOP_RATE_LIMITED"
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
