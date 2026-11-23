package shop.pushok.flow

import android.app.Activity
import android.app.Application
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile
import javax.net.ssl.HttpsURLConnection

/** Application-owned updater. Activity destruction never cancels its network/file work. */
internal class UpdateCoordinator private constructor(private val context: Context) {
    companion object {
        @Volatile private var instance: UpdateCoordinator? = null
        fun get(context: Context): UpdateCoordinator = instance ?: synchronized(this) {
            instance ?: UpdateCoordinator(context.applicationContext).also { instance = it }
        }
        private const val CHECK_TIMEOUT_MS = 60_000L
        private const val SETTINGS = "pushok_flow_updates"
        private const val ENABLED = "automatic_enabled"
        private const val ATTEMPT = "install_attempt"
        private const val BLOCKED_SHA = "automatic_attempted_sha"
        private val updateName = Regex("(?:pending-[0-9]+-[0-9a-f]{16}|verified-[0-9]+-[0-9a-f]{16})\\.apk")
    }

    private data class InstallAttempt(val sessionId: Int, val token: String, val sha256: String,
        val build: Long, val startedAt: Long, val phase: String)
    private val io = Executors.newSingleThreadExecutor()
    private val control = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val preferences = context.getSharedPreferences(SETTINGS, Context.MODE_PRIVATE)
    private val settingsLock = Any()
    private val stateLock = Any()
    private val attemptLock = Any()
    private val busy = AtomicBoolean(false)
    private val initialized = AtomicBoolean(false)
    private val guard = UpdateAutomationGuard()
    @Volatile private var installed = try { installedPackage() } catch (_: Exception) { null }
    @Volatile private var enabled = preferences.getBoolean(ENABLED, true)
    @Volatile private var blockedSha: String? = preferences.getString(BLOCKED_SHA, null)
    @Volatile private var manualFileName: String? = preferences.getString("manual_file", null)
    @Volatile private var activeWork: UpdateWorkCancellation? = null
    @Volatile private var attempt: InstallAttempt? = readAttempt()
    @Volatile private var restored = false // Only the serial I/O queue mutates restoration/candidate fields.
    private var retainedReady: UpdateState? = null
    private var latestManifest: UpdateManifest? = null
    @Volatile private var latestReleaseNotes: UpdateReleaseNotes? = null
    private var state = UpdateState(if (installed == null) "unavailable" else "idle",
        errorCode = if (installed == null) "UPDATE_INCOMPATIBLE" else null)

    init {
        if (attempt != null) guard.restoreInstallReservation()
        (context as? Application)?.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) { guard.foreground(activity, true) }
            override fun onActivityStopped(activity: Activity) { guard.foreground(activity, false); requestIdleWork() }
            override fun onActivityDestroyed(activity: Activity) { guard.foreground(activity, false) }
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        })
    }

    fun initialize() {
        if (!initialized.compareAndSet(false, true)) return
        try { BackgroundUpdateScheduler.configure(context, enabled, immediate = enabled) }
        catch (_: Exception) { setError("UPDATE_SCHEDULER_UNAVAILABLE") }
        runManual("restore") { }
    }

    fun setForeground(owner: Any, value: Boolean) {
        guard.foreground(owner, value)
        if (!value) requestIdleWork()
    }
    fun beginConnection(token: Long): Boolean {
        reconcileIfExpired()
        return guard.beginConnection(token)
    }
    fun reconcileIfExpired() {
        val saved = attempt ?: return
        val age = System.currentTimeMillis() - saved.startedAt
        if (guard.isInstalling() && (age < 0 || age > UpdateAutomationPolicy.INSTALL_TIMEOUT_MS)) runManual("restore") { }
    }
    fun endConnection(token: Long) { guard.endConnection(token); requestIdleWork() }
    fun observeTunnel(upOrUnknown: Boolean) {
        guard.observeTunnel(upOrUnknown)
        if (!upOrUnknown) requestIdleWork()
    }

    private fun requestIdleWork() {
        // No timers/polling loop: one coalesced work request after the app/tunnel becomes idle.
        if (enabled && !guard.isForeground() && !guard.connectionUnsafe() && readState().apk != null) {
            try { BackgroundUpdateScheduler.whenIdle(context) } catch (_: Exception) { setError("UPDATE_SCHEDULER_UNAVAILABLE") }
        }
    }

    fun snapshot(errorOverride: String? = null): Map<String, Any?> {
        val current = readState()
        val permission = installPermissionGranted()
        val activeAttempt = attempt
        val waiting = if (current.phase == "ready" && current.apk != null && current.manifest != null)
            UpdateAutomationPolicy.waitingReason(enabled, Build.VERSION.SDK_INT, permission,
                blockedSha == current.manifest.sha256 || (activeAttempt?.phase == "waiting" &&
                    activeAttempt.sha256 == current.manifest.sha256),
                guard.connectionUnsafe() || vpnPresentOrUnknown(), guard.isForeground()) else null
        return mapOf(
            "installedVersion" to (installed?.versionName ?: "0.0.0"),
            "installedBuild" to (installed?.let(::versionCode) ?: 0L),
            "phase" to current.phase,
            "availableVersion" to current.manifest?.versionName,
            "availableBuild" to current.manifest?.versionCode,
            "downloadedBytes" to current.downloadedBytes,
            "totalBytes" to current.totalBytes,
            "errorCode" to (errorOverride ?: current.errorCode?.takeUnless {
                it == "INSTALL_PERMISSION_REQUIRED" && permission }),
            "installPermissionGranted" to permission,
            "checkedAtMillis" to current.checkedAtMillis,
            "checkStage" to current.checkStage,
            "automaticUpdatesEnabled" to enabled,
            "installWaitingReason" to waiting,
            "releaseNotes" to UpdateReleaseNotesPolicy.visible(latestReleaseNotes, current.manifest,
                installed?.versionName ?: "0.0.0", installed?.let(::versionCode) ?: 0L)?.metadata(),
        )
    }

    fun setAutomaticUpdates(value: Boolean, callback: (Map<String, Any?>) -> Unit) {
        // Independent from the download queue: disabling takes effect even during a long transfer.
        control.execute {
            var failure: String? = null
            try {
                synchronized(settingsLock) {
                    if (!preferences.edit().putBoolean(ENABLED, value).commit()) throw UpdateFailure("UPDATE_STORAGE_ERROR")
                    enabled = value
                    if (!value) activeWork?.takeIf { it.automatic }?.cancel()
                }
                BackgroundUpdateScheduler.configure(context, value, immediate = value)
            } catch (error: UpdateFailure) { failure = error.code }
            catch (_: Exception) { failure = "UPDATE_SCHEDULER_UNAVAILABLE" }
            main.post { callback(snapshot(failure)) }
        }
    }

    fun runManual(command: String, callback: (Map<String, Any?>) -> Unit) {
        if (!busy.compareAndSet(false, true)) { callback(snapshot("UPDATE_BUSY")); return }
        if (command == "restore" && !restored) changeState { it.copy(phase = "checking", checkStage = null) }
        val cancellation = UpdateWorkCancellation(SystemClock.elapsedRealtime() + UpdateAutomationPolicy.WORK_BUDGET_MS, false)
        io.execute {
            activeWork = cancellation
            try {
                ensureActive()
                restoreOnce()
                reconcileInstallAttempt()
                if (readState().phase != "installing") when (command) {
                    "restore" -> Unit
                    "check" -> checkRemote()
                    else -> throw UpdateFailure("UPDATE_NOT_READY")
                }
            } catch (error: UpdateFailure) { failOperation(error.code) }
            catch (_: Exception) { failOperation("UPDATE_NETWORK_ERROR") }
            finally { activeWork = null; busy.set(false) }
            if (command != "restore" && enabled) {
                try { BackgroundUpdateScheduler.configure(context, true, immediate = true) }
                catch (_: Exception) { setError("UPDATE_SCHEDULER_UNAVAILABLE") }
            }
            main.post { callback(snapshot()) }
        }
    }

    /** A user download is durable before the channel call completes, even with automation disabled.
     * Only WorkManager may execute the transfer; this short queue just captures the verified manifest. */
    fun requestDownload(callback: (Map<String, Any?>) -> Unit) {
        if (!busy.compareAndSet(false, true)) { callback(snapshot("UPDATE_BUSY")); return }
        io.execute {
            try {
                restoreOnce()
                reconcileInstallAttempt()
                if (readState().phase == "installing") throw UpdateFailure("UPDATE_BUSY")
                val manifest = readState().manifest ?: throw UpdateFailure("UPDATE_NOT_READY")
                val current = installedPackage()
                UpdatePolicy.requireCompatible(manifest, current.packageName, signerDigests(current), Build.VERSION.SDK_INT)
                UpdatePolicy.requireDeviceCompatible(manifest, Build.SUPPORTED_ABIS.toList())
                UpdatePolicy.requireNewer(manifest, versionCode(current))
                if (retainedReady?.manifest == manifest) changeState { retainedReady!! }
                else {
                    // The payload, URL, hash and signing identity survive process death together.
                    // KEEP is scoped to this exact artifact, never to an unrelated newer update.
                    BackgroundUpdateScheduler.download(context, manifest,
                        JSONObject(UpdatePolicy.manifestFields(manifest)).toString())
                    changeState { it.copy(phase = "downloading", errorCode = null, checkStage = null) }
                }
            } catch (error: UpdateFailure) { failOperation(error.code) }
            catch (_: Exception) { failOperation("UPDATE_SCHEDULER_UNAVAILABLE") }
            finally { busy.set(false) }
            main.post { callback(snapshot()) }
        }
    }

    /** WorkManager owns cancellation/deadline; its thread waits for the shared I/O queue. */
    fun runScheduled(cancellation: UpdateWorkCancellation, reconcileOnly: Boolean = false,
        manualManifest: String? = null): String? {
        if ((cancellation.automatic && !enabled) || cancellation.cancelled.get() || (reconcileOnly && attempt == null)) return null
        val future = io.submit<String?> {
            if (cancellation.automatic && !enabled) return@submit null
            if (!busy.compareAndSet(false, true)) return@submit "UPDATE_BUSY"
            activeWork = cancellation
            try {
                ensureActive()
                restoreOnce()
                reconcileInstallAttempt()
                if (reconcileOnly || readState().phase == "installing") return@submit null
                if (manualManifest != null) {
                    val manifest = cachedManifestFromJson(parseJson(manualManifest.toByteArray(StandardCharsets.UTF_8)))
                    // A process/update restart can outlive the job that originally selected this build.
                    if (manifest.versionCode <= versionCode(installedPackage())) return@submit null
                    downloadCandidate(manifest)
                } else {
                    checkRemote()
                    val current = readState()
                    if (current.phase == "available" && current.manifest != null) downloadCandidate(current.manifest)
                }
                if (enabled && readState().phase == "ready") tryAutomaticInstall()
                null
            } catch (error: UpdateFailure) { failOperation(error.code); error.code }
            catch (_: Exception) { failOperation("UPDATE_NETWORK_ERROR"); "UPDATE_NETWORK_ERROR" }
            finally { activeWork = null; busy.set(false) }
        }
        return try {
            val remaining = cancellation.deadline - SystemClock.elapsedRealtime()
            if (remaining <= 0) throw java.util.concurrent.TimeoutException()
            future.get(remaining, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
            cancellation.cancel()
            // Never interrupt the shared executor (a later operation can use the same thread).
            "UPDATE_INTERRUPTED"
        }
    }

    private fun readState(): UpdateState = synchronized(stateLock) { state }
    private fun changeState(transform: (UpdateState) -> UpdateState) { synchronized(stateLock) { state = transform(state) } }
    fun setError(code: String?) { changeState { it.copy(errorCode = code) } }

    private fun failOperation(code: String) {
        changeState { previous ->
            if (previous.phase == "installing") previous.copy(errorCode = code)
            else (retainedReady ?: previous.takeIf { it.manifest != null }?.copy(phase = "available", apk = null)
                ?: UpdateState(if (code == "UPDATE_UNAVAILABLE") "unavailable" else "error"))
                .copy(errorCode = code, checkStage = null)
        }
    }

    private fun restoreOnce() {
        if (restored) return
        installed = installedPackage()
        synchronized(attemptLock) {
            val owner = attempt?.sessionId
            for (session in context.packageManager.packageInstaller.mySessions) {
                if (session.sessionId != owner) abandonSession(session.sessionId)
            }
        }
        val currentBuild = installed?.let(::versionCode) ?: 0L
        manualFileName?.let { name ->
            val build = Regex("verified-([0-9]+)-[0-9a-f]{16}\\.apk").matchEntire(name)?.groupValues?.get(1)?.toLongOrNull()
            if (build != null && build <= currentBuild) {
                if (preferences.edit().remove("manual_file").commit()) manualFileName = null
            }
        }
        updateDirectory().listFiles()?.forEach { file ->
            val build = Regex("(?:pending|verified)-([0-9]+)-[0-9a-f]{16}\\.apk")
                .matchEntire(file.name)?.groupValues?.get(1)?.toLongOrNull()
            if (build != null && build <= currentBuild) deleteOwnedFile(file)
        }
        latestManifest = try { preferences.getString("latest_manifest", null)?.let {
            cachedManifestFromJson(parseJson(it.toByteArray(StandardCharsets.UTF_8)))
        } } catch (_: Exception) { null }
        latestReleaseNotes = try { latestManifest?.let { manifest ->
            preferences.getString("latest_release_notes", null)?.takeIf { it.length <= 16_384 }?.let {
                cachedReleaseNotesFromJson(parseJson(it.toByteArray(StandardCharsets.UTF_8)), manifest)
            }
        } } catch (_: Exception) { null }
        retainedReady = restoreCandidate()
        restored = true
        changeState { retainedReady ?: UpdateState(if (installed == null) "unavailable" else "idle",
            errorCode = if (installed == null) "UPDATE_INCOMPATIBLE" else null) }
    }

    private fun checkRemote() {
        val prior = latestManifest?.let { UpdateState("available", it, totalBytes = it.sizeBytes,
            checkedAtMillis = readState().checkedAtMillis) } ?: readState()
        val session = UpdateCheckSession(prior, versionCode(installedPackage()))
        session.recover(retainedReady)
        changeState { session.checking("release") }
        try {
            val deadline = boundedDeadline(CHECK_TIMEOUT_MS)
            val release = releaseFromJson(parseJson(readRemoteMetadata(
                URI(UpdatePolicy.LATEST_RELEASE_URL), deadline, UpdatePolicy.MAX_RELEASE_BYTES, releaseApi = true)))
            changeState { session.checking("manifest") }
            val universal = manifestFromJson(parseJson(readRemoteMetadata(URI(UpdatePolicy.manifestUrl(release)),
                deadline, UpdatePolicy.MAX_METADATA_BYTES, release = release)))
            val current = installedPackage()
            UpdatePolicy.requireCompatible(universal, current.packageName, signerDigests(current), Build.VERSION.SDK_INT)
            val known = listOfNotNull(prior.manifest, retainedReady?.manifest)
                .filter { it.versionCode > versionCode(current) }
            val manifest = UpdatePolicy.selectManifest(universal, release, Build.SUPPORTED_ABIS.toList(), known)
            UpdatePolicy.requireCompatible(manifest, current.packageName, signerDigests(current), Build.VERSION.SDK_INT)
            UpdatePolicy.requireDeviceCompatible(manifest, Build.SUPPORTED_ABIS.toList())
            val next = session.complete(release, manifest, current.versionName ?: "0.0.0", System.currentTimeMillis())
            val notes = UpdateReleaseNotesPolicy.verified(release, manifest)
            val editor = preferences.edit()
                .putString("latest_manifest", JSONObject(UpdatePolicy.manifestFields(manifest)).toString())
                .putLong("checked_at", next.checkedAtMillis ?: 0)
            if (notes == null) editor.remove("latest_release_notes")
            else editor.putString("latest_release_notes", JSONObject(notes.cacheFields()).toString())
            if (!editor.commit()) throw UpdateFailure("UPDATE_STORAGE_ERROR")
            latestManifest = manifest
            latestReleaseNotes = notes
            // The older ready record remains intact until a newer file is fully verified and atomically published.
            changeState { next }
        } catch (failure: UpdateFailure) { changeState { session.failed(failure.code) }; throw failure }
    }

    private fun downloadCandidate(manifest: UpdateManifest) {
        val current = installedPackage()
        UpdatePolicy.requireCompatible(manifest, current.packageName, signerDigests(current), Build.VERSION.SDK_INT)
        UpdatePolicy.requireDeviceCompatible(manifest, Build.SUPPORTED_ABIS.toList())
        UpdatePolicy.requireNewer(manifest, versionCode(current))
        if (retainedReady?.manifest == manifest) { changeState { retainedReady!! }; return }
        val directory = updateDirectory()
        val temporary = File(directory, "pending-${manifest.versionCode}-${manifest.sha256.take(16)}.apk")
        if (temporary.canonicalFile != temporary) throw UpdateFailure("UPDATE_STORAGE_ERROR")
        if (temporary.exists() && (!temporary.isFile || temporary.length() > manifest.sizeBytes)) {
            if (!temporary.delete()) throw UpdateFailure("UPDATE_STORAGE_ERROR")
        }
        var received = temporary.length()
        changeState { UpdateState("downloading", manifest, downloadedBytes = received,
            totalBytes = manifest.sizeBytes, checkedAtMillis = it.checkedAtMillis) }
        try {
            // This callback belongs to the Worker, not to an Activity or the Flutter polling timer.
            activeWork?.downloadProgress?.invoke(manifest, received)
            ensureActive()
            if (received < manifest.sizeBytes) {
                val deadline = boundedDeadline(UpdateAutomationPolicy.WORK_BUDGET_MS)
                withConnection(URI(manifest.apkUrl), manifest, deadline, offset = received) { remote ->
                    val append = UpdateAutomationPolicy.appendResponse(received, manifest.sizeBytes, remote.responseCode,
                        remote.getHeaderField("Content-Range"), remote.contentLengthLong)
                    if (!append) received = 0L
                    val output = try { FileOutputStream(temporary, append) }
                        catch (_: IOException) { throw UpdateFailure("UPDATE_STORAGE_ERROR") }
                    output.use { file ->
                        try {
                            remote.inputStream.use { input ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    ensureActive(deadline)
                                    remote.readTimeout = remainingTimeout(deadline, 20_000)
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    received += count
                                    if (received > manifest.sizeBytes) throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
                                    try { file.write(buffer, 0, count) }
                                    catch (_: IOException) { throw UpdateFailure("UPDATE_STORAGE_ERROR") }
                                    changeState { it.copy(downloadedBytes = received) }
                                    activeWork?.downloadProgress?.invoke(manifest, received)
                                }
                            }
                        } finally {
                            try { file.fd.sync() } catch (_: IOException) { throw UpdateFailure("UPDATE_STORAGE_ERROR") }
                        }
                    }
                }
            }
            if (received != manifest.sizeBytes) throw UpdateFailure("UPDATE_DOWNLOAD_FAILED")
            verifyReadyFile(temporary, manifest)
            ensureActive()
            val verified = File(directory, UpdatePolicy.candidateFileName(manifest))
            if (verified.canonicalFile != verified || !temporary.setReadOnly() || !temporary.renameTo(verified)) {
                throw UpdateFailure("UPDATE_STORAGE_ERROR")
            }
            persistCandidate(manifest, verified)
            val previous = retainedReady?.apk
            val ready = UpdateState("ready", manifest, verified, manifest.sizeBytes, manifest.sizeBytes,
                checkedAtMillis = readState().checkedAtMillis)
            retainedReady = ready
            changeState { ready }
            // Publication is complete. Only now may the previous verified APK be deleted.
            if (previous != null && previous != verified) deleteOwnedFile(previous)
            directory.listFiles()?.filter { it != verified && it != previous && updateName.matches(it.name) }
                ?.forEach(::deleteOwnedFile)
        } catch (failure: UpdateFailure) {
            if (failure.code in setOf("UPDATE_CHECKSUM_MISMATCH", "UPDATE_APK_INVALID", "UPDATE_SIGNATURE_MISMATCH")) {
                deleteOwnedFile(temporary)
            }
            // Network loss, Worker stop and process death deliberately retain the resumable part.
            throw failure
        }
    }

    private fun tryAutomaticInstall() {
        val ready = readState()
        val manifest = ready.manifest ?: return
        val apk = ready.apk ?: return
        if (UpdateAutomationPolicy.waitingReason(enabled, Build.VERSION.SDK_INT, installPermissionGranted(),
                blockedSha == manifest.sha256, guard.connectionUnsafe() || vpnPresentOrUnknown(),
                guard.isForeground()) != null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        verifyReadyFile(apk, manifest)
        ensureActive()
        if (!guard.reserveInstall(::vpnPresentOrUnknown)) return
        val installer = context.packageManager.packageInstaller
        var sessionId: Int? = null
        var committed = false
        try {
            ensureActive()
            if (!installPermissionGranted()) throw UpdateFailure("INSTALL_PERMISSION_REQUIRED")
            val parameters = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(context.packageName)
                setSize(manifest.sizeBytes)
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            val id = installer.createSession(parameters)
            sessionId = id
            val preparing = InstallAttempt(id, UUID.randomUUID().toString(), manifest.sha256,
                manifest.versionCode, System.currentTimeMillis(), "preparing")
            persistAttempt(preparing)
            installer.openSession(id).use { session ->
                session.openWrite("base.apk", 0, manifest.sizeBytes).use { output ->
                    apk.inputStream().use { input ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            ensureActive()
                            if (guard.isForeground() || guard.connectionUnsafe()) throw UpdateFailure("UPDATE_INTERRUPTED")
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                    }
                    session.fsync(output)
                }
                ensureActive()
                if (!installPermissionGranted()) throw UpdateFailure("INSTALL_PERMISSION_REQUIRED")
                val callback = callbackIntent(preparing)
                val sender = PendingIntent.getBroadcast(context, id, callback,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender
                // Persist BEFORE commit, so a killed/restarted UI cannot start a VPN while Android is replacing us.
                persistAttempt(preparing.copy(phase = "committing"))
                BackgroundUpdateScheduler.monitorSession(context)
                changeState { ready.copy(phase = "installing", errorCode = null) }
                committed = guard.commitIfSafe(::vpnPresentOrUnknown) {
                    synchronized(settingsLock) {
                        ensureActive()
                        if (!installPermissionGranted()) throw UpdateFailure("INSTALL_PERMISSION_REQUIRED")
                        session.commit(sender)
                    }
                }
                if (!committed) changeState { ready }
            }
        } catch (failure: UpdateFailure) {
            if (failure.code != "UPDATE_INTERRUPTED") setError(failure.code)
            throw failure
        } catch (_: Exception) {
            blockAutomatic(manifest.sha256)
            changeState { ready.copy(errorCode = "UPDATE_INSTALL_FAILED") }
        } finally {
            if (!committed) {
                val abandoned = sessionId == null || abandonSession(sessionId)
                if (abandoned) {
                    persistAttempt(null)
                    guard.releaseInstall()
                    changeState { if (it.phase == "installing") ready.copy(errorCode = it.errorCode) else it }
                } else {
                    // An uncertain PackageInstaller session continues to block CONNECTING until reconciliation.
                    changeState { ready.copy(phase = "installing", errorCode = "UPDATE_INSTALL_FAILED") }
                }
            }
        }
    }

    /** Only an explicit foreground tap can receive this file and launch Android's installer UI. */
    fun prepareManualInstall(callback: (File?, String?) -> Unit) {
        if (!busy.compareAndSet(false, true)) { callback(null, "UPDATE_BUSY"); return }
        io.execute {
            activeWork = UpdateWorkCancellation(SystemClock.elapsedRealtime() + UpdateAutomationPolicy.WORK_BUDGET_MS, false)
            var file: File? = null
            var failure: String? = null
            try {
                restoreOnce()
                reconcileInstallAttempt()
                val ready = readState()
                val manifest = ready.manifest ?: throw UpdateFailure("UPDATE_NOT_READY")
                val apk = ready.apk ?: throw UpdateFailure("UPDATE_NOT_READY")
                if (ready.phase != "ready" || guard.isInstalling()) throw UpdateFailure("UPDATE_BUSY")
                if (!installPermissionGranted()) throw UpdateFailure("INSTALL_PERMISSION_REQUIRED")
                verifyReadyFile(apk, manifest)
                // A cancelled/manual installer must not be reopened automatically by a Worker.
                blockAutomatic(manifest.sha256)
                if (!preferences.edit().putString("manual_file", apk.name).commit()) throw UpdateFailure("UPDATE_STORAGE_ERROR")
                manualFileName = apk.name
                setError(null)
                file = apk
            } catch (error: UpdateFailure) { failure = error.code; setError(error.code) }
            catch (_: Exception) { failure = "UPDATE_APK_INVALID"; setError(failure) }
            finally { activeWork = null; busy.set(false) }
            main.post { callback(file, failure) }
        }
    }

    private fun callbackIntent(value: InstallAttempt): Intent = Intent(context, UpdateInstallReceiver::class.java).apply {
        action = UpdateInstallReceiver.ACTION
        setPackage(context.packageName)
        data = Uri.parse("pushok-flow-update://install/${value.sessionId}/${value.token}")
    }

    /** Called on a short control queue, never queued behind an eight-minute transfer. */
    fun installationResult(intent: Intent, finished: () -> Unit) {
        control.execute {
            try {
                synchronized(attemptLock) {
                    val saved = attempt ?: return@execute
                    if (intent.action != UpdateInstallReceiver.ACTION || intent.data != callbackIntent(saved).data ||
                        intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != saved.sessionId ||
                        saved.phase != "committing") return@execute
                    when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)) {
                        PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                            blockAutomatic(saved.sha256)
                            // No background Activity and no persisted arbitrary Intent. Manual installation reuses our verified APK.
                            if (abandonSession(saved.sessionId)) {
                                persistAttempt(saved.copy(phase = "waiting"))
                                guard.releaseInstall()
                                changeState { if (it.manifest?.sha256 == saved.sha256)
                                    it.copy(phase = "ready", errorCode = null) else it }
                            } else {
                                persistAttempt(saved)
                                setError("UPDATE_INSTALL_FAILED")
                            }
                        }
                        PackageInstaller.STATUS_SUCCESS -> {
                            // The PackageManager/replace broadcast, not this callback alone, proves the installed version.
                            val current = installedPackage()
                            if (versionCode(current) >= saved.build) {
                                installed = current
                                persistAttempt(null)
                                guard.releaseInstall()
                                changeState { UpdateState("current", checkedAtMillis = it.checkedAtMillis) }
                            }
                        }
                        in PackageInstaller.STATUS_FAILURE..Int.MAX_VALUE -> {
                            blockAutomatic(saved.sha256)
                            persistAttempt(saved.copy(phase = "failed"))
                            guard.releaseInstall()
                            changeState { if (it.manifest?.sha256 == saved.sha256)
                                it.copy(phase = "ready", errorCode = "UPDATE_INSTALL_FAILED") else it }
                        }
                    }
                }
            } catch (_: Exception) {
                // A failed durable transition keeps the reservation; it is reconciled from PackageInstaller on restart.
                setError("UPDATE_INSTALL_FAILED")
            } finally { finished() }
        }
    }

    private fun reconcileInstallAttempt() {
        synchronized(attemptLock) {
            val saved = attempt ?: return
            val installer = context.packageManager.packageInstaller
            val current = installedPackage()
            if (versionCode(current) >= saved.build) {
                installed = current
                abandonSession(saved.sessionId)
                persistAttempt(null)
                guard.releaseInstall()
                retainedReady?.takeIf { (it.manifest?.versionCode ?: Long.MAX_VALUE) <= versionCode(current) }?.let {
                    discardStoredCandidate(it.apk)
                    retainedReady = null
                }
                changeState { if ((it.manifest?.versionCode ?: 0L) <= versionCode(current))
                    UpdateState("current", checkedAtMillis = it.checkedAtMillis) else it }
                return
            }
            if (saved.phase in setOf("waiting", "failed")) {
                // Idempotent restoration: a fresh process may have no in-memory candidate status yet.
                if (!abandonSession(saved.sessionId)) throw UpdateFailure("UPDATE_INSTALL_FAILED")
                guard.releaseInstall()
                readyAfterAttempt(saved, if (saved.phase == "failed") "UPDATE_INSTALL_FAILED" else null)
                return
            }
            val info = try { installer.getSessionInfo(saved.sessionId) }
                catch (_: Exception) { throw UpdateFailure("UPDATE_INSTALL_FAILED") }
            if (info == null) {
                blockAutomatic(saved.sha256)
                persistAttempt(saved.copy(phase = "failed"))
                guard.releaseInstall()
                readyAfterAttempt(saved, "UPDATE_INSTALL_FAILED")
                return
            }
            val age = System.currentTimeMillis() - saved.startedAt
            if (saved.phase == "preparing" || age < 0 || age > UpdateAutomationPolicy.INSTALL_TIMEOUT_MS) {
                if (!abandonSession(saved.sessionId)) throw UpdateFailure("UPDATE_INSTALL_FAILED")
                if (saved.phase == "committing") blockAutomatic(saved.sha256)
                persistAttempt(if (saved.phase == "committing") saved.copy(phase = "failed") else null)
                guard.releaseInstall()
                readyAfterAttempt(saved, if (saved.phase == "committing") "UPDATE_INSTALL_FAILED" else null)
                return
            }
            guard.restoreInstallReservation()
            val candidate = retainedReady
            if (candidate?.manifest?.sha256 == saved.sha256) changeState { candidate.copy(phase = "installing") }
            else throw UpdateFailure("UPDATE_INSTALL_FAILED")
        }
    }

    private fun readyAfterAttempt(saved: InstallAttempt, error: String?) {
        retainedReady?.takeIf { it.manifest?.sha256 == saved.sha256 }?.let { candidate ->
            changeState { candidate.copy(errorCode = error) }
        }
    }

    private fun abandonSession(id: Int): Boolean = try {
        context.packageManager.packageInstaller.abandonSession(id)
        true
    } catch (_: Exception) {
        try { context.packageManager.packageInstaller.getSessionInfo(id) == null }
        catch (_: Exception) { false }
    }

    private fun blockAutomatic(sha: String) {
        synchronized(settingsLock) {
            if (!preferences.edit().putString(BLOCKED_SHA, sha).commit()) throw UpdateFailure("UPDATE_STORAGE_ERROR")
            blockedSha = sha
        }
    }

    private fun persistAttempt(value: InstallAttempt?) {
        synchronized(attemptLock) {
            val edit = preferences.edit()
            if (value == null) edit.remove(ATTEMPT) else edit.putString(ATTEMPT, JSONObject()
                .put("sessionId", value.sessionId).put("token", value.token).put("sha256", value.sha256)
                .put("build", value.build).put("startedAt", value.startedAt).put("phase", value.phase).toString())
            if (!edit.commit()) throw UpdateFailure("UPDATE_STORAGE_ERROR")
            attempt = value
        }
    }

    private fun readAttempt(): InstallAttempt? = try {
        preferences.getString(ATTEMPT, null)?.let { raw ->
            if (raw.length > 2048) throw IllegalArgumentException()
            val json = JSONObject(raw)
            val result = InstallAttempt(json.getInt("sessionId"), json.getString("token"), json.getString("sha256"),
                json.getLong("build"), json.getLong("startedAt"), json.getString("phase"))
            if (result.sessionId < 0 || !Regex("[0-9a-f-]{36}").matches(result.token) ||
                !Regex("[0-9a-f]{64}").matches(result.sha256) || result.build <= 0 || result.startedAt <= 0 ||
                result.phase !in setOf("preparing", "committing", "waiting", "failed")) throw IllegalArgumentException()
            result
        }
    } catch (_: Exception) { null }

    fun packageReplaced() {
        // The persisted Worker performs verified-candidate cleanup, including when this receiver is the only entry point.
        try { BackgroundUpdateScheduler.configure(context, enabled, immediate = true) }
        catch (_: Exception) { setError("UPDATE_SCHEDULER_UNAVAILABLE") }
        runManual("restore") { }
    }

    private fun vpnPresentOrUnknown(): Boolean { return try {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return true
        @Suppress("DEPRECATION")
        manager.allNetworks.any { network ->
            val capabilities = manager.getNetworkCapabilities(network)
            capabilities == null || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    } catch (_: Exception) { true } }

    fun installPermissionGranted(): Boolean = try {
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()
    } catch (_: Exception) { false }

    private fun boundedDeadline(duration: Long): Long =
        minOf(SystemClock.elapsedRealtime() + duration, activeWork?.deadline ?: Long.MAX_VALUE)

    private fun ensureActive(deadline: Long = Long.MAX_VALUE) {
        val work = activeWork
        if (Thread.currentThread().isInterrupted || work?.cancelled?.get() == true ||
            (work?.automatic == true && !enabled)) throw UpdateFailure("UPDATE_INTERRUPTED")
        if (SystemClock.elapsedRealtime() >= minOf(deadline, work?.deadline ?: Long.MAX_VALUE)) {
            throw UpdateFailure("UPDATE_INTERRUPTED")
        }
    }

    private fun readRemoteMetadata(uri: URI, deadline: Long, maxBytes: Int,
        releaseApi: Boolean = false, release: PublishedUpdateRelease? = null): ByteArray {
        val bytes = ByteArrayOutputStream()
        withConnection(uri, null, deadline, releaseApi = releaseApi, release = release) { remote ->
            if (remote.contentLengthLong > maxBytes) throw UpdateFailure("UPDATE_METADATA_INVALID")
            remote.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    ensureActive(deadline)
                    remote.readTimeout = remainingTimeout(deadline, 20_000)
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (bytes.size() + count > maxBytes) throw UpdateFailure("UPDATE_METADATA_INVALID")
                    bytes.write(buffer, 0, count)
                }
            }
        }
        return bytes.toByteArray()
    }

    private fun parseJson(bytes: ByteArray): JSONObject {
        try {
            val text = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
            val tokens = JSONTokener(text)
            val json = tokens.nextValue() as? JSONObject ?: throw UpdateFailure("UPDATE_METADATA_INVALID")
            if (tokens.nextClean() != '\u0000') throw UpdateFailure("UPDATE_METADATA_INVALID")
            return json
        } catch (failure: UpdateFailure) {
            throw failure
        } catch (_: Exception) {
            throw UpdateFailure("UPDATE_METADATA_INVALID")
        }
    }

    private fun jsonValues(json: JSONObject): Map<String, Any?> {
        val values = mutableMapOf<String, Any?>()
        json.keys().forEach { key -> values[key] = json.get(key) }
        return values
    }

    private fun manifestFromJson(json: JSONObject): UpdateManifest = UpdatePolicy.manifest(jsonValues(json))

    private fun cachedManifestFromJson(json: JSONObject): UpdateManifest =
        UpdatePolicy.cachedManifest(jsonValues(json), Build.SUPPORTED_ABIS.toList())

    private fun cachedReleaseNotesFromJson(json: JSONObject, manifest: UpdateManifest): UpdateReleaseNotes? {
        val changes = json.optJSONArray("changes") ?: return null
        if (changes.length() > UpdateReleaseNotesPolicy.MAX_CHANGES) return null
        val values = jsonValues(json).toMutableMap()
        values["changes"] = (0 until changes.length()).map { changes.get(it) }
        if (json.has("publishedOn") && json.isNull("publishedOn")) values["publishedOn"] = null
        return UpdateReleaseNotesPolicy.restore(values, manifest)
    }

    private fun releaseFromJson(json: JSONObject): PublishedUpdateRelease {
        val values = jsonValues(json).toMutableMap()
        if (json.has("assets")) {
            val assets = json.get("assets") as? JSONArray ?: throw UpdateFailure("UPDATE_METADATA_INVALID")
            if (assets.length() > UpdatePolicy.MAX_RELEASE_ASSETS) throw UpdateFailure("UPDATE_METADATA_INVALID")
            values["assets"] = (0 until assets.length()).map { index ->
                val asset = assets.get(index) as? JSONObject ?: throw UpdateFailure("UPDATE_METADATA_INVALID")
                jsonValues(asset)
            }
        }
        return UpdatePolicy.publishedRelease(values)
    }

    private fun remainingTimeout(deadline: Long, limit: Int): Int =
        (deadline - SystemClock.elapsedRealtime()).coerceIn(1, limit.toLong()).toInt()


    private fun withConnection(initial: URI, apk: UpdateManifest?, deadline: Long,
        releaseApi: Boolean = false, release: PublishedUpdateRelease? = null, offset: Long = 0,
        consume: (HttpsURLConnection) -> Unit) {
        var uri = initial
        repeat(6) { redirect ->
            ensureActive(deadline)
            val allowed = when {
                releaseApi -> UpdatePolicy.allowedReleaseRequest(uri)
                apk != null -> UpdatePolicy.allowedApkRequest(uri, apk)
                release != null -> UpdatePolicy.allowedManifestRequest(uri, release)
                else -> false
            }
            if (!allowed) throw UpdateFailure("UPDATE_METADATA_INVALID")
            val remote = uri.toURL().openConnection() as? HttpsURLConnection
                ?: throw UpdateFailure("UPDATE_NETWORK_ERROR")
            activeWork?.connection = remote
            try {
                remote.instanceFollowRedirects = false
                remote.connectTimeout = remainingTimeout(deadline, 15_000)
                remote.readTimeout = remainingTimeout(deadline, 20_000)
                remote.useCaches = false
                remote.setRequestProperty("Accept-Encoding", "identity")
                if (offset > 0 && apk != null) remote.setRequestProperty("Range", "bytes=$offset-")
                remote.setRequestProperty("Accept", if (releaseApi) "application/vnd.github+json" else "application/octet-stream")
                remote.setRequestProperty("User-Agent", "Pushok-Flow-Updater")
                if (apk == null) {
                    // Request revalidation; these headers do not prove global CDN freshness.
                    remote.setRequestProperty("Cache-Control", "no-cache, max-age=0")
                    remote.setRequestProperty("Pragma", "no-cache")
                }
                if (releaseApi) remote.setRequestProperty("X-GitHub-Api-Version", "2026-03-10")
                val status = remote.responseCode
                ensureActive(deadline)
                if (status in setOf(301, 302, 303, 307, 308)) {
                    if (redirect == 5) throw UpdateFailure("UPDATE_NETWORK_ERROR")
                    val location = remote.getHeaderField("Location")
                        ?: throw UpdateFailure("UPDATE_NETWORK_ERROR")
                    if (location.length > 8192) throw UpdateFailure("UPDATE_METADATA_INVALID")
                    uri = try { uri.resolve(location) }
                        catch (_: Exception) { throw UpdateFailure("UPDATE_METADATA_INVALID") }
                } else {
                    if (status == 429 || (status == 403 &&
                            (remote.getHeaderField("X-RateLimit-Remaining") == "0" ||
                                remote.getHeaderField("Retry-After") != null))) {
                        throw UpdateFailure("UPDATE_RATE_LIMITED")
                    }
                    if (status == 404 && releaseApi) throw UpdateFailure("UPDATE_UNAVAILABLE")
                    if (status == 404 && release != null) throw UpdateFailure("UPDATE_METADATA_STALE")
                    if (status != 200 && !(status == 206 && apk != null && offset > 0)) {
                        if (status == 416 && apk != null) throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
                        throw UpdateFailure("UPDATE_NETWORK_ERROR")
                    }
                    val encoding = remote.contentEncoding
                    if (encoding != null && !encoding.equals("identity", ignoreCase = true)) {
                        throw UpdateFailure("UPDATE_METADATA_INVALID")
                    }
                    consume(remote)
                    return
                }
            } finally {
                remote.disconnect()
                if (activeWork?.connection === remote) activeWork?.connection = null
            }
        }
        throw UpdateFailure("UPDATE_NETWORK_ERROR")
    }


    private fun updateDirectory(): File {
        try {
            val cache = context.filesDir.canonicalFile
            val directory = File(cache, "updates")
            if ((!directory.isDirectory && !directory.mkdirs()) || directory.canonicalFile != directory) {
                throw UpdateFailure("UPDATE_STORAGE_ERROR")
            }
            return directory
        } catch (failure: UpdateFailure) {
            throw failure
        } catch (_: Exception) {
            throw UpdateFailure("UPDATE_STORAGE_ERROR")
        }
    }

    private fun ensureOwnedFile(file: File) {
        if (!updateName.matches(file.name) || !file.isFile || file.canonicalFile != file.absoluteFile ||
            file.canonicalFile.parentFile != updateDirectory()) {
            throw UpdateFailure("UPDATE_NOT_READY")
        }
    }

    private fun candidateStore(): AtomicFile {
        val directory = updateDirectory()
        // AtomicFile may use a backup or a new-file sibling, depending on Android.
        for (suffix in listOf("", ".bak", ".new")) {
            val file = File(directory, "ready-update.json$suffix")
            if (file.canonicalFile != file) throw UpdateFailure("UPDATE_STORAGE_ERROR")
        }
        return AtomicFile(File(directory, "ready-update.json"))
    }

    private fun persistCandidate(manifest: UpdateManifest, file: File) {
        ensureOwnedFile(file)
        UpdatePolicy.requireCandidateFileName(file.name, manifest)
        val record = JSONObject().put("manifest", JSONObject(UpdatePolicy.manifestFields(manifest)))
            .put("fileName", file.name).toString().toByteArray(StandardCharsets.UTF_8)
        val store = candidateStore()
        val output = try { store.startWrite() }
            catch (_: Exception) { throw UpdateFailure("UPDATE_STORAGE_ERROR") }
        try {
            output.write(record)
            store.finishWrite(output)
        } catch (_: Exception) {
            store.failWrite(output)
            throw UpdateFailure("UPDATE_STORAGE_ERROR")
        }
    }

    private fun discardStoredCandidate(file: File? = null) {
        try {
            candidateStore().delete()
            if (file != null && file.canonicalFile == file.absoluteFile &&
                file.parentFile == updateDirectory() && updateName.matches(file.name)) file.delete()
        } catch (_: Exception) { /* An unusable cache entry is never offered for installation. */ }
    }

    private fun restoreCandidate(): UpdateState? {
        val store = candidateStore()
        if (!store.baseFile.exists() && !File(store.baseFile.path + ".bak").exists()) return null
        var candidate: File? = null
        try {
            val bytes = store.openRead().use { readCachedMetadata(it) }
            val record = parseJson(bytes)
            if (record.keys().asSequence().toSet() != setOf("manifest", "fileName")) {
                throw UpdateFailure("UPDATE_METADATA_INVALID")
            }
            val manifest = cachedManifestFromJson(record.getJSONObject("manifest"))
            val name = record.get("fileName") as? String ?: throw UpdateFailure("UPDATE_APK_INVALID")
            UpdatePolicy.requireCandidateFileName(name, manifest)
            val file = File(updateDirectory(), name)
            candidate = file
            if (manifest.versionCode <= versionCode(installedPackage())) {
                discardStoredCandidate(file)
                return null
            }
            verifyReadyFile(file, manifest)
            ensureActive()
            return UpdateState("ready", manifest, file, manifest.sizeBytes, manifest.sizeBytes,
                checkedAtMillis = preferences.getLong("checked_at", 0).takeIf { it > 0 })
        } catch (failure: UpdateFailure) {
            if (failure.code != "UPDATE_INTERRUPTED" && failure.code != "UPDATE_NETWORK_ERROR") {
                discardStoredCandidate(candidate)
            }
            throw failure
        } catch (_: Exception) {
            discardStoredCandidate(candidate)
            throw UpdateFailure("UPDATE_APK_INVALID")
        }
    }

    private fun readCachedMetadata(input: InputStream): ByteArray {
        val deadline = boundedDeadline(CHECK_TIMEOUT_MS)
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            ensureActive(deadline)
            val count = input.read(buffer)
            if (count < 0) break
            if (output.size() + count > UpdatePolicy.MAX_METADATA_BYTES) {
                throw UpdateFailure("UPDATE_METADATA_INVALID")
            }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun verifyReadyFile(file: File, manifest: UpdateManifest) {
        ensureOwnedFile(file)
        val deadline = boundedDeadline(CHECK_TIMEOUT_MS)
        if (file.length() != manifest.sizeBytes) throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
        val digest = MessageDigest.getInstance("SHA-256")
        var received = 0L
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                ensureActive(deadline)
                val count = input.read(buffer)
                if (count < 0) break
                received += count
                if (received > manifest.sizeBytes) throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
                digest.update(buffer, 0, count)
            }
        }
        if (received != manifest.sizeBytes || UpdatePolicy.hex(digest.digest()) != manifest.sha256) {
            throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
        }
        verifyArchive(file, manifest)
    }

    @Suppress("DEPRECATION")
    private fun installedPackage(): PackageInfo = context.packageManager.getPackageInfo(context.packageName,
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES
        else PackageManager.GET_SIGNATURES)

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return emptySet()
            signing.apkContentsSigners?.toList().orEmpty()
        } else info.signatures?.toList().orEmpty()
        return signatures.map { UpdatePolicy.sha256(it.toByteArray()) }.toSet()
    }

    @Suppress("DEPRECATION")
    private fun verifyArchive(file: File, manifest: UpdateManifest) {
        try {
            ensureOwnedFile(file)
            val current = installedPackage()
            UpdatePolicy.requireCompatible(manifest, current.packageName, signerDigests(current), Build.VERSION.SDK_INT)
            UpdatePolicy.requireDeviceCompatible(manifest, Build.SUPPORTED_ABIS.toList())
            UpdatePolicy.requireNewer(manifest, versionCode(current))
            val archive = context.packageManager.getPackageArchiveInfo(file.path,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES
                else PackageManager.GET_SIGNATURES) ?: throw UpdateFailure("UPDATE_APK_INVALID")
            val info = archive.applicationInfo ?: throw UpdateFailure("UPDATE_APK_INVALID")
            if (archive.packageName != UpdatePolicy.PACKAGE_NAME || versionCode(archive) != manifest.versionCode ||
                archive.versionName != manifest.versionName || info.minSdkVersion != manifest.minSdk ||
                !archive.splitNames.isNullOrEmpty()) throw UpdateFailure("UPDATE_APK_INVALID")
            if (signerDigests(archive) != setOf(manifest.certificateSha256)) {
                throw UpdateFailure("UPDATE_SIGNATURE_MISMATCH")
            }
            if (UpdatePolicy.apkAbi(manifest) != null) ZipFile(file).use { zip ->
                UpdatePolicy.requireArchiveAbi(manifest, zip.entries().asSequence().map { it.name to it.size })
            }
        } catch (failure: UpdateFailure) {
            throw failure
        } catch (_: Exception) {
            throw UpdateFailure("UPDATE_APK_INVALID")
        }
    }


    private fun deleteOwnedFile(file: File) {
        try {
            if (file.canonicalFile == file.absoluteFile && file.parentFile == updateDirectory() &&
                updateName.matches(file.name) && file.name != manualFileName) file.delete()
        } catch (_: Exception) { /* Cleanup cannot make an unverified file installable. */ }
    }
}
