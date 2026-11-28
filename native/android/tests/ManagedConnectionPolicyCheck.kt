package shop.pushok.flow

private fun sample(
    profile: String = "primary", source: String = "account-feed",
    candidates: List<String> = listOf("primary", "reserve", "reserve-2"),
    elapsed: Long = 10_000L, now: Long = 100L, expires: Long = 1_000L,
    authorized: Boolean = true, network: Boolean = true,
    probe: String = "https", guarded: Boolean = true,
) = ManagedFailoverPolicy.Sample(profile, source, candidates, expires, now, elapsed,
    authorized, network, probe, guarded)

private fun cacheIsABoundedLease() {
    for (code in listOf("SUBSCRIPTION_NETWORK_ERROR", "SUBSCRIPTION_TIMEOUT")) {
        check(ManagedConnectionPolicy.canUseCached(code, "active", 200, 100))
        for (state in listOf("expired", "revoked", "unknown")) {
            check(!ManagedConnectionPolicy.canUseCached(code, state, 200, 100))
        }
        for (expiry in listOf(null, 0L, 99L, 100L)) {
            check(!ManagedConnectionPolicy.canUseCached(code, "active", expiry, 100))
        }
        check(!ManagedConnectionPolicy.canUseCached(code, "active", 200, 0))
    }
    for (code in listOf("SUBSCRIPTION_AUTH_REQUIRED", "SUBSCRIPTION_INVALID", "SUBSCRIPTION_TLS_ERROR",
        "SUBSCRIPTION_STORE_FAILED", "SUBSCRIPTION_INTERRUPTED", "VPN_ACTIVE", "PROFILE_CHANGED")) {
        check(!ManagedConnectionPolicy.canUseCached(code, "active", 200, 100))
    }
}

private fun twoFailuresAndGuardAreRequired() {
    val policy = ManagedFailoverPolicy()
    val token = policy.start("primary", "account-feed")
    check(policy.observe(token, sample(guarded = false)) == null)
    check(policy.observe(token, sample(elapsed = 12_000L, guarded = false)) == null)
    check(policy.status == "checking") // Fast duplicate did not become a second failure.
    check(policy.observe(token, sample(elapsed = 20_000L, guarded = false)) == null)
    check(policy.status == "guard_required")
    val change = policy.observe(token, sample(elapsed = 30_000L))!!
    check(change.fromProfileId == "primary" && change.toProfileId == "reserve")
    check(change.subscriptionId == "account-feed" && policy.accepts(change))
    check(policy.observe(token, sample(elapsed = 500_000L)) == null) // Pending switch cannot queue another.
    policy.complete(change, true)
    check(policy.status == "checking") // An UP acknowledgement is not a traffic test.
    check(policy.observe(token, sample(profile = "reserve", elapsed = 40_000L, probe = "ok")) == null)
    check(policy.status == "ready")
    check(policy.observe(token, sample(profile = "reserve", elapsed = 50_000L)) == null)
    check(policy.observe(token, sample(profile = "reserve", elapsed = 60_000L)) == null)
    check(policy.status == "checking") // Cooldown, even after two failures.
    val second = policy.observe(token, sample(profile = "reserve", elapsed = 100_000L))!!
    check(second.toProfileId == "reserve-2")
    policy.complete(second, true)
    check(policy.observe(token, sample(profile = "reserve-2", elapsed = 180_000L)) == null)
    check(policy.observe(token, sample(profile = "reserve-2", elapsed = 190_000L)) == null)
    check(policy.status == "exhausted") // Neither primary nor an attempted reserve loops back.
}

private fun lossOfAuthorityOrNetworkDoesNotChangeNodes() {
    val timedOut = ManagedFailoverPolicy()
    val timeoutToken = timedOut.start("primary", "account-feed")
    check(timedOut.observe(timeoutToken, sample(probe = "timeout")) == null)
    check(timedOut.observe(timeoutToken, sample(elapsed = 20_000L, probe = "timeout")) != null)
    for (probe in listOf("unknown", "unrecognized", "ok")) {
        val policy = ManagedFailoverPolicy()
        val token = policy.start("primary", "account-feed")
        repeat(5) { check(policy.observe(token, sample(elapsed = 10_000L * (it + 1), probe = probe)) == null) }
    }
    for (kind in listOf("network", "authority", "expiry", "missing-reserve")) {
        val policy = ManagedFailoverPolicy()
        val token = policy.start("primary", "account-feed")
        repeat(5) {
            check(policy.observe(token, sample(elapsed = 10_000L * (it + 1),
                network = kind != "network", authorized = kind != "authority",
                expires = if (kind == "expiry") 100 else 1_000,
                candidates = if (kind == "missing-reserve") listOf("primary") else listOf("primary", "reserve"))) == null)
        }
    }
    val policy = ManagedFailoverPolicy()
    val token = policy.start("primary", "account-feed")
    check(policy.observe(token, sample(source = "another-account")) == null)
    check(!policy.current(token))
}

private fun stopAndNewIntentInvalidateLateResults() {
    val policy = ManagedFailoverPolicy()
    val first = policy.start("primary", "account-feed")
    policy.observe(first, sample())
    val stale = policy.observe(first, sample(elapsed = 20_000L))!!
    policy.stop()
    check(!policy.accepts(stale))
    policy.complete(stale, true)
    check(policy.status == "idle")
    val next = policy.start("primary", "account-feed")
    check(next != first)
    check(policy.observe(first, sample(elapsed = 90_000L)) == null)
    policy.complete(stale, true)
    check(policy.status == "checking" && policy.current(next))
    check(policy.observe(next, sample(profile = "manual-choice")) == null)
    check(!policy.current(next))
}

private fun deferredPreflightDoesNotConsumeReserve() {
    val policy = ManagedFailoverPolicy()
    val token = policy.start("primary", "account-feed")
    policy.observe(token, sample())
    val first = policy.observe(token, sample(elapsed = 20_000L))!!
    policy.defer(first)
    check(!policy.accepts(first) && policy.status == "checking")
    check(policy.observe(token, sample(elapsed = 30_000L)) == null)
    val retry = policy.observe(token, sample(elapsed = 40_000L))!!
    check(retry.toProfileId == "reserve") // Gate contention never touched this reserve.
    policy.complete(retry, true)
    policy.observe(token, sample(profile = "reserve", elapsed = 50_000L))
    check(policy.observe(token, sample(profile = "reserve", elapsed = 60_000L)) == null)
    val second = policy.observe(token, sample(profile = "reserve", elapsed = 110_000L))!!
    policy.stop()
    policy.defer(second)
    check(policy.status == "idle")
}

private fun blockingActivationCannotOutliveItsAuthority() {
    for (cause in listOf("stop", "expiry", "same-account-new-epoch")) {
        var valid = true
        var up = false
        var stopped = false
        val result = runCatching {
            ManagedActivation.connect(validate = { check(valid) { cause } }, activate = {
                up = true
                valid = false // The account executor/user/timer can change it during backend UP.
                true
            }, deactivate = { up = false; stopped = true })
        }
        check(result.isFailure && stopped && !up)
    }
    var activated = false
    check(runCatching {
        ManagedActivation.connect(validate = { error("expired before UP") },
            activate = { activated = true; true }, deactivate = { })
    }.isFailure)
    check(!activated)
    var valid = true
    var stopped = false
    check(runCatching {
        ManagedActivation.connect(validate = { check(valid) }, activate = {
            valid = false
            error("backend failed after creating a TUN")
        }, deactivate = { stopped = true })
    }.isFailure)
    check(stopped)
    check(ManagedActivation.connect(validate = { }, activate = { true },
        deactivate = { error("valid activation must stay up") }))
}

private fun serviceHoldIsBoundedAndCannotReviveAfterCancellation() {
    val acknowledged = ManagedServiceHold()
    acknowledged.connected()
    check(acknowledged.awaitReady({ true }))
    acknowledged.disconnected()
    acknowledged.connected() // A late callback cannot revive a lost binding.
    check(!acknowledged.ready && !acknowledged.awaitReady({ true }))
    check(!ManagedServiceHold().awaitReady({ false }))
    val beginning = System.nanoTime()
    check(!ManagedServiceHold().awaitReady({ true }, timeoutMs = 10L))
    check(System.nanoTime() - beginning < java.util.concurrent.TimeUnit.SECONDS.toNanos(1))
    val wanted = java.util.concurrent.atomic.AtomicBoolean(true)
    val waiting = ManagedServiceHold()
    val entered = java.util.concurrent.CountDownLatch(1)
    val done = java.util.concurrent.CountDownLatch(1)
    val result = java.util.concurrent.atomic.AtomicBoolean(true)
    val worker = Thread {
        try { result.set(waiting.awaitReady({ entered.countDown(); wanted.get() })) }
        finally { done.countDown() }
    }
    worker.start()
    check(entered.await(1, java.util.concurrent.TimeUnit.SECONDS))
    wanted.set(false)
    check(done.await(1, java.util.concurrent.TimeUnit.SECONDS))
    check(!result.get())
    worker.join(1_000)
}

private fun onlyAnActualBuilderMaySupplyServiceIdentity() {
    val identity = ManagedServiceIdentity<Any>()
    val appService = Any()
    val replacement = Any()
    identity.beginBuild()
    check(identity.current() == null) // Always-on base service does not call our builder.
    identity.builtBy(appService)
    check(identity.matches(appService))
    identity.beginBuild()
    check(!identity.matches(appService)) // A later base/unknown UP cannot reuse an old proof.
    identity.builtBy(replacement)
    identity.destroyed(appService)
    check(identity.matches(replacement)) // Late old-service destruction cannot erase the new one.
    identity.destroyed(replacement)
    check(identity.current() == null)
}

fun main() {
    cacheIsABoundedLease()
    twoFailuresAndGuardAreRequired()
    lossOfAuthorityOrNetworkDoesNotChangeNodes()
    stopAndNewIntentInvalidateLateResults()
    deferredPreflightDoesNotConsumeReserve()
    blockingActivationCannotOutliveItsAuthority()
    serviceHoldIsBoundedAndCannotReviveAfterCancellation()
    onlyAnActualBuilderMaySupplyServiceIdentity()
    println("Managed connection cache, guarded failover, cooldown and Stop-race checks passed")
}
