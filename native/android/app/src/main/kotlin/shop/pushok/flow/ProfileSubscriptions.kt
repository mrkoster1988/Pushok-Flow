package shop.pushok.flow

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Explicit imports and opted-in checks while Flow is visible; never starts a tunnel. */
class ProfileSubscriptions(
    activity: Activity,
    private val store: SecureWireGuardStore,
    // MainActivity supplies its process-wide tunnel/profile operation gate and native DOWN check.
    private val commit: (action: () -> Unit, completed: (String?) -> Unit) -> Unit,
) {
    private val context = activity.applicationContext
    private val activityReference = WeakReference(activity)
    private val main = Handler(Looper.getMainLooper())
    private val settings = context.getSharedPreferences("flow_subscription_settings", Context.MODE_PRIVATE)
    private val lifecycleLock = Any()
    private val disposed = AtomicBoolean(false)
    private val foreground = AtomicBoolean(false)
    private val epoch = AtomicLong(0)
    private val downloader = SubscriptionDownloader()
    private val shopBridge = FlowShopBridgeClient(context)
    private val shopBinding = FlowShopBindingStore(context)
    @Volatile private var shopSyncState: String = "idle"
    private val pendingResults = mutableSetOf<MethodChannel.Result>()
    private var channel: MethodChannel? = null
    @Volatile private var automatic = false
    @Volatile private var enabled = readEnabled()
    @Volatile private var errorCode: String? = null
    // Session-only outcomes, protected by lifecycleLock. Identity includes the private URL,
    // but the public snapshot contains only current IDs and constant error codes.
    private class RefreshError(val url: String, val code: String) {
        override fun toString() = "RefreshError(<redacted>)"
    }
    private val refreshErrors = mutableMapOf<String, RefreshError>()

    companion object {
        private val network = Executors.newSingleThreadExecutor()
        private val reads = Executors.newSingleThreadExecutor()
        private val busy = AtomicBoolean(false)
        private var pendingDraft: SubscriptionLinks.Draft? = null
        private var pendingAt = 0L
        private const val PENDING_LINK_TTL_MS = 10 * 60_000L
        private val PROVIDER_ERRORS = setOf("SUBSCRIPTION_URL_INVALID", "SUBSCRIPTION_INVALID",
            "SUBSCRIPTION_TOO_LARGE", "SUBSCRIPTION_EMPTY", "SUBSCRIPTION_UNSUPPORTED",
            "SUBSCRIPTION_NETWORK_ERROR", "SUBSCRIPTION_TLS_ERROR", "SUBSCRIPTION_AUTH_REQUIRED")
    }

    fun register(messenger: BinaryMessenger) {
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, "shop.pushok.flow/subscriptions").also { registered ->
            registered.setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> status(result)
                    "syncShop" -> request(result) { operationEpoch ->
                        syncShop(operationEpoch)
                    }
                    "unlinkShop" -> request(result) { operationEpoch ->
                        guardedWrite(operationEpoch) {
                            shopBinding.unlink(store)
                            shopSyncState = "idle"
                        }
                    }
                    "setShopAutoSync" -> {
                        val args = call.arguments as? Map<*, *>
                        val enabled = args?.get("enabled") as? Boolean
                        if (args?.keys != setOf("enabled") || enabled == null) {
                            failure(result, "SUBSCRIPTION_INVALID")
                        } else setShopAutoSync(enabled, result)
                    }
                    "takePendingLink" -> result.success(takePendingLink())
                    "openPushokAccount" -> openPushokLink(PushokExternalLinks.Destination.ACCOUNT, result)
                    "openPushokHub" -> openPushokLink(PushokExternalLinks.Destination.HUB, result)
                    "setAutomaticUpdates" -> {
                        val value = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
                        if (value == null) failure(result, "SUBSCRIPTION_INVALID")
                        else setAutomaticUpdates(value, result)
                    }
                    "importSubscription" -> {
                        val args = call.arguments as? Map<*, *>
                        val name = args?.get("name") as? String
                        val url = args?.get("url") as? String
                        if (name == null || url == null) failure(result, "SUBSCRIPTION_INVALID")
                        else request(result) { operationEpoch ->
                            val validatedName = ProfileCatalogStore.normalizedName(name)
                            val normalizedUrl = SubscriptionPolicy.normalizeUrl(url)
                            if (store.subscriptionRecords().any { it.url == normalizedUrl }) {
                                throw SubscriptionFailure("SUBSCRIPTION_EXISTS")
                            }
                            guardedWrite(operationEpoch) { }
                            val response = downloader.fetch(normalizedUrl) { ensureActive(operationEpoch) }
                            val feed = try { SubscriptionFeed.parse(response.body, response.userInfo, response.title) }
                                finally { response.body.fill(0) }
                            guardedWrite(operationEpoch) {
                                store.importSubscription(validatedName, normalizedUrl, feed, System.currentTimeMillis())
                            }
                        }
                    }
                    "refreshSubscription" -> {
                        val id = (call.arguments as? Map<*, *>)?.get("id") as? String
                        if (id == null || !ProfileCatalogStore.validId(id)) failure(result, "SUBSCRIPTION_NOT_FOUND")
                        else request(result) { operationEpoch ->
                            val record = store.subscriptionRecords().firstOrNull { it.id == id }
                                ?: throw SubscriptionFailure("SUBSCRIPTION_NOT_FOUND")
                            refresh(record, operationEpoch)
                        }
                    }
                    "deleteSubscription" -> {
                        val id = (call.arguments as? Map<*, *>)?.get("id") as? String
                        if (id == null || !ProfileCatalogStore.validId(id)) failure(result, "SUBSCRIPTION_NOT_FOUND")
                        else request(result) { operationEpoch ->
                            guardedWrite(operationEpoch) {
                                store.deleteSubscription(id)
                                refreshErrors.remove(id)
                            }
                            settings.edit().remove("attempt_$id").apply()
                        }
                    }
                    "refreshDue" -> {
                        if (!enabled || hasPendingLink()) status(result)
                        else request(result, isAutomatic = true) { operationEpoch ->
                            for (record in store.subscriptionRecords()) {
                                ensureActive(operationEpoch)
                                val now = System.currentTimeMillis()
                                val attempt = settings.getLong("attempt_${record.id}", 0L)
                                if (SubscriptionRefreshPolicy.due(now, record.updatedAt, attempt)) {
                                    refresh(record, operationEpoch, isolateProviderFailure = true)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun setForeground(value: Boolean) {
        synchronized(lifecycleLock) {
            if (!value) epoch.incrementAndGet()
            if (value) enabled = readEnabled()
            foreground.set(value && !disposed.get())
        }
        if (!value) downloader.cancel()
        else if (hasPendingLink()) channel?.invokeMethod("pendingLinkAvailable", null)
    }

    fun acceptLink(raw: String?) {
        val parsed = SubscriptionLinks.parse(raw) ?: return
        synchronized(ProfileSubscriptions::class.java) {
            pendingDraft = parsed
            pendingAt = SystemClock.elapsedRealtime()
        }
        if (foreground.get()) channel?.invokeMethod("pendingLinkAvailable", null)
    }

    private fun hasPendingLink(): Boolean = synchronized(ProfileSubscriptions::class.java) {
        val elapsed = SystemClock.elapsedRealtime() - pendingAt
        if (elapsed < 0 || elapsed > PENDING_LINK_TTL_MS) pendingDraft = null
        pendingDraft != null
    }

    private fun takePendingLink(): Map<String, Any?>? {
        if (!foreground.get() || disposed.get()) return null
        return synchronized(ProfileSubscriptions::class.java) {
            if (!hasPendingLink()) return@synchronized null
            val draft = pendingDraft
            pendingDraft = null
            draft?.metadata()
        }
    }

    private fun openPushokLink(destination: PushokExternalLinks.Destination, result: MethodChannel.Result) {
        try {
            ensureActive(epoch.get())
            val activity = activityReference.get() ?: throw SubscriptionFailure("SUBSCRIPTION_INTERRUPTED")
            PushokExternalLinks.open(destination) { url ->
                activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            }
            result.success(true)
        } catch (_: Exception) {
            failure(result, when (destination) {
                PushokExternalLinks.Destination.ACCOUNT -> "PUSHOK_ACCOUNT_UNAVAILABLE"
                PushokExternalLinks.Destination.HUB -> "PUSHOK_HUB_UNAVAILABLE"
            })
        }
    }

    private fun setShopAutoSync(value: Boolean, result: MethodChannel.Result) {
        if (disposed.get()) { failure(result, "SUBSCRIPTION_INTERRUPTED"); return }
        pendingResults.add(result)
        reads.execute {
            var failureCode: String? = null
            try {
                if (!settings.edit().putBoolean("shop_auto_sync", value).commit()) {
                    throw SubscriptionFailure("SUBSCRIPTION_STORE_FAILED")
                }
            } catch (_: Exception) { failureCode = "SUBSCRIPTION_STORE_FAILED" }
            main.post {
                if (pendingResults.remove(result)) {
                    if (failureCode != null) failure(result, failureCode!!)
                    else status(result)
                }
            }
        }
    }

    private fun syncShop(operationEpoch: Long) {
        ensureActive(operationEpoch)
        val coordinator = FlowAccountCoordinator.get(context)
        val lease = coordinator.shopLease() ?: throw FlowShopFailure("SHOP_LOGIN_REQUIRED")
        shopBinding.requireOwner(lease.accountId)
        val reply = shopBridge.exchange(lease.token) {
            ensureActive(operationEpoch)
            coordinator.requireShopLease(lease)
        }
        if (reply.state != "active") {
            synchronized(lifecycleLock) {
                ensureActive(operationEpoch)
                coordinator.requireShopLease(lease)
                shopSyncState = reply.state
            }
            return
        }
        val rawUrl = reply.url ?: throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
        val url = try { SubscriptionPolicy.normalizeUrl(rawUrl) }
            catch (_: SubscriptionFailure) { throw FlowShopFailure("SHOP_PROTOCOL_INVALID") }
        // Never import a subscription from a caller-controlled domain. Shop URLs are
        // returned only from the signed identity exchange and checked again here.
        if (!url.startsWith("https://pushok.shop/shop/flow/wireguard/")) {
            throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
        }
        val response = downloader.fetch(url) {
            ensureActive(operationEpoch)
            coordinator.requireShopLease(lease)
        }
        val feed = try { SubscriptionFeed.parse(response.body, response.userInfo, response.title) }
            finally { response.body.fill(0) }
        if (feed.format != SubscriptionFeed.MANAGED_WIREGUARD_FORMAT) {
            throw FlowShopFailure("SHOP_PROTOCOL_INVALID")
        }
        // This entire block holds the existing MainActivity operation gate and
        // verifies the tunnel is DOWN. It never starts a connection.
        guardedWrite(operationEpoch) {
            coordinator.requireShopLease(lease)
            shopBinding.requireOwner(lease.accountId)
            val previous = store.subscriptionRecords()
            val linked = previous.firstOrNull { it.url == url }
            // The binding commits BEFORE any personal configuration can be written.
            shopBinding.bind(lease.accountId, url)
            if (linked == null) {
                store.importSubscription("Моё подключение Pushok", url, feed, System.currentTimeMillis())
            } else {
                store.refreshSubscription(linked.id, linked.url, feed, System.currentTimeMillis())
            }
            shopSyncState = "active"
        }
    }

    private fun setAutomaticUpdates(value: Boolean, result: MethodChannel.Result) {
        // The toggle is explicit and local. Persist OFF even if opening a system screen pauses Flow.
        if (disposed.get()) { failure(result, "SUBSCRIPTION_INTERRUPTED"); return }
        if (!value) {
            // Serialize OFF with the final guarded catalogue commit: an already started
            // atomic replacement finishes first; a later automatic commit sees OFF.
            synchronized(lifecycleLock) { enabled = false }
            if (automatic) downloader.cancel()
        }
        pendingResults.add(result)
        reads.execute {
            var code: String? = null
            try {
                if (!settings.edit().putBoolean("enabled", value).commit()) {
                    throw SubscriptionFailure("SUBSCRIPTION_STORE_FAILED")
                }
                enabled = value
            } catch (_: Exception) {
                code = "SUBSCRIPTION_STORE_FAILED"
                // Fail closed after an uncertain write, never silently restart automatic traffic.
                enabled = false
            }
            val outcome = code
            main.post {
                if (pendingResults.remove(result)) {
                    if (outcome == null) status(result) else failure(result, outcome)
                }
            }
        }
    }

    private fun status(result: MethodChannel.Result) {
        if (disposed.get()) { failure(result, "SUBSCRIPTION_INTERRUPTED"); return }
        pendingResults.add(result)
        reads.execute {
            val snapshot = try { snapshot() } catch (_: Exception) { null }
            main.post {
                if (pendingResults.remove(result)) {
                    if (snapshot != null) result.success(snapshot)
                    else failure(result, "SUBSCRIPTION_STATE_UNAVAILABLE")
                }
            }
        }
    }

    private fun readEnabled(): Boolean = try { settings.getBoolean("enabled", true) }
        catch (_: Exception) { false }

    private fun snapshot(): Map<String, Any?> {
        val metadata = store.subscriptions()
        val records = store.subscriptionRecords()
        val visibleIds = (metadata["subscriptions"] as List<*>).map { (it as Map<*, *>)["id"] }.toSet()
        val failures = synchronized(lifecycleLock) {
            pruneRefreshErrors(records)
            refreshErrors.filterKeys { it in visibleIds }.mapValues { it.value.code }
        }
        return metadata + mapOf(
            "automaticUpdatesEnabled" to enabled,
            // First-login onboarding defaults to auto-import. Explicit user OFF persists.
            "shopAutoSyncEnabled" to settings.getBoolean("shop_auto_sync", true),
            "shopSyncState" to shopSyncState,
            "busy" to busy.get(),
            "errorCode" to errorCode,
            "refreshErrors" to failures,
        )
    }

    private fun request(result: MethodChannel.Result, isAutomatic: Boolean = false,
        action: (Long) -> Unit) {
        val operationEpoch = epoch.get()
        try { ensureActive(operationEpoch, isAutomatic) }
        catch (problem: SubscriptionFailure) { failure(result, problem.code); return }
        if (!busy.compareAndSet(false, true)) { failure(result, "SUBSCRIPTION_BUSY"); return }
        pendingResults.add(result)
        automatic = isAutomatic
        errorCode = null
        network.execute {
            var code: String? = null
            try {
                ensureActive(operationEpoch)
                action(operationEpoch)
            } catch (error: Exception) { code = safeError(error) }
            finally {
                downloader.cancel()
                automatic = false
                busy.set(false)
            }
            errorCode = code
            val completedCode = code
            val snapshot = try { snapshot() } catch (_: Exception) { null }
            main.post {
                if (pendingResults.remove(result)) {
                    if (completedCode != null) failure(result, completedCode)
                    else if (snapshot != null) result.success(snapshot)
                    else failure(result, "SUBSCRIPTION_STATE_UNAVAILABLE")
                }
            }
        }
    }

    private fun refresh(record: StoredSubscription, operationEpoch: Long,
        isolateProviderFailure: Boolean = false) {
        // Reserve only after the authoritative tunnel-state check succeeds. An active Flow
        // connection does not consume the retry window or lose its selected configuration.
        guardedWrite(operationEpoch) { }
        if (!settings.edit().putLong("attempt_${record.id}", System.currentTimeMillis()).commit()) {
            throw SubscriptionFailure("SUBSCRIPTION_STORE_FAILED")
        }
        val feed = try {
            val response = downloader.fetch(record.url) { ensureActive(operationEpoch) }
            try { SubscriptionFeed.parse(response.body, response.userInfo, response.title) }
                finally { response.body.fill(0) }
        } catch (failure: SubscriptionFailure) {
            if (failure.code !in PROVIDER_ERRORS) throw failure
            synchronized(lifecycleLock) {
                // OFF, pause and disposal dominate a concurrent provider error. Never
                // publish it as a completed attempt or proceed to another provider.
                ensureActive(operationEpoch)
                val records = store.subscriptionRecords()
                val current = records.firstOrNull { it.id == record.id }
                    ?: throw SubscriptionFailure("SUBSCRIPTION_NOT_FOUND")
                if (current.url != record.url) throw SubscriptionFailure("SUBSCRIPTION_CHANGED")
                pruneRefreshErrors(records)
                refreshErrors[record.id] = RefreshError(record.url, failure.code)
            }
            if (isolateProviderFailure) return
            throw failure
        }
        // Only the download/parse boundary above may be isolated. Catalog, capacity,
        // tunnel and settings errors remain fatal even if their public code overlaps.
        guardedWrite(operationEpoch) {
            store.refreshSubscription(record.id, record.url, feed, System.currentTimeMillis())
            refreshErrors.remove(record.id)
        }
    }

    /** Caller holds lifecycleLock; removed/replaced records never inherit an older outcome. */
    private fun pruneRefreshErrors(records: List<StoredSubscription>) {
        refreshErrors.entries.removeAll { (id, failure) ->
            records.none { it.id == id && it.url == failure.url }
        }
    }

    /** The network never owns the tunnel lock. A fresh native DOWN check gates just the commit. */
    private fun guardedWrite(operationEpoch: Long, action: () -> Unit) {
        ensureActive(operationEpoch)
        val latch = CountDownLatch(1)
        val allowed = AtomicBoolean(true)
        var error: String? = null
        main.post {
            try {
                ensureActive(operationEpoch)
                commit({
                    synchronized(lifecycleLock) {
                        ensureActive(operationEpoch)
                        if (!allowed.get()) throw SubscriptionFailure("SUBSCRIPTION_INTERRUPTED")
                        action()
                    }
                }) { code -> error = code; latch.countDown() }
            } catch (failure: Exception) {
                error = safeError(failure)
                latch.countDown()
            }
        }
        val deadline = SystemClock.elapsedRealtime() + 20_000L
        try {
            while (!latch.await(200, TimeUnit.MILLISECONDS)) {
                ensureActive(operationEpoch)
                if (SystemClock.elapsedRealtime() >= deadline) {
                    throw SubscriptionFailure("SUBSCRIPTION_BUSY")
                }
            }
            error?.let {
                if (it.startsWith("VPN_") || it.startsWith("PROFILE_")) throw ProfileCatalogFailure(it)
                throw SubscriptionFailure(it)
            }
        } finally { allowed.set(false) }
    }

    private fun ensureActive(operationEpoch: Long, automaticOverride: Boolean = automatic) {
        val activity = activityReference.get()
        if (disposed.get() || !foreground.get() || epoch.get() != operationEpoch ||
            activity == null || activity.isDestroyed || activity.isFinishing ||
            Thread.currentThread().isInterrupted || (automaticOverride && !enabled)) {
            throw SubscriptionFailure("SUBSCRIPTION_INTERRUPTED")
        }
    }

    private fun safeError(error: Exception): String = when (error) {
        is FlowShopFailure -> error.code
        is SubscriptionFailure -> error.code
        is ProfileCatalogFailure -> error.code.takeIf { it in setOf("PROFILE_NAME_INVALID",
            "PROFILE_LIMIT_REACHED", "PROFILE_STORE_UNAVAILABLE", "PROFILE_MANAGED",
            "VPN_ACTIVE", "VPN_BUSY", "VPN_STATE_UNAVAILABLE") } ?: "SUBSCRIPTION_STORE_FAILED"
        else -> "SUBSCRIPTION_UNAVAILABLE"
    }

    private fun failure(result: MethodChannel.Result, code: String) {
        result.error(code, "Не удалось выполнить действие с подпиской", null)
    }

    fun dispose() {
        synchronized(lifecycleLock) {
            if (!disposed.compareAndSet(false, true)) return
            foreground.set(false)
            epoch.incrementAndGet()
        }
        downloader.cancel()
        channel?.setMethodCallHandler(null)
        channel = null
        val results = pendingResults.toList()
        pendingResults.clear()
        results.forEach { failure(it, "SUBSCRIPTION_INTERRUPTED") }
        activityReference.clear()
    }
}
