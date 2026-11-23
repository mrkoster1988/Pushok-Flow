package android.os

/**
 * The real pinned WireGuard Config/InetAddresses classes run on this JVM.
 * API 24 selects their own numeric-address fallback when Android's reflective
 * InetAddress.parseNumericAddress is absent. No configuration/IP grammar is stubbed.
 */
object Build {
    object VERSION { const val SDK_INT = 24 }
}
