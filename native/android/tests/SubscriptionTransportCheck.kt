package shop.pushok.flow

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.net.URL
import java.net.URLEncoder
import java.security.cert.Certificate
import java.security.cert.CertificateException
import java.security.cert.CertPathValidatorException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

private open class TestConnection(
    url: URL,
    private val status: Int = 200,
    private val bytes: ByteArray = "safe-body".toByteArray(),
    private val headers: Map<String, String> = emptyMap(),
    private val length: Long = bytes.size.toLong(),
    private val encoding: String? = null,
) : HttpsURLConnection(url) {
    var closed = false
    override fun connect() { }
    override fun disconnect() { closed = true }
    override fun usingProxy() = false
    override fun getResponseCode() = status
    override fun getInputStream(): InputStream = ByteArrayInputStream(bytes)
    override fun getHeaderField(name: String?) = headers.entries.firstOrNull { it.key.equals(name, true) }?.value
    override fun getContentLengthLong() = length
    override fun getContentEncoding() = encoding
    override fun getCipherSuite() = "TLS_TEST"
    override fun getLocalCertificates(): Array<Certificate>? = null
    override fun getServerCertificates(): Array<Certificate> = emptyArray()
}

private fun expectCode(code: String, run: () -> Unit) {
    try { run(); error("Expected $code") }
    catch (failure: SubscriptionFailure) {
        check(failure.code == code) { "Expected $code, got ${failure.code}" }
        check(failure.message == null && failure.cause == null)
        check(!failure.toString().contains("secret"))
    }
}

private fun await(latch: CountDownLatch, message: String) {
    check(latch.await(3, TimeUnit.SECONDS)) { message }
}

/** Model a platform call which ignores interrupt and socket timeout. No network is used. */
private fun blockedPlatformCall(entered: CountDownLatch, release: CountDownLatch) {
    entered.countDown()
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
    while (release.count != 0L) {
        check(System.nanoTime() < deadline) { "Blocked transport test was not released" }
        try { release.await(100, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { }
    }
}

private class AsyncResult<T>(action: () -> T) {
    val completed = CountDownLatch(1)
    private val result = AtomicReference<Result<T>?>()
    val thread = Thread {
        try { result.set(runCatching(action)) } finally { completed.countDown() }
    }.apply { isDaemon = true; start() }

    fun outcome(): Result<T> {
        await(completed, "Caller remained blocked after cancellation or deadline")
        return checkNotNull(result.get())
    }
}

private fun checkUncooperativeSubscriptionTransport() {
    // The open hook also represents a second DNS lookup inside URLConnection.
    for ((stage, cancel) in listOf("dns" to false, "dns" to true, "open" to false,
        "headers" to false, "read" to false, "disconnect" to true)) {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val workerFinished = CountDownLatch(1)
        val opens = AtomicInteger()
        val ticks = AtomicLong()
        val pool = BoundedNetworkPool("subscription-test-$stage", afterCompletion = { workerFinished.countDown() })
        val connection = object : TestConnection(URL("https://subscription.example.org/synthetic")) {
            override fun getResponseCode(): Int {
                if (stage == "headers") blockedPlatformCall(entered, release)
                return super.getResponseCode()
            }
            override fun getInputStream(): InputStream = if (stage == "read") {
                object : ByteArrayInputStream("late-body".toByteArray()) {
                    override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                        blockedPlatformCall(entered, release)
                        return super.read(bytes, offset, length)
                    }
                }
            } else super.getInputStream()
            override fun disconnect() {
                if (stage == "disconnect") blockedPlatformCall(entered, release)
                super.disconnect()
            }
        }
        val client = SubscriptionDownloader(
            resolve = {
                if (stage == "dns") blockedPlatformCall(entered, release)
                arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8)))
            },
            open = {
                opens.incrementAndGet()
                if (stage == "open") blockedPlatformCall(entered, release)
                connection
            },
            elapsedMs = ticks::get,
            network = pool,
        )
        val task = AsyncResult { client.fetch("https://subscription.example.org/synthetic") }
        try {
            await(entered, "$stage stage was not reached")
            if (cancel) {
                // In particular, disconnect is allowed to block indefinitely. Neither
                // this cancellation caller nor the fetch caller may wait for it.
                val cancellation = AsyncResult { client.cancel() }
                cancellation.outcome().getOrThrow()
            } else ticks.set(40_001L)
            val error = task.outcome().exceptionOrNull()
            val expected = if (cancel) "SUBSCRIPTION_INTERRUPTED" else "SUBSCRIPTION_NETWORK_ERROR"
            check(error is SubscriptionFailure && error.code == expected) {
                "$stage did not return the fixed $expected code before platform release"
            }
            check(release.count == 1L && workerFinished.count == 1L)
            if (stage == "dns") check(opens.get() == 0) { "Cancelled DNS must not reach HTTP" }
        } finally {
            release.countDown()
            await(workerFinished, "$stage worker did not finish after release")
        }
        if (stage == "open") check(connection.closed) { "A late-created connection must be closed" }
    }
}

private fun checkSubscriptionCancelIsolation() {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val completed = CountDownLatch(2)
    val resolutions = AtomicInteger()
    val opens = AtomicInteger()
    val pool = BoundedNetworkPool("subscription-isolation", afterCompletion = { completed.countDown() })
    val client = SubscriptionDownloader(
        resolve = {
            if (resolutions.incrementAndGet() == 1) blockedPlatformCall(entered, release)
            arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8)))
        }, open = { opens.incrementAndGet(); TestConnection(it) }, elapsedMs = { 0L }, network = pool,
    )
    val old = AsyncResult { client.fetch("https://subscription.example.org/old-synthetic") }
    try {
        await(entered, "Old DNS request did not start")
        client.cancel()
        val error = old.outcome().exceptionOrNull()
        check(error is SubscriptionFailure && error.code == "SUBSCRIPTION_INTERRUPTED")
        val replacement = client.fetch("https://subscription.example.org/new-synthetic")
        check(String(replacement.body) == "safe-body" && opens.get() == 1)
        check(release.count == 1L) { "Replacement depended on the cancelled resolver" }
    } finally {
        release.countDown()
        await(completed, "Old and replacement requests did not finish")
    }
    check(opens.get() == 1) { "Old request must not open a connection after cancellation" }
    client.cancel()
    check(String(client.fetch("https://subscription.example.org/third-synthetic").body) == "safe-body")
}

private fun checkConnectRefreshDeadlineIncludesBlockedDns() {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val finished = CountDownLatch(1)
    val clock = AtomicLong()
    val opens = AtomicInteger()
    val client = SubscriptionDownloader(resolve = {
        blockedPlatformCall(entered, release)
        arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8)))
    }, open = { opens.incrementAndGet(); TestConnection(it) }, elapsedMs = clock::get,
        network = BoundedNetworkPool("connect-deadline-test", afterCompletion = { finished.countDown() }))
    val task = AsyncResult { client.fetchWithin("https://subscription.example.org/private-token", 5_000L) }
    try {
        await(entered, "Connect preflight did not reach DNS")
        clock.set(5_001L)
        val error = task.outcome().exceptionOrNull()
        check(error is SubscriptionFailure && error.code == "SUBSCRIPTION_NETWORK_ERROR")
        check(release.count == 1L && opens.get() == 0)
    } finally {
        release.countDown()
        await(finished, "Timed out resolver did not release its bounded worker")
    }
}

private fun checkBoundedPoolCapacityAndDiscard() {
    val entered = CountDownLatch(2)
    val release = CountDownLatch(1)
    val finished = CountDownLatch(2)
    val discarded = AtomicInteger()
    val starts = AtomicInteger()
    val bodies = List(2) { "synthetic-secret".toByteArray() }
    val pool = BoundedNetworkPool("bounded-capacity", afterCompletion = { finished.countDown() })
    val calls = bodies.map { body ->
        pool.newCall<ByteArray>(Long.MAX_VALUE, { 0L }) {
            it.fill(0)
            discarded.incrementAndGet()
        } to body
    }
    val tasks = calls.map { (call, body) -> AsyncResult {
        call.run { starts.incrementAndGet(); blockedPlatformCall(entered, release); body }
    } }
    try {
        await(entered, "Both fixed workers must be occupied")
        calls.forEach { it.first.cancel() }
        tasks.forEach {
            val error = it.outcome().exceptionOrNull()
            check(error is BoundedNetworkFailure && error.kind == BoundedNetworkFailure.Kind.CANCELLED)
        }
        var extraRan = false
        val rejected = runCatching {
            pool.newCall<Unit>(Long.MAX_VALUE, { 0L }).run { extraRan = true }
        }.exceptionOrNull()
        check(rejected is BoundedNetworkFailure && rejected.kind == BoundedNetworkFailure.Kind.BUSY)
        check(starts.get() == 2 && !extraRan) { "Cancellation must not replace stuck workers" }
        check(discarded.get() == 0) { "Response bytes do not exist until blocked workers return" }
    } finally {
        release.countDown()
        await(finished, "Cancelled workers did not release their real capacity")
    }
    check(discarded.get() == 2 && bodies.all { body -> body.all { it == 0.toByte() } }) {
        "Each late successful response must be discarded and wiped exactly once"
    }
    check(pool.newCall<Int>(Long.MAX_VALUE, { 0L }).run { 7 } == 7)
}

private fun checkPoolCompletionHandoff() {
    val stuckEntered = CountDownLatch(1)
    val releaseStuck = CountDownLatch(1)
    val epilogueEntered = CountDownLatch(1)
    val releaseEpilogue = CountDownLatch(1)
    val firstCompletion = AtomicInteger()
    val pool = BoundedNetworkPool("bounded-handoff", afterCompletion = {
        if (firstCompletion.incrementAndGet() == 1) blockedPlatformCall(epilogueEntered, releaseEpilogue)
    })
    val stuckCall = pool.newCall<Unit>(Long.MAX_VALUE, { 0L })
    val stuck = AsyncResult { stuckCall.run { blockedPlatformCall(stuckEntered, releaseStuck) } }
    try {
        await(stuckEntered, "First worker did not enter its stuck platform operation")
        stuckCall.cancel()
        val cancelled = stuck.outcome().exceptionOrNull()
        check(cancelled is BoundedNetworkFailure && cancelled.kind == BoundedNetworkFailure.Kind.CANCELLED)
        check(pool.newCall<String>(Long.MAX_VALUE, { 0L }).run { "capabilities" } == "capabilities")
        await(epilogueEntered, "Completed second worker did not reach the held epilogue")

        val admittedOrFailed = CountDownLatch(1)
        val guards = AtomicInteger()
        val secondStarted = CountDownLatch(1)
        val second = AsyncResult {
            try {
                pool.newCall<String>(Long.MAX_VALUE, { 0L }).run(ensureActive = {
                    // The first guard is before submission; the second is after
                    // accepted submission, while the only usable worker is held.
                    if (guards.incrementAndGet() == 2) admittedOrFailed.countDown()
                }) { secondStarted.countDown(); "device" }
            } finally { admittedOrFailed.countDown() }
        }
        await(admittedOrFailed, "Sequential request neither queued nor returned an error")
        check(guards.get() >= 2 && second.completed.count == 1L && secondStarted.count == 1L) {
            "A completed response must admit the next request before its worker leaves the epilogue"
        }
        releaseEpilogue.countDown()
        check(second.outcome().getOrThrow() == "device")
    } finally {
        releaseEpilogue.countDown()
        releaseStuck.countDown()
    }
}

private fun checkInterruptedWaiterAndLateAbort() {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val aborted = CountDownLatch(1)
    val finished = CountDownLatch(1)
    val abortThread = AtomicReference<Thread?>()
    val interruptPreserved = AtomicReference<Boolean?>()
    val pool = BoundedNetworkPool("bounded-interrupt", afterCompletion = { finished.countDown() })
    val call = pool.newCall<Unit>(Long.MAX_VALUE, { 0L })
    val task = AsyncResult {
        try {
            call.run { active ->
                blockedPlatformCall(entered, release)
                active.setAbort { abortThread.set(Thread.currentThread()); aborted.countDown() }
            }
        } finally { interruptPreserved.set(Thread.currentThread().isInterrupted) }
    }
    try {
        await(entered, "Interrupt test did not reach its blocked operation")
        task.thread.interrupt()
        val error = task.outcome().exceptionOrNull()
        check(error is BoundedNetworkFailure && error.kind == BoundedNetworkFailure.Kind.CANCELLED)
        check(interruptPreserved.get() == true)
    } finally { release.countDown() }
    await(finished, "Interrupted operation did not finish after release")
    await(aborted, "Connection registered after cancellation was not aborted")
    check(abortThread.get() !== task.thread && abortThread.get()?.name?.contains("-abort-") == true)
}

private fun checkSubscriptionTlsErrorsAreSafe() {
    val source = "https://subscription.example.org:2096/sub/secret-token"
    val tlsFailures: List<() -> Exception> = listOf(
        { SSLPeerUnverifiedException("secret-token hostname did not match") },
        { SSLHandshakeException("secret-token handshake failed") },
        { IOException("secret-token wrapper", SSLPeerUnverifiedException("secret-token peer")) },
        { IOException("secret-token wrapper", SSLHandshakeException("secret-token handshake")) },
        { IOException("secret-token wrapper", CertificateException("secret-token certificate")) },
        { IOException("secret-token wrapper", CertPathValidatorException("secret-token certificate path")) },
    )
    for (stage in listOf("open", "headers", "body")) for (failure in tlsFailures) {
        val requestedSchemes = mutableListOf<String>()
        val connection = object : TestConnection(URL(source)) {
            override fun getResponseCode(): Int {
                if (stage == "headers") throw failure()
                return super.getResponseCode()
            }
            override fun getInputStream(): InputStream {
                if (stage == "body") throw failure()
                return super.getInputStream()
            }
        }
        val client = SubscriptionDownloader(
            resolve = { arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))) },
            open = {
                requestedSchemes.add(it.protocol)
                if (stage == "open") throw failure()
                connection
            },
        )
        expectCode("SUBSCRIPTION_TLS_ERROR") { client.fetch(source) }
        check(requestedSchemes == listOf("https")) { "TLS failure must not retry or downgrade transport" }
        check(stage == "open" || connection.closed)
    }
    val first = IOException("secret-token cycle one")
    val second = IOException("secret-token cycle two", first)
    first.initCause(second)
    for (failure in listOf(
        IOException("secret-token SSLHandshakeException certificate text is not a TLS type"),
        UnknownHostException("secret-token DNS"),
        SocketTimeoutException("secret-token timeout"),
        IOException("secret-token wrapper", SocketTimeoutException("secret-token timeout")),
        first,
    )) {
        val client = SubscriptionDownloader(
            resolve = { arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))) },
            open = { throw failure },
        )
        expectCode("SUBSCRIPTION_NETWORK_ERROR") { client.fetch(source) }
    }
}

private fun checkLateTlsFailureDoesNotOverrideStop() {
    for (cancel in listOf(false, true)) {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val ticks = AtomicLong()
        val source = "https://subscription.example.org/sub/secret-token"
        val pool = BoundedNetworkPool("subscription-tls-stop", afterCompletion = { finished.countDown() })
        val client = SubscriptionDownloader(
            resolve = { arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))) },
            open = { target -> object : TestConnection(target) {
                override fun getResponseCode(): Int {
                    blockedPlatformCall(entered, release)
                    throw SSLPeerUnverifiedException("secret-token late hostname failure")
                }
            } },
            elapsedMs = ticks::get,
            network = pool,
        )
        val result = AsyncResult { client.fetch(source) }
        try {
            await(entered, "TLS fixture did not reach its blocked handshake")
            if (cancel) client.cancel() else ticks.set(40_001L)
            val error = result.outcome().exceptionOrNull()
            val expected = if (cancel) "SUBSCRIPTION_INTERRUPTED" else "SUBSCRIPTION_NETWORK_ERROR"
            check(error is SubscriptionFailure && error.code == expected)
            check(release.count == 1L && finished.count == 1L)
        } finally {
            release.countDown()
            await(finished, "Late TLS failure did not release the worker")
        }
    }
}

private fun checkPushokExternalLinks() {
    val destinations = mapOf(
        PushokExternalLinks.Destination.SUPPORT to listOf(
            "tg://resolve?domain=server_pushok_bot", "https://t.me/server_pushok_bot"),
        PushokExternalLinks.Destination.ACCOUNT to listOf(
            "tg://resolve?domain=mtproxy_pushok_bot", "https://pushok.shop/"),
        PushokExternalLinks.Destination.HUB to listOf(
            "tg://resolve?domain=pushok_app", "https://t.me/pushok_app"),
        PushokExternalLinks.Destination.SHOP to listOf(
            "https://pushok.shop/shop/", "https://pushok.shop/shop/"),
    )
    check(PushokExternalLinks.Destination.entries.toSet() == destinations.keys)
    for ((destination, expected) in destinations) {
        val nativeOnly = mutableListOf<String>()
        PushokExternalLinks.open(destination) { nativeOnly.add(it) }
        check(nativeOnly == expected.take(1)) { "Telegram success must not launch a second activity" }

        // ActivityNotFoundException is a RuntimeException. A forbidden launch may
        // instead raise SecurityException; both must fall back to the fixed HTTPS URL.
        for (launchFailure in listOf(RuntimeException("No handler"), SecurityException("Launch refused"))) {
            val fallback = mutableListOf<String>()
            PushokExternalLinks.open(destination) { url ->
                fallback.add(url)
                if (fallback.size == 1) throw launchFailure
            }
            check(fallback == expected) { "Unavailable Telegram must open the correct web destination" }
        }

        val failed = mutableListOf<String>()
        val browserFailure = IllegalStateException("No browser")
        var propagated: Exception? = null
        try {
            PushokExternalLinks.open(destination) { url ->
                failed.add(url)
                if (failed.size == 1) throw RuntimeException("No Telegram")
                throw browserFailure
            }
        } catch (failure: Exception) { propagated = failure }
        check(failed == expected && propagated === browserFailure) {
            "A failed fallback must reach the method-channel error handler"
        }
    }
}

fun main() {
    val publicDns: (String) -> Array<InetAddress> = { arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))) }
    val source = "https://subscription.example.org/access/secret-token"
    val seen = mutableListOf<TestConnection>()
    val ordinary = SubscriptionDownloader(resolve = publicDns, open = { url ->
        TestConnection(url, headers = mapOf("Subscription-Userinfo" to "expire=1900000000", "Profile-Title" to "Pushok"))
            .also { seen.add(it) }
    })
    val response = ordinary.fetch(source)
    check(String(response.body) == "safe-body")
    check(response.title == "Pushok" && response.userInfo == "expire=1900000000")
    check(seen.single().closed && !seen.single().instanceFollowRedirects)
    check(seen.single().getRequestProperty("Accept-Encoding") == "identity")
    check(seen.single().getRequestProperty("Authorization") == null)

    var opened = 0
    val internalDns = SubscriptionDownloader(resolve = {
        arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8)), InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
    }, open = { opened++; TestConnection(it) })
    expectCode("SUBSCRIPTION_URL_INVALID") { internalDns.fetch(source) }
    check(opened == 0)

    for (location in listOf("http://subscription.example.org/file", "https://127.0.0.1/private",
        "https://username:secret@other.example.org/file", "https://other.example.org/file#secret")) {
        var calls = 0
        val client = SubscriptionDownloader(resolve = publicDns, open = {
            calls++
            TestConnection(it, 302, headers = mapOf("Location" to location))
        })
        expectCode("SUBSCRIPTION_URL_INVALID") { client.fetch(source) }
        check(calls == 1)
    }

    val paths = mutableListOf<String>()
    val relativeRedirect = SubscriptionDownloader(resolve = publicDns, open = {
        paths.add(it.path)
        if (paths.size == 1) TestConnection(it, 302, headers = mapOf("Location" to "/final"))
        else TestConnection(it)
    })
    relativeRedirect.fetch(source)
    check(paths == listOf("/access/secret-token", "/final"))

    var redirectCount = 0
    val redirectLoop = SubscriptionDownloader(resolve = publicDns, open = {
        redirectCount++
        TestConnection(it, 307, headers = mapOf("Location" to "/again"))
    })
    expectCode("SUBSCRIPTION_NETWORK_ERROR") { redirectLoop.fetch(source) }
    check(redirectCount == 4)

    val hugeLength = SubscriptionDownloader(resolve = publicDns, open = {
        TestConnection(it, length = SubscriptionPolicy.MAX_BYTES + 1L)
    })
    expectCode("SUBSCRIPTION_TOO_LARGE") { hugeLength.fetch(source) }
    val hugeStream = SubscriptionDownloader(resolve = publicDns, open = {
        TestConnection(it, bytes = ByteArray(SubscriptionPolicy.MAX_BYTES + 1), length = -1)
    })
    expectCode("SUBSCRIPTION_TOO_LARGE") { hugeStream.fetch(source) }
    val compressed = SubscriptionDownloader(resolve = publicDns, open = { TestConnection(it, encoding = "gzip") })
    expectCode("SUBSCRIPTION_INVALID") { compressed.fetch(source) }
    for (code in listOf(401, 403, 410)) {
        val denied = SubscriptionDownloader(resolve = publicDns, open = { TestConnection(it, status = code) })
        expectCode("SUBSCRIPTION_AUTH_REQUIRED") { denied.fetch(source) }
    }
    val unavailable = SubscriptionDownloader(resolve = publicDns, open = { TestConnection(it, status = 503) })
    expectCode("SUBSCRIPTION_NETWORK_ERROR") { unavailable.fetch(source) }
    val ticks = AtomicLong()
    val timeout = SubscriptionDownloader(resolve = publicDns, open = { TestConnection(it) },
        elapsedMs = { ticks.getAndAdd(15_000L) })
    expectCode("SUBSCRIPTION_NETWORK_ERROR") { timeout.fetch(source) }
    expectCode("SUBSCRIPTION_INTERRUPTED") {
        ordinary.fetch(source) { throw SubscriptionFailure("SUBSCRIPTION_INTERRUPTED") }
    }

    val encoded = URLEncoder.encode(source, "UTF-8")
    val validLink = "pushokflow://subscription?url=$encoded&name=Pushok"
    check(SubscriptionLinks.parse(validLink)?.url == source)
    check(SubscriptionLinks.parse(validLink)?.name == "Pushok")
    check(SubscriptionLinks.parse("pushokflow://subscription?url=$encoded")?.name == null)
    for (bad in listOf("https://subscription?url=$encoded", "pushokflow://other?url=$encoded",
        "pushokflow://subscription/path?url=$encoded", "$validLink&url=$encoded", "$validLink&%75rl=$encoded",
        "$validLink&unknown=1", "$validLink#ignored", "pushokflow://user@subscription?url=$encoded",
        "pushokflow://subscription?url=%QQ", "pushokflow://subscription?url=https%3A%2F%2F127.0.0.1%2Fsecret",
        "$validLink\n", "pushokflow://subscription?url=" + "x".repeat(SubscriptionLinks.MAX_LINK_LENGTH))) {
        check(SubscriptionLinks.parse(bad) == null) { "Invalid link was accepted" }
    }
    checkPushokExternalLinks()
    checkUncooperativeSubscriptionTransport()
    checkSubscriptionCancelIsolation()
    checkConnectRefreshDeadlineIncludesBlockedDns()
    checkBoundedPoolCapacityAndDiscard()
    checkPoolCompletionHandoff()
    checkInterruptedWaiterAndLateAbort()
    checkSubscriptionTlsErrorsAreSafe()
    checkLateTlsFailureDoesNotOverrideStop()

    val sixHours = SubscriptionRefreshPolicy.SUCCESS_INTERVAL_MS
    val hour = SubscriptionRefreshPolicy.RETRY_INTERVAL_MS
    check(SubscriptionRefreshPolicy.due(10, 0, 0))
    check(!SubscriptionRefreshPolicy.due(sixHours, 1, 0))
    check(SubscriptionRefreshPolicy.due(sixHours + 1, 1, 0))
    check(!SubscriptionRefreshPolicy.due(sixHours + 1, 1, sixHours))
    check(SubscriptionRefreshPolicy.due(sixHours + hour, 1, sixHours))
    check(!SubscriptionRefreshPolicy.due(100, 200, 0))
    check(!SubscriptionRefreshPolicy.due(100, 0, 200))
    check(!SubscriptionRefreshPolicy.due(100, 0, -1))
    println("Subscription HTTPS, bounded DNS/transport/cancel/handoff, link and refresh policy checks passed")
}
