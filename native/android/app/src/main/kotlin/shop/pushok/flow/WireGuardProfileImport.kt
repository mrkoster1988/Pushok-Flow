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

/** Imports a chosen file or offline QR code into an already-protected editor draft. */
class WireGuardProfileImport(
    private val activity: Activity,
    private val isProtected: () -> Boolean,
) {
    enum class Source { FILE, CAMERA, QR_IMAGE }

    companion object {
        internal val qrSessions = ProfileQrSession()
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

    private class Request(val code: Int, val source: Source, var result: MethodChannel.Result?) {
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

    fun open(result: MethodChannel.Result, source: Source = Source.FILE) {
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
        if (source == Source.CAMERA && !qrSessions.begin(code)) {
            error(result, "PROFILE_IMPORT_BUSY")
            return
        }
        val request = Request(code, source, result)
        pending = request
        val intent = if (source == Source.CAMERA) {
            Intent(activity, WireGuardQrActivity::class.java)
                .putExtra(WireGuardQrActivity.EXTRA_REQUEST_CODE, code)
        } else Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // .conf has inconsistent MIME types across Android document providers.
            // The bounded reader and protocol parser decide whether content is valid.
            type = if (source == Source.QR_IMAGE) "image/*" else "*/*"
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
        if (!isProtected() || disposed ||
            (request.source == Source.CAMERA && !qrSessions.isActive(request.code))) {
            finish(request, code = "PROFILE_IMPORT_INTERRUPTED")
            return true
        }
        var cameraText: String? = null
        val uri = try {
            if (request.source == Source.CAMERA) {
                val cameraError = data?.getStringExtra(WireGuardQrActivity.EXTRA_ERROR)
                if (cameraError != null) {
                    val safe = cameraError.takeIf { it in ProfileFormatFailure.SAFE_CODES ||
                        it in setOf("PROFILE_QR_CAMERA_DENIED", "PROFILE_QR_UNAVAILABLE") }
                        ?: "PROFILE_IMPORT_INVALID"
                    finish(request, code = safe)
                    return true
                }
                cameraText = data?.getStringExtra(WireGuardQrActivity.EXTRA_TEXT)
                null
            } else data?.data
        } catch (_: Exception) {
            finish(request, code = "PROFILE_IMPORT_INVALID")
            return true
        }
        if (resultCode != Activity.RESULT_OK) {
            finish(request)
            return true
        }
        if (request.source == Source.CAMERA) {
            if (cameraText == null || cameraText.length > ProfileImportReader.MAX_BYTES) {
                finish(request, code = "PROFILE_IMPORT_INVALID")
                return true
            }
        } else if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT ||
            data?.clipData?.itemCount?.let { it > 1 } == true) {
            finish(request, code = "PROFILE_IMPORT_INVALID")
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
            var payload: ProfileImportPayload.Draft? = null
            var failure: String? = null
            try {
                if (request.cancelled.get()) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
                val draft = if (request.source == Source.CAMERA) {
                    ProfileQrDecoder.normalizePayload(cameraText) { request.cancelled.get() }
                } else {
                    val descriptor = documentResolver.openAssetFileDescriptor(uri!!, "r", request.signal)
                        ?: throw ProfileImportReader.Failure("PROFILE_IMPORT_FAILED")
                    if (!request.attach(descriptor)) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
                    val input = descriptor.createInputStream()
                    if (!request.attach(input)) throw ProfileImportReader.Failure("PROFILE_IMPORT_INTERRUPTED")
                    if (request.source == Source.QR_IMAGE) ProfileQrImageReader.read(input) { request.cancelled.get() }
                    else ProfileImportReader.read(input) { request.cancelled.get() }
                }
                // Classify before crossing the channel. A subscription remains a masked
                // draft and requires explicit confirmation/import; no URL is fetched here.
                // A profile still requires explicit Save and authoritative WG validation.
                val parsedPayload = ProfileImportPayload.parse(draft) { request.cancelled.get() }
                if (parsedPayload is ProfileImportPayload.Profile &&
                    parsedPayload.protocol == ConnectionProfile.Kind.WIREGUARD) {
                    val parsed = Config.parse(ByteArrayInputStream(parsedPayload.text.toByteArray(StandardCharsets.UTF_8)))
                    if (parsed.peers.isEmpty()) throw ProfileImportReader.Failure("PROFILE_IMPORT_INVALID")
                }
                if (!request.cancelled.get()) payload = parsedPayload
            } catch (error: ProfileFormatFailure) {
                failure = error.code
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
            val value = payload
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

    private fun finish(request: Request, value: ProfileImportPayload.Draft? = null, code: String? = null) {
        if (pending !== request) return
        pending = null
        if (request.source == Source.CAMERA) qrSessions.end(request.code)
        request.timeout?.let { handler.removeCallbacks(it) }
        request.timeout = null
        val result = request.result ?: return
        request.result = null
        if (code == null) result.success(value?.toPlatform()) else error(result, code)
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
            "PROFILE_IMPORT_INVALID" -> "Нужен полный профиль WireGuard или ссылка VLESS в формате UTF-8"
            "INVALID_VLESS_CONFIG" -> "Проверьте ссылку VLESS: обязательные параметры отсутствуют или неверны"
            "UNSUPPORTED_PROFILE" -> "Поддерживаются профиль WireGuard и ссылка VLESS"
            "SUBSCRIPTION_URL_INVALID" -> "Для подписки нужна полная публичная HTTPS-ссылка без логина и пароля"
            "PROFILE_TELEGRAM_LINK" -> "Это ссылка Telegram, а не профиль WireGuard/VLESS или HTTPS-подписка"
            "PROFILE_VMESS_LINK" -> "Это ссылка VMess; этот протокол пока не поддерживается"
            "PROFILE_TROJAN_LINK" -> "Это ссылка Trojan; этот протокол пока не поддерживается"
            "PROFILE_SHADOWSOCKS_LINK" -> "Это ссылка Shadowsocks; этот протокол пока не поддерживается"
            "UNSUPPORTED_TRANSPORT" -> "Для VLESS поддерживаются TCP / RAW, WebSocket и gRPC; проверьте параметры транспорта"
            "UNSUPPORTED_SECURITY" -> "Для TCP / RAW нужны TLS или REALITY, для WebSocket и gRPC — TLS; encryption=none, проверка сертификата включена"
            "UNSUPPORTED_PROFILE_OPTION" -> "Ссылка VLESS содержит пока неподдерживаемый параметр"
            "PROFILE_IMPORT_INTERRUPTED" -> "Импорт профиля прерван"
            "PROFILE_IMPORT_UNAVAILABLE" -> "Импорт профиля сейчас недоступен"
            "PROFILE_QR_CAMERA_DENIED" -> "Доступ к камере не разрешён"
            "PROFILE_QR_UNAVAILABLE" -> "Не удалось открыть камеру"
            "PROFILE_QR_NOT_FOUND" -> "QR-код не найден на изображении"
            "PROFILE_QR_MULTIPLE" -> "Выберите изображение с одним QR-кодом"
            "PROFILE_QR_IMAGE_TOO_LARGE" -> "Изображение слишком большое для чтения QR-кода"
            else -> "Не удалось прочитать файл профиля"
        }
        result.error(code, message, null)
    }
}
