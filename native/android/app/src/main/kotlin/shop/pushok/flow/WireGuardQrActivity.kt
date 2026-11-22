package shop.pushok.flow

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.hardware.Camera
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.google.zxing.BarcodeFormat
import com.google.zxing.ResultPoint
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.CameraPreview
import com.journeyapps.barcodescanner.DecoratedBarcodeView
import java.lang.ref.WeakReference

/** Private, editor-owned offline scanner. No raw QR content is displayed, logged or saved. */
class WireGuardQrActivity : Activity() {
    companion object {
        const val EXTRA_REQUEST_CODE = "shop.pushok.flow.qr.request"
        const val EXTRA_TEXT = "shop.pushok.flow.qr.text"
        const val EXTRA_ERROR = "shop.pushok.flow.qr.error"
        private const val CAMERA_REQUEST = 0x42
        private const val SCAN_HINT_DELAY_MS = 9_000L
    }

    private val ui = Handler(Looper.getMainLooper())
    private var requestCode = -1
    private var scanner: DecoratedBarcodeView? = null
    private var scanStatus: TextView? = null
    private var torchButton: Button? = null
    private var torchAvailable = false
    private var torchOn = false
    private var scanHint: Runnable? = null
    private var resumed = false
    private var finished = false
    private var permissionRequested = false
    private var epoch = 0
    private var cancellation: (() -> Unit)? = null
    private var unregisterBack: (() -> Unit)? = null

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        // Apply before creating any content or camera preview, including restored activities.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
        requestCode = intent.getIntExtra(EXTRA_REQUEST_CODE, -1)
        if (callingActivity?.packageName != packageName ||
            !WireGuardProfileImport.qrSessions.isActive(requestCode)) {
            complete()
            return
        }
        val owner = WeakReference(this)
        val platformUi = ui
        val cancel: () -> Unit = { platformUi.post { owner.get()?.complete() }; Unit }
        cancellation = cancel
        if (!WireGuardProfileImport.qrSessions.watch(requestCode, cancel)) {
            complete()
            return
        }
        if (Build.VERSION.SDK_INT >= 33) {
            val callback = OnBackInvokedCallback { complete() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
            unregisterBack = { onBackInvokedDispatcher.unregisterOnBackInvokedCallback(callback) }
        }
        window.statusBarColor = Color.rgb(7, 19, 36)
        window.navigationBarColor = Color.rgb(7, 19, 36)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(7, 19, 36))
            setPadding(dp(16), dp(12), dp(16), dp(12))
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(dp(16) + insets.systemWindowInsetLeft,
                    dp(12) + insets.systemWindowInsetTop,
                    dp(16) + insets.systemWindowInsetRight,
                    dp(12) + insets.systemWindowInsetBottom)
                insets
            }
        }
        layout.addView(TextView(this).apply {
            text = "QR-код подключения"
            textSize = 22f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(Color.rgb(96, 232, 232))
            setPadding(0, dp(8), 0, dp(8))
        })
        val status = TextView(this).apply {
            text = "Открываю камеру…"
            textSize = 16f
            minLines = 3
            setTextColor(Color.rgb(190, 206, 225))
            setPadding(0, 0, 0, dp(12))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        scanStatus = status
        layout.addView(status)
        val camera = DecoratedBarcodeView(this).apply {
            setStatusText("")
            barcodeView.decoderFactory = ProfileQrCameraDecoder.createFactory()
            // Prefer continuous focus; the SDK falls back to AUTO on unsupported cameras.
            barcodeView.cameraSettings.isContinuousFocusEnabled = true
            // Keep the SDK's adaptive frame and preview-coordinate mapping. Its default
            // layout has no fixed-size rectangle and fits portrait and landscape previews.
            barcodeView.addStateListener(object : CameraPreview.StateListener {
                override fun previewSized() = Unit
                override fun previewStarted() = onPreviewStarted()
                override fun previewStopped() {
                    clearScanHint()
                    torchAvailable = false
                    torchButton?.visibility = View.GONE
                }
                override fun cameraClosed() = Unit
                override fun cameraError(error: Exception) {
                    if (resumed && !finished) complete(error = "PROFILE_QR_UNAVAILABLE")
                }
            })
        }
        scanner = camera
        layout.addView(camera, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        torchButton = Button(this).apply {
            text = "Фонарик"
            textSize = 16f
            isAllCaps = false
            gravity = Gravity.CENTER
            setTextColor(Color.rgb(96, 232, 232))
            setBackgroundColor(Color.rgb(18, 38, 61))
            visibility = View.GONE
            setOnClickListener { toggleTorch() }
        }.also {
            actions.addView(it, LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.MATCH_PARENT, 1f).apply { marginEnd = dp(8) })
        }
        actions.addView(Button(this).apply {
            text = "Отмена"
            textSize = 16f
            isAllCaps = false
            gravity = Gravity.CENTER
            setTextColor(Color.rgb(96, 232, 232))
            setBackgroundColor(Color.rgb(18, 38, 61))
            setOnClickListener { complete() }
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
        layout.addView(actions, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(56)).apply {
            topMargin = dp(12)
        })
        setContentView(layout)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        if (finished) return
        if (!WireGuardProfileImport.qrSessions.isActive(requestCode)) {
            complete()
            return
        }
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
            complete(error = "PROFILE_QR_UNAVAILABLE")
            return
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else if (!permissionRequested) {
            permissionRequested = true
            try { requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_REQUEST) }
            catch (_: Exception) { complete(error = "PROFILE_QR_UNAVAILABLE") }
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code != CAMERA_REQUEST || finished) return
        val index = permissions.indexOf(Manifest.permission.CAMERA)
        if (index < 0 || grants.getOrNull(index) != PackageManager.PERMISSION_GRANTED) {
            complete(error = "PROFILE_QR_CAMERA_DENIED")
        } else if (resumed) startCamera()
    }

    private fun startCamera() {
        if (!resumed || finished || !WireGuardProfileImport.qrSessions.isActive(requestCode)) return
        val camera = scanner ?: return
        val activeEpoch = ++epoch
        clearScanHint()
        scanStatus?.text = "Открываю камеру…"
        try {
            camera.decodeSingle(object : BarcodeCallback {
                override fun barcodeResult(result: BarcodeResult) {
                    if (!resumed || finished || isFinishing || isDestroyed || activeEpoch != epoch ||
                        !WireGuardProfileImport.qrSessions.isActive(requestCode)) return
                    if (result.barcodeFormat != BarcodeFormat.QR_CODE) return
                    val text = result.text
                    if (text == null || text.length > ProfileImportReader.MAX_BYTES) {
                        complete(error = "PROFILE_IMPORT_INVALID")
                    } else complete(text = text)
                }
                override fun possibleResultPoints(points: MutableList<ResultPoint>?) = Unit
            })
            camera.resume()
            // Permission delivery and onResume can both reach here. The SDK's resume
            // is idempotent and may not emit another previewStarted for an open camera.
            if (camera.barcodeView.isPreviewActive) onPreviewStarted()
        } catch (_: SecurityException) {
            complete(error = "PROFILE_QR_CAMERA_DENIED")
        } catch (_: Exception) {
            complete(error = "PROFILE_QR_UNAVAILABLE")
        }
    }

    @Suppress("DEPRECATION")
    private fun onPreviewStarted() {
        if (!resumed || finished || !WireGuardProfileImport.qrSessions.isActive(requestCode)) return
        val camera = scanner ?: return
        if (!camera.barcodeView.isPreviewActive) return
        val activeEpoch = epoch
        scanStatus?.text = "QR WireGuard или VLESS: поместите код целиком в рамку."
        clearScanHint()
        scanHint = Runnable {
            scanHint = null
            if (resumed && !finished && activeEpoch == epoch &&
                camera.barcodeView.isPreviewActive &&
                WireGuardProfileImport.qrSessions.isActive(requestCode)) {
                // Guidance only: the decoder remains active and still accepts the next frame.
                scanStatus?.text = "QR пока не распознан. Измените расстояние или выберите «QR из фото» в редакторе."
            }
        }.also { ui.postDelayed(it, SCAN_HINT_DELAY_MS) }
        torchAvailable = false
        torchButton?.visibility = View.GONE
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FLASH)) return
        // Public SDK callback runs on its camera thread. A device can advertise a flash
        // while the selected camera has none; only that camera's modes enable this button.
        camera.barcodeView.changeCameraParameters { parameters ->
            val modes = parameters.supportedFlashModes.orEmpty()
            val available = Camera.Parameters.FLASH_MODE_TORCH in modes &&
                Camera.Parameters.FLASH_MODE_OFF in modes
            ui.post {
                if (resumed && !finished && activeEpoch == epoch &&
                    camera.barcodeView.isPreviewActive &&
                    WireGuardProfileImport.qrSessions.isActive(requestCode)) {
                    torchAvailable = available
                    torchButton?.visibility = if (available) View.VISIBLE else View.GONE
                }
            }
            parameters
        }
    }

    private fun toggleTorch() {
        val camera = scanner ?: return
        if (!resumed || finished || !torchAvailable || !camera.barcodeView.isPreviewActive ||
            !WireGuardProfileImport.qrSessions.isActive(requestCode)) return
        if (torchOn) camera.setTorchOff() else camera.setTorchOn()
        torchOn = !torchOn
        torchButton?.text = if (torchOn) "Выключить фонарик" else "Фонарик"
    }

    private fun clearScanHint() {
        scanHint?.let { ui.removeCallbacks(it) }
        scanHint = null
    }

    private fun pauseCamera() {
        clearScanHint()
        torchAvailable = false
        torchOn = false
        torchButton?.visibility = View.GONE
        torchButton?.text = "Фонарик"
        scanner?.setTorchOff()
        scanner?.barcodeView?.stopDecoding()
        scanner?.pause()
    }

    override fun onPause() {
        resumed = false
        epoch++
        pauseCamera()
        super.onPause()
    }

    override fun onDestroy() {
        unregisterBack?.invoke()
        unregisterBack = null
        cancellation?.let { WireGuardProfileImport.qrSessions.unwatch(requestCode, it) }
        cancellation = null
        pauseCamera()
        scanner = null
        scanStatus = null
        torchButton = null
        super.onDestroy()
    }

    @Deprecated("Handled by the platform back callback on API 33 and newer")
    override fun onBackPressed() = complete()

    private fun complete(text: String? = null, error: String? = null) {
        if (finished) return
        finished = true
        epoch++
        pauseCamera()
        val data = Intent()
        if (text != null) data.putExtra(EXTRA_TEXT, text)
        if (error != null) data.putExtra(EXTRA_ERROR, error)
        setResult(if (text == null) RESULT_CANCELED else RESULT_OK, data)
        finish()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()
}
