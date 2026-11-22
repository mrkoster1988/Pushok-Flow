package shop.pushok.flow

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

fun main() {
    fun invalid(block: () -> Unit) {
        try { block(); error("Expected a rejected response") }
        catch (_: UpdateFailure) { }
    }
    check(!UpdateAutomationPolicy.appendResponse(400, 1000, 200, null, 1000))
    check(UpdateAutomationPolicy.appendResponse(400, 1000, 206, "bytes 400-999/1000", 600))
    check(UpdateAutomationPolicy.appendResponse(400, 1000, 206, "bytes 400-999/1000", -1))
    invalid { UpdateAutomationPolicy.appendResponse(400, 1000, 206, "bytes 0-999/1000", 1000) }
    invalid { UpdateAutomationPolicy.appendResponse(400, 1000, 206, "bytes 400-999/2000", 600) }
    invalid { UpdateAutomationPolicy.appendResponse(400, 1000, 206, "bytes 400-999/1000", 1000) }
    invalid { UpdateAutomationPolicy.appendResponse(400, 1000, 206, "bytes */1000", -1) }
    invalid { UpdateAutomationPolicy.appendResponse(400, 1000, 200, null, 600) }
    invalid { UpdateAutomationPolicy.appendResponse(0, 1000, 206, "bytes 0-999/1000", 1000) }
    invalid { UpdateAutomationPolicy.appendResponse(400, 1000, 416, null, 0) }
    invalid { UpdateAutomationPolicy.appendResponse(400, 1000, 206, "bytes 400-999999999999999999999/1000", -1) }

    fun reason(sdk: Int = 31, permission: Boolean = true, confirmation: Boolean = false,
        connection: Boolean = false, foreground: Boolean = false, enabled: Boolean = true) =
        UpdateAutomationPolicy.waitingReason(enabled, sdk, permission, confirmation, connection, foreground)
    check(reason() == null)
    check(reason(sdk = 30) == "unsupported")
    check(reason(permission = false) == "permission")
    check(reason(confirmation = true) == "confirmation")
    check(reason(connection = true) == "connection")
    check(reason(foreground = true) == "foreground")
    check(reason(enabled = false, connection = true) == null)
    check(UpdateAutomationPolicy.retry("UPDATE_INTERRUPTED", 4))
    check(!UpdateAutomationPolicy.retry("UPDATE_INTERRUPTED", 5))
    check(!UpdateAutomationPolicy.retry("UPDATE_SIGNATURE_MISMATCH", 0))
    check(!UpdateAutomationPolicy.retry("UPDATE_INSTALL_FAILED", 0))

    // Permission dialogs/CONNECTING already hold this lease before Android exposes a VPN network.
    val gate = UpdateAutomationGuard()
    check(gate.beginConnection(1))
    check(!gate.reserveInstall { false })
    gate.endConnection(1)
    gate.observeTunnel(true)
    check(!gate.reserveInstall { false })
    gate.observeTunnel(false)
    check(!gate.reserveInstall { true }) // Unknown/other-app VPN also defers.
    val activity = Any()
    val qrActivity = Any()
    gate.foreground(activity, true)
    gate.foreground(qrActivity, true)
    gate.foreground(activity, false)
    check(!gate.reserveInstall { false }) // QR stays foreground after the main Activity pauses.
    gate.foreground(qrActivity, false)
    check(gate.reserveInstall { false })
    check(!gate.beginConnection(2))
    gate.foreground(activity, true)
    check(!gate.commitIfSafe({ false }) { error("Must not commit after foreground resume") })
    gate.foreground(activity, false)
    gate.releaseInstall()

    // The final commit and a simultaneous connect acquisition are one linearized decision.
    check(gate.reserveInstall { false })
    val committing = CountDownLatch(1)
    val finishCommit = CountDownLatch(1)
    val connectionDone = CountDownLatch(1)
    var allowedConnect = true
    val installer = Thread {
        check(gate.commitIfSafe({ false }) {
            committing.countDown()
            check(finishCommit.await(2, TimeUnit.SECONDS))
        })
    }
    installer.start()
    check(committing.await(2, TimeUnit.SECONDS))
    val connection = Thread { allowedConnect = gate.beginConnection(3); connectionDone.countDown() }
    connection.start()
    check(!connectionDone.await(50, TimeUnit.MILLISECONDS))
    finishCommit.countDown()
    installer.join(2000)
    connection.join(2000)
    check(!installer.isAlive && !connection.isAlive && !allowedConnect)
    gate.releaseInstall() // Terminal callback / successfully abandoned waiting session.
    check(gate.beginConnection(4))
    gate.endConnection(4)
    gate.restoreInstallReservation() // Recreated process honors a durable committed session.
    check(!gate.beginConnection(5))
    println("Update automation policy checks passed")
}
