package shop.pushok.flow

import android.content.Context
import android.content.pm.PackageManager
import android.net.VpnService

/** Call BEFORE builder.establish() inside the actual tunnel backend.
 * This helper alone does not enable WireGuard or establish a VPN.
 */
object VpnBypassConfigurator {
    data class Outcome(val applied: List<String>, val missing: List<String>)

    fun apply(context: Context, builder: VpnService.Builder): Outcome {
        val prefs = context.getSharedPreferences("pushok_flow_routes", Context.MODE_PRIVATE)
        val packages = prefs.getStringSet("flow_bypass_packages", emptySet()).orEmpty().sorted()
        val applied = mutableListOf<String>()
        val missing = mutableListOf<String>()
        for (pkg in packages) {
            try {
                builder.addDisallowedApplication(pkg)
                applied.add(pkg)
            } catch (_: PackageManager.NameNotFoundException) {
                missing.add(pkg)
            }
        }
        return Outcome(applied, missing)
    }
}