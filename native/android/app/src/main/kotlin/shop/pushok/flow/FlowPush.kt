package shop.pushok.flow

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class FlowPushApplication : android.app.Application() {
    override fun onCreate() {
        super.onCreate()
        val process = if (Build.VERSION.SDK_INT >= 28) android.app.Application.getProcessName() else
            getSystemService(android.app.ActivityManager::class.java).runningAppProcesses
                ?.firstOrNull { it.pid == android.os.Process.myPid() }?.processName
        if (process == packageName) runCatching { FlowPush.restore(this) }
    }
}

class FlowPush : FirebaseMessagingService() {
    override fun onCreate() {
        super.onCreate()
        restore(this)
    }

    override fun onNewToken(token: String) {
        val ctx = applicationContext
        worker.execute {
            runCatching {
                val session = FlowAccountStore(ctx).load().session ?: return@runCatching
                if (!accepts(ctx, session)) return@runCatching
                register(ctx, session, token)
            }
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val account = message.data["account"] ?: return
        if (message.data["event"] != "account_changed") return
        val session = runCatching { FlowAccountStore(this).load().session }.getOrNull() ?: return
        if (account != session.profile?.id || !accepts(this, session)) return
        val manager = getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Аккаунт Pushok", NotificationManager.IMPORTANCE_DEFAULT))
            Notification.Builder(this, CHANNEL)
        } else Notification.Builder(this)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        manager.notify(NOTICE, builder.setSmallIcon(R.drawable.ic_flow_tunnel).setContentTitle("Pushok Flow")
            .setContentText("В вашем аккаунте есть изменения").setContentIntent(open)
            .setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE).build())
    }

    companion object {
        private const val CHANNEL = "flow_account_events"
        private const val NOTICE = 3610
        private val worker = Executors.newSingleThreadExecutor()
        private fun prefs(ctx: Context) = ctx.getSharedPreferences("flow_push_settings", Context.MODE_PRIVATE)

        private fun accepts(ctx: Context, session: FlowAccountSession): Boolean {
            val account = session.profile?.id ?: return false
            return prefs(ctx).getString("owner", null) == account && session.expiresAt > System.currentTimeMillis()
        }

        @Synchronized fun restore(ctx: Context) {
            val settings = prefs(ctx)
            if (!settings.contains("app") || FirebaseApp.getApps(ctx).any { it.name == FirebaseApp.DEFAULT_APP_NAME }) return
            val options = FirebaseOptions.Builder()
                .setApplicationId(settings.getString("app", null) ?: return)
                .setApiKey(settings.getString("key", null) ?: return)
                .setGcmSenderId(settings.getString("sender", null) ?: return)
                .setProjectId(settings.getString("project", null) ?: return).build()
            FirebaseApp.initializeApp(ctx, options)
        }

        private fun register(ctx: Context, session: FlowAccountSession, token: String?) {
            val client = FlowAccountClient(FlowAccountCall {
                FlowAccountStore(ctx).load().session?.accessToken == session.accessToken &&
                    session.expiresAt > System.currentTimeMillis()
            })
            val response = client.request("POST", "/push-device", session.accessToken, mapOf("registration_token" to token))
            check(response.status == 200 && response.json["enabled"] == (token != null))
        }

        fun configure(activity: Activity, enable: Boolean, result: MethodChannel.Result) {
            val ctx = activity.applicationContext
            if (enable && Build.VERSION.SDK_INT >= 33 &&
                activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7355)
                result.error("PERMISSION", "Разрешите уведомления Android и нажмите «Включить» ещё раз.", null)
                return
            }
            worker.execute {
                try {
                    val settings = prefs(ctx)
                    val session = FlowAccountStore(ctx).load().session ?: error("session")
                    val account = session.profile?.id ?: error("account")
                    if (enable) {
                        val config = FlowAccountClient(FlowAccountCall { true }).request("GET", "/push-config", null, null)
                        check(config.status == 200)
                        val editor = settings.edit()
                        for (field in listOf("app", "key", "sender", "project")) {
                            val value = config.json[field] as? String ?: error("config")
                            check(value.isNotBlank())
                            editor.putString(field, value)
                        }
                        check(editor.commit())
                        restore(ctx)
                        val token = Tasks.await(FirebaseMessaging.getInstance().token, 15, TimeUnit.SECONDS)
                        register(ctx, session, token)
                        check(settings.edit().putString("owner", account).commit())
                    } else {
                        check(settings.edit().remove("owner").commit())
                        ctx.getSystemService(NotificationManager::class.java).cancel(NOTICE)
                        register(ctx, session, null)
                    }
                    activity.runOnUiThread { result.success(null) }
                } catch (_: Exception) {
                    activity.runOnUiThread {
                        result.error("PUSH_UNAVAILABLE", "Не удалось связаться со службой уведомлений. Проверьте вход и настройку Firebase.", null)
                    }
                }
            }
        }
    }
}
