package android.content

import android.app.NotificationManager

open class Context {
    companion object { const val NOTIFICATION_SERVICE = "notification" }
    val notifications = NotificationManager()
    fun getSystemService(name: String): Any = notifications
}
class Intent(context: Context, target: Class<*>) {
    companion object { const val FLAG_ACTIVITY_SINGLE_TOP = 1; const val FLAG_ACTIVITY_CLEAR_TOP = 2 }
    fun addFlags(flags: Int) { }
}
