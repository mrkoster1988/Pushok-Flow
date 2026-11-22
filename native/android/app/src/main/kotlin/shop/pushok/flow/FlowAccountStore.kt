package shop.pushok.flow

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal object FlowAccountJson {
    fun encode(value: Map<String, Any?>): ByteArray = JSONObject(value).toString().toByteArray(StandardCharsets.UTF_8)
    fun parse(bytes: ByteArray): Map<String, Any?> {
        if (bytes.isEmpty() || bytes.size > FlowAccountPolicy.MAX_JSON_BYTES) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
        try {
            val text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            val reader = JSONTokener(text)
            val value = reader.nextValue() as? JSONObject ?: throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
            if (reader.nextClean() != '\u0000') throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
            return FlowAccountPolicy.map(convert(value, 0))
        } catch (failure: FlowAccountFailure) { throw failure }
        catch (_: Exception) { throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED") }
    }
    private fun convert(value: Any?, depth: Int): Any? {
        if (depth > 5) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> {
                if (value.length() > 32) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
                value.keys().asSequence().associateWith { convert(value.get(it), depth + 1) }
            }
            is JSONArray -> {
                if (value.length() > 32) throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
                (0 until value.length()).map { convert(value.get(it), depth + 1) }
            }
            else -> value
        }
    }
}

/** Independent of VPN/subscription storage. The stable alias survives normal signed APK updates. */
internal class FlowAccountStore(context: Context) : FlowAccountPersistence {
    private val preferences = context.applicationContext.getSharedPreferences("pushok_flow_account_v1", Context.MODE_PRIVATE)
    private var poisoned = false
    companion object {
        private const val ALIAS = "pushok_flow_account_v1"
        private val AAD = "shop.pushok.flow/account-record/v1".toByteArray(StandardCharsets.UTF_8)
    }
    override fun load(): FlowAccountRecord {
        if (poisoned) unavailable()
        try {
            val encoded = preferences.getString("record", null) ?: return FlowAccountRecord()
            if (encoded.length > 64 * 1024 || !Regex("[A-Za-z0-9+/]+={0,2}").matches(encoded)) unavailable()
            val encrypted = Base64.decode(encoded, Base64.NO_WRAP)
            if (encrypted.size < 30 || encrypted[0] != 1.toByte()) unavailable()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            // Never generate a replacement key to 'recover' an existing ciphertext.
            cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, encrypted.copyOfRange(1, 13)))
            cipher.updateAAD(AAD)
            val plain = cipher.doFinal(encrypted.copyOfRange(13, encrypted.size))
            return try { FlowAccountPolicy.restore(FlowAccountJson.parse(plain)) }
            finally { plain.fill(0) }
        } catch (_: Exception) {
            // A missing/invalidated key cannot reveal an old account. Explicit next login can create
            // a fresh record; unrelated encrypted VPN profiles and their keys are never touched.
            if (!preferences.edit().remove("record").commit()) poisoned = true
            unavailable()
        }
    }
    override fun save(value: FlowAccountRecord) {
        if (poisoned) unavailable()
        try {
            if (value.pending == null && value.session == null) {
                if (!preferences.edit().remove("record").commit()) { poisoned = true; unavailable() }
                return
            }
            val plain = FlowAccountJson.encode(FlowAccountPolicy.record(value))
            val encrypted = try {
                if (plain.size > FlowAccountPolicy.MAX_JSON_BYTES) unavailable()
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, key(true))
                cipher.updateAAD(AAD)
                if (cipher.iv.size != 12) unavailable()
                byteArrayOf(1) + cipher.iv + cipher.doFinal(plain)
            } finally { plain.fill(0) }
            if (!preferences.edit().putString("record", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit()) {
                poisoned = true
                unavailable()
            }
        } catch (failure: FlowAccountFailure) { throw failure }
        catch (_: Exception) { unavailable() }
    }
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(ALIAS, null)
        if (existing != null) return existing as? SecretKey ?: unavailable()
        if (!create || store.containsAlias(ALIAS)) unavailable()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    private fun unavailable(): Nothing = throw FlowAccountFailure("FLOW_STORE_UNAVAILABLE")
}
