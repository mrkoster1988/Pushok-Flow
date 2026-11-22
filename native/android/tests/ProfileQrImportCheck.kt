package shop.pushok.flow

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.BitArray
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.decoder.Mode
import com.google.zxing.qrcode.decoder.Version
import com.google.zxing.qrcode.encoder.ByteMatrix
import com.google.zxing.qrcode.encoder.Encoder
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.URLEncoder

private const val WHITE = -0x1
private const val BLACK = -0x1000000

// Synthetic fixtures only: these placeholder values are never used to connect a tunnel.
private val profile = """
    [Interface]
    # Синтетический профиль WGDashboard
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Address = 10.44.0.2/32
    DNS = 1.1.1.1

    [Peer]
    PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = example.invalid:51820
    PersistentKeepalive = 25
""".trimIndent() + "\n"

private fun rejected(code: String, action: () -> Unit) {
    try {
        action()
        error("Expected $code")
    } catch (error: ProfileImportReader.Failure) {
        check(error.code == code) { "Expected $code, received ${error.code}" }
    }
}

private fun qr(text: String, size: Int = 600): IntArray {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size,
        mapOf(EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.MARGIN to 4))
    return IntArray(size * size) { index -> if (matrix[index % size, index / size]) BLACK else WHITE }
}

private fun inverted(pixels: IntArray): IntArray =
    pixels.map { if (it == WHITE) BLACK else WHITE }.toIntArray()

private fun beside(first: IntArray, second: IntArray, size: Int, gap: Int = 80): Pair<Int, IntArray> {
    val width = size * 2 + gap
    val combined = IntArray(width * size) { WHITE }
    for (row in 0 until size) {
        first.copyInto(combined, row * width, row * size, (row + 1) * size)
        second.copyInto(combined, row * width + size + gap, row * size, (row + 1) * size)
    }
    return width to combined
}

private fun imageAppearanceChecks() {
    val size = 600
    val first = qr(profile)
    val untouched = first.copyOf()
    check(ProfileQrDecoder.decodePixels(size, size, first) == profile)
    check(first.contentEquals(untouched))
    // Transparent PNG export, both with zero RGB and with white RGB behind alpha=0.
    for (transparent in listOf(0, 0x00FFFFFF)) {
        val pixels = first.map { if (it == WHITE) transparent else it }.toIntArray()
        val original = pixels.copyOf()
        check(ProfileQrDecoder.decodePixels(size, size, pixels) == profile)
        check(pixels.contentEquals(original))
    }
    val translucent = first.map { if (it == WHITE) 0 else 0x80000000.toInt() }.toIntArray()
    check(ProfileQrDecoder.decodePixels(size, size, translucent) == profile)
    check(ProfileQrDecoder.decodePixels(size, size, inverted(first)) == profile)
    // A fully invisible QR must never be recovered from hidden RGB channels.
    rejected("PROFILE_QR_NOT_FOUND") {
        ProfileQrDecoder.decodePixels(size, size, first.map { it and 0x00FFFFFF }.toIntArray())
    }
    val second = qr(profile.replace("10.44.0.2", "10.44.0.3"))
    val subscription = qr("https://example.invalid/sub/synthetic")
    // Counts are based on physical QR symbols, including identical payloads and mixed
    // polarity. Payload validity must not allow selecting one of several symbols.
    for ((left, right) in listOf(
        first to first,
        first to inverted(first),
        first to inverted(second),
        inverted(first) to second,
        inverted(first) to inverted(second),
        first to inverted(subscription),
        subscription to inverted(first),
    )) {
        val (width, combined) = beside(left, right, size)
        rejected("PROFILE_QR_MULTIPLE") { ProfileQrDecoder.decodePixels(width, size, combined) }
    }
}

/** Manufacture real SA symbols with the pinned upstream encoder, not mocked decode results. */
private fun structuredAppendQr(text: String, index: Int, total: Int, parity: Int): Pair<Int, IntArray> {
    val version = Version.getVersionForNumber(4)
    val ec = ErrorCorrectionLevel.L
    val bytes = text.toByteArray(Charsets.US_ASCII)
    val bits = BitArray().apply {
        appendBits(Mode.STRUCTURED_APPEND.bits, 4)
        appendBits(index, 4)
        appendBits(total - 1, 4)
        appendBits(parity, 8)
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
    val side = (dimension + quiet * 2) * scale
    return side to IntArray(side * side) { offset ->
        val x = offset % side / scale - quiet
        val y = offset / side / scale - quiet
        if (x in 0 until dimension && y in 0 until dimension && matrix[x, y].toInt() == 1) BLACK else WHITE
    }
}

private fun structuredAppendChecks() {
    val uri = "vless://11111111-2222-4333-8444-555555555555@example.invalid:443?security=tls"
    val parity = uri.toByteArray(Charsets.US_ASCII).fold(0) { value, byte -> value xor (byte.toInt() and 255) }
    val (side, first) = structuredAppendQr(uri.take(40), 0, 2, parity)
    val second = structuredAppendQr(uri.drop(40), 1, 2, parity).second
    val (width, combined) = beside(first, second, side)
    // This is the library edge case: two physical symbols become one valid VLESS result.
    val merged = QRCodeMultiReader().decodeMultiple(BinaryBitmap(HybridBinarizer(
        RGBLuminanceSource(width, side, combined))), mapOf(DecodeHintType.TRY_HARDER to true))
    check(merged.size == 1 && merged.single().text == uri && merged.single().resultPoints.isEmpty())
    for (pixels in listOf(combined, inverted(combined), beside(first, inverted(second), side).second)) {
        rejected("PROFILE_QR_MULTIPLE") { ProfileQrDecoder.decodePixels(width, side, pixels) }
    }
    // A lone segment is not a complete standalone QR profile either.
    rejected("PROFILE_QR_MULTIPLE") { ProfileQrDecoder.decodePixels(side, side, first) }
}

private fun decoderChecks() {
    val size = 600
    check(ProfileQrDecoder.decodePixels(size, size, qr(profile)) == profile)
    val windows = "\uFEFF" + profile.replace("\n", "\r\n")
    check(ProfileQrDecoder.decodePixels(size, size, qr(windows)) == windows.removePrefix("\uFEFF"))
    rejected("PROFILE_QR_NOT_FOUND") {
        ProfileQrDecoder.decodePixels(size, size, IntArray(size * size) { WHITE })
    }
    val subscription = "https://example.invalid/sub/synthetic"
    check(ProfileQrDecoder.decodePixels(size, size, qr(subscription)) == subscription)
    for (payload in listOf("random text", "eyJjb250YWluZXJzIjpbXX0=",
        "{\"containers\":[{\"container\":\"amnezia-awg\"}]}", "[Interface]\nPrivateKey = missing-peer")) {
        rejected("PROFILE_IMPORT_INVALID") { ProfileQrDecoder.decodePixels(size, size, qr(payload)) }
    }
    // A saved WGDashboard screenshot can contain separate WireGuard and Amnezia QRs.
    // Never choose one silently, even if one is a valid draft.
    val second = qr(profile.replace("10.44.0.2", "10.44.0.3"))
    val first = qr(profile)
    val gap = 80
    val width = size * 2 + gap
    val combined = IntArray(width * size) { WHITE }
    for (row in 0 until size) {
        first.copyInto(combined, row * width, row * size, (row + 1) * size)
        second.copyInto(combined, row * width + size + gap, row * size, (row + 1) * size)
    }
    rejected("PROFILE_QR_MULTIPLE") { ProfileQrDecoder.decodePixels(width, size, combined) }
    rejected("PROFILE_IMPORT_INTERRUPTED") {
        ProfileQrDecoder.decodePixels(size, size, first) { true }
    }
    var checkpoints = 0
    rejected("PROFILE_IMPORT_INTERRUPTED") {
        ProfileQrDecoder.decodePixels(size, size, first) { ++checkpoints > 1 }
    }
    rejected("PROFILE_QR_IMAGE_TOO_LARGE") { ProfileQrDecoder.decodePixels(2049, 1, IntArray(2049)) }
    rejected("PROFILE_QR_IMAGE_TOO_LARGE") { ProfileQrDecoder.decodePixels(2, 2, IntArray(3)) }
    val vless = "vless://11111111-2222-4333-8444-555555555555@example.invalid:443?security=tls#Synthetic"
    check(ProfileQrDecoder.decodePixels(size, size, qr(vless)) == vless)
    val websocket = vless.replace("security=tls",
        "security=tls&type=ws&path=%2Fflow%252Fsocket%3Ftoken%3Da%2Bb&host=cdn.example.invalid")
    check(ProfileQrDecoder.decodePixels(size, size, qr(websocket)) == websocket)
    val grpc = vless.replace("security=tls",
        "security=tls&type=grpc&serviceName=flow-service&authority=grpc.example.invalid&mode=multi")
    check(ProfileQrDecoder.decodePixels(size, size, qr(grpc)) == grpc)
    rejected("UNSUPPORTED_TRANSPORT") {
        ProfileQrDecoder.decodePixels(size, size, qr(vless.replace("security=tls", "security=tls&type=xhttp")))
    }
    rejected("UNSUPPORTED_SECURITY") {
        ProfileQrDecoder.decodePixels(size, size, qr(vless.replace("security=tls", "security=none")))
    }
    rejected("INVALID_VLESS_CONFIG") {
        ProfileQrDecoder.decodePixels(size, size, qr(vless.replace(":443", ":0")))
    }
}

private fun payloadChecks() {
    check(ProfileQrDecoder.normalizePayload(profile) == profile)
    check(ProfileQrDecoder.normalizePayload("\uFEFF" + profile) == profile)
    for (bad in listOf(null, "", " \n", profile + "\u0000", profile + "\u001B", profile + "\u007F",
        profile + "\uD800", profile + "\uDC00")) {
        rejected("PROFILE_IMPORT_INVALID") { ProfileQrDecoder.normalizePayload(bad) }
    }
    rejected("PROFILE_IMPORT_TOO_LARGE") {
        ProfileQrDecoder.normalizePayload("x".repeat(ProfileImportReader.MAX_BYTES + 1))
    }
    // The UTF-8 byte bound also applies when the UTF-16 string length is within its limit.
    rejected("PROFILE_IMPORT_TOO_LARGE") {
        ProfileQrDecoder.normalizePayload("Ж".repeat(ProfileImportReader.MAX_BYTES / 2 + 1))
    }
    rejected("PROFILE_IMPORT_INTERRUPTED") { ProfileQrDecoder.normalizePayload(profile) { true } }
    // The shape gate keeps unknown attributes intact for the authoritative WireGuard parser.
    val awg = profile.replace("[Interface]", "[Interface]\nJc = 5")
    check(ProfileQrDecoder.normalizePayload(awg) == awg)
}

private fun importClassificationChecks() {
    val vless = "vless://11111111-2222-4333-8444-555555555555@example.invalid:443" +
        "?type=ws&security=tls&path=%2Fflow%252Fsocket%3Ftoken%3Da%2Bb#%D0%A2%D0%B5%D1%81%D1%82"
    for ((raw, kind) in listOf(profile to ConnectionProfile.Kind.WIREGUARD,
        vless to ConnectionProfile.Kind.VLESS)) {
        val parsed = ProfileImportPayload.parse(raw)
        check(parsed is ProfileImportPayload.Profile && parsed.protocol == kind)
        check(parsed.text == raw && parsed.toPlatform() == mapOf("kind" to "profile", "config" to raw))
        check("11111111" !in parsed.toString() && "PrivateKey" !in parsed.toString())
    }
    // Existing 3x-ui percent escapes are preserved; no unwrapping or double decoding.
    val prefixed = "\uFEFF\r\n" + vless + "\r\n"
    check(ProfileImportPayload.parse(prefixed).text == prefixed.removePrefix("\uFEFF"))
    val original = " HTTPS://EXAMPLE.INVALID:443/Sub/%2fSYNTHETIC?token=A+b%2BC%2fD \r\n"
    val expected = "https://example.invalid/Sub/%2fSYNTHETIC?token=A+b%2BC%2fD"
    val wrapped = "pushokflow://subscription?url=" + URLEncoder.encode(original.trim(), "UTF-8") +
        "&name=%D0%9C%D0%BE%D1%8F+%D0%BF%D0%BE%D0%B4%D0%BF%D0%B8%D1%81%D0%BA%D0%B0"
    for (raw in listOf(original, "\uFEFF" + original, wrapped)) {
        val parsed = ProfileImportPayload.parse(raw)
        check(parsed is ProfileImportPayload.Subscription)
        check(parsed.text == expected)
        check(parsed.toPlatform() == mapOf("kind" to "subscription", "url" to expected))
        check("SYNTHETIC" !in parsed.toString())
        // Camera/photo normalization and subsequent native classification are idempotent.
        check(ProfileImportPayload.parse(parsed.text).toPlatform() == parsed.toPlatform())
        val file = ProfileImportReader.read(ByteArrayInputStream(raw.toByteArray(Charsets.UTF_8)))
        check(ProfileImportPayload.parse(file).toPlatform() == parsed.toPlatform())
        val size = 600
        check(ProfileImportPayload.parse(ProfileQrDecoder.decodePixels(size, size, qr(raw))).toPlatform() ==
            parsed.toPlatform())
    }
    // A subscription URL must remain impossible to save or connect as a profile.
    try { ConnectionProfile.validateShape(expected); error("Subscription reached profile gate") }
    catch (failure: ProfileFormatFailure) { check(failure.code == "UNSUPPORTED_PROFILE") }
    for (raw in listOf("http://example.invalid/sub/synthetic", "https://localhost/sub/synthetic",
        "https://127.0.0.1/sub/synthetic", "https://10.0.0.1/sub/synthetic", "https://[::1]/sub/synthetic",
        "https://user:password@example.invalid/sub/synthetic", "https://example.invalid/sub/synthetic#fragment",
        "https://example.invalid:0/sub/synthetic", "https://example.invalid/a b", "https:///missing-host",
        "pushokflow://subscription?url=https%253A%252F%252Fexample.invalid%252Fsub",
        "pushokflow://subscription?url=https%3A%2F%2Fexample.invalid%2Fsub&url=https%3A%2F%2Fexample.invalid%2Fother",
        "pushokflow://subscription?url=https%3A%2F%2Fexample.invalid%2Fsub&extra=ignored",
        "pushokflow://other?url=https%3A%2F%2Fexample.invalid%2Fsub")) {
        rejected("SUBSCRIPTION_URL_INVALID") { ProfileImportPayload.parse(raw) }
    }
    val urlPrefix = "https://example.invalid/"
    val limit = urlPrefix + "x".repeat(SubscriptionPolicy.MAX_URL_LENGTH - urlPrefix.length)
    check(ProfileImportPayload.parse(limit) is ProfileImportPayload.Subscription)
    rejected("SUBSCRIPTION_URL_INVALID") { ProfileImportPayload.parse(limit + "x") }
    val telegram = "https://t.me/proxy?server=example.invalid&port=443&secret=SYNTHETIC"
    for ((raw, code) in listOf(
        "tg://proxy?server=example.invalid&port=443&secret=SYNTHETIC" to "PROFILE_TELEGRAM_LINK",
        telegram to "PROFILE_TELEGRAM_LINK",
        "pushokflow://subscription?url=${URLEncoder.encode(telegram, "UTF-8")}" to "PROFILE_TELEGRAM_LINK",
        "VMESS://SYNTHETIC" to "PROFILE_VMESS_LINK",
        "trojan://SYNTHETIC@example.invalid:443" to "PROFILE_TROJAN_LINK",
        "ss://SYNTHETIC@example.invalid:443" to "PROFILE_SHADOWSOCKS_LINK",
        "ssr://SYNTHETIC" to "PROFILE_SHADOWSOCKS_LINK",
        "hysteria2://SYNTHETIC@example.invalid:443" to "UNSUPPORTED_PROFILE",
        "v2rayng://install-config?url=https%3A%2F%2Fexample.invalid%2Fsub" to "UNSUPPORTED_PROFILE",
    )) {
        rejected(code) { ProfileImportPayload.parse(raw) }
        rejected(code) { ProfileQrDecoder.decodePixels(600, 600, qr(raw)) }
        try { ProfileImportPayload.parse(raw); error("Expected safe error") }
        catch (failure: ProfileImportReader.Failure) {
            check(failure.message == null && "SYNTHETIC" !in failure.toString())
        }
    }
    rejected("PROFILE_IMPORT_INTERRUPTED") { ProfileImportPayload.parse(expected) { true } }
    var calls = 0
    rejected("PROFILE_IMPORT_INTERRUPTED") { ProfileImportPayload.parse(expected) { ++calls > 3 } }
}

private fun imageBoundsChecks() {
    check(ProfileQrDecoder.sampleSize(2048, 2048) == 1)
    check(ProfileQrDecoder.sampleSize(2049, 500) == 2)
    check(ProfileQrDecoder.sampleSize(8000, 6000) == 4)
    check(ProfileQrDecoder.sampleSize(16384, 1000) == 8)
    rejected("PROFILE_QR_IMAGE_TOO_LARGE") { ProfileQrDecoder.sampleSize(8001, 6000) }
    rejected("PROFILE_QR_IMAGE_TOO_LARGE") { ProfileQrDecoder.sampleSize(16385, 1) }
    rejected("PROFILE_QR_IMAGE_TOO_LARGE") { ProfileQrDecoder.sampleSize(Int.MAX_VALUE, Int.MAX_VALUE) }
    rejected("PROFILE_QR_NOT_FOUND") { ProfileQrDecoder.sampleSize(0, 100) }
    rejected("PROFILE_QR_NOT_FOUND") { ProfileQrDecoder.sampleSize(-1, 100) }
    rejected("PROFILE_QR_NOT_FOUND") { ProfileQrDecoder.readImageBytes(ByteArrayInputStream(byteArrayOf())) }
    val expected = byteArrayOf(1, 2, 3, 4)
    check(ProfileQrDecoder.readImageBytes(ByteArrayInputStream(expected)).contentEquals(expected))
    val zeroThenData = object : ByteArrayInputStream(expected) {
        private var zero = true
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            if (zero) { zero = false; return 0 }
            return super.read(bytes, offset, length)
        }
    }
    check(ProfileQrDecoder.readImageBytes(zeroThenData).contentEquals(expected))
    var reads = 0
    val endless = object : InputStream() {
        override fun read(): Int { reads++; return 1 }
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            bytes.fill(1, offset, offset + length)
            reads += length
            return length
        }
    }
    rejected("PROFILE_QR_IMAGE_TOO_LARGE") { ProfileQrDecoder.readImageBytes(endless) }
    check(reads == ProfileQrDecoder.MAX_IMAGE_BYTES + 1)
    reads = 0
    rejected("PROFILE_IMPORT_INTERRUPTED") { ProfileQrDecoder.readImageBytes(endless) { true } }
    check(reads == 0)
    var cancelled = false
    val cancelling = object : ByteArrayInputStream(expected) {
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            val count = super.read(bytes, offset, minOf(2, length))
            cancelled = true
            return count
        }
    }
    rejected("PROFILE_IMPORT_INTERRUPTED") { ProfileQrDecoder.readImageBytes(cancelling) { cancelled } }
}

private fun ownerSessionChecks() {
    val session = ProfileQrSession()
    check(!session.isActive(1))
    check(!session.watch(1) { error("Unexpected callback") })
    check(session.begin(1))
    check(!session.begin(2))
    var cancellations = 0
    val old = { cancellations += 1 }
    check(session.watch(1, old))
    session.end(2)
    check(session.isActive(1) && cancellations == 0)
    session.end(1)
    session.end(1)
    check(!session.isActive(1) && cancellations == 1)
    check(session.begin(2))
    val current = { cancellations += 10 }
    check(session.watch(2, old))
    // Replacement Activity registers its own listener; an old onDestroy must not remove it.
    check(session.watch(2, current))
    session.unwatch(2, old)
    session.end(1)
    check(session.isActive(2))
    session.end(2)
    check(cancellations == 11)
    check(session.begin(3))
    check(session.watch(3, current))
    session.unwatch(3, current)
    session.end(3)
    check(cancellations == 11)
    // Owner cancellation is published before the callback; no callback can revive its result.
    check(session.begin(4))
    check(session.watch(4) {
        check(!session.isActive(4))
        check(session.begin(5))
    })
    session.end(4)
    session.end(4)
    check(session.isActive(5))
}

fun main() {
    decoderChecks()
    imageAppearanceChecks()
    structuredAppendChecks()
    payloadChecks()
    importClassificationChecks()
    imageBoundsChecks()
    ownerSessionChecks()
    println("ProfileQrImport executable checks passed (ZXing 3.5.4, typed profile/subscription, WG/VLESS RAW/WS/gRPC, alpha/polarity/ambiguity/structured-append/payload/bounds/cancellation/session)")
}
