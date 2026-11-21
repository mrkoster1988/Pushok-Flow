package shop.pushok.flow

import android.os.SystemClock
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.app.Activity
import io.flutter.plugin.common.MethodCall
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private var pending: Pair<MethodCall, MethodChannel.Result>? = null
    // The tunnel must outlive Activity recreation (rotation / process UI rebuild).
    // GoBackend.getState compares the Tunnel object by identity.
    private object Session {
        val tunnel = object : Tunnel {
            override fun getName() = "pushok_flow"
            override fun onStateChange(newState: Tunnel.State) {}
        }
        @Volatile var backend: GoBackend? = null
        @Volatile var connected = false
        @Volatile var connectedSinceElapsedMs: Long? = null
        @Volatile var lastErrorCode: String? = null
        val operationInProgress = AtomicBoolean(false)
    }
    private val tunnel get() = Session.tunnel
    private var backend: GoBackend?
        get() = Session.backend
        set(value) { Session.backend = value }
    private var connected: Boolean
        get() = Session.connected
        set(value) { Session.connected = value }
    private val secureStore by lazy { SecureWireGuardStore(applicationContext) }
    private val decisionMemory by lazy { LocalDecisionMemory(applicationContext) }
    private val appUpdates by lazy { AppUpdates(this) }
    private val profileScreenProtection by lazy { ProfileScreenProtection(this) }
    private var lastErrorCode: String?
        get() = Session.lastErrorCode
        set(value) { Session.lastErrorCode = value }
    private val vpnRequestCode = 7341

    override fun onResume() {
        super.onResume()
        appUpdates.setForeground(true)
    }

    override fun onPause() {
        appUpdates.setForeground(false)
        super.onPause()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != vpnRequestCode) return
        val item = pending ?: return
        pending = null
        if (resultCode != Activity.RESULT_OK) {
            item.second.error("VPN_DENIED", "Разрешение VPN не предоставлено", null)
        } else {
            startTunnel(item.first, item.second)
        }
    }

    private fun startTunnel(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("config")
        if (raw.isNullOrBlank() || raw.length > 65536) {
            result.error("INVALID_CONFIG", "Нужна конфигурация WireGuard", null)
            return
        }
        if (!Session.operationInProgress.compareAndSet(false, true)) {
            result.error("VPN_BUSY", "Подключение уже изменяется", null)
            return
        }
        io.execute {
            try {
                val cleaned = WireGuardRouting.prepare(raw, prefs.getStringSet("flow_bypass_packages", emptySet()).orEmpty())
                val config = Config.parse(ByteArrayInputStream(cleaned.toByteArray(StandardCharsets.UTF_8)))
                if (backend == null) backend = GoBackend(applicationContext)
                val state = backend!!.setState(tunnel, Tunnel.State.UP, config)
                connected = state == Tunnel.State.UP
                Session.connectedSinceElapsedMs = if (connected) SystemClock.elapsedRealtime() else null
                lastErrorCode = null
                runOnUiThread { result.success(mapOf("connected" to connected)) }
            } catch (error: Exception) {
                connected = false
                Session.connectedSinceElapsedMs = null
                lastErrorCode = "WG_CONNECT_FAILED"
                // Never send raw exceptions: they might include the private key or full configuration.
                runOnUiThread { result.error("WG_CONNECT_FAILED", "Не удалось установить туннель. Проверьте параметры сервера.", null) }
            } finally {
                Session.operationInProgress.set(false)
            }
        }
    }

    override fun onDestroy() {
        appUpdates.dispose()
        profileScreenProtection.dispose()
        // Android may recreate the Activity while the VPN permission dialog is open.
        // A MethodChannel.Result owned by the destroyed Activity must not be left pending.
        // Fail closed and let the user retry from the new screen; never start a tunnel
        // from a stale permission request. The already-running tunnel is unaffected.
        val request = pending
        pending = null
        if (request != null) {
            request.second.error("VPN_REQUEST_INTERRUPTED", "Запрос разрешения прерван. Повторите подключение.", null)
        }
        super.onDestroy()
    }

    private val channelName = "shop.pushok.flow/app_routes"
    private val prefs by lazy { getSharedPreferences("pushok_flow_routes", MODE_PRIVATE) }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        profileScreenProtection.dispose()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        profileScreenProtection.register(flutterEngine)
        appUpdates.register(flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "vpnStatus" -> io.execute {
                        val active = try { backend?.getState(tunnel) == Tunnel.State.UP } catch (_: Exception) { connected }
                        connected = active
                        if (!active) Session.connectedSinceElapsedMs = null
                        val status = TunnelHealth.snapshot(active, Session.operationInProgress.get(),
                            Session.connectedSinceElapsedMs, SystemClock.elapsedRealtime(), lastErrorCode)
                        runOnUiThread { result.success(status) }
                    }
                    "savedProfileExists" -> result.success(secureStore.exists())
                    "aiFeedbackSummary" -> result.success(decisionMemory.summary())
                    "aiFeedbackClear" -> {
                        try { decisionMemory.clear(); result.success(true) }
                        catch (_: Exception) { result.error("FEEDBACK_CLEAR_FAILED", "Не удалось очистить историю", null) }
                    }
                    "aiFeedbackRecord" -> {
                        val category = call.argument<String>("category")
                        val helpful = call.argument<Boolean>("helpful")
                        if (category !in setOf("connection", "routing", "server") || helpful == null) {
                            result.error("INVALID_FEEDBACK", "Некорректный результат проверки", null)
                        } else {
                            try { result.success(decisionMemory.record(category!!, helpful)) }
                            catch (_: Exception) { result.error("FEEDBACK_SAVE_FAILED", "Не удалось сохранить результат", null) }
                        }
                    }
                    "saveWireGuardProfile" -> {
                        val config = call.argument<String>("config")
                        if (config.isNullOrBlank() || config.length > 65536) {
                            result.error("INVALID_CONFIG", "Некорректная конфигурация", null)
                        } else io.execute {
                            try {
                                // Parse before storing; failure must not overwrite the existing profile.
                                Config.parse(ByteArrayInputStream(config.toByteArray(StandardCharsets.UTF_8)))
                            } catch (_: Exception) {
                                // Parser exceptions can contain private profile data.
                                runOnUiThread { result.error("INVALID_CONFIG", "Проверьте конфигурацию WireGuard", null) }
                                return@execute
                            }
                            try {
                                secureStore.save(config)
                                runOnUiThread { result.success(true) }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("PROFILE_SAVE_FAILED", "Не удалось сохранить профиль", null) }
                            }
                        }
                    }
                    "loadWireGuardProfile" -> io.execute {
                        try {
                            val config = secureStore.load()
                            runOnUiThread { result.success(config) }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("PROFILE_LOAD_FAILED", "Не удалось расшифровать профиль", null) }
                        }
                    }
                    "deleteWireGuardProfile" -> io.execute {
                        try {
                            secureStore.delete()
                            runOnUiThread { result.success(true) }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("PROFILE_DELETE_FAILED", "Не удалось удалить профиль", null) }
                        }
                    }
                    "connectWireGuard" -> {
                        val config = call.argument<String>("config")
                        if (pending != null || Session.operationInProgress.get()) {
                            result.error("VPN_BUSY", "Подключение уже выполняется", null)
                        } else if (config.isNullOrBlank() || config.length > 65536) {
                            // Do not show Android's VPN approval for an unusable profile.
                            result.error("INVALID_CONFIG", "Нужна конфигурация WireGuard", null)
                        } else {
                            val approval = VpnService.prepare(this)
                            if (approval != null) {
                                pending = call to result
                                startActivityForResult(approval, vpnRequestCode)
                            } else startTunnel(call, result)
                        }
                    }
                    "disconnectWireGuard" -> {
                        if (!Session.operationInProgress.compareAndSet(false, true)) {
                            result.error("VPN_BUSY", "Подключение уже изменяется", null)
                        } else io.execute {
                            try {
                                backend?.setState(tunnel, Tunnel.State.DOWN, null)
                                connected = false
                                Session.connectedSinceElapsedMs = null
                                runOnUiThread { result.success(mapOf("connected" to false)) }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("WG_DISCONNECT_FAILED", "Не удалось отключить туннель", null) }
                            } finally {
                                Session.operationInProgress.set(false)
                            }
                        }
                    }
                    "installedApps" -> {
                        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                        @Suppress("DEPRECATION")
                        val activities = packageManager.queryIntentActivities(intent, 0)
                        val apps = activities.map { info ->
                            mapOf(
                                "packageName" to info.activityInfo.packageName,
                                "label" to info.loadLabel(packageManager).toString(),
                            )
                        }.distinctBy { it["packageName"] }.sortedBy { it["label"] }
                        result.success(apps)
                    }
                    "getBypass" -> result.success(
                        prefs.getStringSet("flow_bypass_packages", emptySet())!!.sorted()
                    )
                    "setBypass" -> {
                        val values = call.argument<List<String>>("packages")
                        if (values == null || values.any { !it.matches(Regex("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")) }) {
                            result.error("INVALID_PACKAGES", "Expected Android package IDs", null)
                        } else {
                            // Preserve user's choices even if an app is temporarily uninstalled.
                            if (connected || Session.operationInProgress.get() || pending != null) {
                                result.error("VPN_ACTIVE", "Отключите туннель перед изменением исключений", null)
                            } else {
                                if (prefs.edit().putStringSet("flow_bypass_packages", values.toSet()).commit()) {
                                    result.success(null)
                                } else {
                                    result.error("ROUTES_SAVE_FAILED", "Не удалось сохранить исключения", null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
