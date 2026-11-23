package shop.pushok.flow

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
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
import java.net.InetAddress
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Must run in :xray. A second independently built Go runtime cannot share WireGuard's process. */
class XrayVpnService : VpnService() {
    private val main = Handler(Looper.getMainLooper())
    // Native APIs are process-global. Service recreation must use the same queue.
    private val worker get() = ProcessCore.worker
    private val lease = XrayRequestLease { SystemClock.elapsedRealtime() }
    private val destroyed = AtomicBoolean()
    private val networks = XrayNetworkState<XrayNetworkMonitor.Snapshot>()
    private class Desired(val epoch: Long, val hostname: String)
    @Volatile private var desired: Desired? = null
    private var networkMonitor: XrayNetworkMonitor? = null
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
            try { showNotification("starting") } catch (_: Exception) { terminate() }
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
                if (stopping || startingId != 0 || desired != null || nativeActive) {
                    reply(reply, id, false, "XRAY_SERVICE_UNAVAILABLE")
                    return true
                }
                val data = Bundle(message.data)
                val generation = lease.invalidate()
                startingId = id
                try {
                    beginNetworks(data)
                } catch (_: Exception) {
                    clearNetworks()
                    startingId = 0
                    data.clear()
                    reply(reply, id, false, "XRAY_CONNECT_FAILED")
                    finishService()
                    return true
                }
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
                    val completion = try {
                        lease.runStart(
                            generation, deadline,
                            readConnected = { connected },
                            activate = {
                                // An unsuccessful teardown still owns native resources.
                                // Do not overwrite that owner with a queued new START.
                                XrayRequestLease.knownState(false, nativeActive, false)
                                startCore(data, generation, deadline)
                            },
                            cleanup = { stopCore() },
                            errorCode = { failure -> when (failure) {
                                is XrayTunnelFailure -> failure.code
                                is PackageManager.NameNotFoundException -> "ROUTES_APPS_UNAVAILABLE"
                                else -> "XRAY_CONNECT_FAILED"
                            } },
                        )
                    } finally {
                        data.clear()
                    }
                    main.post {
                        lease.deliver(
                            completion,
                            available = { canDeliver(completion) },
                            onUp = { try { showNotification(localStatus().state) } catch (_: Exception) { terminate() } },
                            reply = { up, error ->
                                // Keep the startup watchdog armed until delivery. An old
                                // command (including a reused IPC id) cannot clear a new one.
                                if (lease.owns(generation) && startingId == id) startingId = 0
                                reply(reply, id, up, error)
                            },
                            onDown = { stopping = true; clearNetworks(); finishService() },
                            onExpired = ::terminate,
                        )
                    }
                }
            }
            XrayIpc.STOP -> {
                stopping = true
                lease.invalidate()
                startingId = 0
                clearNetworks()
                armNativeShutdownWatchdog()
                worker.execute {
                    val owner = ProcessCore.owner
                    val stopped = if (owner != null && owner !== this) owner.stopCore() else stopCore()
                    main.post { reply(reply, id, false, if (stopped) null else "XRAY_STOP_FAILED"); finishService() }
                }
            }
            XrayIpc.STATUS -> {
                // Capture at receipt: an old queued STATUS must not adopt the
                // generation of a START that arrives before its worker runs.
                val generation = lease.current()
                val observed = localStatus()
                // Neither a native call nor a ProfileOperationGate is needed to
                // say that this service still owns a waiting connection. STOP
                // remains usable while startup/native work occupies the worker.
                if (!observed.needsNativeProbe) {
                    val failure = if (SystemClock.elapsedRealtime() >= deadline) "XRAY_TIMEOUT" else null
                    replyStatus(reply, id, observed, failure)
                    return true
                }
                worker.execute {
                    var up = false
                    var error: String? = null
                    try {
                        if (!lease.owns(generation)) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
                        if (ProcessCore.owner != null && ProcessCore.owner !== this) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
                        val wasConnected = connected
                        val wasNativeActive = nativeActive
                        up = XrayRequestLease.knownState(wasConnected, wasNativeActive, wasNativeActive && coreState())
                        if (!lease.owns(generation)) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
                        if (!up && wasNativeActive && !stopCore()) throw XrayTunnelFailure("XRAY_STATE_UNAVAILABLE")
                    } catch (_: Throwable) {
                        up = false
                        error = "XRAY_STATE_UNAVAILABLE"
                    }
                    val completion = XrayRequestLease.Completion(generation, deadline, up, error)
                    main.post {
                        lease.deliver(
                            completion,
                            available = { canDeliver(completion) },
                            reply = { _, failure -> replyStatus(reply, id, localStatus(), failure) },
                            onDown = {
                                if (completion.error == null && startingId == 0) {
                                    // This is a confirmed native DOWN, never the
                                    // known waiting/reconnecting fast path.
                                    clearNetworks()
                                    finishService()
                                }
                            },
                        )
                    }
                }
            }
        }
        return true
    }

    private fun requireCurrent(generation: Long, deadline: Long) {
        if (destroyed.get()) throw XrayTunnelFailure("XRAY_TIMEOUT")
        lease.requireCurrent(generation, deadline)
    }

    private fun canDeliver(completion: XrayRequestLease.Completion): Boolean =
        !destroyed.get() && (!completion.connected ||
            (!stopping && desired != null && connected && nativeActive && ProcessCore.owner === this))

    private fun startCore(data: Bundle, generation: Long, deadline: Long) {
        if (ProcessCore.owner != null && ProcessCore.owner !== this) throw XrayTunnelFailure("XRAY_SERVICE_UNAVAILABLE")
        val configText = data.getString("config") ?: throw XrayTunnelFailure("INVALID_VLESS_CONFIG")
        if (configText.length > 131_072) throw XrayTunnelFailure("INVALID_VLESS_CONFIG")
        val exclusions = try {
            RouteSettingsStore.validatePackages(data.getStringArrayList("exclusions") ?: arrayListOf<String>(), "INVALID_PACKAGES")
        } catch (_: RouteSettingsFailure) { throw XrayTunnelFailure("INVALID_PACKAGES") }
        if (prepare(this) != null) throw XrayTunnelFailure("VPN_DENIED")
        val builder = Builder().setSession("Pushok Flow").setMtu(XrayConfig.MTU).setBlocking(false)
            .addAddress(XrayConfig.IPV4, 30).addAddress(XrayConfig.IPV6, 126)
            .addRoute("0.0.0.0", 0).addRoute("::", 0)
        for (dns in XrayConfig.DNS) builder.addDnsServer(dns)
        // Do not exclude the Flow UID: only protected core/bootstrap sockets bypass the tunnel.
        for (pkg in exclusions.distinct()) builder.addDisallowedApplication(pkg)
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
        builder.setUnderlyingNetworks(networks.view().selection?.let { arrayOf(it.target.network) } ?: emptyArray())
        requireCurrent(generation, deadline)
        val descriptor = builder.establish() ?: throw XrayTunnelFailure("VPN_DENIED")
        synchronized(descriptorLock) { tun = descriptor }
        try {
            requireCurrent(generation, deadline)
            ProcessCore.owner = this
            nativeActive = true
            requireCurrent(generation, deadline)
            synchronizeUnderlying(generation, deadline)
            // The core APPENDS controllers. Register once; resolve the current service
            // for every socket so a destroyed service cannot poison a later session.
            if (!ProcessCore.dialerRegistered) {
                LibXray.registerDialerController(ProcessCore.outboundController)
                ProcessCore.dialerRegistered = true
            }
            coreLoaded = true
            if (!ProcessCore.listenerRegistered) {
                LibXray.registerListenerController(ProcessCore.localController)
                ProcessCore.listenerRegistered = true
            }
            // Process-global resolver pointers are installed only before the
            // first core. Handover changes the bridge's target, never SetDNS.
            ProcessCore.ensureDns()
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

    private fun beginNetworks(data: Bundle) {
        val text = data.getString("config") ?: throw XrayTunnelFailure("INVALID_VLESS_CONFIG")
        if (text.length > 131_072) throw XrayTunnelFailure("INVALID_VLESS_CONFIG")
        // This is private IPC containing XrayConfig's generated single outbound,
        // not a remotely supplied JSON document. Keep the hostname in memory only.
        val hostname = JSONObject(text).getJSONArray("outbounds").getJSONObject(0)
            .getJSONObject("settings").getJSONArray("vnext").getJSONObject(0).getString("address")
        if (hostname.isBlank() || hostname.length > 253) throw XrayTunnelFailure("INVALID_VLESS_CONFIG")
        val epoch = networks.begin()
        desired = Desired(epoch, hostname)
        val monitor = XrayNetworkMonitor(getSystemService(ConnectivityManager::class.java), main,
            onChanging = {
                if (networks.changing(epoch)) {
                    // An empty list means no usable underlying network. Null
                    // would instead let Android choose the default (possibly VPN).
                    if (!publishUnderlying(epoch, null)) networks.fail(epoch)
                    updateNotification()
                }
            },
            onSelected = { selected ->
                if (networks.owns(epoch)) {
                    if (publishUnderlying(epoch, selected)) networks.select(epoch, selected)
                    else networks.fail(epoch)
                    updateNotification()
                }
            },
        )
        networkMonitor = monitor
        monitor.start()
    }

    private fun publishUnderlying(epoch: Long, selected: XrayNetworkMonitor.Snapshot?): Boolean =
        networks.update(epoch) {
            val established = synchronized(descriptorLock) { tun != null }
            !established || try {
                setUnderlyingNetworks(selected?.let { arrayOf(it.network) } ?: emptyArray())
            } catch (_: Exception) { false }
        }

    /**
     * Builder.establish runs on the native worker and can outlive a handover.
     * Reconcile its initial snapshot on main before Go starts. All later calls
     * to setUnderlyingNetworks also run there, so an old worker cannot overwrite
     * the new network after the monitor has published it.
     */
    private fun synchronizeUnderlying(generation: Long, deadline: Long) {
        val done = CountDownLatch(1)
        var failure: Throwable? = null
        if (!main.post {
                try {
                    requireCurrent(generation, deadline)
                    val epoch = desired?.epoch ?: throw XrayTunnelFailure("XRAY_TIMEOUT")
                    if (!publishUnderlying(epoch, networks.view().selection?.target)) {
                        throw XrayTunnelFailure("XRAY_CONNECT_FAILED")
                    }
                    requireCurrent(generation, deadline)
                } catch (error: Throwable) { failure = error }
                finally { done.countDown() }
            }) throw XrayTunnelFailure("XRAY_SERVICE_UNAVAILABLE")
        try {
            if (!done.await((deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0), TimeUnit.MILLISECONDS)) {
                throw XrayTunnelFailure("XRAY_TIMEOUT")
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            throw XrayTunnelFailure("XRAY_TIMEOUT")
        }
        requireCurrent(generation, deadline)
        failure?.let { throw it }
    }

    /** Main-thread cancellation precedes any queued native cleanup. */
    private fun clearNetworks() {
        desired = null
        networks.stop()
        networkMonitor?.stop()
        networkMonitor = null
        try { if (ProcessCore.owner === this) setUnderlyingNetworks(emptyArray()) } catch (_: Exception) {}
    }

    private fun ownsSockets(): Boolean =
        ProcessCore.owner === this && !destroyed.get() && !stopping && desired != null

    private fun bindOutbound(fd: Long): Boolean {
        val selection = networks.view().selection ?: return false
        return networks.useCurrent(selection) { target ->
            ownsSockets() && XrayNetworkSockets.bind(target.network, fd) { protect(it) } && ownsSockets()
        }
    }

    private fun dnsTarget(): XrayDnsTarget? {
        val request = desired ?: return null
        val selection = networks.view().selection ?: return null
        if (selection.epoch != request.epoch || !ownsSockets()) return null
        return object : XrayDnsTarget {
            override val hostname = request.hostname
            override fun isCurrent(): Boolean = desired === request && ownsSockets() && networks.isCurrent(selection)
            override fun resolve(): List<InetAddress> =
                if (isCurrent()) selection.target.network.getAllByName(hostname).toList() else emptyList()
        }
    }

    private fun localStatus(): XrayServiceStatus {
        val network = networks.view()
        val owner = ProcessCore.owner
        val occupied = network.desired || nativeActive || owner?.nativeActive == true ||
            synchronized(descriptorLock) { tun != null }
        return XrayServiceStatus.read(
            occupied = occupied,
            blocked = destroyed.get() || stopping || (owner != null && owner !== this) || network.failed,
            coreReady = connected && nativeActive && owner === this,
            starting = startingId != 0 && network.desired,
            changing = network.changing,
            networkAvailable = network.selection != null,
        )
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
        clearNetworks()
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

    private fun replyStatus(destination: Messenger?, id: Int, status: XrayServiceStatus, error: String? = null) {
        if (destination == null) return
        val value = if (error == null) status else status.withFailure(error)
        val response = Message.obtain(null, XrayIpc.REPLY, id, 0).apply {
            data = Bundle().apply {
                putBoolean("connected", value.connected)
                putBoolean("ownsTunnel", value.ownsTunnel)
                putString("state", value.state)
                if (value.error != null) putString("lastErrorCode", value.error)
                if (error != null) putString("error", error)
            }
        }
        try { destination.send(response) } catch (_: Exception) {}
    }

    private fun updateNotification() {
        if (foreground && !stopping && !destroyed.get()) {
            try { showNotification(localStatus().state) } catch (_: Exception) { terminate() }
        }
    }

    private fun showNotification(state: String) {
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
            .setContentText(when (state) {
                "connected" -> "Туннель включён · VLESS"
                "waiting_network" -> "Ожидание сети · VLESS"
                "reconnecting" -> if (startingId != 0) "Подключение…" else "Восстановление сети · VLESS"
                "unknown" -> "Проверка состояния · VLESS"
                else -> "Подключение…"
            })
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
        clearNetworks()
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
        private var dnsAttempted = false
        private var dnsInstalled = false
        private var dns: XrayDnsBridge? = null

        fun ensureDns() {
            if (dnsInstalled) return
            if (dnsAttempted) throw XrayTunnelFailure("XRAY_SERVICE_UNAVAILABLE")
            val bridge = XrayDnsBridge { owner?.dnsTarget() }
            dns = bridge
            // Local bind/selector setup can be retried if it never reached Go.
            // Once the global setter is attempted, it must not be repeated.
            dnsAttempted = true
            LibXray.setDNS(localController, bridge.endpoint)
            dnsInstalled = true
        }

        // Pinned Xray's outbound TCP and UDP paths both invoke dialer
        // Controllers; its separate listener slice is protect-only.
        val outboundController by lazy { DialerController { fd -> owner?.bindOutbound(fd) ?: false } }
        val localController by lazy {
            DialerController { fd ->
                val current = owner
                try {
                    fd in 0..Int.MAX_VALUE.toLong() && current != null &&
                        current.ownsSockets() && current.protect(fd.toInt()) && current.ownsSockets()
                } catch (_: Exception) { false }
            }
        }
    }
}
