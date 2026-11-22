package shop.pushok.flow

import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.NotFoundException
import com.google.zxing.Result
import com.google.zxing.common.BitMatrix
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/** Offline QR-only decoding. Protocol-specific validation still checks the returned draft. */
object ProfileQrDecoder {
    const val MAX_IMAGE_BYTES = 16 * 1024 * 1024
    const val MAX_SOURCE_PIXELS = 48_000_000L
    const val MAX_SOURCE_SIDE = 16_384
    const val MAX_DECODE_SIDE = 2_048

    private class ImageBuffer : ByteArrayOutputStream() {
        fun erase() { buf.fill(0); reset() }
    }

    /** One owned, erasable luminance plane; the caller's ARGB pixels are not modified. */
    private class ImageLuminance(width: Int, height: Int, private val data: ByteArray) :
        LuminanceSource(width, height) {
        override fun getMatrix(): ByteArray = data

        override fun getRow(y: Int, row: ByteArray?): ByteArray {
            require(y in 0 until height)
            val output = row?.takeIf { it.size >= width } ?: ByteArray(width)
            data.copyInto(output, 0, y * width, (y + 1) * width)
            return output
        }
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
        val luminance = ByteArray(pixels.size)
        try {
            var darkest = 255
            var lightest = 0
            for (row in 0 until height) {
                active(cancelled)
                for (index in row * width until (row + 1) * width) {
                    val color = pixels[index]
                    val alpha = color ushr 24
                    val gray = ((color ushr 16 and 255) +
                        (color ushr 8 and 255) * 2 + (color and 255)) / 4
                    // Transparent PNG backgrounds commonly have zero RGB channels.
                    // Composite onto white; invisible RGB must not turn into a hidden QR.
                    val visible = (gray * alpha + 255 * (255 - alpha) + 127) / 255
                    luminance[index] = visible.toByte()
                    darkest = minOf(darkest, visible)
                    lightest = maxOf(lightest, visible)
                }
            }
            // A visible translucent symbol may be grey on white. Preserve the ordering
            // of its visible luminance while giving the binarizer the full contrast range.
            // A fully transparent/flat image stays flat; hidden RGB never contributes.
            if (lightest > darkest && (darkest != 0 || lightest != 255)) {
                val range = lightest - darkest
                for (row in 0 until height) {
                    active(cancelled)
                    for (index in row * width until (row + 1) * width) {
                        val value = luminance[index].toInt() and 255
                        luminance[index] = ((value - darkest) * 255 / range).toByte()
                    }
                }
            }
            var count = 0
            var text: String? = null
            repeat(2) { pass ->
                active(cancelled)
                val bitmap = BinaryBitmap(HybridBinarizer(ImageLuminance(width, height, luminance)))
                var matrix: BitMatrix? = null
                val values = try {
                    matrix = bitmap.blackMatrix
                    QRCodeMultiReader().decodeMultiple(bitmap, mapOf(
                        DecodeHintType.TRY_HARDER to true,
                        DecodeHintType.CHARACTER_SET to "UTF-8",
                    ))
                } catch (_: NotFoundException) { emptyArray<Result>() }
                finally { matrix?.clear() }
                try {
                    active(cancelled)
                    // ZXing combines Structured Append symbols into a result with no
                    // finder points. This importer accepts one physical QR, not a merged
                    // group (or an incomplete group); PURE_BARCODE is never enabled.
                    if (values.any { (it.resultPoints?.size ?: 0) < 3 }) fail("PROFILE_QR_MULTIPLE")
                    count += values.size
                    // Check both polarities even after a successful first pass. Otherwise
                    // a normal QR beside an inverted QR would silently select the former.
                    // Do not deduplicate by payload: two equal QRs are still ambiguous.
                    if (count > 1) fail("PROFILE_QR_MULTIPLE")
                    if (values.size == 1) text = values.single().text
                } finally {
                    values.forEach { it.rawBytes?.fill(0) }
                }
                if (pass == 0) {
                    for (row in 0 until height) {
                        active(cancelled)
                        for (index in row * width until (row + 1) * width) {
                            luminance[index] = (255 - (luminance[index].toInt() and 255)).toByte()
                        }
                    }
                }
            }
            active(cancelled)
            if (count == 0) fail("PROFILE_QR_NOT_FOUND")
            // Only the unambiguous result reaches protocol parsing or the editor draft.
            return normalizePayload(text, cancelled)
        } finally {
            luminance.fill(0)
        }
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
        // A VLESS link is local configuration, never a URL to fetch. JSON, subscription
        // URLs and base64 wrappers are rejected. WG options (including AWG) remain intact
        // for authoritative Config.parse validation before the draft crosses the channel.
        try { ConnectionProfile.validateShape(text) }
        catch (error: ProfileFormatFailure) { fail(error.code) }
        active(cancelled)
        return text
    }

    private fun active(cancelled: () -> Boolean) {
        if (cancelled()) fail("PROFILE_IMPORT_INTERRUPTED")
    }

    private fun fail(code: String): Nothing = throw ProfileImportReader.Failure(code)
}
