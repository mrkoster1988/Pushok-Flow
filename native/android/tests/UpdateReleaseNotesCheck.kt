package shop.pushok.flow

private const val NOTES_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private const val NOTES_CERT = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

private fun notesManifest(version: String = "0.48.0", code: Long = 48) = UpdateManifest(
    version, code, 24, "${UpdatePolicy.RELEASE_ROOT}/download/v$version/Pushok-Flow-v$version.apk",
    NOTES_SHA, 12_345L, NOTES_CERT,
)

private fun notesRelease(body: Any?) = UpdatePolicy.publishedRelease(mapOf(
    "id" to 123L, "tag_name" to "v0.48.0", "draft" to false, "prerelease" to false,
    "published_at" to "2026-11-23T05:00:00Z", "body" to body,
))

fun main() {
    val manifest = notesManifest()
    val release = notesRelease("""
        # Pushok Flow

        ## Изменения
        - **История обновлений** доступна без интернета.
          Описание `новой версии` рядом с кнопкой загрузки.
        - Открытие [кабинета](https://example.invalid/never-open-this) и QR 📷.

        ## Проверка выпуска
        - This footer is not an application change.
    """.trimIndent())
    check(release.changes == listOf(
        "История обновлений доступна без интернета. Описание новой версии рядом с кнопкой загрузки.",
        "Открытие кабинета и QR 📷.",
    ))
    check(release.publishedOn == "2026-11-23")
    val notes = UpdateReleaseNotesPolicy.verified(release, manifest)!!
    check(notes.metadata().keys == setOf("versionName", "versionCode", "changes", "publishedOn"))
    check(!notes.metadata().toString().contains("example.invalid"))
    check(UpdatePolicy.manifestUrl(release) == "${UpdatePolicy.RELEASE_ROOT}/download/v0.48.0/update.json")
    check(UpdateCheckSession(UpdateState("idle"), 47).complete(release, manifest, "0.47.0", 10L).manifest == manifest)

    val fenced = notesRelease("```text\n## Изменения\n- Not a real change.\n```\n## Что нового\n* Настоящее изменение.\n")
    check(fenced.changes == listOf("Настоящее изменение."))
    check(notesRelease("## Changes\n- First\n~~~\n- Hidden code\n~~~").changes == listOf("First"))
    check(notesRelease("## Изменения\n- Одно\n\nОбычный текст\n- Не продолжение").changes == listOf("Одно"))

    // Optional copy never rejects an otherwise valid update or changes its install metadata.
    for (bad in listOf<Any?>(null, 123, listOf("not text"), "Unstructured description", "x".repeat(24_001),
        "## Изменения\n- " + "x".repeat(601), "## Изменения\n- bad\u0000value",
        "## Изменения\n- bidi\u202Evalue", "## Изменения\n- isolate\u2066value",
        "## Изменения\n- broken\uD800value", "## Изменения\n" + (1..9).joinToString("\n") { "- item $it" },
        "## Изменения\n" + (1..8).joinToString("\n") { "- " + "x".repeat(550) })) {
        val badRelease = notesRelease(bad)
        check(badRelease.changes.isEmpty())
        check(UpdateReleaseNotesPolicy.verified(badRelease, manifest) == null)
        check(UpdateCheckSession(UpdateState("idle"), 47).complete(badRelease, manifest, "0.47.0", 11L).manifest == manifest)
    }
    check(UpdateReleaseNotesPolicy.verified(release, notesManifest("0.49.0", 49)) == null)

    // Restored notes belong to one exact verified payload, even when an older APK is retained.
    val cache = notes.cacheFields()
    check(UpdateReleaseNotesPolicy.restore(cache, manifest) == notes)
    check(UpdateReleaseNotesPolicy.restore(cache + ("versionCode" to 48), manifest) == notes)
    for (changed in listOf(
        cache + ("schemaVersion" to 2), cache + ("versionCode" to 48.0),
        cache + ("versionName" to "0.49.0"), cache + ("versionCode" to 49),
        cache + ("apkSha256" to NOTES_CERT), cache + ("unexpected" to true), cache - "publishedOn",
        cache + ("changes" to emptyList<String>()), cache + ("changes" to listOf(123)),
        cache + ("changes" to listOf("bad\nline")), cache + ("publishedOn" to "2026-02-30"),
    )) check(UpdateReleaseNotesPolicy.restore(changed, manifest) == null)
    check(UpdateReleaseNotesPolicy.restore(cache, manifest.copy(sha256 = NOTES_CERT)) == null)
    check(UpdateReleaseNotesPolicy.restore(cache + ("publishedOn" to null), manifest)?.publishedOn == null)
    check(UpdateReleaseNotesPolicy.date("2024-02-29") == "2024-02-29")
    check(UpdateReleaseNotesPolicy.date("2025-02-29") == null)
    check(UpdateReleaseNotesPolicy.date("2026-11-23 trailing") == null)

    val mutable = mutableListOf("Сохранённое описание")
    val snapshot = UpdateReleaseNotesPolicy.restore(cache + ("changes" to mutable), manifest)!!
    mutable.clear()
    check(snapshot.changes == listOf("Сохранённое описание"))
    try { (snapshot.changes as MutableList<String>).clear(); error("Mutable cached changes") }
    catch (_: UnsupportedOperationException) {}

    check(UpdateReleaseNotesPolicy.visible(notes, manifest, "0.47.0", 47) == notes)
    check(UpdateReleaseNotesPolicy.visible(notes, null, "0.48.0", 48) == notes)
    check(UpdateReleaseNotesPolicy.visible(notes, null, "0.47.0", 47) == null)
    check(UpdateReleaseNotesPolicy.visible(notes, notesManifest("0.49.0", 49), "0.48.0", 48) == null)
    check(UpdateReleaseNotesPolicy.visible(notes, manifest.copy(sha256 = NOTES_CERT), "0.48.0", 48) == null)
    check(UpdateReleaseNotesPolicy.visible(null, manifest, "0.47.0", 47) == null)
    println("Update release notes: bounded text, verified payload binding, offline cache and stale-version checks passed")
}
