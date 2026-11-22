package androidx.core.app

import android.app.Notification
import android.app.PendingIntent
import android.content.Context

class NotificationCompat {
    companion object { const val CATEGORY_PROGRESS = "progress"; const val PRIORITY_LOW = -1 }
    class Builder(context: Context, channel: String) {
        private var text = ""
        private var progress = 0
        private var ongoing = false
        fun setSmallIcon(value: Int) = this
        fun setContentTitle(value: String) = this
        fun setContentText(value: String) = apply { text = value }
        fun setContentIntent(value: PendingIntent) = this
        fun setCategory(value: String) = this
        fun setPriority(value: Int) = this
        fun setOnlyAlertOnce(value: Boolean) = this
        fun setOngoing(value: Boolean) = apply { ongoing = value }
        fun setShowWhen(value: Boolean) = this
        fun setProgress(max: Int, value: Int, indeterminate: Boolean) = apply { progress = value }
        fun build() = Notification(text, progress, ongoing)
    }
}
