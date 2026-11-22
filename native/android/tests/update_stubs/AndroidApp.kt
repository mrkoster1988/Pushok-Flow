package android.app

import android.content.Context
import android.content.Intent

class ForegroundServiceStartNotAllowedException : IllegalStateException()
class Notification(val text: String = "", val progress: Int = 0, val ongoing: Boolean = false)
class NotificationChannel(val id: String, val name: String, val importance: Int)
class NotificationManager {
    companion object { const val IMPORTANCE_LOW = 2 }
    val notifications = mutableListOf<Notification>()
    fun createNotificationChannel(channel: NotificationChannel) { }
    fun notify(id: Int, notification: Notification) { notifications.add(notification) }
}
class PendingIntent {
    companion object {
        const val FLAG_UPDATE_CURRENT = 1
        const val FLAG_IMMUTABLE = 2
        fun getActivity(context: Context, code: Int, intent: Intent, flags: Int) = PendingIntent()
    }
}
