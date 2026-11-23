package android.util

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

class AtomicFile(val baseFile: File) {
    private val pending get() = File(baseFile.path + ".new")
    fun openRead(): FileInputStream = baseFile.inputStream()
    fun startWrite(): FileOutputStream = pending.outputStream()
    fun finishWrite(output: FileOutputStream) { output.fd.sync(); output.close(); check(pending.renameTo(baseFile)) }
    fun failWrite(output: FileOutputStream) { output.close(); pending.delete() }
    fun delete() { baseFile.delete(); pending.delete(); File(baseFile.path + ".bak").delete() }
}
