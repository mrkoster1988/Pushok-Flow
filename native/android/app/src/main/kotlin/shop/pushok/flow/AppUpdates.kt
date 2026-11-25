package shop.pushok.flow

import android.app.Activity
import android.Manifest
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** A concrete provider avoids device-specific failures of a bare FileProvider. */
class UpdateFileProvider : FileProvider()

/** Activity-only UI bridge. Network, files, scheduling and install sessions belong to the application. */
class AppUpdates(activity: Activity) {
    private val context = activity.applicationContext
    private val activityReference = WeakReference(activity)
    private val coordinator = UpdateCoordinator.get(context)
    private val disposed = AtomicBoolean(false)
    private val foreground = AtomicBoolean(true)
    private val foregroundEpoch = AtomicLong(0)
    private val results = mutableSetOf<MethodChannel.Result>()
    private var channel: MethodChannel? = null

    init {
        // Construction happens while configuring the visible Activity, before onResume.
        coordinator.setForeground(this, true)
        coordinator.initialize()
    }

    fun register(messenger: BinaryMessenger) {
        check(!disposed.get())
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, "shop.pushok.flow/updates").also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateStatus" -> {
                        coordinator.reconcileIfExpired()
                        result.success(coordinator.snapshot())
                    }
                    "checkForUpdates" -> request(result) { done -> coordinator.runManual("check", done) }
                    "downloadUpdate" -> {
                        requestDownloadNotifications()
                        request(result) { done -> coordinator.requestDownload(done) }
                    }
                    "setAutomaticUpdates" -> {
                        val enabled = (call.arguments as? Map<*, *>)?.get("enabled") as? Boolean
                        if (enabled == null) result.error("UPDATE_ARGUMENT_INVALID", "Нужен параметр enabled", null)
                        else request(result) { done -> coordinator.setAutomaticUpdates(enabled, done) }
                    }
                    "openInstallPermission" -> openInstallPermission(result)
                    "installUpdate" -> installUpdate(result)
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
    fun beginConnection(token: Long): Boolean = coordinator.beginConnection(token)
    fun endConnection(token: Long) = coordinator.endConnection(token)
    fun observeTunnel(upOrUnknown: Boolean) = coordinator.observeTunnel(upOrUnknown)

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        setForeground(false)
        channel?.setMethodCallHandler(null)
        channel = null
        val pending = results.toList()
        results.clear()
        pending.forEach { it.success(coordinator.snapshot("UPDATE_INTERRUPTED")) }
        activityReference.clear()
        // Deliberately do not cancel coordinator work or delete a resumable/verified APK.
    }

    private fun request(result: MethodChannel.Result,
        launch: ((Map<String, Any?>) -> Unit) -> Unit) {
        if (disposed.get()) { result.success(coordinator.snapshot("UPDATE_INTERRUPTED")); return }
        results.add(result)
        launch { status -> if (results.remove(result) && !disposed.get()) result.success(status) }
    }

    internal fun requestDownloadNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        try {
            val activity = liveActivity()
            if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
            val preferences = context.getSharedPreferences("pushok_flow_updates", android.content.Context.MODE_PRIVATE)
            if (preferences.getBoolean("notification_permission_asked", false)) return
            preferences.edit().putBoolean("notification_permission_asked", true).apply()
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7344)
        } catch (_: Exception) {
            // Notification permission is optional. Download ownership must never depend on a dialog result.
        }
    }

    private fun openInstallPermission(result: MethodChannel.Result) {
        try {
            val activity = liveActivity()
            // Explicit permission setup is useful before the first update has been downloaded.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !coordinator.installPermissionGranted()) {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}")))
            }
            coordinator.setError(null)
            result.success(coordinator.snapshot())
        } catch (failure: UpdateFailure) { result.success(coordinator.snapshot(failure.code)) }
        catch (_: Exception) { result.success(coordinator.snapshot("INSTALLER_UNAVAILABLE")) }
    }

    private fun installUpdate(result: MethodChannel.Result) {
        val launchEpoch = foregroundEpoch.get()
        try { liveActivity(launchEpoch) }
        catch (failure: UpdateFailure) { result.success(coordinator.snapshot(failure.code)); return }
        if (!coordinator.installPermissionGranted()) {
            result.success(coordinator.snapshot("INSTALL_PERMISSION_REQUIRED"))
            return
        }
        results.add(result)
        coordinator.prepareManualInstall { file, failure ->
            if (!results.remove(result) || disposed.get()) return@prepareManualInstall
            var error = failure
            if (error == null && file != null) {
                try {
                    val activity = liveActivity(launchEpoch)
                    if (!coordinator.installPermissionGranted()) throw UpdateFailure("INSTALL_PERMISSION_REQUIRED")
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", file)
                    @Suppress("DEPRECATION")
                    val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                        data = uri
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        clipData = ClipData.newRawUri("Pushok Flow update", uri)
                    }
                    activity.startActivity(intent)
                } catch (failureToLaunch: UpdateFailure) { error = failureToLaunch.code }
                catch (_: Exception) { error = "INSTALLER_UNAVAILABLE" }
            }
            result.success(coordinator.snapshot(error))
        }
    }

    private fun liveActivity(expectedEpoch: Long? = null): Activity {
        val activity = activityReference.get()
        if (disposed.get() || !foreground.get() ||
            (expectedEpoch != null && expectedEpoch != foregroundEpoch.get()) ||
            activity == null || activity.isFinishing || activity.isDestroyed) throw UpdateFailure("UPDATE_INTERRUPTED")
        return activity
    }
}
