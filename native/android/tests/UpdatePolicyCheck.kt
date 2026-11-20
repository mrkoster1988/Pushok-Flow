package shop.pushok.flow

import java.net.URI

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
