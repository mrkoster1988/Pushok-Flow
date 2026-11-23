package shop.pushok.flow

import java.net.URI
import java.io.File
import java.security.MessageDigest
import java.nio.charset.StandardCharsets
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Collections
import java.util.Locale
import java.util.TimeZone

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

internal data class PublishedUpdateApk(
    val abi: String?,
    val apkUrl: String,
    val sha256: String,
    val sizeBytes: Long,
)

internal data class PublishedUpdateRelease(
    val id: Long,
    val versionName: String,
    val apks: List<PublishedUpdateApk> = emptyList(),
    val changes: List<String> = emptyList(),
    val publishedOn: String? = null,
)

/** Descriptive copy only. It never supplies an APK URL, signature or install decision. */
internal data class UpdateReleaseNotes(
    val versionName: String,
    val versionCode: Long,
    val apkSha256: String,
    val changes: List<String>,
    val publishedOn: String?,
) {
    fun metadata(): Map<String, Any?> = mapOf(
        "versionName" to versionName, "versionCode" to versionCode,
        "changes" to changes, "publishedOn" to publishedOn,
    )
    fun cacheFields(): Map<String, Any?> = metadata() + mapOf("schemaVersion" to 1, "apkSha256" to apkSha256)
}

/** Optional bounded release text, bound only after the normal manifest verification. */
internal object UpdateReleaseNotesPolicy {
    const val MAX_CHANGES = 8
    const val MAX_CHANGE_CHARS = 600
    private const val MAX_BODY_CHARS = 24_000
    private const val MAX_TOTAL_CHARS = 4_000
    private val fields = setOf("schemaVersion", "versionName", "versionCode", "apkSha256", "changes", "publishedOn")
    private val headings = setOf("изменения", "что нового", "changes", "what's new")
    private val markdownLink = Regex("\\[([^\\]\\r\\n]{1,256})]\\([^\\r\\n)]{1,2048}\\)")

    private fun validText(text: String): Boolean = text.isNotBlank() && text.length <= MAX_CHANGE_CHARS &&
        text.none { it.code < 32 || it.code == 127 || it.code in 0x202A..0x202E || it.code in 0x2066..0x2069 } &&
        String(text.toByteArray(StandardCharsets.UTF_8), StandardCharsets.UTF_8) == text

    private fun clean(text: String): String = markdownLink.replace(text) { it.groupValues[1] }
        .replace("**", "").replace("__", "").replace("`", "").replace(Regex("[ \\t]+"), " ").trim()

    /** Only the public human-written changes section is shown; footer/build instructions stay out. */
    fun changes(raw: Any?): List<String> {
        val body = raw as? String ?: return emptyList()
        if (body.length > MAX_BODY_CHARS) return emptyList()
        var inside = false
        var fence: String? = null
        val result = mutableListOf<String>()
        for (line in body.lineSequence()) {
            val trimmed = line.trim()
            val openFence = fence
            if (openFence != null) {
                if (trimmed.startsWith(openFence) && trimmed.drop(openFence.length).all { it == openFence[0] || it.isWhitespace() }) fence = null
                continue
            }
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                if (inside) break
                fence = trimmed.takeWhile { it == trimmed[0] }
                continue
            }
            if (trimmed.startsWith("#")) {
                if (inside) break
                if (trimmed.startsWith("## ") && trimmed.drop(3).trim().lowercase(Locale.ROOT) in headings) inside = true
                continue
            }
            if (!inside || trimmed.isEmpty()) continue
            if (trimmed.startsWith("- ") || trimmed.startsWith("* ")) {
                result.add(clean(trimmed.drop(2)))
            } else if (line.firstOrNull()?.isWhitespace() == true && result.isNotEmpty()) {
                result[result.lastIndex] = clean(result.last() + " " + trimmed)
            } else {
                // Stop at prose/code, never accidentally append another section as a change.
                break
            }
            if (result.size > MAX_CHANGES || result.any { !validText(it) } ||
                result.sumOf { it.length } > MAX_TOTAL_CHARS) return emptyList()
        }
        return Collections.unmodifiableList(ArrayList(result))
    }

    fun date(value: Any?): String? {
        val text = value as? String ?: return null
        if (!Regex("[1-9][0-9]{3}-[0-9]{2}-[0-9]{2}").matches(text)) return null
        val parser = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).apply {
            isLenient = false
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val position = ParsePosition(0)
        return if (parser.parse(text, position) != null && position.index == text.length) text else null
    }

    fun verified(release: PublishedUpdateRelease, manifest: UpdateManifest): UpdateReleaseNotes? {
        if (release.versionName != manifest.versionName || release.changes.isEmpty() ||
            release.changes.size > MAX_CHANGES || release.changes.any { !validText(it) } ||
            release.changes.sumOf { it.length } > MAX_TOTAL_CHARS) return null
        return UpdateReleaseNotes(manifest.versionName, manifest.versionCode, manifest.sha256,
            Collections.unmodifiableList(ArrayList(release.changes)), date(release.publishedOn))
    }

    fun restore(raw: Map<String, Any?>, manifest: UpdateManifest): UpdateReleaseNotes? {
        val schema = (raw["schemaVersion"] as? Int)?.toLong() ?: raw["schemaVersion"] as? Long
        val code = (raw["versionCode"] as? Int)?.toLong() ?: raw["versionCode"] as? Long
        if (raw.keys != fields || schema != 1L || code != manifest.versionCode ||
            raw["versionName"] != manifest.versionName || raw["apkSha256"] != manifest.sha256) return null
        val changes = raw["changes"] as? List<*> ?: return null
        if (changes.isEmpty() || changes.size > MAX_CHANGES || changes.any { it !is String || !validText(it) }) return null
        val strings = changes.map { it as String }
        if (strings.sumOf { it.length } > MAX_TOTAL_CHARS) return null
        val published = raw["publishedOn"]
        if (published != null && date(published) == null) return null
        return UpdateReleaseNotes(manifest.versionName, manifest.versionCode, manifest.sha256,
            Collections.unmodifiableList(ArrayList(strings)), published as? String)
    }

    fun visible(notes: UpdateReleaseNotes?, manifest: UpdateManifest?, installedVersion: String,
        installedBuild: Long): UpdateReleaseNotes? = notes?.takeIf {
        if (manifest != null) it.versionName == manifest.versionName && it.versionCode == manifest.versionCode &&
            it.apkSha256 == manifest.sha256
        else it.versionName == installedVersion && it.versionCode == installedBuild
    }
}

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
    const val MAX_RELEASE_ASSETS = 64
    const val MAX_ARCHIVE_ENTRIES = 10000
    const val MAX_APK_BYTES = 200L * 1024 * 1024
    private const val FIRST_ABI_BUILD = 40L
    private val apkAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
    private val nativeLibraries = setOf("libflutter.so", "libapp.so", "libgojni.so",
        "libwg-go.so", "libwg.so", "libwg-quick.so")
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
        val apks = if (raw.containsKey("assets")) releaseApks(raw["assets"], version) else emptyList()
        val changes = UpdateReleaseNotesPolicy.changes(raw["body"])
        return PublishedUpdateRelease(id, version, apks, changes,
            if (changes.isEmpty()) null else UpdateReleaseNotesPolicy.date(published.take(10)))
    }

    private fun apkUrl(version: String, abi: String? = null): String =
        "$RELEASE_ROOT/download/v$version/Pushok-Flow-v$version${abi?.let { "-$it" }.orEmpty()}.apk"

    /** Missing ABI assets means a legacy release. A partially present or ambiguous set is not a fallback. */
    private fun releaseApks(value: Any?, version: String): List<PublishedUpdateApk> {
        fun invalid(): Nothing = throw UpdateFailure("UPDATE_METADATA_INVALID")
        val assets = value as? List<*> ?: invalid()
        if (assets.size > MAX_RELEASE_ASSETS) invalid()
        val byName = mutableMapOf<String, Map<*, *>>()
        for (item in assets) {
            val asset = item as? Map<*, *> ?: invalid()
            val name = asset["name"] as? String ?: invalid()
            if (name.length !in 1..255 || byName.put(name, asset) != null) invalid()
        }
        val names = apkAbis.associateWith { apkUrl(version, it).substringAfterLast('/') }
        if (names.values.none { byName.containsKey(it) }) return emptyList()
        return (listOf<String?>(null) + apkAbis).map { abi ->
            val url = apkUrl(version, abi)
            val asset = byName[url.substringAfterLast('/')] ?: invalid()
            val size = when (val rawSize = asset["size"]) {
                is Int -> rawSize.toLong()
                is Long -> rawSize
                else -> invalid()
            }
            val digest = asset["digest"] as? String ?: invalid()
            if (asset["state"] != "uploaded" || asset["browser_download_url"] != url ||
                size !in 1..MAX_APK_BYTES || !digest.startsWith("sha256:") ||
                !digestPattern.matches(digest.removePrefix("sha256:"))) invalid()
            PublishedUpdateApk(abi, url, digest.removePrefix("sha256:"), size)
        }
    }

    /** Select a standalone APK for the next installation, not for the current process's bitness. */
    fun selectManifest(universal: UpdateManifest, release: PublishedUpdateRelease,
        supportedAbis: List<String>, known: List<UpdateManifest> = emptyList()): UpdateManifest {
        if (universal.versionName != release.versionName) throw UpdateFailure("UPDATE_METADATA_STALE")
        if (universal.apkUrl != apkUrl(universal.versionName)) throw UpdateFailure("UPDATE_METADATA_INVALID")
        val alternatives = mutableListOf(universal)
        if (release.apks.isNotEmpty()) {
            if (universal.versionCode < FIRST_ABI_BUILD) throw UpdateFailure("UPDATE_METADATA_INVALID")
            val base = release.apks.singleOrNull { it.abi == null }
                ?: throw UpdateFailure("UPDATE_METADATA_INVALID")
            if (base.apkUrl != universal.apkUrl || base.sha256 != universal.sha256 ||
                base.sizeBytes != universal.sizeBytes) throw UpdateFailure("UPDATE_METADATA_STALE")
            val variants = release.apks.filter { it.abi != null }
            if (variants.size != apkAbis.size || variants.map { it.abi }.toSet() != apkAbis.toSet()) {
                throw UpdateFailure("UPDATE_METADATA_INVALID")
            }
            for (asset in variants) {
                if (asset.abi in supportedAbis) alternatives.add(universal.copy(apkUrl = asset.apkUrl,
                    sha256 = asset.sha256, sizeBytes = asset.sizeBytes))
            }
        }
        // Keep an already discovered or downloaded exact payload. Switching variants for the same
        // build must not look like an allowed mutation of its hash or discard a verified cache.
        val retained = known.filter {
            it.versionCode == universal.versionCode || it.versionName == universal.versionName
        }
        if (retained.any { it !in alternatives } || retained.distinct().size > 1) {
            throw UpdateFailure("UPDATE_METADATA_STALE")
        }
        retained.firstOrNull()?.let { return it }
        for (abi in supportedAbis.distinct()) {
            alternatives.firstOrNull { it.apkUrl == apkUrl(universal.versionName, abi) }?.let { return it }
        }
        return universal
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

    fun manifest(raw: Map<String, Any?>): UpdateManifest = parseManifest(raw, allowVariant = false)

    /** Private persisted metadata uses the same nine fields; remote update.json stays universal-only. */
    fun cachedManifest(raw: Map<String, Any?>, supportedAbis: List<String>): UpdateManifest =
        parseManifest(raw, allowVariant = true).also { requireDeviceCompatible(it, supportedAbis) }

    private fun parseManifest(raw: Map<String, Any?>, allowVariant: Boolean): UpdateManifest {
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
            (url != apkUrl(version) && !(allowVariant && build >= FIRST_ABI_BUILD &&
                apkAbis.any { url == apkUrl(version, it) }))) invalid()
        return UpdateManifest(version, build, minSdk.toInt(), url, sha, size, certificate)
    }

    fun apkAbi(manifest: UpdateManifest): String? {
        if (manifest.apkUrl == apkUrl(manifest.versionName)) return null
        return apkAbis.firstOrNull { manifest.versionCode >= FIRST_ABI_BUILD &&
            manifest.apkUrl == apkUrl(manifest.versionName, it) }
            ?: throw UpdateFailure("UPDATE_METADATA_INVALID")
    }

    fun requireDeviceCompatible(manifest: UpdateManifest, supportedAbis: List<String>) {
        val abi = apkAbi(manifest)
        if (abi != null && abi !in supportedAbis) throw UpdateFailure("UPDATE_INCOMPATIBLE")
    }

    /** ZIP structure is checked in addition to the unchanged signed package/version/hash gates. */
    fun requireArchiveAbi(manifest: UpdateManifest, entries: Sequence<Pair<String, Long>>) {
        val abi = apkAbi(manifest) ?: return
        fun invalid(): Nothing = throw UpdateFailure("UPDATE_APK_INVALID")
        val names = mutableSetOf<String>()
        val libraries = mutableSetOf<String>()
        var count = 0
        for ((name, size) in entries) {
            if (++count > MAX_ARCHIVE_ENTRIES || !names.add(name)) invalid()
            if (name.startsWith("lib/") && name.endsWith(".so")) {
                val parts = name.split('/')
                if (parts.size != 3 || parts[1] != abi || parts[2].isEmpty() || size <= 0) invalid()
                libraries.add(parts[2])
            }
        }
        if (!libraries.containsAll(nativeLibraries)) invalid()
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

    fun allowedApkRequest(uri: URI, manifest: UpdateManifest): Boolean {
        if (!safeUri(uri) || !versionPattern.matches(manifest.versionName)) return false
        try { apkAbi(manifest) } catch (_: UpdateFailure) { return false }
        return if (uri.host?.lowercase(Locale.ROOT) == "github.com") {
            uri.rawQuery == null && uri.path == URI(manifest.apkUrl).path
        } else allowedRequest(uri, manifest.versionName)
    }

    private fun safeUri(uri: URI): Boolean = uri.toString().length <= 8192 && uri.scheme == "https" &&
        uri.rawUserInfo == null && uri.rawFragment == null && uri.port in setOf(-1, 443) &&
        uri.normalize() == uri && uri.rawPath == uri.path

    fun sha256(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    fun hex(bytes: ByteArray): String = bytes.joinToString("") {
        (it.toInt() and 0xff).toString(16).padStart(2, '0')
    }
}
