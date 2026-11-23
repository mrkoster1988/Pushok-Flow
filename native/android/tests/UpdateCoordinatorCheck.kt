package shop.pushok.flow

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.net.URL
import java.net.URLConnection
import java.net.URLStreamHandler
import java.nio.file.Files
import java.security.cert.Certificate
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

// Execute the real coordinator, hashing, cache persistence/restoration, release binding and
// serial queue. Only Android services, the Worker scheduler boundary and HTTPS are doubles.
// UpdateWorkerCheck separately executes the real durable scheduler and cancellation owner.
private val fixtureCertificate = "coordinator-fixture-certificate".toByteArray()
private val resources = mutableMapOf<String, ByteArray>()
private val requests = mutableListOf<String>()
private val packageFixtures = mutableMapOf<String, PackageInfo>()
private fun packageInfo(build: Int) = PackageInfo(build, "0.$build.0", arrayOf(Signature(fixtureCertificate)))
private fun manifest(build: Int): UpdateManifest {
    val bytes = "Synthetic APK fixture version $build".toByteArray()
    val manifest = UpdateManifest("0.$build.0", build.toLong(), 24,
        "${UpdatePolicy.RELEASE_ROOT}/download/v0.$build.0/Pushok-Flow-v0.$build.0.apk",
        UpdatePolicy.sha256(bytes), bytes.size.toLong(), UpdatePolicy.sha256(fixtureCertificate))
    resources[manifest.apkUrl] = bytes
    packageFixtures[manifest.sha256] = packageInfo(build)
    return manifest
}
private fun encoded(manifest: UpdateManifest) = JSONObject(UpdatePolicy.manifestFields(manifest)).toString()
private class FixtureConnection(url: URL) : HttpsURLConnection(url) {
    private val bytes get() = resources[url.toString()] ?: error("Unexpected URL $url")
    override fun connect() { }
    override fun disconnect() { }
    override fun usingProxy() = false
    override fun getResponseCode() = 200
    override fun getContentLengthLong() = bytes.size.toLong()
    override fun getInputStream() = bytes.inputStream()
    override fun getCipherSuite() = "fixture"
    override fun getLocalCertificates(): Array<Certificate>? = null
    override fun getServerCertificates(): Array<Certificate> = emptyArray()
}
private class FixtureManager : PackageManager() {
    var installedBuild = 48
    override fun getPackageInfo(name: String, flags: Int): PackageInfo = packageInfo(installedBuild)
    override fun getPackageArchiveInfo(path: String, flags: Int): PackageInfo? =
        packageFixtures[UpdatePolicy.sha256(File(path).readBytes())]
}
private fun coordinator(context: Context): UpdateCoordinator =
    UpdateCoordinator::class.java.getDeclaredConstructor(Context::class.java).let {
        it.isAccessible = true; it.newInstance(context)
    }
private fun UpdateCoordinator.closeFixture() {
    for (name in listOf("io", "control")) UpdateCoordinator::class.java.getDeclaredField(name).let {
        it.isAccessible = true; (it.get(this) as ExecutorService).shutdownNow()
    }
}
private fun awaitSnapshot(action: ((Map<String, Any?>) -> Unit) -> Unit): Map<String, Any?> {
    val future = CompletableFuture<Map<String, Any?>>()
    action { future.complete(it) }
    return future.get(5, TimeUnit.SECONDS)
}
private class Fixture : AutoCloseable {
    val directory = Files.createTempDirectory("update-coordinator-check").toFile()
    val prefs = SharedPreferences().apply { edit().putBoolean("automatic_enabled", false).commit() }
    val manager = FixtureManager()
    val context = Context(directory, manager, prefs)
    var updater = coordinator(context)
    val record get() = File(directory, "updates/ready-update.json")
    fun apk(manifest: UpdateManifest) = File(directory, "updates/${UpdatePolicy.candidateFileName(manifest)}")
    fun select(manifest: UpdateManifest) {
        resources[UpdatePolicy.LATEST_RELEASE_URL] = JSONObject(mapOf(
            "id" to manifest.versionCode, "tag_name" to "v${manifest.versionName}", "draft" to false,
            "prerelease" to false, "published_at" to "2026-11-23T05:00:00Z",
            "body" to "## Изменения\n- Изменение ${manifest.versionName}",
        )).toString().toByteArray()
        resources["${UpdatePolicy.RELEASE_ROOT}/download/v${manifest.versionName}/update.json"] =
            encoded(manifest).toByteArray()
        val snapshot = awaitSnapshot { updater.runManual("check", it) }
        check(snapshot["errorCode"] == null) { "Fixture discovery failed: $snapshot" }
        check(snapshot["availableBuild"] == manifest.versionCode)
    }
    fun enqueue(): String {
        val count = BackgroundUpdateScheduler.enqueued.size
        val snapshot = awaitSnapshot(updater::requestDownload)
        check(snapshot["phase"] == "downloading" && snapshot["errorCode"] == null)
        check(BackgroundUpdateScheduler.enqueued.size == count + 1)
        return BackgroundUpdateScheduler.enqueued.last()
    }
    fun run(job: String): String? = updater.runScheduled(
        UpdateWorkCancellation(SystemClock.elapsedRealtime() + 30_000, false), manualManifest = job)
    fun restart() { updater.closeFixture(); updater = coordinator(context) }
    fun restore() {
        val snapshot = awaitSnapshot { updater.runManual("restore", it) }
        check(snapshot["errorCode"] == null) { "Fixture restoration failed: $snapshot" }
    }
    override fun close() { updater.closeFixture(); directory.deleteRecursively() }
}

fun main() {
    URL.setURLStreamHandlerFactory { protocol -> if (protocol == "https") object : URLStreamHandler() {
        override fun openConnection(url: URL): URLConnection {
            requests.add(url.toString()); return FixtureConnection(url)
        }
    } else null }
    val old = manifest(49)
    val newer = manifest(50)

    // Two distinct manual jobs are persisted while automation is off. A later-selected job
    // can finish first; replaying the older job must not replace or delete its verified APK.
    Fixture().use { fixture ->
        fixture.select(old)
        val oldJob = fixture.enqueue()
        fixture.select(newer)
        val newJob = fixture.enqueue()
        check(fixture.run(newJob) == null)
        val ready = fixture.updater.snapshot()
        val record = fixture.record.readBytes()
        val notes = fixture.prefs.getString("latest_release_notes", null)
        check(ready["phase"] == "ready" && ready["availableBuild"] == 50L && ready["releaseNotes"] != null)
        val before = requests.size
        check(fixture.run(oldJob) == null)
        check(fixture.updater.snapshot() == ready) { "Older queued work replaced newer ready state" }
        check(fixture.apk(newer).exists()) { "Older queued work deleted newer verified APK" }
        check(fixture.record.readBytes().contentEquals(record))
        check(fixture.prefs.getString("latest_release_notes", null) == notes)
        check(requests.size == before) { "Stale queued work opened a connection" }

        // A recreated coordinator must apply the same admission rule to the persisted payload,
        // with the actual candidate restored and reverified from its JSON record and file.
        fixture.restart()
        check(fixture.run(oldJob) == null)
        check(fixture.updater.snapshot() == ready)
        check(fixture.apk(newer).exists() && fixture.record.readBytes().contentEquals(record))
        check(requests.size == before)
        check(fixture.run(newJob) == null) // Exact ready-artifact retry remains idempotent.
        check(fixture.updater.snapshot() == ready && requests.size == before)
        val enqueued = BackgroundUpdateScheduler.enqueued.size
        check(awaitSnapshot(fixture.updater::requestDownload) == ready)
        check(BackgroundUpdateScheduler.enqueued.size == enqueued && requests.size == before)

        // The candidate is independently authoritative even if latest-discovery metadata is absent.
        fixture.prefs.edit().remove("latest_manifest").remove("latest_release_notes").commit()
        fixture.restart()
        check(fixture.run(oldJob) == null)
        check(fixture.updater.snapshot()["availableBuild"] == 50L)
        check(fixture.apk(newer).exists() && fixture.record.readBytes().contentEquals(record))
        check(requests.size == before)
    }

    // Discovery alone supersedes an old job; no ready candidate is required. Preserve the
    // newer visible manifest/notes and leave a stale resumable part untouched on rejection.
    Fixture().use { fixture ->
        fixture.select(old)
        val oldJob = fixture.enqueue()
        val partial = File(fixture.directory, "updates/pending-49-${old.sha256.take(16)}.apk")
        partial.writeBytes(resources.getValue(old.apkUrl).copyOf(4))
        val part = partial.readBytes()
        fixture.select(newer)
        val available = fixture.updater.snapshot()
        val before = requests.size
        check(fixture.run(oldJob) == null)
        check(fixture.updater.snapshot() == available)
        check(!fixture.record.exists() && partial.readBytes().contentEquals(part))
        check(requests.size == before)
        fixture.restart()
        check(fixture.run(oldJob) == null) // latest_manifest, without a ready record, survives restart.
        check(!fixture.record.exists() && partial.readBytes().contentEquals(part) && requests.size == before)
    }

    // A same-build SHA conflict must not invoke failOperation's fallback to the older retained
    // APK. Keep the newer available state and its exact release-note binding, then permit its
    // valid persisted job to replace the old file only after normal download verification.
    Fixture().use { fixture ->
        fixture.select(old)
        check(fixture.run(fixture.enqueue()) == null)
        fixture.select(newer)
        val available = fixture.updater.snapshot()
        val oldRecord = fixture.record.readBytes()
        val before = requests.size
        val conflict = newer.copy(sha256 = "a".repeat(64))
        check(fixture.run(encoded(conflict)) == "UPDATE_METADATA_STALE")
        check(fixture.updater.snapshot() == available + ("errorCode" to "UPDATE_METADATA_STALE"))
        check(fixture.apk(old).exists() && fixture.record.readBytes().contentEquals(oldRecord))
        check(requests.size == before)
        val newJob = fixture.enqueue()
        fixture.restart()
        // On restart the older retained APK is ready, but newer persisted discovery still retires it.
        fixture.restore()
        val restored = fixture.updater.snapshot()
        check(restored["availableBuild"] == 49L && restored["releaseNotes"] == null)
        check(fixture.run(encoded(old)) == null && fixture.updater.snapshot() == restored)
        check(fixture.run(newJob) == null)
        val ready = fixture.updater.snapshot()
        check(ready["availableBuild"] == 50L && ready["phase"] == "ready" && ready["errorCode"] == null)
        check(ready["releaseNotes"] == available["releaseNotes"])
        check(fixture.apk(newer).exists() && !fixture.apk(old).exists())

        // Replayed work after Android has installed that build is a no-op and normal restoration
        // removes the obsolete cache without starting another APK request or installer session.
        val beforeReplace = requests.size
        fixture.manager.installedBuild = 50
        fixture.restart()
        check(fixture.run(newJob) == null)
        check(fixture.updater.snapshot()["installedBuild"] == 50L)
        check(!fixture.record.exists() && !fixture.apk(newer).exists())
        check(requests.size == beforeReplace)
    }

    // Both cached shortcuts must actually verify the retained file. A missing/corrupted file
    // cannot install, then the explicit retry must repair it without requiring process death.
    for (missing in listOf(false, true)) for (entry in listOf("worker", "request", "install")) Fixture().use { fixture ->
        fixture.select(newer)
        val job = fixture.enqueue()
        check(fixture.run(job) == null)
        val notes = fixture.updater.snapshot()["releaseNotes"]
        val apk = fixture.apk(newer)
        if (missing) check(apk.delete()) else {
            check(apk.setWritable(true))
            apk.writeBytes(apk.readBytes().map { (it.toInt() xor 1).toByte() }.toByteArray())
        }
        if (entry == "install") {
            val install = CompletableFuture<Pair<File?, String?>>()
            fixture.updater.prepareManualInstall { file, failure -> install.complete(file to failure) }
            check(install.get(5, TimeUnit.SECONDS) ==
                (null to if (missing) "UPDATE_NOT_READY" else "UPDATE_CHECKSUM_MISMATCH"))
            check(fixture.updater.snapshot()["phase"] == "available") // Existing UI exposes Download here.
            check(!fixture.record.exists() && !apk.exists())
        }
        val before = requests.size
        val repair = if (entry != "worker") fixture.enqueue().also {
            check(!fixture.record.exists() && !apk.exists())
            check(requests.size == before) // The UI only enqueues; Worker still owns the transfer.
        } else job
        check(fixture.run(repair) == null)
        val repaired = fixture.updater.snapshot()
        check(repaired["phase"] == "ready" && repaired["availableBuild"] == 50L && repaired["errorCode"] == null)
        check(repaired["releaseNotes"] == notes)
        check(UpdatePolicy.sha256(apk.readBytes()) == newer.sha256 && fixture.record.exists())
        check(requests.size == before + 1)
    }

    // Losing an older retained APK after restart must expose the newer known release, not
    // enqueue an obsolete job that the freshness gate would correctly retire without repair.
    for (installFirst in listOf(false, true)) Fixture().use { fixture ->
        fixture.select(old)
        check(fixture.run(fixture.enqueue()) == null)
        fixture.select(newer)
        val notes = fixture.updater.snapshot()["releaseNotes"]
        fixture.restart()
        fixture.restore()
        check(fixture.updater.snapshot()["availableBuild"] == 49L)
        val oldApk = fixture.apk(old)
        check(oldApk.setWritable(true))
        oldApk.writeText("corrupt")
        if (installFirst) {
            val install = CompletableFuture<Pair<File?, String?>>()
            fixture.updater.prepareManualInstall { file, failure -> install.complete(file to failure) }
            check(install.get(5, TimeUnit.SECONDS) == (null to "UPDATE_CHECKSUM_MISMATCH"))
            check(fixture.updater.snapshot()["phase"] == "available")
            check(fixture.updater.snapshot()["availableBuild"] == 50L)
        }
        val repair = fixture.enqueue()
        check(JSONObject(repair).getLong("versionCode") == 50L)
        check(fixture.run(repair) == null)
        check(fixture.updater.snapshot()["phase"] == "ready")
        check(fixture.updater.snapshot()["releaseNotes"] == notes)
        check(fixture.apk(newer).exists() && !oldApk.exists())
    }

    // An explicit installer handoff pins its file path. Rechecking a subsequently invalid file
    // still exits ready; repair may atomically replace the path only with the fully verified APK.
    Fixture().use { fixture ->
        fixture.select(newer)
        check(fixture.run(fixture.enqueue()) == null)
        val apk = fixture.apk(newer)
        val firstInstall = CompletableFuture<Pair<File?, String?>>()
        fixture.updater.prepareManualInstall { file, failure -> firstInstall.complete(file to failure) }
        check(firstInstall.get(5, TimeUnit.SECONDS) == (apk to null))
        check(fixture.prefs.getString("manual_file", null) == apk.name)
        check(apk.setWritable(true))
        apk.writeText("corrupt")
        val retryInstall = CompletableFuture<Pair<File?, String?>>()
        fixture.updater.prepareManualInstall { file, failure -> retryInstall.complete(file to failure) }
        check(retryInstall.get(5, TimeUnit.SECONDS) == (null to "UPDATE_CHECKSUM_MISMATCH"))
        check(fixture.updater.snapshot()["phase"] == "available" && !fixture.record.exists())
        check(apk.exists()) // Preserve the explicit handoff path until verified replacement.
        check(fixture.run(fixture.enqueue()) == null)
        check(fixture.updater.snapshot()["phase"] == "ready")
        check(UpdatePolicy.sha256(apk.readBytes()) == newer.sha256)
    }

    // AtomicFile.delete has no success return. A sidecar it cannot delete must report storage
    // failure without keeping the known-invalid file ready or enqueuing a claimed-success retry.
    Fixture().use { fixture ->
        fixture.select(newer)
        check(fixture.run(fixture.enqueue()) == null)
        val apk = fixture.apk(newer)
        check(apk.setWritable(true))
        apk.writeText("corrupt")
        val blocked = File(fixture.record.path + ".new")
        check(blocked.mkdir())
        File(blocked, "undeletable-child").writeText("fixture")
        val before = requests.size
        val enqueued = BackgroundUpdateScheduler.enqueued.size
        val failed = awaitSnapshot(fixture.updater::requestDownload)
        check(failed["phase"] == "available" && failed["errorCode"] == "UPDATE_STORAGE_ERROR")
        check(failed["availableBuild"] == 50L && failed["releaseNotes"] != null)
        check(BackgroundUpdateScheduler.enqueued.size == enqueued && requests.size == before)
        check(blocked.deleteRecursively())
        check(fixture.run(fixture.enqueue()) == null)
        check(fixture.updater.snapshot()["phase"] == "ready")
        check(UpdatePolicy.sha256(apk.readBytes()) == newer.sha256)
    }
    println("UpdateCoordinator: durable job ordering, recreation, exact identity, cache repair and truthful storage failures passed")
}
