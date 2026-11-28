package shop.pushok.flow

import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Process
import android.os.IBinder
import android.os.SystemClock
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import java.io.ByteArrayInputStream
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Process-owned monitor: it retains no Activity and never reauthenticates or edits routes.
 * Switching is enabled only when Android already enforces VPN lockdown. The app never
 * enables that OS setting; excluded/direct applications may need a different policy.
 */
internal class ManagedWireGuardRecovery(
    context: Context,
    private val connection: TunnelConnectionSession,
    private val tunnel: Tunnel,
    private val backend: () -> GoBackend?,
    private val gate: ProfileOperationGate,
) {
    private val app = context.applicationContext
    private val store = SecureWireGuardStore(app)
    private val binding = FlowShopBindingStore(app)
    private val policy = ManagedFailoverPolicy()
    private val timer = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "pushok-managed-wg-recovery").apply { isDaemon = true }
    }
    private val probePool = BoundedNetworkPool("pushok-managed-wg-probe")
    private var scheduled: ScheduledFuture<*>? = null
    @Volatile private var probeCall: BoundedNetworkCall<String>? = null
    @Volatile private var exclusions: Set<String> = emptySet()
    val status: String get() = policy.status

    @Synchronized fun start(profileId: String?, routeExclusions: Set<String>) {
        stop()
        if (profileId == null) return
        val metadata = store.metadata()
        val selected = (metadata["profiles"] as? List<*>)?.mapNotNull { it as? Map<*, *> }
            ?.firstOrNull { it["id"] == profileId } ?: return
        val subscriptionId = selected["subscriptionId"] as? String ?: return
        val subscription = store.subscriptionRecords().firstOrNull { it.id == subscriptionId } ?: return
        if (subscription.format != SubscriptionFeed.MANAGED_WIREGUARD_FORMAT) return
        exclusions = routeExclusions.toSet()
        val token = policy.start(profileId, subscriptionId)
        scheduled = timer.scheduleWithFixedDelay({ check(token) }, 20, 30, TimeUnit.SECONDS)
    }

    @Synchronized fun stop() {
        policy.stop()
        scheduled?.cancel(false)
        scheduled = null
        probeCall?.cancel()
        probeCall = null
    }

    @Synchronized private fun stopCurrent(token: Long) {
        if (policy.current(token)) stop()
    }

    private fun guarded(service: FlowBrowserVpnService? = FlowBrowserVpnService.recoveryService()): Boolean =
        Build.VERSION.SDK_INT >= 29 && service != null && try {
        FlowBrowserVpnService.isRecoveryService(service) && service.isLockdownEnabled
    } catch (_: Exception) { false }

    @Suppress("DEPRECATION")
    private fun physicalNetworkAvailable(): Boolean {
        val manager = app.getSystemService(ConnectivityManager::class.java)
        return manager.allNetworks.any { network ->
            val caps = manager.getNetworkCapabilities(network)
            caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }
    }

    private fun probe(token: Long): String {
        val manager = app.getSystemService(ConnectivityManager::class.java)
        val network = manager.activeNetwork ?: return "unknown"
        fun stillOwned(): Boolean {
            val caps = manager.getNetworkCapabilities(network) ?: return false
            return policy.current(token) && !gate.get() &&
                backend()?.getState(tunnel) == Tunnel.State.UP && manager.activeNetwork == network &&
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                (Build.VERSION.SDK_INT < 29 || caps.ownerUid == Process.myUid())
        }
        if (!stillOwned()) return "unknown"
        val call = probePool.newCall<String>(SystemClock.elapsedRealtime() + 8_000L,
            SystemClock::elapsedRealtime)
        probeCall = call
        return try {
            call.run({ if (!policy.current(token)) throw SubscriptionFailure("SUBSCRIPTION_INTERRUPTED") }) {
                TunnelInternet.check(app, ::stillOwned)
            }
        } catch (error: BoundedNetworkFailure) {
            // A blackholed VPN resolver can ignore interruption. Count its deadline only
            // while this exact owned VPN and a validated physical network still exist.
            if (error.kind == BoundedNetworkFailure.Kind.TIMEOUT && stillOwned() &&
                physicalNetworkAvailable()) "timeout" else "unknown"
        } catch (_: Exception) { "unknown" }
        finally { call.cancel(); if (probeCall === call) probeCall = null }
    }

    private fun check(token: Long) {
        try {
            if (!policy.current(token) || gate.get()) return
            if (backend()?.getState(tunnel) != Tunnel.State.UP) { stopCurrent(token); return }
            val metadata = store.metadata()
            val profileId = metadata["activeProfileId"] as? String ?: return
            val profiles = (metadata["profiles"] as? List<*>)?.mapNotNull { it as? Map<*, *> } ?: return
            val selected = profiles.firstOrNull { it["id"] == profileId } ?: return
            val subscriptionId = selected["subscriptionId"] as? String ?: return
            val source = store.subscriptionRecords().firstOrNull { it.id == subscriptionId } ?: return
            if (source.format != SubscriptionFeed.MANAGED_WIREGUARD_FORMAT) return
            val now = System.currentTimeMillis()
            val valid = source.state == "active" && (source.expiresAt ?: 0L) > now
            val authorized = if (!valid) true else try {
                val raw = store.load(profileId) ?: throw IllegalStateException()
                binding.requireConnectionAllowed(raw, profileId, store, FlowAccountCoordinator.get(app))
                true
            } catch (_: Exception) { false }
            val physical = physicalNetworkAvailable()
            // Keepalives, handshakes and counter growth cannot prove Internet access.
            val response = if (valid && authorized && physical) probe(token) else "unknown"
            val next = policy.observe(token, ManagedFailoverPolicy.Sample(profileId, subscriptionId,
                profiles.filter { it["subscriptionId"] == subscriptionId }.mapNotNull { it["id"] as? String },
                if (valid) source.expiresAt!! else 0L, now, SystemClock.elapsedRealtime(),
                authorized, physical, response, guarded())) ?: return
            connection.io.execute { switch(next) }
        } catch (_: Exception) {
            // Unknown local/storage/network state never authorizes changing the current TUN.
        }
    }

    private fun requireCurrent(change: ManagedFailoverPolicy.Switch) {
        if (!policy.accepts(change)) throw SubscriptionFailure("SUBSCRIPTION_INTERRUPTED")
    }

    private fun config(profileId: String, subscriptionId: String): Pair<String, Config> {
        val metadata = store.metadata()
        val profile = (metadata["profiles"] as? List<*>)?.mapNotNull { it as? Map<*, *> }
            ?.firstOrNull { it["id"] == profileId && it["subscriptionId"] == subscriptionId }
            ?: throw ProfileCatalogFailure("PROFILE_CHANGED")
        val id = profile["id"] as String
        val raw = store.load(id) ?: throw ProfileCatalogFailure("PROFILE_NOT_FOUND")
        binding.requireConnectionAllowed(raw, id, store, FlowAccountCoordinator.get(app))
        RouteAppAvailability.requireForConnection(exclusions) { packageName ->
            try {
                @Suppress("DEPRECATION")
                app.packageManager.getApplicationInfo(packageName, 0)
                true
            } catch (_: PackageManager.NameNotFoundException) { false }
        }
        val clean = WireGuardRouting.prepare(raw, exclusions)
        return raw to Config.parse(ByteArrayInputStream(clean.toByteArray(Charsets.UTF_8)))
    }

    private fun boundLease(subscriptionId: String): FlowShopSessionLease? {
        val bound = binding.binding() ?: return null
        val source = store.subscriptionRecords().firstOrNull { it.id == subscriptionId }
            ?: throw ProfileCatalogFailure("PROFILE_CHANGED")
        if (FlowShopBindingStore.fingerprint(source.url) != bound.urlHash) return null
        val lease = FlowAccountCoordinator.get(app).shopLease()
            ?: throw FlowShopFailure("SHOP_LOGIN_REQUIRED")
        if (!lease.accountId.equals(bound.accountId, ignoreCase = true))
            throw FlowShopFailure("SHOP_ACCOUNT_CHANGED")
        return lease
    }

    private fun switch(change: ManagedFailoverPolicy.Switch) {
        if (!policy.accepts(change)) return
        val token = gate.acquire()
        if (token == null) { policy.defer(change); return }
        val updates = UpdateCoordinator.get(app)
        var success = false
        var changed = false
        var lease: FlowShopSessionLease? = null
        val heldService = FlowBrowserVpnService.recoveryService()
        // BrowserRoutingContext redirects normal GoBackend starts to this subclass.
        // Holding the base service instead would create a second, unrelated instance.
        val serviceIntent = Intent(app, FlowBrowserVpnService::class.java)
        val serviceHold = ManagedServiceHold()
        val serviceConnection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) = serviceHold.connected()
            override fun onServiceDisconnected(name: ComponentName) = serviceHold.disconnected()
            override fun onBindingDied(name: ComponentName) = serviceHold.disconnected()
            override fun onNullBinding(name: ComponentName) = serviceHold.disconnected()
        }
        var bindRequested = false
        fun occupied(): Boolean = backend()?.getState(tunnel) == Tunnel.State.UP
        fun down(): Boolean {
            backend()?.setState(tunnel, Tunnel.State.DOWN, null)
            return occupied()
        }
        fun activate(profileId: String, candidate: Pair<String, Config>): Boolean =
            ManagedActivation.connect(validate = {
                requireCurrent(change)
                if (!serviceHold.ready) throw IllegalStateException()
                if (heldService == null || !FlowBrowserVpnService.isRecoveryService(heldService))
                    throw IllegalStateException()
                store.validateActive(profileId, candidate.first)
                val account = FlowAccountCoordinator.get(app)
                lease?.let(account::requireShopLease)
                binding.requireConnectionAllowed(candidate.first, profileId, store, account)
            }, activate = {
                // DOWN calls VpnService.stopSelf(). Our acknowledged binding keeps the
                // same service alive; restart its started lifetime before releasing it.
                if (app.startService(serviceIntent) == null) throw IllegalStateException()
                requireCurrent(change)
                if (!serviceHold.ready) throw IllegalStateException()
                if (!guarded(heldService)) throw IllegalStateException()
                FlowBrowserVpnService.beginTunnelBuild()
                backend()?.setState(tunnel, Tunnel.State.UP, candidate.second) == Tunnel.State.UP
            }, deactivate = { connection.disconnect(::occupied, ::down) })
        try {
            requireCurrent(change)
            if (!updates.beginConnection(token) || !guarded(heldService) || !occupied()) return
            if (store.metadata()["activeProfileId"] != change.fromProfileId) return
            lease = boundLease(change.subscriptionId)
            val candidate = config(change.toProfileId, change.subscriptionId)
            // A bound started service survives stopSelf until its clients unbind.
            // Never tear down the old TUN without an acknowledged, bounded hold.
            bindRequested = true
            if (!app.bindService(Intent(serviceIntent).setAction(VpnService.SERVICE_INTERFACE),
                    serviceConnection, Context.BIND_AUTO_CREATE) ||
                !serviceHold.awaitReady({ policy.accepts(change) })) return
            // Nothing below may run after Stop, a new intent, loss of authority or OS protection.
            requireCurrent(change)
            if (!guarded(heldService)) return
            lease?.let(FlowAccountCoordinator.get(app)::requireShopLease)
            changed = true
            connection.disconnect(::occupied, ::down)
            requireCurrent(change)
            store.select(change.toProfileId)
            store.validateActive(change.toProfileId, candidate.first)
            binding.requireConnectionAllowed(candidate.first, change.toProfileId,
                store, FlowAccountCoordinator.get(app))
            requireCurrent(change)
            success = connection.connect(::occupied) { activate(change.toProfileId, candidate) }
            // A user Stop can arrive while Android is establishing the replacement TUN.
            if (!policy.accepts(change)) { connection.disconnect(::occupied, ::down); success = false }
        } catch (_: Exception) {
            // Restore only the original, still-authorized profile, never another subscription.
            if (changed && policy.accepts(change) && guarded()) try {
                if (occupied()) {
                    if (!guarded()) throw IllegalStateException()
                    connection.disconnect(::occupied, ::down)
                }
                val previous = config(change.fromProfileId, change.subscriptionId)
                requireCurrent(change)
                store.select(change.fromProfileId)
                connection.connect(::occupied) { activate(change.fromProfileId, previous) }
                if (!policy.accepts(change)) connection.disconnect(::occupied, ::down)
            } catch (_: Exception) { }
        } finally {
            if (changed && !policy.current(change.generation)) {
                try { connection.disconnect(::occupied, ::down) } catch (_: Exception) { }
            }
            if (changed) policy.complete(change, success) else policy.defer(change)
            val upOrUnknown = try { occupied() } catch (_: Exception) { true }
            if (changed && !upOrUnknown) {
                try { app.stopService(serviceIntent) } catch (_: Exception) { }
            }
            serviceHold.disconnected()
            if (bindRequested) try { app.unbindService(serviceConnection) } catch (_: Exception) { }
            updates.observeTunnel(upOrUnknown)
            updates.endConnection(token)
            gate.release(token)
            try { FlowWidget.render(app, if (upOrUnknown) "wireguard" else "disconnected") } catch (_: Exception) { }
        }
    }
}
