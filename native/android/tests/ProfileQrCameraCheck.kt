package shop.pushok.flow

import com.google.zxing.BarcodeFormat
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ResultMetadataType
import com.google.zxing.ResultPointCallback
import com.google.zxing.common.BitArray
import com.google.zxing.common.BitMatrix
import com.google.zxing.oned.Code128Writer
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.decoder.Mode
import com.google.zxing.qrcode.decoder.Version
import com.google.zxing.qrcode.encoder.ByteMatrix
import com.google.zxing.qrcode.encoder.Encoder
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

private fun reads(label: String, expected: String, source: LuminanceSource,
    target: Decoder = decoder()) {
    // MIXED_SCAN alternates polarity. It must resolve either colour in two frames.
    val first = target.decode(source)
    val result = first ?: target.decode(source)
    check(result?.barcodeFormat == BarcodeFormat.QR_CODE && result.text == expected) {
        "Camera decoder failed: $label"
    }
    check(ProfileQrCameraDecoder.readPayload(result) == expected) {
        "Complete camera result rejected: $label"
    }
}

private fun finderSelectionCameraChecks() {
    // A reserved documentation IP and invented token. Fractional screen scaling
    // makes the single-QR finder choose an interior candidate; the multi-reader
    // still finds exactly one complete symbol after checking the other candidates.
    val subscription = "https://198.51.100.150:2096/sub/548e034ab52285f5"
    val symbol = Encoder.encode(subscription, ErrorCorrectionLevel.L, mapOf(
        EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.QR_MASK_PATTERN to 5,
    )).matrix
    check(symbol.width == 29 && symbol.height == 29)
    val side = 360
    val quiet = 3
    for (inverted in listOf(false, true)) {
        val data = ByteArray(side * side) { offset ->
            val x = (offset % side) * (symbol.width + quiet * 2) / side - quiet
            val y = (offset / side) * (symbol.height + quiet * 2) / side - quiet
            val black = x in 0 until symbol.width && y in 0 until symbol.height &&
                symbol[x, y].toInt() == 1
            if (black != inverted) 128.toByte() else 179.toByte()
        }
        data[0] = 110.toByte()
        data[1] = 194.toByte()
        val unchanged = data.copyOf()
        val source = PlanarYUVLuminanceSource(data, side, side, 0, 0, side, side, false)
        reads("fractionally scaled finder candidates, inverted=$inverted", subscription, source)
        check(data.contentEquals(unchanged))
        val pixels = IntArray(data.size) { index ->
            val value = data[index].toInt() and 255
            -0x1000000 or (value shl 16) or (value shl 8) or value
        }
        check(ProfileQrDecoder.decodePixels(side, side, pixels) == subscription)
    }
}

private fun lowContrastCameraChecks() {
    // Same image size and grey distribution as a reported screenshot, with an
    // invented subscription: main levels 128/179 and edge extremes 110/194.
    // Never commit a user's QR pixels or bearer subscription URL.
    val subscription = "https://example.invalid:2096/sub/synthetic-token"
    val symbol = qr(subscription, 360)
    for (inverted in listOf(false, true)) {
        val data = ByteArray(360 * 360) { offset ->
            if (symbol[offset % 360, offset / 360] != inverted) 128.toByte() else 179.toByte()
        }
        data[0] = 110.toByte()
        data[1] = 194.toByte()
        val unchanged = data.copyOf()
        val source = PlanarYUVLuminanceSource(data, 360, 360, 0, 0, 360, 360, false)
        reads("360px grey subscription, inverted=$inverted", subscription, source)
        check(data.contentEquals(unchanged)) { "Camera changed the borrowed frame" }
        val pixels = IntArray(data.size) { index ->
            val value = data[index].toInt() and 255
            -0x1000000 or (value shl 16) or (value shl 8) or value
        }
        check(ProfileQrDecoder.decodePixels(360, 360, pixels) == subscription)
    }
}

/** A cropped provider whose rows are borrowed, not owned by the decoder. */
private class BorrowedRows(
    source: LuminanceSource,
    private val interruptedAt: Int? = null,
    private val brokenAt: Int? = null,
) : LuminanceSource(source.width, source.height) {
    private val borrowed = Array(height) { source.getRow(it, null) }
    private val snapshots = borrowed.map { it.copyOf() }
    private val ownedBuffers = mutableSetOf<ByteArray>()
    var reads = 0
        private set

    override fun getMatrix(): ByteArray = error("Camera must copy bounded crop rows")

    override fun getRow(y: Int, row: ByteArray?): ByteArray {
        reads++
        check(row != null && row.size == width)
        ownedBuffers += row
        // Some sources ignore the provided scratch row. It must still be erased,
        // while the array actually returned below remains owned by this provider.
        row.fill(17)
        if (y == brokenAt) error("Synthetic unavailable camera row")
        if (y == interruptedAt) Thread.currentThread().interrupt()
        return borrowed[y]
    }

    fun assertUnchangedAndErased() {
        check(borrowed.indices.all { borrowed[it].contentEquals(snapshots[it]) }) {
            "Camera modified a borrowed luminance row"
        }
        check(ownedBuffers.all { row -> row.all { it == 0.toByte() } }) {
            "Camera retained its owned row buffer"
        }
    }
}

private fun boundedCameraFrameChecks() {
    // PlanarYUVLuminanceSource has a 720px source stride, 40px left crop and
    // 160px top crop. Result coordinates and crop contents must remain unchanged.
    val cropped = frame(qr(vless, 360), dark = 128, light = 179)
    val before = cropped.matrix.copyOf()
    val source = BorrowedRows(cropped)
    reads("cropped, strided, borrowed grey rows", vless, source)
    check(source.reads in 640..1280)
    source.assertUnchangedAndErased()
    check(cropped.matrix.contentEquals(before))

    // Never request a huge matrix/row before checking dimensions and pixel count.
    for ((width, height) in listOf(4097 to 1, 1 to 4097, 2049 to 2049,
        Int.MAX_VALUE to Int.MAX_VALUE)) {
        val oversized = object : LuminanceSource(width, height) {
            override fun getMatrix(): ByteArray = error("Read oversized matrix")
            override fun getRow(y: Int, row: ByteArray?): ByteArray = error("Read oversized row")
        }
        check(decoder().decode(oversized) == null)
    }

    val target = decoder()
    val cancelledBeforeRead = BorrowedRows(cropped)
    try {
        Thread.currentThread().interrupt()
        check(target.decode(cancelledBeforeRead) == null)
        check(Thread.currentThread().isInterrupted)
        check(cancelledBeforeRead.reads == 0)
    } finally { Thread.interrupted() }
    cancelledBeforeRead.assertUnchangedAndErased()

    val cancelledDuringRead = BorrowedRows(cropped, interruptedAt = 17)
    try {
        check(target.decode(cancelledDuringRead) == null)
        check(Thread.currentThread().isInterrupted)
        check(cancelledDuringRead.reads == 18)
    } finally { Thread.interrupted() }
    cancelledDuringRead.assertUnchangedAndErased()

    val broken = BorrowedRows(cropped, brokenAt = 8)
    check(target.decode(broken) == null)
    broken.assertUnchangedAndErased()
    reads("after interrupted/unavailable frames", vless, cropped, target)

    // The framework's result-point callback must survive factory construction;
    // caller hints cannot expand this scanner to non-QR barcode formats.
    var callbackPoints = 0
    val callbackTarget = ProfileQrCameraDecoder.createFactory().createDecoder(mapOf(
        DecodeHintType.NEED_RESULT_POINT_CALLBACK to ResultPointCallback { callbackPoints++ },
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.CODE_128),
    ))
    reads("preserved result-point callback", vless, cropped, callbackTarget)
    check(callbackPoints >= 3)
    val barcode = frame(Code128Writer().encode("123456789012", BarcodeFormat.CODE_128, 560, 160),
        dark = 128, light = 179)
    repeat(4) { check(callbackTarget.decode(barcode) == null) }
}

private fun multipleCameraSymbolsChecks() {
    val firstPayload = "https://example.invalid/sub/synthetic-first"
    val side = 360
    val gap = 60
    val width = side * 2 + gap
    for (secondPayload in listOf(firstPayload, "https://example.invalid/sub/synthetic-second")) {
        val first = qr(firstPayload, side)
        val second = qr(secondPayload, side)
        for (inverted in listOf(false, true)) {
            val data = ByteArray(width * side) { if (inverted) 128.toByte() else 179.toByte() }
            for ((left, symbol) in listOf(0 to first, side + gap to second)) {
                for (y in 0 until side) for (x in 0 until side) {
                    data[y * width + left + x] =
                        if (symbol[x, y] != inverted) 128.toByte() else 179.toByte()
                }
            }
            val unchanged = data.copyOf()
            val source = PlanarYUVLuminanceSource(data, width, side, 0, 0, width, side, false)
            val target = decoder()
            // Two symbols in the inspected polarity are ambiguous even if their
            // text is equal. This is not a cross-polarity scene guarantee.
            repeat(4) { check(target.decode(source) == null) { "Camera chose one of several QRs" } }
            check(data.contentEquals(unchanged))
            reads("after ambiguous camera frame", vless, frame(qr(vless)), target)
        }
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
            val camera = importOutcome {
                ProfileQrDecoder.normalizePayload(ProfileQrCameraDecoder.readPayload(read!!))
            }
            val pixels = IntArray(symbol.width * symbol.height) { index ->
                if (symbol[index % symbol.width, index / symbol.width] != inverted) -0x1000000 else -1
            }
            val photo = importOutcome { ProfileQrDecoder.decodePixels(symbol.width, symbol.height, pixels) }
            check(camera == expected && photo == expected) { "Import parity failed: $label" }
        }
    }
}

/** Real structured-append bitstream: an incomplete segment can itself be a valid URL. */
private fun structuredAppendSymbol(text: String, index: Int, total: Int): BitMatrix {
    val version = Version.getVersionForNumber(4)
    val ec = ErrorCorrectionLevel.L
    val bytes = text.toByteArray(Charsets.US_ASCII)
    val bits = BitArray().apply {
        appendBits(Mode.STRUCTURED_APPEND.bits, 4)
        appendBits(index, 4)
        appendBits(total - 1, 4)
        appendBits(91, 8)
        appendBits(Mode.BYTE.bits, 4)
        appendBits(bytes.size, Mode.BYTE.getCharacterCountBits(version))
        bytes.forEach { appendBits(it.toInt() and 255, 8) }
    }
    val blocks = version.getECBlocksForLevel(ec)
    val dataBytes = version.totalCodewords - blocks.totalECCodewords
    Encoder::class.java.getDeclaredMethod("terminateBits", Integer.TYPE, BitArray::class.java)
        .apply { isAccessible = true }.invoke(null, dataBytes, bits)
    val encoded = Encoder::class.java.getDeclaredMethod("interleaveWithECBytes", BitArray::class.java,
        Integer.TYPE, Integer.TYPE, Integer.TYPE).apply { isAccessible = true }
        .invoke(null, bits, version.totalCodewords, dataBytes, blocks.numBlocks) as BitArray
    val dimension = version.dimensionForVersion
    val matrix = ByteMatrix(dimension, dimension)
    Class.forName("com.google.zxing.qrcode.encoder.MatrixUtil")
        .getDeclaredMethod("buildMatrix", BitArray::class.java, ErrorCorrectionLevel::class.java,
            Version::class.java, Integer.TYPE, ByteMatrix::class.java)
        .apply { isAccessible = true }.invoke(null, encoded, ec, version, 0, matrix)
    val scale = 8
    val quiet = 4
    return BitMatrix((dimension + quiet * 2) * scale).also { symbol ->
        for (y in 0 until dimension) for (x in 0 until dimension) {
            if (matrix[x, y].toInt() == 1) {
                symbol.setRegion((x + quiet) * scale, (y + quiet) * scale, scale, scale)
            }
        }
    }
}

private fun structuredAppendCameraPhotoParity() {
    val partialUrl = "https://example.invalid/sub/synthetic"
    check(ProfileImportPayload.parse(partialUrl) is ProfileImportPayload.Subscription)
    val expected = mapOf("errorCode" to "PROFILE_QR_MULTIPLE")
    for ((index, total) in listOf(0 to 2, 1 to 2, 0 to 1)) {
        val symbol = structuredAppendSymbol(partialUrl, index, total)
        for (inverted in listOf(false, true)) for ((dark, light) in listOf(0 to 255, 128 to 179)) {
            val target = decoder()
            val source = frame(symbol, inverted = inverted, dark = dark, light = light)
            val result = target.decode(source) ?: target.decode(source)
                ?: error("Real structured-append fixture was not decoded")
            // The multi-reader may merge structured append into a result with no
            // finder points. Either real upstream representation must be rejected.
            val metadata = result.resultMetadata
            check((metadata?.containsKey(ResultMetadataType.STRUCTURED_APPEND_SEQUENCE) == true &&
                metadata.containsKey(ResultMetadataType.STRUCTURED_APPEND_PARITY)) ||
                result.resultPoints.isEmpty())
            check(result.text == partialUrl)
            // This reproduces the old boundary: validating text alone accepts a
            // partial token URL. Production must inspect the real result first.
            check(ProfileImportPayload.parse(result.text) is ProfileImportPayload.Subscription)
            val camera = importOutcome {
                ProfileQrDecoder.normalizePayload(ProfileQrCameraDecoder.readPayload(result))
            }
            val pixels = IntArray(symbol.width * symbol.height) { offset ->
                if (symbol[offset % symbol.width, offset / symbol.width] != inverted) -0x1000000 else -1
            }
            val photo = importOutcome { ProfileQrDecoder.decodePixels(symbol.width, symbol.height, pixels) }
            check(camera == expected && photo == expected) { "Incomplete QR accepted by an import route" }
        }
    }
}

fun main() {
    finderSelectionCameraChecks()
    lowContrastCameraChecks()
    boundedCameraFrameChecks()
    multipleCameraSymbolsChecks()
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
    structuredAppendCameraPhotoParity()

    println("Profile QR camera checks passed")
}
