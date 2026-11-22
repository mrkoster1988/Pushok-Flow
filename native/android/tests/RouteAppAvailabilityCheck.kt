package shop.pushok.flow

private class SavedRoutes(initial: Set<String>) : RouteSettingsStorage {
    val packages = initial.toSet()
    var writes = 0
    override fun read(): Set<*> = packages
    override fun replace(packages: Set<String>): Boolean { writes++; return true }
}

private fun rejectsRoute(code: String, action: () -> Unit) {
    try { action(); error("Expected $code") }
    catch (failure: RouteSettingsFailure) {
        check(failure.code == code && failure.message == code && failure.cause == null)
    }
}

private fun rejectsConnect(code: String, action: () -> Unit) {
    try { action(); error("Expected $code") }
    catch (failure: TunnelConnectionFailure) {
        check(failure.code == code && failure.message == code && failure.cause == null)
    }
}

private fun withSession(action: (TunnelConnectionSession) -> Unit) {
    val session = TunnelConnectionSession(nowElapsedMs = { 1000L })
    try { action(session) } finally { session.io.shutdownNow() }
}

fun main() {
    val selected = setOf("com.example.unavailable_z", "com.example.browser",
        "com.example.no_launcher", "com.example.unavailable_a")
    val storage = SavedRoutes(selected)
    val store = RouteSettingsStore(storage, RouteSettingsState())
    val available = mutableSetOf("com.example.browser", "com.example.no_launcher")
    val queries = mutableListOf<String>()
    val query = { packageName: String -> queries.add(packageName); available.contains(packageName) }
    val snapshot = RouteAppAvailability.inspect(store.read(), query)
    check(snapshot.packages == selected.sorted())
    check(snapshot.unavailablePackages == listOf("com.example.unavailable_a", "com.example.unavailable_z"))
    check(queries == selected.sorted())
    check("com.example.no_launcher" !in snapshot.unavailablePackages)
    check(snapshot.toChannel().keys == setOf("packages", "unavailablePackages"))
    check(snapshot.toChannel()["packages"] == selected.sorted())
    check(store.read() == selected && storage.writes == 0)

    // Returning/reinstalled apps are rechecked. The old unavailable snapshot
    // remains independent, and no saved exclusion needs to be recreated.
    available.addAll(selected)
    val returned = RouteAppAvailability.inspect(store.read(), query)
    check(returned.unavailablePackages.isEmpty())
    check(snapshot.unavailablePackages.size == 2)
    check(store.read() == selected && storage.writes == 0)
    val empty = RouteAppAvailability.inspect(emptySet()) { error("Must not query empty selection") }
    check(empty.packages.isEmpty() && empty.unavailablePackages.isEmpty())

    // A failed PackageManager read is not evidence that an app disappeared.
    // Do not expose a partially collected unavailable list or raw exception.
    var partial: RouteAppAvailability.Snapshot? = null
    rejectsRoute("ROUTES_APPS_CHECK_FAILED") {
        partial = RouteAppAvailability.inspect(setOf("com.example.a", "com.example.z")) {
            if (it.endsWith(".a")) false else throw SecurityException("PRIVATE_QUERY_DETAIL")
        }
    }
    check(partial == null)
    rejectsRoute("ROUTES_LOAD_FAILED") {
        RouteAppAvailability.inspect(setOf("PRIVATE_BAD_PACKAGE")) { error("Invalid package queried") }
    }

    // Production availability guard prevents activation without rewriting the
    // stored list. Both unavailable and indeterminate queries have fixed codes.
    for (failedQuery in listOf(false, true)) withSession { session ->
        var activations = 0
        val code = if (failedQuery) "ROUTES_APPS_CHECK_FAILED" else "ROUTES_APPS_UNAVAILABLE"
        rejectsConnect(code) {
            session.connect({ false }) {
                RouteAppAvailability.requireForConnection(store.read()) {
                    if (failedQuery) error("PRIVATE_PACKAGE_MANAGER_DETAIL") else false
                }
                activations++
                true
            }
        }
        check(activations == 0 && !session.connected && session.connectedSinceElapsedMs == null)
        check(session.lastErrorCode == code)
        check(store.read() == selected && storage.writes == 0)
        // Restoring availability permits a deliberate retry; no auto-retry or
        // silent filtering occurs inside either the helper or the session.
        check(session.connect({ false }) {
            RouteAppAvailability.requireForConnection(store.read()) { true }
            activations++
            true
        })
        check(activations == 1 && session.lastErrorCode == null)
    }

    // The callback is reached only for known DOWN. An already-UP Connect keeps
    // the existing session/uptime, even if an excluded app has since vanished.
    withSession { session ->
        var actual = false
        var queriesForConnection = 0
        var activations = 0
        val activate = {
            RouteAppAvailability.requireForConnection(store.read()) { queriesForConnection++; true }
            activations++
            actual = true
            true
        }
        check(session.connect({ actual }, activate))
        val queried = queriesForConnection
        check(session.connect({ actual }) {
            RouteAppAvailability.requireForConnection(store.read()) { queriesForConnection++; false }
            error("Repeated UP must not activate")
        })
        check(queriesForConnection == queried && activations == 1)
        check(session.connectedSinceElapsedMs == 1000L)
        rejectsConnect("VPN_STATE_UNAVAILABLE") {
            session.connect({ error("PRIVATE_STATE_ERROR") }) {
                RouteAppAvailability.requireForConnection(store.read()) { queriesForConnection++; false }
                error("Unknown state must not activate")
            }
        }
        check(queriesForConnection == queried && session.connected)
        session.disconnect({ error("PRIVATE_STATE_ERROR") }) { actual = false; false }
        check(!actual && !session.connected && queriesForConnection == queried)
    }

    // The backend can fail with the same fixed diagnosis after preflight (for
    // example an uninstall race). Reconcile actual state, even if rollback is UP.
    withSession { session ->
        var actual = false
        rejectsConnect("ROUTES_APPS_UNAVAILABLE") {
            session.connect({ actual }) {
                RouteAppAvailability.requireForConnection(store.read()) { true }
                actual = true
                throw TunnelConnectionFailure("ROUTES_APPS_UNAVAILABLE")
            }
        }
        check(session.connected && session.connectedSinceElapsedMs == null)
        check(session.lastErrorCode == "ROUTES_APPS_UNAVAILABLE")
    }
    withSession { session ->
        rejectsConnect("WG_CONNECT_FAILED") {
            session.connect({ false }) { throw TunnelConnectionFailure("PRIVATE_BACKEND_DETAIL") }
        }
        check(session.lastErrorCode == "WG_CONNECT_FAILED")
    }
    println("RouteAppAvailability snapshots, connection guards and recovery checks passed")
}
