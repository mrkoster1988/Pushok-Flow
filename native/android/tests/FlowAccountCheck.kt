package shop.pushok.flow

private class AccountMemoryStore : FlowAccountPersistence {
    var value = FlowAccountRecord()
    var rejectSession = false
    var rejectClear = false
    override fun load() = FlowAccountPolicy.restore(FlowAccountPolicy.record(value))
    override fun save(value: FlowAccountRecord) {
        if (rejectSession && value.session != null) throw FlowAccountFailure("FLOW_STORE_UNAVAILABLE")
        if (rejectClear && value.session == null && value.pending == null) throw FlowAccountFailure("FLOW_STORE_UNAVAILABLE")
        this.value = FlowAccountPolicy.restore(FlowAccountPolicy.record(value))
    }
}

fun main() {
    var now = 1_800_000_000_000L
    val commit: (() -> Unit) -> Unit = { it() }
    val secret = "pfd_" + "a".repeat(43)
    val token = "pfa_" + "b".repeat(64)
    val code = "2345ABCDEFGH"
    val capabilities = mapOf("protocol_version" to 1, "scopes" to listOf("profile:read", "wallet:read"),
        "session_ttl_seconds" to 43200)
    val device = mapOf("device_code" to secret, "user_code" to code, "expires_in" to 300, "interval" to 5)
    val authorized = mapOf("status" to "authorized", "access_token" to token, "token_type" to "Bearer",
        "expires_in" to 43200, "scope" to listOf("profile:read", "wallet:read"))
    val profile = mapOf("id" to "12345678-1234-1234-1234-123456789abc", "display_name" to "Аккаунт",
        "role" to "admin", "phone_verified" to true, "wallet" to mapOf("RUB" to -101L, "BONUS" to 0L, "XTR" to 42L))
    fun failure(code: String, action: () -> Unit) {
        try { action(); error("Expected $code") }
        catch (error: FlowAccountFailure) { check(error.code == code) { "Expected $code, got ${error.code}" } }
    }
    val memory = AccountMemoryStore()
    val manager = FlowAccountSessionManager(memory) { now }
    val calls = mutableListOf<String>()
    var meStatus = 200
    var networkMe = false
    var tokenResponse = FlowAccountResponse(200, mapOf("status" to "pending", "interval" to 5, "expires_in" to 295))
    val remote = FlowAccountRemote { method, path, bearer, body ->
        calls.add(path)
        when (path) {
            "/capabilities" -> { check(method == "GET" && bearer == null && body == null); FlowAccountResponse(200, capabilities) }
            "/device" -> { check(method == "POST" && bearer == null && body == emptyMap<String, Any?>()); FlowAccountResponse(201, device) }
            "/device/token" -> { check(bearer == null && body == mapOf("device_code" to secret)); tokenResponse }
            "/me" -> {
                check(method == "GET" && bearer == token && body == null)
                // Protection must precede profile fetch, including a crash/lost /me response.
                check(memory.value.session?.accessToken == token)
                if (networkMe) throw FlowAccountFailure("FLOW_NETWORK_ERROR")
                FlowAccountResponse(meStatus, profile)
            }
            "/logout" -> { check(method == "POST" && bearer == token && memory.value.session == null); FlowAccountResponse(204) }
            else -> error("Unexpected account endpoint")
        }
    }
    manager.execute("beginLogin", remote, commit)
    check(calls == listOf("/capabilities", "/device"))
    check(memory.value.pending?.deviceCode == secret)
    check(manager.record.metadata(now)["state"] == "pending")
    check(!manager.record.metadata(now).toString().contains(secret))
    check(!manager.record.toString().contains(secret) && !manager.record.pending.toString().contains(secret))
    manager.execute("pollLogin", remote, commit)
    check(calls.size == 2) // The native layer enforces cadence, even if Flutter calls too early.
    now += 5000
    manager.execute("pollLogin", remote, commit)
    check(calls.last() == "/device/token" && manager.record.pending!!.nextPollAt == now + 5000)

    // Recreating the process keeps only one challenge and respects the saved poll interval.
    var resumed = FlowAccountSessionManager(memory) { now }
    resumed.execute("status", remote, commit)
    check(resumed.record.pending == manager.record.pending)
    now += 5000
    tokenResponse = FlowAccountResponse(429, mapOf("error" to "slow_down", "interval" to 10), 20)
    failure("FLOW_LOGIN_SLOW_DOWN") { resumed.execute("pollLogin", remote, commit) }
    check(resumed.record.pending!!.nextPollAt == now + 20_000)
    now += 20_000
    tokenResponse = FlowAccountResponse(200, authorized)
    memory.rejectSession = true
    failure("FLOW_STORE_UNAVAILABLE") { resumed.execute("pollLogin", remote, commit) }
    check(resumed.record == FlowAccountRecord() && memory.value.pending != null)
    failure("FLOW_STORE_UNAVAILABLE") { resumed.execute("pollLogin", remote, commit) }
    memory.rejectSession = false
    resumed = FlowAccountSessionManager(memory) { now }
    now += 20_000
    networkMe = true
    failure("FLOW_NETWORK_ERROR") { resumed.execute("pollLogin", remote, commit) }
    check(resumed.record.session?.accessToken == token && memory.value.session != null)
    check(resumed.record.metadata(now)["state"] == "connected" && resumed.record.metadata(now)["stale"] == true)
    check(!resumed.record.metadata(now).toString().contains(token))

    val connected = FlowAccountSessionManager(memory) { now }
    networkMe = false
    connected.execute("refresh", remote, commit)
    check(connected.record.session!!.profile!!.wallet["RUB"] == -101L)
    check(connected.record.session!!.profile!!.wallet["XTR"] == 42L)
    check(connected.record.session!!.profile!!.role == "admin") // Display role never grants admin credentials/scopes.
    val cached = connected.record
    networkMe = true
    failure("FLOW_NETWORK_ERROR") { connected.execute("refresh", remote, commit) }
    check(connected.record == cached && memory.value == cached)
    networkMe = false
    meStatus = 401
    failure("FLOW_SESSION_EXPIRED") { connected.execute("refresh", remote, commit) }
    check(memory.value.session == null && connected.record.session == null)

    // A late successful token response cannot reattach after cancel/logout/new login wins the epoch.
    val raceStore = AccountMemoryStore()
    val race = FlowAccountSessionManager(raceStore) { now }
    race.execute("beginLogin", remote, commit)
    now += 5000
    var valid = true
    val oldCommit: (() -> Unit) -> Unit = { change ->
        if (!valid) throw FlowAccountFailure("FLOW_INTERRUPTED")
        change()
    }
    val late = FlowAccountRemote { _, path, _, _ ->
        check(path == "/device/token")
        valid = false
        race.execute("cancelLogin", remote, commit)
        FlowAccountResponse(200, authorized)
    }
    failure("FLOW_INTERRUPTED") { race.execute("pollLogin", late, oldCommit) }
    check(race.record.pending == null && race.record.session == null && raceStore.value.session == null)

    val logoutStore = AccountMemoryStore().apply { value = cached }
    val logout = FlowAccountSessionManager(logoutStore) { now }
    failure("FLOW_LOGOUT_REMOTE_FAILED") {
        logout.execute("logout", FlowAccountRemote { _, path, bearer, _ ->
            check(path == "/logout" && bearer == token)
            check(logoutStore.value.session == null && logout.record.session == null)
            throw FlowAccountFailure("FLOW_NETWORK_ERROR")
        }, commit)
    }
    check(logoutStore.value == FlowAccountRecord())

    val brokenStore = AccountMemoryStore().apply { value = cached; rejectClear = true }
    val brokenLogout = FlowAccountSessionManager(brokenStore) { now }
    failure("FLOW_STORE_UNAVAILABLE") { brokenLogout.execute("logout", remote, commit) }
    check(brokenLogout.record == FlowAccountRecord())
    val callCount = calls.size
    failure("FLOW_STORE_UNAVAILABLE") { brokenLogout.execute("refresh", remote, commit) }
    check(calls.size == callCount) // A poisoned store cannot reuse the pre-logout token.

    val expiredStore = AccountMemoryStore().apply { value = FlowAccountRecord(pending =
        FlowAccountPolicy.device(device, now - 301_000)) }
    val expired = FlowAccountSessionManager(expiredStore) { now }
    failure("FLOW_LOGIN_EXPIRED") { expired.execute("status", remote, commit) }
    check(expiredStore.value == FlowAccountRecord())
    val oldServer = FlowAccountSessionManager(AccountMemoryStore()) { now }
    failure("FLOW_SERVICE_UNAVAILABLE") { oldServer.execute("beginLogin", FlowAccountRemote { _, _, _, _ -> FlowAccountResponse(404) }, commit) }

    check(FlowAccountPolicy.telegram(code) == "tg://resolve?domain=mtproxy_pushok_bot&start=flow_$code")
    check(FlowAccountPolicy.browser(code) == "https://pushok.shop/?flow=$code")
    for (bad in listOf(secret, token, "https://evil.invalid", "2345ABCDEFG0", "$code&token=x"))
        failure("FLOW_PROTOCOL_UNSUPPORTED") { FlowAccountPolicy.telegram(bad) }
    failure("FLOW_PROTOCOL_UNSUPPORTED") { FlowAccountPolicy.authorized(authorized + ("scope" to listOf("admin")), now) }
    failure("FLOW_PROTOCOL_UNSUPPORTED") { FlowAccountPolicy.authorized(authorized + ("cabinet_token" to "secret"), now) }
    failure("FLOW_PROTOCOL_UNSUPPORTED") { FlowAccountPolicy.device(device + ("verification_uri" to "https://evil.invalid"), now) }
    failure("FLOW_PROTOCOL_UNSUPPORTED") { FlowAccountPolicy.profile(profile + ("phone" to "+123")) }
    failure("FLOW_PROTOCOL_UNSUPPORTED") { FlowAccountPolicy.profile(profile + ("wallet" to mapOf("RUB" to 1.2, "BONUS" to 0, "XTR" to 0))) }
    failure("FLOW_PROTOCOL_UNSUPPORTED") { FlowAccountPolicy.profile(profile + ("display_name" to "name\nsecret")) }
    check(cached.metadata(now).keys == setOf("state", "busy", "errorCode", "pending", "profile", "refreshedAt", "sessionExpiresAt", "stale"))
    check(cached.metadata(now)["profile"] == cached.session!!.profile!!.metadata())
    println("Flow account bounded schema, native secret boundary, durable login, expiry, logout and stale-response checks passed")
}
