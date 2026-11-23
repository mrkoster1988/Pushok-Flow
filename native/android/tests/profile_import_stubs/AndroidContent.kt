package android.content

import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.CancellationSignal

open class ContentResolver {
    open fun openAssetFileDescriptor(uri: Uri, mode: String, signal: CancellationSignal): AssetFileDescriptor? =
        error("Test provider not configured")
    companion object { const val SCHEME_CONTENT = "content" }
}

open class Context(val contentResolver: ContentResolver) {
    val applicationContext: Context get() = this
}

class ActivityNotFoundException : RuntimeException()
class ClipData(val itemCount: Int)
class Intent {
    constructor()
    constructor(action: String) { this.action = action }
    constructor(context: Context, type: Class<*>) { target = type.name }
    var action: String? = null
    var target: String? = null
    var type: String? = null
    var data: Uri? = null
    var clipData: ClipData? = null
    private val extras = mutableMapOf<String, Any?>()
    fun addCategory(category: String): Intent = this
    fun addFlags(flags: Int): Intent = this
    fun putExtra(name: String, value: String): Intent = apply { extras[name] = value }
    fun putExtra(name: String, value: Boolean): Intent = apply { extras[name] = value }
    fun putExtra(name: String, value: Int): Intent = apply { extras[name] = value }
    fun getStringExtra(name: String): String? = extras[name] as? String
    fun getIntExtra(name: String, defaultValue: Int): Int = extras[name] as? Int ?: defaultValue
    companion object {
        const val ACTION_OPEN_DOCUMENT = "android.intent.action.OPEN_DOCUMENT"
        const val CATEGORY_OPENABLE = "android.intent.category.OPENABLE"
        const val FLAG_GRANT_READ_URI_PERMISSION = 1
        const val EXTRA_ALLOW_MULTIPLE = "android.intent.extra.ALLOW_MULTIPLE"
    }
}
