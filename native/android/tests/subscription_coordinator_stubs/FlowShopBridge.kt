package shop.pushok.flow

import android.content.Context

/** JNI/JVM coordinator fixtures; production uses actual native account authority. */
internal class FlowShopSessionLease(val accountId: String, val token: String,
    val epoch: Long = 0L, val expiresAt: Long = Long.MAX_VALUE)
internal class FlowAccountCoordinator {
    companion object {
        val fixture = FlowAccountCoordinator()
        fun get(context: Context) = fixture
    }
    var current: FlowShopSessionLease? = null
    fun shopLease() = current
    fun requireShopLease(lease: FlowShopSessionLease) {
        if (current !== lease) throw FlowShopFailure("SHOP_ACCOUNT_CHANGED")
    }
}
internal class FlowShopBridgeClient(context: Context) {
    companion object {
        var response = FlowShopBridgePolicy.Reply("disabled", null)
        var requests = 0
    }
    fun exchange(token: String, isCurrent: () -> Unit): FlowShopBridgePolicy.Reply {
        requests++
        isCurrent()
        return response
    }
}
