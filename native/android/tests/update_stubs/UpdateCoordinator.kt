package shop.pushok.flow

import android.content.Context

class MainActivity
internal class UpdateCoordinator {
    companion object {
        val instance = UpdateCoordinator()
        fun get(context: Context) = instance
    }
    var run: (UpdateWorkCancellation, Boolean, String?) -> String? = { _, _, _ -> null }
    fun runScheduled(work: UpdateWorkCancellation, reconcileOnly: Boolean, manifest: String?): String? =
        run(work, reconcileOnly, manifest)
}
