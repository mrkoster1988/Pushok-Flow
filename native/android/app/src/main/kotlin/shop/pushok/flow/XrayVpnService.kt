package shop.pushok.flow

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import libXray.DialerController
import libXray.LibXray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Must run in :xray. A second independently built Go runtime cannot share WireGuard's process. */
class XrayVpnService : VpnService() {
    private val main = Handler(Looper.getMainLooper())
    // Native APIs are process-global. Service recreation must use the same queue.
    private val worker get() = ProcessCore.worker
    private val lease = XrayRequestLease { SystemClock.elapsedRealtime() }
    private val destroyed = AtomicBoolean()
    private val descriptorLock = Any()
    private var tun: ParcelFileDescriptor? = null
    @Volatile private var coreLoaded = false
    @Volatile private var nativeActive = false
    @Volatile private var connected = false
    @Volatile private var stopping = false
    @Volatile private var startingId = 0
    private var foreground = false
    private val messenger = Messenger(Handler(Looper.getMainLooper(), ::receive))

    override fun onBind(intent: Intent?): IBinder? =
        if (intent?.action == XrayIpc.BIND) messenger.binder else super.onBind(intent)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == XrayIpc.STOP_ACTION) {
            terminate()
        } else if (intent?.action == XrayIpc.PREPARE && !destroyed.get()) {
            try { showNotification(false) } catch (_: Exception) { terminate() }
            // An abandoned bind must not leave an idle foreground service behind.
            val observed = lease.current()
            main.postDelayed({ if (!connected && startingId == 0 && lease.owns(observed)) terminate() },
                XrayIpc.START_TIMEOUT_MS)
        } else {
            stopSelf()
        }
        // Never reconnect on reboot, service restart or an old Intent.
        return START_NOT_STICKY
    }

    private fun receive(message: Message): Boolean {
        if (message.sendingUid != applicationInfo.uid || destroyed.get()) return true
        val reply = message.replyTo
        val id = message.arg1
        val deadline = message.data.getLong("deadline", 0)
        when (message.what) {
            XrayIpc.CANCEL -> if (id == startingId) terminate()
            XrayIpc.START -> {
                if (stopping) { reply(reply, id, false, "XRAY_SERVICE_UNAVAILABLE"); return true }
                val data = Bundle(message.data)
                val generation = lease.invalidate()
                startingId = id
                val remaining = (deadline - SystemClock.elapsedRealtime()).coerceIn(0, XrayIpc.START_TIMEOUT_MS)
                // Closing the application's FD alone is insufficient: core owns a duplicate.
                // Kill ONLY the isolated service process if native startup cannot be cancelled.
                main.postDelayed({
                    if (startingId == id && lease.owns(generation)) {
                        terminate()
                        reply(reply, id, false, "XRAY_TIMEOUT")
                    }
                }, remaining)
                worker.execute {
                    var error: String? = null
                    try {
                        requireCurrent(generation, deadline)
                        if (!connected) startCore(data, generation, deadline)
                        requireCurrent(generation, deadline)
                    } catch (failure: XrayTunnelFailure) {
                        error = failure.code
                    } catch (_: PackageManager.NameNotFoundException) {
                        error = "ROUTES_APPS_UNAVAILABLE"
                    } catch (_: Throwable) {
                        error = "XRAY_CONNECT_FAILED"
                    } finally {
                        data.clear()
                        if (error != null) { stopping = true; stopCore() }
                        if (startingId == id) startingId = 0
                    }
                    val finalError = error
                    main.post {
                        if (finalError == null && connected && lease.owns(generation)) {
                            try { showNotification(true) } catch (_: Exception) { terminate() }
                        }
                        reply(reply, id, connected, finalError)
                        if (!connected) finishService()
                    }
                }
            }
            XrayIpc.STOP -> {
                stopping = true
                lease.invalidate()
                startingId = 0
                armNativeShutdownWatchdog()
                worker.execute {
                    val owner = ProcessCore.owner
                    val stopped = if (owner != null && owner !== this) owner.stopCore() else stopCore()
                    main.post { reply(reply, id, false, if (stopped) null else "XRAY_STOP_FAILED"); finishService() }
                }
            }
            XrayIpc.STATUS -> worker.execute {
                try {
                    val generation = lease.current()
                    if (ProcessCore.owner != null && ProcessCore.owner !== this) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
                    val wasConnected = connected
                    val wasNativeActive = nativeActive
                    val up = XrayRequestLease.knownState(wasConnected, wasNativeActive, wasNativeActive && coreState())
                    if (!lease.owns(generation) && nativeActive) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
                    if (!up && wasNativeActive && !stopCore()) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
                    main.post { reply(reply, id, up); if (!up && startingId == 0) finishService() }
                } catch (_: Throwable) {
                    main.post { reply(reply, id, false, "XRAY_STATE_UNAVAILABLE") }
                }
            }
        }
        return true
    }

    private fun requireCurrent(generation: Long, deadline: Long) {
        if (destroyed.get()) throw XrayTunnelFailure("XRAY_TIMEOUT")
        lease.requireCurrent(generation, deadline)
    }

    private fun startCore(data: Bundle, generation: Long, deadline: Long) {
        if (ProcessCore.owner != null && ProcessCore.owner !== this) throw XrayTunnelFailure("XRAY_SERVICE_UNAVAILABLE")
        val configText = data.getString("config") ?: throw XrayTunnelFailure("INVALID_VLESS_CONFIG")
        if (configText.length > 131_072) throw XrayTunnelFailure("INVALID_VLESS_CONFIG")
        val exclusions = try {
            RouteSettingsStore.validatePackages(data.getStringArrayList("exclusions") ?: arrayListOf<String>(), "INVALID_PACKAGES")
        } catch (_: RouteSettingsFailure) { throw XrayTunnelFailure("INVALID_PACKAGES") }
        if (prepare(this) != null) throw XrayTunnelFailure("VPN_DENIED")
        val resolver = bootstrapDns()
        val builder = Builder().setSession("Pushok Flow").setMtu(XrayConfig.MTU).setBlocking(false)
            .addAddress(XrayConfig.IPV4, 30).addAddress(XrayConfig.IPV6, 126)
            .addRoute("0.0.0.0", 0).addRoute("::", 0)
        for (dns in XrayConfig.DNS) builder.addDnsServer(dns)
        // Do not exclude the Flow UID: only protected core/bootstrap sockets bypass the tunnel.
        for (pkg in exclusions.distinct()) builder.addDisallowedApplication(pkg)
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
        requireCurrent(generation, deadline)
        val descriptor = builder.establish() ?: throw XrayTunnelFailure("VPN_DENIED")
        synchronized(descriptorLock) { tun = descriptor }
        try {
            requireCurrent(generation, deadline)
            ProcessCore.owner = this
            nativeActive = true
            requireCurrent(generation, deadline)
            // The core APPENDS controllers. Register once; resolve the current service
            // for every socket so a destroyed service cannot poison a later session.
            if (!ProcessCore.dialerRegistered) {
                LibXray.registerDialerController(ProcessCore.protector)
                ProcessCore.dialerRegistered = true
            }
            coreLoaded = true
            if (!ProcessCore.listenerRegistered) {
                LibXray.registerListenerController(ProcessCore.protector)
                ProcessCore.listenerRegistered = true
            }
            // Endpoint hostname resolution is necessarily a protected bootstrap request.
            LibXray.setDNS(ProcessCore.protector, resolver)
            val config = JSONObject(configText)
                .put("env", JSONObject().put("xray.tun.fd", descriptor.fd.toString()))
            requireCurrent(generation, deadline)
            invoke("runXray", JSONObject().put("xrayJson", config.toString()))
            requireCurrent(generation, deadline)
            if (!coreState()) throw XrayTunnelFailure("XRAY_CONNECT_FAILED")
            connected = true
        } catch (error: Throwable) {
            stopCore()
            throw error
        }
    }

    private fun bootstrapDns(): String {
        return try {
            val cm = getSystemService(ConnectivityManager::class.java)
            val networks = cm.allNetworks.sortedBy { if (it == cm.activeNetwork) 0 else 1 }
            val server = networks.firstNotNullOfOrNull { network ->
                val capabilities = cm.getNetworkCapabilities(network)
                if (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) {
                    cm.getLinkProperties(network)?.dnsServers?.firstOrNull()?.hostAddress
                } else null
            }?.substringBefore('%')
            when { server == null -> "1.1.1.1:53"; ':' in server -> "[$server]:53"; else -> "$server:53" }
        } catch (_: Exception) { "1.1.1.1:53" }
    }

    private fun invoke(method: String, payload: JSONObject? = null): JSONObject {
        val request = JSONObject().put("apiVersion", 3).put("method", method)
        if (payload != null) request.put("payload", payload)
        val response = JSONObject(LibXray.invoke(request.toString()))
        // Do not log, persist, return, or attach native errors: they can contain credentials.
        if (!response.optBoolean("success", false)) throw XrayTunnelFailure("XRAY_CORE_FAILED")
        return response.optJSONObject("data") ?: JSONObject()
    }

    private fun coreState(): Boolean = invoke("getXrayState").getBoolean("running")

    private fun stopCore(): Boolean {
        connected = false
        var stopped = true
        if (coreLoaded && ProcessCore.owner === this) {
            try { invoke("stopXray") } catch (_: Throwable) { stopped = false }
            if (stopped) try { LibXray.resetDNS() } catch (_: Throwable) {}
        }
        nativeActive = !stopped
        if (stopped && ProcessCore.owner === this) ProcessCore.owner = null
        closeOwnerDescriptor()
        if (!stopped) main.post { armNativeShutdownWatchdog() }
        return stopped
    }

    private fun closeOwnerDescriptor() {
        synchronized(descriptorLock) {
            try { tun?.close() } catch (_: Exception) {}
            tun = null
        }
    }

    private fun armNativeShutdownWatchdog() {
        main.postDelayed({ if (nativeActive) Process.killProcess(Process.myPid()) }, 2_000)
    }

    private fun terminate() {
        stopping = true
        lease.invalidate()
        startingId = 0
        connected = false
        armNativeShutdownWatchdog()
        worker.execute { stopCore(); main.post { finishService() } }
    }

    private fun finishService() {
        if (foreground) { stopForeground(STOP_FOREGROUND_REMOVE); foreground = false }
        stopSelf()
    }

    private fun reply(destination: Messenger?, id: Int, up: Boolean, error: String? = null) {
        if (destination == null) return
        // Main-thread cancellation can happen after the worker took its snapshot.
        // Until the native owner is gone, an unqualified DOWN reply is forbidden.
        val safeError = error ?: if (!up && ProcessCore.owner?.nativeActive == true) "XRAY_STATE_UNAVAILABLE" else null
        val response = Message.obtain(null, XrayIpc.REPLY, id, 0).apply {
            data = Bundle().apply { putBoolean("connected", up); if (safeError != null) putString("error", safeError) }
        }
        try { destination.send(response) } catch (_: Exception) {}
    }

    private fun showNotification(up: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Подключение Pushok Flow",
                NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }
        val open = Intent().setClassName(this, "shop.pushok.flow.MainActivity")
        val content = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 0, Intent(this, XrayVpnService::class.java).setAction(XrayIpc.STOP_ACTION),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.drawable.ic_flow_tunnel).setContentTitle("Pushok Flow")
            .setContentText(if (up) "Туннель включён · VLESS" else "Подключение…")
            .setContentIntent(content).setOngoing(true).setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .addAction(Notification.Action.Builder(null, "Отключить", stop).build()).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(NOTIFICATION, notification)
        foreground = true
    }

    override fun onRevoke() { terminate(); super.onRevoke() }

    override fun onDestroy() {
        destroyed.set(true)
        lease.invalidate()
        connected = false
        armNativeShutdownWatchdog()
        // Never close the owner FD concurrently with native startup: the core may
        // still be duplicating it. The shared worker closes it after stopXray.
        worker.execute { stopCore() }
        super.onDestroy()
    }

    private companion object {
        const val CHANNEL = "pushok_flow_tunnel"
        const val NOTIFICATION = 3601
    }

    private object ProcessCore {
        val worker = Executors.newSingleThreadExecutor()
        @Volatile var owner: XrayVpnService? = null
        var dialerRegistered = false
        var listenerRegistered = false
        val protector by lazy {
            DialerController { fd ->
                val current = owner
                try {
                    fd in 0..Int.MAX_VALUE.toLong() && current != null &&
                        !current.destroyed.get() && current.protect(fd.toInt())
                } catch (_: Exception) { false }
            }
        }
    }
}
