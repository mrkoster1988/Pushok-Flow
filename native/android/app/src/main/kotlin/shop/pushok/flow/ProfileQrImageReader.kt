package shop.pushok.flow

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.InputStream

/** Reads only the user-selected document and never stores/uploads its image. */
object ProfileQrImageReader {
    fun read(input: InputStream, cancelled: () -> Boolean): String {
        var bytes: ByteArray? = null
        var bitmap: Bitmap? = null
        var pixels: IntArray? = null
        try {
            val encoded = ProfileQrDecoder.readImageBytes(input, cancelled)
            bytes = encoded
            if (cancelled()) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(encoded, 0, encoded.size, bounds)
            val sample = ProfileQrDecoder.sampleSize(bounds.outWidth, bounds.outHeight)
            if (cancelled()) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
            val options = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inScaled = false
            }
            val decoded = BitmapFactory.decodeByteArray(encoded, 0, encoded.size, options)
                ?: throw ProfileImportReader.Failure("PROFILE_QR_NOT_FOUND")
            bitmap = decoded
            if (decoded.width > ProfileQrDecoder.MAX_DECODE_SIDE || decoded.height > ProfileQrDecoder.MAX_DECODE_SIDE) {
                throw ProfileImportReader.Failure("PROFILE_QR_IMAGE_TOO_LARGE")
            }
            if (cancelled()) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
            val colors = IntArray(decoded.width * decoded.height)
            pixels = colors
            decoded.getPixels(colors, 0, decoded.width, 0, 0, decoded.width, decoded.height)
            return ProfileQrDecoder.decodePixels(decoded.width, decoded.height, colors, cancelled)
        } catch (_: OutOfMemoryError) {
            throw ProfileImportReader.Failure("PROFILE_QR_IMAGE_TOO_LARGE")
        } finally {
            pixels?.fill(0)
            bitmap?.recycle()
            bytes?.fill(0)
        }
    }
}
