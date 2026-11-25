package shop.pushok.flow

/** Validated metadata only. Ticket, phone ID and bearer feed URL remain native. */
internal class FlowShopFailure(val code: String) : Exception(code)

internal object FlowShopBridgePolicy {
    const val TICKET_URL = "https://pushok.shop/api/v1/flow/shop-ticket"
    const val EXCHANGE_URL = "https://pushok.shop/shop/api/flow/bridge/exchange"
    private val ticket = Regex("psb1\\.[A-Za-z0-9_-]{20,720}\\.[a-f0-9]{64}")
    private val states = setOf("active", "pending", "expired", "revoked", "disabled",
        "unavailable", "link_disabled")

    class Reply(val state: String, val url: String?) {
        override fun toString() = "FlowShopBridgePolicy.Reply($state, redacted)"
    }

    fun requireTicket(value: Map<String, Any?>): String {
        if (value.keys != setOf("ticket", "expires_in")) invalid()
        val expires = value["expires_in"]
        if ((expires !is Int && expires !is Long) || (expires as Number).toLong() != 60L) invalid()
        val token = value["ticket"] as? String ?: invalid()
        if (!ticket.matches(token)) invalid()
        return token
    }

    fun parseExchange(value: Map<String, Any?>): Reply {
        if (value.keys != setOf("status", "subscription_url")) invalid()
        val state = value["status"] as? String ?: invalid()
        if (state !in states) invalid()
        val raw = value["subscription_url"]
        if (state == "active") {
            val url = raw as? String ?: invalid()
            if (url.length > 4096 || !url.startsWith("https://")) invalid()
            return Reply(state, url)
        }
        if (raw != null) invalid()
        return Reply(state, null)
    }

    /**
     * HTTP 409 is not proof that another phone owns a peer. The MTProxy proof
     * can also be replayed or the identity mapping can conflict. Read only
     * fixed server codes, never display arbitrary API error strings.
     * Legacy server strings are accepted for a safe rolling deployment.
     */
    fun conflictCode(value: Map<String, Any?>): String {
        if (value.keys != setOf("detail")) return "SHOP_CONFLICT"
        val detail = value["detail"]
        val remote = when (detail) {
            is String -> detail
            is Map<*, *> ->
                if (detail.keys == setOf("code")) detail["code"] as? String else null
            else -> null
        }
        return when (remote) {
            "FLOW_DEVICE_BOUND", "Подключение уже привязано к другому устройству" ->
                "SHOP_DEVICE_BOUND"
            "FLOW_PROOF_REPLAY", "Подтверждение уже использовано" ->
                "SHOP_PROOF_REPLAY"
            "FLOW_IDENTITY_CONFLICT", "Для аккаунта требуется проверка привязки",
            "Привязка аккаунтов изменилась" -> "SHOP_IDENTITY_CONFLICT"
            else -> "SHOP_CONFLICT"
        }
    }

    private fun invalid(): Nothing = throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
}
