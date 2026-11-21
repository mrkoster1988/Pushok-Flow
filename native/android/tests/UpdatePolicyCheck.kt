package shop.pushok.flow

import java.net.URI
import java.nio.file.Files

private const val CERT = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
private const val SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

private fun metadata(): Map<String, Any?> = mapOf(
    "schemaVersion" to 1,
    "packageName" to "shop.pushok.flow",
    "versionName" to "0.25.0",
    "versionCode" to 25,
    "minSdk" to 24,
    "apkUrl" to "https://github.com/mrkoster1988/Pushok-Flow/releases/download/v0.25.0/Pushok-Flow-v0.25.0.apk",
    "sha256" to SHA,
    "sizeBytes" to 12345L,
    "certificateSha256" to CERT,
)

private fun releaseMetadata(): Map<String, Any?> = mapOf(
    "id" to 123L,
    "tag_name" to "v0.25.0",
    "draft" to false,
    "prerelease" to false,
    "published_at" to "2026-11-22T00:00:00Z",
    // Unused release text is not a URL, source of app copy, or executable instruction.
    "body" to "arbitrary remote text",
)

private fun manifestVersion(version: String, build: Int): UpdateManifest = UpdatePolicy.manifest(
    metadata() + mapOf("versionName" to version, "versionCode" to build,
        "apkUrl" to "${UpdatePolicy.RELEASE_ROOT}/download/v$version/Pushok-Flow-v$version.apk"))

private fun rejected(code: String, action: () -> Unit) {
    val error = try { action(); null } catch (failure: UpdateFailure) { failure.code }
    check(error == code) { "Expected $code; got $error" }
}

fun main() {
    val raw = metadata()
    val manifest = UpdatePolicy.manifest(raw)
    check(manifest.versionCode == 25L && manifest.versionName == "0.25.0")
    check(manifest.sizeBytes == 12345L && manifest.minSdk == 24)
    check(UpdatePolicy.manifest(UpdatePolicy.manifestFields(manifest)) == manifest)
    val candidate = UpdatePolicy.candidateFileName(manifest)
    check(candidate == "verified-25-aaaaaaaaaaaaaaaa.apk")
    UpdatePolicy.requireCandidateFileName(candidate, manifest)
    for (unsafeName in listOf("../$candidate", "/cache/updates/$candidate", "subdir/$candidate",
        "pending-123.apk", candidate.replace("25", "24"), candidate.replace("aaaa", "bbbb"))) {
        rejected("UPDATE_APK_INVALID") { UpdatePolicy.requireCandidateFileName(unsafeName, manifest) }
    }
    check(UpdatePolicy.manifest(raw + ("sizeBytes" to UpdatePolicy.MAX_APK_BYTES)).sizeBytes == 209715200L)
    for ((field, value) in listOf(
        "schemaVersion" to 2, "schemaVersion" to 1.0,
        "packageName" to "shop.pushok.other", "versionName" to "0.25.0/../../bad",
        "versionName" to "0.25.0-beta", "versionName" to "00.25.0",
        "versionName" to "9".repeat(100), "versionCode" to 0,
        "versionCode" to -1, "versionCode" to 25.0, "versionCode" to "25",
        "versionCode" to (Int.MAX_VALUE.toLong() + 1), "minSdk" to 23,
        "minSdk" to (Int.MAX_VALUE.toLong() + 1), "minSdk" to 24.0,
        "sizeBytes" to 0, "sizeBytes" to -1, "sizeBytes" to "12345",
        "sizeBytes" to (UpdatePolicy.MAX_APK_BYTES + 1), "sizeBytes" to Long.MAX_VALUE,
        "sha256" to "a".repeat(63), "sha256" to SHA.uppercase(),
        "certificateSha256" to CERT.uppercase(), "certificateSha256" to null,
        "apkUrl" to "http://github.com/mrkoster1988/Pushok-Flow/releases/download/v0.25.0/Pushok-Flow-v0.25.0.apk",
        "apkUrl" to manifest.apkUrl.replace("mrkoster1988", "other"),
        "apkUrl" to manifest.apkUrl.replace("v0.25.0.apk", "v0.24.0.apk"),
        "apkUrl" to (manifest.apkUrl + "?redirect=elsewhere"),
    )) {
        rejected("UPDATE_METADATA_INVALID") { UpdatePolicy.manifest(raw + (field to value)) }
    }
    rejected("UPDATE_METADATA_INVALID") { UpdatePolicy.manifest(raw - "sha256") }
    rejected("UPDATE_METADATA_INVALID") { UpdatePolicy.manifest(raw + ("unexpected" to true)) }

    UpdatePolicy.requireCompatible(manifest, "shop.pushok.flow", setOf(CERT), 24)
    UpdatePolicy.requireNewer(manifest, 24)
    rejected("UPDATE_INCOMPATIBLE") { UpdatePolicy.requireCompatible(manifest, "another.package", setOf(CERT), 36) }
    rejected("UPDATE_INCOMPATIBLE") { UpdatePolicy.requireCompatible(manifest, "shop.pushok.flow", setOf(CERT), 23) }
    for (signers in listOf(emptySet(), setOf(SHA), setOf(CERT, SHA))) {
        rejected("UPDATE_SIGNATURE_MISMATCH") {
            UpdatePolicy.requireCompatible(manifest, "shop.pushok.flow", signers, 36)
        }
    }
    rejected("UPDATE_NOT_READY") { UpdatePolicy.requireNewer(manifest, 25) }
    rejected("UPDATE_NOT_READY") { UpdatePolicy.requireNewer(manifest, 26) }

    val release = UpdatePolicy.publishedRelease(releaseMetadata())
    check(release == PublishedUpdateRelease(123, "0.25.0"))
    check(UpdatePolicy.manifestUrl(release) == "${UpdatePolicy.RELEASE_ROOT}/download/v0.25.0/update.json")
    for ((field, value) in listOf(
        "id" to 0, "id" to -1, "id" to 123.0, "id" to "123",
        "tag_name" to "0.25.0", "tag_name" to "v0.25.0-beta", "tag_name" to "v00.25.0",
        "tag_name" to "v0.25.0/../../evil", "tag_name" to "v${"9".repeat(100)}.0.0",
        "tag_name" to null, "draft" to true, "draft" to "false", "draft" to null,
        "prerelease" to true, "prerelease" to 0, "prerelease" to null,
        "published_at" to null, "published_at" to "", "published_at" to 123,
        "published_at" to "2026-11-22", "published_at" to "2026-11-22T00:00:00Z trailing",
    )) rejected("UPDATE_METADATA_INVALID") { UpdatePolicy.publishedRelease(releaseMetadata() + (field to value)) }
    for (required in listOf("id", "tag_name", "draft", "prerelease", "published_at")) {
        rejected("UPDATE_METADATA_INVALID") { UpdatePolicy.publishedRelease(releaseMetadata() - required) }
    }

    UpdatePolicy.requireFresh(release, manifest, "0.24.0", 24)
    UpdatePolicy.requireFresh(release, manifest, "0.25.0", 25)
    rejected("UPDATE_METADATA_STALE") { UpdatePolicy.requireFresh(release, manifest, "0.26.0", 26) }
    rejected("UPDATE_METADATA_STALE") { UpdatePolicy.requireFresh(release, manifest, "0.26.0", 24) }
    rejected("UPDATE_METADATA_STALE") { UpdatePolicy.requireFresh(release, manifest, "0.24.0", 25) }
    rejected("UPDATE_METADATA_STALE") {
        UpdatePolicy.requireFresh(PublishedUpdateRelease(124, "0.26.0"), manifest, "0.24.0", 24)
    }
    val nextManifest = manifestVersion("0.26.0", 26)
    rejected("UPDATE_METADATA_STALE") {
        UpdatePolicy.requireFresh(release, manifest, "0.24.0", 24, listOf(nextManifest))
    }
    for (changed in listOf(manifest.copy(sha256 = CERT), manifest.copy(sizeBytes = 67890),
        manifest.copy(certificateSha256 = SHA), manifest.copy(minSdk = 25),
        manifestVersion("0.25.1", 25), manifest.copy(versionCode = 26))) {
        rejected("UPDATE_METADATA_STALE") {
            UpdatePolicy.requireFresh(PublishedUpdateRelease(125, changed.versionName), changed,
                "0.24.0", 24, listOf(manifest))
        }
    }
    // Version components are compared numerically without parsing them into an overflowing integer.
    val multiDigit = manifestVersion("0.10.0", 25)
    UpdatePolicy.requireFresh(PublishedUpdateRelease(126, "0.10.0"), multiDigit, "0.9.0", 24)
    val largeVersion = manifestVersion("99999999999999999999.1.0", 26)
    UpdatePolicy.requireFresh(PublishedUpdateRelease(127, largeVersion.versionName), largeVersion,
        "9999999999999999999.1.0", 24)

    check(UpdatePolicy.allowedReleaseRequest(URI(UpdatePolicy.LATEST_RELEASE_URL)))
    check(UpdatePolicy.allowedReleaseRequest(URI(UpdatePolicy.LATEST_RELEASE_URL.replace("api.github.com", "api.github.com:443"))))
    for (url in listOf(
        UpdatePolicy.LATEST_RELEASE_URL.replace("https:", "http:"),
        UpdatePolicy.LATEST_RELEASE_URL.replace("api.github.com", "api.github.com.evil.example"),
        UpdatePolicy.LATEST_RELEASE_URL.replace("api.github.com", "user@api.github.com"),
        UpdatePolicy.LATEST_RELEASE_URL.replace("api.github.com", "api.github.com:8443"),
        UpdatePolicy.LATEST_RELEASE_URL.replace("Pushok-Flow", "Other"),
        UpdatePolicy.LATEST_RELEASE_URL.replace("Pushok-Flow", "Pushok%2dFlow"),
        UpdatePolicy.LATEST_RELEASE_URL.replace("latest", "tags/v0.25.0"),
        UpdatePolicy.LATEST_RELEASE_URL + "?token=bad", UpdatePolicy.LATEST_RELEASE_URL + "#fragment",
        UpdatePolicy.LATEST_RELEASE_URL + "/../latest", UpdatePolicy.MANIFEST_URL,
        "https://release-assets.githubusercontent.com/github-production-release-asset/123/file",
    )) check(!UpdatePolicy.allowedReleaseRequest(URI(url))) { "Unexpected release discovery origin accepted" }
    check(!UpdatePolicy.allowedRequest(URI(UpdatePolicy.LATEST_RELEASE_URL), null))
    check(!UpdatePolicy.allowedRequest(URI(UpdatePolicy.LATEST_RELEASE_URL), manifest.versionName))
    check(UpdatePolicy.allowedManifestRequest(URI(UpdatePolicy.manifestUrl(release)), release))
    check(!UpdatePolicy.allowedManifestRequest(URI(UpdatePolicy.MANIFEST_URL), release))
    check(!UpdatePolicy.allowedManifestRequest(URI(UpdatePolicy.manifestUrl(release).replace("0.25.0", "0.24.0")), release))

    // Execute the same state coordinator used by AppUpdates, including its exact APK reference.
    val candidateFile = Files.createTempFile("pushok-update-check-", ".apk").toFile()
    try {
        candidateFile.writeBytes(byteArrayOf(1, 2, 3))
        val previous = UpdateState("ready", manifest, candidateFile, manifest.sizeBytes,
            manifest.sizeBytes, checkedAtMillis = 1000L)
        for (failure in listOf("UPDATE_NETWORK_ERROR", "UPDATE_RATE_LIMITED", "UPDATE_METADATA_STALE",
            "UPDATE_METADATA_INVALID", "UPDATE_UNAVAILABLE", "UPDATE_SIGNATURE_MISMATCH")) {
            val session = UpdateCheckSession(previous, 24)
            session.recover(previous)
            check(session.checking("release").checkStage == "release")
            check(session.checking("manifest").phase == "checking")
            val retained = session.failed(failure)
            check(retained.phase == "ready" && retained.apk === candidateFile)
            check(retained.manifest == manifest && retained.errorCode == failure)
            check(retained.checkedAtMillis == 1000L && retained.checkStage == null)
            check(candidateFile.readBytes().contentEquals(byteArrayOf(1, 2, 3)))
        }
        val same = UpdateCheckSession(previous, 24).apply { recover(previous) }
            .complete(release, manifest, "0.24.0", 2000L)
        check(same.phase == "ready" && same.apk === candidateFile && same.checkedAtMillis == 2000L)
        val newer = UpdateCheckSession(previous, 24).apply { recover(previous) }.complete(
            PublishedUpdateRelease(124, "0.26.0"), nextManifest, "0.24.0", 3000L)
        check(newer.phase == "available" && newer.manifest == nextManifest && newer.apk == null)
        check(newer.checkedAtMillis == 3000L)
        // A recreated Activity discovers the cached update before a stale network response.
        val recreated = UpdateCheckSession(UpdateState("idle"), 23)
        recreated.recover(previous)
        rejected("UPDATE_METADATA_STALE") {
            recreated.complete(PublishedUpdateRelease(122, "0.24.0"), manifestVersion("0.24.0", 24),
                "0.23.0", 4000L)
        }
        val afterStale = recreated.failed("UPDATE_METADATA_STALE")
        check(afterStale.phase == "ready" && afterStale.apk === candidateFile)
        check(afterStale.checkedAtMillis == null) // Recovering a file is not a network check.
        // An unavailable/corrupted file never remains installable just because it was ready before.
        val missing = UpdateCheckSession(previous, 24).apply { recover(null) }.failed("UPDATE_NETWORK_ERROR")
        check(missing.phase == "available" && missing.apk == null && missing.manifest == manifest)
        val conflicting = UpdateCheckSession(previous, 24).apply { recover(previous) }
        rejected("UPDATE_METADATA_STALE") {
            conflicting.complete(release, manifest.copy(sha256 = CERT), "0.24.0", 4000L)
        }
        check(conflicting.failed("UPDATE_METADATA_STALE").apk === candidateFile)
    } finally {
        candidateFile.delete()
    }
    val availableSession = UpdateCheckSession(UpdateState("available", nextManifest, checkedAtMillis = 2000L), 24)
    rejected("UPDATE_METADATA_STALE") { availableSession.complete(release, manifest, "0.24.0", 3000L) }
    check(availableSession.failed("UPDATE_METADATA_STALE").manifest == nextManifest)
    check(availableSession.failed("UPDATE_METADATA_STALE").phase == "available")
    check(availableSession.failed("UPDATE_METADATA_STALE").checkedAtMillis == 2000L)
    val olderReady = UpdateState("ready", manifest, java.io.File("verified-older.apk"),
        manifest.sizeBytes, manifest.sizeBytes)
    availableSession.recover(olderReady)
    rejected("UPDATE_METADATA_STALE") { availableSession.complete(release, manifest, "0.24.0", 3000L) }
    check(availableSession.failed("UPDATE_METADATA_STALE").manifest == nextManifest)
    check(availableSession.failed("UPDATE_METADATA_STALE").apk == null)
    val noHistory = UpdateCheckSession(UpdateState("idle"), 25)
    check(noHistory.failed("UPDATE_NETWORK_ERROR").phase == "error")
    check(noHistory.failed("UPDATE_NETWORK_ERROR").checkedAtMillis == null)
    check(noHistory.failed("UPDATE_UNAVAILABLE").phase == "unavailable")
    val current = noHistory.complete(release, manifest, "0.25.0", 5000L)
    check(current.phase == "current" && current.checkedAtMillis == 5000L && current.manifest == null)
    check(UpdateCheckSession(current, 25).failed("UPDATE_NETWORK_ERROR").phase == "error")
    check(UpdateCheckSession(current, 25).failed("UPDATE_NETWORK_ERROR").checkedAtMillis == 5000L)

    check(UpdatePolicy.allowedRequest(URI(UpdatePolicy.MANIFEST_URL), null))
    check(UpdatePolicy.allowedRequest(URI("${UpdatePolicy.RELEASE_ROOT}/download/v0.25.0/update.json"), null))
    check(UpdatePolicy.allowedRequest(URI(manifest.apkUrl), manifest.versionName))
    for (url in listOf(
        "https://release-assets.githubusercontent.com/github-production-release-asset/123/file?signature=token",
        "https://objects.githubusercontent.com/github-production-release-asset-2e65be/123/file?signature=token",
    )) {
        check(UpdatePolicy.allowedRequest(URI(url), null))
        check(UpdatePolicy.allowedRequest(URI(url), manifest.versionName))
    }
    for (url in listOf(
        "http://github.com/mrkoster1988/Pushok-Flow/releases/latest/download/update.json",
        "https://github.com.evil.example/mrkoster1988/Pushok-Flow/releases/latest/download/update.json",
        "https://github.com@evil.example/mrkoster1988/Pushok-Flow/releases/latest/download/update.json",
        "https://user@github.com/mrkoster1988/Pushok-Flow/releases/latest/download/update.json",
        "https://github.com:8443/mrkoster1988/Pushok-Flow/releases/latest/download/update.json",
        "https://github.com/mrkoster1988/Other/releases/latest/download/update.json",
        "https://github.com/mrkoster1988/Pushok-Flow/releases/latest/download/update.json?token=bad",
        "https://github.com/mrkoster1988/Pushok-Flow/releases/latest/download/update.json#fragment",
        "https://github.com/mrkoster1988/Pushok-Flow/releases/download/v0.25.0/../update.json",
        "https://github.com/mrkoster1988/Pushok-Flow/releases/download/v0%2e25%2e0/update.json",
        "https://release-assets.githubusercontent.com.evil.example/github-production-release-asset/1/file",
        "https://release-assets.githubusercontent.com/another-path/file",
        "https://release-assets.githubusercontent.com/github-production-release-asset/%2e%2e/file",
        "https://objects.githubusercontent.com/another-path/file",
        "https://example.com/github-production-release-asset/1/file",
        "file:///tmp/update.json",
    )) {
        check(!UpdatePolicy.allowedRequest(URI(url), null)) { "Unexpected metadata origin accepted" }
        check(!UpdatePolicy.allowedRequest(URI(url), manifest.versionName)) { "Unexpected APK origin accepted" }
    }
    check(!UpdatePolicy.allowedRequest(URI(manifest.apkUrl), null))
    check(!UpdatePolicy.allowedRequest(URI(UpdatePolicy.MANIFEST_URL), manifest.versionName))
    check(!UpdatePolicy.allowedRequest(URI(manifest.apkUrl.replace("0.25.0", "0.24.0")), manifest.versionName))
    check(!UpdatePolicy.allowedRequest(URI(manifest.apkUrl), "0.25.0/../../bad"))
    check(UpdatePolicy.sha256("abc".toByteArray()) ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    println("UpdatePolicy executable checks passed")
}
