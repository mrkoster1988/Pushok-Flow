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
    check(json.getInt("version") == 3)
    check(json.getJSONArray("subscriptions").getJSONObject(0).getInt("skippedProfileCount") == 2)

    // An existing v2 record without this optional field remains readable with the same AAD/key.
    json.put("version", 2)
    json.getJSONArray("profiles").getJSONObject(0).remove("providerId")
    for (field in listOf("format", "state", "revision")) {
        json.getJSONArray("subscriptions").getJSONObject(0).remove(field)
    }
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
    check(decryptCatalog(context).getInt("version") == 3)
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

private fun managedCatalogRoundTripAndStrictV3() {
    val context = Context()
    val store = SecureWireGuardStore(context)
    val privateKey = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    val config = "[Interface]\nPrivateKey = $privateKey\nAddress = 10.77.0.2/32\n" +
        "[Peer]\nPublicKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=\n" +
        "Endpoint = 203.0.113.10:51820\nAllowedIPs = 0.0.0.0/0\n"
    val feed = SubscriptionFeed.Parsed(listOf(SubscriptionFeed.Entry("Устройство", config, "device-entry")),
        null, 4_102_444_800_000, null, null, format = "wireguard-v1", state = "active", revision = 1)
    val url = "https://example.com/managed-private-token"
    val id = store.importSubscription("WireGuard", url, feed, 1)
    val selected = store.metadata()["activeProfileId"]
    check(SecureWireGuardStore(context.recreated()).load() == config)
    val json = decryptCatalog(context)
    check(json.getInt("version") == 3)
    val stored = json.getJSONArray("subscriptions").getJSONObject(0)
    check(stored.getString("format") == "wireguard-v1" && stored.getString("state") == "active")
    check(stored.getLong("revision") == 1L)
    check(json.getJSONArray("profiles").getJSONObject(0).getString("providerId") == "device-entry")
    val public = singleMetadata(store).toString() + store.metadata().toString()
    for (secret in listOf(privateKey, "managed-private-token", "device-entry", "[Interface]")) {
        check(!public.contains(secret))
        check(!preferences(context).getString(CATALOG_FIELD, null)!!.contains(secret))
    }
    val original = json.toString()
    val corruptions = listOf<(JSONObject) -> Unit>(
        { it.getJSONArray("subscriptions").getJSONObject(0).remove("format") },
        { it.getJSONArray("subscriptions").getJSONObject(0).remove("state") },
        { it.getJSONArray("subscriptions").getJSONObject(0).remove("revision") },
        { it.getJSONArray("profiles").getJSONObject(0).remove("providerId") },
        { it.getJSONArray("profiles").getJSONObject(0).put("providerId", JSONObject.NULL) },
        { it.getJSONArray("subscriptions").getJSONObject(0).put("format", "vless") },
        { it.getJSONArray("subscriptions").getJSONObject(0).put("state", "revoked") },
        { it.getJSONArray("subscriptions").getJSONObject(0).put("state", "unknown") },
        { it.getJSONArray("subscriptions").getJSONObject(0).put("revision", 0) },
        { it.getJSONArray("subscriptions").getJSONObject(0).put("revision", "1") },
        { it.getJSONArray("subscriptions").getJSONObject(0).put("revision", 1.5) },
        { it.getJSONArray("subscriptions").getJSONObject(0).put("expiresAt", JSONObject.NULL) },
        { it.getJSONArray("subscriptions").getJSONObject(0).put("expiresAt", 4_102_444_800_001) },
    )
    for (corrupt in corruptions) {
        val changed = JSONObject(original)
        corrupt(changed)
        replaceCatalog(context, changed)
        val encrypted = preferences(context).getString(CATALOG_FIELD, null)
        expectCorruptCatalog { SecureWireGuardStore(context.recreated()).subscriptions() }
        check(preferences(context).getString(CATALOG_FIELD, null) == encrypted)
    }
    replaceCatalog(context, JSONObject(original))
    check(store.metadata()["activeProfileId"] == selected && store.load() == config)
    val revoked = SubscriptionFeed.Parsed(emptyList(), null, 4_102_444_800_000, null, null,
        format = "wireguard-v1", state = "revoked", revision = 2)
    store.refreshSubscription(id, url, revoked, 2)
    val restarted = SecureWireGuardStore(context.recreated())
    check(restarted.load() == null && !restarted.exists())
    check(restarted.subscriptionRecords().single().revision == 2L)
    check(singleMetadata(restarted)["state"] == "revoked" && singleMetadata(restarted)["profileCount"] == 0)
    check(decryptCatalog(context).getJSONArray("profiles").length() == 0)
}

fun main() {
    check(Security.getProvider("AndroidKeyStore") == null)
    Security.addProvider(SubscriptionStoreFixtureProvider())
    try {
        encryptedRoundTripAndBackwardCompatibility()
        corruptCountsCannotSilentlyBecomeZero()
        managedCatalogRoundTripAndStrictV3()
        check(SubscriptionStoreFixtureKey.reads > 0)
        println("Actual profile store: encrypted managed state round trip, v1/v2/v3 compatibility, tombstones and corrupt-record rejection checks passed")
    } finally { Security.removeProvider("AndroidKeyStore") }
}
