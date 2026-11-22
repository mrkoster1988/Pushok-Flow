package shop.pushok.flow

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Android sends this only after replacing this package; user settings and VPN profiles survive. */
class UpdateReplacedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) UpdateCoordinator.get(context).packageReplaced()
    }
}
