package android.net

class Uri private constructor(private val value: String) {
    val scheme: String? get() = java.net.URI(value).scheme
    override fun toString() = value
    companion object { fun parse(value: String) = Uri(value) }
}
