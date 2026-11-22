package shop.pushok.flow

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.SystemClock
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** No libXray/Go classes may be referenced here: WireGuard lives in this process. */
class XrayTunnelClient(context: Context) {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val sequence = AtomicInteger()

    @Synchronized fun start(profile: VlessProfile.Parsed, exclusions: Set<String>): Boolean {
        val arguments = Bundle().apply {
            putString("config", XrayConfig.build(profile))
            putStringArrayList("exclusions", ArrayList(exclusions.sorted()))
        }
        return exchange(XrayIpc.START, arguments, create = true)
    }

    /** Returns the resulting connected state (false after a successful disconnect). */
    @Synchronized fun stop(): Boolean = exchange(XrayIpc.STOP, Bundle(), create = false)

    /** Passive binding discovers a surviving service or briefly creates an idle Java service. */
    @Synchronized fun isUp(): Boolean = exchange(XrayIpc.STATUS, Bundle(), create = false)

    private fun exchange(command: Int, arguments: Bundle, create: Boolean): Boolean {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Tunnel IPC must run on the connection queue" }
        val id = sequence.incrementAndGet()
        val timeout = if (command == XrayIpc.START) XrayIpc.START_TIMEOUT_MS else XrayIpc.QUERY_TIMEOUT_MS
        val deadline = SystemClock.elapsedRealtime() + timeout
        val finished = AtomicBoolean(false)
        val bound = AtomicBoolean(false)
        val ready = CountDownLatch(1)
        val replied = CountDownLatch(1)
        var remote: Messenger? = null
        var failure: String? = null
        var response: Bundle? = null
        val replyTo = Messenger(Handler(Looper.getMainLooper()) { message ->
            if (!finished.get() && message.sendingUid == app.applicationInfo.uid &&
                message.arg1 == id && message.what == XrayIpc.REPLY) {
                response = message.data
                replied.countDown()
            }
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                if (!finished.get()) remote = Messenger(binder)
                ready.countDown()
            }
            override fun onServiceDisconnected(name: ComponentName) {
                failure = "XRAY_SERVICE_UNAVAILABLE"
                ready.countDown()
                replied.countDown()
            }
            override fun onNullBinding(name: ComponentName) {
                failure = "XRAY_SERVICE_UNAVAILABLE"
                ready.countDown()
                replied.countDown()
            }
            override fun onBindingDied(name: ComponentName) = onServiceDisconnected(name)
        }
        val intent = Intent().setClassName(app, XrayIpc.SERVICE).setAction(XrayIpc.BIND)
        main.post {
            if (finished.get()) return@post
            try {
                if (create) {
                    val start = Intent(intent).setAction(XrayIpc.PREPARE)
                    if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(start) else app.startService(start)
                }
                // flags=0 may return true without a callback when the service is absent.
                // AUTO_CREATE is safe: onCreate/onBind never establish a TUN or load Go.
                bound.set(app.bindService(intent, connection, Context.BIND_AUTO_CREATE))
                if (!bound.get()) { failure = "XRAY_SERVICE_UNAVAILABLE"; ready.countDown() }
            } catch (_: Exception) {
                failure = "XRAY_SERVICE_UNAVAILABLE"
                ready.countDown()
            }
        }
        fun remaining() = (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0)
        try {
            if (!ready.await(remaining(), TimeUnit.MILLISECONDS)) throw XrayTunnelFailure("XRAY_TIMEOUT")
            if (failure != null) throw XrayTunnelFailure(failure!!)
            val target = remote ?: throw XrayTunnelFailure("XRAY_SERVICE_UNAVAILABLE")
            arguments.putLong("deadline", deadline)
            val request = Message.obtain(null, command, id, 0).apply { data = arguments; this.replyTo = replyTo }
            target.send(request)
            if (!replied.await(remaining(), TimeUnit.MILLISECONDS)) throw XrayTunnelFailure("XRAY_TIMEOUT")
            if (failure != null) throw XrayTunnelFailure(failure!!)
            val answer = response ?: throw XrayTunnelFailure("XRAY_SERVICE_UNAVAILABLE")
            answer.getString("error")?.let { throw XrayTunnelFailure(it) }
            if (!answer.containsKey("connected")) throw XrayTunnelFailure("XRAY_SERVICE_UNAVAILABLE")
            return answer.getBoolean("connected")
        } catch (error: Exception) {
            // A START which times out must never activate later without an owner.
            if (command == XrayIpc.START) {
                try { remote?.send(Message.obtain(null, XrayIpc.CANCEL, id, 0)) } catch (_: Exception) {}
                main.post { try { app.stopService(intent) } catch (_: Exception) {} }
            }
            if (error is InterruptedException) Thread.currentThread().interrupt()
            throw if (error is XrayTunnelFailure) error else XrayTunnelFailure("XRAY_SERVICE_UNAVAILABLE")
        } finally {
            finished.set(true)
            arguments.clear()
            main.post { if (bound.getAndSet(false)) try { app.unbindService(connection) } catch (_: Exception) {} }
        }
    }
}

internal object XrayIpc {
    const val SERVICE = "shop.pushok.flow.XrayVpnService"
    const val BIND = "shop.pushok.flow.XRAY_BIND"
    const val PREPARE = "shop.pushok.flow.XRAY_PREPARE"
    const val STOP_ACTION = "shop.pushok.flow.XRAY_STOP"
    const val START = 1
    const val STOP = 2
    const val STATUS = 3
    const val CANCEL = 4
    const val REPLY = 5
    const val START_TIMEOUT_MS = 20_000L
    const val QUERY_TIMEOUT_MS = 5_000L
}
