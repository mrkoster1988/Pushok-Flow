package shop.pushok.flow

/** A saved package is checked directly, never inferred from its launcher entry. */
object RouteAppAvailability {
    data class Snapshot(
        val packages: List<String>,
        val unavailablePackages: List<String>,
    ) {
        fun toChannel(): Map<String, List<String>> = mapOf(
            "packages" to packages,
            "unavailablePackages" to unavailablePackages,
        )
    }

    /**
     * [isAvailable] returns false only for Android's NameNotFoundException.
     * Visibility restrictions can produce that result too: it does not prove
     * uninstallation. Any other query failure invalidates the whole snapshot.
     * No saved choice is removed or rewritten by this read-only operation.
     */
    fun inspect(packages: Set<String>, isAvailable: (String) -> Boolean): Snapshot {
        val selected = RouteSettingsStore.validatePackages(packages, "ROUTES_LOAD_FAILED").sorted()
        val unavailable = mutableListOf<String>()
        for (packageName in selected) {
            val available = try { isAvailable(packageName) }
                catch (_: Exception) { throw RouteSettingsFailure("ROUTES_APPS_CHECK_FAILED") }
            if (!available) unavailable.add(packageName)
        }
        return Snapshot(selected, unavailable)
    }

    /** Called inside the session's activation callback, after a fresh known DOWN. */
    fun requireForConnection(packages: Set<String>, isAvailable: (String) -> Boolean) {
        val snapshot = try { inspect(packages, isAvailable) }
            catch (_: RouteSettingsFailure) { throw TunnelConnectionFailure("ROUTES_APPS_CHECK_FAILED") }
        if (snapshot.unavailablePackages.isNotEmpty()) {
            throw TunnelConnectionFailure("ROUTES_APPS_UNAVAILABLE")
        }
    }
}
