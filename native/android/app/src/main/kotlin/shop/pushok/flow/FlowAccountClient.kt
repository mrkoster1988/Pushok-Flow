package shop.pushok.flow

import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection

/** One command budget, shared by its sequential HTTP exchanges; cancellation never waits for I/O. */
internal class FlowAccountCall(private val current: () -> Boolean) {
    private val cancelled = AtomicBoolean(false)
    private val active = AtomicReference<BoundedNetworkCall<FlowAccountResponse>?>(null)
    val deadline = SystemClock.elapsedRealtime() + 20_000L
    fun cancel() {
        cancelled.set(true)
        active.get()?.cancel()
    }
    fun check() {
        if (SystemClock.elapsedRealtime() >= deadline) throw FlowAccountFailure("FLOW_TIMEOUT")
        if (cancelled.get() || !current()) throw FlowAccountFailure("FLOW_INTERRUPTED")
    }
    fun timeout(): Int {
        check()
        return (deadline - SystemClock.elapsedRealtime()).coerceIn(1, 10_000).toInt()
    }
    fun attach(request: BoundedNetworkCall<FlowAccountResponse>) {
        check()
        if (!active.compareAndSet(null, request)) throw FlowAccountFailure("FLOW_BUSY")
        try { check() }
        catch (failure: FlowAccountFailure) {
            active.compareAndSet(request, null)
            request.cancel()
            throw failure
        }
    }
    fun detach(request: BoundedNetworkCall<FlowAccountResponse>) {
        active.compareAndSet(request, null)
    }
}

/** No WebView, cookies, caller URLs or redirects. Flow credentials can reach only /me and /logout. */
internal class FlowAccountClient(private val call: FlowAccountCall,
    private val transport: BoundedNetworkPool = sharedTransport,
    private val open: (URL) -> HttpsURLConnection = { it.openConnection() as HttpsURLConnection },
) : FlowAccountRemote {
    companion object {
        private val sharedTransport = BoundedNetworkPool("pushok-account", workers = 2)
    }
    override fun request(method: String, path: String, token: String?, body: Map<String, Any?>?): FlowAccountResponse {
        val expected = mapOf("/capabilities" to "GET", "/device" to "POST", "/device/token" to "POST",
            "/me" to "GET", "/logout" to "POST", "/push-config" to "GET", "/push-device" to "POST")
        if (expected[path] != method || (path in setOf("/me", "/logout", "/push-device")) != (token != null))
            throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
        token?.let(FlowAccountPolicy::requireAccessToken)
        call.check()
        val request = transport.newCall<FlowAccountResponse>(call.deadline, SystemClock::elapsedRealtime)
        call.attach(request)
        try {
            // Only HTTP and parsing run in the bounded pool. The session manager
            // and every durable/epoch-guarded commit stay on the serial caller.
            return request.run(ensureActive = call::check) { active ->
                exchange(active, method, path, token, body)
            }
        } catch (failure: BoundedNetworkFailure) {
            throw FlowAccountFailure(when (failure.kind) {
                BoundedNetworkFailure.Kind.TIMEOUT -> "FLOW_TIMEOUT"
                BoundedNetworkFailure.Kind.CANCELLED -> "FLOW_INTERRUPTED"
                BoundedNetworkFailure.Kind.BUSY -> "FLOW_NETWORK_ERROR"
            })
        } finally { call.detach(request) }
    }

    private fun exchange(active: BoundedNetworkCall<FlowAccountResponse>, method: String, path: String,
        token: String?, body: Map<String, Any?>?): FlowAccountResponse {
        fun check() { active.check(); call.check() }
        var connection: HttpsURLConnection? = null
        try {
            check()
            connection = open(URL("${FlowAccountPolicy.ORIGIN}/api/v1/flow$path"))
            // The closure owns this exact connection, including when open() only
            // returns after cancellation. Never disconnect a later request.
            val owned = connection
            active.setAbort { try { owned.disconnect() } catch (_: Exception) { } }
            check()
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
                    connection.outputStream.use {
                        check()
                        it.write(bytes)
                        check()
                    }
                } finally { bytes.fill(0) }
            }
            check()
            connection.readTimeout = call.timeout()
            val status = connection.responseCode
            check()
            if (status in 300..399) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
            // Authentication/availability status is authoritative even when an old proxy returns
            // HTML or an oversized error page. Never keep an invalid credential because of its body.
            if (status in setOf(401, 403, 410, 404, 405, 501, 503)) {
                check()
                return FlowAccountResponse(status)
            }
            if (connection.contentLengthLong > FlowAccountPolicy.MAX_JSON_BYTES) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
            if (status == 204) { check(); return FlowAccountResponse(status) }
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val output = ByteArrayOutputStream()
            stream?.use { input ->
                val buffer = ByteArray(4096)
                while (true) {
                    check()
                    connection.readTimeout = call.timeout()
                    val count = input.read(buffer)
                    check()
                    if (count < 0) break
                    if (output.size() + count > FlowAccountPolicy.MAX_JSON_BYTES) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
                    output.write(buffer, 0, count)
                }
            }
            check()
            val bytes = output.toByteArray()
            val json = try {
                val jsonType = connection.contentType?.substringBefore(';')?.trim()?.lowercase() == "application/json"
                check()
                if (status in 200..299 && (!jsonType || bytes.isEmpty())) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
                if (jsonType && bytes.isNotEmpty()) FlowAccountJson.parse(bytes) else emptyMap()
            } finally { bytes.fill(0) }
            val retryAfter = connection.getHeaderField("Retry-After")?.toIntOrNull()?.takeIf { it in 1..300 }
            check()
            return FlowAccountResponse(status, json, retryAfter)
        } catch (failure: FlowAccountFailure) { throw failure }
        catch (failure: BoundedNetworkFailure) { throw failure }
        catch (_: SocketTimeoutException) { throw FlowAccountFailure("FLOW_TIMEOUT") }
        catch (_: Exception) { check(); throw FlowAccountFailure("FLOW_NETWORK_ERROR") }
        finally {
            active.setAbort(null)
            // Provider cleanup may block as well; it occupies only this bounded
            // transport worker and can never hold the main or serial state thread.
            try { connection?.disconnect() } catch (_: Exception) { }
        }
    }
}
