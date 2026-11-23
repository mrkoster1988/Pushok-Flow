package android.content

/** In-memory/durable preference views let failed commit tests model Android's uncertain result. */
open class Context {
    companion object { const val MODE_PRIVATE = 0 }
    val stores = mutableMapOf<String, SharedPreferences>()
    open val applicationContext: Context get() = this
    fun getSharedPreferences(name: String, mode: Int) = stores.getOrPut(name) { SharedPreferences() }
    fun recreated() = Context().also { copy ->
        stores.forEach { (name, preferences) ->
            copy.stores[name] = SharedPreferences().apply {
                values.putAll(preferences.durable)
                durable.putAll(preferences.durable)
            }
        }
    }
}

class SharedPreferences {
    val values = mutableMapOf<String, String>()
    val durable = mutableMapOf<String, String>()
    var failCommit = false
    var onCommit: (Map<String, String?>, Boolean) -> Unit = { _, _ -> }
    fun getString(key: String, default: String?): String? = values[key] ?: default
    fun edit() = Editor(this)
    class Editor(private val owner: SharedPreferences) {
        private val changes = mutableMapOf<String, String?>()
        fun remove(key: String) = apply { changes[key] = null }
        fun putString(key: String, value: String) = apply { changes[key] = value }
        fun commit(): Boolean {
            applyTo(owner.values) // SharedPreferences can change in memory before persistence fails.
            if (!owner.failCommit) applyTo(owner.durable)
            owner.onCommit(changes.toMap(), !owner.failCommit)
            return !owner.failCommit
        }
        private fun applyTo(target: MutableMap<String, String>) {
            changes.forEach { (key, value) -> if (value == null) target.remove(key) else target[key] = value }
        }
    }
}
