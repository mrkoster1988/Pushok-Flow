package shop.pushok.flow

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.lang.ref.WeakReference
import java.net.URL
import java.security.PublicKey
import java.security.cert.CertificateFactory
import java.security.interfaces.RSAPublicKey
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.HttpsURLConnection

/** Explicit user refreshes fetch suggestions only. No profile, route or tunnel store is referenced. */
class RouteRecommendations(activity: Activity) {
    private val context = activity.applicationContext
    private val activityReference = WeakReference(activity)
    private val main = Handler(Looper.getMainLooper())
    private val lifecycleLock = Any()
    private val disposed = AtomicBoolean(false)
    private val foreground = AtomicBoolean(false)
    private val foregroundEpoch = AtomicLong(0)
    private val busy = AtomicBoolean(false)
    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    @Volatile private var connection: HttpsURLConnection? = null
    @Volatile private var errorCode: String? = null
    private val signingKey: PublicKey? = try { installedSigningKey() } catch (_: Exception) { null }
    private val store = RouteRecommendationStore(PrivateStorage()) { bytes ->
        val key = signingKey ?: throw RouteRecommendationFailure("RECOMMENDATIONS_UNAVAILABLE")
        RouteRecommendationPolicy.verify(bytes, key)
    }

    companion object {
        // Shared across Activity recreation: an older writer cannot race a newer cache restore/write.
        private val io = Executors.newSingleThreadExecutor()
        private const val CHECK_TIMEOUT_MS = 40_000L
    }

    fun register(messenger: BinaryMessenger) {
        check(!disposed.get())
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, "shop.pushok.flow/route_recommendations").also { registered ->
            registered.setMethodCallHandler { call, result ->
                when (call.method) {
                    "recommendationStatus" -> recommendationStatus(result)
                    "refreshRecommendations" -> refreshRecommendations(result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun setForeground(value: Boolean) {
        synchronized(lifecycleLock) {
            if (!value) foregroundEpoch.incrementAndGet()
            foreground.set(value && !disposed.get())
        }
        if (!value) disconnect()
    }

    fun dispose() {
        synchronized(lifecycleLock) {
            if (!disposed.compareAndSet(false, true)) return
            foreground.set(false)
            foregroundEpoch.incrementAndGet()
        }
        disconnect()
        channel?.setMethodCallHandler(null)
        channel = null
        val result = pendingResult
        pendingResult = null
        busy.set(false)
        if (result != null) result.success(snapshot("RECOMMENDATIONS_INTERRUPTED"))
        activityReference.clear()
    }

    private fun disconnect() {
        try { connection?.disconnect() } catch (_: Exception) { /* Cancel without exposing network errors. */ }
    }

    private fun snapshot(errorOverride: String? = null): Map<String, Any?> {
        val current = store.snapshot()
        return mapOf(
            "rulesVersion" to current.recommendations.rulesVersion,
            "packages" to current.recommendations.packages,
            "checkedAtMillis" to current.checkedAtMillis,
            "busy" to busy.get(),
            "errorCode" to (errorOverride ?: errorCode),
        )
    }

    private fun recommendationStatus(result: MethodChannel.Result) {
        if (busy.get()) {
            result.success(snapshot())
            return
        }
        runIo(result, null) { store.restore { action -> guarded(null, action) } }
    }

    private fun refreshRecommendations(result: MethodChannel.Result) {
        val epoch = foregroundEpoch.get()
        val deadline = SystemClock.elapsedRealtime() + CHECK_TIMEOUT_MS
        try { ensureActive(epoch) }
        catch (failure: RouteRecommendationFailure) {
            result.success(snapshot(failure.code))
            return
        }
        runIo(result, epoch) {
            // Re-read on the shared queue in case another Activity accepted a newer catalogue.
            try { store.restore { action -> guarded(epoch, action) } }
            catch (failure: RouteRecommendationFailure) {
                if (failure.code == "RECOMMENDATIONS_INTERRUPTED" ||
                    failure.code == "RECOMMENDATIONS_UNAVAILABLE") throw failure
                // The last verified in-memory catalogue survives. An explicit signed refresh
                // can repair a damaged/missing cache, while freshness still uses that catalogue.
            }
            val envelope = fetch(epoch, deadline)
            ensureActive(epoch)
            store.accept(envelope, System.currentTimeMillis()) { action -> guarded(epoch, action) }
        }
    }

    private fun runIo(result: MethodChannel.Result, epoch: Long?, action: () -> Unit) {
        if (disposed.get()) {
            result.success(snapshot("RECOMMENDATIONS_INTERRUPTED"))
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.success(snapshot("RECOMMENDATIONS_BUSY"))
            return
        }
        pendingResult = result
        errorCode = null
        io.execute {
            var failure: String? = null
            try {
                ensureActive(epoch)
                if (signingKey == null) throw RouteRecommendationFailure("RECOMMENDATIONS_UNAVAILABLE")
                action()
            } catch (error: RouteRecommendationFailure) {
                failure = error.code
            } catch (_: Exception) {
                failure = "RECOMMENDATIONS_UNAVAILABLE"
            }
            // Disconnection often surfaces as IOException; interruption remains the useful result.
            try { ensureActive(epoch) } catch (_: RouteRecommendationFailure) {
                failure = "RECOMMENDATIONS_INTERRUPTED"
            }
            val completedError = failure
            main.post {
                if (disposed.get() || pendingResult !== result) return@post
                errorCode = completedError
                pendingResult = null
                busy.set(false)
                result.success(snapshot())
            }
        }
    }

    private fun guarded(epoch: Long?, action: () -> Unit) = synchronized(lifecycleLock) {
        // Final atomic replacement and in-memory acknowledgement occur under this same lock.
        // Pause/dispose therefore either precedes the whole commit or follows a completed commit.
        ensureActive(epoch)
        action()
    }

    private fun ensureActive(epoch: Long?) {
        if (disposed.get() || Thread.currentThread().isInterrupted) {
            throw RouteRecommendationFailure("RECOMMENDATIONS_INTERRUPTED")
        }
        if (epoch != null) {
            val activity = activityReference.get()
            if (!foreground.get() || foregroundEpoch.get() != epoch ||
                activity == null || activity.isFinishing || activity.isDestroyed) {
                throw RouteRecommendationFailure("RECOMMENDATIONS_INTERRUPTED")
            }
        }
    }

    private fun fetch(epoch: Long, deadline: Long): ByteArray {
        ensureActive(epoch)
        var remote: HttpsURLConnection? = null
        try {
            remote = URL(RouteRecommendationPolicy.URL).openConnection() as? HttpsURLConnection
                ?: throw RouteRecommendationFailure("RECOMMENDATIONS_NETWORK_ERROR")
            connection = remote
            ensureActive(epoch)
            remote.instanceFollowRedirects = false
            remote.connectTimeout = remainingTimeout(deadline, 10_000)
            remote.readTimeout = remainingTimeout(deadline, 10_000)
            remote.useCaches = false
            remote.setRequestProperty("Accept", "application/json")
            remote.setRequestProperty("Accept-Encoding", "identity")
            remote.setRequestProperty("Cache-Control", "no-cache, max-age=0")
            remote.setRequestProperty("User-Agent", "Pushok-Flow-Route-Recommendations")
            if (remote.responseCode != 200) throw RouteRecommendationFailure("RECOMMENDATIONS_NETWORK_ERROR")
            if (remote.contentLengthLong > RouteRecommendationPolicy.MAX_ENVELOPE_BYTES ||
                remote.contentEncoding?.let { it.isNotBlank() && !it.equals("identity", ignoreCase = true) } == true) {
                throw RouteRecommendationFailure("RECOMMENDATIONS_INVALID")
            }
            val active = remote
            return remote.inputStream.use { input ->
                boundedRead(input) {
                    ensureActive(epoch)
                    active.readTimeout = remainingTimeout(deadline, 10_000)
                }
            }
        } catch (failure: RouteRecommendationFailure) {
            throw failure
        } catch (_: Exception) {
            throw RouteRecommendationFailure("RECOMMENDATIONS_NETWORK_ERROR")
        } finally {
            try { remote?.disconnect() } catch (_: Exception) { /* No raw URLs in diagnostics. */ }
            if (connection === remote) connection = null
        }
    }

    private fun remainingTimeout(deadline: Long, maximum: Int): Int {
        val left = deadline - SystemClock.elapsedRealtime()
        if (left <= 0) throw RouteRecommendationFailure("RECOMMENDATIONS_NETWORK_ERROR")
        return left.coerceAtMost(maximum.toLong()).toInt()
    }

    private fun boundedRead(input: InputStream, beforeRead: () -> Unit = {}): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            beforeRead()
            val count = input.read(buffer)
            if (count == -1) break
            if (count > RouteRecommendationPolicy.MAX_ENVELOPE_BYTES - output.size()) {
                throw RouteRecommendationFailure("RECOMMENDATIONS_INVALID")
            }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    @Suppress("DEPRECATION")
    private fun installedSigningKey(): PublicKey? {
        val info = context.packageManager.getPackageInfo(context.packageName,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES
            else PackageManager.GET_SIGNATURES)
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            info.signingInfo?.apkContentsSigners?.toList().orEmpty()
            else info.signatures?.toList().orEmpty()
        val signer = signatures.singleOrNull() ?: return null
        return CertificateFactory.getInstance("X.509").generateCertificate(
            ByteArrayInputStream(signer.toByteArray())).publicKey as? RSAPublicKey
    }

    private inner class PrivateStorage : RouteRecommendationStorage {
        private fun file(): AtomicFile {
            val directory = context.filesDir.canonicalFile
            val base = File(directory, "route-recommendations.json")
            // AtomicFile may also restore/delete its two implementation sidecars.
            for (name in listOf(base.name, "${base.name}.new", "${base.name}.bak")) {
                val item = File(directory, name)
                if (item.canonicalFile != item.absoluteFile) {
                    throw RouteRecommendationFailure("RECOMMENDATIONS_STORAGE_ERROR")
                }
            }
            return AtomicFile(base)
        }

        override fun read(): ByteArray? {
            val atomic = file()
            return try { atomic.openRead().use { boundedRead(it) } }
            catch (_: FileNotFoundException) {
                if (atomic.baseFile.exists()) throw RouteRecommendationFailure("RECOMMENDATIONS_STORAGE_ERROR")
                null
            }
        }

        override fun replace(value: ByteArray, commit: (write: () -> Unit) -> Unit) {
            val atomic = file()
            val output = atomic.startWrite()
            replaceRecommendationFile(
                prepare = {
                    output.write(value)
                    // Propagate sync failure before the prior committed record is replaced.
                    output.fd.sync()
                },
                finish = { atomic.finishWrite(output) },
                verifyCommitted = {
                    // AtomicFile can report a rename error only in logcat; verify the exact result.
                    val saved = atomic.openRead().use { boundedRead(it) }
                    if (!saved.contentEquals(value)) throw RouteRecommendationFailure("RECOMMENDATIONS_STORAGE_ERROR")
                },
                abortUnfinished = { atomic.failWrite(output) },
                commit = commit,
            )
        }
    }
}
