package shop.pushok.flow

import android.app.Activity
import android.os.Handler
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

private const val OLD_CODE = "2345ABCDEFGH"
private const val NEW_CODE = "6789ABCDEFGH"
private val fixtureDevice = "pfd_" + "a".repeat(43)
private val fixtureToken = "pfa_" + "b".repeat(64)

private fun pending(code: String = OLD_CODE, expires: Long = System.currentTimeMillis() + 300_000L) =
    FlowAccountRecord(pending = FlowAccountPending(fixtureDevice, code, expires,
        System.currentTimeMillis() + 5000L, 5))

private class BridgeReply : MethodChannel.Result {
    var completions = 0
    var value: Any? = null
    var errorCode: String? = null
    override fun success(value: Any?) { check(++completions == 1); this.value = value }
    override fun error(code: String, message: String?, details: Any?) {
        check(++completions == 1); errorCode = code; check(details == null)
    }
    override fun notImplemented() = error("Unexpected method")
    fun metadata() = value as Map<*, *>
}

private class AccountBridgeFixture(initial: FlowAccountRecord = pending()) : AutoCloseable {
    private val instance = FlowAccountCoordinator::class.java.getDeclaredField("instance").apply { isAccessible = true }
    val activity = Activity()
    val messenger = object : BinaryMessenger {}
    val bridge: FlowAccount
    val coordinator: FlowAccountCoordinator
    val serial: ExecutorService
    val remoteCalls = mutableListOf<String>()
    init {
        check(instance.get(null) == null)
        Handler.clearForTest()
        FlowAccountStore.value = initial
        FlowAccountClient.remote = FlowAccountRemote { method, path, bearer, body ->
            remoteCalls += path
            when (path) {
                "/capabilities" -> {
                    check(method == "GET" && bearer == null && body == null)
                    FlowAccountResponse(200, mapOf("protocol_version" to 1,
                        "scopes" to listOf("profile:read", "wallet:read"), "session_ttl_seconds" to 43200))
                }
                "/device" -> {
                    check(method == "POST" && bearer == null && body == emptyMap<String, Any?>())
                    FlowAccountResponse(201, mapOf("device_code" to fixtureDevice, "user_code" to NEW_CODE,
                        "expires_in" to 300, "interval" to 5))
                }
                "/logout" -> {
                    check(method == "POST" && bearer == fixtureToken && body == emptyMap<String, Any?>())
                    check(FlowAccountStore.value == FlowAccountRecord())
                    FlowAccountResponse(204)
                }
                else -> error("Unexpected bridge fixture request")
            }
        }
        bridge = FlowAccount(activity)
        bridge.register(messenger)
        coordinator = FlowAccountCoordinator.get(activity)
        serial = coordinator.javaClass.getDeclaredField("io").apply { isAccessible = true }
            .get(coordinator) as ExecutorService
    }
    fun invoke(method: String, arguments: Any? = null): BridgeReply = BridgeReply().also {
        MethodChannel.invoke(messenger, method, arguments, it)
    }
    fun idle() { serial.submit {}.get(2, TimeUnit.SECONDS) }
    fun reply() = Handler.runNext()
    fun pauseSerial(): AutoCloseable {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        serial.submit { entered.countDown(); release.await() }
        check(entered.await(2, TimeUnit.SECONDS))
        return AutoCloseable { release.countDown() }
    }
    override fun close() {
        bridge.dispose()
        serial.shutdownNow()
        check(serial.awaitTermination(2, TimeUnit.SECONDS))
        instance.set(null, null)
        Handler.clearForTest()
    }
}

fun main() {
    // A valid reopen uses only the public comparison code, never either secret.
    AccountBridgeFixture().use { test ->
        val reply = test.invoke("openLogin")
        test.idle(); test.reply()
        check(reply.completions == 1 && reply.errorCode == null && reply.value == null)
        check(test.activity.opened.single().uri.value == FlowAccountPolicy.telegram(OLD_CODE))
        check(test.remoteCalls.isEmpty())
    }

    // Deterministic legal scheduling: old status has posted its main callback,
    // then the serial thread pauses. Cancel wins before that callback is handled.
    for (method in listOf("cancelLogin", "logout")) AccountBridgeFixture().use { test ->
        val open = test.invoke("openLogin")
        test.pauseSerial().use {
            val clear = test.invoke(method, if (method == "cancelLogin") mapOf("userCode" to OLD_CODE) else null)
            check(test.coordinator.metadata()["busy"] == true)
            test.reply()
            check(open.errorCode == "FLOW_INTERRUPTED" && test.activity.attempts.isEmpty())
            check(clear.completions == 0)
        }
        test.idle(); test.reply()
        check(FlowAccountStore.value == FlowAccountRecord() && test.activity.attempts.isEmpty())
    }

    // Replacing the challenge invalidates a queued reopen. Only the new begin
    // result may perform the automatic handoff, and it carries the new code.
    AccountBridgeFixture().use { test ->
        val oldOpen = test.invoke("openLogin")
        val begin: BridgeReply
        test.pauseSerial().use {
            begin = test.invoke("beginLogin")
            test.reply()
            check(oldOpen.errorCode == "FLOW_INTERRUPTED" && test.activity.attempts.isEmpty())
        }
        test.idle(); test.reply()
        check(begin.metadata()["state"] == "pending")
        check(test.activity.opened.single().uri.value == FlowAccountPolicy.telegram(NEW_CODE))
    }

    // The initial beginLogin automatic opening obeys the same cancellation epoch.
    AccountBridgeFixture(FlowAccountRecord()).use { test ->
        val begin = test.invoke("beginLogin")
        test.pauseSerial().use {
            test.invoke("cancelLogin", mapOf("userCode" to NEW_CODE))
            test.reply()
            check(begin.metadata()["errorCode"] == "FLOW_INTERRUPTED")
            check(test.activity.attempts.isEmpty())
        }
        test.idle(); test.reply()
        check(FlowAccountStore.value == FlowAccountRecord())
    }

    // A blocked/queued operation cannot silently turn reopen into an unleased
    // status read. The shared open guard rejects busy metadata without an Intent.
    AccountBridgeFixture().use { test ->
        test.pauseSerial().use {
            test.invoke("pollLogin")
            val open = test.invoke("openLogin")
            test.reply()
            check(open.errorCode == "FLOW_BUSY" && test.activity.attempts.isEmpty())
        }
        test.idle(); test.reply()
    }

    for (method in listOf("openLogin", "beginLogin")) AccountBridgeFixture(
        if (method == "beginLogin") FlowAccountRecord() else pending()).use { test ->
        val result = test.invoke(method)
        test.idle()
        test.bridge.setForeground(false)
        test.bridge.setForeground(true)
        test.reply()
        check(test.activity.attempts.isEmpty() && result.completions == 1)
        if (method == "openLogin") check(result.errorCode == "FLOW_INTERRUPTED")
        check(FlowAccountStore.value.pending != null) // backgrounding does not discard the request
    }

    AccountBridgeFixture().use { test ->
        val open = test.invoke("openLogin")
        test.idle(); test.bridge.dispose()
        check(open.completions == 1 && open.metadata()["errorCode"] == "FLOW_INTERRUPTED")
        test.reply()
        check(open.completions == 1 && test.activity.attempts.isEmpty())
    }

    AccountBridgeFixture(pending(expires = System.currentTimeMillis() - 1L)).use { test ->
        val open = test.invoke("openLogin")
        test.idle(); test.reply()
        check(open.errorCode == "FLOW_LOGIN_EXPIRED" && test.activity.attempts.isEmpty())
        check(FlowAccountStore.value == FlowAccountRecord())
    }

    AccountBridgeFixture().use { test ->
        test.activity.rejectTelegram = true
        val open = test.invoke("openLogin")
        test.idle(); test.reply()
        check(open.errorCode == null && test.activity.attempts.size == 2)
        check(test.activity.opened.single().uri.value == FlowAccountPolicy.browser(OLD_CODE))
        check(test.activity.attempts.none { fixtureDevice in it.uri.value || fixtureToken in it.uri.value })
    }

    // Exact input contract: only cancel accepts arguments, only a public code.
    AccountBridgeFixture().use { test ->
        for (arguments in listOf(null, emptyMap<String, Any?>(), mapOf("userCode" to fixtureToken),
            mapOf("userCode" to OLD_CODE, "deviceCode" to fixtureDevice), mapOf("userCode" to 7))) {
            check(test.invoke("cancelLogin", arguments).errorCode == "FLOW_PROTOCOL_UNSUPPORTED")
        }
        for (method in listOf("status", "beginLogin", "pollLogin", "refresh", "logout", "openLogin")) {
            check(test.invoke(method, mapOf("userCode" to OLD_CODE)).errorCode == "FLOW_PROTOCOL_UNSUPPORTED")
        }
        check(Handler.pendingForTest() == 0 && test.remoteCalls.isEmpty())
        check(FlowAccountStore.value.pending?.userCode == OLD_CODE)
    }

    // A delayed cancel for a different challenge returns authoritative state;
    // it cannot clear or revoke a newer already-authorized session.
    val current = FlowAccountRecord(session = FlowAccountSession(fixtureToken,
        System.currentTimeMillis() + 60_000L, loginUserCode = NEW_CODE))
    AccountBridgeFixture(current).use { test ->
        val cancel = test.invoke("cancelLogin", mapOf("userCode" to OLD_CODE))
        test.idle(); test.reply()
        check(cancel.metadata()["state"] == "connected" && cancel.metadata()["errorCode"] == "FLOW_INTERRUPTED")
        check(FlowAccountStore.value == current && test.remoteCalls.isEmpty())
    }

    // Explicit local clearing must survive the immediate Activity pause even
    // when that pause prevents the best-effort server revoke from starting.
    for (method in listOf("cancelLogin", "logout")) AccountBridgeFixture(current).use { test ->
        val clear: BridgeReply
        test.pauseSerial().use {
            clear = test.invoke(method, if (method == "cancelLogin") mapOf("userCode" to NEW_CODE) else null)
            test.bridge.setForeground(false)
        }
        test.idle(); test.reply()
        check(clear.metadata()["state"] == "signed_out")
        check(clear.metadata()["errorCode"] == "FLOW_LOGOUT_REMOTE_FAILED")
        check(FlowAccountStore.value == FlowAccountRecord() && test.remoteCalls.isEmpty())
        check(test.activity.attempts.isEmpty())
    }

    println("Flow account actual bridge: qualified cancel, stale handoff, replacement, foreground and exact argument checks passed")
}
