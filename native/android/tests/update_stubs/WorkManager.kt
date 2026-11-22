package androidx.work

import android.app.Notification
import android.content.Context
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

enum class BackoffPolicy { EXPONENTIAL }
enum class ExistingPeriodicWorkPolicy { KEEP }
enum class ExistingWorkPolicy { KEEP, REPLACE }
enum class NetworkType { CONNECTED }
enum class OutOfQuotaPolicy { RUN_AS_NON_EXPEDITED_WORK_REQUEST }
class ForegroundInfo(val notificationId: Int, val notification: Notification, val foregroundServiceType: Int = 0)
class Data(private val values: Map<String, Any>) {
    fun getString(key: String): String? = values[key] as? String
    fun getBoolean(key: String, default: Boolean) = values[key] as? Boolean ?: default
    class Builder {
        private val values = mutableMapOf<String, Any>()
        fun putString(key: String, value: String) = apply { values[key] = value }
        fun putBoolean(key: String, value: Boolean) = apply { values[key] = value }
        fun build() = Data(values.toMap())
    }
}
class Constraints(val network: NetworkType?, val batteryNotLow: Boolean, val storageNotLow: Boolean) {
    class Builder {
        private var network: NetworkType? = null
        private var battery = false
        private var storage = false
        fun setRequiredNetworkType(value: NetworkType) = apply { network = value }
        fun setRequiresBatteryNotLow(value: Boolean) = apply { battery = value }
        fun setRequiresStorageNotLow(value: Boolean) = apply { storage = value }
        fun build() = Constraints(network, battery, storage)
    }
}
class WorkerParameters(val input: Data = Data.Builder().build(), val attempts: Int = 0, val id: UUID = UUID.randomUUID())
abstract class Worker(val applicationContext: Context, val parameters: WorkerParameters) {
    val inputData get() = parameters.input
    val runAttemptCount get() = parameters.attempts
    val id get() = parameters.id
    var isStopped = false
    val foregroundCalls = mutableListOf<ForegroundInfo>()
    var foregroundError: Exception? = null
    open fun getForegroundInfo(): ForegroundInfo = error("Missing notification")
    abstract fun doWork(): Result
    open fun onStopped() { }
    fun stopForTest() { isStopped = true; onStopped() }
    fun setForegroundAsync(info: ForegroundInfo): CompletableFuture<Void> {
        foregroundCalls.add(info)
        val result = CompletableFuture<Void>()
        foregroundError?.let { result.completeExceptionally(it) } ?: result.complete(null)
        return result
    }
    data class Result(val retry: Boolean) {
        companion object { fun retry() = Result(true); fun success() = Result(false) }
    }
}
data class WorkRequest(val input: Data, val constraints: Constraints, val expedited: Boolean, val backoffMs: Long)
open class WorkRequestBuilder {
    private var input = Data.Builder().build()
    private var constraints = Constraints.Builder().build()
    private var expedited = false
    private var backoffMs = 0L
    fun setInputData(value: Data) = apply { input = value }
    fun setConstraints(value: Constraints) = apply { constraints = value }
    fun setExpedited(value: OutOfQuotaPolicy) = apply { expedited = true }
    fun setBackoffCriteria(policy: BackoffPolicy, time: Long, unit: TimeUnit) = apply { backoffMs = unit.toMillis(time) }
    fun setInitialDelay(time: Long, unit: TimeUnit) = this
    fun build() = WorkRequest(input, constraints, expedited, backoffMs)
}
class OneTimeWorkRequestBuilder<T : Worker> : WorkRequestBuilder()
class PeriodicWorkRequestBuilder<T : Worker>(time: Long, unit: TimeUnit) : WorkRequestBuilder()
class Operation { val result: CompletableFuture<Void> = CompletableFuture.completedFuture(null) }
class WorkManager {
    companion object {
        val instance = WorkManager()
        fun getInstance(context: Context) = instance
    }
    val unique = mutableMapOf<String, WorkRequest>()
    val cancelled = mutableSetOf<String>()
    fun cancelUniqueWork(name: String): Operation { cancelled.add(name); unique.remove(name); return Operation() }
    fun enqueueUniqueWork(name: String, policy: ExistingWorkPolicy, request: WorkRequest): Operation {
        if (policy == ExistingWorkPolicy.REPLACE || name !in unique) unique[name] = request
        return Operation()
    }
    fun enqueueUniquePeriodicWork(name: String, policy: ExistingPeriodicWorkPolicy, request: WorkRequest) =
        enqueueUniqueWork(name, ExistingWorkPolicy.KEEP, request)
}
