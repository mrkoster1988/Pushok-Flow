package shop.pushok.flow

import java.util.UUID

/** No generated toString(): an accidental exception/log must never print a key. */
class StoredWireGuardProfile(val id: String, val name: String, val config: String,
    val subscriptionId: String? = null)

class StoredSubscription(val id: String, val name: String, val url: String,
    val updatedAt: Long, val expiresAt: Long? = null,
    val usedBytes: Long? = null, val totalBytes: Long? = null) {
    override fun toString() = "StoredSubscription(<redacted>)"
}

class ProfileCatalog(val profiles: List<StoredWireGuardProfile>, val activeProfileId: String?,
    val subscriptions: List<StoredSubscription> = emptyList())

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
                catalog.subscriptions.size > SubscriptionPolicy.MAX_SUBSCRIPTIONS ||
                catalog.subscriptions.map { it.id }.toSet().size != catalog.subscriptions.size ||
                catalog.subscriptions.map { it.url }.toSet().size != catalog.subscriptions.size ||
                (catalog.profiles.isEmpty() != (catalog.activeProfileId == null)) ||
                (catalog.activeProfileId != null && catalog.profiles.none { it.id == catalog.activeProfileId })) {
                throw ProfileCatalogFailure("PROFILE_LOAD_FAILED")
            }
            catalog.profiles.forEach {
                if (!validId(it.id) || normalizedName(it.name) != it.name) {
                    throw ProfileCatalogFailure("PROFILE_LOAD_FAILED")
                }
                validateConfig(it.config)
                if (it.subscriptionId != null && catalog.subscriptions.none { sub -> sub.id == it.subscriptionId }) {
                    throw ProfileCatalogFailure("PROFILE_LOAD_FAILED")
                }
            }
            catalog.subscriptions.forEach { sub ->
                if (!validId(sub.id) || normalizedName(sub.name) != sub.name ||
                    sub.updatedAt !in 0..SubscriptionPolicy.MAX_TIMESTAMP_MS ||
                    sub.expiresAt?.let { it !in 0..SubscriptionPolicy.MAX_TIMESTAMP_MS } == true || sub.usedBytes?.let { it < 0 } == true ||
                    sub.totalBytes?.let { it <= 0 } == true ||
                    catalog.profiles.none { it.subscriptionId == sub.id }) {
                    throw ProfileCatalogFailure("PROFILE_LOAD_FAILED")
                }
                try {
                    if (SubscriptionPolicy.normalizeUrl(sub.url) != sub.url) throw IllegalArgumentException()
                } catch (_: Exception) { throw ProfileCatalogFailure("PROFILE_LOAD_FAILED") }
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
        mapOf("profiles" to catalog.profiles.map {
            val value = linkedMapOf<String, Any?>("id" to it.id, "name" to it.name)
            if (it.subscriptionId != null) {
                value["subscriptionId"] = it.subscriptionId
                value["subscriptionName"] = catalog.subscriptions.first { sub -> sub.id == it.subscriptionId }.name
            }
            value
        },
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
            if (profiles[index].subscriptionId != null) throw ProfileCatalogFailure("PROFILE_MANAGED")
            profiles[index] = StoredWireGuardProfile(targetId, suppliedName ?: profiles[index].name, config)
            persist(ProfileCatalog(profiles, catalog.activeProfileId, catalog.subscriptions))
        } else {
            if (profiles.size >= MAX_PROFILES) throw ProfileCatalogFailure("PROFILE_LIMIT_REACHED")
            val id = newId()
            profiles.add(StoredWireGuardProfile(id, suppliedName ?: "Мой профиль", config))
            persist(ProfileCatalog(profiles, catalog.activeProfileId ?: id, catalog.subscriptions))
        }
    }

    fun select(profileId: String) = synchronized(state.lock) {
        val catalog = readCatalog()
        if (catalog.profiles.none { it.id == profileId }) throw ProfileCatalogFailure("PROFILE_NOT_FOUND")
        if (catalog.activeProfileId != profileId) persist(ProfileCatalog(catalog.profiles, profileId, catalog.subscriptions))
    }

    fun delete(profileId: String? = null) = synchronized(state.lock) {
        val catalog = readCatalog()
        val id = profileId ?: catalog.activeProfileId ?: return@synchronized
        if (catalog.profiles.none { it.id == id }) throw ProfileCatalogFailure("PROFILE_NOT_FOUND")
        if (catalog.profiles.first { it.id == id }.subscriptionId != null) throw ProfileCatalogFailure("PROFILE_MANAGED")
        val remaining = catalog.profiles.filterNot { it.id == id }
        val active = if (catalog.activeProfileId == id) remaining.firstOrNull()?.id else catalog.activeProfileId
        // Persist an empty catalog after deleting the final profile. Never fall
        // back to a legacy configuration that might survive an old backup.
        persist(ProfileCatalog(remaining, active, catalog.subscriptions))
    }

    /** Public metadata contains neither personal subscription URLs nor connection credentials. */
    fun subscriptions(): Map<String, Any?> = synchronized(state.lock) {
        val catalog = readCatalog()
        mapOf("subscriptions" to catalog.subscriptions.map { sub ->
            mapOf("id" to sub.id, "name" to sub.name, "host" to SubscriptionPolicy.host(sub.url),
                "profileCount" to catalog.profiles.count { it.subscriptionId == sub.id },
                "updatedAt" to sub.updatedAt, "expiresAt" to sub.expiresAt,
                "usedBytes" to sub.usedBytes, "totalBytes" to sub.totalBytes)
        })
    }

    /** Native-only secrets. Never return this collection over a method channel or log it. */
    fun subscriptionRecords(): List<StoredSubscription> = synchronized(state.lock) {
        readCatalog().subscriptions.toList()
    }

    fun importSubscription(name: String, url: String, feed: SubscriptionFeed.Parsed, now: Long): String =
        synchronized(state.lock) {
            val normalizedUrl = SubscriptionPolicy.normalizeUrl(url)
            val normalizedName = normalizedName(name)
            val catalog = readCatalog()
            if (catalog.subscriptions.any { it.url == normalizedUrl }) throw SubscriptionFailure("SUBSCRIPTION_EXISTS")
            if (catalog.subscriptions.size >= SubscriptionPolicy.MAX_SUBSCRIPTIONS) {
                throw SubscriptionFailure("SUBSCRIPTION_LIMIT_REACHED")
            }
            validateFeed(feed, now)
            if (catalog.profiles.size + feed.entries.size > MAX_PROFILES) {
                throw ProfileCatalogFailure("PROFILE_LIMIT_REACHED")
            }
            val id = newId()
            val entries = feed.entries.map { StoredWireGuardProfile(newId(), it.name, it.config, id) }
            val sub = StoredSubscription(id, normalizedName, normalizedUrl, now,
                feed.expiresAt, feed.usedBytes, feed.totalBytes)
            persist(ProfileCatalog(catalog.profiles + entries, catalog.activeProfileId ?: entries.first().id,
                catalog.subscriptions + sub))
            id
        }

    /** Commit a fully parsed response once; failures never replace the last working server list. */
    fun refreshSubscription(id: String, expectedUrl: String, feed: SubscriptionFeed.Parsed, now: Long) =
        synchronized(state.lock) {
            val catalog = readCatalog()
            val sub = catalog.subscriptions.firstOrNull { it.id == id }
                ?: throw SubscriptionFailure("SUBSCRIPTION_NOT_FOUND")
            if (sub.url != expectedUrl) throw SubscriptionFailure("SUBSCRIPTION_CHANGED")
            validateFeed(feed, now)
            val existing = catalog.profiles.filter { it.subscriptionId == id }
            if (catalog.profiles.size - existing.size + feed.entries.size > MAX_PROFILES) {
                throw ProfileCatalogFailure("PROFILE_LIMIT_REACHED")
            }
            val previousIds = existing.associateBy { SubscriptionFeed.identity(it.config) }
            val replacements = feed.entries.map { entry ->
                val profileId = previousIds[SubscriptionFeed.identity(entry.config)]?.id ?: newId()
                StoredWireGuardProfile(profileId, entry.name, entry.config, id)
            }
            val insertion = catalog.profiles.indexOfFirst { it.subscriptionId == id }
            val profiles = catalog.profiles.filter { it.subscriptionId != id }.toMutableList()
            profiles.addAll(insertion.coerceIn(0, profiles.size), replacements)
            val active = catalog.activeProfileId?.takeIf { activeId -> profiles.any { it.id == activeId } }
                ?: replacements.first().id
            val refreshed = StoredSubscription(id, sub.name, sub.url, now,
                feed.expiresAt, feed.usedBytes, feed.totalBytes)
            persist(ProfileCatalog(profiles, active, catalog.subscriptions.map { if (it.id == id) refreshed else it }))
        }

    fun deleteSubscription(id: String) = synchronized(state.lock) {
        val catalog = readCatalog()
        if (catalog.subscriptions.none { it.id == id }) throw SubscriptionFailure("SUBSCRIPTION_NOT_FOUND")
        val profiles = catalog.profiles.filter { it.subscriptionId != id }
        val active = catalog.activeProfileId?.takeIf { selected -> profiles.any { it.id == selected } }
            ?: profiles.firstOrNull()?.id
        persist(ProfileCatalog(profiles, active, catalog.subscriptions.filter { it.id != id }))
    }

    private fun validateFeed(feed: SubscriptionFeed.Parsed, now: Long) {
        if (now !in 0..SubscriptionPolicy.MAX_TIMESTAMP_MS) throw SubscriptionFailure("SUBSCRIPTION_INVALID")
        if (feed.entries.isEmpty()) throw SubscriptionFailure("SUBSCRIPTION_EMPTY")
        if (feed.entries.size > MAX_PROFILES) throw SubscriptionFailure("SUBSCRIPTION_TOO_LARGE")
        if (feed.entries.map { SubscriptionFeed.identity(it.config) }.toSet().size != feed.entries.size) {
            throw SubscriptionFailure("SUBSCRIPTION_INVALID")
        }
        feed.entries.forEach {
            normalizedName(it.name)
            try { VlessProfile.parse(it.config) }
            catch (_: ProfileFormatFailure) { throw SubscriptionFailure("SUBSCRIPTION_INVALID") }
        }
    }
}
