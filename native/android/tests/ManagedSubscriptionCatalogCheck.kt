package shop.pushok.flow

private fun managedId(number: Int) = "90000000-0000-0000-0000-" + number.toString().padStart(12, '0')
private const val MANAGED_PRIVATE = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
private fun managedConfig(port: Int = 51820) = """
    [Interface]
    PrivateKey = $MANAGED_PRIVATE
    Address = 10.77.0.2/32
    DNS = 1.1.1.1
    [Peer]
    PublicKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = 203.0.113.10:$port
    PersistentKeepalive = 25
""".trimIndent()

private fun managedEntry(id: String = "private-device-entry", port: Int = 51820,
    name: String = "Основной") = SubscriptionFeed.Entry(name, managedConfig(port), id)

private fun managedFeed(revision: Long = 1, state: String = "active", expiry: Long = 10_000,
    entries: List<SubscriptionFeed.Entry> = if (state == "active") listOf(managedEntry()) else emptyList()) =
    SubscriptionFeed.Parsed(entries, null, expiry, null, null,
        format = "wireguard-v1", state = state, revision = revision)

private class ManagedCipher : ProfileCatalogCipher {
    val records = mutableMapOf<String, ProfileCatalog>()
    override fun encrypt(catalog: ProfileCatalog) = "cipher-${records.size}".also { records[it] = catalog }
    override fun decrypt(encrypted: String) = records.getValue(encrypted)
    override fun decryptLegacy(encrypted: String) = error("No legacy fallback")
}

private class ManagedStorage : ProfileCatalogStorage {
    var record = EncryptedProfileRecords(null, null)
    var writes = 0
    override fun read() = record
    override fun replaceCatalog(encrypted: String): Boolean {
        writes++
        record = EncryptedProfileRecords(encrypted, null)
        return true
    }
}

private class ManagedFixture {
    val storage = ManagedStorage()
    val cipher = ManagedCipher()
    var clock = 5_000L
    private var id = 0
    val store = ProfileCatalogStore(storage, cipher, ProfileCatalogState(), { clock }) { managedId(++id) }
    fun recreated() = ProfileCatalogStore(storage, cipher, ProfileCatalogState(), { clock }) { managedId(++id) }
}

private fun rejectsManaged(code: String, action: () -> Any?) {
    try { action(); error("Expected $code") }
    catch (failure: SubscriptionFailure) { check(failure.code == code) { failure.code } }
    catch (failure: ProfileCatalogFailure) { check(failure.code == code) { failure.code } }
}

private fun managedProfiles(store: ProfileCatalogStore) =
    (store.metadata()["profiles"] as List<*>).map { it as Map<*, *> }

private fun stableEntriesAndOwnership() {
    val fixture = ManagedFixture()
    val store = fixture.store
    store.save("manual-config", name = "Личный")
    val manual = store.metadata()["activeProfileId"] as String
    val primary = store.importSubscription("Устройство", "https://example.com/private-token",
        managedFeed(entries = listOf(managedEntry(), managedEntry("backup", 51821, "Резерв"))), 1)
    val other = store.importSubscription("Другое", "https://example.com/other",
        managedFeed(), 1)
    val selected = managedProfiles(store).first { it["subscriptionId"] == primary }["id"] as String
    val backup = managedProfiles(store).first { it["name"] == "Резерв" }["id"] as String
    val otherProfile = managedProfiles(store).first { it["subscriptionId"] == other }["id"] as String
    check(selected != otherProfile) // Provider IDs are scoped to a subscription.
    store.select(selected)
    store.refreshSubscription(primary, "https://example.com/private-token", managedFeed(2,
        entries = listOf(managedEntry("backup", 51821, "Резерв"),
            managedEntry(port = 51822, name = "Новое имя"))), 2)
    check(store.metadata()["activeProfileId"] == selected)
    check(store.load(selected) == managedConfig(51822) && store.load(backup) == managedConfig(51821))
    check(store.load(manual) == "manual-config" && store.load(otherProfile) == managedConfig())
    rejectsManaged("PROFILE_CHANGED") { store.validateActive(selected, managedConfig()) }
    store.validateActive(selected, managedConfig(51822))
    rejectsManaged("PROFILE_MANAGED") { store.save(managedConfig(), profileId = selected) }
    rejectsManaged("PROFILE_MANAGED") { store.delete(selected) }
    val public = store.metadata().toString() + store.subscriptions().toString()
    for (secret in listOf(MANAGED_PRIVATE, "private-token", "private-device-entry", "[Interface]", "203.0.113.10")) {
        check(!public.contains(secret)) { "Private managed field entered metadata" }
    }
    val restarted = fixture.recreated()
    check(restarted.metadata()["activeProfileId"] == selected && restarted.load() == managedConfig(51822))
    check(restarted.subscriptionRecords().single { it.id == primary }.revision == 2L)
}

private fun inactiveResponsesAndRenewal() {
    for (state in listOf("expired", "revoked")) {
        val fixture = ManagedFixture()
        val store = fixture.store
        val id = store.importSubscription("Отключена", "https://example.com/sub", managedFeed(state = state), 1)
        check(!store.exists() && store.metadata()["activeProfileId"] == null && store.load() == null)
        check(store.subscriptionRecords().single().state == state)
        check((store.subscriptions()["subscriptions"] as List<*>).single().let { it as Map<*, *> }["profileCount"] == 0)
        store.refreshSubscription(id, "https://example.com/sub", managedFeed(2, expiry = 20_000), 2)
        val selected = store.metadata()["activeProfileId"] as String
        check(store.load() == managedConfig())
        store.refreshSubscription(id, "https://example.com/sub", managedFeed(3, expiry = 30_000), 3)
        check(store.metadata()["activeProfileId"] == selected && store.load() == managedConfig())
        store.save("manual-config", name = "Личный", createNew = true)
        val manual = managedProfiles(store).single { it["subscriptionId"] == null }["id"] as String
        store.refreshSubscription(id, "https://example.com/sub", managedFeed(4, state), 4)
        check(store.metadata()["activeProfileId"] == manual && store.load() == "manual-config")
        check(managedProfiles(store).size == 1 && fixture.recreated().subscriptionRecords().single().state == state)
        store.delete(manual)
        check(!store.exists() && store.subscriptionRecords().size == 1)
        store.deleteSubscription(id)
        check(store.subscriptionRecords().isEmpty())
    }
}

private fun expiryFencesNewConnectionsWithoutDeletingCachedCatalog() {
    val fixture = ManagedFixture()
    val store = fixture.store
    store.importSubscription("Срок", "https://example.com/sub", managedFeed(), 1)
    val selected = store.metadata()["activeProfileId"] as String
    fixture.clock = 9_999
    val loaded = store.load()!!
    store.validateActive(selected, loaded)
    val writes = fixture.storage.writes
    fixture.clock = 10_000 // Expires while Android approval is open.
    rejectsManaged("SUBSCRIPTION_EXPIRED") { store.validateActive(selected, loaded) }
    rejectsManaged("SUBSCRIPTION_EXPIRED") { store.load() }
    rejectsManaged("SUBSCRIPTION_EXPIRED") { store.select(selected) }
    check(fixture.storage.writes == writes && store.exists() && managedProfiles(store).size == 1)
    check(store.subscriptionRecords().single().state == "active") // Declared state is not rewritten by the clock.
    rejectsManaged("SUBSCRIPTION_EXPIRED") { fixture.recreated().load() }
    val legacy = SubscriptionFeed.parse(("vless://00000000-0000-4000-8000-000000000001@" +
        "example.invalid:443?security=tls&type=tcp").toByteArray(), "expire=1")
    val oldId = store.importSubscription("Legacy", "https://example.com/legacy", legacy, 1)
    val oldProfile = managedProfiles(store).single { it["subscriptionId"] == oldId }["id"] as String
    store.select(oldProfile)
    check(store.load() == legacy.entries.single().config) // Legacy expiry is informational.
}

private fun invalidAndReplayedResponsesLeaveCatalogUntouched() {
    val fixture = ManagedFixture()
    val store = fixture.store
    val id = store.importSubscription("Стабильная", "https://example.com/sub", managedFeed(5), 1)
    val unchanged = fixture.storage.record
    val selected = store.metadata()["activeProfileId"]
    val writes = fixture.storage.writes
    val broken = listOf(
        managedFeed(4), managedFeed(5, expiry = 20_000), managedFeed(5, "revoked"),
        managedFeed(6, entries = emptyList()), managedFeed(6, "unknown"), managedFeed(0),
        managedFeed(6, expiry = 10_001),
        managedFeed(6, entries = listOf(SubscriptionFeed.Entry("Invalid", managedConfig()))),
        managedFeed(6, entries = listOf(managedEntry(), managedEntry())),
        managedFeed(6, entries = listOf(SubscriptionFeed.Entry("Broken", managedConfig().replace(
            MANAGED_PRIVATE, "invalid-private-key"), "entry"))),
        managedFeed(6, "expired", entries = listOf(managedEntry())),
    )
    for (feed in broken) {
        rejectsManaged("SUBSCRIPTION_INVALID") { store.refreshSubscription(id, "https://example.com/sub", feed, 2) }
        check(fixture.storage.record === unchanged && fixture.storage.writes == writes)
        check(store.metadata()["activeProfileId"] == selected && store.load() == managedConfig())
    }
    val legacy = SubscriptionFeed.parse(("vless://00000000-0000-4000-8000-000000000001@" +
        "example.invalid:443?security=tls&type=tcp").toByteArray())
    rejectsManaged("SUBSCRIPTION_INVALID") { store.refreshSubscription(id, "https://example.com/sub", legacy, 2) }
    check(fixture.storage.record === unchanged)
    store.refreshSubscription(id, "https://example.com/sub", managedFeed(5), 2)
    check(store.metadata()["activeProfileId"] == selected && store.subscriptionRecords().single().updatedAt == 2L)
    store.refreshSubscription(id, "https://example.com/sub", managedFeed(6, "revoked"), 3)
    rejectsManaged("SUBSCRIPTION_INVALID") { store.refreshSubscription(id, "https://example.com/sub", managedFeed(5), 4) }
    check(!store.exists() && store.subscriptionRecords().single().state == "revoked")
}

fun main() {
    stableEntriesAndOwnership()
    inactiveResponsesAndRenewal()
    expiryFencesNewConnectionsWithoutDeletingCachedCatalog()
    invalidAndReplayedResponsesLeaveCatalogUntouched()
    println("Managed subscription catalog: device-scoped identity, renewal, inactive transitions, expiry fences, replay rejection and atomicity checks passed")
}
