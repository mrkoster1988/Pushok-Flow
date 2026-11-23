package android.app

import android.content.ContentResolver
import android.content.Context
import android.content.Intent

open class Activity(resolver: ContentResolver) : Context(resolver) {
    var isDestroyed = false
    var isFinishing = false
    val opened = mutableListOf<Pair<Intent, Int>>()
    var openFailure: Exception? = null
    open fun startActivityForResult(intent: Intent, code: Int) {
        openFailure?.let { throw it }
        opened += intent to code
    }
    companion object { const val RESULT_OK = -1; const val RESULT_CANCELED = 0 }
}
