package shop.pushok.flow

import android.app.Activity
import android.os.Handler
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.URL
import java.security.cert.Certificate
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLPeerUnverifiedException

/** The production bridge, downloader, feed parser and catalog; only Android/I/O are fixtures. */
private class Reply : MethodChannel.Result {
    var completions = 0
    var value: Any? = null
    var code: String? = null
    override fun success(value: Any?) { check(++completions == 1); this.value = value }
    override fun error(code: String, message: String?, details: Any?) {
        check(++completions == 1); this.code = code; check(details == null)
    }
    override fun notImplemented() = error("Unexpected bridge method", null, null)
    fun status(): Map<*, *> { check(code == null) { "Unexpected status error: $code" }; return value as Map<*, *> }
}

private fun executor(name: String) = ProfileSubscriptions::class.java.getDeclaredField(name)
    .apply { isAccessible = true }.get(null) as ExecutorService

private fun drainUntil(done: () -> Boolean) {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(6)
    while (!done()) { check(System.nanoTime() < deadline) { "Coordinator did not finish" }; Handler.runNext() }
}

private fun config(number: Int) =
    "vless://00000000-0000-4000-8000-${number.toString().padStart(12, '0')}@endpoint.example:443?security=tls&type=tcp#Server$number"
private fun feed(vararg numbers: Int) = SubscriptionFeed.parse(numbers.joinToString("\n", transform = ::config).toByteArray())

private class ResponseSpec(
    val status: Int = 200,
    val body: String = config(100),
    val length: Long = -1,
    val location: String? = null,
    val onStatus: () -> Unit = {},
    val onDisconnect: () -> Unit = {},
)

private class Fixture(count: Int = 2, var gateCode: String? = null) : AutoCloseable {
    val activity = Activity()
    val store = SecureWireGuardStore()
    val messenger = object : BinaryMessenger {}
    val responses = (1..count).associateWith { ResponseSpec(body = config(100 + it)) }.toMutableMap()
    val opened = Collections.synchronizedList(mutableListOf<Int>())
    val ids: List<String>
    val originalWrites: Int
    val bridge = ProfileSubscriptions(activity, store) { action, completed ->
        val code = gateCode
        if (code == null) { action(); completed(null) } else completed(code)
    }

    init {
        ids = (1..count).map { number ->
            store.importSubscription("Подписка $number", "https://provider$number.example/sub/private-token-$number",
                feed(number), 0)
        }
        originalWrites = store.writes
        val downloader = SubscriptionDownloader(
            resolve = { arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))) },
            open = { url -> connection(url) },
            elapsedMs = { System.nanoTime() / 1_000_000L },
            network = BoundedNetworkPool("subscription-coordinator-test"),
        )
        ProfileSubscriptions::class.java.getDeclaredField("downloader")
            .apply { isAccessible = true }.set(bridge, downloader)
        bridge.register(messenger)
        bridge.setForeground(true)
    }

    private fun connection(target: URL): HttpsURLConnection {
        val number = target.host.removePrefix("provider").substringBefore('.').toInt()
        opened.add(number)
        val spec = responses.getValue(number)
        return object : HttpsURLConnection(target) {
            override fun connect() {}
            override fun disconnect() = spec.onDisconnect()
            override fun usingProxy() = false
            override fun getResponseCode(): Int { spec.onStatus(); return spec.status }
            override fun getContentLengthLong() = spec.length
            override fun getContentEncoding(): String? = null
            override fun getHeaderField(name: String?): String? = if (name == "Location") spec.location else null
            override fun getCipherSuite() = "TEST"
            override fun getLocalCertificates(): Array<Certificate>? = null
            override fun getServerCertificates(): Array<Certificate> = emptyArray()
            override fun getInputStream() = ByteArrayInputStream(spec.body.toByteArray())
        }
    }

    fun start(method: String, args: Any? = null) = Reply().also {
        MethodChannel.invoke(messenger, method, args, it)
    }
    fun invoke(method: String, args: Any? = null) = start(method, args).also {
        drainUntil { it.completions == 1 }
    }
    fun status() = invoke("status").status()
    fun errors(status: Map<*, *> = status()): Map<*, *> = status["refreshErrors"] as Map<*, *>
    fun profiles(id: String): List<String> {
        val metadata = store.catalogStore.metadata()["profiles"] as List<*>
        return metadata.map { it as Map<*, *> }.filter { it["subscriptionId"] == id }
            .map { store.catalogStore.load(it["id"] as String)!! }
    }
    override fun close() {
        bridge.dispose()
        executor("network").submit {}.get(3, TimeUnit.SECONDS)
        executor("reads").submit {}.get(3, TimeUnit.SECONDS)
        Handler.clearForTest()
    }
}

private fun partialRefreshContinues() {
    Fixture().use { f ->
        f.responses[1] = ResponseSpec(status = 401)
        val result = f.invoke("refreshDue")
        check(f.opened == listOf(1, 2)) { "A provider failure starved the next subscription" }
        val status = result.status()
        check(status["errorCode"] == null && status["busy"] == false)
        check(f.errors(status) == mapOf(f.ids[0] to "SUBSCRIPTION_AUTH_REQUIRED"))
        check(f.profiles(f.ids[0]) == listOf(config(1)))
        check(f.profiles(f.ids[1]) == listOf(config(102)))
        check(f.store.writes == f.originalWrites + 1)
        val records = f.store.subscriptionRecords()
        check(records[0].updatedAt == 0L && records[1].updatedAt > 0)
        check(f.activity.preferences.getLong("attempt_${f.ids[0]}", 0) > 0)
        check(f.activity.preferences.getLong("attempt_${f.ids[1]}", 0) > 0)
        check(!status.toString().contains("private-token") && !status.toString().contains("vless://"))
        // Neither a status read nor a cooldown-only automatic pass erases the failed provider.
        check(f.errors(f.invoke("refreshDue").status()) == f.errors(status))
        check(f.opened == listOf(1, 2) && f.store.writes == f.originalWrites + 1)
        // A later due pass still reaches the healthy provider after the bad provider is due again.
        f.activity.preferences.edit().putLong("attempt_${f.ids[0]}", 0)
            .putLong("attempt_${f.ids[1]}", 0).commit()
        val second = records[1]
        f.store.refreshSubscription(second.id, second.url, feed(102), 0)
        f.invoke("refreshDue").status()
        check(f.opened == listOf(1, 2, 1, 2))
    }
}

private fun providerFailuresAreBoundedAndPreserveProfiles() {
    val cases = mapOf(
        "SUBSCRIPTION_URL_INVALID" to ResponseSpec(status = 302, location = "https://127.0.0.1/private"),
        "SUBSCRIPTION_INVALID" to ResponseSpec(body = "%invalid%"),
        "SUBSCRIPTION_TOO_LARGE" to ResponseSpec(length = SubscriptionPolicy.MAX_BYTES + 1L),
        "SUBSCRIPTION_EMPTY" to ResponseSpec(body = ""),
        "SUBSCRIPTION_UNSUPPORTED" to ResponseSpec(body = "{\"unsupported\":true}"),
        "SUBSCRIPTION_NETWORK_ERROR" to ResponseSpec(status = 503),
        "SUBSCRIPTION_TLS_ERROR" to ResponseSpec(onStatus = {
            throw IOException("private-token transport", SSLPeerUnverifiedException("private-token certificate"))
        }),
        "SUBSCRIPTION_AUTH_REQUIRED" to ResponseSpec(status = 403),
    )
    for ((code, response) in cases) Fixture().use { f ->
        f.responses[1] = response
        val status = f.invoke("refreshDue").status()
        check(f.opened == listOf(1, 2))
        check(f.errors(status) == mapOf(f.ids[0] to code))
        check(f.profiles(f.ids[0]) == listOf(config(1)))
        check(f.profiles(f.ids[1]) == listOf(config(102)))
    }
    Fixture().use { f ->
        f.responses[1] = ResponseSpec(onStatus = {
            throw SSLPeerUnverifiedException("private-token certificate")
        })
        val result = f.invoke("refreshSubscription", mapOf("id" to f.ids[0]))
        check(result.code == "SUBSCRIPTION_TLS_ERROR")
        check(f.errors() == mapOf(f.ids[0] to "SUBSCRIPTION_TLS_ERROR"))
        check(f.store.writes == f.originalWrites)
        check(f.profiles(f.ids[0]) == listOf(config(1)) && f.profiles(f.ids[1]) == listOf(config(2)))
        // A failed new import cannot create a subscription or replace either saved list.
        f.responses[3] = ResponseSpec(onStatus = {
            throw SSLPeerUnverifiedException("private-token certificate")
        })
        val imported = f.invoke("importSubscription", mapOf(
            "name" to "New provider", "url" to "https://provider3.example/sub/private-token-3"))
        check(imported.code == "SUBSCRIPTION_TLS_ERROR")
        check(f.store.subscriptionRecords().map { it.id } == f.ids)
        check(f.store.writes == f.originalWrites)
        check(f.errors() == mapOf(f.ids[0] to "SUBSCRIPTION_TLS_ERROR"))
        check(f.profiles(f.ids[0]) == listOf(config(1)) && f.profiles(f.ids[1]) == listOf(config(2)))
        // After the provider is corrected, a normal verified refresh clears only its error.
        f.responses[1] = ResponseSpec(body = config(111))
        check(f.errors(f.invoke("refreshSubscription", mapOf("id" to f.ids[0])).status()).isEmpty())
        check(f.profiles(f.ids[0]) == listOf(config(111)) && f.profiles(f.ids[1]) == listOf(config(2)))
        check(f.opened == listOf(1, 3, 1) && f.store.writes == f.originalWrites + 1)
    }
    Fixture(5).use { f ->
        for (number in 1..5) f.responses[number] = ResponseSpec(status = 503)
        val status = f.invoke("refreshDue").status()
        check(f.opened == listOf(1, 2, 3, 4, 5))
        check(f.errors(status) == f.ids.associateWith { "SUBSCRIPTION_NETWORK_ERROR" })
        check(f.store.writes == f.originalWrites)
        for (number in 1..5) check(f.profiles(f.ids[number - 1]) == listOf(config(number)))
        check(f.errors(f.invoke("refreshDue").status()) == f.errors(status) && f.opened.size == 5)
    }
}

private fun manualRecoveryAndDeletionOnlyClearTheirOwnErrors() {
    Fixture(3).use { f ->
        for (number in 1..3) f.responses[number] = ResponseSpec(status = 401)
        f.invoke("refreshDue").status()
        f.responses[1] = ResponseSpec(body = config(111))
        val status = f.invoke("refreshSubscription", mapOf("id" to f.ids[0])).status()
        check(f.errors(status) == f.ids.drop(1).associateWith { "SUBSCRIPTION_AUTH_REQUIRED" })
        check(f.profiles(f.ids[0]) == listOf(config(111)))
        f.responses[2] = ResponseSpec(body = "%bad%")
        check(f.invoke("refreshSubscription", mapOf("id" to f.ids[1])).code == "SUBSCRIPTION_INVALID")
        check(f.errors() == mapOf(f.ids[1] to "SUBSCRIPTION_INVALID", f.ids[2] to "SUBSCRIPTION_AUTH_REQUIRED"))
        val deleted = f.invoke("deleteSubscription", mapOf("id" to f.ids[1])).status()
        check(f.errors(deleted) == mapOf(f.ids[2] to "SUBSCRIPTION_AUTH_REQUIRED"))
        check(f.activity.preferences.getLong("attempt_${f.ids[1]}", 0) == 0L)
        // Catalog changes outside this bridge cannot retain errors for missing IDs.
        f.store.deleteSubscription(f.ids[2])
        check(f.errors().isEmpty())
        f.invoke("setAutomaticUpdates", mapOf("enabled" to false)).status()
        f.responses[1] = ResponseSpec(body = config(112))
        val manual = f.invoke("refreshSubscription", mapOf("id" to f.ids[0])).status()
        check(manual["automaticUpdatesEnabled"] == false && f.profiles(f.ids[0]) == listOf(config(112)))
    }
}

private fun globalFailuresStopTheBatch() {
    for (code in listOf("VPN_ACTIVE", "VPN_BUSY", "VPN_STATE_UNAVAILABLE", "SUBSCRIPTION_BUSY")) {
        Fixture(gateCode = code).use { f ->
            check(f.invoke("refreshDue").code == code)
            check(f.opened.isEmpty() && f.store.writes == f.originalWrites)
            check(f.errors().isEmpty())
            check(f.activity.preferences.getLong("attempt_${f.ids[0]}", 0) == 0L)
        }
    }
    Fixture().use { f ->
        f.activity.preferences.failWrites = true
        check(f.invoke("refreshDue").code == "SUBSCRIPTION_STORE_FAILED")
        check(f.opened.isEmpty() && f.store.writes == f.originalWrites && f.errors().isEmpty())
    }
    // Even a code that is safe when produced by a provider is fatal when produced by storage.
    for (failure in listOf(SubscriptionFailure("SUBSCRIPTION_INVALID"), SubscriptionFailure("SUBSCRIPTION_CHANGED"),
        IllegalStateException("synthetic private-token must never escape"))) Fixture().use { f ->
        f.store.refreshFailure = failure
        val expected = if (failure is SubscriptionFailure) failure.code else "SUBSCRIPTION_UNAVAILABLE"
        check(f.invoke("refreshDue").code == expected)
        check(f.opened == listOf(1) && f.store.writes == f.originalWrites && f.errors().isEmpty())
    }
    Fixture().use { f ->
        repeat(18) { f.store.catalogStore.save("manual-$it", name = "Manual $it", createNew = true) }
        f.responses[1] = ResponseSpec(body = config(101) + "\n" + config(201))
        val before = f.store.writes
        check(f.invoke("refreshDue").code == "PROFILE_LIMIT_REACHED")
        check(f.opened == listOf(1) && f.store.writes == before && f.errors().isEmpty())
    }
    Fixture().use { f ->
        f.store.failWrites = true
        check(f.invoke("refreshDue").code == "PROFILE_STORE_UNAVAILABLE")
        check(f.opened == listOf(1))
    }
    Fixture().use { f ->
        f.responses[1] = ResponseSpec(onStatus = { f.store.deleteSubscription(f.ids[0]) })
        check(f.invoke("refreshDue").code == "SUBSCRIPTION_NOT_FOUND")
        check(f.opened == listOf(1) && f.errors().isEmpty())
    }
    Fixture().use { f ->
        f.responses[1] = ResponseSpec(status = 401, onStatus = {
            f.store.replaceUrlForTest(f.ids[0], "https://provider1.example/new-private-token")
        })
        check(f.invoke("refreshDue").code == "SUBSCRIPTION_CHANGED")
        check(f.opened == listOf(1) && f.errors().isEmpty())
    }
    Fixture().use { f ->
        f.responses[1] = ResponseSpec(status = 401)
        f.responses[2] = ResponseSpec(status = 503)
        f.invoke("refreshDue").status()
        f.store.replaceUrlForTest(f.ids[0], "https://provider1.example/new-private-token")
        check(f.errors() == mapOf(f.ids[1] to "SUBSCRIPTION_NETWORK_ERROR"))
    }
}

private fun interruptionBetweenProvidersStopsFurtherTraffic() {
    for (turnOff in listOf(false, true)) Fixture().use { f ->
        f.responses[1] = ResponseSpec(status = 401)
        val refresh = f.start("refreshDue")
        Handler.runNext() // Authorize the first provider.
        val next = Handler.takeNextForTest() // The second provider's authoritative gate is queued.
        val off = if (turnOff) f.start("setAutomaticUpdates", mapOf("enabled" to false)) else null
        if (!turnOff) f.bridge.setForeground(false)
        next.run()
        drainUntil { refresh.completions == 1 && (off == null || off.completions == 1) }
        check(refresh.code == "SUBSCRIPTION_INTERRUPTED")
        check(f.opened == listOf(1) && f.store.writes == f.originalWrites)
        check(f.activity.preferences.getLong("attempt_${f.ids[1]}", 0) == 0L)
        if (turnOff) {
            check(!f.activity.preferences.getBoolean("enabled", true))
            f.invoke("refreshDue").status()
            check(f.opened == listOf(1))
        }
    }
}

private fun cancellationDominatesABlockedProviderFailure() {
    for (action in listOf("off", "pause", "dispose")) Fixture().use { f ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val departed = CountDownLatch(1)
        f.responses[1] = ResponseSpec(status = 401, onDisconnect = {
            entered.countDown()
            try {
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(6)
                while (release.count > 0) {
                    check(System.nanoTime() < deadline)
                    try { release.await(20, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {}
                }
            } finally { departed.countDown() }
        })
        val refresh = f.start("refreshDue")
        Handler.runNext()
        check(entered.await(2, TimeUnit.SECONDS))
        try {
            val off = if (action == "off") f.start("setAutomaticUpdates", mapOf("enabled" to false)) else null
            if (action == "pause") f.bridge.setForeground(false)
            if (action == "dispose") f.bridge.dispose()
            drainUntil { refresh.completions == 1 && (off == null || off.completions == 1) }
            check(refresh.code == "SUBSCRIPTION_INTERRUPTED")
            check(f.opened == listOf(1) && f.store.writes == f.originalWrites)
            check(release.count == 1L && departed.count == 1L)
            if (action != "dispose") check(f.errors().isEmpty())
        } finally {
            release.countDown()
            check(departed.await(2, TimeUnit.SECONDS))
        }
    }
}

private fun mixedImportsAndRefreshesReportSkippedProfilesWithoutPartialFailures() {
    Fixture().use { f ->
        f.responses[3] = ResponseSpec(body = "vmess://synthetic\n" + config(3) + "\n" +
            config(4).replace("type=tcp", "type=xhttp"))
        val status = f.invoke("importSubscription", mapOf("name" to "Mixed",
            "url" to "https://provider3.example/sub/private-token-3")).status()
        val imported = f.store.subscriptionRecords().single { it.id !in f.ids }
        check(imported.skippedProfileCount == 2 && f.profiles(imported.id) == listOf(config(3)))
        val metadata = (status["subscriptions"] as List<*>).map { it as Map<*, *> }.single { it["id"] == imported.id }
        check(metadata["skippedProfileCount"] == 2 && metadata["profileCount"] == 1)
        check(!status.toString().contains("private-token") && !status.toString().contains("synthetic"))
        check(f.profiles(f.ids[0]) == listOf(config(1)) && f.profiles(f.ids[1]) == listOf(config(2)))
        val selected = (f.store.catalogStore.metadata()["profiles"] as List<*>).map { it as Map<*, *> }
            .single { it["subscriptionId"] == imported.id }["id"] as String
        f.store.catalogStore.select(selected)
        val writes = f.store.writes
        for ((code, body) in listOf(
            "SUBSCRIPTION_UNSUPPORTED" to "trojan://synthetic\nvmess://synthetic",
            "SUBSCRIPTION_INVALID" to config(30) + "\nvless://broken",
            "SUBSCRIPTION_INVALID" to config(30) + "\nnot a profile",
        )) {
            f.responses[3] = ResponseSpec(body = body)
            check(f.invoke("refreshSubscription", mapOf("id" to imported.id)).code == code)
            check(f.store.writes == writes && f.profiles(imported.id) == listOf(config(3)))
            check(f.store.catalogStore.metadata()["activeProfileId"] == selected)
            check(f.store.subscriptionRecords().single { it.id == imported.id }.skippedProfileCount == 2)
        }
        f.responses[3] = ResponseSpec(body = config(3))
        val clean = f.invoke("refreshSubscription", mapOf("id" to imported.id)).status()
        check(f.store.subscriptionRecords().single { it.id == imported.id }.skippedProfileCount == 0)
        check((clean["subscriptions"] as List<*>).map { it as Map<*, *> }
            .single { it["id"] == imported.id }["skippedProfileCount"] == 0)
        check(f.store.catalogStore.metadata()["activeProfileId"] == selected && f.errors(clean).isEmpty())
    }
}

fun main() {
    try {
        partialRefreshContinues()
        providerFailuresAreBoundedAndPreserveProfiles()
        manualRecoveryAndDeletionOnlyClearTheirOwnErrors()
        globalFailuresStopTheBatch()
        interruptionBetweenProvidersStopsFurtherTraffic()
        cancellationDominatesABlockedProviderFailure()
        mixedImportsAndRefreshesReportSkippedProfilesWithoutPartialFailures()
        println("Actual subscription coordinator checks passed: 7 regression groups")
    } finally {
        for (name in listOf("network", "reads")) {
            executor(name).shutdownNow()
            check(executor(name).awaitTermination(3, TimeUnit.SECONDS))
        }
        Handler.clearForTest()
    }
}
