package shop.pushok.flow

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

private fun id(number: Int) = "00000000-0000-0000-0000-" + number.toString().padStart(12, '0')
private const val SECRET = "[Interface]\nPrivateKey = test-only-secret\n[Peer]\n"

private class FakeCipher : ProfileCatalogCipher {
    val catalogs = mutableMapOf<String, ProfileCatalog>()
    var legacyReads = 0
    var failEncryption = false
    override fun encrypt(catalog: ProfileCatalog): String {
        if (failEncryption) throw IllegalStateException("encryption unavailable")
        return "ciphertext-${catalogs.size}".also { catalogs[it] = catalog }
    }
    override fun decrypt(encrypted: String): ProfileCatalog = catalogs[encrypted] ?: error("corrupt record")
    override fun decryptLegacy(encrypted: String): String {
        legacyReads++
        check(encrypted == "legacy-ciphertext")
        return SECRET
    }
}

private class FakeStorage(legacy: String? = null) : ProfileCatalogStorage {
    var disk = EncryptedProfileRecords(null, legacy)
    var memory = disk
    var failCommit = false
    var throwCommit = false
    var writes = 0
    var reads = 0
    override fun read(): EncryptedProfileRecords { reads++; return memory }
    override fun replaceCatalog(encrypted: String): Boolean {
        writes++
        // Model the crucial Android behavior: even a failed commit changes RAM.
        memory = EncryptedProfileRecords(encrypted, null)
        if (throwCommit) throw IllegalStateException("disk unavailable")
        if (failCommit) return false
        disk = memory
        return true
    }
    fun restart() { memory = disk }
}

private class Fixture(legacy: String? = null) {
    val storage = FakeStorage(legacy)
    val cipher = FakeCipher()
    val state = ProfileCatalogState()
    var generated = 0
    fun store(state: ProfileCatalogState = this.state) = ProfileCatalogStore(storage, cipher, state) { id(++generated) }
}

private fun rejects(code: String? = null, operation: () -> Any?) {
    try { operation(); error("Expected rejection") }
    catch (failure: ProfileCatalogFailure) { if (code != null) check(failure.code == code) }
}

private fun rejectsAny(operation: () -> Any?) {
    var failed = false
    try { operation() } catch (_: Exception) { failed = true }
    check(failed)
}

fun main() {
    // Empty storage, a single legacy migration, then repeated reads from a new instance.
    val empty = Fixture()
    check(empty.store().load() == null)
    check(!empty.store().exists())
    check(empty.store().metadata() == mapOf("profiles" to emptyList<Any>(), "activeProfileId" to null))
    check(empty.storage.writes == 0)
    val migrated = Fixture("legacy-ciphertext")
    val first = migrated.store()
    val initial = first.metadata()
    check(initial == mapOf("profiles" to listOf(mapOf("id" to id(1), "name" to "Мой профиль")), "activeProfileId" to id(1)))
    check(!initial.toString().contains("PrivateKey"))
    check(first.load() == SECRET)
    first.validateActive(id(1), SECRET)
    check(migrated.store().load() == SECRET)
    check(migrated.storage.disk.legacy == null)
    check(migrated.storage.writes == 1 && migrated.cipher.legacyReads == 1)

    // A new protocol uses the same encrypted catalog without migrating or
    // overwriting the old WireGuard profile, selected ID or sensitive text.
    val mixed = Fixture("legacy-ciphertext")
    val mixedStore = mixed.store()
    check(mixedStore.load() == SECRET)
    val link = "vless://00000000-0000-4000-8000-000000000001@example.invalid:443?security=tls&type=tcp"
    mixedStore.save(link, name = "3x-ui", createNew = true)
    check(mixedStore.load() == SECRET)
    check(mixedStore.load(id(2)) == link)
    val publicMetadata = mixedStore.metadata().toString()
    check(!publicMetadata.contains("vless://") && !publicMetadata.contains("PrivateKey"))
    mixedStore.select(id(2))
    mixed.storage.restart()
    check(mixed.store(ProfileCatalogState()).load() == link)
    mixedStore.delete(id(2))
    check(mixedStore.load() == SECRET && mixed.cipher.legacyReads == 1)

    // Create, rename an inactive profile, select, and deterministic deletion fallback.
    first.save("second-config", name = "  Работа  ", createNew = true)
    check(first.load() == SECRET)
    first.save("second-edited", profileId = id(2), name = "Резерв")
    check(first.load() == SECRET && first.load(id(2)) == "second-edited")
    rejects("PROFILE_CHANGED") { first.validateActive(id(2), "second-edited") }
    first.select(id(2))
    check(first.load() == "second-edited")
    rejects("PROFILE_CHANGED") { first.validateActive(id(1), SECRET) }
    rejects("PROFILE_CHANGED") { first.validateActive(id(2), "second-config") }
    first.validateActive(id(2), "second-edited")
    first.save("third-config", name = "Третий", createNew = true)
    first.delete(id(1))
    check(first.load() == "second-edited")
    first.delete(id(2))
    check(first.load() == "third-config")
    first.delete()
    check(!first.exists() && first.load() == null && migrated.storage.disk.catalog != null)
    // A surviving stale legacy value cannot resurrect a deleted profile.
    migrated.storage.memory = EncryptedProfileRecords(migrated.storage.disk.catalog, "legacy-ciphertext")
    check(!first.exists())
    check(migrated.cipher.legacyReads == 1)

    // Unknown IDs never create or overwrite a profile and do not change storage.
    val writesBeforeMissing = migrated.storage.writes
    rejects("PROFILE_NOT_FOUND") { first.select(id(900)) }
    rejects("PROFILE_NOT_FOUND") { first.delete(id(900)) }
    rejects("PROFILE_NOT_FOUND") { first.load(id(900)) }
    rejects("PROFILE_NOT_FOUND") { first.save("new", profileId = id(900)) }
    rejects("PROFILE_NOT_FOUND") { first.save("new", profileId = id(900), createNew = true) }
    check(migrated.storage.writes == writesBeforeMissing)

    // A migration write failure must not authorize reads of prefs' changed RAM map.
    for (throws in listOf(false, true)) {
        val failed = Fixture("legacy-ciphertext")
        failed.storage.failCommit = !throws
        failed.storage.throwCommit = throws
        rejects("PROFILE_STORE_UNAVAILABLE") { failed.store().metadata() }
        check(failed.storage.disk.legacy == "legacy-ciphertext" && failed.storage.disk.catalog == null)
        check(failed.storage.memory.catalog != null && failed.storage.memory.legacy == null)
        val otherActivity = failed.store()
        val readCount = failed.storage.reads
        rejects("PROFILE_STORE_UNAVAILABLE") { otherActivity.metadata() }
        rejects("PROFILE_STORE_UNAVAILABLE") { otherActivity.exists() }
        rejects("PROFILE_STORE_UNAVAILABLE") { otherActivity.load() }
        rejects("PROFILE_STORE_UNAVAILABLE") { otherActivity.validateActive(id(1), SECRET) }
        rejects("PROFILE_STORE_UNAVAILABLE") { otherActivity.save("replacement") }
        rejects("PROFILE_STORE_UNAVAILABLE") { otherActivity.select(id(1)) }
        rejects("PROFILE_STORE_UNAVAILABLE") { otherActivity.delete() }
        check(failed.storage.reads == readCount && failed.storage.writes == 1)
        // Restart reloads authoritative disk, and a successful retry preserves data.
        failed.storage.restart()
        failed.storage.failCommit = false
        failed.storage.throwCommit = false
        check(failed.store(ProfileCatalogState()).load() == SECRET)
    }

    // A failed edit, not only migration, preserves the previous disk catalog.
    val editFailure = Fixture()
    val editStore = editFailure.store()
    editStore.save(SECRET, name = "Первый")
    val durable = editFailure.storage.disk.catalog
    editFailure.storage.failCommit = true
    rejects("PROFILE_STORE_UNAVAILABLE") { editStore.save("replacement") }
    check(editFailure.storage.disk.catalog == durable)
    editFailure.storage.restart()
    check(editFailure.store(ProfileCatalogState()).load() == SECRET)

    // Encryption (including serialization/size rejection) happens before any storage write.
    val encryptedFailure = Fixture("legacy-ciphertext")
    encryptedFailure.cipher.failEncryption = true
    rejectsAny { encryptedFailure.store().metadata() }
    check(encryptedFailure.storage.writes == 0 && encryptedFailure.storage.disk.legacy == "legacy-ciphertext")
    encryptedFailure.cipher.failEncryption = false
    check(encryptedFailure.store().load() == SECRET)
    val durableAfterMigration = encryptedFailure.storage.disk.catalog
    val durableWrites = encryptedFailure.storage.writes
    encryptedFailure.cipher.failEncryption = true
    rejectsAny { encryptedFailure.store().save("unwritable-large-record") }
    check(encryptedFailure.storage.writes == durableWrites)
    check(encryptedFailure.storage.disk.catalog == durableAfterMigration)
    check(encryptedFailure.store().load() == SECRET)

    // Corrupt catalogs fail closed; legacy data is not silently used as a fallback.
    val corrupt = Fixture("legacy-ciphertext")
    corrupt.storage.memory = EncryptedProfileRecords("corrupt-catalog", "legacy-ciphertext")
    rejectsAny { corrupt.store().metadata() }
    rejectsAny { corrupt.store().save("replacement") }
    check(corrupt.storage.writes == 0 && corrupt.cipher.legacyReads == 0)
    val one = StoredWireGuardProfile(id(1), "Один", SECRET)
    for (catalog in listOf(
        ProfileCatalog(listOf(one), null), ProfileCatalog(emptyList(), id(1)),
        ProfileCatalog(listOf(one), id(2)), ProfileCatalog(listOf(one, one), id(1)),
        ProfileCatalog(listOf(StoredWireGuardProfile("bad-id", "Один", SECRET)), "bad-id"),
        ProfileCatalog(listOf(StoredWireGuardProfile(id(1), "  Имя  ", SECRET)), id(1)),
    )) rejectsAny { ProfileCatalogStore.validate(catalog) }

    // Unicode names use code points, preserve non-Latin labels, and reject unsafe controls.
    check(ProfileCatalogStore.normalizedName("  Дом 🐈  ") == "Дом 🐈")
    check(ProfileCatalogStore.normalizedName("🐈".repeat(64)).codePointCount(0, 128) == 64)
    for (name in listOf("", "   ", "🐈".repeat(65), "a\u0000b", "a\u007fb", "a\u0085b", "a\u2028b", "a\u2029b", "a\ud800b")) {
        rejects("PROFILE_NAME_INVALID") { ProfileCatalogStore.normalizedName(name) }
    }
    rejects("INVALID_CONFIG") { ProfileCatalogStore.validateConfig(" ") }
    rejects("INVALID_CONFIG") { ProfileCatalogStore.validateConfig("x".repeat(65537)) }
    ProfileCatalogStore.validateConfig("x".repeat(65536))

    // The 21st profile fails without affecting the 20 saved profiles or active choice.
    val full = Fixture()
    val fullStore = full.store()
    repeat(20) { fullStore.save("config-$it", name = "Профиль $it", createNew = true) }
    rejects("PROFILE_LIMIT_REACHED") { fullStore.save("21st", name = "Лишний", createNew = true) }
    check(full.storage.writes == 20 && fullStore.load() == "config-0")
    fullStore.save("renamed-at-limit", profileId = id(20), name = "Новый")
    check(fullStore.load(id(20)) == "renamed-at-limit" && fullStore.load() == "config-0")

    // The native operation lease spans pending approval and cannot be released by stale cleanup.
    val gate = ProfileOperationGate()
    val permission = gate.acquire()!!
    check(gate.get() && gate.acquire() == null)
    gate.release(permission)
    val mutation = gate.acquire()!!
    gate.release(permission)
    check(gate.get() && gate.acquire() == null)
    gate.release(mutation)
    check(!gate.get())
    val pool = Executors.newFixedThreadPool(8)
    val start = CountDownLatch(1)
    val done = CountDownLatch(24)
    val winners = AtomicInteger()
    repeat(24) {
        pool.execute {
            start.await()
            if (gate.acquire() != null) winners.incrementAndGet()
            done.countDown()
        }
    }
    start.countDown()
    done.await()
    pool.shutdown()
    check(winners.get() == 1 && gate.get())
    println("ProfileCatalog and process-wide operation checks passed")
}
