package android.content

open class Context(private val connectivity: android.net.ConnectivityManager) {
    fun <T> getSystemService(kind: Class<T>): T = kind.cast(connectivity)
}
