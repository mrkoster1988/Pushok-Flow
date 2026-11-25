package shop.pushok.flow

import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class FlowTile : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    private fun refresh(): String {
        val state = try { MainActivity.widgetState(this) } catch (_: Exception) { "unknown" }
        qsTile?.apply {
            this.state = when (state) {
                "wireguard" -> Tile.STATE_ACTIVE
                "disconnected" -> Tile.STATE_INACTIVE
                else -> Tile.STATE_UNAVAILABLE
            }
            contentDescription = if (state == "wireguard") "Отключить Pushok Flow" else "Подключить Pushok Flow"
            updateTile()
        }
        return state
    }

    @Suppress("DEPRECATION")
    override fun onClick() {
        super.onClick()
        unlockAndRun {
            val command = when (refresh()) {
                "wireguard" -> FlowWidget.STOP
                "disconnected" -> FlowWidget.CONNECT
                else -> return@unlockAndRun
            }
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(FlowWidget.action(this, command))
            } else {
                startActivityAndCollapse(Intent(this, WidgetControlActivity::class.java)
                    .setAction(command).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}
