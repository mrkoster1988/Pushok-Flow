package shop.pushok.flow

private fun subId(number: Int) = "00000000-0000-0000-0000-" + number.toString().padStart(12, '0')
private fun uri(number: Int, label: String = "Server$number") =
    "vless://00000000-0000-4000-8000-${number.toString().padStart(12, '0')}@example.invalid:443?security=tls&type=tcp#$label"
private fun feed(vararg numbers: Int) = SubscriptionFeed.parse(numbers.joinToString("\n") { uri(it) }.toByteArray(), "expire=1800000000")

private class SubCipher : ProfileCatalogCipher {
    val values = mutableMapOf<String, ProfileCatalog>()
    var fail = false
    override fun encrypt(catalog: ProfileCatalog): String {
        if (fail) error("encrypted storage unavailable")
        return "cipher-${values.size}".also { values[it] = catalog }
    }
    override fun decrypt(encrypted: String) = values.getValue(encrypted)
    override fun decryptLegacy(encrypted: String) = "legacy-private-config"
}

private class SubStorage : ProfileCatalogStorage {
    var disk = EncryptedProfileRecords(null, null)
    var memory = disk
    var fail = false
    var writes = 0
    override fun read() = memory
    override fun replaceCatalog(encrypted: String): Boolean {
        writes++
        memory = EncryptedProfileRecords(encrypted, null)
        if (fail) return false
        disk = memory
        return true
    }
}

private class SubFixture {
    val storage = SubStorage()
    val cipher = SubCipher()
    val state = ProfileCatalogState()
    var sequence = 0
    fun store(state: ProfileCatalogState = this.state) = ProfileCatalogStore(storage, cipher, state) { subId(++sequence) }
}

private fun rejectsSubscription(code: String, block: () -> Any?) {
    try { block(); error("Expected $code") }
    catch (error: SubscriptionFailure) { check(error.code == code) }
    catch (error: ProfileCatalogFailure) { check(error.code == code) }
}

private fun profiles(store: ProfileCatalogStore): List<Map<*, *>> =
    (store.metadata()["profiles"] as List<*>).map { it as Map<*, *> }

private fun equivalentSubscriptionLinksKeepSelection() {
    val fixture = SubFixture()
    val store = fixture.store()
    store.save("manual-preserved", name = "Личный")
    val manual = store.metadata()["activeProfileId"] as String
    val original = "vless://01234567-89ab-4cde-8f01-23456789abcd@edge.example.invalid:443?security=tls&type=tcp#Chosen"
    val rewritten = "VLESS://01234567-89AB-4CDE-8F01-23456789ABCD@EDGE.EXAMPLE.INVALID:00443?fp=chrome&sni=edge.example.invalid&encryption=none&allowInsecure=false&headerType=none&flow=&alpn=&type=raw&security=%74ls#Renamed"
    val own = store.importSubscription("Основная", "https://example.com/main",
        SubscriptionFeed.parse((uri(1) + "\n" + original).toByteArray()), 1)
    val other = store.importSubscription("Резерв", "https://example.com/other", feed(9), 1)
    val originalProfiles = profiles(store)
    val selected = originalProfiles.single { it["name"] == "Chosen" }["id"] as String
    val unchanged = originalProfiles.single { it["subscriptionId"] == own && it["name"] != "Chosen" }["id"] as String
    val otherId = originalProfiles.single { it["subscriptionId"] == other }["id"] as String
    store.select(selected)
    store.refreshSubscription(own, "https://example.com/main",
        SubscriptionFeed.parse((uri(1) + "\n" + rewritten).toByteArray()), 2)
    check(store.metadata()["activeProfileId"] == selected) {
        "Reformatting the selected server silently selected another subscription server"
    }
    check(store.load(selected) == rewritten && store.load() == rewritten)
    check(profiles(store).single { it["id"] == selected }["name"] == "Renamed")
    check(store.load(unchanged) == uri(1) && store.load(manual) == "manual-preserved")
    check(store.load(otherId) == uri(9))
    check(store.subscriptionRecords().single { it.id == other }.updatedAt == 1L)
    // Equality here never loosens the exact-config connection fence.
    rejectsSubscription("PROFILE_CHANGED") { store.validateActive(selected, original) }
    store.validateActive(selected, rewritten)
    val rotated = rewritten.replace("01234567-89AB-4CDE-8F01-23456789ABCD",
        "01234567-89AB-4CDE-8F01-23456789ABCE")
    store.refreshSubscription(own, "https://example.com/main",
        SubscriptionFeed.parse((uri(1) + "\n" + rotated).toByteArray()), 3)
    check(profiles(store).none { it["id"] == selected })
    check(store.metadata()["activeProfileId"] == unchanged && store.load() == uri(1))
    check(store.load(manual) == "manual-preserved" && store.load(otherId) == uri(9))
}

private fun legacyAliasesKeepTheSelectedIdAndRemainRefreshable() {
    val original = uri(2, "Original")
    val alias = original.replace("security=tls&type=tcp", "type=raw&security=tls").replace("#Original", "#Alias")
    val rewritten = original.replace("security=tls&type=tcp", "encryption=none&security=tls").replace("#Original", "#Current")
    val owner = subId(500)
    val first = subId(501)
    val second = subId(502)
    val manual = subId(503)
    val otherOwner = subId(504)
    val other = subId(505)
    for (selected in listOf(first, second, manual)) {
        val fixture = SubFixture()
        fixture.cipher.values["legacy-aliases"] = ProfileCatalog(listOf(
            StoredWireGuardProfile(manual, "Личный", "manual-preserved"),
            StoredWireGuardProfile(first, "Original", original, owner),
            StoredWireGuardProfile(second, "Alias", alias, owner),
            StoredWireGuardProfile(other, "Other", uri(9), otherOwner),
        ), selected, listOf(
            StoredSubscription(owner, "Основная", "https://example.com/main", 1),
            StoredSubscription(otherOwner, "Резерв", "https://example.com/other", 1),
        ))
        fixture.storage.disk = EncryptedProfileRecords("legacy-aliases", null)
        fixture.storage.memory = fixture.storage.disk
        val store = fixture.store()
        check(store.metadata()["activeProfileId"] == selected && profiles(store).size == 4)
        val writes = fixture.storage.writes
        val duplicate = SubscriptionFeed.Parsed(listOf(
            SubscriptionFeed.Entry("First", original), SubscriptionFeed.Entry("Second", alias)
        ), null, null, null, null)
        rejectsSubscription("SUBSCRIPTION_INVALID") {
            store.refreshSubscription(owner, "https://example.com/main", duplicate, 2)
        }
        check(fixture.storage.writes == writes && store.metadata()["activeProfileId"] == selected)
        store.refreshSubscription(owner, "https://example.com/main",
            SubscriptionFeed.parse((uri(1) + "\n" + rewritten).toByteArray()), 3)
        val kept = if (selected == second) second else first
        check(profiles(store).single { it["name"] == "Current" }["id"] == kept)
        check(profiles(store).none { it["id"] == if (kept == first) second else first })
        check(store.metadata()["activeProfileId"] == selected)
        check(store.load(kept) == rewritten && store.load(manual) == "manual-preserved" && store.load(other) == uri(9))
        check(store.subscriptionRecords().single { it.id == otherOwner }.updatedAt == 1L)
    }

    // An old managed entry need not parse with today's importer to be safely replaced.
    for (oldConfig in listOf("vless://legacy-invalid", uri(2).replace("type=tcp", "type=xhttp"))) {
        val fixture = SubFixture()
        fixture.cipher.values["legacy-unreadable"] = ProfileCatalog(listOf(
            StoredWireGuardProfile(first, "Legacy", oldConfig, owner)
        ), first, listOf(StoredSubscription(owner, "Основная", "https://example.com/main", 1)))
        fixture.storage.disk = EncryptedProfileRecords("legacy-unreadable", null)
        fixture.storage.memory = fixture.storage.disk
        val store = fixture.store()
        check(store.load() == oldConfig)
        val invalid = SubscriptionFeed.Parsed(listOf(SubscriptionFeed.Entry("Invalid", oldConfig)), null, null, null, null)
        rejectsSubscription("SUBSCRIPTION_INVALID") {
            store.refreshSubscription(owner, "https://example.com/main", invalid, 2)
        }
        check(fixture.storage.writes == 0 && store.load() == oldConfig)
        store.refreshSubscription(owner, "https://example.com/main", feed(2), 3)
        check(store.load() == uri(2) && store.metadata()["activeProfileId"] != first)
    }
}

private fun partialFeedsPersistCountsAndFailuresPreserveTheWholeCatalog() {
    val fixture = SubFixture()
    val store = fixture.store()
    store.save("manual-preserved", name = "Личный")
    val manual = store.metadata()["activeProfileId"] as String
    val other = store.importSubscription("Резерв", "https://example.com/other", feed(9), 1)
    val mixed = SubscriptionFeed.parse(("vmess://synthetic\n" + uri(1) + "\n" +
        uri(2).replace("type=tcp", "type=xhttp")).toByteArray())
    val own = store.importSubscription("Смешанная", "https://example.com/mixed", mixed, 2)
    val ownProfile = profiles(store).single { it["subscriptionId"] == own }["id"] as String
    fun record() = store.subscriptionRecords().single { it.id == own }
    fun metadata() = (store.subscriptions()["subscriptions"] as List<*>).map { it as Map<*, *> }
        .single { it["id"] == own }
    check(record().skippedProfileCount == 2 && metadata()["skippedProfileCount"] == 2)
    check(metadata()["profileCount"] == 1 && store.load() == "manual-preserved")
    check(store.subscriptionRecords().single { it.id == other }.skippedProfileCount == 0)
    check(!store.subscriptions().toString().contains("synthetic") && !store.subscriptions().toString().contains("vless://"))
    // A recreated store reads the persisted count rather than deriving it from retained servers.
    check(fixture.store().subscriptionRecords().single { it.id == own }.skippedProfileCount == 2)
    store.select(ownProfile)
    store.refreshSubscription(own, "https://example.com/mixed",
        SubscriptionFeed.parse((uri(1, "Renamed") + "\ntrojan://synthetic").toByteArray()), 3)
    check(store.metadata()["activeProfileId"] == ownProfile && store.load() == uri(1, "Renamed"))
    check(record().skippedProfileCount == 1 && metadata()["skippedProfileCount"] == 1)
    val writes = fixture.storage.writes
    val disk = fixture.storage.disk.catalog
    val before = store.subscriptions().toString()
    val failures = listOf(
        "SUBSCRIPTION_UNSUPPORTED" to "vmess://synthetic\n" + uri(2).replace("type=tcp", "type=xhttp"),
        "SUBSCRIPTION_INVALID" to uri(2) + "\nvless://broken",
        "SUBSCRIPTION_INVALID" to uri(2) + "\n" +
            uri(3).replace("type=tcp", "type=xhttp&sni=bad%2Fhost"),
        "SUBSCRIPTION_INVALID" to uri(2) + "\n" +
            uri(3).replace("security=tls", "security=reality&fp=chrome&unknownOption=1"),
        "SUBSCRIPTION_INVALID" to uri(2) + "\n" +
            uri(3).replace("type=tcp", "type=grpc&unknownOption=1"),
        "SUBSCRIPTION_INVALID" to uri(2) + "\nunknown://not-a-supported-family",
        "SUBSCRIPTION_INVALID" to uri(2) + "\nnot a profile",
        "SUBSCRIPTION_TOO_LARGE" to (List(SubscriptionPolicy.MAX_FEED_ENTRIES) { "ss://synthetic" } + uri(2)).joinToString("\n"),
    )
    for ((code, text) in failures) {
        rejectsSubscription(code) {
            store.refreshSubscription(own, "https://example.com/mixed", SubscriptionFeed.parse(text.toByteArray()), 4)
        }
        check(fixture.storage.writes == writes && fixture.storage.disk.catalog == disk)
        check(store.subscriptions().toString() == before && store.load() == uri(1, "Renamed"))
        check(store.metadata()["activeProfileId"] == ownProfile && store.load(manual) == "manual-preserved")
    }
    // The catalog also rejects inconsistent metadata from a bypassed parser.
    for (skipped in listOf(-1, SubscriptionPolicy.MAX_FEED_ENTRIES, Int.MAX_VALUE)) {
        val invalid = SubscriptionFeed.Parsed(listOf(SubscriptionFeed.Entry("One", uri(2))),
            null, null, null, null, skipped)
        rejectsSubscription("SUBSCRIPTION_INVALID") {
            store.refreshSubscription(own, "https://example.com/mixed", invalid, 4)
        }
        check(fixture.storage.writes == writes && fixture.storage.disk.catalog == disk)
    }
    store.refreshSubscription(own, "https://example.com/mixed", feed(1), 5)
    check(record().skippedProfileCount == 0 && metadata()["skippedProfileCount"] == 0)
    check(store.metadata()["activeProfileId"] == ownProfile && store.load(manual) == "manual-preserved")
    check(store.subscriptionRecords().single { it.id == other }.updatedAt == 1L)
}

fun main() {
    equivalentSubscriptionLinksKeepSelection()
    legacyAliasesKeepTheSelectedIdAndRemainRefreshable()
    partialFeedsPersistCountsAndFailuresPreserveTheWholeCatalog()
    val fixture = SubFixture()
    val store = fixture.store()
    store.save("manual-secret", name = "Мой сервер")
    val manual = store.metadata()["activeProfileId"] as String
    val first = store.importSubscription("Основная", "https://example.com/sub/private-token", feed(1, 2), 1000)
    val second = store.importSubscription("Резерв", "https://example.com/sub/other-token", feed(3), 2000)
    check(store.load() == "manual-secret")
    check(profiles(store).size == 4)
    val primaryProfiles = profiles(store).filter { it["subscriptionId"] == first }
    check(primaryProfiles.map { it["subscriptionName"] } == listOf("Основная", "Основная"))
    val selected = primaryProfiles.first()["id"] as String
    val preservedSecond = profiles(store).single { it["subscriptionId"] == second }["id"] as String
    store.select(selected)
    val initialSubscriptions = store.subscriptions().toString()
    check(!initialSubscriptions.contains("private-token") && !initialSubscriptions.contains("vless://"))
    check(!store.subscriptionRecords().toString().contains("private-token"))
    val meta = (store.subscriptions()["subscriptions"] as List<*>).first() as Map<*, *>
    check(meta["host"] == "example.com" && meta["profileCount"] == 2 && meta["updatedAt"] == 1000L)
    check(meta["expiresAt"] == 1_800_000_000_000L)
    check(meta["skippedProfileCount"] == 0)

    // Only this subscription changes, an unchanged server keeps its ID and active selection.
    val reordered = SubscriptionFeed.parse((uri(2) + "\n" + uri(1, "NewLabel") + "\n" + uri(4)).toByteArray())
    store.refreshSubscription(first, "https://example.com/sub/private-token", reordered, 3000)
    check(store.metadata()["activeProfileId"] == selected)
    check(store.load(selected) == uri(1, "NewLabel"))
    check(store.load(manual) == "manual-secret" && store.load(preservedSecond) == uri(3))
    check(store.subscriptionRecords().single { it.id == second }.updatedAt == 2000L)
    check(store.subscriptionRecords().single { it.id == first }.expiresAt == null)

    // Removing the selected server chooses another server of that same refreshed subscription.
    store.refreshSubscription(first, "https://example.com/sub/private-token", feed(2, 4), 4000)
    check(store.load() == uri(2))
    val writes = fixture.storage.writes
    val disk = fixture.storage.disk.catalog
    rejectsSubscription("SUBSCRIPTION_EXISTS") {
        store.importSubscription("Duplicate", "https://EXAMPLE.com:443/sub/private-token", feed(9), 1)
    }
    rejectsSubscription("SUBSCRIPTION_CHANGED") {
        store.refreshSubscription(first, "https://example.com/sub/wrong", feed(9), 1)
    }
    rejectsSubscription("SUBSCRIPTION_NOT_FOUND") { store.deleteSubscription(subId(999)) }
    rejectsSubscription("PROFILE_MANAGED") { store.save(uri(99), name = "Manual edit") }
    rejectsSubscription("PROFILE_MANAGED") { store.delete() }
    check(fixture.storage.writes == writes && fixture.storage.disk.catalog == disk && store.load() == uri(2))

    // Metadata-only/manual mutations do not accidentally discard subscription records.
    store.save("manual-edited", profileId = manual, name = "Личный")
    store.select(manual)
    check(store.subscriptionRecords().size == 2 && store.load() == "manual-edited")
    store.deleteSubscription(first)
    check(store.load() == "manual-edited" && store.load(preservedSecond) == uri(3))
    check(profiles(store).none { it["subscriptionId"] == first })
    store.delete(manual)
    check(store.load() == uri(3) && store.subscriptionRecords().size == 1)
    store.deleteSubscription(second)
    check(!store.exists() && store.load() == null && store.subscriptionRecords().isEmpty())

    // A previous catalog with manual entries is extended, never replaced by subscription import.
    val old = SubFixture()
    old.storage.memory = EncryptedProfileRecords("old-v1", null)
    old.storage.disk = old.storage.memory
    old.cipher.values["old-v1"] = ProfileCatalog(listOf(StoredWireGuardProfile(subId(500), "Старый", "keep-me")), subId(500))
    old.store().importSubscription("New", "https://example.com/new", feed(7), 100)
    check(old.store().load() == "keep-me" && old.store().subscriptionRecords().size == 1)

    // Limits reject before persisting and leave the old state complete.
    val full = SubFixture(); val fullStore = full.store()
    repeat(19) { fullStore.save("manual-$it", name = "Manual $it", createNew = true) }
    rejectsSubscription("PROFILE_LIMIT_REACHED") { fullStore.importSubscription("Two", "https://example.com/2", feed(1, 2), 1) }
    check(full.storage.writes == 19 && profiles(fullStore).size == 19)
    val oneSub = fullStore.importSubscription("One", "https://example.com/1", feed(1), 1)
    rejectsSubscription("PROFILE_LIMIT_REACHED") { fullStore.refreshSubscription(oneSub, "https://example.com/1", feed(1, 2), 2) }
    check(full.storage.writes == 20 && profiles(fullStore).size == 20)
    val subs = SubFixture(); val subsStore = subs.store()
    repeat(5) { subsStore.importSubscription("Sub $it", "https://example.com/sub/$it", feed(it + 1), 1) }
    rejectsSubscription("SUBSCRIPTION_LIMIT_REACHED") { subsStore.importSubscription("Six", "https://example.com/6", feed(6), 1) }
    check(subs.storage.writes == 5)

    // Network/parser failures happen before a commit; encryption failure also leaves disk untouched.
    val safe = SubFixture(); val safeStore = safe.store()
    val safeId = safeStore.importSubscription("Working", "https://example.com/working", feed(1), 1)
    val workingDisk = safe.storage.disk.catalog
    rejectsSubscription("SUBSCRIPTION_UNSUPPORTED") {
        safeStore.refreshSubscription(safeId, "https://example.com/working",
            SubscriptionFeed.parse("vmess://synthetic\ntrojan://synthetic".toByteArray()), 2)
    }
    check(safe.storage.disk.catalog == workingDisk && safeStore.load() == uri(1))
    safe.cipher.fail = true
    try { safeStore.refreshSubscription(safeId, "https://example.com/working", feed(2), 2); error("Expected encryption failure") }
    catch (_: IllegalStateException) {}
    check(safe.storage.disk.catalog == workingDisk && safe.storage.writes == 1)
    safe.cipher.fail = false
    safe.storage.fail = true
    rejectsSubscription("PROFILE_STORE_UNAVAILABLE") { safeStore.refreshSubscription(safeId, "https://example.com/working", feed(2), 2) }
    check(safe.storage.disk.catalog == workingDisk)
    rejectsSubscription("PROFILE_STORE_UNAVAILABLE") { safe.store().subscriptionRecords() }
    safe.storage.memory = safe.storage.disk
    check(safe.store(ProfileCatalogState()).load() == uri(1))
    println("Subscription catalog atomicity and migration checks passed")
}
