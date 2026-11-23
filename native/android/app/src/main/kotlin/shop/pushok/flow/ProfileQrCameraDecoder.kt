package shop.pushok.flow

import com.google.zxing.BarcodeFormat
import com.google.zxing.DecodeHintType
import com.google.zxing.Result
import com.google.zxing.ResultMetadataType
import com.google.zxing.client.android.Intents
import com.journeyapps.barcodescanner.DecoderFactory
import com.journeyapps.barcodescanner.DefaultDecoderFactory

/** Shared by the live camera and executable QR regressions; contains no camera or profile state. */
object ProfileQrCameraDecoder {
    fun createFactory(): DecoderFactory = DefaultDecoderFactory(
        listOf(BarcodeFormat.QR_CODE),
        mapOf(DecodeHintType.TRY_HARDER to true),
        "UTF-8",
        // Alternate normal and inverted frames locally. Do not invert the device preview:
        // that camera effect is unavailable on some devices and changes what the user sees.
        Intents.Scan.MIXED_SCAN,
    )

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
