package shop.pushok.flow

/** Validated metadata only. Ticket, phone ID and bearer feed URL remain native. */
internal class FlowShopFailure(val code: String) : Exception(code)

internal object FlowShopBridgePolicy {
    const val TICKET_URL = "https://pushok.shop/api/v1/flow/shop-ticket"
    const val EXCHANGE_URL = "https://pushok.shop/shop/api/flow/bridge/exchange"
    private val ticket = Regex("psb1\\.[A-Za-z0-9_-]{20,720}\\.[a-f0-9]{64}")
    private val clientId = Regex("pfc_[A-Za-z0-9_-]{43}")
    private val states = setOf("active", "pending", "expired", "revoked", "disabled",
        "unavailable", "link_disabled")

    class Reply(val state: String, val url: String?) {
        override fun toString() = "FlowShopBridgePolicy.Reply($state, redacted)"
    }

    fun validClientId(value: String): Boolean = clientId.matches(value)

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

    private fun invalid(): Nothing = throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
}
