package shop.pushok.flow

internal class FlowAccountFailure(val code: String) : Exception()

internal data class FlowAccountPending(val deviceCode: String, val userCode: String,
    val expiresAt: Long, val nextPollAt: Long, val interval: Int) {
    fun metadata(): Map<String, Any> = mapOf("userCode" to userCode,
        "expiresAt" to expiresAt, "nextPollAt" to nextPollAt)
    override fun toString() = "FlowAccountPending(redacted)"
}

internal data class FlowAccountProfile(val id: String, val displayName: String, val role: String,
    val phoneVerified: Boolean, val wallet: Map<String, Long>) {
    fun metadata(): Map<String, Any> = mapOf("id" to id, "displayName" to displayName,
        "role" to role, "phoneVerified" to phoneVerified, "wallet" to wallet.toMap())
    fun record(): Map<String, Any> = mapOf("id" to id, "display_name" to displayName,
        "role" to role, "phone_verified" to phoneVerified, "wallet" to wallet.toMap())
    override fun toString() = "FlowAccountProfile(redacted)"
}

internal data class FlowAccountSession(val accessToken: String, val expiresAt: Long,
    val profile: FlowAccountProfile? = null, val refreshedAt: Long? = null,
    val loginUserCode: String? = null) {
    override fun toString() = "FlowAccountSession(redacted)"
}

internal data class FlowAccountRecord(val pending: FlowAccountPending? = null,
    val session: FlowAccountSession? = null, val localOwner: String? = null) {
    init { require(pending == null || session == null) }
    fun metadata(now: Long, busy: Boolean = false, error: String? = null): Map<String, Any?> = mapOf(
        "state" to when { session != null -> "connected"; pending != null -> "pending"; else -> "signed_out" },
        "busy" to busy, "errorCode" to error, "pending" to pending?.metadata(),
        "profile" to session?.profile?.metadata(), "refreshedAt" to session?.refreshedAt,
        "sessionExpiresAt" to session?.expiresAt,
        "stale" to (session != null && (session.profile == null || error != null ||
            now - (session.refreshedAt ?: 0) >= 5 * 60_000L))) +
        if (localOwner != null) mapOf("localConnectionAvailable" to true) else emptyMap()
    override fun toString() = "FlowAccountRecord(redacted)"
}

internal object FlowAccountPolicy {
    const val MAX_JSON_BYTES = 32 * 1024
    const val MAX_REQUEST_BYTES = 4096
    const val CHALLENGE_SECONDS = 300
    const val SESSION_SECONDS = 43200
    const val ORIGIN = "https://pushok.shop"
    private val publicCode = Regex("[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{12}")
    private val deviceCode = Regex("pfd_[A-Za-z0-9_-]{43}")
    private val accessToken = Regex("pfa_[a-f0-9]{64}")
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    fun keys(value: Map<String, Any?>, expected: Set<String>) {
        if (value.keys != expected) invalid()
    }
    fun map(value: Any?): Map<String, Any?> {
        if (value !is Map<*, *> || value.keys.any { it !is String }) invalid()
        return value.entries.associate { (key, item) -> (key as String) to item }
    }
    fun number(value: Any?): Long = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> invalid()
    }
    private fun seconds(value: Any?, max: Int): Int = number(value).takeIf { it in 1..max.toLong() }?.toInt() ?: invalid()
    fun timestamp(value: Any?): Long = number(value).takeIf { it in 1..8_640_000_000_000_000L } ?: invalid()
    private fun text(value: Any?, max: Int): String = (value as? String)?.takeIf {
        it.isNotEmpty() && it.length <= max && it.none { char -> char.code < 32 || char.code == 127 }
    } ?: invalid()
    fun requireUserCode(value: String): String = value.takeIf(publicCode::matches) ?: invalid()
    fun requireDeviceCode(value: String): String = value.takeIf(deviceCode::matches) ?: invalid()
    fun requireAccessToken(value: String): String = value.takeIf(accessToken::matches) ?: invalid()
    private fun scopes(value: Any?) {
        if (value !is List<*> || value.size != 2 || value.toSet() != setOf("profile:read", "wallet:read")) invalid()
    }
    fun capabilities(value: Map<String, Any?>) {
        keys(value, setOf("protocol_version", "scopes", "session_ttl_seconds"))
        if (number(value["protocol_version"]) != 1L || number(value["session_ttl_seconds"]) != SESSION_SECONDS.toLong())
            throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
        scopes(value["scopes"])
    }
    fun device(value: Map<String, Any?>, now: Long): FlowAccountPending {
        keys(value, setOf("device_code", "user_code", "expires_in", "interval"))
        val interval = seconds(value["interval"], 60).coerceAtLeast(5)
        return FlowAccountPending(requireDeviceCode(text(value["device_code"], 47)),
            requireUserCode(text(value["user_code"], 12)),
            now + seconds(value["expires_in"], CHALLENGE_SECONDS) * 1000L, now + interval * 1000L, interval)
    }
    fun waiting(value: Map<String, Any?>, pending: FlowAccountPending, now: Long): FlowAccountPending {
        keys(value, setOf("status", "interval", "expires_in"))
        if (value["status"] != "pending") invalid()
        val interval = seconds(value["interval"], 300).coerceAtLeast(5)
        return pending.copy(interval = interval, nextPollAt = now + interval * 1000L,
            expiresAt = minOf(pending.expiresAt, now + seconds(value["expires_in"], CHALLENGE_SECONDS) * 1000L))
    }
    fun authorized(value: Map<String, Any?>, now: Long): FlowAccountSession {
        keys(value, setOf("status", "access_token", "token_type", "expires_in", "scope"))
        if (value["status"] != "authorized" || value["token_type"] != "Bearer") invalid()
        scopes(value["scope"])
        return FlowAccountSession(requireAccessToken(text(value["access_token"], 68)),
            now + seconds(value["expires_in"], SESSION_SECONDS) * 1000L)
    }
    fun profile(value: Map<String, Any?>): FlowAccountProfile {
        keys(value, setOf("id", "display_name", "role", "phone_verified", "wallet"))
        val id = text(value["id"], 36).takeIf(uuid::matches) ?: invalid()
        val role = text(value["role"], 32).takeIf { Regex("[a-z_]+").matches(it) } ?: invalid()
        val verified = value["phone_verified"] as? Boolean ?: invalid()
        val wallet = map(value["wallet"])
        keys(wallet, setOf("RUB", "BONUS", "XTR"))
        return FlowAccountProfile(id, text(value["display_name"], 512), role, verified,
            wallet.mapValues { number(it.value) })
    }
    fun telegram(code: String) = "tg://resolve?domain=mtproxy_pushok_bot&start=flow_${requireUserCode(code)}"
    fun browser(code: String) = "$ORIGIN/?flow=${requireUserCode(code)}"

    fun record(value: FlowAccountRecord): Map<String, Any?> = if (value.localOwner != null) {
        mapOf("version" to 3, "local_owner" to value.localOwner)
    } else mapOf("version" to 2,
        "pending" to value.pending?.let { mapOf("device_code" to it.deviceCode, "user_code" to it.userCode,
            "expires_at" to it.expiresAt, "next_poll_at" to it.nextPollAt, "interval" to it.interval) },
        "session" to value.session?.let { mapOf("access_token" to it.accessToken, "expires_at" to it.expiresAt,
            "profile" to it.profile?.record(), "refreshed_at" to it.refreshedAt,
            "login_user_code" to it.loginUserCode) })

    fun restore(value: Map<String, Any?>): FlowAccountRecord {
        if (number(value["version"]) == 3L) {
            keys(value, setOf("version", "local_owner"))
            val owner = text(value["local_owner"], 36).takeIf(uuid::matches) ?: invalid()
            return FlowAccountRecord(localOwner = owner)
        }
        keys(value, setOf("version", "pending", "session"))
        val version = number(value["version"])
        if (version !in 1L..2L || (value["pending"] != null && value["session"] != null)) invalid()
        val pending = value["pending"]?.let { raw ->
            val item = map(raw)
            keys(item, setOf("device_code", "user_code", "expires_at", "next_poll_at", "interval"))
            FlowAccountPending(requireDeviceCode(text(item["device_code"], 47)),
                requireUserCode(text(item["user_code"], 12)), timestamp(item["expires_at"]),
                timestamp(item["next_poll_at"]), seconds(item["interval"], 300).coerceAtLeast(5))
        }
        val session = value["session"]?.let { raw ->
            val item = map(raw)
            keys(item, setOf("access_token", "expires_at", "profile", "refreshed_at") +
                if (version == 2L) setOf("login_user_code") else emptySet())
            if ((item["profile"] == null) != (item["refreshed_at"] == null)) invalid()
            FlowAccountSession(requireAccessToken(text(item["access_token"], 68)), timestamp(item["expires_at"]),
                item["profile"]?.let { profile(map(it)) }, item["refreshed_at"]?.let(::timestamp),
                if (version == 2L) item["login_user_code"]?.let { requireUserCode(text(it, 12)) } else null)
        }
        return FlowAccountRecord(pending, session)
    }
    private fun invalid(): Nothing = throw FlowAccountFailure("FLOW_PROTOCOL_UNSUPPORTED")
}
