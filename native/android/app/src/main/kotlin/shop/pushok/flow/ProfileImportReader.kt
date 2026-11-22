package shop.pushok.flow

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/** Only bounded text decoding. The chosen protocol's grammar is validated afterwards. */
object ProfileImportReader {
    const val MAX_BYTES = 65536

    class Failure(val code: String) : Exception()

    fun read(input: InputStream, cancelled: () -> Boolean = { false }): String {
        // The extra byte detects an oversized stream even when its reported size is absent
        // or false. Never trust document metadata or read an unbounded provider stream.
        val bytes = ByteArray(MAX_BYTES + 1)
        var count = 0
        try {
            while (count <= MAX_BYTES) {
                checkCancelled(cancelled)
                val amount = input.read(bytes, count, minOf(4096, bytes.size - count))
                if (amount < 0) break
                if (amount == 0) {
                    // Some provider streams return zero for a nonempty request. Make progress
                    // without spinning; the Android owner separately bounds read duration.
                    val next = input.read()
                    if (next < 0) break
                    bytes[count++] = next.toByte()
                } else {
                    count += amount
                }
                if (count > MAX_BYTES) throw Failure("PROFILE_IMPORT_TOO_LARGE")
            }
            checkCancelled(cancelled)
            if (count == 0) throw Failure("PROFILE_IMPORT_INVALID")
            val decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            val decoded = try {
                decoder.decode(ByteBuffer.wrap(bytes, 0, count)).toString()
            } catch (_: CharacterCodingException) {
                throw Failure("PROFILE_IMPORT_INVALID")
            }
            val config = decoded.removePrefix("\uFEFF")
            if (config.isBlank() || config.any {
                    (it.code < 32 && it != '\t' && it != '\n' && it != '\r') || it.code == 127
                }) {
                throw Failure("PROFILE_IMPORT_INVALID")
            }
            checkCancelled(cancelled)
            return config
        } finally {
            bytes.fill(0)
        }
    }

    private fun checkCancelled(cancelled: () -> Boolean) {
        if (cancelled()) throw Failure("PROFILE_IMPORT_INTERRUPTED")
    }
}
