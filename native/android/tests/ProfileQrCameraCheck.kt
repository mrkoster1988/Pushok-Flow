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

private fun importOutcome(read: () -> String): Map<String, String> = try {
    ProfileImportPayload.parse(read()).toPlatform()
} catch (failure: ProfileImportReader.Failure) { mapOf("errorCode" to failure.code) }

private fun cameraPhotoImportParity() {
    val supportedVless = vless.substringBefore('#') + "#%D0%A2%D0%B5%D1%81%D1%82"
    val subscription = "https://example.invalid/Sub/%2FSYNTHETIC?token=a+b%2Bc"
    val fixtures = listOf(
        Triple("VLESS", supportedVless, mapOf("kind" to "profile", "config" to supportedVless)),
        Triple("WireGuard", wireGuard, mapOf("kind" to "profile", "config" to wireGuard)),
        Triple("HTTPS", subscription, mapOf("kind" to "subscription", "url" to subscription)),
        Triple("app subscription link", "pushokflow://subscription?url=" +
            java.net.URLEncoder.encode(subscription, "UTF-8"),
            mapOf("kind" to "subscription", "url" to subscription)),
        Triple("Telegram", "tg://proxy?server=example.invalid&port=443&secret=SYNTHETIC",
            mapOf("errorCode" to "PROFILE_TELEGRAM_LINK")),
        Triple("VMess", "vmess://SYNTHETIC", mapOf("errorCode" to "PROFILE_VMESS_LINK")),
        Triple("Trojan", "trojan://SYNTHETIC@example.invalid:443", mapOf("errorCode" to "PROFILE_TROJAN_LINK")),
        Triple("Shadowsocks", "ss://SYNTHETIC@example.invalid:443", mapOf("errorCode" to "PROFILE_SHADOWSOCKS_LINK")),
        Triple("insecure subscription", "http://example.invalid/sub/SYNTHETIC",
            mapOf("errorCode" to "SUBSCRIPTION_URL_INVALID")),
        Triple("private subscription", "https://127.0.0.1/sub/SYNTHETIC",
            mapOf("errorCode" to "SUBSCRIPTION_URL_INVALID")),
    )
    for ((label, payload, expected) in fixtures) {
        val symbol = qr(payload)
        for (inverted in listOf(false, true)) {
            val target = decoder()
            val source = frame(symbol, inverted = inverted)
            val read = target.decode(source) ?: target.decode(source)
            check(read?.barcodeFormat == BarcodeFormat.QR_CODE) { "Missing parity fixture: $label" }
            // Match production's raw camera result -> bounded normalization -> typed draft.
            val camera = importOutcome { ProfileQrDecoder.normalizePayload(read!!.text) }
            val pixels = IntArray(symbol.width * symbol.height) { index ->
                if (symbol[index % symbol.width, index / symbol.width] != inverted) -0x1000000 else -1
            }
            val photo = importOutcome { ProfileQrDecoder.decodePixels(symbol.width, symbol.height, pixels) }
            check(camera == expected && photo == expected) { "Import parity failed: $label" }
        }
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
    cameraPhotoImportParity()

    println("Profile QR camera checks passed")
}
