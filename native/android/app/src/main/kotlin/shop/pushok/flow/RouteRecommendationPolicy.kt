package shop.pushok.flow

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.RSAPublicKey
import java.util.Collections

/** Errors never contain downloaded text, package lists or platform exceptions. */
class RouteRecommendationFailure(val code: String) : Exception(code)

class VerifiedRouteRecommendations internal constructor(
    val rulesVersion: Int,
    packages: List<String>,
    payload: ByteArray,
    envelope: ByteArray,
) {
    val packages: List<String> = Collections.unmodifiableList(packages.sorted())
    private val payloadBytes = payload.copyOf()
    private val envelopeBytes = envelope.copyOf()
    fun samePayload(other: VerifiedRouteRecommendations) = payloadBytes.contentEquals(other.payloadBytes)
    fun envelope(): ByteArray = envelopeBytes.copyOf()
}

/** No executable content or route mutations: this policy accepts package-name suggestions only. */
object RouteRecommendationPolicy {
    const val URL = "https://raw.githubusercontent.com/mrkoster1988/Pushok-Flow/main/updates/route-recommendations.json"
    const val DOMAIN = "Pushok Flow route recommendations v1\n"
    const val MAX_ENVELOPE_BYTES = 131072
    const val MAX_PAYLOAD_BYTES = 65536
    const val MAX_PACKAGES = 256
    private val envelopeFields = setOf("schema_version", "payload", "signature")
    private val payloadFields = setOf("schema_version", "rules_version", "recommended_bypass_packages")
    private const val BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    fun empty() = VerifiedRouteRecommendations(0, emptyList(), byteArrayOf(), byteArrayOf())

    fun verify(envelope: ByteArray, publicKey: PublicKey): VerifiedRouteRecommendations {
        try {
            if (envelope.isEmpty() || envelope.size > MAX_ENVELOPE_BYTES) invalid()
            val fields = JsonObjectReader(utf8(envelope), envelopeFields).read()
            if (fields["schema_version"] != 1L) invalid()
            val payload = decodeBase64(fields["payload"] as? String ?: invalid(), MAX_PAYLOAD_BYTES)
            val signature = decodeBase64(fields["signature"] as? String ?: invalid(), 1024)
            if (payload.isEmpty() || signature.size !in 256..1024) invalid()
            val rsa = publicKey as? RSAPublicKey ?: invalid()
            if (rsa.modulus.bitLength() !in 2048..8192) invalid()
            val verifier = Signature.getInstance("SHA256withRSA")
            verifier.initVerify(rsa)
            verifier.update(DOMAIN.toByteArray(StandardCharsets.UTF_8))
            verifier.update(payload)
            if (!verifier.verify(signature)) invalid()
            val document = JsonObjectReader(utf8(payload), payloadFields).read()
            if (document["schema_version"] != 1L) invalid()
            val version = document["rules_version"] as? Long ?: invalid()
            if (version !in 1..Int.MAX_VALUE.toLong()) invalid()
            val values = document["recommended_bypass_packages"] as? List<*> ?: invalid()
            if (values.size > MAX_PACKAGES) invalid()
            val packages = linkedSetOf<String>()
            for (value in values) {
                if (!RouteSettingsStore.isValidPackageName(value) || !packages.add(value as String)) invalid()
            }
            return VerifiedRouteRecommendations(version.toInt(), packages.toList(), payload, envelope)
        } catch (failure: RouteRecommendationFailure) {
            throw failure
        } catch (_: Exception) {
            invalid()
        }
    }

    fun requireFresh(current: VerifiedRouteRecommendations, offered: VerifiedRouteRecommendations) {
        if (offered.rulesVersion < current.rulesVersion ||
            (offered.rulesVersion == current.rulesVersion && !offered.samePayload(current))) {
            throw RouteRecommendationFailure("RECOMMENDATIONS_STALE")
        }
    }

    private fun utf8(bytes: ByteArray): String = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()

    /** Strict, canonical standard Base64, including unused padding bits; works before Android 26. */
    private fun decodeBase64(text: String, limit: Int): ByteArray {
        if (text.isEmpty() || text.length % 4 != 0 || text.length > ((limit + 2) / 3) * 4) invalid()
        val padding = if (text.endsWith("==")) 2 else if (text.endsWith("=")) 1 else 0
        val size = text.length / 4 * 3 - padding
        if (size > limit) invalid()
        val last = text.length - padding
        for (index in 0 until last) if (BASE64.indexOf(text[index]) < 0) invalid()
        for (index in last until text.length) if (text[index] != '=') invalid()
        if (padding == 2 && (BASE64.indexOf(text[last - 1]) and 15) != 0) invalid()
        if (padding == 1 && (BASE64.indexOf(text[last - 1]) and 3) != 0) invalid()
        val bytes = ByteArray(size)
        var output = 0
        for (offset in text.indices step 4) {
            val a = BASE64.indexOf(text[offset])
            val b = BASE64.indexOf(text[offset + 1])
            val c = if (text[offset + 2] == '=') 0 else BASE64.indexOf(text[offset + 2])
            val d = if (text[offset + 3] == '=') 0 else BASE64.indexOf(text[offset + 3])
            val bits = (a shl 18) or (b shl 12) or (c shl 6) or d
            if (output < size) bytes[output++] = (bits shr 16).toByte()
            if (output < size) bytes[output++] = (bits shr 8).toByte()
            if (output < size) bytes[output++] = bits.toByte()
        }
        return bytes
    }

    private fun invalid(): Nothing = throw RouteRecommendationFailure("RECOMMENDATIONS_INVALID")

    /** A bounded JSON subset, with duplicate keys and non-integer numeric values rejected. */
    private class JsonObjectReader(private val text: String, private val fields: Set<String>) {
        private var index = 0

        fun read(): Map<String, Any> {
            space()
            expect('{')
            val values = linkedMapOf<String, Any>()
            space()
            if (peek() != '}') while (true) {
                val key = string()
                if (key !in fields || values.containsKey(key)) invalid()
                space()
                expect(':')
                space()
                values[key] = when (peek()) {
                    '"' -> string()
                    '[' -> strings()
                    else -> integer()
                }
                space()
                if (peek() != ',') break
                index++
                space()
            }
            expect('}')
            space()
            if (index != text.length || values.keys != fields) invalid()
            return values
        }

        private fun strings(): List<String> {
            expect('[')
            space()
            val values = mutableListOf<String>()
            if (peek() != ']') while (true) {
                if (values.size >= MAX_PACKAGES) invalid()
                values.add(string())
                space()
                if (peek() != ',') break
                index++
                space()
            }
            expect(']')
            return values
        }

        private fun string(): String {
            expect('"')
            val result = StringBuilder()
            while (index < text.length) {
                val value = text[index++]
                if (value == '"') return result.toString()
                if (value.code < 32) invalid()
                if (value != '\\') {
                    result.append(value)
                    continue
                }
                if (index == text.length) invalid()
                result.append(when (val escaped = text[index++]) {
                    '"', '\\', '/' -> escaped
                    'b' -> '\b'
                    'f' -> '\u000C'
                    'n' -> '\n'
                    'r' -> '\r'
                    't' -> '\t'
                    'u' -> {
                        if (index + 4 > text.length) invalid()
                        var code = 0
                        repeat(4) {
                            val hex = text[index++]
                            if (hex !in '0'..'9' && hex !in 'a'..'f' && hex !in 'A'..'F') invalid()
                            code = (code shl 4) or (hex.digitToIntOrNull(16) ?: invalid())
                        }
                        code.toChar()
                    }
                    else -> invalid()
                })
            }
            invalid()
        }

        private fun integer(): Long {
            val start = index
            if (peek() == '-') index++
            when (peek()) {
                '0' -> index++
                in '1'..'9' -> while (peek() in '0'..'9') index++
                else -> invalid()
            }
            return text.substring(start, index).toLongOrNull() ?: invalid()
        }

        private fun space() { while (peek() == ' ' || peek() == '\n' || peek() == '\r' || peek() == '\t') index++ }
        private fun peek(): Char = text.getOrNull(index) ?: '\u0000'
        private fun expect(value: Char) { if (peek() != value) invalid(); index++ }
    }
}
