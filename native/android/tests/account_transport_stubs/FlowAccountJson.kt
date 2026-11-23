package shop.pushok.flow

import java.util.concurrent.atomic.AtomicInteger

/**
 * Android JSONObject is outside this pure JVM transport gate. The decoder is a
 * fixture hook, so these checks prove cancellation/ownership rather than JSON
 * conformance; the existing account policy checks cover parsed data contracts.
 */
internal object FlowAccountJson {
    val parses = AtomicInteger()
    @Volatile var decode: (ByteArray) -> Map<String, Any?> = { emptyMap() }
    fun encode(value: Map<String, Any?>): ByteArray = "{}".toByteArray()
    fun parse(bytes: ByteArray): Map<String, Any?> {
        parses.incrementAndGet()
        return decode(bytes)
    }
}
