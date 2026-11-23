package shop.pushok.flow

import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketAddress
import java.nio.Buffer
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** An immutable physical-network/session snapshot. The guards and supplier must not block. */
interface XrayDnsTarget {
    val hostname: String
    fun isCurrent(): Boolean
    fun resolve(): List<InetAddress>
}

/**
 * Create once per :xray process and give endpoint to SetDNS once, before runXray.
 * Only the target changes. There is no external DNS socket: the adapter resolves
 * with Android Network.getAllByName, including that network's Private DNS policy.
 * No user-provided question, profile field or platform exception is logged.
 */
class XrayDnsBridge internal constructor(
    private val resolveTimeoutMs: Long,
    private val clientTimeoutMs: Long,
    private val currentTarget: () -> XrayDnsTarget?,
    private val testHooks: TestHooks? = null,
) : Closeable {
    constructor(currentTarget: () -> XrayDnsTarget?) : this(2_000L, 1_000L, currentTarget)

    /** Deterministic scheduling only; normal process-owned instances have no hooks. */
    internal class TestHooks(
        val beforeUdpBatch: () -> Unit = {},
        val afterUdpBatch: () -> Unit = {},
        val afterAdmission: () -> Unit = {},
        val afterResolve: () -> Unit = {},
        val beforeSend: () -> Unit = {},
    )

    private class Client(val channel: SocketChannel, var deadline: Long) {
        var input = ByteBuffer.allocate(2)
        var readingLength = true
        var output: ByteBuffer? = null
        var guard: XrayDnsTarget? = null
        var pending: Pending? = null
        lateinit var key: SelectionKey
    }

    private class Destination(val remote: SocketAddress? = null, val client: Client? = null)

    private class Pending(
        val question: XrayDnsWire.Question,
        val target: XrayDnsTarget,
        val destination: Destination,
        val deadline: Long,
    ) {
        val active = AtomicBoolean(true)
    }

    private class Completion(val pending: Pending, val response: ByteArray?)

    private val closed = AtomicBoolean()
    private val permits = Semaphore(RESOLVERS)
    private val completions = ArrayBlockingQueue<Completion>(RESOLVERS * 2)
    private val resolverSequence = AtomicInteger()
    private val resolverPool = ThreadPoolExecutor(
        RESOLVERS, RESOLVERS, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(RESOLVERS),
        { task -> Thread(task, "pushok-xray-dns-resolve-${resolverSequence.incrementAndGet()}").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy(),
    )
    private val selector: Selector
    private val udp: DatagramChannel
    private val tcp: ServerSocketChannel
    // These collections and all network reads/writes belong exclusively to the selector thread.
    private val clients = LinkedHashSet<Client>()
    private val pending = LinkedHashSet<Pending>()
    val endpoint: String

    init {
        require(resolveTimeoutMs in 1..10_000 && clientTimeoutMs in 1..10_000)
        val sockets = openSockets()
        tcp = sockets.first
        udp = sockets.second
        var openedSelector: Selector? = null
        try {
            val created = Selector.open()
            openedSelector = created
            tcp.register(created, SelectionKey.OP_ACCEPT)
            udp.register(created, SelectionKey.OP_READ)
            selector = created
        } catch (_: Exception) {
            try { openedSelector?.close() } catch (_: Exception) { }
            try { tcp.close() } catch (_: Exception) { }
            try { udp.close() } catch (_: Exception) { }
            resolverPool.shutdown()
            throw IOException("XRAY_DNS_UNAVAILABLE")
        }
        endpoint = "127.0.0.1:${tcp.socket().localPort}"
        Thread(::eventLoop, "pushok-xray-dns-io").apply { isDaemon = true; start() }
    }

    /** Non-blocking: never wait for an uncooperative Android resolver during shutdown. */
    override fun close() {
        if (closed.compareAndSet(false, true)) wakeup()
    }

    override fun toString() = "XrayDnsBridge(loopback)"

    private fun eventLoop() {
        val packet = ByteBuffer.allocate(XrayDnsWire.MAX_QUERY_BYTES + 1)
        try {
            while (!closed.get()) {
                selector.select(50)
                drainCompletions()
                expire()
                val ready = selector.selectedKeys().iterator()
                while (ready.hasNext() && !closed.get()) {
                    val key = ready.next()
                    ready.remove()
                    if (!key.isValid) continue
                    try {
                        when (key.channel()) {
                            udp -> receiveDatagrams(packet)
                            tcp -> acceptClients()
                            else -> {
                                val client = key.attachment() as Client
                                if (key.isReadable) readClient(client)
                                if (key.isValid && key.isWritable) writeClient(client)
                            }
                        }
                    } catch (_: Exception) {
                        (key.attachment() as? Client)?.let(::closeClient)
                    }
                }
            }
        } catch (_: Exception) {
            // The caller has no fallback resolver. A failed bridge fails closed.
        } finally {
            closed.set(true)
            pending.forEach { it.active.set(false) }
            pending.clear()
            clients.toList().forEach(::closeClient)
            try { udp.close() } catch (_: Exception) { }
            try { tcp.close() } catch (_: Exception) { }
            try { selector.close() } catch (_: Exception) { }
            resolverPool.shutdown()
            while (true) (completions.poll() ?: break).response?.fill(0)
        }
    }

    private fun receiveDatagrams(packet: ByteBuffer) {
        // A UDP flood must not prevent processing TCP, deadlines or completed DNS work.
        testHooks?.beforeUdpBatch?.invoke()
        try {
            repeat(IO_BATCH) {
                clearBuffer(packet)
                val remote = udp.receive(packet) ?: return
                if ((remote as? InetSocketAddress)?.address?.isLoopbackAddress != true) return@repeat
                flipBuffer(packet)
                val request = ByteArray(packet.remaining())
                packet.get(request)
                submit(request, Destination(remote = remote))
            }
        } finally { testHooks?.afterUdpBatch?.invoke() }
    }

    private fun acceptClients() {
        repeat(IO_BATCH) {
            val channel = tcp.accept() ?: return
            if (clients.size >= MAX_CLIENTS ||
                (channel.remoteAddress as? InetSocketAddress)?.address?.isLoopbackAddress != true) {
                try { channel.close() } catch (_: Exception) { }
                return@repeat
            }
            try {
                channel.configureBlocking(false)
                channel.socket().tcpNoDelay = true
                val client = Client(channel, elapsedMs() + clientTimeoutMs)
                client.key = channel.register(selector, SelectionKey.OP_READ, client)
                clients.add(client)
            } catch (_: Exception) { try { channel.close() } catch (_: Exception) { } }
        }
    }

    private fun readClient(client: Client) {
        // At most a two-byte length and one bounded body; no blocking readFully loop.
        repeat(2) {
            if (client.channel.read(client.input) < 0) { closeClient(client); return }
            if (client.input.hasRemaining()) return
            flipBuffer(client.input)
            if (client.readingLength) {
                val length = client.input.short.toInt() and 65535
                if (length !in 12..XrayDnsWire.MAX_QUERY_BYTES) { closeClient(client); return }
                client.readingLength = false
                client.input = ByteBuffer.allocate(length)
            } else {
                val request = ByteArray(client.input.remaining())
                client.input.get(request)
                client.key.interestOps(0)
                submit(request, Destination(client = client))
                return
            }
        }
    }

    private fun submit(request: ByteArray, destination: Destination) {
        val question = XrayDnsWire.parse(request)
        if (question == null) {
            val refused = XrayDnsWire.refused(request)
            if (refused == null) destination.client?.let(::closeClient)
            else send(destination, refused, null)
            return
        }
        val target = try { currentTarget() } catch (_: Exception) { null }
        val host = try { target?.hostname?.let(XrayDnsWire::normalizeHostname) } catch (_: Exception) { null }
        if (!question.supported || target == null || question.hostname != host || !current(target)) {
            send(destination, XrayDnsWire.response(question, emptyList(), destination.client != null, XrayDnsWire.REFUSED), null)
            return
        }
        if (pending.size >= MAX_PENDING || !permits.tryAcquire()) {
            send(destination, XrayDnsWire.response(question, emptyList(), destination.client != null, XrayDnsWire.SERVFAIL), target)
            return
        }
        val task = Pending(question, target, destination, elapsedMs() + resolveTimeoutMs)
        pending.add(task)
        destination.client?.let { it.pending = task; it.deadline = task.deadline + clientTimeoutMs }
        try {
            resolverPool.execute {
                var response: ByteArray? = null
                try {
                    response = try {
                        if (!task.active.get() || !current(target)) null
                        else {
                            val addresses = target.resolve()
                            if (!task.active.get() || !current(target)) null
                            else XrayDnsWire.response(question, addresses, destination.client != null)
                        }
                    } catch (_: Throwable) {
                        if (task.active.get() && current(target)) {
                            XrayDnsWire.response(question, emptyList(), destination.client != null, XrayDnsWire.SERVFAIL)
                        } else null
                    }
                } finally {
                    // Keep admission until the real platform call ends, even after a client
                    // timeout/cancellation. Release before delivery; the small executor queue
                    // bridges only finished workers' epilogues, never extra unresolved lookups.
                    permits.release()
                    if (closed.get() || !completions.offer(Completion(task, response))) {
                        task.active.set(false)
                        response?.fill(0)
                    }
                    testHooks?.afterResolve?.invoke()
                    wakeup()
                }
            }
            testHooks?.afterAdmission?.invoke()
        } catch (_: RejectedExecutionException) {
            permits.release()
            pending.remove(task)
            task.active.set(false)
            destination.client?.pending = null
            send(destination, XrayDnsWire.response(question, emptyList(), destination.client != null, XrayDnsWire.SERVFAIL), target)
        }
    }

    private fun drainCompletions() {
        while (true) {
            val completed = completions.poll() ?: return
            val task = completed.pending
            val accepted = pending.remove(task) && task.active.getAndSet(false)
            task.destination.client?.let { if (it.pending === task) it.pending = null }
            if (!accepted || !current(task.target)) {
                completed.response?.fill(0)
                if (accepted) task.destination.client?.let(::closeClient)
                continue
            }
            val response = if (elapsedMs() >= task.deadline) {
                completed.response?.fill(0)
                XrayDnsWire.response(task.question, emptyList(), task.destination.client != null, XrayDnsWire.SERVFAIL)
            } else completed.response
            if (response == null) task.destination.client?.let(::closeClient)
            else send(task.destination, response, task.target)
        }
    }

    private fun expire() {
        val now = elapsedMs()
        val iterator = pending.iterator()
        while (iterator.hasNext()) {
            val task = iterator.next()
            val valid = current(task.target)
            if (valid && task.active.get() && now < task.deadline) continue
            iterator.remove()
            task.active.set(false)
            task.destination.client?.let { if (it.pending === task) it.pending = null }
            if (valid) send(task.destination,
                XrayDnsWire.response(task.question, emptyList(), task.destination.client != null, XrayDnsWire.SERVFAIL), task.target)
            else task.destination.client?.let(::closeClient)
        }
        for (client in clients.toList()) {
            if (now >= client.deadline || client.guard?.let { !current(it) } == true) closeClient(client)
        }
    }

    private fun send(destination: Destination, response: ByteArray, target: XrayDnsTarget?) {
        testHooks?.beforeSend?.invoke()
        if (closed.get() || (target != null && !current(target))) {
            response.fill(0)
            destination.client?.let(::closeClient)
            return
        }
        val client = destination.client
        if (client != null) {
            if (client !in clients || !client.key.isValid) { response.fill(0); return }
            client.output = ByteBuffer.allocate(response.size + 2).putShort(response.size.toShort()).put(response).apply { flipBuffer(this) }
            response.fill(0)
            client.guard = target
            client.deadline = elapsedMs() + clientTimeoutMs
            client.key.interestOps(SelectionKey.OP_WRITE)
        } else {
            try {
                // Non-blocking send: a full local UDP buffer drops the reply, never stalls the receiver.
                udp.send(ByteBuffer.wrap(response), destination.remote)
            } catch (_: Exception) { } finally { response.fill(0) }
        }
    }

    private fun writeClient(client: Client) {
        if (client.guard?.let { !current(it) } == true) { closeClient(client); return }
        val response = client.output ?: return
        client.channel.write(response)
        if (!response.hasRemaining()) closeClient(client)
    }

    private fun closeClient(client: Client) {
        clients.remove(client)
        client.pending?.let { it.active.set(false); pending.remove(it) }
        client.pending = null
        client.output?.array()?.fill(0)
        client.output = null
        try { client.key.cancel() } catch (_: Exception) { }
        try { client.channel.close() } catch (_: Exception) { }
    }

    private fun current(target: XrayDnsTarget): Boolean =
        !closed.get() && try { target.isCurrent() } catch (_: Exception) { false }

    private fun wakeup() { try { selector.wakeup() } catch (_: Exception) { } }

    private companion object {
        const val RESOLVERS = 2
        const val MAX_PENDING = 16
        const val MAX_CLIENTS = 4
        const val IO_BATCH = 32
        val LOOPBACK: InetAddress = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))

        fun elapsedMs(): Long = System.nanoTime() / 1_000_000L

        // Use Android's original Buffer descriptors, including when compiled on a newer JDK.
        fun clearBuffer(buffer: Buffer) { buffer.clear() }
        fun flipBuffer(buffer: Buffer) { buffer.flip() }

        fun openSockets(): Pair<ServerSocketChannel, DatagramChannel> {
            // TCP's ephemeral port can already be occupied by an unrelated UDP socket.
            // Retry only a fixed number of local binds, before publishing the endpoint.
            repeat(4) {
                var tcp: ServerSocketChannel? = null
                var udp: DatagramChannel? = null
                try {
                    tcp = ServerSocketChannel.open()
                    tcp.configureBlocking(false)
                    tcp.socket().bind(InetSocketAddress(LOOPBACK, 0), MAX_CLIENTS)
                    udp = DatagramChannel.open()
                    udp.configureBlocking(false)
                    udp.socket().bind(InetSocketAddress(LOOPBACK, tcp.socket().localPort))
                    return tcp to udp
                } catch (_: Exception) {
                    try { tcp?.close() } catch (_: Exception) { }
                    try { udp?.close() } catch (_: Exception) { }
                }
            }
            throw IOException("XRAY_DNS_UNAVAILABLE")
        }
    }
}
