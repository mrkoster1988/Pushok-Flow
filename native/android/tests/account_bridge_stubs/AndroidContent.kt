package android.content

open class Context {
    open val applicationContext: Context get() = this
}

class Intent(val action: String, val uri: android.net.Uri) {
    companion object { const val ACTION_VIEW = "android.intent.action.VIEW" }
}
