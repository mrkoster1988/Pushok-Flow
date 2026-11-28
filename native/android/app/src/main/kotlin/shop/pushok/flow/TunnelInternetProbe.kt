package shop.pushok.flow

import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** An address-pinned HTTPS probe. The caller supplies the owned VPN's socket factory and DNS. */
internal class TunnelInternetProbe(
    private val pool: BoundedNetworkPool = sharedPool,
    private val elapsedMs: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    companion object {
        private const val HOST = "example.com"
        private const val PORT = 443
        private const val MAX_ADDRESSES = 4
        private const val MAX_STATUS_BYTES = 256
        private const val ATTEMPT_MS = 2_500L
        private const val SOCKET_MS = 1_500
        private val sharedPool = BoundedNetworkPool("flow-internet-probe")
    }

    private class ObsoleteProbe : Exception()

    fun check(
        current: () -> Boolean,
        routes: TunnelInternetPolicy.Routes,
        resolve: (String) -> List<InetAddress>,
        sockets: SocketFactory,
        tls: SSLSocketFactory = SSLSocketFactory.getDefault() as SSLSocketFactory,
        timeoutMs: Long = 7_500L,
    ): String {
        require(timeoutMs in 1..7_500L)
        val phase = AtomicReference("dns")
        val call = pool.newCall<String>(elapsedMs() + timeoutMs, elapsedMs)
        fun ensureCurrent() { if (!current()) throw ObsoleteProbe() }
        return try {
            val status = call.run(::ensureCurrent) { active ->
                ensureCurrent()
                val resolved = resolve(HOST)
                active.check()
                ensureCurrent()
                if (resolved.isEmpty()) return@run "dns"
                val candidates = TunnelInternetPolicy.candidates(resolved, routes).take(MAX_ADDRESSES)
                if (candidates.isEmpty()) return@run "unknown"
                phase.set("https")
                for (address in candidates) {
                    active.check()
                    ensureCurrent()
                    try {
                        if (exchange(address, sockets, tls, active, ::ensureCurrent)) return@run "ok"
                    } catch (obsolete: ObsoleteProbe) {
                        throw obsolete
                    } catch (bounded: BoundedNetworkFailure) {
                        throw bounded
                    } catch (_: Exception) {
                        // Try only another address already approved by the same VPN routes.
                    }
                }
                "https"
            }
            if (current()) status else "unknown"
        } catch (_: ObsoleteProbe) {
            "unknown"
        } catch (failure: BoundedNetworkFailure) {
            if (failure.kind == BoundedNetworkFailure.Kind.TIMEOUT && current()) phase.get() else "unknown"
        } catch (_: Exception) {
            if (current()) phase.get() else "unknown"
        } finally {
            call.cancel()
        }
    }

    private fun exchange(
        address: InetAddress,
        sockets: SocketFactory,
        tls: SSLSocketFactory,
        call: BoundedNetworkCall<String>,
        ensureCurrent: () -> Unit,
    ): Boolean {
        val attemptDeadline = elapsedMs() + ATTEMPT_MS
        fun timeout(): Int {
            ensureCurrent()
            val left = attemptDeadline - elapsedMs()
            if (left <= 0) throw SocketTimeoutException()
            return call.timeout(SOCKET_MS).coerceAtMost(left.toInt())
        }
        // The no-argument overload creates a socket bound to the captured Network.
        // InetSocketAddress(InetAddress, port) cannot resolve a hostname or choose
        // an unapproved family behind our route-policy check.
        val raw = sockets.createSocket()
        call.setAbort { raw.close() }
        try {
            raw.use {
                raw.connect(InetSocketAddress(address, PORT), timeout())
                raw.soTimeout = timeout()
                val secure = tls.createSocket(raw, HOST, PORT, true) as SSLSocket
                call.setAbort {
                    try { raw.close() } finally { secure.close() }
                }
                secure.use {
                    secure.useClientMode = true
                    secure.sslParameters = secure.sslParameters.apply {
                        endpointIdentificationAlgorithm = "HTTPS"
                        serverNames = listOf(SNIHostName(HOST))
                    }
                    secure.soTimeout = timeout()
                    secure.startHandshake()
                    // Certificate trust and hostname verification remain enabled.
                    // An HTTP redirect is a diagnostic failure, never a new destination.
                    secure.soTimeout = timeout()
                    secure.outputStream.write(("GET / HTTP/1.1\r\nHost: $HOST\r\n" +
                        "Connection: close\r\nAccept: */*\r\n\r\n").toByteArray(Charsets.US_ASCII))
                    secure.outputStream.flush()
                    val status = StringBuilder()
                    repeat(MAX_STATUS_BYTES) {
                        secure.soTimeout = timeout()
                        val byte = secure.inputStream.read()
                        if (byte < 0) throw IOException()
                        if (byte == 10) {
                            val line = status.toString()
                            return line.matches(Regex("HTTP/1\\.[01] 200(?: [^\\r\\n]*)?\\r"))
                        }
                        if (byte != 13 && byte !in 32..126) throw IOException()
                        status.append(byte.toChar())
                    }
                    throw IOException()
                }
            }
        } finally {
            // Also covers a late socket/TLS creation after the deadline. Clearing
            // the abort hook only happens after both close paths have completed.
            try { raw.close() } finally { call.setAbort(null) }
        }
    }
}
