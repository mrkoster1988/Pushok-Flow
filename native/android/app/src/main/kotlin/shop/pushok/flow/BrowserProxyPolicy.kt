package shop.pushok.flow

/** Site routing must not replace Android's normal network proxy implicitly. */
internal object BrowserProxyPolicy {
    fun shouldInstall(enabled: Boolean, sdk: Int, selected: Set<String>): Boolean =
        enabled && sdk >= 29 && selected.isNotEmpty()
}
