package shop.pushok.flow

import java.io.ByteArrayInputStream
import java.net.InetAddress
import java.net.URL
import java.net.URLEncoder
import java.security.cert.Certificate
import javax.net.ssl.HttpsURLConnection

private class TestConnection(
    url: URL,
    private val status: Int = 200,
    private val bytes: ByteArray = "safe-body".toByteArray(),
    private val headers: Map<String, String> = emptyMap(),
    private val length: Long = bytes.size.toLong(),
    private val encoding: String? = null,
) : HttpsURLConnection(url) {
    var closed = false
    override fun connect() { }
    override fun disconnect() { closed = true }
    override fun usingProxy() = false
    override fun getResponseCode() = status
    override fun getInputStream() = ByteArrayInputStream(bytes)
    override fun getHeaderField(name: String?) = headers.entries.firstOrNull { it.key.equals(name, true) }?.value
    override fun getContentLengthLong() = length
    override fun getContentEncoding() = encoding
    override fun getCipherSuite() = "TLS_TEST"
    override fun getLocalCertificates(): Array<Certificate>? = null
    override fun getServerCertificates(): Array<Certificate> = emptyArray()
}

private fun expectCode(code: String, run: () -> Unit) {
    try { run(); error("Expected $code") }
    catch (failure: SubscriptionFailure) {
        check(failure.code == code) { "Expected $code, got ${failure.code}" }
        check(!failure.toString().contains("secret"))
    }
}

fun main() {
    val publicDns: (String) -> Array<InetAddress> = { arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8))) }
    val source = "https://subscription.example.org/access/secret-token"
    val seen = mutableListOf<TestConnection>()
    val ordinary = SubscriptionDownloader(resolve = publicDns, open = { url ->
        TestConnection(url, headers = mapOf("Subscription-Userinfo" to "expire=1900000000", "Profile-Title" to "Pushok"))
            .also { seen.add(it) }
    })
    val response = ordinary.fetch(source)
    check(String(response.body) == "safe-body")
    check(response.title == "Pushok" && response.userInfo == "expire=1900000000")
    check(seen.single().closed && !seen.single().instanceFollowRedirects)
    check(seen.single().getRequestProperty("Accept-Encoding") == "identity")
    check(seen.single().getRequestProperty("Authorization") == null)

    var opened = 0
    val internalDns = SubscriptionDownloader(resolve = {
        arrayOf(InetAddress.getByAddress(byteArrayOf(8, 8, 8, 8)), InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
    }, open = { opened++; TestConnection(it) })
    expectCode("SUBSCRIPTION_URL_INVALID") { internalDns.fetch(source) }
    check(opened == 0)

    for (location in listOf("http://subscription.example.org/file", "https://127.0.0.1/private",
        "https://username:secret@other.example.org/file", "https://other.example.org/file#secret")) {
        var calls = 0
        val client = SubscriptionDownloader(resolve = publicDns, open = {
            calls++
            TestConnection(it, 302, headers = mapOf("Location" to location))
        })
        expectCode("SUBSCRIPTION_URL_INVALID") { client.fetch(source) }
        check(calls == 1)
    }

    val paths = mutableListOf<String>()
    val relativeRedirect = SubscriptionDownloader(resolve = publicDns, open = {
        paths.add(it.path)
        if (paths.size == 1) TestConnection(it, 302, headers = mapOf("Location" to "/final"))
        else TestConnection(it)
    })
    relativeRedirect.fetch(source)
    check(paths == listOf("/access/secret-token", "/final"))

    var redirectCount = 0
    val redirectLoop = SubscriptionDownloader(resolve = publicDns, open = {
        redirectCount++
        TestConnection(it, 307, headers = mapOf("Location" to "/again"))
    })
    expectCode("SUBSCRIPTION_NETWORK_ERROR") { redirectLoop.fetch(source) }
    check(redirectCount == 4)

    val hugeLength = SubscriptionDownloader(resolve = publicDns, open = {
        TestConnection(it, length = SubscriptionPolicy.MAX_BYTES + 1L)
    })
    expectCode("SUBSCRIPTION_TOO_LARGE") { hugeLength.fetch(source) }
    val hugeStream = SubscriptionDownloader(resolve = publicDns, open = {
        TestConnection(it, bytes = ByteArray(SubscriptionPolicy.MAX_BYTES + 1), length = -1)
    })
    expectCode("SUBSCRIPTION_TOO_LARGE") { hugeStream.fetch(source) }
    val compressed = SubscriptionDownloader(resolve = publicDns, open = { TestConnection(it, encoding = "gzip") })
    expectCode("SUBSCRIPTION_INVALID") { compressed.fetch(source) }
    for (code in listOf(401, 403)) {
        val denied = SubscriptionDownloader(resolve = publicDns, open = { TestConnection(it, status = code) })
        expectCode("SUBSCRIPTION_AUTH_REQUIRED") { denied.fetch(source) }
    }
    val unavailable = SubscriptionDownloader(resolve = publicDns, open = { TestConnection(it, status = 503) })
    expectCode("SUBSCRIPTION_NETWORK_ERROR") { unavailable.fetch(source) }
    var ticks = 0L
    val timeout = SubscriptionDownloader(resolve = publicDns, open = { TestConnection(it) },
        elapsedMs = { ticks.also { ticks += 15_000 } })
    expectCode("SUBSCRIPTION_NETWORK_ERROR") { timeout.fetch(source) }
    expectCode("SUBSCRIPTION_INTERRUPTED") {
        ordinary.fetch(source) { throw SubscriptionFailure("SUBSCRIPTION_INTERRUPTED") }
    }

    val encoded = URLEncoder.encode(source, "UTF-8")
    val validLink = "pushokflow://subscription?url=$encoded&name=Pushok"
    check(SubscriptionLinks.parse(validLink)?.url == source)
    check(SubscriptionLinks.parse(validLink)?.name == "Pushok")
    check(SubscriptionLinks.parse("pushokflow://subscription?url=$encoded")?.name == null)
    for (bad in listOf("https://subscription?url=$encoded", "pushokflow://other?url=$encoded",
        "pushokflow://subscription/path?url=$encoded", "$validLink&url=$encoded", "$validLink&%75rl=$encoded",
        "$validLink&unknown=1", "$validLink#ignored", "pushokflow://user@subscription?url=$encoded",
        "pushokflow://subscription?url=%QQ", "pushokflow://subscription?url=https%3A%2F%2F127.0.0.1%2Fsecret",
        "$validLink\n", "pushokflow://subscription?url=" + "x".repeat(SubscriptionLinks.MAX_LINK_LENGTH))) {
        check(SubscriptionLinks.parse(bad) == null) { "Invalid link was accepted" }
    }
    check(SubscriptionLinks.ACCOUNT_URL == "https://t.me/pushok_app")

    val sixHours = SubscriptionRefreshPolicy.SUCCESS_INTERVAL_MS
    val hour = SubscriptionRefreshPolicy.RETRY_INTERVAL_MS
    check(SubscriptionRefreshPolicy.due(10, 0, 0))
    check(!SubscriptionRefreshPolicy.due(sixHours, 1, 0))
    check(SubscriptionRefreshPolicy.due(sixHours + 1, 1, 0))
    check(!SubscriptionRefreshPolicy.due(sixHours + 1, 1, sixHours))
    check(SubscriptionRefreshPolicy.due(sixHours + hour, 1, sixHours))
    check(!SubscriptionRefreshPolicy.due(100, 200, 0))
    check(!SubscriptionRefreshPolicy.due(100, 0, 200))
    check(!SubscriptionRefreshPolicy.due(100, 0, -1))
    println("Subscription HTTPS, link and refresh policy checks passed")
}
