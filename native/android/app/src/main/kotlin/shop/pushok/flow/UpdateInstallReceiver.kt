package shop.pushok.flow

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Explicit mutable PendingIntent recipient; never exported and never starts an Activity. */
class UpdateInstallReceiver : BroadcastReceiver() {
    companion object { const val ACTION = "shop.pushok.flow.UPDATE_INSTALL_RESULT" }
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val pending = goAsync()
        try { UpdateCoordinator.get(context).installationResult(intent) { pending.finish() } }
        catch (_: Exception) { pending.finish() }
    }
}
