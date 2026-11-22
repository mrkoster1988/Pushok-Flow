package shop.pushok.flow

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

/** Names, active choice and configurations are all encrypted by Android Keystore. */
class SecureWireGuardStore(context: Context) {
    companion object {
        private val state = ProfileCatalogState()
        private const val ALIAS = "pushok_flow_wireguard_v1"
        private const val MAX_ENCODED_LENGTH = 8_000_000
        private val CATALOG_AAD = "pushok_flow_profile_catalog_v2".toByteArray(StandardCharsets.UTF_8)
    }
    private val prefs = context.getSharedPreferences("flow_encrypted_profile", Context.MODE_PRIVATE)

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        // Never replace a missing key while trying to recover existing data.
        check(create) { "PROFILE_LOAD_FAILED" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build())
            generateKey()
        }
    }

    private fun decryptText(encoded: String, catalog: Boolean): String {
        require(encoded.length <= MAX_ENCODED_LENGTH) { "PROFILE_LOAD_FAILED" }
        val data = Base64.decode(encoded, Base64.NO_WRAP)
        require(data.size > 12 + 16) { "PROFILE_LOAD_FAILED" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        if (catalog) cipher.updateAAD(CATALOG_AAD)
        val plaintext = cipher.doFinal(data.copyOfRange(12, data.size))
        return try {
            StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(plaintext)).toString()
        } finally { plaintext.fill(0) }
    }

    private val catalogStore = ProfileCatalogStore(object : ProfileCatalogStorage {
        override fun read() = EncryptedProfileRecords(prefs.getString("encrypted_catalog_v2", null),
            prefs.getString("encrypted_config", null))

        override fun replaceCatalog(encrypted: String): Boolean = prefs.edit()
            .putString("encrypted_catalog_v2", encrypted).remove("encrypted_config").commit()
    }, object : ProfileCatalogCipher {
        override fun encrypt(catalog: ProfileCatalog): String {
            val profiles = JSONArray()
            catalog.profiles.forEach { profiles.put(JSONObject().put("id", it.id)
                .put("name", it.name).put("config", it.config)
                .put("subscriptionId", it.subscriptionId ?: JSONObject.NULL)) }
            val subscriptions = JSONArray()
            catalog.subscriptions.forEach { subscriptions.put(JSONObject().put("id", it.id)
                .put("name", it.name).put("url", it.url).put("updatedAt", it.updatedAt)
                .put("expiresAt", it.expiresAt ?: JSONObject.NULL)
                .put("usedBytes", it.usedBytes ?: JSONObject.NULL)
                .put("totalBytes", it.totalBytes ?: JSONObject.NULL)) }
            val json = JSONObject().put("version", 2).put("profiles", profiles).put("subscriptions", subscriptions)
                .put("activeProfileId", catalog.activeProfileId ?: JSONObject.NULL)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
            cipher.updateAAD(CATALOG_AAD)
            val plaintext = json.toString().toByteArray(StandardCharsets.UTF_8)
            val ciphertext = try { cipher.doFinal(plaintext) } finally { plaintext.fill(0) }
            val encoded = Base64.encodeToString(cipher.iv + ciphertext, Base64.NO_WRAP)
            // Never commit a value that this same reader would reject later.
            require(encoded.length <= MAX_ENCODED_LENGTH) { "PROFILE_SAVE_FAILED" }
            return encoded
        }

        override fun decrypt(encrypted: String): ProfileCatalog {
            val json = JSONObject(decryptText(encrypted, catalog = true))
            val version = json.opt("version")
            require(version in listOf(1, 2) && json.has("activeProfileId")) { "PROFILE_LOAD_FAILED" }
            val values = json.opt("profiles") as? JSONArray ?: error("PROFILE_LOAD_FAILED")
            require(values.length() <= ProfileCatalogStore.MAX_PROFILES) { "PROFILE_LOAD_FAILED" }
            val profiles = (0 until values.length()).map { index ->
                val item = values.opt(index) as? JSONObject ?: error("PROFILE_LOAD_FAILED")
                StoredWireGuardProfile(item.opt("id") as? String ?: error("PROFILE_LOAD_FAILED"),
                    item.opt("name") as? String ?: error("PROFILE_LOAD_FAILED"),
                    item.opt("config") as? String ?: error("PROFILE_LOAD_FAILED"),
                    if (version == 2) nullableString(item, "subscriptionId") else null)
            }
            val active = json.opt("activeProfileId")
            require(active == JSONObject.NULL || active is String) { "PROFILE_LOAD_FAILED" }
            val subscriptions = if (version == 1) emptyList() else {
                val items = json.opt("subscriptions") as? JSONArray ?: error("PROFILE_LOAD_FAILED")
                require(items.length() <= SubscriptionPolicy.MAX_SUBSCRIPTIONS) { "PROFILE_LOAD_FAILED" }
                (0 until items.length()).map { index ->
                    val item = items.opt(index) as? JSONObject ?: error("PROFILE_LOAD_FAILED")
                    StoredSubscription(item.opt("id") as? String ?: error("PROFILE_LOAD_FAILED"),
                        item.opt("name") as? String ?: error("PROFILE_LOAD_FAILED"),
                        item.opt("url") as? String ?: error("PROFILE_LOAD_FAILED"),
                        nullableLong(item, "updatedAt") ?: error("PROFILE_LOAD_FAILED"),
                        nullableLong(item, "expiresAt"), nullableLong(item, "usedBytes"), nullableLong(item, "totalBytes"))
                }
            }
            return ProfileCatalog(profiles, active as? String, subscriptions)
        }

        override fun decryptLegacy(encrypted: String) = decryptText(encrypted, catalog = false)
    }, state)

    private fun nullableString(item: JSONObject, field: String): String? = when (val value = item.opt(field)) {
        JSONObject.NULL -> null
        is String -> value
        else -> error("PROFILE_LOAD_FAILED")
    }

    private fun nullableLong(item: JSONObject, field: String): Long? = when (val value = item.opt(field)) {
        JSONObject.NULL -> null
        is Long -> value
        is Int -> value.toLong()
        else -> error("PROFILE_LOAD_FAILED")
    }

    fun metadata(): Map<String, Any?> = catalogStore.metadata()
    fun save(config: String, profileId: String? = null, name: String? = null, createNew: Boolean = false) =
        catalogStore.save(config, profileId, name, createNew)
    fun load(profileId: String? = null): String? = catalogStore.load(profileId)
    fun validateActive(profileId: String, config: String) = catalogStore.validateActive(profileId, config)
    fun delete(profileId: String? = null) = catalogStore.delete(profileId)
    fun select(profileId: String) = catalogStore.select(profileId)
    fun exists(): Boolean = catalogStore.exists()
    fun subscriptions(): Map<String, Any?> = catalogStore.subscriptions()
    fun subscriptionRecords(): List<StoredSubscription> = catalogStore.subscriptionRecords()
    fun importSubscription(name: String, url: String, feed: SubscriptionFeed.Parsed, now: Long): String =
        catalogStore.importSubscription(name, url, feed, now)
    fun refreshSubscription(id: String, expectedUrl: String, feed: SubscriptionFeed.Parsed, now: Long) =
        catalogStore.refreshSubscription(id, expectedUrl, feed, now)
    fun deleteSubscription(id: String) = catalogStore.deleteSubscription(id)
}
