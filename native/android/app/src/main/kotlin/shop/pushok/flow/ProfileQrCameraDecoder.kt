package shop.pushok.flow

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.NotFoundException
import com.google.zxing.Reader
import com.google.zxing.Result
import com.google.zxing.ResultMetadataType
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import com.journeyapps.barcodescanner.DecoderFactory
import com.journeyapps.barcodescanner.MixedDecoder
import java.util.EnumMap

/** Shared by the live camera and executable QR regressions; contains no camera or profile state. */
object ProfileQrCameraDecoder {
    private const val MAX_FRAME_SIDE = 4096
    private const val MAX_FRAME_PIXELS = 4_194_304L

    fun createFactory(): DecoderFactory = DecoderFactory { baseHints ->
        // Retain JourneyApps' result-point callback while enforcing the same
        // QR-only UTF-8 policy for both ordinary and contrast-restored frames.
        val hints = EnumMap<DecodeHintType, Any>(DecodeHintType::class.java)
        baseHints.forEach { (key, value) -> if (value != null) hints[key] = value }
        hints[DecodeHintType.POSSIBLE_FORMATS] = listOf(BarcodeFormat.QR_CODE)
        hints[DecodeHintType.TRY_HARDER] = true
        hints[DecodeHintType.CHARACTER_SET] = "UTF-8"
        ContrastDecoder(CameraQrReader(hints))
    }

    /** Search QR finder candidates as the photo decoder does; never pick an arbitrary match. */
    private class CameraQrReader(private val hints: Map<DecodeHintType, Any>) : Reader {
        private val reader = QRCodeMultiReader()

        override fun decode(image: BinaryBitmap): Result {
            val results = reader.decodeMultiple(image, hints)
            if (results.size != 1) {
                results.forEach { it.rawBytes?.fill(0) }
                throw NotFoundException.getNotFoundInstance()
            }
            // Preserve the actual result and metadata. readPayload still rejects
            // structured append and merged results that have no finder points.
            return results.single()
        }

        override fun decode(image: BinaryBitmap, hints: Map<DecodeHintType, *>?): Result = decode(image)

        override fun reset() = reader.reset()
    }

    /** One copied crop, at most one upstream decode per frame, no retained image. */
    private class ContrastDecoder(reader: Reader) : MixedDecoder(reader) {
        override fun decode(source: LuminanceSource): Result? {
            val width = source.width
            val height = source.height
            if (Thread.currentThread().isInterrupted || width !in 1..MAX_FRAME_SIDE ||
                height !in 1..MAX_FRAME_SIDE || width.toLong() * height > MAX_FRAME_PIXELS) return null
            val luminance = ByteArray(width * height)
            val row = ByteArray(width)
            try {
                var darkest = 255
                var lightest = 0
                for (y in 0 until height) {
                    if (Thread.currentThread().isInterrupted) return null
                    // getRow respects the camera crop/stride. A source may return a
                    // borrowed row instead of our buffer; never modify that array.
                    val input = source.getRow(y, row)
                    if (input.size < width) return null
                    val start = y * width
                    input.copyInto(luminance, start, 0, width)
                    for (index in start until start + width) {
                        val value = luminance[index].toInt() and 255
                        darkest = minOf(darkest, value)
                        lightest = maxOf(lightest, value)
                    }
                }
                // A grey QR photographed from a screen can have enough visible
                // detail while HybridBinarizer still loses its dark modules.
                // Match the photo decoder's contrast stretch, leaving flat frames flat.
                if (lightest > darkest && (darkest != 0 || lightest != 255)) {
                    val range = lightest - darkest
                    for (y in 0 until height) {
                        if (Thread.currentThread().isInterrupted) return null
                        for (index in y * width until (y + 1) * width) {
                            val value = luminance[index].toInt() and 255
                            luminance[index] = ((value - darkest) * 255 / range).toByte()
                        }
                    }
                }
                if (Thread.currentThread().isInterrupted) return null
                // Keep the SDK's alternating normal/inverted scan and result-point
                // coordinates. The preview pixels and device camera effect stay untouched.
                val result = super.decode(FrameLuminance(width, height, luminance))
                if (Thread.currentThread().isInterrupted) {
                    result?.rawBytes?.fill(0)
                    return null
                }
                return result
            } catch (_: Exception) {
                // Treat a malformed/stale frame like the SDK's ordinary decode miss.
                return null
            } finally {
                row.fill(0)
                luminance.fill(0)
            }
        }
    }

    private class FrameLuminance(width: Int, height: Int, private val data: ByteArray) :
        LuminanceSource(width, height) {
        override fun getMatrix(): ByteArray = data

        override fun getRow(y: Int, row: ByteArray?): ByteArray {
            require(y in 0 until height)
            val output = row?.takeIf { it.size >= width } ?: ByteArray(width)
            data.copyInto(output, 0, y * width, (y + 1) * width)
            return output
        }
    }

    /**
     * A camera result must be a complete standalone symbol. A structured-append
     * segment can look like a valid HTTPS address before the remaining segments
     * add its token, so text validation alone cannot establish completeness.
     */
    fun readPayload(result: Result): String {
        if (result.barcodeFormat != BarcodeFormat.QR_CODE) {
            throw ProfileImportReader.Failure("PROFILE_IMPORT_INVALID")
        }
        val metadata = result.resultMetadata
        if (metadata?.containsKey(ResultMetadataType.STRUCTURED_APPEND_SEQUENCE) == true ||
            metadata?.containsKey(ResultMetadataType.STRUCTURED_APPEND_PARITY) == true ||
            (result.resultPoints?.size ?: 0) < 3) {
            throw ProfileImportReader.Failure("PROFILE_QR_MULTIPLE")
        }
        val text = result.text
        if (text == null || text.length > ProfileImportReader.MAX_BYTES) {
            throw ProfileImportReader.Failure("PROFILE_IMPORT_INVALID")
        }
        return text
    }
}
