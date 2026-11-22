package shop.pushok.flow

import com.google.zxing.BarcodeFormat
import com.google.zxing.DecodeHintType
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
}
