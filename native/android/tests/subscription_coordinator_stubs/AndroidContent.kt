package android.content
open class Context {
    open val applicationContext: Context get() = this
    val preferences = Preferences()
    fun getSharedPreferences(name: String, mode: Int) = preferences
    companion object { const val MODE_PRIVATE = 0 }
}
class Intent(val action: String, val uri: android.net.Uri) {
    companion object { const val ACTION_VIEW = "android.intent.action.VIEW" }
}
class Preferences {
    private val values = java.util.concurrent.ConcurrentHashMap<String, Any>()
    var failWrites = false
    fun getBoolean(key: String, fallback: Boolean) = values[key] as? Boolean ?: fallback
    fun getLong(key: String, fallback: Long) = values[key] as? Long ?: fallback
    fun getString(key: String, fallback: String?): String? = values[key] as? String ?: fallback
    fun edit() = Editor()
    inner class Editor {
        private val changes = mutableMapOf<String, Any?>()
        fun putBoolean(key: String, value: Boolean) = apply { changes[key] = value }
        fun putLong(key: String, value: Long) = apply { changes[key] = value }
        fun putString(key: String, value: String) = apply { changes[key] = value }
        fun remove(key: String) = apply { changes[key] = null }
        fun commit(): Boolean {
            if (failWrites) return false
            for ((key,value) in changes) { if(value==null) values.remove(key) else values[key]=value }
            return true
        }
        fun apply() { commit() }
    }
}

class ActivityNotFoundException : RuntimeException()
