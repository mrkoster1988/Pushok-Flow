package android.app

import android.content.Context
import android.content.Intent

open class Activity : Context() {
    var isFinishing = false
    var isDestroyed = false
    var rejectTelegram = false
    var rejectBrowser = false
    val attempts = mutableListOf<Intent>()
    val opened = mutableListOf<Intent>()
    open fun startActivity(intent: Intent) {
        attempts += intent
        if ((rejectTelegram && intent.uri.value.startsWith("tg:")) ||
            (rejectBrowser && intent.uri.value.startsWith("https:"))) throw android.content.ActivityNotFoundException()
        opened += intent
    }
}
