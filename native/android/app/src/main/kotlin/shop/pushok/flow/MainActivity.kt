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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

open class MainActivity : FlutterActivity() {
    companion object {
        internal fun widgetState(context: android.content.Context): String {
            if (Session.operationInProgress.get()) return "starting"
            if (Session.backend?.getState(Session.tunnel) == Tunnel.State.UP) return "wireguard"
            return "disconnected"
        }
    }

    private val io get() = Session.connection.io
    private class PendingTunnelRequest(val call: MethodCall, val result: MethodChannel.Result, val token: Long)
    private var pending: PendingTunnelRequest? = null
    // The tunnel must outlive Activity recreation (rotation / process UI rebuild).
    // GoBackend.getState compares the Tunnel object by identity.
    private object Session {
        @Volatile var app: android.content.Context? = null
        val connection = TunnelConnectionSession(nowElapsedMs = { SystemClock.elapsedRealtime() })
        val tunnel = object : Tunnel {
            override fun getName() = "pushok_flow"
            override fun onStateChange(newState: Tunnel.State) {
                app?.let { FlowWidget.wireGuardChanged(it, newState == Tunnel.State.UP) }
            }
        }
        @Volatile var backend: GoBackend? = null
        var protocol = TunnelConnectionSession.Protocol.WIREGUARD
        val operationInProgress = ProfileOperationGate()
        val routeSettingsState = RouteSettingsState()
    }
    private val tunnel get() = Session.tunnel
    private var backend: GoBackend?
        get() = Session.backend
        set(value) { Session.backend = value }
    private fun readTunnelOccupied(): Boolean {
        try {
            val occupied = backend?.getState(tunnel) == Tunnel.State.UP
            appUpdates.observeTunnel(occupied)
            return occupied
        } catch (error: Exception) {
            appUpdates.observeTunnel(true)
            throw error
        }
    }

    private fun releaseOperation(token: Long) {
        Session.operationInProgress.release(token)
        appUpdates.endConnection(token)
        try { FlowWidget.render(applicationContext, widgetState(applicationContext)) } catch (_: Exception) { }

    }

    private fun stopTunnels(): Boolean {
        var failed = false
        try { backend?.setState(tunnel, Tunnel.State.DOWN, null) }
        catch (_: Exception) { failed = true }
        if (failed) throw IllegalStateException("TUNNEL_STOP_FAILED")
        return readTunnelOccupied()
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (pending != null || Session.operationInProgress.get()) {
            result.error("VPN_BUSY", "Подключение уже выполняется", null)
        } else if (config.isNullOrBlank() || config.length > 65536) {
            // Do not show Android's VPN approval for an unusable profile.
            result.error("INVALID_CONFIG", "Нужен профиль подключения", null)
        } else {
            val token = Session.operationInProgress.acquire()
            if (token == null) {
                result.error("VPN_BUSY", "Подключение уже изменяется", null)
            } else if (!appUpdates.beginConnection(token)) {
                releaseOperation(token)
                result.error("UPDATE_INSTALLING", "Android завершает обновление. Подключитесь после установки.", null)
            } else try {
                validateConnectionProfile(config)
                // Guard once before displaying the Android permission prompt.
                shopBinding.requireConnectionAllowed(config,
                    call.argument<String>("expectedProfileId"),
                    secureStore, FlowAccountCoordinator.get(applicationContext))
                val approval = VpnService.prepare(this)
                if (approval != null) {
                    pending = PendingTunnelRequest(call, result, token)
                    startActivityForResult(approval, vpnRequestCode)
                } else startTunnel(call, result, token)
            } catch (error: Exception) {
                pending = null
                releaseOperation(token)
                result.error(profileErrorCode(error, "VPN_REQUEST_INTERRUPTED"),
                    "Не удалось подготовить подключение", null)
            }
        }
    }
    private fun disconnect(result: MethodChannel.Result) {
        val token = Session.operationInProgress.acquire()
        if (token == null) {
            result.error("VPN_BUSY", "Подключение уже изменяется", null)
        } else io.execute {
            try {
                Session.connection.disconnect(
                    protocol = Session.protocol,
                    readState = ::readTunnelOccupied,
                    deactivate = ::stopTunnels,
                )
                runOnUiThread { result.success(mapOf("connected" to false)) }
            } catch (_: Exception) {
                runOnUiThread { result.error(Session.protocol.disconnectError, "Не удалось отключить туннель", null) }
            } finally {
                releaseOperation(token)
            }
        }
    }

    protected fun widgetAction(connecting: Boolean, result: MethodChannel.Result) {
        val current = try { widgetState(applicationContext) } catch (_: Exception) { "unknown" }
        if (current == "starting" || current == "unknown") {
            result.error("VPN_BUSY", "Состояние подключения уточняется", null)
            return
        }
        if (connecting == (current == "wireguard")) { result.success(null); return }
        if (!connecting) { disconnect(result); return }
        io.execute {
            try {
                val id = secureStore.metadata()["activeProfileId"] as? String
                    ?: throw IllegalStateException()
                val config = secureStore.load(id) ?: throw IllegalStateException()
                runOnUiThread {
                    connect(MethodCall("connectWireGuard", mapOf("config" to config,
                        "expectedProfileId" to id)), result)
                }
            } catch (_: Exception) {
                runOnUiThread { result.error("PROFILE_LOAD_FAILED", "Выберите профиль в Pushok Flow", null) }
            }
        }
    }
    private fun validateConnectionProfile(raw: String): ConnectionProfile.Kind {
        val kind = ConnectionProfile.validateShape(raw)
        if (kind == ConnectionProfile.Kind.WIREGUARD) {
            try {
                WireGuardRouting.prepare(raw, emptySet())
                val parsed = Config.parse(ByteArrayInputStream(raw.toByteArray(StandardCharsets.UTF_8)))
                if (parsed.peers.isEmpty()) throw IllegalArgumentException()
            } catch (_: Exception) { throw ProfileCatalogFailure("INVALID_CONFIG") }
        }
        return kind
    }
    private val secureStore by lazy { SecureWireGuardStore(applicationContext) }
    private val decisionMemory by lazy { LocalDecisionMemory(applicationContext) }
    private val appUpdates by lazy { AppUpdates(this) }
    private val flowAccount by lazy { FlowAccount(this) }
    private val shopBinding by lazy { FlowShopBindingStore(applicationContext) }
    private val routeRecommendations by lazy { RouteRecommendations(this) }
    private val profileScreenProtection by lazy { ProfileScreenProtection(this) }
    private val profileImport by lazy { WireGuardProfileImport(this) { profileScreenProtection.isActive } }
    private val profileSubscriptions by lazy {
        ProfileSubscriptions(this, secureStore, ::mutateSubscription)
    }
    private val lastErrorCode get() = Session.connection.lastErrorCode
    private val vpnRequestCode = 7341

    override fun onResume() {
        super.onResume()
        appUpdates.setForeground(true)
        flowAccount.setForeground(true)
        routeRecommendations.setForeground(true)
        profileSubscriptions.setForeground(true)
    }

    override fun onPause() {
        appUpdates.setForeground(false)
        flowAccount.setForeground(false)
        routeRecommendations.setForeground(false)
        profileSubscriptions.setForeground(false)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        profileSubscriptions.acceptLink(intent.takeIf { it.action == Intent.ACTION_VIEW }?.dataString)
        // Do not retain a bearer subscription URL in the Activity's next recreation intent.
        setIntent(Intent(intent).setData(null))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (profileImport.onActivityResult(requestCode, resultCode, data)) return
        if (requestCode != vpnRequestCode) return
        val item = pending ?: return
        pending = null
        if (resultCode != Activity.RESULT_OK) {
            releaseOperation(item.token)
            item.result.error("VPN_DENIED", "Разрешение VPN не предоставлено", null)
        } else {
            startTunnel(item.call, item.result, item.token)
        }
    }

    private fun startTunnel(call: MethodCall, result: MethodChannel.Result, token: Long) {
        val raw = call.argument<String>("config")
        val expectedProfileId = (call.arguments as? Map<*, *>)?.get("expectedProfileId")
        if (raw.isNullOrBlank() || raw.length > 65536) {
            releaseOperation(token)
            result.error("INVALID_CONFIG", "Нужен профиль подключения", null)
            return
        }
        if (expectedProfileId != null && expectedProfileId !is String) {
            releaseOperation(token)
            result.error("PROFILE_CHANGED", "Выбранный профиль изменился", null)
            return
        }
        // The same process-wide token has been held since before VPN approval.
        // No other Activity may change the selected profile while approval is open.
        io.execute {
            if (expectedProfileId != null) {
                try {
                    // A different Activity may have selected/edited a profile
                    // between Flutter's earlier load and this connect request.
                    // Both the ID and exact configuration must still match.
                    secureStore.validateActive(expectedProfileId as String, raw)
                } catch (error: Exception) {
                    releaseOperation(token)
                    runOnUiThread { result.error(profileErrorCode(error, "PROFILE_LOAD_FAILED"),
                        "Не удалось подтвердить выбранный профиль. Повторите подключение.", null) }
                    return@execute
                }
            }
            // A route read/latch failure happens before any backend mutation. Preserve
            // the existing tunnel state rather than reporting a failed reconnect as DOWN.
            val exclusions = try { routeStore.read() } catch (error: Exception) {
                releaseOperation(token)
                runOnUiThread { result.error(routeErrorCode(error, "ROUTES_LOAD_FAILED"),
                    "Не удалось прочитать исключения приложений", null) }
                return@execute
            }
            val requestedProtocol = TunnelConnectionSession.Protocol.WIREGUARD
            try {
                // Recheck after Android VPN permission: logout/account switch
                // while that dialog is open must not start another user's tunnel.
                shopBinding.requireConnectionAllowed(raw, expectedProfileId as? String,
                    secureStore, FlowAccountCoordinator.get(applicationContext))
                validateConnectionProfile(raw)
                val cleaned = WireGuardRouting.prepare(raw, exclusions)
                val config = Config.parse(ByteArrayInputStream(cleaned.toByteArray(StandardCharsets.UTF_8)))
                val active = Session.connection.connect(
                    protocol = requestedProtocol,
                    readState = ::readTunnelOccupied,
                    activate = {
                        // Never reconnect an already-UP tunnel or diagnose its
                        // old choices as missing before the session state check.
                        RouteAppAvailability.requireForConnection(exclusions, ::isRouteAppAvailable)
                        Session.protocol = requestedProtocol
                        try {
                            if (backend == null) backend = GoBackend(applicationContext)
                            backend!!.setState(tunnel, Tunnel.State.UP, config) == Tunnel.State.UP
                        } catch (_: PackageManager.NameNotFoundException) {
                            // The app may disappear between preflight and the
                            // backend's addDisallowedApplication call.
                            throw TunnelConnectionFailure("ROUTES_APPS_UNAVAILABLE")
                        }
                    },
                )
                // Transfer the CONNECTING lease to the known-UP latch before releasing the operation token.
                appUpdates.observeTunnel(active)
                runOnUiThread { if (active) appUpdates.requestDownloadNotifications(); result.success(mapOf("connected" to active)) }
            } catch (error: TunnelConnectionFailure) {
                when (error.code) {
                    "VPN_STATE_UNAVAILABLE" -> runOnUiThread { result.error("VPN_STATE_UNAVAILABLE",
                        "Не удалось уточнить состояние туннеля. Повторите проверку.", null) }
                    "ROUTES_APPS_UNAVAILABLE" -> runOnUiThread { result.error("ROUTES_APPS_UNAVAILABLE",
                        "Android не подтвердил доступность приложения из исключений. Проверьте раздел «Маршруты».", null) }
                    "ROUTES_APPS_CHECK_FAILED" -> runOnUiThread { result.error("ROUTES_APPS_CHECK_FAILED",
                        "Не удалось проверить приложения из исключений. Повторите проверку в «Маршрутах».", null) }
                    else -> runOnUiThread { result.error(requestedProtocol.connectError,
                        "Не удалось установить туннель. Проверьте параметры сервера.", null) }
                }
            } catch (error: Exception) {
                Session.connection.failedConnect(requestedProtocol, ::readTunnelOccupied)
                // Never send raw exceptions: they might include the private key or full configuration.
                runOnUiThread { result.error(profileErrorCode(error, requestedProtocol.connectError),
                    "Не удалось установить туннель. Проверьте параметры сервера.", null) }
            } finally {
                releaseOperation(token)
            }
        }
    }

    override fun onDestroy() {
        profileImport.dispose()
        appUpdates.dispose()
        flowAccount.dispose()
        routeRecommendations.dispose()
        profileSubscriptions.dispose()
        profileScreenProtection.dispose()
        interruptPendingVpnRequest()
        super.onDestroy()
    }

    private fun interruptPendingVpnRequest() {
        // Android may recreate the Activity while the VPN permission dialog is open.
        // A MethodChannel.Result owned by the destroyed Activity must not be left pending.
        // Fail closed and let the user retry from the new screen; never start a tunnel
        // from a stale permission request. The already-running tunnel is unaffected.
        val request = pending
        pending = null
        if (request != null) {
            releaseOperation(request.token)
            request.result.error("VPN_REQUEST_INTERRUPTED", "Запрос разрешения прерван. Повторите подключение.", null)
        }
    }

    private val channelName = "shop.pushok.flow/app_routes"
    private val prefs by lazy { getSharedPreferences("pushok_flow_routes", MODE_PRIVATE) }
    private val routeStore by lazy {
        RouteSettingsStore(object : RouteSettingsStorage {
            override fun read(): Set<*> {
                val key = "flow_bypass_packages"
                // A saved empty set is intentional. Never overwrite earlier choices,
                // including those saved by a user who disabled every exclusion.
                if (!prefs.contains(key)) {
                    val installed = try {
                        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                        @Suppress("DEPRECATION")
                        packageManager.queryIntentActivities(intent, 0)
                            .map { it.activityInfo.packageName }
                    } catch (_: Exception) {
                        // Do not mark setup complete when Android cannot enumerate apps.
                        throw RouteSettingsFailure("ROUTES_LOAD_FAILED")
                    }
                    val selected = RouteInitialRecommendations.installedOnly(installed)
                    if (!prefs.edit().putStringSet(key, selected).commit()) {
                        throw RouteSettingsFailure("ROUTES_STORE_UNAVAILABLE")
                    }
                }
                return prefs.getStringSet(key, emptySet()).orEmpty()
            }
            override fun replace(packages: Set<String>): Boolean =
                prefs.edit().putStringSet("flow_bypass_packages", packages).commit()
        }, Session.routeSettingsState)
    }

    private fun isRouteAppAvailable(packageName: String): Boolean = try {
        // A package without a launcher can still be installed and routable.
        // Use the same default flags as VpnService.Builder, not archived or
        // uninstalled packages. A visibility-filtered app remains "unavailable",
        // never a claim that it was definitely removed from the phone.
        @Suppress("DEPRECATION")
        packageManager.getApplicationInfo(packageName, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        flowAccount.dispose()
        profileImport.dispose()
        routeRecommendations.dispose()
        profileSubscriptions.dispose()
        profileScreenProtection.dispose()
        interruptPendingVpnRequest()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun profileErrorCode(error: Exception, fallback: String): String {
        if (error is ProfileFormatFailure) return error.code
        if (error is SubscriptionFailure) return error.code
        if (error is FlowShopFailure) return error.code
        val code = (error as? ProfileCatalogFailure)?.code
        return if (code in setOf("PROFILE_NAME_INVALID", "PROFILE_LIMIT_REACHED", "PROFILE_NOT_FOUND",
                "PROFILE_STORE_UNAVAILABLE", "PROFILE_CHANGED", "PROFILE_MANAGED", "SUBSCRIPTION_EXPIRED",
                "SUBSCRIPTION_REVOKED", "INVALID_CONFIG", "VPN_ACTIVE", "VPN_BUSY", "VPN_STATE_UNAVAILABLE")) code!! else fallback
    }

    private fun mutateProfile(result: MethodChannel.Result, fallback: String, action: () -> Unit) {
        val token = Session.operationInProgress.acquire()
        if (token == null) {
            result.error("VPN_BUSY", "Подключение или профиль уже изменяется", null)
            return
        }
        io.execute {
            val failure = try {
                // A failed state read is not proof that the tunnel is down.
                val state = Session.connection.observe(::readTunnelOccupied)
                if (!state.known) throw ProfileCatalogFailure("VPN_STATE_UNAVAILABLE")
                if (state.occupied) throw ProfileCatalogFailure("VPN_ACTIVE")
                action()
                null
            } catch (error: Exception) {
                profileErrorCode(error, fallback)
            } finally {
                releaseOperation(token)
            }
            runOnUiThread {
                if (failure == null) result.success(true)
                else result.error(failure, "Не удалось изменить профиль", null)
            }
        }
    }

    /** The same process-wide queue and gate protect local edits and subscription commits. */
    private fun mutateSubscription(action: () -> Unit, completed: (String?) -> Unit) {
        val token = Session.operationInProgress.acquire()
        if (token == null) { completed("VPN_BUSY"); return }
        io.execute {
            val failure = try {
                val state = Session.connection.observe(::readTunnelOccupied)
                if (!state.known) throw ProfileCatalogFailure("VPN_STATE_UNAVAILABLE")
                if (state.occupied) throw ProfileCatalogFailure("VPN_ACTIVE")
                action()
                null
            } catch (error: Exception) {
                profileErrorCode(error, "SUBSCRIPTION_STORE_FAILED")
            } finally { releaseOperation(token) }
            runOnUiThread { completed(failure) }
        }
    }

    private fun routeErrorCode(error: Exception, fallback: String): String {
        val code = (error as? RouteSettingsFailure)?.code
        return if (code in setOf("INVALID_PACKAGES", "ROUTES_CHANGED", "ROUTES_LOAD_FAILED",
                "ROUTES_STORE_UNAVAILABLE", "ROUTES_APPS_CHECK_FAILED", "VPN_ACTIVE", "VPN_STATE_UNAVAILABLE")) code!! else fallback
    }

    private fun mutateRoutes(result: MethodChannel.Result, request: RouteSettingsRequest) {
        // Acquired before IO is queued: connect/permission/profile work in any
        // Activity cannot slip between the state check and committing new routes.
        val token = Session.operationInProgress.acquire()
        if (token == null) {
            result.error("VPN_BUSY", "Подключение или настройки уже изменяются", null)
            return
        }
        io.execute {
            val failure = try {
                val state = Session.connection.observe(::readTunnelOccupied)
                if (!state.known) throw RouteSettingsFailure("VPN_STATE_UNAVAILABLE")
                if (state.occupied) throw RouteSettingsFailure("VPN_ACTIVE")
                routeStore.replace(request)
                null
            } catch (error: Exception) {
                routeErrorCode(error, "ROUTES_SAVE_FAILED")
            } finally {
                releaseOperation(token)
            }
            runOnUiThread {
                if (failure == null) result.success(null)
                else result.error(failure, "Не удалось изменить исключения приложений", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Session.app = applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shop.pushok.flow/push")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable", "disable" -> FlowPush.configure(this, call.method == "enable", result)
                    else -> result.notImplemented()
                }
            }
        profileScreenProtection.register(flutterEngine)
        appUpdates.register(flutterEngine.dartExecutor.binaryMessenger)
        flowAccount.register(flutterEngine.dartExecutor.binaryMessenger)
        routeRecommendations.register(flutterEngine.dartExecutor.binaryMessenger)
        profileSubscriptions.register(flutterEngine.dartExecutor.binaryMessenger)
        profileSubscriptions.acceptLink(intent.takeIf { it?.action == Intent.ACTION_VIEW }?.dataString)
        if (intent?.data != null) setIntent(Intent(intent).setData(null))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importWireGuardProfile" -> profileImport.open(result)
                    "scanWireGuardProfileQr" -> profileImport.open(result, WireGuardProfileImport.Source.CAMERA)
                    "importWireGuardProfileQrImage" -> profileImport.open(result, WireGuardProfileImport.Source.QR_IMAGE)
                    "cancelWireGuardProfileImport" -> {
                        profileImport.cancel()
                        result.success(true)
                    }
                    "vpnStatus" -> io.execute {
                        val currentBackend = backend
                        val initial = Session.connection.observe(::readTunnelOccupied)
                        var stateKnown = initial.known
                        var occupied = initial.occupied
                        var samples: List<TunnelHealth.PeerSample>? = null
                        var sampledSessionStartMs: Long? = null
                        if (stateKnown && occupied && !Session.operationInProgress.get() &&
                            Session.protocol == TunnelConnectionSession.Protocol.WIREGUARD) {
                            sampledSessionStartMs = Session.connection.connectedSinceElapsedMs
                            samples = try {
                                val statistics = currentBackend?.getStatistics(tunnel)
                                    ?: throw IllegalStateException("Tunnel backend unavailable")
                                statistics.peers().map { key ->
                                    val peer = statistics.peer(key)
                                        ?: throw IllegalStateException("Incomplete tunnel statistics")
                                    TunnelHealth.PeerSample(peer.rxBytes(), peer.txBytes(),
                                        peer.latestHandshakeEpochMillis())
                                }
                            } catch (_: Exception) {
                                // Native errors may contain profile data. The UI receives only
                                // unavailable numeric statistics, never raw exceptions or keys.
                                null
                            }
                            // A service can stop during the native statistics read. Discard its
                            // metrics if the tunnel state changed before the snapshot is returned.
                            val afterStatistics = Session.connection.observe(::readTunnelOccupied)
                            occupied = afterStatistics.occupied
                            stateKnown = afterStatistics.known
                            if (!stateKnown) samples = null
                        }
                        val currentSessionStartMs = Session.connection.connectedSinceElapsedMs
                        // Every Activity uses the same queue. An external service stop
                        // can still invalidate a statistics sample before its second read.
                        if (sampledSessionStartMs != currentSessionStartMs) samples = null
                        val active = stateKnown && occupied
                        val status = TunnelHealth.snapshot(active, Session.operationInProgress.get(),
                            currentSessionStartMs, SystemClock.elapsedRealtime(), lastErrorCode,
                            stateKnown = stateKnown, peerSamples = samples,
                            nowEpochMs = System.currentTimeMillis(),
                            ownsTunnel = occupied)
                        runOnUiThread { result.success(status) }
                    }
                    "listWireGuardProfiles" -> io.execute {
                        try {
                            val metadata = secureStore.metadata()
                            runOnUiThread { result.success(metadata) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error(profileErrorCode(error, "PROFILE_LOAD_FAILED"),
                                "Не удалось открыть список профилей", null) }
                        }
                    }
                    "savedProfileExists" -> io.execute {
                        try {
                            val exists = secureStore.exists()
                            runOnUiThread { result.success(exists) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error(profileErrorCode(error, "PROFILE_LOAD_FAILED"),
                                "Не удалось проверить сохранённые профили", null) }
                        }
                    }
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
                        val arguments = call.arguments as? Map<*, *>
                        val config = arguments?.get("config") as? String
                        val profileId = arguments?.get("profileId")
                        val name = arguments?.get("name")
                        val createNew = arguments?.get("createNew")
                        if (config.isNullOrBlank() || config.length > 65536) {
                            result.error("INVALID_CONFIG", "Некорректная конфигурация", null)
                        } else if (name != null && name !is String) {
                            result.error("PROFILE_NAME_INVALID", "Некорректное имя профиля", null)
                        } else if ((profileId != null && profileId !is String) ||
                                   (createNew != null && createNew !is Boolean)) {
                            result.error("PROFILE_NOT_FOUND", "Не удалось выбрать профиль", null)
                        } else mutateProfile(result, "PROFILE_SAVE_FAILED") {
                            // Validation precedes the encrypted catalog write for both protocols.
                            validateConnectionProfile(config)
                            secureStore.save(config, profileId as? String, name as? String, createNew == true)
                        }
                    }
                    "loadWireGuardProfile" -> {
                        val id = (call.arguments as? Map<*, *>)?.get("profileId")
                        if (id != null && id !is String) {
                            result.error("PROFILE_NOT_FOUND", "Не удалось выбрать профиль", null)
                        } else io.execute {
                            try {
                                val config = secureStore.load(id as? String)
                                runOnUiThread { result.success(config) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error(profileErrorCode(error, "PROFILE_LOAD_FAILED"),
                                    "Не удалось расшифровать профиль", null) }
                            }
                        }
                    }
                    "deleteWireGuardProfile" -> {
                        val id = (call.arguments as? Map<*, *>)?.get("profileId")
                        if (id != null && id !is String) {
                            result.error("PROFILE_NOT_FOUND", "Не удалось выбрать профиль", null)
                        } else mutateProfile(result, "PROFILE_DELETE_FAILED") { secureStore.delete(id as? String) }
                    }
                    "selectWireGuardProfile" -> {
                        val id = (call.arguments as? Map<*, *>)?.get("profileId") as? String
                        if (id == null) {
                            result.error("PROFILE_NOT_FOUND", "Не удалось выбрать профиль", null)
                        } else mutateProfile(result, "PROFILE_SELECT_FAILED") { secureStore.select(id) }
                    }
                    "connectWireGuard" -> connect(call, result)
                    "disconnectWireGuard" -> disconnect(result)
                    "installedApps" -> io.execute {
                        try {
                            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                            @Suppress("DEPRECATION")
                            val activities = packageManager.queryIntentActivities(intent, 0)
                            val apps = activities.map { info ->
                                val packageName = info.activityInfo.packageName
                                check(RouteSettingsStore.isValidPackageName(packageName))
                                mapOf(
                                    "packageName" to packageName,
                                    "label" to RouteAppLabels.normalize(info.loadLabel(packageManager), packageName),
                                )
                            }.distinctBy { it["packageName"] }.sortedBy { it["label"] }
                            check(apps.size <= RouteSettingsStore.MAX_PACKAGES)
                            runOnUiThread { result.success(apps) }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("APPS_LOAD_FAILED", "Не удалось открыть список приложений", null) }
                        }
                    }
                    "getBypass" -> io.execute {
                        try {
                            val packages = routeStore.read().sorted()
                            runOnUiThread { result.success(packages) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error(routeErrorCode(error, "ROUTES_LOAD_FAILED"),
                                "Не удалось прочитать исключения приложений", null) }
                        }
                    }
                    "getBypassStatus" -> io.execute {
                        try {
                            val status = RouteAppAvailability.inspect(routeStore.read(), ::isRouteAppAvailable)
                            runOnUiThread { result.success(status.toChannel()) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error(routeErrorCode(error, "ROUTES_APPS_CHECK_FAILED"),
                                "Не удалось проверить приложения из исключений", null) }
                        }
                    }
                    "setBypass" -> {
                        val request = try { RouteSettingsRequest.parse(call.arguments) }
                            catch (_: Exception) { null }
                        if (request == null) {
                            result.error("INVALID_PACKAGES", "Некорректный список приложений", null)
                        } else mutateRoutes(result, request)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
