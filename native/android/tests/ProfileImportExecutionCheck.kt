package shop.pushok.flow

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentResolver
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Actual Android importer orchestration; only platform boundaries are small JVM adapters. */
private const val SUBSCRIPTION = "https://example.invalid/sub/synthetic"
private val mainThread = Thread.currentThread()

private class Reply : MethodChannel.Result {
    var calls = 0
    var value: Any? = null
    var code: String? = null
    var message: String? = null
    override fun success(value: Any?) { called(); this.value = value }
    override fun error(code: String, message: String?, details: Any?) {
        called(); this.code = code; this.message = message
        check(details == null)
    }
    override fun notImplemented() = error("Unexpected notImplemented")
    private fun called() {
        check(Thread.currentThread() === mainThread) { "Reply escaped the UI dispatcher" }
        check(++calls == 1) { "An import replied more than once" }
    }
    fun expectCode(expected: String) {
        check(calls == 1 && code == expected && value == null) {
            "Expected $expected, got calls=$calls code=$code"
        }
    }
    fun expectCancelled() = check(calls == 1 && code == null && value == null)
    fun expectSubscription() {
        check(calls == 1 && code == null)
        check(value == mapOf("kind" to "subscription", "url" to SUBSCRIPTION))
    }
}

private class Gate {
    private val entered = CountDownLatch(1)
    private val released = CountDownLatch(1)
    @Volatile var thread: String? = null
    fun block() {
        thread = Thread.currentThread().name
        entered.countDown()
        // An adversarial provider may ignore Thread.interrupt and CancellationSignal.
        while (released.count > 0) {
            try { released.await() } catch (_: InterruptedException) { }
        }
    }
    fun awaitEntry(label: String) = await(label) { entered.count == 0L }
    fun release() = released.countDown()
}

private class Provider(
    private val openGate: Gate? = null,
    private val readGate: Gate? = null,
    private val closeGate: Gate? = null,
    private val signalGate: Gate? = null,
    private val descriptorCloseGate: Gate? = null,
    private val openFailure: Boolean = false,
) {
    val opens = AtomicInteger()
    val reads = AtomicInteger()
    val streamCloses = AtomicInteger()
    val descriptorCloses = AtomicInteger()
    val signalCalls = AtomicInteger()
    @Volatile var signal: CancellationSignal? = null

    fun open(signal: CancellationSignal): AssetFileDescriptor {
        opens.incrementAndGet()
        this.signal = signal
        signal.onCancel = { signalCalls.incrementAndGet(); signalGate?.block() }
        openGate?.block()
        if (openFailure) error("Synthetic provider failure; never surface this text")
        return AssetFileDescriptor(input = {
            object : InputStream() {
                private val bytes = ByteArrayInputStream(SUBSCRIPTION.toByteArray())
                private val first = AtomicBoolean(true)
                override fun read(): Int {
                    if (first.getAndSet(false)) { reads.incrementAndGet(); readGate?.block() }
                    return bytes.read()
                }
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    if (first.getAndSet(false)) { reads.incrementAndGet(); readGate?.block() }
                    return bytes.read(buffer, offset, length)
                }
                override fun close() { streamCloses.incrementAndGet(); closeGate?.block() }
            }
        }, onClose = { descriptorCloses.incrementAndGet(); descriptorCloseGate?.block() })
    }
}

private class Harness(private val provider: Provider = Provider()) {
    val protected = AtomicBoolean(true)
    val activity = Activity(object : ContentResolver() {
        override fun openAssetFileDescriptor(uri: Uri, mode: String, signal: CancellationSignal): AssetFileDescriptor {
            check(mode == "r")
            check(Thread.currentThread().name.startsWith("pushok-profile-provider-"))
            return provider.open(signal)
        }
    })
    val importer = WireGuardProfileImport(activity) { protected.get() }
    fun open(source: WireGuardProfileImport.Source = WireGuardProfileImport.Source.FILE): Pair<Reply, Int?> {
        val reply = Reply()
        val before = activity.opened.size
        importer.open(reply, source)
        return reply to if (activity.opened.size > before) activity.opened.last().second else null
    }
    fun choose(code: Int, data: Intent = Intent().apply { this.data = Uri.parse("content://synthetic/profile") }) {
        check(importer.onActivityResult(code, Activity.RESULT_OK, data))
    }
    fun start(source: WireGuardProfileImport.Source = WireGuardProfileImport.Source.FILE): Pair<Reply, Int> {
        val (reply, nullableCode) = open(source)
        val code = checkNotNull(nullableCode) { "Expected a picker, got ${reply.code}" }
        if (source == WireGuardProfileImport.Source.CAMERA) {
            choose(code, Intent().putExtra(WireGuardQrActivity.EXTRA_TEXT, SUBSCRIPTION))
        } else choose(code)
        return reply to code
    }
}

private fun await(label: String, drain: Boolean = true, condition: () -> Boolean) {
    val end = System.nanoTime() + 5_000_000_000L
    while (!condition()) {
        if (drain) Handler.drain()
        check(System.nanoTime() < end) { "Timed out: $label" }
        Thread.sleep(2)
    }
    if (drain) Handler.drain()
}

private fun readyProviders() {
    // Synchronize test boundaries on the real pool's admission, without replacing it.
    await("both provider slots returned") {
        val one = ProfileImportWork.reserve(false) {}
        val two = ProfileImportWork.reserve(false) {}
        val ready = one != null && two != null
        one?.cancel(); two?.cancel()
        ready
    }
}

private fun healthy(source: WireGuardProfileImport.Source = WireGuardProfileImport.Source.FILE) {
    val harness = Harness()
    val (reply) = harness.start(source)
    await("healthy $source import") { reply.calls == 1 }
    reply.expectSubscription()
    harness.importer.dispose()
}

private fun reservationsAndPickerLifecycle() {
    val provider = Provider()
    val harness = Harness(provider)
    repeat(12) {
        val (reply, code) = harness.open()
        check(code != null)
        val (busy, busyCode) = harness.open(WireGuardProfileImport.Source.CAMERA)
        busy.expectCode("PROFILE_IMPORT_BUSY"); check(busyCode == null)
        check(harness.importer.onActivityResult(code, Activity.RESULT_CANCELED, null))
        reply.expectCancelled()
        harness.importer.cancel()
    }
    check(provider.opens.get() == 0)
    repeat(4) {
        harness.activity.openFailure = ActivityNotFoundException()
        val (reply, code) = harness.open()
        reply.expectCode("PROFILE_IMPORT_UNAVAILABLE"); check(code == null)
    }
    harness.activity.openFailure = null
    val (picker, pickerCode) = harness.open()
    Handler.advance(25_000) // The read deadline starts after choosing, not while browsing.
    check(picker.calls == 0)
    harness.choose(checkNotNull(pickerCode), Intent().apply { data = Uri.parse("https://example.invalid/profile") })
    picker.expectCode("PROFILE_IMPORT_INVALID")
    val (multiple, multiCode) = harness.open(WireGuardProfileImport.Source.QR_IMAGE)
    harness.choose(checkNotNull(multiCode), Intent().apply {
        data = Uri.parse("content://synthetic/photo"); clipData = ClipData(2)
    })
    multiple.expectCode("PROFILE_IMPORT_INVALID")
    val (disposed) = harness.open()
    harness.importer.dispose()
    disposed.expectCode("PROFILE_IMPORT_INTERRUPTED")
    readyProviders()
    healthy()
}

private fun cameraErrorsAndStalePicker() {
    val harness = Harness()
    val (old, oldCode) = harness.open(WireGuardProfileImport.Source.CAMERA)
    harness.importer.cancel(); old.expectCancelled()
    val (current, code) = harness.open(WireGuardProfileImport.Source.CAMERA)
    harness.choose(checkNotNull(oldCode), Intent().putExtra(WireGuardQrActivity.EXTRA_TEXT, SUBSCRIPTION))
    check(current.calls == 0)
    harness.choose(checkNotNull(code), Intent().putExtra(WireGuardQrActivity.EXTRA_ERROR, "PROFILE_QR_MULTIPLE"))
    current.expectCode("PROFILE_QR_MULTIPLE")
    val (unsafe, unsafeCode) = harness.open(WireGuardProfileImport.Source.CAMERA)
    harness.choose(checkNotNull(unsafeCode), Intent().putExtra(WireGuardQrActivity.EXTRA_ERROR, "secret-synthetic-error"))
    unsafe.expectCode("PROFILE_IMPORT_INVALID")
    check(!unsafe.message.orEmpty().contains("secret"))
    healthy(WireGuardProfileImport.Source.CAMERA)
    harness.importer.dispose()
}

private fun independentCancellationAndFullProviders() {
    val read = Gate(); val close = Gate(); val signal = Gate()
    val secondOpen = Gate(); val lateClose = Gate()
    val firstProvider = Provider(readGate = read, closeGate = close, signalGate = signal)
    val secondProvider = Provider(openGate = secondOpen, descriptorCloseGate = lateClose)
    val first = Harness(firstProvider); val second = Harness(secondProvider)
    try {
        val (cancelled, firstCode) = first.start()
        read.awaitEntry("first provider blocked in read")
        val before = System.nanoTime()
        first.importer.cancel()
        check(System.nanoTime() - before < 1_000_000_000L) { "Cancel waited for provider" }
        first.importer.cancel(); cancelled.expectCancelled()
        close.awaitEntry("resource close dispatched independently")
        signal.awaitEntry("signal cancellation dispatched independently")
        check(close.thread?.startsWith("pushok-profile-close-") == true)
        check(signal.thread?.startsWith("pushok-profile-signal-") == true)
        healthy() // A single stuck provider leaves one real provider worker available.

        read.release() // The provider worker must retain admission while close is blocked.
        val (timedOut, secondCode) = second.start(WireGuardProfileImport.Source.QR_IMAGE)
        secondOpen.awaitEntry("second provider blocked in open")
        Handler.advance(20_001)
        timedOut.expectCode("PROFILE_IMPORT_TIMEOUT")
        second.importer.cancel()
        await("second provider cancellation signal") { secondProvider.signalCalls.get() == 1 }
        val blocked = Harness()
        for (source in listOf(WireGuardProfileImport.Source.FILE, WireGuardProfileImport.Source.QR_IMAGE)) {
            val (reply, code) = blocked.open(source)
            reply.expectCode("PROFILE_IMPORT_SOURCE_BUSY"); check(code == null)
        }
        check(blocked.activity.opened.isEmpty())
        healthy(WireGuardProfileImport.Source.CAMERA)

        close.release() // A blocked CancellationSignal no longer holds up resource cleanup.
        await("first descriptor closed") { firstProvider.descriptorCloses.get() == 1 }
        val waiting = Harness()
        var reservation: Pair<Reply, Int?>? = null
        await("first provider slot reusable") {
            val attempt = waiting.open()
            if (attempt.second != null) { reservation = attempt; true }
            else { attempt.first.expectCode("PROFILE_IMPORT_SOURCE_BUSY"); false }
        }
        secondOpen.release()
        lateClose.awaitEntry("cancelled late descriptor closes on provider worker")
        check(lateClose.thread?.startsWith("pushok-profile-provider-") == true)
        check(secondProvider.reads.get() == 0)
        val (stillFull, stillFullCode) = Harness().open()
        stillFull.expectCode("PROFILE_IMPORT_SOURCE_BUSY"); check(stillFullCode == null)
        waiting.importer.cancel(); checkNotNull(reservation).first.expectCancelled()
        healthy()
        // Late callbacks from both cancelled requests cannot affect a new draft.
        first.choose(firstCode); second.choose(secondCode)
        check(cancelled.calls == 1 && timedOut.calls == 1)
    } finally {
        read.release(); close.release(); signal.release(); secondOpen.release(); lateClose.release()
        first.importer.dispose(); second.importer.dispose()
        readyProviders()
    }
    check(firstProvider.streamCloses.get() == 1 && firstProvider.descriptorCloses.get() == 1)
    check(secondProvider.descriptorCloses.get() == 1 && secondProvider.streamCloses.get() == 0)
    check(firstProvider.signalCalls.get() == 1 && secondProvider.signalCalls.get() == 1)
    healthy()
}

private fun completedReadStillRetainsHungClose() {
    val closeOne = Gate(); val closeTwo = Gate()
    val one = Harness(Provider(closeGate = closeOne)); val two = Harness(Provider(closeGate = closeTwo))
    try {
        val (replyOne) = one.start()
        val (replyTwo) = two.start(WireGuardProfileImport.Source.QR_IMAGE)
        closeOne.awaitEntry("first successful read blocked closing")
        closeTwo.awaitEntry("second successful read blocked closing")
        check(replyOne.calls == 0 && replyTwo.calls == 0)
        Handler.advance(20_001)
        replyOne.expectCode("PROFILE_IMPORT_TIMEOUT"); replyTwo.expectCode("PROFILE_IMPORT_TIMEOUT")
        val (busy, code) = Harness().open()
        busy.expectCode("PROFILE_IMPORT_SOURCE_BUSY"); check(code == null)
        healthy(WireGuardProfileImport.Source.CAMERA)
        closeOne.release(); closeTwo.release()
        readyProviders(); Handler.drain()
        check(replyOne.calls == 1 && replyTwo.calls == 1)
    } finally {
        closeOne.release(); closeTwo.release()
        one.importer.dispose(); two.importer.dispose()
        readyProviders()
    }
}

private fun elapsedDeadlineProtectionAndQueuedCancellation() {
    val open = Gate()
    val harness = Harness(Provider(openGate = open))
    try {
        val (reply) = harness.start()
        open.awaitEntry("provider before elapsed deadline")
        SystemClock.advanceSleep(20_001) // Handler uptime has not advanced.
        open.release()
        await("elapsed deadline wins over returned payload") { reply.calls == 1 }
        reply.expectCode("PROFILE_IMPORT_TIMEOUT")
    } finally { open.release(); harness.importer.dispose(); readyProviders() }

    val read = Gate()
    val protected = Harness(Provider(readGate = read))
    try {
        val (reply) = protected.start()
        read.awaitEntry("provider before editor lock")
        protected.protected.set(false)
        read.release()
        await("locked editor rejects completed draft") { reply.calls == 1 }
        reply.expectCode("PROFILE_IMPORT_INTERRUPTED")
    } finally { read.release(); protected.importer.dispose(); readyProviders() }

    // The worker has completed and posted a reply, but UI cancellation wins before delivery.
    val queued = Harness()
    val (old, oldCode) = queued.start()
    await("worker reply queued", drain = false) { Handler.hasPostedReply() }
    queued.importer.cancel(); old.expectCancelled()
    val (next, nextCode) = queued.start()
    queued.choose(oldCode)
    queued.choose(nextCode) // Duplicate picker delivery cannot start a second provider read.
    await("new draft survives stale queued reply") { next.calls == 1 }
    next.expectSubscription(); check(old.calls == 1)
    queued.importer.dispose()
    readyProviders()
    val failed = Harness(Provider(openFailure = true))
    val (failedReply) = failed.start()
    await("provider failure") { failedReply.calls == 1 }
    failedReply.expectCode("PROFILE_IMPORT_FAILED")
    check(!failedReply.message.orEmpty().contains("Synthetic"))
    failed.importer.dispose(); readyProviders(); healthy()
}

private fun boundedThreadCounts() {
    for ((prefix, limit) in mapOf("provider" to 2, "camera" to 1, "signal" to 2, "close" to 2)) {
        val count = Thread.getAllStackTraces().keys.count { it.isAlive && it.name.startsWith("pushok-profile-$prefix-") }
        check(count in 1..limit) { "$prefix created $count live workers; bound is $limit" }
    }
}

fun main() {
    reservationsAndPickerLifecycle()
    cameraErrorsAndStalePicker()
    independentCancellationAndFullProviders()
    completedReadStillRetainsHungClose()
    elapsedDeadlineProtectionAndQueuedCancellation()
    boundedThreadCounts()
    println("Profile import bounded provider/camera lanes, elapsed deadline, cancellation, cleanup and stale-result checks passed")
}
