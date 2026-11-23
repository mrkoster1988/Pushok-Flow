package android.content

import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import java.io.File

open class Context(val filesDir: File, val packageManager: PackageManager,
    val preferences: SharedPreferences = SharedPreferences()) {
    companion object { const val MODE_PRIVATE = 0; const val CONNECTIVITY_SERVICE = "connectivity" }
    val applicationContext: Context get() = this
    val packageName = "shop.pushok.flow"
    fun getSharedPreferences(name: String, mode: Int): SharedPreferences = preferences
    fun getSystemService(name: String): Any = ConnectivityManager()
}

class SharedPreferences {
    private val values = mutableMapOf<String, Any>()
    fun getBoolean(key: String, fallback: Boolean): Boolean = values[key] as? Boolean ?: fallback
    fun getString(key: String, fallback: String?): String? = values[key] as? String ?: fallback
    fun getLong(key: String, fallback: Long): Long = values[key] as? Long ?: fallback
    fun edit(): Editor = Editor()
    inner class Editor {
        private val edits = mutableMapOf<String, Any?>()
        fun putBoolean(key: String, value: Boolean): Editor = apply { edits[key] = value }
        fun putString(key: String, value: String?): Editor = apply { edits[key] = value }
        fun putLong(key: String, value: Long): Editor = apply { edits[key] = value }
        fun remove(key: String): Editor = apply { edits[key] = null }
        fun commit(): Boolean { edits.forEach { (key, value) ->
            if (value == null) values.remove(key) else values[key] = value
        }; return true }
    }
}

class Intent(context: Context, target: Class<*>) {
    var action: String? = null
    var data: Uri? = null
    fun setPackage(name: String): Intent = this
    fun getIntExtra(name: String, fallback: Int): Int = fallback
}
