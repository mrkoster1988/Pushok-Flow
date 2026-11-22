package shop.pushok.flow

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import java.io.ByteArrayInputStream
import java.io.InputStream

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

private fun decoderChecks() {
    val size = 600
    check(ProfileQrDecoder.decodePixels(size, size, qr(profile)) == profile)
    val windows = "\uFEFF" + profile.replace("\n", "\r\n")
    check(ProfileQrDecoder.decodePixels(size, size, qr(windows)) == windows.removePrefix("\uFEFF"))
    rejected("PROFILE_QR_NOT_FOUND") {
        ProfileQrDecoder.decodePixels(size, size, IntArray(size * size) { WHITE })
    }
    for (payload in listOf("https://example.invalid/profile", "random text", "eyJjb250YWluZXJzIjpbXX0=",
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
    payloadChecks()
    imageBoundsChecks()
    ownerSessionChecks()
    println("ProfileQrImport executable checks passed (ZXing 3.5.4, payload/bounds/cancellation/session)")
}
