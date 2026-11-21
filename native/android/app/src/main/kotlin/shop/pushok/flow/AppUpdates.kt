package shop.pushok.flow

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.AtomicFile
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.lang.ref.WeakReference
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.HttpsURLConnection

/** A concrete provider avoids device-specific failures of a bare FileProvider. */
class UpdateFileProvider : FileProvider()

/** All network and installation actions require an explicit method-channel call. */
class AppUpdates(activity: Activity) {
    private val context = activity.applicationContext
    private val activityReference = WeakReference(activity)
    private val main = Handler(Looper.getMainLooper())
    private val disposed = AtomicBoolean(false)
    private val busy = AtomicBoolean(false)
    private val foreground = AtomicBoolean(false)
    private val foregroundEpoch = AtomicLong(0)
    private val restoreStarted = AtomicBoolean(false)
    private val stateLock = Any()
    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    @Volatile private var connection: HttpsURLConnection? = null
    private val installed = try { installedPackage() } catch (_: Exception) { null }
    private var state = UpdateState(if (installed == null) "unavailable" else "idle",
        errorCode = if (installed == null) "UPDATE_INCOMPATIBLE" else null)

    companion object {
        // One process-wide queue also serializes cache writes across Activity recreation.
        private val io = Executors.newSingleThreadExecutor()
        private const val CHECK_TIMEOUT_MS = 60_000L
        private const val DOWNLOAD_TIMEOUT_MS = 10 * 60_000L
        private val cacheName = Regex("(?:pending-[0-9-]+|verified-[0-9]+-[0-9a-f]{16})\\.apk")
    }

    fun register(messenger: BinaryMessenger) {
        check(!disposed.get())
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, "shop.pushok.flow/updates").also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateStatus" -> updateStatus(result)
                    "checkForUpdates" -> checkForUpdates(result)
                    "downloadUpdate" -> downloadUpdate(result)
                    "openInstallPermission" -> openInstallPermission(result)
                    "installUpdate" -> installUpdate(result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun setForeground(value: Boolean) {
        // Even pause -> resume while verification is running requires a new tap.
        if (!value) foregroundEpoch.incrementAndGet()
        foreground.set(value && !disposed.get())
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        setForeground(false)
        channel?.setMethodCallHandler(null)
        channel = null
        try { connection?.disconnect() } catch (_: Exception) { /* Request is being cancelled. */ }
        connection = null
        val result = pendingResult
        pendingResult = null
        busy.set(false)
        if (result != null) {
            changeState { it.copy(phase = "error", apk = null, errorCode = "UPDATE_INTERRUPTED", checkStage = null) }
            result.success(snapshot())
        }
        activityReference.clear()
    }

    private fun readState(): UpdateState = synchronized(stateLock) { state }

    private fun changeState(transform: (UpdateState) -> UpdateState) {
        synchronized(stateLock) { state = transform(state) }
    }

    private fun updateStatus(result: MethodChannel.Result) {
        if (restoreStarted.get() || busy.get()) {
            result.success(snapshot())
            return
        }
        runIo(result, { it.copy(phase = "checking", errorCode = null) }, "UPDATE_APK_INVALID", work = {
            restoreStarted.set(true)
            val restored = restoreCandidate()
            changeState { restored ?: UpdateState(if (installed == null) "unavailable" else "idle",
                errorCode = if (installed == null) "UPDATE_INCOMPATIBLE" else null) }
        })
    }

    private fun snapshot(errorOverride: String? = null): Map<String, Any?> {
        val current = readState()
        val permission = installPermissionGranted()
        val error = errorOverride ?: current.errorCode?.takeUnless {
            it == "INSTALL_PERMISSION_REQUIRED" && permission
        }
        return mapOf(
            "installedVersion" to (installed?.versionName ?: "0.0.0"),
            "installedBuild" to (installed?.let(::versionCode) ?: 0L),
            "phase" to current.phase,
            "availableVersion" to current.manifest?.versionName,
            "availableBuild" to current.manifest?.versionCode,
            "downloadedBytes" to current.downloadedBytes,
            "totalBytes" to current.totalBytes,
            "errorCode" to error,
            "installPermissionGranted" to permission,
            "checkedAtMillis" to current.checkedAtMillis,
            "checkStage" to current.checkStage,
        )
    }

    private fun runIo(result: MethodChannel.Result, initial: (UpdateState) -> UpdateState,
        defaultError: String, work: () -> Unit, onSuccess: (() -> Unit)? = null,
        onFailure: ((String) -> UpdateState)? = null) {
        if (disposed.get()) {
            result.success(snapshot("UPDATE_INTERRUPTED"))
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.success(snapshot("UPDATE_BUSY"))
            return
        }
        pendingResult = result
        changeState(initial)
        io.execute {
            var failure: String? = null
            try {
                ensureActive()
                work()
            } catch (error: UpdateFailure) {
                failure = error.code
            } catch (_: Exception) {
                // Never return or log URLs, filesystem paths, or raw platform errors.
                failure = defaultError
            }
            val failureCode = failure
            main.post {
                if (disposed.get() || pendingResult !== result) return@post
                if (failureCode != null) {
                    changeState { onFailure?.invoke(failureCode) ?: it.copy(phase = if (failureCode == "UPDATE_UNAVAILABLE")
                        "unavailable" else "error", apk = null, errorCode = failureCode, checkStage = null) }
                } else {
                    try { onSuccess?.invoke() }
                    catch (error: UpdateFailure) {
                        changeState { it.copy(errorCode = error.code) }
                    } catch (_: Exception) {
                        changeState { it.copy(errorCode = "INSTALLER_UNAVAILABLE") }
                    }
                }
                pendingResult = null
                busy.set(false)
                result.success(snapshot())
            }
        }
    }

    private fun checkForUpdates(result: MethodChannel.Result) {
        val previous = readState()
        val session = UpdateCheckSession(previous, installed?.let(::versionCode) ?: 0L)
        runIo(result, { session.checking("release") }, "UPDATE_NETWORK_ERROR", work = {
            restoreStarted.set(true)
            // Restore first, including when a new Activity calls check directly.
            // Network failure must never remove a verified downloaded update.
            val cached = try { restoreCandidate() } catch (failure: UpdateFailure) {
                if (failure.code == "UPDATE_INTERRUPTED" || failure.code == "UPDATE_NETWORK_ERROR") throw failure
                null
            }
            session.recover(cached)
            changeState { session.checking("release") }
            val deadline = SystemClock.elapsedRealtime() + CHECK_TIMEOUT_MS
            val releaseBytes = readRemoteMetadata(URI(UpdatePolicy.LATEST_RELEASE_URL), deadline,
                UpdatePolicy.MAX_RELEASE_BYTES, releaseApi = true)
            val release = UpdatePolicy.publishedRelease(jsonValues(parseJson(releaseBytes)))
            changeState { session.checking("manifest") }
            val manifest = parseManifest(readRemoteMetadata(URI(UpdatePolicy.manifestUrl(release)),
                deadline, UpdatePolicy.MAX_METADATA_BYTES, release = release))
            val current = installedPackage()
            UpdatePolicy.requireCompatible(manifest, current.packageName, signerDigests(current), Build.VERSION.SDK_INT)
            val next = session.complete(release, manifest, current.versionName ?: "0.0.0",
                System.currentTimeMillis())
            // Only a complete, consistent check may supersede the stored candidate.
            if (next.phase != "ready") discardStoredCandidate()
            changeState { next }
        }, onFailure = session::failed)
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

    private fun downloadUpdate(result: MethodChannel.Result) {
        if (busy.get()) {
            result.success(snapshot("UPDATE_BUSY"))
            return
        }
        val manifest = readState().manifest
        if (manifest == null) {
            result.success(snapshot("UPDATE_NOT_READY"))
            return
        }
        runIo(result, { UpdateState("downloading", manifest, totalBytes = manifest.sizeBytes,
            checkedAtMillis = it.checkedAtMillis) },
            "UPDATE_DOWNLOAD_FAILED", work = {
                val current = installedPackage()
                UpdatePolicy.requireCompatible(manifest, current.packageName, signerDigests(current), Build.VERSION.SDK_INT)
                UpdatePolicy.requireNewer(manifest, versionCode(current))
                val directory = updateDirectory()
                discardStoredCandidate()
                // Only this updater's fixed-name files are removed, never other cache data.
                directory.listFiles()?.filter { cacheName.matches(it.name) }?.forEach { old ->
                    if (old.canonicalFile.parentFile == directory && old.isFile && !old.delete()) {
                        throw UpdateFailure("UPDATE_STORAGE_ERROR")
                    }
                }
                val temporary = try { File.createTempFile("pending-", ".apk", directory) }
                    catch (_: IOException) { throw UpdateFailure("UPDATE_STORAGE_ERROR") }
                try {
                    val deadline = SystemClock.elapsedRealtime() + DOWNLOAD_TIMEOUT_MS
                    val digest = MessageDigest.getInstance("SHA-256")
                    var received = 0L
                    withConnection(URI(manifest.apkUrl), manifest.versionName, deadline) { remote ->
                        val length = remote.contentLengthLong
                        if (length >= 0 && length != manifest.sizeBytes) throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
                        val output = try { FileOutputStream(temporary) }
                            catch (_: IOException) { throw UpdateFailure("UPDATE_STORAGE_ERROR") }
                        output.use { file ->
                            remote.inputStream.use { input ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    ensureActive(deadline)
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    received += count
                                    if (received > manifest.sizeBytes || received > UpdatePolicy.MAX_APK_BYTES) {
                                        throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
                                    }
                                    try { file.write(buffer, 0, count) }
                                    catch (_: IOException) { throw UpdateFailure("UPDATE_STORAGE_ERROR") }
                                    digest.update(buffer, 0, count)
                                    changeState { it.copy(downloadedBytes = received) }
                                }
                            }
                            try { file.fd.sync() }
                            catch (_: IOException) { throw UpdateFailure("UPDATE_STORAGE_ERROR") }
                        }
                    }
                    if (received != manifest.sizeBytes || UpdatePolicy.hex(digest.digest()) != manifest.sha256) {
                        throw UpdateFailure("UPDATE_CHECKSUM_MISMATCH")
                    }
                    verifyArchive(temporary, manifest)
                    ensureActive(deadline)
                    val verified = File(directory, UpdatePolicy.candidateFileName(manifest))
                    if (!temporary.setReadOnly() || !temporary.renameTo(verified)) {
                        throw UpdateFailure("UPDATE_STORAGE_ERROR")
                    }
                    try { persistCandidate(manifest, verified) }
                    catch (failure: Exception) { verified.delete(); throw failure }
                    changeState { UpdateState("ready", manifest, verified, manifest.sizeBytes, manifest.sizeBytes,
                        checkedAtMillis = it.checkedAtMillis) }
                } finally {
                    temporary.delete()
                }
            })
    }

    private fun openInstallPermission(result: MethodChannel.Result) {
        if (busy.get()) {
            result.success(snapshot("UPDATE_BUSY"))
            return
        }
        if (readState().apk == null) {
            result.success(snapshot("UPDATE_NOT_READY"))
            return
        }
        try {
            val activity = liveActivity()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !installPermissionGranted()) {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}")))
            }
            changeState { it.copy(errorCode = null) }
            result.success(snapshot())
        } catch (failure: UpdateFailure) {
            changeState { it.copy(errorCode = failure.code) }
            result.success(snapshot())
        } catch (_: Exception) {
            result.success(snapshot("INSTALLER_UNAVAILABLE"))
        }
    }

    private fun installUpdate(result: MethodChannel.Result) {
        if (busy.get()) {
            result.success(snapshot("UPDATE_BUSY"))
            return
        }
        val ready = readState()
        val manifest = ready.manifest
        val apk = ready.apk
        if (manifest == null || apk == null || ready.phase != "ready") {
            result.success(snapshot("UPDATE_NOT_READY"))
            return
        }
        val launchEpoch = foregroundEpoch.get()
        try { liveActivity(launchEpoch) }
        catch (failure: UpdateFailure) {
            changeState { it.copy(errorCode = failure.code) }
            result.success(snapshot())
            return
        }
        if (!installPermissionGranted()) {
            changeState { it.copy(errorCode = "INSTALL_PERMISSION_REQUIRED") }
            result.success(snapshot())
            return
        }
        runIo(result, { it.copy(errorCode = null) }, "UPDATE_APK_INVALID", work = {
            verifyReadyFile(apk, manifest)
        }, onSuccess = {
            val activity = liveActivity(launchEpoch)
            if (!installPermissionGranted()) throw UpdateFailure("INSTALL_PERMISSION_REQUIRED")
            ensureCacheFile(apk)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", apk)
            @Suppress("DEPRECATION")
            val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                data = uri
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri("Pushok Flow update", uri)
            }
            activity.startActivity(intent)
            // Ready means the verified file exists, never that installation succeeded.
        })
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

    private fun parseManifest(bytes: ByteArray): UpdateManifest = manifestFromJson(parseJson(bytes))

    private fun jsonValues(json: JSONObject): Map<String, Any?> {
        val values = mutableMapOf<String, Any?>()
        json.keys().forEach { key -> values[key] = json.get(key) }
        return values
    }

    private fun manifestFromJson(json: JSONObject): UpdateManifest = UpdatePolicy.manifest(jsonValues(json))

    private fun remainingTimeout(deadline: Long, limit: Int): Int =
        (deadline - SystemClock.elapsedRealtime()).coerceIn(1, limit.toLong()).toInt()

    private fun withConnection(initial: URI, apkVersion: String?, deadline: Long,
        releaseApi: Boolean = false, release: PublishedUpdateRelease? = null,
        consume: (HttpsURLConnection) -> Unit) {
        var uri = initial
        repeat(6) { redirect ->
            ensureActive(deadline)
            val allowed = when {
                releaseApi -> UpdatePolicy.allowedReleaseRequest(uri)
                apkVersion != null -> UpdatePolicy.allowedRequest(uri, apkVersion)
                release != null -> UpdatePolicy.allowedManifestRequest(uri, release)
                else -> false
            }
            if (!allowed) throw UpdateFailure("UPDATE_METADATA_INVALID")
            val remote = uri.toURL().openConnection() as? HttpsURLConnection
                ?: throw UpdateFailure("UPDATE_NETWORK_ERROR")
            connection = remote
            try {
                remote.instanceFollowRedirects = false
                remote.connectTimeout = remainingTimeout(deadline, 15_000)
                remote.readTimeout = remainingTimeout(deadline, 20_000)
                remote.useCaches = false
                remote.setRequestProperty("Accept-Encoding", "identity")
                remote.setRequestProperty("Accept", if (releaseApi) "application/vnd.github+json" else "application/octet-stream")
                remote.setRequestProperty("User-Agent", "Pushok-Flow-Updater")
                if (apkVersion == null) {
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
                    if (status != 200) throw UpdateFailure("UPDATE_NETWORK_ERROR")
                    val encoding = remote.contentEncoding
                    if (encoding != null && !encoding.equals("identity", ignoreCase = true)) {
                        throw UpdateFailure("UPDATE_METADATA_INVALID")
                    }
                    consume(remote)
                    return
                }
            } finally {
                remote.disconnect()
                if (connection === remote) connection = null
            }
        }
        throw UpdateFailure("UPDATE_NETWORK_ERROR")
    }

    private fun ensureActive(deadline: Long = Long.MAX_VALUE) {
        if (disposed.get() || Thread.currentThread().isInterrupted) throw UpdateFailure("UPDATE_INTERRUPTED")
        if (SystemClock.elapsedRealtime() >= deadline) throw UpdateFailure("UPDATE_NETWORK_ERROR")
    }

    private fun liveActivity(expectedEpoch: Long? = null): Activity {
        val activity = activityReference.get()
        if (disposed.get() || !foreground.get() ||
            (expectedEpoch != null && expectedEpoch != foregroundEpoch.get()) ||
            activity == null || activity.isFinishing || activity.isDestroyed) {
            throw UpdateFailure("UPDATE_INTERRUPTED")
        }
        return activity
    }

    private fun updateDirectory(): File {
        try {
            val cache = context.cacheDir.canonicalFile
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

    private fun ensureCacheFile(file: File) {
        if (!cacheName.matches(file.name) || !file.isFile || file.canonicalFile != file.absoluteFile ||
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
        ensureCacheFile(file)
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
                file.parentFile == updateDirectory() && cacheName.matches(file.name)) file.delete()
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
            val manifest = manifestFromJson(record.getJSONObject("manifest"))
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
            return UpdateState("ready", manifest, file, manifest.sizeBytes, manifest.sizeBytes)
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
        val deadline = SystemClock.elapsedRealtime() + CHECK_TIMEOUT_MS
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
        ensureCacheFile(file)
        val deadline = SystemClock.elapsedRealtime() + CHECK_TIMEOUT_MS
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
            ensureCacheFile(file)
            val current = installedPackage()
            UpdatePolicy.requireCompatible(manifest, current.packageName, signerDigests(current), Build.VERSION.SDK_INT)
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
        } catch (failure: UpdateFailure) {
            throw failure
        } catch (_: Exception) {
            throw UpdateFailure("UPDATE_APK_INVALID")
        }
    }

    private fun installPermissionGranted(): Boolean = try {
        // Before Android 8, the system installer handles the global unknown-sources setting.
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()
    } catch (_: Exception) { false }
}
