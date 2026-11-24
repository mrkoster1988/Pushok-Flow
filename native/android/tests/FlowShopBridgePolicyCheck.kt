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
    // Every 409 used to display "another phone", including replayed tickets.
    // Match only tightly whitelisted conflict codes, never arbitrary messages.
    check(FlowShopBridgePolicy.conflictCode(mapOf(
        "detail" to mapOf("code" to "FLOW_DEVICE_BOUND"))) == "SHOP_DEVICE_BOUND")
    check(FlowShopBridgePolicy.conflictCode(mapOf(
        "detail" to mapOf("code" to "FLOW_PROOF_REPLAY"))) == "SHOP_PROOF_REPLAY")
    check(FlowShopBridgePolicy.conflictCode(mapOf(
        "detail" to mapOf("code" to "FLOW_IDENTITY_CONFLICT"))) == "SHOP_IDENTITY_CONFLICT")
    check(FlowShopBridgePolicy.conflictCode(mapOf(
        "detail" to "Подтверждение уже использовано")) == "SHOP_PROOF_REPLAY")
    check(FlowShopBridgePolicy.conflictCode(mapOf(
        "detail" to "Подключение уже привязано к другому устройству")) == "SHOP_DEVICE_BOUND")
    check(FlowShopBridgePolicy.conflictCode(mapOf(
        "detail" to "Измените платёжный ключ: secret=private")) == "SHOP_CONFLICT")
    for (bad in listOf<Map<String, Any?>>(
        emptyMap(), mapOf("detail" to null),
        mapOf("detail" to mapOf("code" to "FLOW_DEVICE_BOUND", "token" to "private")),
        mapOf("detail" to mapOf("code" to "UNKNOWN")),
        mapOf("detail" to "FLOW_DEVICE_BOUND", "ticket" to "secret"),
    )) check(FlowShopBridgePolicy.conflictCode(bad) == "SHOP_CONFLICT")
    println("FlowShop bridge shape, privacy and exact-state checks passed")
}
