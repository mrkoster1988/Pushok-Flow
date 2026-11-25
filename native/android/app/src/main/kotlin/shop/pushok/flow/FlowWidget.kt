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
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.graphics.Rect
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

        private var portraits: Pair<Bitmap, Bitmap>? = null

        @Synchronized
        private fun portrait(context: Context, connected: Boolean): Bitmap {
            val cached = portraits ?: run {
                val icon = BitmapFactory.decodeResource(context.resources, R.drawable.flow_launcher_foreground)
                // The adaptive icon includes a wide transparent safe zone. Trim it for the 1×1 widget.
                val pixels = IntArray(icon.width * icon.height)
                icon.getPixels(pixels, 0, icon.width, 0, 0, icon.width, icon.height)
                val bounds = Rect(icon.width, icon.height, 0, 0)
                for (y in 0 until icon.height) for (x in 0 until icon.width) {
                    if (pixels[y * icon.width + x] ushr 24 > 12) {
                        bounds.left = minOf(bounds.left, x)
                        bounds.top = minOf(bounds.top, y)
                        bounds.right = maxOf(bounds.right, x + 1)
                        bounds.bottom = maxOf(bounds.bottom, y + 1)
                    }
                }
                val color = if (bounds.isEmpty) icon else Bitmap.createBitmap(icon, bounds.left,
                    bounds.top, bounds.width(), bounds.height())
                val gray = Bitmap.createBitmap(color.width, color.height, Bitmap.Config.ARGB_8888)
                val paint = Paint(Paint.FILTER_BITMAP_FLAG).apply {
                    colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(0f) })
                }
                Canvas(gray).drawBitmap(color, null, Rect(0, 0, gray.width, gray.height), paint)
                Pair(color, gray).also { portraits = it }
            }
            return if (connected) cached.first else cached.second
        }

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
            views.setImageViewBitmap(R.id.flow_action, portrait(context, state == "connected" || state == "wireguard"))
            views.setContentDescription(R.id.flow_action, "Pushok Flow. $text. " + when (command) {
                CONNECT -> "Подключить"
                STOP -> "Отключить"
                else -> "Открыть"
            })
            views.setOnClickPendingIntent(R.id.flow_action, action(context, command))
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
