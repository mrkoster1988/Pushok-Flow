package shop.pushok.flow

import java.util.UUID

/** Engine-scoped leases. All calls are made on Android's platform thread. */
class ProfileProtectionPolicy {
    private val leases = mutableSetOf<String>()
    private var owner: String? = null

    val required: Boolean get() = leases.isNotEmpty()

    fun attach(ownerId: String) {
        owner = ownerId
    }

    fun owns(ownerId: String): Boolean = owner == ownerId

    /** A previous Activity must not detach the handler of its replacement. */
    fun detach(ownerId: String): Boolean {
        if (!owns(ownerId)) return false
        owner = null
        return true
    }

    fun acquire(ownerId: String): String {
        check(owns(ownerId)) { "Profile screen is not attached" }
        var token: String
        do { token = UUID.randomUUID().toString() } while (token in leases)
        leases.add(token)
        return token
    }

    /** Duplicate or already-released tokens cannot release another editor. */
    fun release(ownerId: String, token: String) {
        check(owns(ownerId)) { "Profile screen is not attached" }
        leases.remove(token)
    }
}
