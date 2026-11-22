package shop.pushok.flow

import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.NotFoundException
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/** Offline QR-only decoding. WireGuard's SDK still validates the complete returned draft. */
object ProfileQrDecoder {
    const val MAX_IMAGE_BYTES = 16 * 1024 * 1024
    const val MAX_SOURCE_PIXELS = 48_000_000L
    const val MAX_SOURCE_SIDE = 16_384
    const val MAX_DECODE_SIDE = 2_048

    private class ImageBuffer : ByteArrayOutputStream() {
        fun erase() { buf.fill(0); reset() }
    }

    fun readImageBytes(input: InputStream, cancelled: () -> Boolean = { false }): ByteArray {
        val output = ImageBuffer()
        val buffer = ByteArray(8192)
        try {
            while (true) {
                active(cancelled)
                val count = input.read(buffer, 0, minOf(buffer.size, MAX_IMAGE_BYTES - output.size() + 1))
                if (count < 0) break
                if (count == 0) {
                    val next = input.read()
                    if (next < 0) break
                    if (output.size() == MAX_IMAGE_BYTES) fail("PROFILE_QR_IMAGE_TOO_LARGE")
                    output.write(next)
                } else {
                    if (count > MAX_IMAGE_BYTES - output.size()) fail("PROFILE_QR_IMAGE_TOO_LARGE")
                    output.write(buffer, 0, count)
                }
            }
            active(cancelled)
            if (output.size() == 0) fail("PROFILE_QR_NOT_FOUND")
            return output.toByteArray()
        } finally {
            buffer.fill(0)
            output.erase()
        }
    }

    /** Power-of-two sampling keeps the decoded bitmap and pixel array bounded. */
    fun sampleSize(width: Int, height: Int): Int {
        if (width <= 0 || height <= 0) fail("PROFILE_QR_NOT_FOUND")
        if (width > MAX_SOURCE_SIDE || height > MAX_SOURCE_SIDE ||
            width.toLong() * height > MAX_SOURCE_PIXELS) fail("PROFILE_QR_IMAGE_TOO_LARGE")
        var sample = 1
        while ((width + sample - 1) / sample > MAX_DECODE_SIDE ||
            (height + sample - 1) / sample > MAX_DECODE_SIDE) sample *= 2
        return sample
    }

    fun decodePixels(width: Int, height: Int, pixels: IntArray,
        cancelled: () -> Boolean = { false }): String {
        active(cancelled)
        if (width <= 0 || height <= 0 || width > MAX_DECODE_SIDE || height > MAX_DECODE_SIDE ||
            pixels.size.toLong() != width.toLong() * height) fail("PROFILE_QR_IMAGE_TOO_LARGE")
        val bitmap = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(width, height, pixels)))
        val values = try {
            QRCodeMultiReader().decodeMultiple(bitmap, mapOf(
                DecodeHintType.TRY_HARDER to true,
                DecodeHintType.CHARACTER_SET to "UTF-8",
            ))
        } catch (_: NotFoundException) { fail("PROFILE_QR_NOT_FOUND") }
        active(cancelled)
        if (values.isEmpty()) fail("PROFILE_QR_NOT_FOUND")
        if (values.size != 1) fail("PROFILE_QR_MULTIPLE")
        return normalizePayload(values.single().text, cancelled)
    }

    fun normalizePayload(value: String?, cancelled: () -> Boolean = { false }): String {
        active(cancelled)
        if (value == null || value.length > ProfileImportReader.MAX_BYTES) {
            fail(if (value == null) "PROFILE_IMPORT_INVALID" else "PROFILE_IMPORT_TOO_LARGE")
        }
        val encoded = try {
            StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value))
        } catch (_: Exception) { fail("PROFILE_IMPORT_INVALID") }
        if (encoded.remaining() > ProfileImportReader.MAX_BYTES) fail("PROFILE_IMPORT_TOO_LARGE")
        val bytes = ByteArray(encoded.remaining())
        encoded.get(bytes)
        val text = try { ProfileImportReader.read(ByteArrayInputStream(bytes), cancelled) }
            finally { bytes.fill(0); if (encoded.hasArray()) encoded.array().fill(0) }
        // Do not interpret links, JSON or base64 wrappers as remote configuration sources.
        // This is only an early shape check; unknown options (including AWG) reach Config.parse.
        if (!Regex("(?m)^\\s*\\[Interface]\\s*(?:#.*)?$").containsMatchIn(text) ||
            !Regex("(?m)^\\s*\\[Peer]\\s*(?:#.*)?$").containsMatchIn(text)) {
            fail("PROFILE_IMPORT_INVALID")
        }
        active(cancelled)
        return text
    }

    private fun active(cancelled: () -> Boolean) {
        if (cancelled()) fail("PROFILE_IMPORT_INTERRUPTED")
    }

    private fun fail(code: String): Nothing = throw ProfileImportReader.Failure(code)
}
