package shop.pushok.flow

import android.app.ForegroundServiceStartNotAllowedException
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.Data
import java.util.concurrent.TimeUnit
import java.util.concurrent.ExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/** Cancellation belongs to a work attempt, never to an Activity. */
internal class UpdateWorkCancellation(val deadline: Long, val automatic: Boolean) {
    val cancelled = AtomicBoolean(false)
    @Volatile var connection: HttpsURLConnection? = null
    var downloadProgress: ((UpdateManifest, Long) -> Unit)? = null
    fun cancel() {
        cancelled.set(true)
        try { connection?.disconnect() } catch (_: Exception) { /* Cooperative cancellation. */ }
    }
}

class UpdateWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    companion object {
        internal const val MANUAL_MANIFEST = "manual_manifest"
        private const val CHANNEL = "pushok_flow_update_downloads"
    }
    @Volatile private var cancellation: UpdateWorkCancellation? = null
    private var foregroundAttempted = false
    private var foregroundStarted = false
    private var lastNotificationAt = 0L
    private var lastPercent = -1
    private val notificationId get() = (id.hashCode() and 0x0fffffff) or 0x40000000

    // Required for expedited WorkManager jobs on Android 11 and older.
    override fun getForegroundInfo(): ForegroundInfo = notification(null, 0)

    override fun doWork(): Result {
        val reconcileOnly = inputData.getBoolean("reconcile_only", false)
        val manualManifest = inputData.getString(MANUAL_MANIFEST)
        val work = UpdateWorkCancellation(
            SystemClock.elapsedRealtime() + UpdateAutomationPolicy.WORK_BUDGET_MS,
            !reconcileOnly && manualManifest == null)
        work.downloadProgress = ::downloadProgress
        cancellation = work
        if (isStopped) work.cancel()
        val failure = UpdateCoordinator.get(applicationContext).runScheduled(work, reconcileOnly, manualManifest)
        return if (!isStopped && UpdateAutomationPolicy.retry(failure, runAttemptCount)) Result.retry()
        else Result.success()
    }

    /** Promote before opening the APK connection, then update at most once per second.
     * Android may reject foreground promotion of a delayed/background job. In that specific case
     * the bounded JobScheduler-owned worker still runs; its persisted request and partial resume
     * after a system stop. Never start an unowned service or bypass Android's restrictions. */
    private fun downloadProgress(manifest: UpdateManifest, received: Long) {
        if (isStopped || cancellation?.cancelled?.get() == true) throw UpdateFailure("UPDATE_INTERRUPTED")
        val now = SystemClock.elapsedRealtime()
        val percent = UpdateAutomationPolicy.downloadPercent(received, manifest.sizeBytes)
        if (!foregroundAttempted) {
            foregroundAttempted = true
            try {
                setForegroundAsync(notification(manifest, received)).get(10, TimeUnit.SECONDS)
                foregroundStarted = true
            } catch (error: Exception) {
                val cause = if (error is ExecutionException) error.cause ?: error else error
                if (Build.VERSION.SDK_INT < 31 || cause !is ForegroundServiceStartNotAllowedException) {
                    if (isStopped || cancellation?.cancelled?.get() == true)
                        throw UpdateFailure("UPDATE_INTERRUPTED")
                    throw UpdateFailure("UPDATE_SCHEDULER_UNAVAILABLE")
                }
            }
            lastNotificationAt = now
            lastPercent = percent
        } else if (foregroundStarted && percent != lastPercent &&
            (now - lastNotificationAt >= 1000 || percent == 100)) {
            // Updating an existing FGS notification does not start another service. Permission
            // denial on Android 13 only hides it from the drawer; it must not cancel a download.
            try { notificationManager().notify(notificationId, notification(manifest, received).notification) }
            catch (_: SecurityException) { /* The system still owns the foreground worker. */ }
            lastNotificationAt = now
            lastPercent = percent
        }
    }

    private fun notificationManager(): NotificationManager =
        applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun notification(manifest: UpdateManifest?, received: Long): ForegroundInfo {
        if (Build.VERSION.SDK_INT >= 26) notificationManager().createNotificationChannel(
            NotificationChannel(CHANNEL, "Загрузка обновлений", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(applicationContext, 0,
            Intent(applicationContext, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val percent = manifest?.let { UpdateAutomationPolicy.downloadPercent(received, it.sizeBytes) } ?: 0
        val message = when {
            manifest == null -> "Подготовка загрузки"
            received >= manifest.sizeBytes -> "Проверка загруженного APK"
            else -> "Версия ${manifest.versionName} · $percent%"
        }
        val value = NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Обновление Pushok Flow")
            .setContentText(message)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setShowWhen(false)
            .setProgress(100, percent, manifest == null)
            .build()
        return if (Build.VERSION.SDK_INT >= 29)
            ForegroundInfo(notificationId, value, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else ForegroundInfo(notificationId, value)
    }

    override fun onStopped() {
        cancellation?.cancel()
        super.onStopped()
    }
}

internal object BackgroundUpdateScheduler {
    private const val PERIODIC = "pushok-flow-update-periodic"
    private const val IMMEDIATE = "pushok-flow-update-immediate"
    private const val IDLE = "pushok-flow-update-idle"
    private const val SESSION = "pushok-flow-update-session"
    private const val MANUAL = "pushok-flow-update-download"
    private val constraints get() = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(true)
        .setRequiresStorageNotLow(true)
        .build()

    fun download(context: Context, manifest: UpdateManifest, encoded: String) {
        val request = OneTimeWorkRequestBuilder<UpdateWorker>()
            .setInputData(Data.Builder().putString(UpdateWorker.MANUAL_MANIFEST, encoded).build())
            // Explicit downloads must not disappear when automatic updates/battery-not-low change.
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            "$MANUAL-${manifest.versionCode}-${manifest.sha256}", ExistingWorkPolicy.KEEP, request)
            .result.get(5, TimeUnit.SECONDS)
    }

    fun configure(context: Context, enabled: Boolean, immediate: Boolean = false) {
        val manager = WorkManager.getInstance(context)
        if (!enabled) {
            manager.cancelUniqueWork(PERIODIC)
            manager.cancelUniqueWork(IMMEDIATE)
            manager.cancelUniqueWork(IDLE)
            return
        }
        val periodic = PeriodicWorkRequestBuilder<UpdateWorker>(6, TimeUnit.HOURS)
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
            .build()
        manager.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, periodic)
        if (immediate) manager.enqueueUniqueWork(IMMEDIATE, ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<UpdateWorker>().setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES).build())
    }


    /** Independent of network/auto preference: a lost installer callback must not lock VPN forever. */
    fun monitorSession(context: Context) {
        WorkManager.getInstance(context).enqueueUniqueWork(SESSION, ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<UpdateWorker>()
                .setInputData(Data.Builder().putBoolean("reconcile_only", true).build())
                .setInitialDelay(UpdateAutomationPolicy.INSTALL_TIMEOUT_MS + 1000, TimeUnit.MILLISECONDS)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.MINUTES).build())
            .result.get(5, TimeUnit.SECONDS)
    }

    /** A quiet retry after leaving the app/disconnecting, coalesced across Activity callbacks. */
    fun whenIdle(context: Context) {
        WorkManager.getInstance(context).enqueueUniqueWork(IDLE, ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<UpdateWorker>().setConstraints(constraints)
                .setInitialDelay(30, TimeUnit.SECONDS)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES).build())
    }
}
