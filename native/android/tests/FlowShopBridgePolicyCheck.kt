package shop.pushok.flow

fun main() {
    val validTicket = "psb1." + "a".repeat(150) + "." + "f".repeat(64)
    check(FlowShopBridgePolicy.requireTicket(mapOf("ticket" to validTicket,
        "expires_in" to 60)) == validTicket)
    for (data in listOf<Map<String, Any?>>(
        emptyMap(), mapOf("ticket" to validTicket),
        mapOf("ticket" to validTicket, "expires_in" to 61),
        mapOf("ticket" to validTicket, "expires_in" to true),
        mapOf("ticket" to "not-a-ticket", "expires_in" to 60),
        mapOf("ticket" to validTicket, "expires_in" to 60, "user_id" to "fake"),
    )) {
        try { FlowShopBridgePolicy.requireTicket(data); error("accepted malformed ticket") }
        catch (failure: FlowShopFailure) { check(failure.code == "SHOP_PROTOCOL_INVALID") }
    }
    check(FlowShopBridgePolicy.validClientId("pfc_" + "A".repeat(43)))
    check(!FlowShopBridgePolicy.validClientId("pfc_" + "A".repeat(42)))
    val url = "https://pushok.shop/shop/flow/wireguard/private"
    val valid = FlowShopBridgePolicy.parseExchange(mapOf("status" to "active",
        "subscription_url" to url))
    check(valid.url == url && valid.state == "active")
    check(!valid.toString().contains("private"))
    for (state in listOf("pending","expired","revoked","disabled","unavailable","link_disabled")) {
        check(FlowShopBridgePolicy.parseExchange(mapOf("status" to state,
            "subscription_url" to null)).state == state)
    }
    for (reply in listOf<Map<String, Any?>>(
        mapOf("status" to "active", "subscription_url" to null),
        mapOf("status" to "pending", "subscription_url" to url),
        mapOf("status" to "admin", "subscription_url" to url),
        mapOf("status" to "active", "subscription_url" to "http://plain"),
        mapOf("status" to "active", "subscription_url" to url, "key" to "private"),
    )) {
        try { FlowShopBridgePolicy.parseExchange(reply); error("accepted invalid response") }
        catch (failure: FlowShopFailure) { check(failure.code == "SHOP_PROTOCOL_INVALID") }
    }
    println("FlowShop bridge shape, privacy and exact-state checks passed")
}
