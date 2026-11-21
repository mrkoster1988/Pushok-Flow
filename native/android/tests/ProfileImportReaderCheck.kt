package shop.pushok.flow

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets.UTF_8

private fun invalid(bytes: ByteArray, code: String = "PROFILE_IMPORT_INVALID") {
    try {
        ProfileImportReader.read(ByteArrayInputStream(bytes))
        error("Expected import rejection")
    } catch (failure: ProfileImportReader.Failure) {
        check(failure.code == code)
    }
}

fun main() {
    val text = "[Interface]\r\n# Тестовый профиль\r\nPrivateKey = placeholder\r\n[Peer]\r\n"
    check(ProfileImportReader.read(ByteArrayInputStream(text.toByteArray(UTF_8))) == text)
    check(ProfileImportReader.read(ByteArrayInputStream(("\uFEFF" + text).toByteArray(UTF_8))) == text)
    val max = ByteArray(ProfileImportReader.MAX_BYTES) { 'x'.code.toByte() }
    check(ProfileImportReader.read(ByteArrayInputStream(max)).length == ProfileImportReader.MAX_BYTES)
    invalid(max + byteArrayOf('x'.code.toByte()), "PROFILE_IMPORT_TOO_LARGE")
    invalid(byteArrayOf())
    invalid("\uFEFF \t\r\n".toByteArray(UTF_8))
    invalid("prefix\u0000suffix".toByteArray(UTF_8))
    invalid("prefix\u001Bsuffix".toByteArray(UTF_8))
    invalid("prefix\u007Fsuffix".toByteArray(UTF_8))
    invalid(byteArrayOf(0xC3.toByte(), 0x28))
    invalid(byteArrayOf(0xE2.toByte(), 0x82.toByte()))
    invalid(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0, 0))
    // A multibyte character straddling the byte limit remains an oversized input,
    // not a silently truncated or replacement-character profile.
    invalid(ByteArray(ProfileImportReader.MAX_BYTES - 1) { 'x'.code.toByte() } +
        "Ж".toByteArray(UTF_8), "PROFILE_IMPORT_TOO_LARGE")

    var reads = 0
    val endless = object : InputStream() {
        override fun read(): Int { reads++; return 'x'.code }
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            bytes.fill('x'.code.toByte(), offset, offset + length)
            reads += length
            return length
        }
    }
    try {
        ProfileImportReader.read(endless)
        error("Expected bounded read rejection")
    } catch (failure: ProfileImportReader.Failure) {
        check(failure.code == "PROFILE_IMPORT_TOO_LARGE")
        check(reads == ProfileImportReader.MAX_BYTES + 1)
    }

    var cancelledReads = 0
    val forbidden = object : InputStream() {
        override fun read(): Int { cancelledReads++; return 'x'.code }
    }
    try {
        ProfileImportReader.read(forbidden) { true }
        error("Expected cancellation")
    } catch (failure: ProfileImportReader.Failure) {
        check(failure.code == "PROFILE_IMPORT_INTERRUPTED")
        check(cancelledReads == 0)
    }

    var cancel = false
    val cancelDuringRead = object : ByteArrayInputStream(text.toByteArray(UTF_8)) {
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            val amount = super.read(bytes, offset, minOf(length, 4))
            cancel = true
            return amount
        }
    }
    try {
        ProfileImportReader.read(cancelDuringRead) { cancel }
        error("Expected cancellation during read")
    } catch (failure: ProfileImportReader.Failure) {
        check(failure.code == "PROFILE_IMPORT_INTERRUPTED")
    }

    val zeroThenData = object : ByteArrayInputStream(text.toByteArray(UTF_8)) {
        private var zero = true
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            if (zero) { zero = false; return 0 }
            return super.read(bytes, offset, length)
        }
    }
    check(ProfileImportReader.read(zeroThenData) == text)
    println("ProfileImportReader executable checks passed")
}
