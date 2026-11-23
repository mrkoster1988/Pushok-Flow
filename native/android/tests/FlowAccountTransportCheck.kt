package shop.pushok.flow

import android.os.SystemClock
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.URL
import java.security.cert.Certificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.HttpsURLConnection

private const val SERIAL_THREAD = "account-test-state"
private val fixtureToken = "pfa_" + "a".repeat(64)
private val fixtureDevice = "pfd_" + "B".repeat(43)
private val noRemote = FlowAccountRemote { _, _, _, _ -> error("Local state operation attempted HTTP") }
private val serialCommit: (() -> Unit) -> Unit = { change ->
    check(Thread.currentThread().name == SERIAL_THREAD) { "A transport worker attempted a state commit" }
    change()
}

private fun await(latch: CountDownLatch, description: String) {
    check(latch.await(2, TimeUnit.SECONDS)) { "Timed out waiting for $description" }
}
private fun uninterruptible(latch: CountDownLatch) {
    while (true) try { latch.await(); return } catch (_: InterruptedException) { }
}
private fun outcome(action: () -> Unit): String = try { action(); "OK" }
catch (failure: FlowAccountFailure) {
    check(!failure.toString().contains("raw-provider-secret"))
    failure.code
}

private class TransportStore(@Volatile var value: FlowAccountRecord) : FlowAccountPersistence {
    override fun load(): FlowAccountRecord {
        check(Thread.currentThread().name == SERIAL_THREAD)
        return value
    }
    override fun save(value: FlowAccountRecord) {
        check(Thread.currentThread().name == SERIAL_THREAD)
        this.value = value
    }
}

private class TransportConnection(url: URL, private val status: Int = 401,
    private val blocked: String? = null, private val blockDisconnect: Boolean = false,
    private val bytes: ByteArray = "{}".toByteArray(),
) : HttpsURLConnection(url) {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val disconnectEntered = CountDownLatch(1)
    val disconnectRelease = CountDownLatch(1)
    val workerCleaned = CountDownLatch(1)
    val sent = ByteArrayOutputStream()
    val openedBodies = AtomicInteger()
    val responseReads = AtomicInteger()
    @Volatile var firstDisconnectThread: String? = null
    override fun connect() = Unit
    override fun usingProxy() = false
    override fun getCipherSuite() = "TLS_TEST_ONLY"
    override fun getLocalCertificates(): Array<Certificate>? = null
    override fun getServerCertificates(): Array<Certificate> = emptyArray()
    override fun getOutputStream(): OutputStream {
        if (blocked == "output") { entered.countDown(); uninterruptible(release) }
        return sent
    }
    override fun getResponseCode(): Int {
        responseReads.incrementAndGet()
        if (blocked == "response") { entered.countDown(); uninterruptible(release) }
        return status
    }
    override fun getInputStream(): InputStream {
        openedBodies.incrementAndGet()
        return object : ByteArrayInputStream(bytes) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (blocked == "read") { entered.countDown(); uninterruptible(release) }
                return super.read(buffer, offset, length)
            }
        }
    }
    override fun getErrorStream(): InputStream = inputStream
    override fun getContentType(): String = "application/json"
    override fun getContentLengthLong(): Long = bytes.size.toLong()
    override fun getHeaderField(name: String?): String? = null
    override fun disconnect() {
        if (firstDisconnectThread == null) firstDisconnectThread = Thread.currentThread().name
        disconnectEntered.countDown()
        if (blockDisconnect) uninterruptible(disconnectRelease)
        val thread = Thread.currentThread().name
        if (thread.startsWith("pushok-account") && "-io-" in thread) workerCleaned.countDown()
    }
    fun releaseAll() { release.countDown(); disconnectRelease.countDown() }
}

private fun connectedStore() = TransportStore(FlowAccountRecord(session =
    FlowAccountSession(fixtureToken, System.currentTimeMillis() + 60_000L)))
private fun pendingStore() = TransportStore(FlowAccountRecord(pending =
    FlowAccountPending(fixtureDevice, "2345ABCDEFGH", System.currentTimeMillis() + 60_000L, 1L, 5)))

fun main() {
    val serial = Executors.newSingleThreadExecutor { task -> Thread(task, SERIAL_THREAD).apply { isDaemon = true } }
    val caller = Executors.newSingleThreadExecutor { task -> Thread(task, "account-test-ui").apply { isDaemon = true } }
    val fixtures = mutableListOf<TransportConnection>()
    fun connection(status: Int = 401, blocked: String? = null, blockDisconnect: Boolean = false) =
        TransportConnection(URL("https://fixture.invalid"), status, blocked, blockDisconnect).also(fixtures::add)
    try {
        // The old implementation released neither HTTP nor queued status when
        // the deadline fired. An uncooperative responseCode still owns its bounded
        // worker, while the serial session manager and status are now free.
        SystemClock.reset()
        val timed = connection(blocked = "response")
        val timeoutCall = FlowAccountCall { true }
        val timeoutStore = connectedStore()
        val timeoutManager = FlowAccountSessionManager(timeoutStore)
        val timeout = serial.submit<String> { outcome {
            timeoutManager.execute("refresh", FlowAccountClient(timeoutCall) { timed }, serialCommit)
        } }
        await(timed.entered, "blocked responseCode")
        SystemClock.advance(20_001L)
        check(timeout.get(2, TimeUnit.SECONDS) == "FLOW_TIMEOUT")
        serial.submit { timeoutManager.load(serialCommit); timeoutManager.expire(serialCommit) }.get(2, TimeUnit.SECONDS)
        check(timed.release.count == 1L && timeoutStore.value.session != null)
        timed.releaseAll(); await(timed.workerCleaned, "late response cleanup")
        check(timed.openedBodies.get() == 0)
        println("PASS: account deadline frees serial status before blocked responseCode returns")

        // The explicit cancel command is committed while outputStream and even
        // disconnect are still blocked. A late stream acquisition must write zero
        // bytes, and neither operation runs on the UI/state threads.
        SystemClock.reset()
        val output = connection(blocked = "output", blockDisconnect = true)
        val outputCall = FlowAccountCall { true }
        val outputStore = pendingStore()
        val outputManager = FlowAccountSessionManager(outputStore)
        val poll = serial.submit<String> { outcome {
            outputManager.execute("pollLogin", FlowAccountClient(outputCall) { output }, serialCommit)
        } }
        await(output.entered, "blocked outputStream")
        caller.submit { outputCall.cancel() }.get(2, TimeUnit.SECONDS)
        check(poll.get(2, TimeUnit.SECONDS) == "FLOW_INTERRUPTED")
        await(output.disconnectEntered, "asynchronous disconnect")
        serial.submit { outputManager.execute("cancelLogin", noRemote, serialCommit) }.get(2, TimeUnit.SECONDS)
        check(outputStore.value == FlowAccountRecord() && output.release.count == 1L && output.disconnectRelease.count == 1L)
        check(output.firstDisconnectThread?.startsWith("pushok-account-abort") == true)
        output.releaseAll(); await(output.workerCleaned, "cancelled stream cleanup")
        check(output.sent.size() == 0 && output.responseReads.get() == 0)
        println("PASS: cancellation and local clear precede blocked cleanup; late output writes zero bytes")

        // A provider may block before returning a connection (including its DNS
        // work). Cancellation is registered before open, not after it succeeds.
        SystemClock.reset()
        val opening = CountDownLatch(1)
        val openRelease = CountDownLatch(1)
        val opened = connection()
        val openCall = FlowAccountCall { true }
        val openResult = serial.submit<String> { outcome {
            FlowAccountClient(openCall) { url ->
                check(url.toString() == "https://pushok.shop/api/v1/flow/capabilities")
                opening.countDown(); uninterruptible(openRelease); opened
            }.request("GET", "/capabilities", null, null)
        } }
        try {
            await(opening, "connection factory")
            caller.submit { openCall.cancel() }.get(2, TimeUnit.SECONDS)
            check(openResult.get(2, TimeUnit.SECONDS) == "FLOW_INTERRUPTED")
            serial.submit {}.get(2, TimeUnit.SECONDS)
            check(openRelease.count == 1L)
        } finally { openRelease.countDown() }
        await(opened.workerCleaned, "late connection registration")
        check(opened.responseReads.get() == 0 && opened.getRequestProperty("Authorization") == null)
        println("PASS: a stalled connection factory cannot retain the account queue or start a late request")

        // Account owner/generation changes invalidate a late authorized response
        // before JSON parsing, even without an explicit call.cancel(). State writes
        // continue only on the original serial executor.
        SystemClock.reset()
        FlowAccountJson.parses.set(0)
        val current = AtomicBoolean(true)
        val late = connection(status = 200, blocked = "read")
        val lateCall = FlowAccountCall(current::get)
        val lateStore = pendingStore()
        val lateManager = FlowAccountSessionManager(lateStore)
        val lateResult = serial.submit<String> { outcome {
            lateManager.execute("pollLogin", FlowAccountClient(lateCall) { late }, serialCommit)
        } }
        await(late.entered, "blocked response body")
        current.set(false)
        check(lateResult.get(2, TimeUnit.SECONDS) == "FLOW_INTERRUPTED")
        serial.submit { lateManager.execute("logout", noRemote, serialCommit) }.get(2, TimeUnit.SECONDS)
        check(lateStore.value == FlowAccountRecord() && late.release.count == 1L)
        late.releaseAll(); await(late.workerCleaned, "late response body cleanup")
        check(FlowAccountJson.parses.get() == 0 && lateStore.value == FlowAccountRecord())
        println("PASS: owner invalidation releases logout and discards late credential JSON before parsing")

        // The two exchanges in beginLogin share one command budget. The first
        // exchange consumes 19 seconds on the controlled clock; the second must
        // receive at most one second rather than a fresh twenty-second allowance.
        SystemClock.reset()
        val budgetCall = FlowAccountCall { true }
        val first = connection(status = 200)
        val second = connection(blocked = "output")
        val count = AtomicInteger()
        FlowAccountJson.decode = {
            SystemClock.advance(19_000L)
            mapOf("protocol_version" to 1, "scopes" to listOf("profile:read", "wallet:read"), "session_ttl_seconds" to 43200)
        }
        val budgetStore = TransportStore(FlowAccountRecord())
        val budgetManager = FlowAccountSessionManager(budgetStore)
        val budget = serial.submit<String> { outcome {
            budgetManager.execute("beginLogin", FlowAccountClient(budgetCall) {
                if (count.getAndIncrement() == 0) first else second
            }, serialCommit)
        } }
        await(second.entered, "second login exchange")
        check(count.get() == 2 && second.connectTimeout in 1..1_000)
        SystemClock.advance(1_001L)
        check(budget.get(2, TimeUnit.SECONDS) == "FLOW_TIMEOUT")
        check(budgetStore.value == FlowAccountRecord() && second.release.count == 1L)
        second.releaseAll(); await(second.workerCleaned, "second exchange cleanup")
        check(second.sent.size() == 0)
        FlowAccountJson.decode = { emptyMap() }
        println("PASS: capabilities and device share the original twenty-second command budget")

        // One old provider permanently occupies a physical worker during this
        // scenario. Hold the other worker after capabilities has been handed to
        // its caller, but before that Runnable returns to the executor. The next
        // device exchange must be admitted, rather than rejected as a busy pool.
        SystemClock.reset()
        val afterCapabilities = CountDownLatch(1)
        val leaveEpilogue = CountDownLatch(1)
        val pauseCompletion = AtomicBoolean(true)
        val handoffPool = BoundedNetworkPool("pushok-account-handoff", afterCompletion = {
            if (pauseCompletion.compareAndSet(true, false)) {
                afterCapabilities.countDown()
                uninterruptible(leaveEpilogue)
            }
        })
        val abandoned = connection(blocked = "response")
        val abandonedCall = FlowAccountCall { true }
        val abandonedResult = serial.submit<String> { outcome {
            FlowAccountClient(abandonedCall, handoffPool) { abandoned }
                .request("GET", "/capabilities", null, null)
        } }
        await(abandoned.entered, "old occupied worker")
        abandonedCall.cancel()
        check(abandonedResult.get(2, TimeUnit.SECONDS) == "FLOW_INTERRUPTED")
        val handoffFirst = connection(status = 200)
        val handoffSecond = connection(status = 201)
        val deviceAttempt = CountDownLatch(1)
        val handoffOpens = AtomicInteger()
        val handoffParses = AtomicInteger()
        val handoffStore = TransportStore(FlowAccountRecord())
        val handoffManager = FlowAccountSessionManager(handoffStore)
        FlowAccountJson.decode = {
            if (handoffParses.getAndIncrement() == 0) {
                mapOf("protocol_version" to 1, "scopes" to listOf("profile:read", "wallet:read"), "session_ttl_seconds" to 43200)
            } else {
                mapOf("device_code" to fixtureDevice, "user_code" to "2345ABCDEFGH", "expires_in" to 300, "interval" to 5)
            }
        }
        val handoffClient = FlowAccountClient(FlowAccountCall { true }, handoffPool) { url ->
            when (handoffOpens.getAndIncrement()) {
                0 -> { check(url.path.endsWith("/capabilities")); handoffFirst }
                1 -> { check(url.path.endsWith("/device")); handoffSecond }
                else -> error("Unexpected extra login request")
            }
        }
        val handoffRemote = FlowAccountRemote { method, path, bearer, body ->
            if (path == "/device") deviceAttempt.countDown()
            handoffClient.request(method, path, bearer, body)
        }
        val handoff = serial.submit<String> { outcome {
            handoffManager.execute("beginLogin", handoffRemote, serialCommit)
        } }
        try {
            await(afterCapabilities, "completed capabilities epilogue")
            await(deviceAttempt, "immediate device request")
            try {
                val early = handoff.get(200, TimeUnit.MILLISECONDS)
                error("Login finished before the available worker left its epilogue: $early")
            } catch (_: TimeoutException) { }
            check(handoffOpens.get() == 1 && handoffStore.value == FlowAccountRecord())
            check(abandoned.release.count == 1L)
            leaveEpilogue.countDown()
            check(handoff.get(2, TimeUnit.SECONDS) == "OK")
            check(handoffOpens.get() == 2 && handoffParses.get() == 2)
            check(handoffStore.value.pending?.userCode == "2345ABCDEFGH" && abandoned.release.count == 1L)
        } finally {
            leaveEpilogue.countDown()
            abandoned.releaseAll()
            FlowAccountJson.decode = { emptyMap() }
        }
        await(abandoned.workerCleaned, "old worker cleanup after successful login")
        println("PASS: beginLogin admits device behind capabilities epilogue with one abandoned worker")

        SystemClock.reset()
        for (status in listOf(401, 403, 410, 404, 405, 501, 503)) {
            val response = connection(status)
            val result = serial.submit<FlowAccountResponse> {
                FlowAccountClient(FlowAccountCall { true }) { url ->
                    check(url.toString() == "https://pushok.shop/api/v1/flow/me"); response
                }.request("GET", "/me", fixtureToken, null)
            }.get(2, TimeUnit.SECONDS)
            check(result.status == status && response.openedBodies.get() == 0)
            check(response.getRequestProperty("Authorization") == "Bearer $fixtureToken")
            check(!response.instanceFollowRedirects && !response.useCaches)
        }
        var invalidOpened = false
        val invalid = FlowAccountClient(FlowAccountCall { true }) { invalidOpened = true; connection() }
        check(outcome { invalid.request("POST", "/device", fixtureToken, emptyMap()) } == "FLOW_PROTOCOL_UNSUPPORTED")
        check(outcome { invalid.request("GET", "/me", null, null) } == "FLOW_PROTOCOL_UNSUPPORTED")
        check(outcome { invalid.request("GET", "https://other.invalid", null, null) } == "FLOW_PROTOCOL_UNSUPPORTED")
        check(!invalidOpened)
        val failed = FlowAccountClient(FlowAccountCall { true }) { throw java.io.IOException("raw-provider-secret") }
        check(outcome { failed.request("GET", "/capabilities", null, null) } == "FLOW_NETWORK_ERROR")
        println("PASS: fixed origin, bearer boundaries, authoritative statuses and redacted errors remain enforced")

        // Two abandoned providers retain the fixed two transport slots. A third
        // request fails fast, starts no provider work and does not report UI-busy.
        SystemClock.reset()
        val saturated = listOf(connection(blocked = "response"), connection(blocked = "response"))
        for (held in saturated) {
            val call = FlowAccountCall { true }
            val result = serial.submit<String> { outcome {
                FlowAccountClient(call) { held }.request("GET", "/capabilities", null, null)
            } }
            await(held.entered, "bounded transport slot")
            call.cancel()
            check(result.get(2, TimeUnit.SECONDS) == "FLOW_INTERRUPTED")
        }
        val openedThird = AtomicBoolean()
        val rejected = serial.submit<String> { outcome {
            FlowAccountClient(FlowAccountCall { true }) { openedThird.set(true); connection() }
                .request("GET", "/capabilities", null, null)
        } }.get(2, TimeUnit.SECONDS)
        check(rejected == "FLOW_NETWORK_ERROR" && !openedThird.get())
        serial.submit {}.get(2, TimeUnit.SECONDS)
        check(saturated.all { it.release.count == 1L })
        saturated.forEach { it.releaseAll(); await(it.workerCleaned, "bounded slot cleanup") }
        println("PASS: two abandoned transports cap worker growth and reject a third without blocking state")
        println("Flow account transport checks passed (8 groups; synthetic providers, no network)")
    } finally {
        fixtures.forEach(TransportConnection::releaseAll)
        FlowAccountJson.decode = { emptyMap() }
        SystemClock.reset()
        serial.shutdownNow(); caller.shutdownNow()
    }
}
