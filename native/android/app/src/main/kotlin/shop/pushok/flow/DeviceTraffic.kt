package shop.pushok.flow

import android.app.Activity
import android.app.AppOpsManager
import android.app.usage.NetworkStats
import android.app.usage.NetworkStatsManager
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Process
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** A user-requested, device-local snapshot. No persistence or network requests. */
internal object DeviceTraffic {
    fun register(activity: Activity, messenger: BinaryMessenger) {
        val context = activity.applicationContext
        val channel = MethodChannel(messenger, "shop.pushok.flow/device_traffic",
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> try {
                    result.success(snapshot(context))
                } catch (_: Exception) {
                    result.error("UNAVAILABLE", "Android не вернул статистику", null)
                }
                "settings" -> activity.runOnUiThread {
                    val settings = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                    val opened = runCatching {
                        activity.startActivity(Intent(settings).setData(Uri.parse("package:" + context.packageName)))
                    }.isSuccess || runCatching { activity.startActivity(settings) }.isSuccess
                    result.success(opened)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun snapshot(context: Context): Map<String, Any> {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val addresses = connectivity.allNetworks.flatMap { network ->
            val caps = connectivity.getNetworkCapabilities(network) ?: return@flatMap emptyList()
            val label = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Мобильная сеть"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
                else -> return@flatMap emptyList()
            }
            connectivity.getLinkProperties(network)?.linkAddresses.orEmpty().mapNotNull {
                val ip = it.address
                if (ip.isAnyLocalAddress || ip.isLoopbackAddress || ip.isLinkLocalAddress) null
                else ip.hostAddress?.let { value -> mapOf("network" to label, "ip" to value) }
            }
        }.distinct()
        val result = mutableMapOf<String, Any>("addresses" to addresses)
        val ops = context.getSystemService(AppOpsManager::class.java)
        if (ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(),
                context.packageName) != AppOpsManager.MODE_ALLOWED) return result + ("status" to "permission")

        val end = System.currentTimeMillis()
        val start = end - 24 * 60 * 60 * 1000L
        val stats = context.getSystemService(NetworkStatsManager::class.java)
        val totals = mutableMapOf<Int, LongArray>()
        val sources = mutableListOf<String>()
        for ((type, name) in listOf(ConnectivityManager.TYPE_WIFI to "Wi-Fi",
                ConnectivityManager.TYPE_MOBILE to "Мобильная сеть")) {
            // Merge only complete queries. A partial bucket stream must not become a total.
            val bytes = mutableMapOf<Int, LongArray>()
            try {
                val summary = stats.querySummary(type, null, start, end) ?: continue
                summary.use {
                    val bucket = NetworkStats.Bucket()
                    while (it.getNextBucket(bucket)) {
                        if (bucket.uid < 0 || bucket.rxBytes < 0 || bucket.txBytes < 0) continue
                        val pair = bytes.getOrPut(bucket.uid) { LongArray(2) }
                        pair[0] += bucket.rxBytes
                        pair[1] += bucket.txBytes
                    }
                }
            } catch (_: RuntimeException) { continue }
            sources.add(name)
            for ((uid, pair) in bytes) {
                val sum = totals.getOrPut(uid) { LongArray(2) }
                sum[0] += pair[0]
                sum[1] += pair[1]
            }
        }
        val packages = context.packageManager
        val rows = totals.filterValues { it[0] > 0 || it[1] > 0 }
            .entries.sortedByDescending { it.value.sum() }.map { (uid, pair) ->
                val names = packages.getPackagesForUid(uid).orEmpty().sorted().map { pkg ->
                    runCatching { packages.getApplicationLabel(packages.getApplicationInfo(pkg, 0)).toString() }
                        .getOrDefault(pkg)
                }
                mapOf("label" to names.distinct().joinToString(" / ").ifBlank { "UID " + uid },
                    "received" to pair[0], "sent" to pair[1])
            }
        return result + mapOf("status" to if (sources.isEmpty()) "unavailable" else "ready",
            "sources" to sources, "apps" to rows)
    }
}
