package shop.pushok.flow

/** Route settings remain local; errors never include app lists or channel payloads. */
class RouteSettingsFailure(val code: String) : Exception(code)

interface RouteSettingsStorage {
    fun read(): Set<*>
    fun replace(packages: Set<String>): Boolean
}

/** Shared by every Activity/store in this process, like SharedPreferences' memory map. */
class RouteSettingsState {
    internal val lock = Any()
    internal var writeFailed = false
}

class RouteSettingsRequest private constructor(
    val packages: Set<String>,
    val expectedPackages: Set<String>?,
) {
    companion object {
        fun parse(arguments: Any?): RouteSettingsRequest {
            val values = arguments as? Map<*, *> ?: throw RouteSettingsFailure("INVALID_PACKAGES")
            if (values.keys.any { it != "packages" && it != "expectedPackages" }) {
                throw RouteSettingsFailure("INVALID_PACKAGES")
            }
            val packages = values["packages"] as? List<*>
                ?: throw RouteSettingsFailure("INVALID_PACKAGES")
            val expected = if (values.containsKey("expectedPackages")) {
                val list = values["expectedPackages"] as? List<*>
                    ?: throw RouteSettingsFailure("INVALID_PACKAGES")
                RouteSettingsStore.validatePackages(list, "INVALID_PACKAGES")
            } else null
            return RouteSettingsRequest(RouteSettingsStore.validatePackages(packages, "INVALID_PACKAGES"), expected)
        }
    }
}

/** Serializes reads/CAS/writes; the caller also owns the tunnel operation lease on mutations. */
class RouteSettingsStore(
    private val storage: RouteSettingsStorage,
    private val state: RouteSettingsState,
) {
    companion object {
        const val MAX_PACKAGES = 4096
        const val MAX_PACKAGE_LENGTH = 255
        private val packagePattern = Regex("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")

        fun isValidPackageName(value: Any?): Boolean = value is String &&
            value.length <= MAX_PACKAGE_LENGTH && packagePattern.matches(value)

        fun validatePackages(values: Collection<*>, code: String): Set<String> {
            if (values.size > MAX_PACKAGES) throw RouteSettingsFailure(code)
            val result = linkedSetOf<String>()
            for (value in values) {
                if (!isValidPackageName(value) || !result.add(value as String)) {
                    throw RouteSettingsFailure(code)
                }
            }
            return result
        }
    }

    private fun readLocked(): Set<String> {
        if (state.writeFailed) throw RouteSettingsFailure("ROUTES_STORE_UNAVAILABLE")
        return try { validatePackages(storage.read(), "ROUTES_LOAD_FAILED") }
            catch (_: Exception) { throw RouteSettingsFailure("ROUTES_LOAD_FAILED") }
    }

    fun read(): Set<String> = synchronized(state.lock) { readLocked() }

    fun replace(request: RouteSettingsRequest) = synchronized(state.lock) {
        val current = readLocked()
        val packages = validatePackages(request.packages, "INVALID_PACKAGES")
        val expected = request.expectedPackages?.let { validatePackages(it, "INVALID_PACKAGES") }
        if (expected != null && expected != current) throw RouteSettingsFailure("ROUTES_CHANGED")
        if (packages == current) return@synchronized
        // Never filter against installed/launcher apps: an unavailable app may return later.
        val written = try { storage.replace(packages.toSet()) } catch (_: Exception) { false }
        if (!written) {
            // Android can change its RAM map before a commit fails. No later Activity
            // or connect action may mistake those uncommitted choices for durable settings.
            state.writeFailed = true
            throw RouteSettingsFailure("ROUTES_STORE_UNAVAILABLE")
        }
    }
}

/** Launcher labels are third-party text; keep the channel result bounded and single-line. */
object RouteAppLabels {
    const val MAX_CODE_POINTS = 1024

    fun normalize(raw: CharSequence, fallback: String): String {
        val result = StringBuilder()
        var offset = 0
        var count = 0
        while (offset < raw.length && count < MAX_CODE_POINTS) {
            val codePoint = Character.codePointAt(raw, offset)
            offset += Character.charCount(codePoint)
            count++
            if (codePoint in 0..31 || codePoint in 127..159 ||
                codePoint in 0xD800..0xDFFF || codePoint == 0x2028 || codePoint == 0x2029) {
                result.append(' ')
            } else result.appendCodePoint(codePoint)
        }
        // Dart String.trim also treats a boundary BOM as whitespace.
        return result.toString().trim { it.isWhitespace() || it == '\uFEFF' }.ifEmpty { fallback }
    }
}
