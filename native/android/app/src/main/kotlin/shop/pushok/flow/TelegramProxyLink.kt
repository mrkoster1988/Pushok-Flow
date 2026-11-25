package shop.pushok.flow

import android.net.Uri
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** Public Telegram proxy published by the cabinet. No phone or account identifiers. */
internal object TelegramProxyLink {
    fun fetch(): Uri {
        val remote = URL("https://pushok.shop/api/v1/public-config").openConnection() as HttpsURLConnection
        try {
            remote.instanceFollowRedirects = false
            remote.connectTimeout = 3500
            remote.readTimeout = 4500
            require(remote.responseCode == 200)
            val body = ByteArrayOutputStream()
            remote.inputStream.use { input ->
                val buffer = ByteArray(2048)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    require(body.size() + n <= 16384)
                    body.write(buffer, 0, n)
                }
            }
            val url = Uri.parse(JSONObject(body.toString("UTF-8")).getString("proxy_url"))
            require(url.scheme == "https" && url.encodedAuthority == "t.me" && url.path == "/proxy")
            val host = url.getQueryParameter("server").orEmpty()
            val port = url.getQueryParameter("port")?.toIntOrNull()
            val secret = url.getQueryParameter("secret").orEmpty()
            require(host.length in 1..253 && host.matches(Regex("[A-Za-z0-9.:-]+")))
            require(port != null && port in 1..65535 && secret.matches(Regex("[a-fA-F0-9]{32,512}")))
            return Uri.Builder().scheme("tg").authority("proxy").appendQueryParameter("server", host)
                .appendQueryParameter("port", port.toString()).appendQueryParameter("secret", secret).build()
        } finally {
            remote.disconnect()
        }
    }
}
