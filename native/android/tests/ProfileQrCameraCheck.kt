package shop.pushok.flow

import com.google.zxing.BarcodeFormat
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.BitMatrix
import com.google.zxing.oned.Code128Writer
import com.google.zxing.qrcode.QRCodeWriter
import com.journeyapps.barcodescanner.Decoder
import com.journeyapps.barcodescanner.DefaultDecoderFactory

// Synthetic profiles only. The test runs the same production factory used by the
// camera against actual upstream decoding classes, not mocked barcode callbacks.
private val vless = "vless://11111111-2222-4333-8444-555555555555@example.invalid:443" +
    "?security=tls&type=ws&host=cdn.example.invalid&path=%2Fflow#Тестовый профиль"
private val denseVless = vless.replace("%2Fflow", "%2F" + "route%2Fsegment".repeat(45))
private val wireGuard = """
    [Interface]
    # Синтетический профиль
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Address = 10.44.0.2/32

    [Peer]
    PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = example.invalid:51820
""".trimIndent() + "\n"

private fun qr(text: String, side: Int = 560): BitMatrix = QRCodeWriter().encode(
    text, BarcodeFormat.QR_CODE, side, side,
    mapOf(EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.MARGIN to 4),
)

/** Model the cropped Y plane delivered to JourneyApps by an Android camera. */
private fun frame(
    symbol: BitMatrix,
    inverted: Boolean = false,
    rotated: Boolean = false,
    dark: Int = 0,
    light: Int = 255,
): PlanarYUVLuminanceSource {
    val width = 720
    val height = 960
    val symbolWidth = if (rotated) symbol.height else symbol.width
    val symbolHeight = if (rotated) symbol.width else symbol.height
    val left = (width - symbolWidth) / 2
    val top = (height - symbolHeight) / 2
    val background = if (inverted) dark else light
    val data = ByteArray(width * height) { background.toByte() }
    for (y in 0 until symbolHeight) {
        for (x in 0 until symbolWidth) {
            val black = if (rotated) symbol[y, symbol.height - 1 - x] else symbol[x, y]
            val value = if (black != inverted) dark else light
            data[(top + y) * width + left + x] = value.toByte()
        }
    }
    // A square crop inside a portrait camera frame, including the quiet zone.
    return PlanarYUVLuminanceSource(data, width, height, 40, 160, 640, 640, false)
}

private fun decoder(): Decoder = ProfileQrCameraDecoder.createFactory()
    .createDecoder(emptyMap<DecodeHintType, Any>())

private fun reads(label: String, expected: String, source: PlanarYUVLuminanceSource,
    target: Decoder = decoder()) {
    // MIXED_SCAN alternates polarity. It must resolve either colour in two frames.
    val first = target.decode(source)
    val result = first ?: target.decode(source)
    check(result?.barcodeFormat == BarcodeFormat.QR_CODE && result.text == expected) {
        "Camera decoder failed: $label"
    }
}

fun main() {
    val ordinary = frame(qr(vless))
    val inverted = frame(qr(vless), inverted = true)
    val previous = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
        .createDecoder(emptyMap<DecodeHintType, Any>())
    check(previous.decode(ordinary)?.text == vless) { "Baseline fixture is not decodable" }
    repeat(4) {
        check(previous.decode(inverted) == null) { "Baseline did not reproduce inverted QR failure" }
    }
    for ((name, payload) in listOf("VLESS UTF-8" to vless, "dense VLESS" to denseVless,
        "WireGuard" to wireGuard)) {
        val symbol = qr(payload)
        reads("$name normal", payload, frame(symbol))
        reads("$name inverted", payload, frame(symbol, inverted = true))
        reads("$name rotated", payload, frame(symbol, rotated = true))
        reads("$name inverted low contrast", payload,
            frame(symbol, inverted = true, rotated = true, dark = 55, light = 195))
    }

    val target = decoder()
    val empty = PlanarYUVLuminanceSource(ByteArray(640 * 640) { 255.toByte() },
        640, 640, 0, 0, 640, 640, false)
    repeat(5) { check(target.decode(empty) == null) { "Blank frame produced a barcode" } }
    // A sequence of failed frames must not make the live decoder stop reading.
    reads("after blank frames", vless, inverted, target)

    val barcode = frame(Code128Writer().encode("123456789012", BarcodeFormat.CODE_128, 560, 160))
    repeat(4) { check(target.decode(barcode) == null) { "Non-QR format was accepted" } }
    reads("after non-QR frames", vless, ordinary, target)

    println("Profile QR camera checks passed")
}
