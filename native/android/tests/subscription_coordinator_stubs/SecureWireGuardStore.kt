package shop.pushok.flow

/** Android encryption/storage boundary only; all catalog transitions use production code. */
class SecureWireGuardStore {
    private var storedCiphertext: String? = null
    var writes = 0
        private set
    var failWrites = false
    var refreshFailure: Exception? = null
    private var sequence = 0
    private val storage = object : ProfileCatalogStorage {
        override fun read() = EncryptedProfileRecords(storedCiphertext, null)
        override fun replaceCatalog(encrypted: String): Boolean {
            writes++
            if (failWrites) return false
            storedCiphertext = encrypted
            return true
        }
    }
    private val cipher = object : ProfileCatalogCipher {
        private val values = mutableMapOf<String, ProfileCatalog>()
        override fun encrypt(catalog: ProfileCatalog): String {
            val token = "test-cipher-${values.size}"
            values[token] = catalog
            return token
        }
        override fun decrypt(encrypted: String): ProfileCatalog = values.getValue(encrypted)
        override fun decryptLegacy(encrypted: String): String = error("Unexpected legacy load")
    }
    val catalogStore = ProfileCatalogStore(storage, cipher, ProfileCatalogState()) {
        "10000000-0000-4000-8000-${(++sequence).toString().padStart(12, '0')}"
    }
    fun subscriptionRecords() = catalogStore.subscriptionRecords()
    fun subscriptions() = catalogStore.subscriptions()
    fun importSubscription(name: String, url: String, feed: SubscriptionFeed.Parsed, now: Long) =
        catalogStore.importSubscription(name, url, feed, now)
    fun refreshSubscription(id: String, url: String, feed: SubscriptionFeed.Parsed, now: Long) {
        refreshFailure?.let { throw it }
        catalogStore.refreshSubscription(id, url, feed, now)
    }
    fun deleteSubscription(id: String) = catalogStore.deleteSubscription(id)

    /** Simulate an independently replaced encrypted catalog while a fetch is in flight. */
    fun replaceUrlForTest(id: String, url: String) {
        val current = cipher.decrypt(storedCiphertext!!)
        val records = current.subscriptions.map {
            if (it.id != id) it else StoredSubscription(it.id, it.name, url, it.updatedAt,
                it.expiresAt, it.usedBytes, it.totalBytes, it.skippedProfileCount)
        }
        check(storage.replaceCatalog(cipher.encrypt(ProfileCatalog(current.profiles, current.activeProfileId, records))))
    }
}
