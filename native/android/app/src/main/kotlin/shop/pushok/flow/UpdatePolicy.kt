package shop.pushok.flow

import java.net.URI
import java.io.File
import java.security.MessageDigest
import java.util.Locale

internal class UpdateFailure(val code: String) : Exception()

internal data class UpdateManifest(
    val versionName: String,
    val versionCode: Long,
    val minSdk: Int,
    val apkUrl: String,
    val sha256: String,
    val sizeBytes: Long,
    val certificateSha256: String,
)

internal data class PublishedUpdateRelease(val id: Long, val versionName: String)

internal data class UpdateState(
    val phase: String,
    val manifest: UpdateManifest? = null,
    val apk: File? = null,
    val downloadedBytes: Long = 0,
    val totalBytes: Long = 0,
    val errorCode: String? = null,
    val checkedAtMillis: Long? = null,
    val checkStage: String? = null,
)

/** A failed check cannot erase a previously discovered or verified update.
 * The caller restores and verifies the cached APK before calling [recover]. */
internal class UpdateCheckSession(previous: UpdateState, private val installedBuild: Long) {
    private val lastCheckedAtMillis = previous.checkedAtMillis
    private val known = mutableListOf<UpdateManifest>()
    private var retained: UpdateState? = previous.manifest?.takeIf {
        it.versionCode > installedBuild
    }?.let {
        known.add(it)
        // A previous ready state is only restored after the file has been verified again.
        UpdateState("available", it, totalBytes = it.sizeBytes,
            checkedAtMillis = lastCheckedAtMillis)
    }

    fun recover(verified: UpdateState?) {
        if (verified == null) return
        check(verified.phase == "ready" && verified.manifest != null && verified.apk != null)
        val manifest = verified.manifest
        if (manifest.versionCode <= installedBuild) return
        known.add(manifest)
        val prior = retained?.manifest
        if (prior == null || manifest.versionCode > prior.versionCode || manifest == prior) {
            retained = verified.copy(errorCode = null, checkedAtMillis = lastCheckedAtMillis,
                checkStage = null)
        }
    }

    fun checking(stage: String): UpdateState = (retained ?: UpdateState("checking",
        checkedAtMillis = lastCheckedAtMillis)).copy(phase = "checking", errorCode = null,
        checkStage = stage)

    fun failed(code: String): UpdateState = (retained ?: UpdateState(
        if (code == "UPDATE_UNAVAILABLE") "unavailable" else "error",
        checkedAtMillis = lastCheckedAtMillis)).copy(errorCode = code, checkStage = null)

    fun complete(release: PublishedUpdateRelease, manifest: UpdateManifest,
        installedVersion: String, checkedAtMillis: Long): UpdateState {
        UpdatePolicy.requireFresh(release, manifest, installedVersion, installedBuild, known)
        val ready = retained
        return when {
            manifest.versionCode == installedBuild -> UpdateState("current", checkedAtMillis = checkedAtMillis)
            ready?.phase == "ready" && ready.manifest == manifest ->
                ready.copy(errorCode = null, checkedAtMillis = checkedAtMillis, checkStage = null)
            else -> UpdateState("available", manifest, totalBytes = manifest.sizeBytes,
                checkedAtMillis = checkedAtMillis)
        }
    }
}

/** Trust decisions shared by metadata, download and the final install check. */
internal object UpdatePolicy {
    const val PACKAGE_NAME = "shop.pushok.flow"
    const val RELEASE_ROOT = "https://github.com/mrkoster1988/Pushok-Flow/releases"
    const val MANIFEST_URL = "$RELEASE_ROOT/latest/download/update.json"
    const val LATEST_RELEASE_URL = "https://api.github.com/repos/mrkoster1988/Pushok-Flow/releases/latest"
    const val MAX_METADATA_BYTES = 64 * 1024
    const val MAX_RELEASE_BYTES = 256 * 1024
    const val MAX_APK_BYTES = 200L * 1024 * 1024
    private const val REPO_PATH = "/mrkoster1988/Pushok-Flow/releases"
    private val versionPattern = Regex("(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)")
    private val digestPattern = Regex("[0-9a-f]{64}")
    private val fields = setOf("schemaVersion", "packageName", "versionName", "versionCode",
        "minSdk", "apkUrl", "sha256", "sizeBytes", "certificateSha256")

    fun publishedRelease(raw: Map<String, Any?>): PublishedUpdateRelease {
        fun invalid(): Nothing = throw UpdateFailure("UPDATE_METADATA_INVALID")
        val id = when (val value = raw["id"]) {
            is Int -> value.toLong()
            is Long -> value
            else -> invalid()
        }
        val tag = raw["tag_name"] as? String ?: invalid()
        val published = raw["published_at"] as? String ?: invalid()
        val version = tag.removePrefix("v")
        if (id <= 0 || tag != "v$version" || version.length > 32 ||
            !versionPattern.matches(version) || raw["draft"] != false ||
            raw["prerelease"] != false ||
            !Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z").matches(published)) invalid()
        return PublishedUpdateRelease(id, version)
    }

    fun manifestUrl(release: PublishedUpdateRelease): String =
        "$RELEASE_ROOT/download/v${release.versionName}/update.json"

    fun requireFresh(release: PublishedUpdateRelease, manifest: UpdateManifest,
        installedVersion: String, installedBuild: Long, known: List<UpdateManifest> = emptyList()) {
        fun stale(): Nothing = throw UpdateFailure("UPDATE_METADATA_STALE")
        if (manifest.versionName != release.versionName || manifest.versionCode < installedBuild ||
            (manifest.versionCode == installedBuild && manifest.versionName != installedVersion)) stale()
        if (versionPattern.matches(installedVersion) && compareVersions(manifest.versionName, installedVersion) < 0) stale()
        for (prior in known) {
            if (manifest.versionCode < prior.versionCode ||
                compareVersions(manifest.versionName, prior.versionName) < 0 ||
                ((manifest.versionCode == prior.versionCode || manifest.versionName == prior.versionName) &&
                    manifest != prior)) stale()
        }
    }

    private fun compareVersions(left: String, right: String): Int {
        for ((a, b) in left.split('.').zip(right.split('.'))) {
            val comparison = if (a.length != b.length) a.length.compareTo(b.length) else a.compareTo(b)
            if (comparison != 0) return comparison
        }
        return 0
    }

    fun allowedReleaseRequest(uri: URI): Boolean = safeUri(uri) &&
        uri.host?.lowercase(Locale.ROOT) == "api.github.com" && uri.rawQuery == null &&
        uri.path == "/repos/mrkoster1988/Pushok-Flow/releases/latest"

    fun allowedManifestRequest(uri: URI, release: PublishedUpdateRelease): Boolean =
        allowedRequest(uri, null) && (uri.host?.lowercase(Locale.ROOT) != "github.com" ||
            uri.path == "/mrkoster1988/Pushok-Flow/releases/download/v${release.versionName}/update.json")

    fun manifest(raw: Map<String, Any?>): UpdateManifest {
        fun invalid(): Nothing = throw UpdateFailure("UPDATE_METADATA_INVALID")
        fun string(name: String): String = raw[name] as? String ?: invalid()
        fun integer(name: String): Long = when (val value = raw[name]) {
            is Int -> value.toLong()
            is Long -> value
            else -> invalid()
        }
        if (raw.keys != fields || integer("schemaVersion") != 1L ||
            string("packageName") != PACKAGE_NAME) invalid()
        val version = string("versionName")
        val build = integer("versionCode")
        val minSdk = integer("minSdk")
        val size = integer("sizeBytes")
        val sha = string("sha256")
        val certificate = string("certificateSha256")
        val url = string("apkUrl")
        if (version.length > 32 || !versionPattern.matches(version) ||
            build !in 1..Int.MAX_VALUE.toLong() || minSdk !in 24..Int.MAX_VALUE.toLong() ||
            size !in 1..MAX_APK_BYTES || !digestPattern.matches(sha) ||
            !digestPattern.matches(certificate) ||
            url != "$RELEASE_ROOT/download/v$version/Pushok-Flow-v$version.apk") invalid()
        return UpdateManifest(version, build, minSdk.toInt(), url, sha, size, certificate)
    }

    fun requireCompatible(manifest: UpdateManifest, installedPackage: String,
        installedSigners: Set<String>, sdk: Int) {
        if (installedPackage != PACKAGE_NAME || manifest.minSdk > sdk) {
            throw UpdateFailure("UPDATE_INCOMPATIBLE")
        }
        // A release uses one stable signer. Do not silently accept key rotation,
        // historical certificates or an extra signer on an update APK.
        if (installedSigners != setOf(manifest.certificateSha256)) {
            throw UpdateFailure("UPDATE_SIGNATURE_MISMATCH")
        }
    }

    fun requireNewer(manifest: UpdateManifest, installedBuild: Long) {
        if (manifest.versionCode <= installedBuild) throw UpdateFailure("UPDATE_NOT_READY")
    }

    fun manifestFields(manifest: UpdateManifest): Map<String, Any> = mapOf(
        "schemaVersion" to 1,
        "packageName" to PACKAGE_NAME,
        "versionName" to manifest.versionName,
        "versionCode" to manifest.versionCode,
        "minSdk" to manifest.minSdk,
        "apkUrl" to manifest.apkUrl,
        "sha256" to manifest.sha256,
        "sizeBytes" to manifest.sizeBytes,
        "certificateSha256" to manifest.certificateSha256,
    )

    fun candidateFileName(manifest: UpdateManifest): String =
        "verified-${manifest.versionCode}-${manifest.sha256.take(16)}.apk"

    fun requireCandidateFileName(name: String, manifest: UpdateManifest) {
        if (name != candidateFileName(manifest)) throw UpdateFailure("UPDATE_APK_INVALID")
    }

    fun allowedRequest(uri: URI, apkVersion: String?): Boolean {
        if (!safeUri(uri) || (apkVersion != null &&
                (apkVersion.length > 32 || !versionPattern.matches(apkVersion)))) return false
        return when (uri.host?.lowercase(Locale.ROOT)) {
            "github.com" -> {
                if (uri.rawQuery != null) return false
                if (apkVersion != null) {
                    uri.path == "$REPO_PATH/download/v$apkVersion/Pushok-Flow-v$apkVersion.apk"
                } else {
                    uri.path == "$REPO_PATH/latest/download/update.json" ||
                        Regex(Regex.escape(REPO_PATH) + "/download/v" +
                            versionPattern.pattern + "/update\\.json").matches(uri.path.orEmpty())
                }
            }
            "release-assets.githubusercontent.com" ->
                uri.rawPath?.startsWith("/github-production-release-asset/") == true
            "objects.githubusercontent.com" ->
                uri.rawPath?.startsWith("/github-production-release-asset-2e65be/") == true
            else -> false
        }
    }

    private fun safeUri(uri: URI): Boolean = uri.toString().length <= 8192 && uri.scheme == "https" &&
        uri.rawUserInfo == null && uri.rawFragment == null && uri.port in setOf(-1, 443) &&
        uri.normalize() == uri && uri.rawPath == uri.path

    fun sha256(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    fun hex(bytes: ByteArray): String = bytes.joinToString("") {
        (it.toInt() and 0xff).toString(16).padStart(2, '0')
    }
}
