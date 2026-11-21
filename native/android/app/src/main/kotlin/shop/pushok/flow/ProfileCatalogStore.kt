package shop.pushok.flow

import java.util.UUID

/** No generated toString(): an accidental exception/log must never print a key. */
class StoredWireGuardProfile(val id: String, val name: String, val config: String)

class ProfileCatalog(val profiles: List<StoredWireGuardProfile>, val activeProfileId: String?)

class EncryptedProfileRecords(val catalog: String?, val legacy: String?)

interface ProfileCatalogStorage {
    fun read(): EncryptedProfileRecords
    /** Replace the catalog and remove the legacy record in one durable transaction. */
    fun replaceCatalog(encrypted: String): Boolean
}

interface ProfileCatalogCipher {
    fun encrypt(catalog: ProfileCatalog): String
    fun decrypt(encrypted: String): ProfileCatalog
    fun decryptLegacy(encrypted: String): String
}

/** Shared between Activity/store instances. A failed prefs commit can alter its RAM map. */
class ProfileCatalogState {
    val lock = Any()
    internal var writeFailed = false
}

class ProfileCatalogFailure(val code: String) : Exception(code)

/** Platform-independent transitions; callers never receive configurations from metadata(). */
class ProfileCatalogStore(
    private val storage: ProfileCatalogStorage,
    private val cipher: ProfileCatalogCipher,
    private val state: ProfileCatalogState,
    private val newId: () -> String = { UUID.randomUUID().toString() },
) {
    companion object {
        const val MAX_PROFILES = 20
        const val MAX_NAME_CODEPOINTS = 64
        const val MAX_CONFIG_LENGTH = 65536
        private val idPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

        fun validId(value: String) = idPattern.matches(value)

        fun normalizedName(value: String): String {
            val name = value.trim()
            if (name.isEmpty() || name.codePointCount(0, name.length) > MAX_NAME_CODEPOINTS ||
                name.codePoints().anyMatch { Character.isISOControl(it) ||
                    it == 0x2028 || it == 0x2029 || it in 0xD800..0xDFFF }) {
                throw ProfileCatalogFailure("PROFILE_NAME_INVALID")
            }
            return name
        }

        fun validateConfig(config: String) {
            if (config.isBlank() || config.length > MAX_CONFIG_LENGTH) {
                throw ProfileCatalogFailure("INVALID_CONFIG")
            }
        }

        fun validate(catalog: ProfileCatalog) {
            if (catalog.profiles.size > MAX_PROFILES ||
                catalog.profiles.map { it.id }.toSet().size != catalog.profiles.size ||
                (catalog.profiles.isEmpty() != (catalog.activeProfileId == null)) ||
                (catalog.activeProfileId != null && catalog.profiles.none { it.id == catalog.activeProfileId })) {
                throw ProfileCatalogFailure("PROFILE_LOAD_FAILED")
            }
            catalog.profiles.forEach {
                if (!validId(it.id) || normalizedName(it.name) != it.name) {
                    throw ProfileCatalogFailure("PROFILE_LOAD_FAILED")
                }
                validateConfig(it.config)
            }
        }
    }

    private fun checkUsable() {
        if (state.writeFailed) throw ProfileCatalogFailure("PROFILE_STORE_UNAVAILABLE")
    }

    private fun persist(catalog: ProfileCatalog) {
        checkUsable()
        validate(catalog)
        // Encryption failure has not modified storage and is safe to retry.
        val encrypted = cipher.encrypt(catalog)
        val committed = try {
            storage.replaceCatalog(encrypted)
        } catch (_: Exception) {
            state.writeFailed = true
            throw ProfileCatalogFailure("PROFILE_STORE_UNAVAILABLE")
        }
        if (!committed) {
            // SharedPreferences updates its in-memory values before reporting a
            // disk error. Refuse ALL later reads/writes until process restart;
            // the previous or new atomic disk record remains authoritative.
            state.writeFailed = true
            throw ProfileCatalogFailure("PROFILE_STORE_UNAVAILABLE")
        }
    }

    private fun readCatalog(): ProfileCatalog {
        checkUsable()
        val records = storage.read()
        if (records.catalog != null) {
            // A corrupt new catalog must never resurrect a stale legacy record.
            return cipher.decrypt(records.catalog).also { validate(it) }
        }
        if (records.legacy != null) {
            val config = cipher.decryptLegacy(records.legacy)
            validateConfig(config)
            val id = newId()
            val catalog = ProfileCatalog(listOf(StoredWireGuardProfile(id, "Мой профиль", config)), id)
            persist(catalog)
            return catalog
        }
        return ProfileCatalog(emptyList(), null)
    }

    fun metadata(): Map<String, Any?> = synchronized(state.lock) {
        val catalog = readCatalog()
        mapOf("profiles" to catalog.profiles.map { mapOf("id" to it.id, "name" to it.name) },
            "activeProfileId" to catalog.activeProfileId)
    }

    fun exists(): Boolean = synchronized(state.lock) { readCatalog().profiles.isNotEmpty() }

    fun load(profileId: String? = null): String? = synchronized(state.lock) {
        val catalog = readCatalog()
        val id = profileId ?: catalog.activeProfileId ?: return@synchronized null
        catalog.profiles.firstOrNull { it.id == id }?.config
            ?: throw ProfileCatalogFailure("PROFILE_NOT_FOUND")
    }

    /** Called while the global tunnel-operation token is held, before changing the backend. */
    fun validateActive(profileId: String, config: String) = synchronized(state.lock) {
        val catalog = readCatalog()
        val active = catalog.profiles.firstOrNull { it.id == catalog.activeProfileId }
        if (active == null || active.id != profileId || active.config != config) {
            throw ProfileCatalogFailure("PROFILE_CHANGED")
        }
    }

    fun save(config: String, profileId: String? = null, name: String? = null,
             createNew: Boolean = false) = synchronized(state.lock) {
        checkUsable()
        validateConfig(config)
        val suppliedName = name?.let { normalizedName(it) }
        if (createNew && profileId != null) throw ProfileCatalogFailure("PROFILE_NOT_FOUND")
        val catalog = readCatalog()
        val targetId = if (createNew) null else profileId ?: catalog.activeProfileId
        val profiles = catalog.profiles.toMutableList()
        if (targetId != null) {
            val index = profiles.indexOfFirst { it.id == targetId }
            if (index == -1) throw ProfileCatalogFailure("PROFILE_NOT_FOUND")
            profiles[index] = StoredWireGuardProfile(targetId, suppliedName ?: profiles[index].name, config)
            persist(ProfileCatalog(profiles, catalog.activeProfileId))
        } else {
            if (profiles.size >= MAX_PROFILES) throw ProfileCatalogFailure("PROFILE_LIMIT_REACHED")
            val id = newId()
            profiles.add(StoredWireGuardProfile(id, suppliedName ?: "Мой профиль", config))
            persist(ProfileCatalog(profiles, catalog.activeProfileId ?: id))
        }
    }

    fun select(profileId: String) = synchronized(state.lock) {
        val catalog = readCatalog()
        if (catalog.profiles.none { it.id == profileId }) throw ProfileCatalogFailure("PROFILE_NOT_FOUND")
        if (catalog.activeProfileId != profileId) persist(ProfileCatalog(catalog.profiles, profileId))
    }

    fun delete(profileId: String? = null) = synchronized(state.lock) {
        val catalog = readCatalog()
        val id = profileId ?: catalog.activeProfileId ?: return@synchronized
        if (catalog.profiles.none { it.id == id }) throw ProfileCatalogFailure("PROFILE_NOT_FOUND")
        val remaining = catalog.profiles.filterNot { it.id == id }
        val active = if (catalog.activeProfileId == id) remaining.firstOrNull()?.id else catalog.activeProfileId
        // Persist an empty catalog after deleting the final profile. Never fall
        // back to a legacy configuration that might survive an old backup.
        persist(ProfileCatalog(remaining, active))
    }
}
