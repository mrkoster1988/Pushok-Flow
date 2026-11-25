package shop.pushok.flow

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import kotlin.concurrent.thread

/** Forward standard HTTP proxy requests. CONNECT carries the browser's original TLS session. */
internal class DirectBrowserProxy(
    private val domains: Set<String>,
    private val connect: (host: String, port: Int, direct: Boolean) -> Socket,
) : Closeable {
    private val server = ServerSocket().apply {
        bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 32)
    }
    val port: Int get() = server.localPort
    private val slots = Semaphore(64)
    private val workers = Executors.newCachedThreadPool()
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    init {
        thread(name = "Flow browser proxy", isDaemon = true) {
            try {
                while (!server.isClosed) {
                    val socket = server.accept()
                    if (!slots.tryAcquire()) { socket.close(); continue }
                    sockets.add(socket)
                    if (server.isClosed) { socket.close(); break }
                    workers.execute {
                        try { socket.use { serve(it) } }
                        catch (_: Exception) { }
                        finally { sockets.remove(socket); slots.release() }
                    }
                }
            } catch (_: Exception) { close() }
        }
    }

    private fun serve(client: Socket) {
        client.soTimeout = 8000
        val input = BufferedInputStream(client.getInputStream())
        val out = client.getOutputStream()
        val req = try { readRequest(input) } catch (_: Exception) {
            out.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".toByteArray()); return
        }
        val direct = domains.any { req.host == it || req.host.endsWith("."+it) }
        val remote = try { connect(req.host, req.port, direct) } catch (_: Exception) {
            out.write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".toByteArray()); return
        }
        sockets.add(remote)
        try {
            remote.use { upstream ->
                if (server.isClosed) return
                client.soTimeout = 180000
                upstream.soTimeout = 180000
                val dest = upstream.getOutputStream()
                if (req.tunnel) {
                    out.write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
                    workers.execute {
                        try { input.copyTo(dest); upstream.shutdownOutput() } catch (_: Exception) { }
                    }
                } else {
                    dest.write(req.head.toByteArray(Charsets.ISO_8859_1))
                    var remaining = req.length
                    val buffer = ByteArray(8192)
                    while (remaining > 0) {
                        val n = input.read(buffer, 0, minOf(remaining, buffer.size.toLong()).toInt())
                        if (n < 0) throw EOFException()
                        dest.write(buffer,0,n); remaining -= n
                    }
                }
                upstream.getInputStream().copyTo(out)
            }
        } finally { sockets.remove(remote) }
    }

    override fun close() {
        runCatching { server.close() }
        sockets.forEach { runCatching { it.close() } }
        workers.shutdownNow()
    }

    private data class Request(val host:String,val port:Int,val tunnel:Boolean,val head:String,val length:Long)

    private fun readRequest(source: InputStream): Request {
        val raw=ByteArrayOutputStream()
        var tail=0
        while (tail!=0x0d0a0d0a) {
            val v=source.read()
            if(v<0 || raw.size()>=32768) throw IOException("header")
            raw.write(v);tail=(tail shl 8) or v
        }
        val lines=raw.toString("ISO-8859-1").removeSuffix("\r\n\r\n").split("\r\n")
        val first=lines.first().split(' ')
        require(first.size==3 && first[0].matches(Regex("[A-Z]+")) && first[2] in setOf("HTTP/1.0","HTTP/1.1"))
        val tunnel=first[0]=="CONNECT"
        val uri=URI(if(tunnel) "http://"+first[1] else first[1])
        require(uri.scheme.equals("http",true) && uri.rawUserInfo==null && uri.rawFragment==null)
        require(!tunnel || (uri.rawPath.isNullOrEmpty() && uri.rawQuery==null))
        val host=requireNotNull(uri.host).removePrefix("[").removeSuffix("]").trimEnd('.').lowercase(Locale.ROOT)
        val port=if(uri.port==-1) (if(tunnel) 443 else 80) else uri.port
        require(host.isNotEmpty() && port in 1..65535)
        if(tunnel) return Request(host,port,true,"",0)
        val headers=lines.drop(1).map {
            val split=it.indexOf(':');require(split>0)
            val k=it.substring(0,split);val v=it.substring(split+1).trim()
            require(k.matches(Regex("[!#$%&'*+.^_`|~a-zA-Z0-9-]+")) && v.none { ch->ch<' ' && ch!='\t' })
            k.lowercase(Locale.ROOT) to v
        }
        require(headers.none { it.first=="transfer-encoding" || it.first=="expect" })
        val sizes=headers.filter { it.first=="content-length" }
        require(sizes.size<=1)
        val length=sizes.firstOrNull()?.second?.toLong()?:0L;require(length>=0)
        val omit=setOf("host","connection","proxy-connection","proxy-authorization","upgrade","keep-alive")+
            headers.filter { it.first=="connection" }.flatMap { it.second.lowercase(Locale.ROOT).split(',').map(String::trim) }
        val path=uri.rawPath.takeUnless { it.isNullOrEmpty() }?:"/"
        val head=buildString {
            append(first[0]+" "+path+(uri.rawQuery?.let { "?"+it }?:"")+" HTTP/1.1\r\nHost: "+uri.rawAuthority+"\r\n")
            headers.filterNot { it.first in omit }.forEach { append(it.first+": "+it.second+"\r\n") }
            append("Connection: close\r\n\r\n")
        }
        return Request(host,port,false,head,length)
    }
}
