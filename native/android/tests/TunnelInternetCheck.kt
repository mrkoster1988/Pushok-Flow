package shop.pushok.flow

import java.io.ByteArrayOutputStream
import java.io.File
import java.net.InetAddress
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.nio.file.Files
import java.security.KeyStore
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory
import javax.net.ssl.ExtendedSSLSession
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory

private fun ip(value: String): InetAddress = InetAddress.getByName(value)
private val v4 = ip("192.0.2.10")
private val v4Other = ip("192.0.2.11")
private val v6 = ip("2001:db8::10")
private fun route(prefix: String, device: String? = "tun0", unicast: Boolean = true): TunnelInternetPolicy.Route {
    val parts = prefix.split('/')
    return TunnelInternetPolicy.Route(ip(parts[0]), parts[1].toInt(), device, unicast)
}
private fun routes(vararg entries: TunnelInternetPolicy.Route) = TunnelInternetPolicy.Routes("tun0", entries.toList())
private val v4Routes = routes(route("0.0.0.0/0"))
private val dualRoutes = routes(route("0.0.0.0/0"), route("::/0"))

fun main() {
    policyChecks()
    cancellationAndDnsChecks()
    val fixtureDirectory = Files.createTempDirectory("flow-probe-tls-").toFile()
    try {
        val valid = TlsFixture(fixtureDirectory, "valid", "example.com")
        val wrongName = TlsFixture(fixtureDirectory, "wrong-name", "different.example")
        tlsChecks(valid, wrongName)
        inFlightChecks(valid)
    } finally {
        fixtureDirectory.deleteRecursively()
    }
    println("Tunnel internet dual-stack routes, pinned sockets, TLS identity and bounded cancellation checks passed")
}

private fun policyChecks() {
    // The regression: an AAAA answer must not suppress a working IPv4-only tunnel.
    check(TunnelInternetPolicy.candidates(listOf(v6, v4, v4), v4Routes) == listOf(v4))
    check(TunnelInternetPolicy.candidates(listOf(v4, v6), routes(route("::/0"))) == listOf(v6))
    check(TunnelInternetPolicy.candidates(listOf(v4, v4Other, v6), dualRoutes) == listOf(v4, v6, v4Other))
    check(TunnelInternetPolicy.candidates(listOf(v6), v4Routes).isEmpty())
    check(TunnelInternetPolicy.candidates(listOf(v4), routes()).isEmpty())
    check(!TunnelInternetPolicy.allows(v4, v4Routes.copy(interfaceName = null)))
    check(!TunnelInternetPolicy.allows(v4, routes(route("0.0.0.0/0", device = "wlan0"))))
    check(!TunnelInternetPolicy.allows(v4, routes(route("0.0.0.0/0", device = null))))
    // RTN_THROW/RTN_UNREACHABLE and another interface override the broad VPN route.
    for (excluded in listOf(route("192.0.2.0/24", unicast = false),
        route("192.0.2.0/24", device = "wlan0"))) {
        check(!TunnelInternetPolicy.allows(v4, routes(route("0.0.0.0/0"), excluded)))
        check(TunnelInternetPolicy.allows(v4, routes(route("0.0.0.0/0"), excluded, route("192.0.2.10/32"))))
    }
    check(!TunnelInternetPolicy.allows(v6, routes(route("::/0"), route("2001:db8::/64", unicast = false))))
    check(!TunnelInternetPolicy.allows(v4, routes(route("0.0.0.0/0"), route("0.0.0.0/0", unicast = false))))
    check(TunnelInternetPolicy.allows(v4, routes(route("192.0.2.8/31"), route("192.0.2.10/31"))))
    check(!TunnelInternetPolicy.allows(v4Other, routes(route("192.0.2.10/32"))))
    check(TunnelInternetPolicy.allows(v6, routes(route("2001:db8::10/127"))))
    check(!TunnelInternetPolicy.allows(ip("2001:db8::12"), routes(route("2001:db8::10/127"))))
    for (invalid in listOf("0.0.0.0", "127.0.0.1", "169.254.1.1", "224.0.0.1", "255.255.255.255",
        "::", "::1", "fe80::1", "ff02::1")) {
        check(!TunnelInternetPolicy.allows(ip(invalid), dualRoutes)) { "Non-unicast/local destination accepted" }
    }
    val mapped = ByteArray(16).apply {
        this[10] = -1; this[11] = -1
        v4.address.copyInto(this, 12)
    }
    check(!TunnelInternetPolicy.allows(Inet6Address.getByAddress(null, mapped, -1), routes(route("::/0"))))
}

private class RecordingNetworkFactory(
    private val localPort: Int = 1,
    private val failAddresses: Set<InetAddress> = emptySet(),
) : SocketFactory() {
    val opened = AtomicInteger()
    val attempts = Collections.synchronizedList(mutableListOf<InetSocketAddress>())
    val closed = CountDownLatch(1)
    override fun createSocket(): Socket {
        opened.incrementAndGet()
        return object : Socket() {
            override fun connect(endpoint: SocketAddress, timeout: Int) {
                val selected = endpoint as InetSocketAddress
                check(!selected.isUnresolved && selected.port == 443 && timeout in 1..1500)
                attempts += selected
                if (selected.address in failAddresses) throw SocketTimeoutException()
                // Only the JVM fixture maps a recorded, route-approved endpoint to
                // loopback. Production gets this factory from Android Network.
                super.connect(InetSocketAddress(InetAddress.getLoopbackAddress(),
                    this@RecordingNetworkFactory.localPort), timeout)
            }
            override fun close() { try { super.close() } finally { closed.countDown() } }
        }
    }
    override fun createSocket(host: String, port: Int): Socket = error("Unexpected second DNS lookup")
    override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket = error("Unexpected DNS")
    override fun createSocket(host: InetAddress, port: Int): Socket = error("Unbounded connect")
    override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket = error("Unbounded connect")
}

private fun probe(label: String) = TunnelInternetProbe(BoundedNetworkPool("test-$label", workers = 1))

private fun cancellationAndDnsChecks() {
    val untouched = RecordingNetworkFactory()
    check(probe("not-owned").check({ false }, v4Routes,
        { error("Must not resolve after ownership loss") }, untouched) == "unknown")
    check(probe("no-route").check({ true }, v4Routes, { listOf(v6) }, untouched) == "unknown")
    check(probe("dns-empty").check({ true }, v4Routes, { emptyList() }, untouched) == "dns")
    check(probe("dns-fail").check({ true }, v4Routes, { throw java.net.UnknownHostException() }, untouched) == "dns")
    check(untouched.opened.get() == 0)

    // An uninterruptible resolver cannot hold the caller forever or perform late I/O.
    for (loseOwnership in listOf(false, true)) {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val owned = AtomicBoolean(true)
        val answer = AtomicReference<String>()
        val factory = RecordingNetworkFactory()
        val workFinished = CountDownLatch(1)
        val pool = BoundedNetworkPool("test-dns-deadline", workers = 1,
            afterCompletion = { workFinished.countDown() })
        val worker = Thread {
            answer.set(TunnelInternetProbe(pool).check(owned::get, v4Routes, {
                entered.countDown()
                while (true) {
                    try { release.await(); break } catch (_: InterruptedException) { }
                }
                listOf(v4)
            }, factory, timeoutMs = if (loseOwnership) 3_000L else 150L))
            completed.countDown()
        }.apply { isDaemon = true; start() }
        try {
            check(entered.await(2, TimeUnit.SECONDS))
            if (loseOwnership) owned.set(false)
            check(completed.await(2, TimeUnit.SECONDS)) { "DNS ignored the overall deadline/ownership change" }
            check(answer.get() == if (loseOwnership) "unknown" else "dns")
            // A timed-out stuck call retains its admission slot; repeated checks
            // cannot create an unbounded population of resolver threads.
            check(TunnelInternetProbe(pool).check({ true }, v4Routes, { listOf(v4) }, factory) == "unknown")
        } finally {
            release.countDown()
            worker.join(2_000)
            check(workFinished.await(2, TimeUnit.SECONDS))
        }
        check(factory.opened.get() == 0)
    }
}

/** Real JSSE certificates/handshakes prove that identity checking was not replaced by a fake verifier. */
private class TlsFixture(directory: File, name: String, hostname: String) {
    val serverContext: SSLContext
    val trustedClient: SSLContext
    init {
        val storeFile = File(directory, "$name.p12")
        val password = "flow-test-only".toCharArray()
        val keytool = File(System.getProperty("java.home"), "bin/keytool").absolutePath
        val output = File(directory, "$name.log")
        val process = ProcessBuilder(keytool, "-genkeypair", "-alias", "fixture", "-keyalg", "EC",
            "-groupname", "secp256r1", "-storetype", "PKCS12", "-keystore", storeFile.absolutePath,
            "-storepass", String(password), "-keypass", String(password), "-validity", "1",
            "-dname", "CN=$hostname", "-ext", "SAN=dns:$hostname", "-noprompt")
            .redirectErrorStream(true).redirectOutput(output).start()
        check(process.waitFor(20, TimeUnit.SECONDS) && process.exitValue() == 0) { "TLS fixture generation failed" }
        val store = KeyStore.getInstance("PKCS12").apply { storeFile.inputStream().use { load(it, password) } }
        val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(store, password) }
        serverContext = SSLContext.getInstance("TLS").apply { init(keys.keyManagers, null, null) }
        val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("fixture", store.getCertificate("fixture"))
        }
        val trustManagers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
        trustedClient = SSLContext.getInstance("TLS").apply { init(null, trustManagers.trustManagers, null) }
    }
}

private class TlsServer(
    fixture: TlsFixture,
    private val response: String = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    private val releaseResponse: CountDownLatch? = null,
) : AutoCloseable {
    private val listener = fixture.serverContext.serverSocketFactory.createServerSocket(0, 1,
        InetAddress.getLoopbackAddress()) as SSLServerSocket
    val port = listener.localPort
    val requested = CountDownLatch(1)
    val request = AtomicReference<String>()
    val sni = AtomicReference<String>()
    private val worker = Thread {
        try {
            (listener.accept() as SSLSocket).use { socket ->
                socket.soTimeout = 2_000
                socket.startHandshake()
                sni.set((socket.session as ExtendedSSLSession).requestedServerNames
                    .filterIsInstance<SNIHostName>().singleOrNull()?.asciiName)
                val buffer = ByteArrayOutputStream()
                repeat(2048) {
                    val byte = socket.inputStream.read()
                    if (byte < 0) return@use
                    buffer.write(byte)
                    if (buffer.toString("US-ASCII").endsWith("\r\n\r\n")) {
                        request.set(buffer.toString("US-ASCII"))
                        requested.countDown()
                        releaseResponse?.await(3, TimeUnit.SECONDS)
                        socket.outputStream.write(response.toByteArray(Charsets.US_ASCII))
                        socket.outputStream.flush()
                        return@use
                    }
                }
            }
        } catch (_: Exception) {
            // A rejected certificate, ownership loss or deadline closes this fixture's connection.
        }
    }.apply { isDaemon = true; start() }
    override fun close() {
        releaseResponse?.countDown()
        listener.close()
        worker.join(3_000)
        check(!worker.isAlive)
    }
}

private fun tlsChecks(valid: TlsFixture, wrongName: TlsFixture) {
    TlsServer(valid).use { server ->
        val factory = RecordingNetworkFactory(server.port)
        check(probe("v4-only").check({ true }, v4Routes,
            { host -> check(host == "example.com"); listOf(v6, v4) }, factory,
            valid.trustedClient.socketFactory) == "ok")
        check(factory.attempts.map { it.address } == listOf(v4))
        check(server.request.get().startsWith("GET / HTTP/1.1\r\nHost: example.com\r\n"))
        check(server.sni.get() == "example.com")
        check(factory.closed.await(1, TimeUnit.SECONDS))
    }
    TlsServer(valid).use { server ->
        val factory = RecordingNetworkFactory(server.port, failAddresses = setOf(v4))
        check(probe("dual-fallback").check({ true }, dualRoutes, { listOf(v4, v4Other, v6) }, factory,
            valid.trustedClient.socketFactory) == "ok")
        check(factory.attempts.map { it.address } == listOf(v4, v6))
    }
    TlsServer(wrongName).use { server ->
        val factory = RecordingNetworkFactory(server.port)
        check(probe("wrong-host").check({ true }, v4Routes, { listOf(v4) }, factory,
            wrongName.trustedClient.socketFactory) == "https")
        check(server.request.get() == null) { "Trusted certificate with the wrong hostname reached HTTP" }
    }
    TlsServer(valid).use { server ->
        check(probe("untrusted-cert").check({ true }, v4Routes, { listOf(v4) },
            RecordingNetworkFactory(server.port)) == "https")
        check(server.request.get() == null) { "An untrusted certificate reached HTTP" }
    }
    for (response in listOf("HTTP/1.1 302 Found\r\nLocation: https://other.example/\r\n\r\n",
        "HTTP/1.1 200 " + "x".repeat(300) + "\r\n", "HTTP/1.1 2000 Wrong\r\n")) {
        TlsServer(valid, response).use { server ->
            val factory = RecordingNetworkFactory(server.port)
            val resolutions = AtomicInteger()
            check(probe("http-status").check({ true }, v4Routes,
                { resolutions.incrementAndGet(); listOf(v4) }, factory,
                valid.trustedClient.socketFactory) == "https")
            check(resolutions.get() == 1 && factory.attempts.size == 1)
        }
    }
}

private fun inFlightChecks(fixture: TlsFixture) {
    for (loseOwnership in listOf(false, true)) {
        val release = CountDownLatch(1)
        TlsServer(fixture, releaseResponse = release).use { server ->
            val factory = RecordingNetworkFactory(server.port)
            val owned = AtomicBoolean(true)
            val answer = AtomicReference<String>()
            val complete = CountDownLatch(1)
            val worker = Thread {
                answer.set(probe("in-flight").check(owned::get, v4Routes, { listOf(v4) }, factory,
                    fixture.trustedClient.socketFactory, timeoutMs = if (loseOwnership) 3_000L else 700L))
                complete.countDown()
            }.apply { isDaemon = true; start() }
            try {
                check(server.requested.await(2, TimeUnit.SECONDS))
                if (loseOwnership) owned.set(false)
                check(complete.await(2, TimeUnit.SECONDS))
                check(answer.get() == if (loseOwnership) "unknown" else "https")
                check(factory.closed.await(2, TimeUnit.SECONDS)) { "Abandoned HTTPS socket stayed open" }
            } finally {
                release.countDown()
                worker.join(2_000)
            }
        }
    }
}
