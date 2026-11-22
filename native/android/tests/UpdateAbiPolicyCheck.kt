package shop.pushok.flow

import java.net.URI
import java.nio.file.Files

private const val ABI_CERT = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
private const val BASE_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private val abis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
private val libraries = listOf("libflutter.so", "libapp.so", "libgojni.so",
    "libwg-go.so", "libwg.so", "libwg-quick.so")

private fun baseFields(version: String = "0.40.0", build: Long = 40): Map<String, Any?> = mapOf(
    "schemaVersion" to 1, "packageName" to UpdatePolicy.PACKAGE_NAME,
    "versionName" to version, "versionCode" to build, "minSdk" to 24,
    "apkUrl" to "${UpdatePolicy.RELEASE_ROOT}/download/v$version/Pushok-Flow-v$version.apk",
    "sha256" to BASE_SHA, "sizeBytes" to 66_000_000L, "certificateSha256" to ABI_CERT,
)

private fun assetFields(version: String = "0.40.0"): List<Map<String, Any?>> =
    (listOf<String?>(null) + abis).mapIndexed { index, abi ->
        val name = "Pushok-Flow-v$version${abi?.let { "-$it" }.orEmpty()}.apk"
        mapOf("name" to name, "state" to "uploaded",
            "browser_download_url" to "${UpdatePolicy.RELEASE_ROOT}/download/v$version/$name",
            "size" to if (abi == null) 66_000_000L else 23_000_000L + index,
            "digest" to "sha256:${if (abi == null) BASE_SHA else ('c'.code + index - 1).toChar().toString().repeat(64)}")
    }

private fun releaseFields(version: String = "0.40.0", assets: Any? = assetFields(version)): Map<String, Any?> = mapOf(
    "id" to 400L, "tag_name" to "v$version", "draft" to false, "prerelease" to false,
    "published_at" to "2026-11-22T00:00:00Z", "assets" to assets,
    "body" to "This text never controls a URL, a device ABI, or application copy.",
)

private fun rejectAbi(code: String, action: () -> Unit) {
    val actual = try { action(); null } catch (failure: UpdateFailure) { failure.code }
    check(actual == code) { "Expected $code; got $actual" }
}

private fun entries(abi: String) = libraries.map { "lib/$abi/$it" to 100L }

fun main() {
    val universal = UpdatePolicy.manifest(baseFields())
    val release = UpdatePolicy.publishedRelease(releaseFields())
    check(release.apks.size == 4)
    val selected = abis.associateWith { abi -> UpdatePolicy.selectManifest(universal, release, listOf(abi)) }
    for ((abi, manifest) in selected) {
        check(UpdatePolicy.apkAbi(manifest) == abi)
        check(manifest.versionCode == 40L && manifest.versionName == "0.40.0")
        check(manifest.minSdk == universal.minSdk && manifest.certificateSha256 == ABI_CERT)
        check(manifest.sizeBytes < universal.sizeBytes && manifest.sha256 != BASE_SHA)
        // Remote schema 1 update.json stays universal-only; selected private records round-trip.
        rejectAbi("UPDATE_METADATA_INVALID") { UpdatePolicy.manifest(UpdatePolicy.manifestFields(manifest)) }
        check(UpdatePolicy.cachedManifest(UpdatePolicy.manifestFields(manifest), listOf(abi)) == manifest)
        rejectAbi("UPDATE_INCOMPATIBLE") {
            UpdatePolicy.cachedManifest(UpdatePolicy.manifestFields(manifest), listOf("riscv64"))
        }
        UpdatePolicy.requireDeviceCompatible(manifest, listOf(abi))
        check(UpdatePolicy.allowedApkRequest(URI(manifest.apkUrl), manifest))
        check(UpdatePolicy.allowedApkRequest(URI(manifest.apkUrl.replace("github.com", "github.com:443")), manifest))
        check(!UpdatePolicy.allowedApkRequest(URI(universal.apkUrl), manifest))
        for (other in selected.values.filter { it != manifest }) {
            check(!UpdatePolicy.allowedApkRequest(URI(other.apkUrl), manifest))
        }
        for (bad in listOf(manifest.apkUrl + "?token=bad", manifest.apkUrl + "#fragment",
            manifest.apkUrl.replace("https:", "http:"), manifest.apkUrl.replace("github.com", "evil.example"),
            manifest.apkUrl.replace("v0.40.0/", "v0.39.0/"), manifest.apkUrl.replace("Pushok-Flow-v", "Pushok%2dFlow-v"))) {
            check(!UpdatePolicy.allowedApkRequest(URI(bad), manifest))
        }
        for (cdn in listOf("https://release-assets.githubusercontent.com/github-production-release-asset/1/file?sig=value",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/file?sig=value")) {
            check(UpdatePolicy.allowedApkRequest(URI(cdn), manifest))
        }
        UpdatePolicy.requireArchiveAbi(manifest, entries(abi).asSequence())
        UpdatePolicy.requireArchiveAbi(manifest, (entries(abi) + listOf("assets/example" to 0L,
            "lib/$abi/libfuture.so" to 100L)).asSequence())
        for (library in libraries) rejectAbi("UPDATE_APK_INVALID") {
            UpdatePolicy.requireArchiveAbi(manifest, entries(abi).filterNot { it.first.endsWith("/$library") }.asSequence())
        }
        for (size in listOf(0L, -1L)) rejectAbi("UPDATE_APK_INVALID") {
            UpdatePolicy.requireArchiveAbi(manifest, (entries(abi).drop(1) + (entries(abi).first().first to size)).asSequence())
        }
        for (otherAbi in abis.filter { it != abi } + "riscv64") rejectAbi("UPDATE_APK_INVALID") {
            UpdatePolicy.requireArchiveAbi(manifest, (entries(abi) + ("lib/$otherAbi/libapp.so" to 100L)).asSequence())
        }
        rejectAbi("UPDATE_APK_INVALID") {
            UpdatePolicy.requireArchiveAbi(manifest, (entries(abi) + entries(abi).first()).asSequence())
        }
        rejectAbi("UPDATE_APK_INVALID") {
            UpdatePolicy.requireArchiveAbi(manifest, (entries(abi) + listOf("assets/same" to 1L, "assets/same" to 2L)).asSequence())
        }
        rejectAbi("UPDATE_APK_INVALID") {
            UpdatePolicy.requireArchiveAbi(manifest, (entries(abi) + ("lib/$abi/extra/libbad.so" to 100L)).asSequence())
        }
    }
    check(UpdatePolicy.apkAbi(universal) == null)
    check(UpdatePolicy.cachedManifest(UpdatePolicy.manifestFields(universal), emptyList()) == universal)
    check(UpdatePolicy.selectManifest(universal, release, listOf("arm64-v8a", "armeabi-v7a")) == selected["arm64-v8a"])
    check(UpdatePolicy.selectManifest(universal, release, listOf("armeabi-v7a", "arm64-v8a")) == selected["armeabi-v7a"])
    check(UpdatePolicy.selectManifest(universal, release, listOf("riscv64", "x86_64", "arm64-v8a")) == selected["x86_64"])
    check(UpdatePolicy.selectManifest(universal, release, listOf("x86_64", "x86_64")) == selected["x86_64"])
    check(UpdatePolicy.selectManifest(universal, release, emptyList()) == universal)
    check(UpdatePolicy.selectManifest(universal, release, listOf("riscv64")) == universal)
    val reordered = UpdatePolicy.publishedRelease(releaseFields(assets = assetFields().reversed()))
    check(UpdatePolicy.selectManifest(universal, reordered, listOf("arm64-v8a")) == selected["arm64-v8a"])
    for (legacy in listOf(releaseFields() - "assets", releaseFields(assets = emptyList<Any>()),
        releaseFields(assets = assetFields().take(1)),
        releaseFields(assets = listOf(mapOf("name" to "readme.txt"))))) {
        check(UpdatePolicy.selectManifest(universal, UpdatePolicy.publishedRelease(legacy), abis) == universal)
    }

    val assetSet = assetFields()
    for (index in assetSet.indices) rejectAbi("UPDATE_METADATA_INVALID") {
        UpdatePolicy.publishedRelease(releaseFields(assets = assetSet.filterIndexed { i, _ -> i != index }))
    }
    rejectAbi("UPDATE_METADATA_INVALID") {
        UpdatePolicy.publishedRelease(releaseFields(assets = assetSet + assetSet[1]))
    }
    for (invalid in listOf(null, "assets", mapOf("name" to "one.apk"), listOf("not an object"),
        listOf(mapOf("name" to 123)), listOf(mapOf("name" to "")))) {
        rejectAbi("UPDATE_METADATA_INVALID") { UpdatePolicy.publishedRelease(releaseFields(assets = invalid)) }
    }
    rejectAbi("UPDATE_METADATA_INVALID") {
        UpdatePolicy.publishedRelease(releaseFields(assets = (0..UpdatePolicy.MAX_RELEASE_ASSETS).map { mapOf("name" to "$it.txt") }))
    }
    for ((field, invalid) in listOf(
        "state" to "new", "state" to null, "state" to true,
        "digest" to "sha256:${BASE_SHA.uppercase()}", "digest" to "sha512:$BASE_SHA", "digest" to "sha256:aa",
        "digest" to null, "digest" to 123,
        "size" to 0, "size" to -1, "size" to (UpdatePolicy.MAX_APK_BYTES + 1),
        "size" to 23_000_001.0, "size" to "23000001", "size" to true,
        "browser_download_url" to universal.apkUrl,
        "browser_download_url" to (assetSet[1]["browser_download_url"].toString() + "?download=1"),
        "browser_download_url" to assetSet[1]["browser_download_url"].toString().replace("github.com", "evil.example"),
        "name" to "Pushok-Flow-v0.40.0-ARM64-V8A.apk",
    )) rejectAbi("UPDATE_METADATA_INVALID") {
        UpdatePolicy.publishedRelease(releaseFields(assets = assetSet.mapIndexed { index, asset ->
            if (index == 1) asset + (field to invalid) else asset }))
    }
    for ((field, invalid) in listOf("sha256" to ABI_CERT, "sizeBytes" to 65_999_999L)) {
        val changed = UpdatePolicy.manifest(baseFields() + (field to invalid))
        rejectAbi("UPDATE_METADATA_STALE") { UpdatePolicy.selectManifest(changed, release, abis) }
    }
    rejectAbi("UPDATE_METADATA_INVALID") {
        val old = UpdatePolicy.manifest(baseFields("0.39.0", 39))
        UpdatePolicy.selectManifest(old, UpdatePolicy.publishedRelease(releaseFields("0.39.0")), abis)
    }
    rejectAbi("UPDATE_METADATA_INVALID") {
        UpdatePolicy.cachedManifest(baseFields("0.39.0", 39) +
            ("apkUrl" to "${UpdatePolicy.RELEASE_ROOT}/download/v0.39.0/Pushok-Flow-v0.39.0-arm64-v8a.apk"), abis)
    }
    val arm64 = selected.getValue("arm64-v8a")
    for (altered in listOf(arm64.copy(sha256 = BASE_SHA), arm64.copy(sizeBytes = 1L),
        arm64.copy(certificateSha256 = BASE_SHA), arm64.copy(minSdk = 25), arm64.copy(versionCode = 41L))) {
        rejectAbi("UPDATE_METADATA_STALE") { UpdatePolicy.selectManifest(universal, release, abis, listOf(altered)) }
    }
    check(UpdatePolicy.selectManifest(universal, release, abis, listOf(universal)) == universal)
    check(UpdatePolicy.selectManifest(universal, release, abis, listOf(arm64, arm64)) == arm64)
    rejectAbi("UPDATE_METADATA_STALE") { UpdatePolicy.selectManifest(universal, release, abis, listOf(universal, arm64)) }
    rejectAbi("UPDATE_METADATA_STALE") { UpdatePolicy.selectManifest(universal, release, listOf("armeabi-v7a"), listOf(arm64)) }
    rejectAbi("UPDATE_METADATA_STALE") {
        UpdatePolicy.selectManifest(universal, UpdatePolicy.publishedRelease(releaseFields() - "assets"), abis, listOf(arm64))
    }
    val older = UpdatePolicy.manifest(baseFields("0.39.0", 39))
    check(UpdatePolicy.selectManifest(universal, release, abis, listOf(older)) == arm64)
    UpdatePolicy.requireFresh(release, arm64, "0.39.0", 39, listOf(older))
    rejectAbi("UPDATE_METADATA_STALE") { UpdatePolicy.requireFresh(release, arm64, "0.39.0", 39, listOf(universal)) }
    val file = Files.createTempFile("pushok-abi-ready-", ".apk").toFile()
    try {
        for (payload in listOf(universal, arm64)) {
            val ready = UpdateState("ready", payload, file, payload.sizeBytes, payload.sizeBytes)
            val picked = UpdatePolicy.selectManifest(universal, release, abis, listOf(payload))
            val state = UpdateCheckSession(ready, 39).apply { recover(ready) }.complete(release, picked, "0.39.0", 2000L)
            check(state.phase == "ready" && state.apk === file && state.manifest == payload)
        }
    } finally { file.delete() }
    rejectAbi("UPDATE_APK_INVALID") {
        UpdatePolicy.requireArchiveAbi(arm64, (entries("arm64-v8a").asSequence() +
            (0 until UpdatePolicy.MAX_ARCHIVE_ENTRIES).asSequence().map { "assets/$it" to 0L }))
    }
    check(!UpdatePolicy.allowedApkRequest(URI(arm64.apkUrl), arm64.copy(apkUrl = arm64.apkUrl + "?bad=1")))
    check(!UpdatePolicy.allowedApkRequest(URI(arm64.apkUrl), arm64.copy(versionCode = 39L)))
    println("ABI update selection, strict release assets, retained payloads, archive contents and URL checks passed")
}
