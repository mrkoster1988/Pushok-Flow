package shop.pushok.flow

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.WeakHashMap

/** Applies capture protection only while a profile editor owns a lease. */
class ProfileScreenProtection(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "shop.pushok.flow/profile_privacy"
        private const val SECURE = WindowManager.LayoutParams.FLAG_SECURE
        private val TOKEN = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

        // Values contain no engine or Activity references. A retained engine
        // keeps its leases across Activity recreation; a new engine starts clean.
        private val policies = WeakHashMap<FlutterEngine, ProfileProtectionPolicy>()
    }

    private val ownerId = UUID.randomUUID().toString()
    private var policy: ProfileProtectionPolicy? = null
    private var channel: MethodChannel? = null
    private var ownsWindowProtection = false
    private var windowWasSecure = false

    fun register(engine: FlutterEngine) {
        check(channel == null) { "Profile protection is already registered" }
        val state = policies.getOrPut(engine) { ProfileProtectionPolicy() }
        policy = state
        state.attach(ownerId)
        // configureFlutterEngine runs before the Flutter view is attached.
        // Reapply retained leases before that view can show an existing editor.
        applyWindowProtection(state.required)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun applyWindowProtection(required: Boolean) {
        val window = activity.window
        if (required) {
            if (!ownsWindowProtection) {
                windowWasSecure = (window.attributes.flags and SECURE) != 0
                ownsWindowProtection = true
            }
            window.addFlags(SECURE)
            check((window.attributes.flags and SECURE) != 0) { "Secure window was not applied" }
        } else if (ownsWindowProtection) {
            // Preserve protection established by the host before our first lease.
            if (!windowWasSecure) window.clearFlags(SECURE)
            ownsWindowProtection = false
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val state = policy
        if (state == null || !state.owns(ownerId) || activity.isDestroyed || activity.isFinishing) {
            result.error("PROFILE_PROTECTION_UNAVAILABLE", "Защита экрана недоступна", null)
            return
        }
        when (call.method) {
            "acquire" -> {
                val token = state.acquire(ownerId)
                try {
                    applyWindowProtection(true)
                    // Dart must wait for this acknowledgement before showing a key.
                    result.success(token)
                } catch (_: Exception) {
                    state.release(ownerId, token)
                    // Failed acquisition never authorizes displaying the editor.
                    // If restoring the flag also fails, leave the window secure.
                    try { applyWindowProtection(state.required) } catch (_: Exception) { }
                    result.error("PROFILE_PROTECTION_FAILED", "Не удалось защитить экран", null)
                }
            }
            "release" -> {
                val token = (call.arguments as? Map<*, *>)?.get("token") as? String
                if (token == null || !TOKEN.matches(token)) {
                    result.error("INVALID_PROTECTION_TOKEN", "Некорректный запрос защиты экрана", null)
                    return
                }
                try {
                    state.release(ownerId, token)
                    applyWindowProtection(state.required)
                    result.success(true)
                } catch (_: Exception) {
                    result.error("PROFILE_PROTECTION_FAILED", "Не удалось завершить защиту экрана", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        if (policy?.detach(ownerId) == true) channel?.setMethodCallHandler(null)
        channel = null
        policy = null
        // Do not clear the old window during detach/destroy: its last rendered
        // frame may still contain a key. Leases belong to the engine, not this
        // Activity, and will be reapplied if the same engine is reattached.
    }
}
