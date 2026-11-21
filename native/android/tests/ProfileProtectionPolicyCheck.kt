package shop.pushok.flow

private fun rejected(action: () -> Unit) {
    check(runCatching(action).exceptionOrNull() is IllegalStateException)
}

fun main() {
    val policy = ProfileProtectionPolicy()
    check(!policy.required)
    rejected { policy.acquire("first-window") }
    policy.attach("first-window")
    val first = policy.acquire("first-window")
    val second = policy.acquire("first-window")
    check(first != second)
    check(policy.required)

    // Closing one editor, closing it twice, or an unrelated stale token must
    // not expose another editor still using the same Flutter window.
    policy.release("first-window", first)
    policy.release("first-window", first)
    policy.release("first-window", "00000000-0000-0000-0000-000000000000")
    check(policy.required)

    // Retained-engine recreation keeps protection. Late cleanup or calls from
    // the destroyed Activity cannot remove the replacement's handler or lease.
    policy.attach("replacement-window")
    check(policy.required)
    check(!policy.detach("first-window"))
    rejected { policy.release("first-window", second) }
    rejected { policy.acquire("first-window") }
    check(policy.owns("replacement-window"))
    check(policy.required)

    check(policy.detach("replacement-window"))
    check(!policy.detach("replacement-window"))
    check(policy.required)
    rejected { policy.release("replacement-window", second) }
    policy.attach("third-window")
    policy.release("third-window", second)
    check(!policy.required)

    // A fresh engine has no old leases; tokens from the old engine are inert.
    val fresh = ProfileProtectionPolicy()
    fresh.attach("new-engine-window")
    val current = fresh.acquire("new-engine-window")
    fresh.release("new-engine-window", second)
    check(fresh.required)
    fresh.release("new-engine-window", current)
    check(!fresh.required)
    println("ProfileProtectionPolicy executable checks passed")
}
