package android.content.pm

import java.io.OutputStream

class Signature(private val bytes: ByteArray) { fun toByteArray(): ByteArray = bytes }
class SigningInfo(val apkContentsSigners: Array<Signature>?)
class ApplicationInfo(val minSdkVersion: Int = 24)
class PackageInfo(val versionCode: Int, val versionName: String?, val signatures: Array<Signature>?) {
    val packageName = "shop.pushok.flow"
    val longVersionCode = versionCode.toLong()
    val signingInfo = SigningInfo(signatures)
    val applicationInfo = ApplicationInfo()
    val splitNames: Array<String>? = null
}
open class PackageManager {
    companion object { const val GET_SIGNATURES = 1; const val GET_SIGNING_CERTIFICATES = 2 }
    val packageInstaller = PackageInstaller()
    open fun getPackageInfo(name: String, flags: Int): PackageInfo = error("Set installed fixture")
    open fun getPackageArchiveInfo(path: String, flags: Int): PackageInfo? = error("Set archive fixture")
    fun canRequestPackageInstalls() = true
}
class PackageInstaller {
    companion object {
        const val EXTRA_SESSION_ID = "session_id"; const val EXTRA_STATUS = "status"
        const val STATUS_PENDING_USER_ACTION = -1; const val STATUS_SUCCESS = 0; const val STATUS_FAILURE = 1
    }
    class SessionParams(mode: Int) {
        companion object { const val MODE_FULL_INSTALL = 1; const val USER_ACTION_NOT_REQUIRED = 2 }
        fun setAppPackageName(name: String) { }
        fun setSize(size: Long) { }
        fun setRequireUserAction(action: Int) { }
    }
    class SessionInfo(val sessionId: Int)
    class Session : AutoCloseable {
        fun openWrite(name: String, offset: Long, size: Long): OutputStream = error("No install in this test")
        fun fsync(output: OutputStream) { }
        fun commit(sender: Any) { error("No install in this test") }
        override fun close() { }
    }
    val mySessions = emptyList<SessionInfo>()
    fun abandonSession(id: Int) { }
    fun getSessionInfo(id: Int): SessionInfo? = null
    fun createSession(params: SessionParams): Int = error("No install in this test")
    fun openSession(id: Int): Session = error("No install in this test")
}
