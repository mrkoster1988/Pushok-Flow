package shop.pushok.flow

fun main() {
    val defaults = setOf("vk.com", "ozon.ru")
    check(!BrowserProxyPolicy.shouldInstall(false, 35, defaults))
    check(!BrowserProxyPolicy.shouldInstall(false, 29, defaults))
    check(!BrowserProxyPolicy.shouldInstall(true, 28, defaults))
    check(!BrowserProxyPolicy.shouldInstall(true, 35, emptySet()))
    check(BrowserProxyPolicy.shouldInstall(true, 29, defaults))
    check(BrowserProxyPolicy.shouldInstall(true, 35, defaults))
    println("Browser proxy opt-in checks passed")
}
