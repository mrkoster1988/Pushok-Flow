package shop.pushok.flow

fun main() {
    val legacy = "vless://example.invalid"
    try {
        ConnectionProfile.validateShape(legacy)
        error("Legacy profile accepted")
    } catch (failure: ProfileFormatFailure) {
        check(failure.code == "UNSUPPORTED_PROFILE")
    }
    try {
        SubscriptionFeed.parse(legacy.toByteArray())
        error("Legacy feed accepted")
    } catch (failure: SubscriptionFailure) {
        check(failure.code == "SUBSCRIPTION_UNSUPPORTED")
    }
    check(ConnectionProfile.validateShape("[Interface]\n[Peer]") == ConnectionProfile.Kind.WIREGUARD)
}
