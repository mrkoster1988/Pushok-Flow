package shop.pushok.flow

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Native-only account authority. No Activity owns credentials, network state or encrypted records. */
internal class FlowAccountCoordinator private constructor(context: Context) {
    companion object {
        @Volatile private var instance: FlowAccountCoordinator? = null
        fun get(context: Context): FlowAccountCoordinator = instance ?: synchronized(this) {
            instance ?: FlowAccountCoordinator(context.applicationContext).also { instance = it }
        }
    }
    private data class Active(val owner: Any, val epoch: Long, val call: FlowAccountCall)
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val foreground = mutableSetOf<Any>()
    private val manager = FlowAccountSessionManager(FlowAccountStore(context))
    private var epoch = 0L
    private var busy = false
    private var error: String? = null
    private var active: Active? = null

    fun setForeground(owner: Any, value: Boolean) {
        val cancel = synchronized(lock) {
            if (value) foreground.add(owner) else foreground.remove(owner)
            active?.takeIf { !value && it.owner === owner }?.call
        }
        cancel?.cancel()
    }
    fun metadata(override: String? = null): Map<String, Any?> = synchronized(lock) {
        manager.record.metadata(System.currentTimeMillis(), busy, override ?: error)
    }
    fun status(callback: (Map<String, Any?>) -> Unit) {
        io.execute {
            val selectedEpoch = synchronized(lock) { epoch }
            try {
                val commit = transaction(selectedEpoch)
                manager.load(commit)
                manager.expire(commit)
            } catch (failure: FlowAccountFailure) {
                synchronized(lock) { if (epoch == selectedEpoch) error = failure.code.takeUnless { it == "FLOW_INTERRUPTED" } }
            } catch (_: Exception) { synchronized(lock) { if (epoch == selectedEpoch) error = "FLOW_STORE_UNAVAILABLE" } }
            main.post { callback(metadata()) }
        }
    }
    private fun transaction(selectedEpoch: Long, owner: Any? = null): (() -> Unit) -> Unit = { change ->
        synchronized(lock) {
            if (epoch != selectedEpoch || (owner != null && owner !in foreground)) throw FlowAccountFailure("FLOW_INTERRUPTED")
            change()
        }
    }
    fun perform(owner: Any, command: String, callback: (Map<String, Any?>) -> Unit) {
        val supersede = command in setOf("beginLogin", "cancelLogin", "logout")
        val selected: Pair<Long, FlowAccountCall?> = synchronized(lock) {
            if (busy && !supersede) { main.post { callback(metadata("FLOW_BUSY")) }; return }
            epoch += 1
            busy = true
            error = null
            epoch to active?.call
        }
        selected.second?.cancel()
        val selectedEpoch = selected.first
        io.execute {
            val call = FlowAccountCall { synchronized(lock) { epoch == selectedEpoch && owner in foreground } }
            try {
                synchronized(lock) {
                    if (epoch != selectedEpoch) throw FlowAccountFailure("FLOW_INTERRUPTED")
                    active = Active(owner, selectedEpoch, call)
                }
                // Local cancel/logout must commit even if the user immediately leaves the Activity.
                val commit = transaction(selectedEpoch, owner.takeUnless { command in setOf("cancelLogin", "logout") })
                manager.execute(command, FlowAccountClient(call), commit)
            } catch (failure: FlowAccountFailure) {
                synchronized(lock) { if (epoch == selectedEpoch) error = failure.code.takeUnless { it == "FLOW_INTERRUPTED" } }
            } catch (_: Exception) {
                synchronized(lock) { if (epoch == selectedEpoch) error = "FLOW_NETWORK_ERROR" }
            } finally {
                synchronized(lock) {
                    if (active?.epoch == selectedEpoch) active = null
                    if (epoch == selectedEpoch) busy = false
                }
            }
            main.post {
                val current = synchronized(lock) { epoch == selectedEpoch }
                callback(metadata(if (current) null else "FLOW_INTERRUPTED"))
            }
        }
    }
}

/** The channel exposes only validated metadata and fixed public-code handoffs. */
class FlowAccount(activity: Activity) {
    private val activityReference = WeakReference(activity)
    private val coordinator = FlowAccountCoordinator.get(activity.applicationContext)
    private val disposed = AtomicBoolean(false)
    private val foreground = AtomicBoolean(true)
    private val foregroundEpoch = AtomicLong(0)
    private val results = mutableSetOf<MethodChannel.Result>()
    private var channel: MethodChannel? = null

    init { coordinator.setForeground(this, true) }
    fun register(messenger: BinaryMessenger) {
        check(!disposed.get())
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, "shop.pushok.flow/account").also { value ->
            value.setMethodCallHandler { call, result ->
                if (call.arguments != null) { result.error("FLOW_PROTOCOL_UNSUPPORTED", "Неизвестные параметры входа", null); return@setMethodCallHandler }
                when (call.method) {
                    "status" -> request(result) { done -> coordinator.status(done) }
                    "beginLogin", "pollLogin", "cancelLogin", "refresh", "logout" -> {
                        val launchEpoch = foregroundEpoch.get()
                        request(result, openAfter = call.method == "beginLogin", launchEpoch = launchEpoch) { done ->
                            coordinator.perform(this, call.method, done)
                        }
                    }
                    "openLogin" -> openLogin(result)
                    else -> result.notImplemented()
                }
            }
        }
    }
    fun setForeground(value: Boolean) {
        if (!value) foregroundEpoch.incrementAndGet()
        val active = value && !disposed.get()
        foreground.set(active)
        coordinator.setForeground(this, active)
    }
    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        setForeground(false)
        channel?.setMethodCallHandler(null)
        channel = null
        val pending = results.toList()
        results.clear()
        pending.forEach { it.success(coordinator.metadata("FLOW_INTERRUPTED")) }
        activityReference.clear()
    }
    private fun request(result: MethodChannel.Result, openAfter: Boolean = false,
        launchEpoch: Long = foregroundEpoch.get(), launch: ((Map<String, Any?>) -> Unit) -> Unit) {
        if (disposed.get()) { result.success(coordinator.metadata("FLOW_INTERRUPTED")); return }
        results.add(result)
        launch { status ->
            if (!results.remove(result) || disposed.get()) return@launch
            var output = status
            if (openAfter && foreground.get() && foregroundEpoch.get() == launchEpoch &&
                status["state"] == "pending" && status["errorCode"] == null) {
                try { open(status, launchEpoch) }
                catch (_: Exception) { output = status + ("errorCode" to "FLOW_LOGIN_OPEN_FAILED") }
            }
            result.success(output)
        }
    }
    private fun openLogin(result: MethodChannel.Result) {
        if (disposed.get()) { result.error("FLOW_INTERRUPTED", "Открытие прервано", null); return }
        val launchEpoch = foregroundEpoch.get()
        results.add(result)
        coordinator.status { status ->
            if (!results.remove(result) || disposed.get()) return@status
            try { open(status, launchEpoch); result.success(null) }
            catch (failure: FlowAccountFailure) { result.error(failure.code, "Не удалось открыть подтверждение", null) }
            catch (_: Exception) { result.error("FLOW_LOGIN_OPEN_FAILED", "Не удалось открыть подтверждение", null) }
        }
    }
    private fun open(status: Map<String, Any?>, launchEpoch: Long) {
        val pending = status["pending"] as? Map<*, *> ?: throw FlowAccountFailure("FLOW_LOGIN_EXPIRED")
        val code = pending["userCode"] as? String ?: throw FlowAccountFailure("FLOW_LOGIN_EXPIRED")
        val expires = pending["expiresAt"] as? Long ?: throw FlowAccountFailure("FLOW_LOGIN_EXPIRED")
        if (expires <= System.currentTimeMillis()) throw FlowAccountFailure("FLOW_LOGIN_EXPIRED")
        val activity = activityReference.get()
        if (disposed.get() || !foreground.get() || foregroundEpoch.get() != launchEpoch ||
            activity == null || activity.isFinishing || activity.isDestroyed) throw FlowAccountFailure("FLOW_INTERRUPTED")
        try { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(FlowAccountPolicy.telegram(code)))) }
        catch (_: Exception) {
            try { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(FlowAccountPolicy.browser(code)))) }
            catch (_: Exception) { throw FlowAccountFailure("FLOW_LOGIN_OPEN_FAILED") }
        }
    }
}
