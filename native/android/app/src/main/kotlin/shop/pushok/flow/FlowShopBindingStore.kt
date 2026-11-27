package shop.pushok.flow

import android.content.Context
import java.security.MessageDigest
import java.util.Locale

/** Local ownership guard for the one Shop-managed WireGuard subscription.

No ticket, bearer URL or private configuration is written to shared preferences.
A durable owner binding is committed BEFORE the encrypted profile import, so
a lost response cannot leave a personal key usable by a different login.
*/
internal class FlowShopBindingStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("flow_shop_binding", Context.MODE_PRIVATE)

    internal class Binding(val accountId: String, val urlHash: String) {
        override fun toString() = "FlowShopBindingStore.Binding(redacted)"
    }

    companion object {
        private val lock = Any()
        @Volatile private var writeFailed = false
        private val sha = Regex("[a-f0-9]{64}")

        fun fingerprint(url: String): String = MessageDigest.getInstance("SHA-256")
            .digest(url.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun readLocked(): Binding? {
        if (writeFailed) throw FlowShopFailure("SHOP_STORAGE_ERROR")
        val owner: String?
        val digest: String?
        try {
            owner = prefs.getString("owner", null)
            digest = prefs.getString("url_hash", null)
        } catch (_: Exception) { throw FlowShopFailure("SHOP_STORAGE_ERROR") }
        if (owner == null && digest == null) return null
        if (owner == null || digest == null || !ProfileCatalogStore.validId(owner) ||
            !sha.matches(digest)) throw FlowShopFailure("SHOP_STORAGE_ERROR")
        return Binding(owner, digest)
    }

    fun binding(): Binding? = synchronized(lock) { readLocked() }

    fun requireOwner(accountId: String) = synchronized(lock) {
        if (!ProfileCatalogStore.validId(accountId)) throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
        if (readLocked()?.accountId?.equals(accountId, ignoreCase = true) == false) {
            throw FlowShopFailure("SHOP_ACCOUNT_CHANGED")
        }
    }

    fun bind(accountId: String, url: String) = synchronized(lock) {
        requireOwner(accountId)
        val normalized = SubscriptionPolicy.normalizeUrl(url)
        val digest = fingerprint(normalized)
        val prior = readLocked()
        if (prior != null) {
            if (prior.urlHash != digest) throw FlowShopFailure("SHOP_LINK_CHANGED")
            return@synchronized
        }
        val committed = try {
            prefs.edit().putString("owner", accountId.lowercase(Locale.ROOT))
                .putString("url_hash", digest).commit()
        } catch (_: Exception) { false }
        if (!committed) {
            writeFailed = true
            throw FlowShopFailure("SHOP_STORAGE_ERROR")
        }
    }

    /** Delete only the exact subscription previously bound to this phone. */
    fun unlink(store: SecureWireGuardStore) = synchronized(lock) {
        val binding = readLocked() ?: return@synchronized
        val linked = store.subscriptionRecords().firstOrNull {
            fingerprint(it.url) == binding.urlHash
        }
        if (linked != null) store.deleteSubscription(linked.id)
        val removed = try { prefs.edit().remove("owner").remove("url_hash").commit() }
            catch (_: Exception) { false }
        if (!removed) {
            writeFailed = true
            throw FlowShopFailure("SHOP_STORAGE_ERROR")
        }
    }

    /** Only Shop-bound profiles require the previously verified device owner.
     * Manual profiles and all unrelated subscriptions are not affected.
     */
    fun requireConnectionAllowed(config: String, profileId: String?,
        store: SecureWireGuardStore, account: FlowAccountCoordinator) {
        val bound = binding() ?: return
        val linked = store.subscriptionRecords().firstOrNull {
            fingerprint(it.url) == bound.urlHash
        } ?: return
        val metadata = store.metadata()["profiles"] as? List<*>
            ?: throw FlowShopFailure("SHOP_STORAGE_ERROR")
        for (raw in metadata) {
            val profile = raw as? Map<*, *> ?: throw FlowShopFailure("SHOP_STORAGE_ERROR")
            val id = profile["id"] as? String ?: throw FlowShopFailure("SHOP_STORAGE_ERROR")
            if (profile["subscriptionId"] == linked.id && (profileId == null || profileId == id) &&
                store.load(id) == config) {
                if (!bound.accountId.equals(account.connectionOwner(), ignoreCase = true)) {
                    throw FlowShopFailure("SHOP_LOGIN_REQUIRED")
                }
            }
        }
    }
}
