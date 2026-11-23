package shop.pushok.flow

import android.content.Context
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

internal class UpdateWorkCancellation(val deadline: Long, val automatic: Boolean) {
    val cancelled = AtomicBoolean(false)
    @Volatile var connection: HttpsURLConnection? = null
    var downloadProgress: ((UpdateManifest, Long) -> Unit)? = null
    fun cancel() { cancelled.set(true); try { connection?.disconnect() } catch (_: Exception) { } }
}
internal object BackgroundUpdateScheduler {
    val enqueued = mutableListOf<String>()
    fun configure(context: Context, enabled: Boolean, immediate: Boolean = false) { }
    fun whenIdle(context: Context) { }
    fun monitorSession(context: Context) { }
    fun download(context: Context, manifest: UpdateManifest, encoded: String) { enqueued.add(encoded) }
}
class UpdateInstallReceiver { companion object { const val ACTION = "update_fixture" } }
