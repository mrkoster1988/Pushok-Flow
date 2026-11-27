package shop.pushok.flow

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private class FakeRoutes(initial: Set<*> = emptySet<String>()) : RouteSettingsStorage {
    var disk: Set<*> = initial.toSet()
    var memory: Set<*> = disk
    var failCommit = false
    var throwCommit = false
    var failRead = false
    var reads = 0
    var writes = 0

    override fun read(): Set<*> {
        reads++
        if (failRead) error("PRIVATE_STORAGE_ERROR")
        return memory
    }

    override fun replace(packages: Set<String>): Boolean {
        writes++
        // Android mutates the in-process preference map before commit returns.
        memory = packages.toSet()
        if (throwCommit) error("PRIVATE_STORAGE_ERROR")
        if (failCommit) return false
        disk = memory
        return true
    }

    fun restart() { memory = disk }
}

private fun request(packages: List<String>, expected: List<String>? = null): RouteSettingsRequest {
    val args = mutableMapOf<String, Any>("packages" to packages)
    if (expected != null) args["expectedPackages"] = expected
    return RouteSettingsRequest.parse(args)
}

private fun reject(code: String, action: () -> Any?) {
    try { action(); error("Expected $code") }
    catch (failure: RouteSettingsFailure) {
        check(failure.code == code)
        check(failure.message == code && failure.cause == null)
    }
}

fun main() {
    // The bundled defaults are offline and only installed recommendations can
    // be selected; all other apps and absent packages are left untouched.
    check(RouteInitialRecommendations.packages.size == 16)
    check(RouteInitialRecommendations.installedOnly(listOf(
        "ru.dublgis.dgismobile", "ru.gazprombank.android.mobilebank.app", "com.example.other",
    )) == setOf("ru.dublgis.dgismobile", "ru.gazprombank.android.mobilebank.app"))
    check(RouteInitialRecommendations.installedOnly(listOf(
        "com.vkontakte.android", "ru.sberbankmobile", "com.example.other",
        "ru.sberbankmobile", "com.example.missing",
    )) == setOf("com.vkontakte.android", "ru.sberbankmobile"))
    check(RouteInitialRecommendations.installedOnly(emptyList()).isEmpty())
    check(RouteInitialRecommendations.installedOnly(listOf("com.example.other")).isEmpty())
    val storage = FakeRoutes()
    val state = RouteSettingsState()
    val firstActivity = RouteSettingsStore(storage, state)
    val secondActivity = RouteSettingsStore(storage, state)
    check(firstActivity.read().isEmpty() && storage.writes == 0)
    val saved = listOf("com.example.browser", "com.example.no_launcher", "com.example.uninstalled")
    firstActivity.replace(request(saved, emptyList()))
    check(secondActivity.read() == saved.toSet())
    check(storage.disk == saved.toSet() && storage.writes == 1)
    // Returned sets are snapshots; callers cannot mutate SharedPreferences by alias.
    (firstActivity.read() as MutableSet<String>).clear()
    check(secondActivity.read() == saved.toSet())
    firstActivity.replace(request(saved.reversed(), saved))
    check(storage.writes == 1) // A no-op still validates its expected selection.
    reject("ROUTES_CHANGED") { secondActivity.replace(request(emptyList(), emptyList())) }
    check(storage.writes == 1 && secondActivity.read() == saved.toSet())
    // No installed-app filtering: absent launcher entries survive an unrelated change.
    firstActivity.replace(request(saved + "com.example.chat", saved))
    reject("ROUTES_CHANGED") { secondActivity.replace(request(emptyList(), saved)) }
    check(firstActivity.read() == (saved + "com.example.chat").toSet())
    // Legacy callers without an expected set remain compatible.
    firstActivity.replace(request(listOf("com.example.browser")))
    check(secondActivity.read() == setOf("com.example.browser"))
    secondActivity.replace(request(emptyList(), listOf("com.example.browser")))
    check(firstActivity.read().isEmpty())

    // Malformed channel requests never reach storage or erase old choices.
    val malformed = listOf<Any?>(
        null, "PRIVATE_PAYLOAD", emptyMap<String, Any>(),
        mapOf("packages" to null), mapOf("packages" to "com.example.app"),
        mapOf("packages" to listOf(123)), mapOf("packages" to listOf(null)),
        mapOf("packages" to listOf("PRIVATE_PAYLOAD")),
        mapOf("packages" to listOf("com.example.app", "com.example.app")),
        mapOf("packages" to emptyList<String>(), "expectedPackages" to null),
        mapOf("packages" to emptyList<String>(), "expectedPackages" to listOf(true)),
        mapOf("packages" to emptyList<String>(), "expectedPackages" to listOf("com.example.app", "com.example.app")),
        mapOf("packages" to emptyList<String>(), "unexpected" to true),
    )
    val readsBeforeMalformed = storage.reads
    for (args in malformed) reject("INVALID_PACKAGES") { RouteSettingsRequest.parse(args) }
    check(storage.reads == readsBeforeMalformed)
    for (invalid in listOf("", "android", ".app", "com..app", "com.app.", "com.app\n", " com.app", "com.app/path", "com.приложение")) {
        reject("INVALID_PACKAGES") { request(listOf(invalid)) }
    }
    val longest = "a." + "b".repeat(RouteSettingsStore.MAX_PACKAGE_LENGTH - 2)
    check(request(listOf(longest)).packages == setOf(longest))
    reject("INVALID_PACKAGES") { request(listOf(longest + "b")) }
    val limit = (0 until RouteSettingsStore.MAX_PACKAGES).map { "com.example.app$it" }
    check(request(limit).packages.size == RouteSettingsStore.MAX_PACKAGES)
    reject("INVALID_PACKAGES") { request(limit + "com.example.over_limit") }

    // A failed durable write latches every store instance, including connect's reader.
    for (throws in listOf(false, true)) {
        val failedStorage = FakeRoutes(setOf("com.example.original"))
        val failedState = RouteSettingsState()
        val failed = RouteSettingsStore(failedStorage, failedState)
        val otherActivity = RouteSettingsStore(failedStorage, failedState)
        failedStorage.failCommit = !throws
        failedStorage.throwCommit = throws
        reject("ROUTES_STORE_UNAVAILABLE") {
            failed.replace(request(listOf("com.example.changed"), listOf("com.example.original")))
        }
        check(failedStorage.disk == setOf("com.example.original"))
        check(failedStorage.memory == setOf("com.example.changed"))
        val readsAfterFailure = failedStorage.reads
        reject("ROUTES_STORE_UNAVAILABLE") { failed.read() }
        reject("ROUTES_STORE_UNAVAILABLE") { otherActivity.read() }
        reject("ROUTES_STORE_UNAVAILABLE") { otherActivity.replace(request(emptyList())) }
        check(failedStorage.reads == readsAfterFailure && failedStorage.writes == 1)
        // A fresh process reloads authoritative disk, preserving the old selections.
        failedStorage.restart()
        failedStorage.failCommit = false
        failedStorage.throwCommit = false
        val restarted = RouteSettingsStore(failedStorage, RouteSettingsState())
        check(restarted.read() == setOf("com.example.original"))
        restarted.replace(request(listOf("com.example.changed"), listOf("com.example.original")))
        check(restarted.read() == setOf("com.example.changed"))
    }

    // Corrupt/unreadable storage cannot be silently treated as an empty selection.
    for (record in listOf(setOf<Any?>(null), setOf<Any>(123), setOf("PRIVATE_PAYLOAD"), (limit + "com.example.extra").toSet())) {
        val corruptStorage = FakeRoutes(record)
        val corrupt = RouteSettingsStore(corruptStorage, RouteSettingsState())
        reject("ROUTES_LOAD_FAILED") { corrupt.read() }
        reject("ROUTES_LOAD_FAILED") { corrupt.replace(request(emptyList())) }
        check(corruptStorage.writes == 0 && corruptStorage.disk == record)
    }
    storage.failRead = true
    reject("ROUTES_LOAD_FAILED") { firstActivity.read() }
    reject("ROUTES_LOAD_FAILED") { firstActivity.replace(request(saved)) }
    storage.failRead = false
    check(firstActivity.read().isEmpty()) // A read error alone does not poison future reads.

    // Two Activities submit edits based on one old selection: exactly one commits.
    val concurrentStorage = FakeRoutes()
    val concurrentState = RouteSettingsState()
    val gate = CountDownLatch(1)
    val executor = Executors.newFixedThreadPool(2)
    try {
        val results = (1..2).map { index -> executor.submit<String> {
            check(gate.await(5, TimeUnit.SECONDS))
            try {
                RouteSettingsStore(concurrentStorage, concurrentState)
                    .replace(request(listOf("com.example.app$index"), emptyList()))
                "saved"
            } catch (failure: RouteSettingsFailure) { failure.code }
        } }
        gate.countDown()
        check(results.map { it.get(5, TimeUnit.SECONDS) }.sorted() == listOf("ROUTES_CHANGED", "saved"))
        check(concurrentStorage.writes == 1 && concurrentStorage.disk.size == 1)
    } finally { executor.shutdownNow() }

    // Third-party labels are single-line and bounded without splitting surrogate pairs.
    check(RouteAppLabels.normalize("  Browser\nname\t\u0000 ", "com.example.app") == "Browser name")
    check(RouteAppLabels.normalize("A\uD800B\uDC00C\u2028D\u2029E", "fallback") == "A B C D E")
    check(RouteAppLabels.normalize("\n\u0085\uD800", "com.example.app") == "com.example.app")
    check(RouteAppLabels.normalize("\uFEFF\u00A0Browser\uFEFF", "fallback") == "Browser")
    val emoji = "\uD83D\uDE3A".repeat(RouteAppLabels.MAX_CODE_POINTS + 1)
    val normalized = RouteAppLabels.normalize(emoji, "fallback")
    check(normalized.codePointCount(0, normalized.length) == RouteAppLabels.MAX_CODE_POINTS)
    check(normalized.length == RouteAppLabels.MAX_CODE_POINTS * 2)
    println("RouteSettings CAS, failure recovery, validation and label checks passed")
}
