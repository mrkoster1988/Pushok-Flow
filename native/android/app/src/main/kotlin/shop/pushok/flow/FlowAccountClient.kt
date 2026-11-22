package shop.pushok.flow

import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/** One bounded native operation; pausing/cancelling owns its connection, never another request's. */
internal class FlowAccountCall(private val current: () -> Boolean) {
    private val cancelled = AtomicBoolean(false)
    private val timedOut = AtomicBoolean(false)
    val deadline = SystemClock.elapsedRealtime() + 20_000L
    @Volatile var connection: HttpsURLConnection? = null
    fun cancel(timeout: Boolean = false) {
        if (timeout) timedOut.set(true)
        cancelled.set(true)
        try { connection?.disconnect() } catch (_: Exception) { }
    }
    fun check() {
        if (timedOut.get() || SystemClock.elapsedRealtime() >= deadline) throw FlowAccountFailure("FLOW_TIMEOUT")
        if (cancelled.get() || !current()) throw FlowAccountFailure("FLOW_INTERRUPTED")
    }
    fun timeout(): Int {
        check()
        return (deadline - SystemClock.elapsedRealtime()).coerceIn(1, 10_000).toInt()
    }
}

/** No WebView, cookies, caller URLs or redirects. Flow credentials can reach only /me and /logout. */
internal class FlowAccountClient(private val call: FlowAccountCall) : FlowAccountRemote {
    companion object {
        private val timeoutQueue = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "pushok-account-timeout").apply { isDaemon = true }
        }
    }
    override fun request(method: String, path: String, token: String?, body: Map<String, Any?>?): FlowAccountResponse {
        val expected = mapOf("/capabilities" to "GET", "/device" to "POST", "/device/token" to "POST",
            "/me" to "GET", "/logout" to "POST")
        if (expected[path] != method || (path in setOf("/me", "/logout")) != (token != null))
            throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
        token?.let(FlowAccountPolicy::requireAccessToken)
        call.check()
        val connection = URL("${FlowAccountPolicy.ORIGIN}/api/v1/flow$path").openConnection() as HttpsURLConnection
        call.connection = connection
        val timeout = timeoutQueue.schedule({ call.cancel(timeout = true) },
            (call.deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1), TimeUnit.MILLISECONDS)
        try {
            call.check()
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = call.timeout()
            connection.readTimeout = call.timeout()
            connection.requestMethod = method
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Cache-Control", "no-store")
            if (token != null) connection.setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                val bytes = FlowAccountJson.encode(body)
                try {
                    if (bytes.size > FlowAccountPolicy.MAX_REQUEST_BYTES) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    connection.setFixedLengthStreamingMode(bytes.size)
                    connection.outputStream.use { it.write(bytes) }
                } finally { bytes.fill(0) }
            }
            call.check()
            connection.readTimeout = call.timeout()
            val status = connection.responseCode
            if (status in 300..399) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
            // Authentication/availability status is authoritative even when an old proxy returns
            // HTML or an oversized error page. Never keep an invalid credential because of its body.
            if (status in setOf(401, 403, 410, 404, 405, 501, 503)) {
                call.check()
                return FlowAccountResponse(status)
            }
            if (connection.contentLengthLong > FlowAccountPolicy.MAX_JSON_BYTES) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
            if (status == 204) { call.check(); return FlowAccountResponse(status) }
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val output = ByteArrayOutputStream()
            stream?.use { input ->
                val buffer = ByteArray(4096)
                while (true) {
                    call.check()
                    connection.readTimeout = call.timeout()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > FlowAccountPolicy.MAX_JSON_BYTES) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
                    output.write(buffer, 0, count)
                }
            }
            call.check()
            val bytes = output.toByteArray()
            val json = try {
                val jsonType = connection.contentType?.substringBefore(';')?.trim()?.lowercase() == "application/json"
                if (status in 200..299 && (!jsonType || bytes.isEmpty())) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
                if (jsonType && bytes.isNotEmpty()) FlowAccountJson.parse(bytes) else emptyMap()
            } finally { bytes.fill(0) }
            val retryAfter = connection.getHeaderField("Retry-After")?.toIntOrNull()?.takeIf { it in 1..300 }
            return FlowAccountResponse(status, json, retryAfter)
        } catch (failure: FlowAccountFailure) { throw failure }
        catch (_: SocketTimeoutException) { throw FlowAccountFailure("FLOW_TIMEOUT") }
        catch (_: Exception) { call.check(); throw FlowAccountFailure("FLOW_NETWORK_ERROR") }
        finally {
            timeout.cancel(false)
            if (call.connection === connection) call.connection = null
            connection.disconnect()
        }
    }
}
