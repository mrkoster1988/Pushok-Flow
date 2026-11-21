package shop.pushok.flow

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Intent
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import com.wireguard.config.Config
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.Closeable
import java.lang.ref.WeakReference
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Imports one explicitly chosen document into an already-protected editor draft. */
class WireGuardProfileImport(
    private val activity: Activity,
    private val isProtected: () -> Boolean,
) {
    companion object {
        private const val FIRST_REQUEST_CODE = 0x5000
        private const val LAST_REQUEST_CODE = 0x7FFF
        private const val READ_TIMEOUT_MS = 20_000L
        // Never reuse a code within this process: a cancelled old picker cannot complete
        // a newer request, including after Activity replacement. Exhaustion fails closed.
        private val nextCode = AtomicInteger(FIRST_REQUEST_CODE)
        private val reading = AtomicBoolean(false)
        private val io = Executors.newSingleThreadExecutor { task ->
            Thread(task, "pushok-profile-import").apply { isDaemon = true }
        }
        private val cleanup = Executors.newSingleThreadExecutor { task ->
            Thread(task, "pushok-profile-import-cancel").apply { isDaemon = true }
        }
    }

    private class Request(val code: Int, var result: MethodChannel.Result?) {
        val cancelled = AtomicBoolean(false)
        val signal = CancellationSignal()
        var timeout: Runnable? = null
        var readStarted = false
        private val resources = mutableListOf<Closeable>()

        fun attach(resource: Closeable): Boolean = synchronized(resources) {
            if (cancelled.get()) {
                try { resource.close() } catch (_: Exception) { }
                false
            } else {
                resources.add(resource)
                true
            }
        }

        fun closeResources() {
            val open = synchronized(resources) {
                resources.toList().also { resources.clear() }
            }
            // Closing the stream also wakes ordinary blocking pipe reads. Provider open
            // cancellation and close run away from the platform thread.
            open.asReversed().forEach { try { it.close() } catch (_: Exception) { } }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val resolver = activity.applicationContext.contentResolver
    private var pending: Request? = null
    private var disposed = false

    fun open(result: MethodChannel.Result) {
        if (disposed || activity.isDestroyed || activity.isFinishing || !isProtected()) {
            error(result, "PROFILE_IMPORT_UNAVAILABLE")
            return
        }
        if (pending != null || reading.get()) {
            error(result, "PROFILE_IMPORT_BUSY")
            return
        }
        val code = nextCode.getAndUpdate { if (it <= LAST_REQUEST_CODE) it + 1 else it }
        if (code !in FIRST_REQUEST_CODE..LAST_REQUEST_CODE) {
            error(result, "PROFILE_IMPORT_UNAVAILABLE")
            return
        }
        val request = Request(code, result)
        pending = request
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // .conf has inconsistent MIME types across Android document providers.
            // The bounded reader and WireGuard parser decide whether content is valid.
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
        }
        try {
            activity.startActivityForResult(intent, code)
        } catch (_: ActivityNotFoundException) {
            finish(request, code = "PROFILE_IMPORT_UNAVAILABLE")
        } catch (_: Exception) {
            finish(request, code = "PROFILE_IMPORT_FAILED")
        }
    }

    /** Returns true for this importer's request-code range, including stale results. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in FIRST_REQUEST_CODE..LAST_REQUEST_CODE) return false
        val request = pending ?: return true
        if (request.code != requestCode) return true
        if (request.readStarted) return true
        if (resultCode != Activity.RESULT_OK) {
            finish(request)
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT ||
            data?.clipData?.itemCount?.let { it > 1 } == true) {
            finish(request, code = "PROFILE_IMPORT_INVALID")
            return true
        }
        if (!isProtected() || disposed) {
            finish(request, code = "PROFILE_IMPORT_INTERRUPTED")
            return true
        }
        if (!reading.compareAndSet(false, true)) {
            finish(request, code = "PROFILE_IMPORT_BUSY")
            return true
        }
        request.readStarted = true
        request.timeout = Runnable {
            if (pending === request) {
                finish(request, code = "PROFILE_IMPORT_FAILED")
                stopRead(request)
            }
        }.also { handler.postDelayed(it, READ_TIMEOUT_MS) }
        val owner = WeakReference(this)
        val documentResolver = resolver
        val platformHandler = handler
        io.execute {
            var config: String? = null
            var failure: String? = null
            try {
                if (request.cancelled.get()) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
                val descriptor = documentResolver.openAssetFileDescriptor(uri, "r", request.signal)
                    ?: throw ProfileImportReader.Failure("PROFILE_IMPORT_FAILED")
                if (!request.attach(descriptor)) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
                val input = descriptor.createInputStream()
                if (!request.attach(input)) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
                val draft = ProfileImportReader.read(input) { request.cancelled.get() }
                // Parse before crossing the channel. The editor still requires explicit Save.
                // No filename, URI, raw parser error, or parsed peer/key object is returned.
                val parsed = Config.parse(ByteArrayInputStream(draft.toByteArray(StandardCharsets.UTF_8)))
                if (parsed.peers.isEmpty()) throw ProfileImportReader.Failure("PROFILE_IMPORT_INVALID")
                if (!request.cancelled.get()) config = draft
            } catch (error: ProfileImportReader.Failure) {
                failure = error.code
            } catch (_: com.wireguard.config.BadConfigException) {
                failure = "PROFILE_IMPORT_INVALID"
            } catch (_: Exception) {
                failure = "PROFILE_IMPORT_FAILED"
            } finally {
                request.closeResources()
                reading.set(false)
            }
            val value = config
            val code = failure
            platformHandler.post {
                val current = owner.get() ?: return@post
                if (request.cancelled.get() || current.pending !== request) return@post
                if (current.disposed || !current.isProtected()) {
                    current.finish(request, code = "PROFILE_IMPORT_INTERRUPTED")
                } else {
                    current.finish(request, value, code)
                }
            }
        }
        return true
    }

    /** Called only for an editor-owned outstanding import. */
    fun cancel() {
        val request = pending ?: return
        finish(request)
        stopRead(request)
    }

    fun dispose() {
        disposed = true
        val request = pending ?: return
        finish(request, code = "PROFILE_IMPORT_INTERRUPTED")
        stopRead(request)
    }

    private fun finish(request: Request, value: String? = null, code: String? = null) {
        if (pending !== request) return
        pending = null
        request.timeout?.let { handler.removeCallbacks(it) }
        request.timeout = null
        val result = request.result ?: return
        request.result = null
        if (code == null) result.success(value) else error(result, code)
    }

    private fun stopRead(request: Request) {
        request.cancelled.set(true)
        if (request.readStarted) cleanup.execute {
            request.closeResources()
            try { request.signal.cancel() } catch (_: Exception) { }
        }
    }

    private fun error(result: MethodChannel.Result, code: String) {
        val message = when (code) {
            "PROFILE_IMPORT_BUSY" -> "Импорт профиля уже выполняется"
            "PROFILE_IMPORT_TOO_LARGE" -> "Файл профиля больше 65 536 байт"
            "PROFILE_IMPORT_INVALID" -> "Нужен полный профиль WireGuard в формате UTF-8"
            "PROFILE_IMPORT_INTERRUPTED" -> "Импорт профиля прерван"
            "PROFILE_IMPORT_UNAVAILABLE" -> "Импорт профиля сейчас недоступен"
            else -> "Не удалось прочитать файл профиля"
        }
        result.error(code, message, null)
    }
}
