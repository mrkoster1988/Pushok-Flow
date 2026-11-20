package shop.pushok.flow

import android.content.Context

/** Local, bounded feedback counters. No hosts, package names, IPs or credentials. */
class LocalDecisionMemory(context: Context) {
    private val prefs = context.getSharedPreferences("pushok_ai_feedback_v1", Context.MODE_PRIVATE)
    private val allowed = setOf("connection", "routing", "server")

    fun record(category: String, helpful: Boolean): Map<String, Int> {
        require(category in allowed) { "Unknown feedback category" }
        val key = "${category}_${if (helpful) "helpful" else "unhelpful"}"
        val next = (prefs.getInt(key, 0).toLong() + 1).coerceAtMost(100000L).toInt()
        check(prefs.edit().putInt(key, next).commit()) { "Failed to save feedback" }
        return summary()
    }

    fun summary(): Map<String, Int> = allowed.flatMap { category ->
        listOf("helpful", "unhelpful").map { outcome ->
            val key = "${category}_${outcome}"
            key to prefs.getInt(key, 0)
        }
    }.toMap()

    fun clear() { check(prefs.edit().clear().commit()) { "Failed to clear feedback" } }
}