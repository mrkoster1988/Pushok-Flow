package shop.pushok.flow

import android.content.Context
import java.io.InputStream
import java.io.OutputStream
import java.security.Key
import java.security.KeyStoreSpi
import java.security.Provider
import java.security.Security
import java.security.cert.Certificate
import java.util.Base64
import java.util.Collections
import java.util.Date
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

private const val PROFILE_ALIAS = "pushok_flow_wireguard_v1"
private const val CATALOG_FIELD = "encrypted_catalog_v2"
private val catalogAad = "pushok_flow_profile_catalog_v2".toByteArray(Charsets.UTF_8)
private const val LINK = "vless://00000000-0000-4000-8000-000000000001@example.invalid:443?security=tls&type=tcp"

/** Synthetic provider only. Encryption/decryption use the JVM's real AES-GCM Cipher. */
object SubscriptionStoreFixtureKey {
    val value = SecretKeySpec(ByteArray(32) { (it + 1).toByte() }, "AES")
    var reads = 0
}

class SubscriptionStoreFixtureKeyStore : KeyStoreSpi() {
    override fun engineGetKey(alias: String, password: CharArray?): Key {
        check(alias == PROFILE_ALIAS)
        SubscriptionStoreFixtureKey.reads++
        return SubscriptionStoreFixtureKey.value
    }
    override fun engineDeleteEntry(alias: String) = error("Migration must not delete the profile key")
    override fun engineGetCertificateChain(alias: String): Array<Certificate>? = null
    override fun engineGetCertificate(alias: String): Certificate? = null
    override fun engineGetCreationDate(alias: String): Date? = Date(0)
    override fun engineSetKeyEntry(alias: String, key: Key, password: CharArray?, chain: Array<Certificate>?) = error("Not used")
    override fun engineSetKeyEntry(alias: String, key: ByteArray, chain: Array<Certificate>?) = error("Not used")
    override fun engineSetCertificateEntry(alias: String, certificate: Certificate) = error("Not used")
    override fun engineAliases() = Collections.enumeration(listOf(PROFILE_ALIAS))
    override fun engineContainsAlias(alias: String) = alias == PROFILE_ALIAS
    override fun engineSize() = 1
    override fun engineIsKeyEntry(alias: String) = engineContainsAlias(alias)
    override fun engineIsCertificateEntry(alias: String) = false
    override fun engineGetCertificateAlias(cert: Certificate): String? = null
    override fun engineStore(stream: OutputStream?, password: CharArray?) = Unit
    override fun engineLoad(stream: InputStream?, password: CharArray?) = Unit
}

class SubscriptionStoreFixtureProvider : Provider("AndroidKeyStore", "1.0", "Synthetic profile store only") {
    init { put("KeyStore.AndroidKeyStore", SubscriptionStoreFixtureKeyStore::class.java.name) }
}

private fun preferences(context: Context) = context.getSharedPreferences("flow_encrypted_profile", Context.MODE_PRIVATE)

private fun decryptCatalog(context: Context): JSONObject {
    val data = Base64.getDecoder().decode(preferences(context).getString(CATALOG_FIELD, null)!!)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, SubscriptionStoreFixtureKey.value, GCMParameterSpec(128, data.copyOfRange(0, 12)))
    cipher.updateAAD(catalogAad)
    val plain = cipher.doFinal(data.copyOfRange(12, data.size))
    return try { JSONObject(plain.toString(Charsets.UTF_8)) }
        finally { data.fill(0); plain.fill(0) }
}

private fun replaceCatalog(context: Context, json: JSONObject) {
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, SubscriptionStoreFixtureKey.value)
    cipher.updateAAD(catalogAad)
    val plain = json.toString().toByteArray(Charsets.UTF_8)
    val encrypted = try { cipher.doFinal(plain) } finally { plain.fill(0) }
    try {
        check(cipher.iv.size == 12)
        check(preferences(context).edit().putString(CATALOG_FIELD,
            Base64.getEncoder().encodeToString(cipher.iv + encrypted)).commit())
    } finally { encrypted.fill(0) }
}

private fun singleMetadata(store: SecureWireGuardStore) =
    (store.subscriptions()["subscriptions"] as List<*>).single() as Map<*, *>

private fun expectCorruptCatalog(action: () -> Unit) {
    var rejected = false
    try { action() }
    catch (failure: Exception) {
        rejected = true
        check(failure.message == "PROFILE_LOAD_FAILED")
    }
    check(rejected) { "An invalid stored skipped count was accepted" }
}

private fun encryptedRoundTripAndBackwardCompatibility() {
    val context = Context()
    val store = SecureWireGuardStore(context)
    val mixed = SubscriptionFeed.parse(("vmess://synthetic\n$LINK\ntrojan://synthetic").toByteArray())
    val id = store.importSubscription("Mixed", "https://example.com/sub/synthetic", mixed, 1)
    val selected = store.metadata()["activeProfileId"]
    val encrypted = preferences(context).getString(CATALOG_FIELD, null)!!
    check(!encrypted.contains("vless://") && !encrypted.contains("synthetic"))
    check(singleMetadata(store)["skippedProfileCount"] == 2)
    val recreated = SecureWireGuardStore(context.recreated())
    check(recreated.subscriptionRecords().single().skippedProfileCount == 2)
    check(recreated.metadata()["activeProfileId"] == selected && recreated.load() == LINK)
    val json = decryptCatalog(context)
    check(json.getInt("version") == 2)
    check(json.getJSONArray("subscriptions").getJSONObject(0).getInt("skippedProfileCount") == 2)

    // An existing v2 record without this optional field remains readable with the same AAD/key.
    json.getJSONArray("subscriptions").getJSONObject(0).remove("skippedProfileCount")
    replaceCatalog(context, json)
    val oldCiphertext = preferences(context).getString(CATALOG_FIELD, null)
    val old = SecureWireGuardStore(context)
    check(old.subscriptionRecords().single().skippedProfileCount == 0)
    check(singleMetadata(old)["skippedProfileCount"] == 0 && old.load() == LINK)
    check(preferences(context).getString(CATALOG_FIELD, null) == oldCiphertext)
    old.refreshSubscription(id, "https://example.com/sub/synthetic", mixed, 2)
    check(SecureWireGuardStore(context.recreated()).subscriptionRecords().single().skippedProfileCount == 2)
    old.refreshSubscription(id, "https://example.com/sub/synthetic", SubscriptionFeed.parse(LINK.toByteArray()), 3)
    check(SecureWireGuardStore(context.recreated()).subscriptionRecords().single().skippedProfileCount == 0)
    check(singleMetadata(old)["skippedProfileCount"] == 0 && old.metadata()["activeProfileId"] == selected)

    // The pre-subscription v1 schema still migrates manual profiles without re-keying.
    val v1 = decryptCatalog(context)
    v1.put("version", 1).remove("subscriptions")
    v1.getJSONArray("profiles").getJSONObject(0).remove("subscriptionId")
    replaceCatalog(context, v1)
    val manual = SecureWireGuardStore(context)
    check(manual.subscriptionRecords().isEmpty() && manual.load() == LINK)
    check(manual.metadata()["activeProfileId"] == selected)
    manual.save(LINK, name = "Manual")
    check(decryptCatalog(context).getInt("version") == 2)
    check(SecureWireGuardStore(context.recreated()).load() == LINK)
}

private fun corruptCountsCannotSilentlyBecomeZero() {
    val context = Context()
    val store = SecureWireGuardStore(context)
    store.importSubscription("One", "https://example.com/sub/synthetic", SubscriptionFeed.parse(LINK.toByteArray()), 1)
    val original = decryptCatalog(context).toString()
    for (count in listOf<Any>(JSONObject.NULL, "0", true, -1, 0.5,
        SubscriptionPolicy.MAX_FEED_ENTRIES, SubscriptionPolicy.MAX_FEED_ENTRIES + 1, Long.MAX_VALUE)) {
        val altered = JSONObject(original)
        altered.getJSONArray("subscriptions").getJSONObject(0).put("skippedProfileCount", count)
        replaceCatalog(context, altered)
        val before = preferences(context).getString(CATALOG_FIELD, null)
        expectCorruptCatalog { SecureWireGuardStore(context).subscriptions() }
        check(preferences(context).getString(CATALOG_FIELD, null) == before)
    }
    replaceCatalog(context, JSONObject(original))
    check(SecureWireGuardStore(context.recreated()).subscriptionRecords().single().skippedProfileCount == 0)
}

fun main() {
    check(Security.getProvider("AndroidKeyStore") == null)
    Security.addProvider(SubscriptionStoreFixtureProvider())
    try {
        encryptedRoundTripAndBackwardCompatibility()
        corruptCountsCannotSilentlyBecomeZero()
        check(SubscriptionStoreFixtureKey.reads > 0)
        println("Actual profile store: encrypted skipped-count round trip, v1/v2 compatibility, reset and corrupt-count rejection checks passed")
    } finally { Security.removeProvider("AndroidKeyStore") }
}
