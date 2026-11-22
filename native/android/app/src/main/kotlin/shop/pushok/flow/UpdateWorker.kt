package shop.pushok.flow

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.Data
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/** Cancellation belongs to a work attempt, never to an Activity. */
internal class UpdateWorkCancellation(val deadline: Long, val automatic: Boolean) {
    val cancelled = AtomicBoolean(false)
    @Volatile var connection: HttpsURLConnection? = null
    fun cancel() {
        cancelled.set(true)
        try { connection?.disconnect() } catch (_: Exception) { /* Cooperative cancellation. */ }
    }
}

class UpdateWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    @Volatile private var cancellation: UpdateWorkCancellation? = null

    override fun doWork(): Result {
        val reconcileOnly = inputData.getBoolean("reconcile_only", false)
        val work = UpdateWorkCancellation(
            android.os.SystemClock.elapsedRealtime() + UpdateAutomationPolicy.WORK_BUDGET_MS, !reconcileOnly)
        cancellation = work
        if (isStopped) work.cancel()
        val failure = UpdateCoordinator.get(applicationContext).runAutomatic(work, reconcileOnly)
        return if (!isStopped && UpdateAutomationPolicy.retry(failure, runAttemptCount)) Result.retry()
        else Result.success()
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
    private val constraints get() = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(true)
        .setRequiresStorageNotLow(true)
        .build()

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
