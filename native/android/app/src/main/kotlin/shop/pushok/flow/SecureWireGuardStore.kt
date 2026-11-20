package shop.pushok.flow

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Android Keystore-protected local WireGuard profile; never logs secrets. */
class SecureWireGuardStore(private val context: Context) {
    private val alias = "pushok_flow_wireguard_v1"
    private val prefs = context.getSharedPreferences("flow_encrypted_profile", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build())
            generateKey()
        }
    }

    fun save(config: String) {
        require(config.isNotBlank() && config.length <= 65536) { "Некорректный размер конфигурации" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ciphertext = cipher.doFinal(config.toByteArray(StandardCharsets.UTF_8))
        val data = Base64.encodeToString(cipher.iv + ciphertext, Base64.NO_WRAP)
        check(prefs.edit().putString("encrypted_config", data).commit()) { "Не удалось сохранить профиль" }
    }

    fun load(): String? {
        val encoded = prefs.getString("encrypted_config", null) ?: return null
        val data = Base64.decode(encoded, Base64.NO_WRAP)
        require(data.size > 12 + 16) { "Повреждён зашифрованный профиль" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        return String(cipher.doFinal(data.copyOfRange(12, data.size)), StandardCharsets.UTF_8)
    }

    fun delete() {
        check(prefs.edit().remove("encrypted_config").commit()) { "Не удалось удалить профиль" }
    }

    fun exists(): Boolean = prefs.contains("encrypted_config")
}