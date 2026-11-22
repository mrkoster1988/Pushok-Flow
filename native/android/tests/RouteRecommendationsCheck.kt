package shop.pushok.flow

import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private fun bytes(value: String) = value.toByteArray(StandardCharsets.UTF_8)
private fun payload(version: Int, vararg packages: String) = bytes(
    "{\"schema_version\":1,\"rules_version\":$version,\"recommended_bypass_packages\":[" +
        packages.joinToString(",") { "\"$it\"" } + "]}\n")

private fun envelope(payload: ByteArray, key: KeyPair,
    domain: String = RouteRecommendationPolicy.DOMAIN): ByteArray {
    val signer = Signature.getInstance("SHA256withRSA")
    signer.initSign(key.private)
    signer.update(bytes(domain))
    signer.update(payload)
    val signature = signer.sign()
    return encodedEnvelope(Base64.getEncoder().encodeToString(payload),
        Base64.getEncoder().encodeToString(signature))
}

private fun encodedEnvelope(payload: String, signature: String) = bytes(
    "{\"schema_version\":1,\"payload\":\"$payload\",\"signature\":\"$signature\"}\n")

private fun reject(code: String, action: () -> Any?) {
    try { action(); error("Expected $code") }
    catch (failure: RouteRecommendationFailure) {
        check(failure.code == code && failure.message == code && failure.cause == null)
    }
}

private class MemoryRecommendations : RouteRecommendationStorage {
    var disk: ByteArray? = null
    var failRead = false
    var failPrepare = false
    var failCommit = false
    var failReadback = false
    var beforeCommit: () -> Unit = {}
    var writes = 0
    var prepared = 0
    var aborted = 0
    override fun read(): ByteArray? {
        if (failRead) throw IOException("private path")
        return disk?.copyOf()
    }
    override fun replace(value: ByteArray, commit: (write: () -> Unit) -> Unit) {
        prepared++
        val staged = value.copyOf()
        var finalized = false
        replaceRecommendationFile(
            prepare = { if (failPrepare) throw IOException("private storage error"); beforeCommit() },
            finish = {
                if (failCommit) throw IOException("private sync error")
                disk = staged
                writes++
                finalized = true
            },
            verifyCommitted = { if (failReadback) throw IOException("private read-back error") },
            abortUnfinished = {
                aborted++
                // Model pre-Android-30 failWrite: calling it after finish can erase the base.
                if (finalized) disk = null
            },
            commit = commit,
        )
    }
}

fun main() {
    checkRecommendationAutomation()
    val keys = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
    val otherKeys = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
    fun verify(value: ByteArray) = RouteRecommendationPolicy.verify(value, keys.public)
    val onePayload = payload(1, "com.example.second", "com.example.first")
    val one = envelope(onePayload, keys)
    val two = envelope(payload(2, "com.example.next"), keys)
    val current = verify(one)
    check(current.rulesVersion == 1 && current.packages == listOf("com.example.first", "com.example.second"))
    check(current.envelope().contentEquals(one))
    val copied = current.envelope()
    copied.fill(0)
    check(current.envelope().contentEquals(one))
    try { (current.packages as MutableList<String>).clear(); error("mutable packages") }
    catch (_: UnsupportedOperationException) { }

    // Signature authenticates exact bytes and the fixed data domain, not a re-serialized JSON object.
    reject("RECOMMENDATIONS_INVALID") { RouteRecommendationPolicy.verify(one, otherKeys.public) }
    reject("RECOMMENDATIONS_INVALID") { verify(envelope(onePayload, keys, "another data type\n")) }
    val changed = String(one, StandardCharsets.UTF_8).replace(
        Base64.getEncoder().encodeToString(onePayload), Base64.getEncoder().encodeToString(payload(9)))
    reject("RECOMMENDATIONS_INVALID") { verify(bytes(changed)) }
    val rawSignature = Signature.getInstance("SHA256withRSA").run {
        initSign(keys.private); update(onePayload); sign()
    }
    reject("RECOMMENDATIONS_INVALID") { verify(encodedEnvelope(
        Base64.getEncoder().encodeToString(onePayload), Base64.getEncoder().encodeToString(rawSignature))) }

    // Strict JSON types, shape, UTF-8, integer bounds and duplicate fields.
    val badPayloads = listOf(
        "{\"schema_version\":2,\"rules_version\":1,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":true,\"rules_version\":1,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":0,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":-1,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":2147483648,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":1.0,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":1e0,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":01,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":\"1\",\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":1,\"rules_version\":2,\"recommended_bypass_packages\":[]}",
        "{\"schema_version\":1,\"rules_version\":1,\"recommended_bypass_packages\":[],\"url\":\"https://evil.invalid\"}",
        "{\"schema_version\":1,\"rules_version\":1,\"recommended_bypass_packages\":null}",
        "{\"schema_version\":1,\"rules_version\":1,\"recommended_bypass_packages\":[123]}",
        "{\"schema_version\":1,\"rules_version\":1,\"recommended_bypass_packages\":[\"com.example.one\",]}",
        "{\"schema_version\":1,\"rules_version\":1,\"recommended_bypass_packages\":[]}{\"extra\":1}",
        "{\"schema_version\":1,\"rules_version\":1,\"recommended_bypass_packages\":[],}",
    )
    for (value in badPayloads) reject("RECOMMENDATIONS_INVALID") { verify(envelope(bytes(value), keys)) }
    reject("RECOMMENDATIONS_INVALID") { verify(envelope(byteArrayOf(0xc3.toByte(), 0x28), keys)) }
    reject("RECOMMENDATIONS_INVALID") { verify(byteArrayOf(0xc3.toByte(), 0x28)) }
    check(verify(envelope(payload(Int.MAX_VALUE), keys)).rulesVersion == Int.MAX_VALUE)
    val reordered = bytes("{\"recommended_bypass_packages\":[\"com.example.a\"], \"rules_version\":3, \"schema_version\":1}")
    check(verify(envelope(reordered, keys)).packages == listOf("com.example.a"))

    for (packages in listOf(arrayOf("com.example.a", "com.example.a"), arrayOf("android"),
        arrayOf("com..app"), arrayOf("com.приложение"), arrayOf("com.example.app\\n"),
        arrayOf("com.example.app/extra"), arrayOf("com." + "a".repeat(252)))) {
        reject("RECOMMENDATIONS_INVALID") { verify(envelope(payload(1, *packages), keys)) }
    }
    val limit = (0 until RouteRecommendationPolicy.MAX_PACKAGES).map { "com.example.app$it" }.toTypedArray()
    check(verify(envelope(payload(1, *limit), keys)).packages.size == 256)
    reject("RECOMMENDATIONS_INVALID") { verify(envelope(payload(1, *limit, "com.example.extra"), keys)) }
    reject("RECOMMENDATIONS_INVALID") {
        verify(envelope(ByteArray(RouteRecommendationPolicy.MAX_PAYLOAD_BYTES + 1) { ' '.code.toByte() }, keys))
    }
    reject("RECOMMENDATIONS_INVALID") { verify(ByteArray(RouteRecommendationPolicy.MAX_ENVELOPE_BYTES + 1)) }

    // Standard Base64 must be canonical, with no whitespace, missing padding or alternate pad bits.
    val validSignature = String(one, StandardCharsets.UTF_8).substringAfter("\"signature\":\"").substringBefore('"')
    val encodedPayload = Base64.getEncoder().encodeToString(onePayload)
    for (value in listOf("", "A", "AA=", "AA===", "====", "AB==", "AAB=", "AA-_", "AA A", "AA\nA")) {
        reject("RECOMMENDATIONS_INVALID") { verify(encodedEnvelope(value, validSignature)) }
    }
    for (size in listOf(0, 255, 1025)) reject("RECOMMENDATIONS_INVALID") {
        verify(encodedEnvelope(encodedPayload, Base64.getEncoder().encodeToString(ByteArray(size))))
    }
    reject("RECOMMENDATIONS_INVALID") { verify(bytes(String(one, StandardCharsets.UTF_8)
        .replace("\"schema_version\":1", "\"schema_version\":1,\"schema_version\":1"))) }
    reject("RECOMMENDATIONS_INVALID") { verify(bytes(String(one, StandardCharsets.UTF_8) + "{}")) }

    val guard: (action: () -> Unit) -> Unit = { it() }
    val storage = MemoryRecommendations()
    val store = RouteRecommendationStore(storage, ::verify)
    check(store.snapshot().recommendations.rulesVersion == 0 && store.snapshot().recommendations.packages.isEmpty())
    check(store.snapshot().checkedAtMillis == null)
    store.restore(guard)
    check(storage.writes == 0)
    store.accept(one, 1000L, guard)
    check(store.snapshot().recommendations.packages == current.packages && store.snapshot().checkedAtMillis == 1000L)
    store.accept(one, 2000L, guard)
    check(store.snapshot().checkedAtMillis == 2000L)
    val changedSameVersion = envelope(payload(1, "com.example.changed"), keys)
    val sameSemanticDifferentBytes = envelope(onePayload + byteArrayOf(' '.code.toByte()), keys)
    val beforeRejected = storage.prepared
    for (value in listOf(changedSameVersion, sameSemanticDifferentBytes)) {
        reject("RECOMMENDATIONS_STALE") { store.accept(value, 9999L, guard) }
    }
    check(storage.prepared == beforeRejected && store.snapshot().checkedAtMillis == 2000L)
    check(storage.disk!!.contentEquals(one))

    // Failed preparation, final durable write or lifecycle guard never acknowledge or erase old data.
    for (prepare in listOf(true, false)) {
        storage.failPrepare = prepare
        storage.failCommit = !prepare
        reject("RECOMMENDATIONS_STORAGE_ERROR") { store.accept(two, 3000L, guard) }
        check(storage.disk!!.contentEquals(one) && store.snapshot().recommendations.rulesVersion == 1)
        check(store.snapshot().checkedAtMillis == 2000L)
    }
    storage.failPrepare = false
    storage.failCommit = false
    reject("RECOMMENDATIONS_INTERRUPTED") { store.accept(two, 3000L) {
        throw RouteRecommendationFailure("RECOMMENDATIONS_INTERRUPTED")
    } }
    check(storage.disk!!.contentEquals(one) && store.snapshot().checkedAtMillis == 2000L)

    val staged = CountDownLatch(1)
    val resume = CountDownLatch(1)
    val executor = Executors.newSingleThreadExecutor()
    val lifecycle = Any()
    var active = true
    storage.beforeCommit = { staged.countDown(); check(resume.await(10, TimeUnit.SECONDS)) }
    try {
        val pending = executor.submit {
            reject("RECOMMENDATIONS_INTERRUPTED") { store.accept(two, 4000L) { action ->
                synchronized(lifecycle) {
                    if (!active) throw RouteRecommendationFailure("RECOMMENDATIONS_INTERRUPTED")
                    action()
                }
            } }
        }
        check(staged.await(10, TimeUnit.SECONDS))
        synchronized(lifecycle) { active = false }
        resume.countDown()
        pending.get(10, TimeUnit.SECONDS)
        check(storage.disk!!.contentEquals(one) && store.snapshot().recommendations.rulesVersion == 1)
    } finally { executor.shutdownNow(); storage.beforeCommit = {} }

    store.accept(two, 5000L, guard)
    reject("RECOMMENDATIONS_STALE") { store.accept(one, 6000L, guard) }
    check(store.snapshot().recommendations.rulesVersion == 2 && store.snapshot().checkedAtMillis == 5000L)
    val restarted = RouteRecommendationStore(storage, ::verify)
    restarted.restore(guard)
    check(restarted.snapshot().recommendations.rulesVersion == 2 && restarted.snapshot().checkedAtMillis == null)
    storage.failRead = true
    reject("RECOMMENDATIONS_STORAGE_ERROR") { store.restore(guard) }
    check(store.snapshot().recommendations.rulesVersion == 2 && store.snapshot().checkedAtMillis == 5000L)
    storage.failRead = false
    storage.disk = envelope(payload(3, "com.example.attacker"), otherKeys)
    reject("RECOMMENDATIONS_INVALID") { store.restore(guard) }
    check(store.snapshot().recommendations.rulesVersion == 2 && store.snapshot().checkedAtMillis == 5000L)
    storage.disk = one
    reject("RECOMMENDATIONS_STALE") { store.restore(guard) }
    check(store.snapshot().recommendations.rulesVersion == 2)
    // A successful explicit refresh can repair cache damage without altering user route selections.
    store.accept(two, 7000L, guard)
    check(storage.disk!!.contentEquals(two))

    val readbackStorage = MemoryRecommendations()
    val readbackStore = RouteRecommendationStore(readbackStorage, ::verify)
    readbackStore.accept(one, 1000L, guard)
    readbackStorage.failReadback = true
    reject("RECOMMENDATIONS_STORAGE_ERROR") { readbackStore.accept(two, 2000L, guard) }
    check(readbackStore.snapshot().recommendations.rulesVersion == 1)
    check(readbackStore.snapshot().checkedAtMillis == 1000L)
    check(readbackStorage.aborted == 0 && readbackStorage.disk!!.contentEquals(two))
    // A later successful re-verification can safely recover the durable finalised record.
    readbackStore.restore(guard)
    check(readbackStore.snapshot().recommendations.rulesVersion == 2)
    check(readbackStore.snapshot().checkedAtMillis == null)

    // Opt-out is serialized with the signed catalogue commit, independently of Activity lifetime.
    val automaticRequests = RecommendationAutomaticRequests()
    val cancelledStorage = MemoryRecommendations()
    val cancelledStore = RouteRecommendationStore(cancelledStorage, ::verify)
    cancelledStore.accept(one, 1000L, guard)
    val requestToken = automaticRequests.capture()
    cancelledStorage.beforeCommit = { automaticRequests.cancel() }
    reject("RECOMMENDATIONS_INTERRUPTED") {
        cancelledStore.accept(two, 2000L) { action -> automaticRequests.guarded(requestToken, action) }
    }
    check(cancelledStorage.disk!!.contentEquals(one))
    check(cancelledStore.snapshot().recommendations.rulesVersion == 1)
    check(cancelledStore.snapshot().checkedAtMillis == 1000L)
    // A manual refresh has no automatic token and remains usable after opt-out.
    cancelledStorage.beforeCommit = {}
    cancelledStore.accept(two, 3000L, guard)
    check(cancelledStore.snapshot().recommendations.rulesVersion == 2)

    println("Route recommendation signatures, strict data validation, rollback and guarded storage checks passed")
}
