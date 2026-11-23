package android.content.res

import java.io.Closeable
import java.io.InputStream

open class AssetFileDescriptor(
    private val input: () -> InputStream,
    private val onClose: () -> Unit = {},
) : Closeable {
    open fun createInputStream(): InputStream = input()
    override fun close() = onClose()
}
