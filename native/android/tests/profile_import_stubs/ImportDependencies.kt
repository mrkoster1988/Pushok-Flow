package shop.pushok.flow

import java.io.InputStream

/** Coordination tests inject bytes only; real image/camera decoding has separate pinned tests. */
object ProfileQrImageReader {
    fun read(input: InputStream, cancelled: () -> Boolean): String = ProfileImportReader.read(input, cancelled)
}

class WireGuardQrActivity {
    companion object {
        const val EXTRA_REQUEST_CODE = "shop.pushok.flow.qr.request"
        const val EXTRA_TEXT = "shop.pushok.flow.qr.text"
        const val EXTRA_ERROR = "shop.pushok.flow.qr.error"
    }
}
