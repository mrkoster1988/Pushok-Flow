package shop.pushok.flow

import android.app.ForegroundServiceStartNotAllowedException
import android.content.Context
import android.os.Build
import android.os.SystemClock
import androidx.work.Data
import androidx.work.NetworkType
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.net.URL
import java.security.cert.Certificate
import javax.net.ssl.HttpsURLConnection

/** Executes the production Worker and scheduler against small platform doubles.
 * Android permission/manifest semantics are checked separately in APK gates. */
fun main() {
    val context = Context()
    val manifest = UpdateManifest("0.44.0", 44, 24, "https://example.invalid/update.apk",
        "a".repeat(64), 1000, "b".repeat(64))
    val encoded = "immutable-selected-manifest"
    val manager = WorkManager.instance
    BackgroundUpdateScheduler.download(context, manifest, encoded)
    val entry = manager.unique.entries.single()
    val request = entry.value
    check(request.input.getString(UpdateWorker.MANUAL_MANIFEST) == encoded)
    check(request.expedited && request.constraints.network == NetworkType.CONNECTED)
    check(!request.constraints.batteryNotLow && !request.constraints.storageNotLow)
    check(request.backoffMs == 30_000L)
    BackgroundUpdateScheduler.configure(context, false)
    check(entry.key in manager.unique && entry.key !in manager.cancelled)
    BackgroundUpdateScheduler.download(context, manifest, "must-not-replace-an-active-transfer")
    check(manager.unique[entry.key]!!.input.getString(UpdateWorker.MANUAL_MANIFEST) == encoded)
    BackgroundUpdateScheduler.download(context, manifest.copy(versionCode = 45, sha256 = "c".repeat(64)), "newer")
    check(manager.unique.size == 2) // An older queued artifact cannot consume the newer button request.

    val parameters = WorkerParameters(request.input)
    val worker = UpdateWorker(context, parameters)
    Build.VERSION.SDK_INT = 24
    check(worker.getForegroundInfo().foregroundServiceType == 0)
    Build.VERSION.SDK_INT = 36
    check(worker.getForegroundInfo().foregroundServiceType == 1)
    val coordinator = UpdateCoordinator.instance
    coordinator.run = { work, reconcile, selected ->
        check(!work.automatic && !reconcile && selected == encoded)
        work.downloadProgress!!(manifest, 400)
        // Foreground ownership is established synchronously before the transfer can read bytes.
        check(worker.foregroundCalls.single().notification.ongoing)
        check(worker.foregroundCalls.single().notification.progress == 40)
        work.downloadProgress!!(manifest, 401)
        check(context.notifications.notifications.isEmpty())
        SystemClock.now += 1000
        work.downloadProgress!!(manifest, 700)
        check(context.notifications.notifications.last().progress == 70)
        work.downloadProgress!!(manifest, 1000)
        check(context.notifications.notifications.last().text == "Проверка загруженного APK")
        null
    }
    check(!worker.doWork().retry)

    val connection = object : HttpsURLConnection(URL("https://example.invalid/")) {
        var disconnected = false
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun connect() { }
        override fun getCipherSuite() = "test"
        override fun getLocalCertificates(): Array<Certificate>? = null
        override fun getServerCertificates(): Array<Certificate> = emptyArray()
    }
    val stopped = UpdateWorker(context, parameters)
    coordinator.run = { work, _, _ ->
        work.connection = connection
        stopped.stopForTest()
        check(work.cancelled.get() && connection.disconnected)
        try { work.downloadProgress!!(manifest, 400); error("Stopped worker published progress") }
        catch (failure: UpdateFailure) { check(failure.code == "UPDATE_INTERRUPTED") }
        "UPDATE_INTERRUPTED"
    }
    check(!stopped.doWork().retry) // WorkManager itself owns scheduling a stopped request.

    // A fresh Worker created from durable input keeps the manual intent, even with auto disabled.
    val recreated = UpdateWorker(context, WorkerParameters(request.input, attempts = 1, id = parameters.id))
    coordinator.run = { work, _, selected ->
        check(selected == encoded && !work.automatic && !work.cancelled.get())
        work.downloadProgress!!(manifest, 400)
        check(recreated.foregroundCalls.single().notification.progress == 40)
        "UPDATE_NETWORK_ERROR"
    }
    check(recreated.doWork().retry)

    val denied = UpdateWorker(context, parameters)
    denied.foregroundError = ForegroundServiceStartNotAllowedException()
    coordinator.run = { work, _, _ ->
        work.downloadProgress!!(manifest, 0)
        check(!work.cancelled.get()) // Bounded JobScheduler ownership remains; no unsafe service retry.
        work.downloadProgress!!(manifest, 1000)
        check(denied.foregroundCalls.size == 1)
        null
    }
    check(!denied.doWork().retry)

    coordinator.run = { work, reconcile, selected ->
        check(work.automatic && !reconcile && selected == null)
        "UPDATE_SIGNATURE_MISMATCH"
    }
    check(!UpdateWorker(context, WorkerParameters()).doWork().retry)
    coordinator.run = { work, reconcile, selected ->
        check(!work.automatic && reconcile && selected == null)
        null
    }
    check(!UpdateWorker(context, WorkerParameters(Data.Builder().putBoolean("reconcile_only", true).build())).doWork().retry)
    println("Update Worker durable ownership, foreground progress, cancellation and resume checks passed")
}
