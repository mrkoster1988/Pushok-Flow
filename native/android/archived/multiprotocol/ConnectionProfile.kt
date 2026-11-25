package shop.pushok.flow

import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/** A public, constant error vocabulary. Never attach parser errors or their raw input. */
class ProfileFormatFailure(code: String) : Exception() {
    val code = code.takeIf { it in SAFE_CODES } ?: "PROFILE_IMPORT_INVALID"

    companion object {
        val SAFE_CODES = setOf("PROFILE_IMPORT_INVALID", "PROFILE_IMPORT_TOO_LARGE", "INVALID_VLESS_CONFIG",
            "UNSUPPORTED_PROFILE", "UNSUPPORTED_TRANSPORT",
            "UNSUPPORTED_SECURITY", "UNSUPPORTED_PROFILE_OPTION")
    }

    override fun toString() = "ProfileFormatFailure($code)"
}

/** Local-only format detection; no URL in a profile is fetched during import. */
object ConnectionProfile {
    enum class Kind { WIREGUARD, VLESS }

    fun kind(raw: String): Kind {
        val text = boundedText(raw)
        if (text.startsWith("vless://", ignoreCase = true)) return Kind.VLESS
        if (Regex("^[A-Za-z][A-Za-z0-9+.-]*:").containsMatchIn(text)) {
            throw ProfileFormatFailure("UNSUPPORTED_PROFILE")
        }
        return Kind.WIREGUARD
    }

    /** WireGuard's complete grammar must still be checked with the native Config.parse. */
    fun validateShape(raw: String): Kind {
        val type = kind(raw)
        if (type == Kind.VLESS) {
            VlessProfile.parse(raw)
        } else {
            val text = boundedText(raw)
            if (!Regex("(?m)^\\s*\\[Interface]\\s*(?:#.*)?$").containsMatchIn(text) ||
                !Regex("(?m)^\\s*\\[Peer]\\s*(?:#.*)?$").containsMatchIn(text)) {
                throw ProfileFormatFailure("PROFILE_IMPORT_INVALID")
            }
        }
        return type
    }

    internal fun boundedText(raw: String): String {
        if (raw.length > ProfileImportReader.MAX_BYTES) {
            throw ProfileFormatFailure("PROFILE_IMPORT_TOO_LARGE")
        }
        val bytes = try {
            StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(raw))
        } catch (_: Exception) { throw ProfileFormatFailure("PROFILE_IMPORT_INVALID") }
        try {
            if (bytes.remaining() > ProfileImportReader.MAX_BYTES) {
                throw ProfileFormatFailure("PROFILE_IMPORT_TOO_LARGE")
            }
        } finally { if (bytes.hasArray()) bytes.array().fill(0) }
        if (raw.any { (it.code < 32 && it != '\n' && it != '\r' && it != '\t') || it.code == 127 }) {
            throw ProfileFormatFailure("PROFILE_IMPORT_INVALID")
        }
        val text = raw.removePrefix("\uFEFF").trim()
        if (text.isEmpty()) throw ProfileFormatFailure("PROFILE_IMPORT_INVALID")
        return text
    }
}
