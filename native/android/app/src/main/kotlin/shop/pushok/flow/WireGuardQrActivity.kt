package shop.pushok.flow

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
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
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import java.lang.ref.WeakReference

/** Private, editor-owned offline scanner. No raw QR content is displayed, logged or saved. */
class WireGuardQrActivity : Activity() {
    companion object {
        const val EXTRA_REQUEST_CODE = "shop.pushok.flow.qr.request"
        const val EXTRA_TEXT = "shop.pushok.flow.qr.text"
        const val EXTRA_ERROR = "shop.pushok.flow.qr.error"
        private const val CAMERA_REQUEST = 0x42
    }

    private var requestCode = -1
    private var scanner: DecoratedBarcodeView? = null
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
        val ui = Handler(Looper.getMainLooper())
        val cancel: () -> Unit = { ui.post { owner.get()?.complete() }; Unit }
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
        layout.addView(TextView(this).apply {
            text = "Наведите камеру на QR-код WireGuard или VLESS из 3x-ui."
            textSize = 16f
            setTextColor(Color.rgb(190, 206, 225))
            setPadding(0, 0, 0, dp(12))
        })
        val camera = DecoratedBarcodeView(this).apply {
            setStatusText("")
            barcodeView.decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
            barcodeView.addStateListener(object : CameraPreview.StateListener {
                override fun previewSized() = Unit
                override fun previewStarted() = Unit
                override fun previewStopped() = Unit
                override fun cameraClosed() = Unit
                override fun cameraError(error: Exception) {
                    if (resumed && !finished) complete(error = "PROFILE_QR_UNAVAILABLE")
                }
            })
        }
        scanner = camera
        layout.addView(camera, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        layout.addView(Button(this).apply {
            text = "Отмена"
            textSize = 16f
            isAllCaps = false
            gravity = Gravity.CENTER
            setTextColor(Color.rgb(96, 232, 232))
            setBackgroundColor(Color.rgb(18, 38, 61))
            setOnClickListener { complete() }
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(56)).apply {
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
        } catch (_: SecurityException) {
            complete(error = "PROFILE_QR_CAMERA_DENIED")
        } catch (_: Exception) {
            complete(error = "PROFILE_QR_UNAVAILABLE")
        }
    }

    override fun onPause() {
        resumed = false
        epoch++
        scanner?.barcodeView?.stopDecoding()
        scanner?.pause()
        super.onPause()
    }

    override fun onDestroy() {
        unregisterBack?.invoke()
        unregisterBack = null
        cancellation?.let { WireGuardProfileImport.qrSessions.unwatch(requestCode, it) }
        cancellation = null
        scanner?.barcodeView?.stopDecoding()
        scanner?.pause()
        scanner = null
        super.onDestroy()
    }

    @Deprecated("Handled by the platform back callback on API 33 and newer")
    override fun onBackPressed() = complete()

    private fun complete(text: String? = null, error: String? = null) {
        if (finished) return
        finished = true
        epoch++
        scanner?.barcodeView?.stopDecoding()
        scanner?.pause()
        val data = Intent()
        if (text != null) data.putExtra(EXTRA_TEXT, text)
        if (error != null) data.putExtra(EXTRA_ERROR, error)
        setResult(if (text == null) RESULT_CANCELED else RESULT_OK, data)
        finish()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()
}
