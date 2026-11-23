package android.security.keystore

import java.security.spec.AlgorithmParameterSpec

object KeyProperties {
    const val KEY_ALGORITHM_AES = "AES"
    const val PURPOSE_ENCRYPT = 1
    const val PURPOSE_DECRYPT = 2
    const val BLOCK_MODE_GCM = "GCM"
    const val ENCRYPTION_PADDING_NONE = "NoPadding"
}

class KeyGenParameterSpec(val alias: String, val purposes: Int, val blockModes: List<String>,
    val paddings: List<String>, val keySize: Int,
    val randomizedEncryptionRequired: Boolean = true) : AlgorithmParameterSpec {
    class Builder(private val alias: String, private val purposes: Int) {
        private var blockModes = emptyList<String>()
        private var paddings = emptyList<String>()
        private var keySize = 0
        private var randomizedEncryptionRequired = true
        fun setBlockModes(vararg modes: String) = apply { blockModes = modes.toList() }
        fun setEncryptionPaddings(vararg values: String) = apply { paddings = values.toList() }
        fun setKeySize(size: Int) = apply { keySize = size }
        fun setRandomizedEncryptionRequired(value: Boolean) = apply { randomizedEncryptionRequired = value }
        fun build() = KeyGenParameterSpec(alias, purposes, blockModes, paddings, keySize, randomizedEncryptionRequired)
    }
}
