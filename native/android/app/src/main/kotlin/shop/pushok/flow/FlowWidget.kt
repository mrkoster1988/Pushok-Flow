package shop.pushok.flow

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.RemoteViews
import android.widget.Toast
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class WidgetControlActivity : MainActivity() {
    private var consumed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        consumed = savedInstanceState != null
        super.onCreate(savedInstanceState)
        // A quick action needs the existing profile and approval flow but no Flutter screen.
        setContentView(android.widget.FrameLayout(this))
        if (consumed || intent.action !in setOf(FlowWidget.CONNECT, FlowWidget.STOP)) finish()
    }

    override fun onPostResume() {
        super.onPostResume()
        if (consumed) return
        consumed = true
        widgetAction(intent.action == FlowWidget.CONNECT, object : MethodChannel.Result {
            override fun success(result: Any?) { finish() }
            override fun error(code: String, message: String?, details: Any?) {
                Toast.makeText(this@WidgetControlActivity, message ?: "Откройте Pushok Flow", Toast.LENGTH_LONG).show()
                finish()
            }
            override fun notImplemented() { finish() }
        })
    }
}

class FlowWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        worker.execute {
            try {
                val state = try { MainActivity.widgetState(context) } catch (_: Exception) { "unknown" }
                render(context, state)
            } finally { pending.finish() }
        }
    }

    companion object {
        const val CONNECT = "shop.pushok.flow.widget.CONNECT"
        const val STOP = "shop.pushok.flow.widget.STOP"
        private const val NOTICE = 3602
        private val worker = Executors.newSingleThreadExecutor()

        internal fun action(context: Context, command: String): PendingIntent {
            val intent = if (command == "open") Intent(context, MainActivity::class.java)
                else Intent(context, WidgetControlActivity::class.java).setAction(command)
            return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        }

        fun render(context: Context, state: String) {
            val text = when (state) {
                "wireguard", "connected" -> "Подключено"
                "disconnected" -> "Отключено"
                "waiting_network" -> "Ожидание сети"
                "starting" -> "Подключение…"
                "reconnecting" -> "Восстановление связи"
                else -> "Статус неизвестен"
            }
            val command = when (state) {
                "disconnected" -> CONNECT
                "connected", "wireguard", "waiting_network", "reconnecting" -> STOP
                else -> "open"
            }
            val views = RemoteViews(context.packageName, R.layout.flow_widget)
            views.setTextViewText(R.id.flow_status, text)
            views.setTextColor(R.id.flow_action, if (command == STOP) 0xFF53E9D2.toInt() else 0xFFBBD7E4.toInt())
            views.setContentDescription(R.id.flow_action, "Pushok Flow. $text. " + when (command) {
                CONNECT -> "Подключить"
                STOP -> "Отключить"
                else -> "Открыть"
            })
            views.setOnClickPendingIntent(R.id.flow_action, action(context, command))
            views.setOnClickPendingIntent(R.id.flow_status, action(context, command))
            AppWidgetManager.getInstance(context).updateAppWidget(ComponentName(context, FlowWidget::class.java), views)
        }

        fun wireGuardChanged(context: Context, active: Boolean) {
            render(context, if (active) "wireguard" else "disconnected")
            val manager = context.getSystemService(NotificationManager::class.java)
            if (!active) { manager.cancel(NOTICE); return }
            val channel = "pushok_flow_tunnel"
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(channel, "Подключение Pushok Flow", NotificationManager.IMPORTANCE_LOW))
                Notification.Builder(context, channel)
            } else Notification.Builder(context)
            val notice = builder.setSmallIcon(R.drawable.ic_flow_tunnel).setContentTitle("Pushok Flow")
                .setContentText("Подключено").setContentIntent(action(context, "open"))
                .setOngoing(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_SECRET)
                .addAction(Notification.Action.Builder(null, "Отключить", action(context, STOP)).build()).build()
            try { manager.notify(NOTICE, notice) } catch (_: SecurityException) {
                // The user may have disabled notifications; the tunnel is already running.
            }
        }
    }
}
