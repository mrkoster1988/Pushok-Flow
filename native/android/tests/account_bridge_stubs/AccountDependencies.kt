package shop.pushok.flow

import android.content.Context
import java.util.concurrent.atomic.AtomicBoolean

/** The bridge test uses actual coordinator/manager/policy, with no Android key or network access. */
internal class FlowAccountStore(context: Context) : FlowAccountPersistence {
    override fun load() = FlowAccountPolicy.restore(FlowAccountPolicy.record(value))
    override fun save(value: FlowAccountRecord) { Companion.value = FlowAccountPolicy.restore(FlowAccountPolicy.record(value)) }
    companion object { @Volatile var value = FlowAccountRecord() }
}

internal class FlowAccountCall(private val current: () -> Boolean) {
    private val cancelled = AtomicBoolean(false)
    fun cancel() { cancelled.set(true) }
    fun check() { if (cancelled.get() || !current()) throw FlowAccountFailure("FLOW_INTERRUPTED") }
}

internal class FlowAccountClient(private val call: FlowAccountCall) : FlowAccountRemote {
    override fun request(method: String, path: String, token: String?, body: Map<String, Any?>?): FlowAccountResponse {
        call.check()
        val response = remote.request(method, path, token, body)
        call.check()
        return response
    }
    companion object {
        var remote = FlowAccountRemote { _, _, _, _ -> error("Unexpected test network operation") }
    }
}
