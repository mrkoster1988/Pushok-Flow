package android.os

object Build {
    val SUPPORTED_ABIS = arrayOf("arm64-v8a")
    object VERSION { const val SDK_INT = 24 }
    object VERSION_CODES { const val O = 26; const val P = 28; const val S = 31 }
}
class Bundle
class Looper { companion object { fun getMainLooper() = Looper() } }
class Handler(looper: Looper) { fun post(action: () -> Unit) { action() } }
object SystemClock { fun elapsedRealtime(): Long = System.nanoTime() / 1_000_000 }
