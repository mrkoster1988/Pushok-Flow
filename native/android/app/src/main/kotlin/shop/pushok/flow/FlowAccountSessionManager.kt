package shop.pushok.flow

internal interface FlowAccountPersistence {
    fun load(): FlowAccountRecord
    fun save(value: FlowAccountRecord)
}
internal data class FlowAccountResponse(val status: Int, val json: Map<String, Any?> = emptyMap(), val retryAfter: Int? = null) {
    override fun toString() = "FlowAccountResponse($status, redacted)"
}
internal fun interface FlowAccountRemote {
    fun request(method: String, path: String, token: String?, body: Map<String, Any?>?): FlowAccountResponse
}

/** Serial state machine; storage writes and credential publication use the caller's epoch lock.
 * Platform-independent so lost replies, revocation and late-result races are executable tests. */
internal class FlowAccountSessionManager(private val store: FlowAccountPersistence,
    private val now: () -> Long = System::currentTimeMillis) {
    @Volatile var record = FlowAccountRecord(); private set
    private var loaded = false
    private var storageUnavailable = false

    fun load(commit: (() -> Unit) -> Unit) {
        if (storageUnavailable) throw FlowAccountFailure("FLOW_STORE_UNAVAILABLE")
        if (loaded) return
        commit {
            try { record = store.load(); loaded = true }
            catch (_: Exception) { failStorage() }
        }
    }
    private fun save(value: FlowAccountRecord, commit: (() -> Unit) -> Unit) = commit {
        try { store.save(value) }
        catch (_: Exception) { failStorage() }
        record = value
    }
    private fun failStorage(): Nothing {
        // A failed commit has uncertain durability. Do not publish/reuse any cached credential,
        // including after failed logout removal; only a fresh process may read durable state again.
        record = FlowAccountRecord()
        storageUnavailable = true
        throw FlowAccountFailure("FLOW_STORE_UNAVAILABLE")
    }
    fun expire(commit: (() -> Unit) -> Unit) {
        if (record.pending?.let { it.expiresAt <= now() } == true) {
            save(FlowAccountRecord(), commit)
            throw FlowAccountFailure("FLOW_LOGIN_EXPIRED")
        }
        if (record.session?.let { it.expiresAt <= now() } == true) {
            save(FlowAccountRecord(), commit)
            throw FlowAccountFailure("FLOW_SESSION_EXPIRED")
        }
    }
    fun execute(command: String, remote: FlowAccountRemote, commit: (() -> Unit) -> Unit,
        cancelUserCode: String? = null) {
        load(commit)
        if (command !in setOf("logout", "cancelLogin", "beginLogin")) expire(commit)
        when (command) {
            "status" -> Unit
            "beginLogin" -> {
                if (record.session != null && record.session!!.expiresAt > now()) return
                save(FlowAccountRecord(), commit)
                val capabilities = remote.request("GET", "/capabilities", null, null)
                requireSuccess(capabilities, 200)
                FlowAccountPolicy.capabilities(capabilities.json)
                val response = remote.request("POST", "/device", null, emptyMap())
                requireSuccess(response, 201)
                save(FlowAccountRecord(pending = FlowAccountPolicy.device(response.json, now())), commit)
            }
            "pollLogin" -> poll(remote, commit)
            "cancelLogin" -> {
                val code = cancelUserCode?.let(FlowAccountPolicy::requireUserCode)
                    ?: throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
                // The displayed challenge identifies the user's cancellation.
                // It remains attached after token issuance and a lost /me reply,
                // so cancellation can clear that login without touching another.
                if (record.pending?.userCode != code && record.session?.loginUserCode != code) {
                    if (record.pending != null || record.session != null) throw FlowAccountFailure("FLOW_INTERRUPTED")
                } else clearAndRevoke(remote, commit)
            }
            "refresh" -> refresh(remote, commit)
            "logout" -> clearAndRevoke(remote, commit)
            else -> throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
        }
    }
    private fun clearAndRevoke(remote: FlowAccountRemote, commit: (() -> Unit) -> Unit) {
        val token = record.session?.accessToken
        // The local choice commits first and survives a failed or cancelled revoke.
        save(FlowAccountRecord(), commit)
        if (token != null) try {
            val response = remote.request("POST", "/logout", token, emptyMap())
            if (response.status != 204 && response.status != 401) throw FlowAccountFailure("FLOW_LOGOUT_REMOTE_FAILED")
        } catch (_: Exception) { throw FlowAccountFailure("FLOW_LOGOUT_REMOTE_FAILED") }
    }
    private fun poll(remote: FlowAccountRemote, commit: (() -> Unit) -> Unit) {
        val pending = record.pending ?: return
        if (now() < pending.nextPollAt) return
        // Advance durably before sending, including failures/recreation; no tight retry on a lost reply.
        save(FlowAccountRecord(pending = pending.copy(nextPollAt = now() + pending.interval * 1000L)), commit)
        val response = remote.request("POST", "/device/token", null, mapOf("device_code" to pending.deviceCode))
        when (response.status) {
            429 -> {
                val serverInterval = response.json["interval"]?.let { try { FlowAccountPolicy.number(it).toInt() }
                    catch (_: FlowAccountFailure) { null } }
                val delay = maxOf(pending.interval, response.retryAfter ?: 5, serverInterval ?: 5).coerceIn(5, 300)
                save(FlowAccountRecord(pending = pending.copy(nextPollAt = now() + delay * 1000L, interval = delay)), commit)
                throw FlowAccountFailure("FLOW_LOGIN_SLOW_DOWN")
            }
            403, 410 -> {
                save(FlowAccountRecord(), commit)
                throw FlowAccountFailure(if (response.status == 403) "FLOW_LOGIN_DENIED" else "FLOW_LOGIN_EXPIRED")
            }
        }
        requireSuccess(response, 200)
        when (response.json["status"]) {
            "pending" -> save(FlowAccountRecord(pending = FlowAccountPolicy.waiting(response.json, pending, now())), commit)
            "authorized" -> {
                // A lost /me response must never discard an already-issued, durably protected credential.
                save(FlowAccountRecord(session = FlowAccountPolicy.authorized(response.json, now())
                    .copy(loginUserCode = pending.userCode)), commit)
                refresh(remote, commit)
            }
            else -> throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
        }
    }
    private fun refresh(remote: FlowAccountRemote, commit: (() -> Unit) -> Unit) {
        val session = record.session ?: return
        val response = remote.request("GET", "/me", session.accessToken, null)
        if (response.status in setOf(401, 403)) {
            save(FlowAccountRecord(), commit)
            throw FlowAccountFailure(if (response.status == 401) "FLOW_SESSION_EXPIRED" else "FLOW_ACCOUNT_BLOCKED")
        }
        requireSuccess(response, 200)
        save(FlowAccountRecord(session = session.copy(profile = FlowAccountPolicy.profile(response.json), refreshedAt = now())), commit)
    }
    private fun requireSuccess(response: FlowAccountResponse, status: Int) {
        if (response.status == status) return
        throw FlowAccountFailure(when (response.status) {
            404, 405, 501, 503 -> "FLOW_SERVICE_UNAVAILABLE"
            429 -> "FLOW_RATE_LIMITED"
            in 500..599 -> "FLOW_NETWORK_ERROR"
            else -> "FLOW_PROTOCOL_UNSUPPORTED"
        })
    }
}
