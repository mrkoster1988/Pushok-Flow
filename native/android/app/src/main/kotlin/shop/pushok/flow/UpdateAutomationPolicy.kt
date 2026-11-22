package shop.pushok.flow

/** Decisions that do not depend on Android, including the CONNECTING/commit race. */
internal object UpdateAutomationPolicy {
    const val WORK_BUDGET_MS = 9 * 60_000L
    const val INSTALL_TIMEOUT_MS = 15 * 60_000L

    fun downloadPercent(received: Long, total: Long): Int {
        if (total !in 1..UpdatePolicy.MAX_APK_BYTES || received !in 0..total) {
            throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
        }
        return (received * 100 / total).toInt()
    }

    fun waitingReason(enabled: Boolean, sdk: Int, permission: Boolean,
        confirmation: Boolean, connection: Boolean, foreground: Boolean): String? = when {
        !enabled -> null
        sdk < 31 -> "unsupported"
        !permission -> "permission"
        confirmation -> "confirmation"
        connection -> "connection"
        foreground -> "foreground"
        else -> null
    }

    /** A range request may legally receive the complete body; never append that 200. */
    fun appendResponse(offset: Long, total: Long, status: Int,
        contentRange: String?, contentLength: Long): Boolean {
        if (offset !in 0..total || total !in 1..UpdatePolicy.MAX_APK_BYTES) {
            throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
        }
        if (status == 200) {
            if (contentLength >= 0 && contentLength != total) throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
            return false
        }
        if (status != 206 || offset == 0L) throw UpdateFailure("UPDATE_NETWORK_ERROR")
        val range = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(contentRange.orEmpty())
            ?: throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
        val start = range.groupValues[1].toLongOrNull()
        val end = range.groupValues[2].toLongOrNull()
        val size = range.groupValues[3].toLongOrNull()
        if (start != offset || end != total - 1 || size != total ||
            (contentLength >= 0 && contentLength != total - offset)) {
            throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
        }
        return true
    }

    fun retry(code: String?, attempt: Int): Boolean = attempt < 5 && code in setOf(
        "UPDATE_NETWORK_ERROR", "UPDATE_DOWNLOAD_FAILED", "UPDATE_INTERRUPTED", "UPDATE_RATE_LIMITED", "UPDATE_BUSY",
        "UPDATE_SCHEDULER_UNAVAILABLE")
}

/** A process-wide lock shared by both VPN engines and automatic installation.
 * A reservation survives commit until Android reports completion or a waiting session is abandoned. */
internal class UpdateAutomationGuard {
    private val foregroundOwners = mutableSetOf<Any>()
    private val connections = mutableSetOf<Long>()
    private var tunnelUnsafe = false
    private var installing = false

    @Synchronized fun foreground(owner: Any, value: Boolean) {
        if (value) foregroundOwners.add(owner) else foregroundOwners.remove(owner)
    }
    @Synchronized fun isForeground(): Boolean = foregroundOwners.isNotEmpty()
    @Synchronized fun connectionUnsafe(): Boolean = tunnelUnsafe || connections.isNotEmpty()
    @Synchronized fun observeTunnel(upOrUnknown: Boolean) { tunnelUnsafe = upOrUnknown }
    @Synchronized fun beginConnection(token: Long): Boolean {
        if (installing) return false
        connections.add(token)
        return true
    }
    @Synchronized fun endConnection(token: Long) { connections.remove(token) }
    @Synchronized fun reserveInstall(vpnPresentOrUnknown: () -> Boolean): Boolean {
        if (installing || foregroundOwners.isNotEmpty() || connectionUnsafe() || vpnPresentOrUnknown()) return false
        installing = true
        return true
    }
    @Synchronized fun restoreInstallReservation() { installing = true }
    @Synchronized fun releaseInstall() { installing = false }
    @Synchronized fun isInstalling(): Boolean = installing
    /** Commit's final gate and a connection acquisition use this same monitor. */
    @Synchronized fun commitIfSafe(vpnPresentOrUnknown: () -> Boolean, commit: () -> Unit): Boolean {
        if (!installing || foregroundOwners.isNotEmpty() || connectionUnsafe() || vpnPresentOrUnknown()) return false
        commit()
        return true
    }
}
