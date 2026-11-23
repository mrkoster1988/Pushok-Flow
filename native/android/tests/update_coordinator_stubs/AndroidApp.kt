package android.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import java.io.File

class Activity
open class Application : Context(File("."), PackageManager()) {
    fun registerActivityLifecycleCallbacks(callbacks: ActivityLifecycleCallbacks) { }
    interface ActivityLifecycleCallbacks {
        fun onActivityStarted(activity: Activity)
        fun onActivityStopped(activity: Activity)
        fun onActivityDestroyed(activity: Activity)
        fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?)
        fun onActivityResumed(activity: Activity)
        fun onActivityPaused(activity: Activity)
        fun onActivitySaveInstanceState(activity: Activity, outState: Bundle)
    }
}
class PendingIntent {
    val intentSender = Any()
    companion object {
        const val FLAG_UPDATE_CURRENT = 1
        const val FLAG_MUTABLE = 2
        fun getBroadcast(context: Context, code: Int, intent: Intent, flags: Int) = PendingIntent()
    }
}
