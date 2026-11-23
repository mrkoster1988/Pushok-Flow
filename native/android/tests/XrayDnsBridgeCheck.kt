package shop.pushok.flow

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

private val local = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
private fun ip(last: Int) = InetAddress.getByAddress(byteArrayOf(203.toByte(), 0, 113, last.toByte()))
private fun ip6(last: Int) = InetAddress.getByAddress(ByteArray(16).also { it[0] = 0x20; it[1] = 1; it[2] = 0x0d; it[3] = 0xb8.toByte(); it[15] = last.toByte() })
private fun u16(packet: ByteArray, offset: Int) = ((packet[offset].toInt() and 255) shl 8) or (packet[offset + 1].toInt() and 255)
private fun await(latch: CountDownLatch, description: String) = check(latch.await(4, TimeUnit.SECONDS)) { description }

private fun ignoreInterrupts(entered: CountDownLatch, release: CountDownLatch) {
    entered.countDown()
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
    while (release.count != 0L) {
        check(System.nanoTime() < deadline) { "Test resolver was never released" }
        try { release.await(100, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { }
    }
}

private fun packet(id: Int, host: String = "lookup.example", type: Int = 1, edns: Boolean = false): ByteArray {
    val bytes = ByteArrayOutputStream()
    DataOutputStream(bytes).use { out ->
        out.writeShort(id); out.writeShort(0x0100); out.writeShort(1)
        out.writeShort(0); out.writeShort(0); out.writeShort(if (edns) 1 else 0)
        for (label in host.split('.')) { val encoded = label.toByteArray(Charsets.US_ASCII); out.writeByte(encoded.size); out.write(encoded) }
        out.writeByte(0); out.writeShort(type); out.writeShort(1)
        if (edns) { out.writeByte(0); out.writeShort(41); out.writeShort(1232); out.writeInt(0); out.writeShort(0) }
    }
    return bytes.toByteArray()
}

private fun port(bridge: XrayDnsBridge) = bridge.endpoint.substringAfterLast(':').toInt()
private fun udp(bridge: XrayDnsBridge) = DatagramSocket(InetSocketAddress(local, 0)).apply {
    connect(InetSocketAddress(local, port(bridge))); soTimeout = 4_000
}
private fun send(socket: DatagramSocket, request: ByteArray) = socket.send(DatagramPacket(request, request.size))
private fun receive(socket: DatagramSocket): ByteArray {
    val datagram = DatagramPacket(ByteArray(65536), 65536)
    socket.receive(datagram)
    return datagram.data.copyOf(datagram.length)
}
private fun exchange(socket: DatagramSocket, request: ByteArray): ByteArray { send(socket, request); return receive(socket) }

private fun tcp(bridge: XrayDnsBridge, request: ByteArray): ByteArray = Socket().use { socket ->
    socket.connect(InetSocketAddress(local, port(bridge)), 1_000); socket.soTimeout = 4_000
    val out = DataOutputStream(socket.getOutputStream())
    out.writeShort(request.size); out.write(request); out.flush()
    val input = DataInputStream(socket.getInputStream())
    val result = ByteArray(input.readUnsignedShort()); input.readFully(result)
    check(input.read() == -1) { "Bridge must close each bounded TCP exchange" }
    result
}

private fun addresses(response: ByteArray, id: Int, type: Int): List<ByteArray> {
    check(u16(response, 0) == id && u16(response, 2) and 15 == 0 && u16(response, 4) == 1)
    var position = 12
    while (response[position].toInt() != 0) position += 1 + (response[position].toInt() and 255)
    position += 5
    return List(u16(response, 6)) {
        check(u16(response, position) == 0xc00c && u16(response, position + 2) == type && u16(response, position + 4) == 1)
        check((position + 6 until position + 10).all { index -> response[index] == 0.toByte() })
        val length = u16(response, position + 10)
        response.copyOfRange(position + 12, position + 12 + length).also { position += 12 + length }
    }.also { check(position == response.size) }
}

private class Target(
    override val hostname: String = "lookup.example",
    private val valid: () -> Boolean = { true },
    private val lookup: () -> List<InetAddress>,
) : XrayDnsTarget {
    override fun isCurrent() = valid()
    override fun resolve() = lookup()
}

private fun actualLoopbackAllowlistAndFamilies() {
    val calls = AtomicInteger()
    val target = AtomicReference<XrayDnsTarget?>(Target("LoOkUp.Example.") {
        calls.incrementAndGet(); listOf(ip(7), ip6(8), ip(9), ip6(10))
    })
    XrayDnsBridge { target.get() }.use { bridge ->
        check(bridge.endpoint.startsWith("127.0.0.1:") && port(bridge) in 1..65535)
        udp(bridge).use { socket ->
            val a = exchange(socket, packet(1, "LOOKUP.example", edns = true))
            val ipv4 = addresses(a, 1, 1)
            check(ipv4.size == 2 && ipv4.zip(listOf(ip(7), ip(9))).all { (actual, expected) -> actual.contentEquals(expected.address) })
            val aaaa = tcp(bridge, packet(2, type = 28, edns = true))
            val ipv6 = addresses(aaaa, 2, 28)
            check(ipv6.size == 2 && ipv6.zip(listOf(ip6(8), ip6(10))).all { (actual, expected) -> actual.contentEquals(expected.address) })
            check(calls.get() == 2)
            for (request in listOf(packet(3, "lookup.example.attacker"), packet(4, type = 16),
                packet(5).also { it[12] = 0xc0.toByte(); it[13] = 12 })) {
                check(u16(exchange(socket, request), 2) and 15 == 5)
            }
            check(calls.get() == 2) { "Unallowed or malformed DNS must never reach the platform" }
            target.set(Target { listOf(ip6(1)) })
            check(addresses(exchange(socket, packet(6)), 6, 1).isEmpty())
            target.set(Target { throw UnknownHostException("synthetic-secret-error") })
            val failure = exchange(socket, packet(7))
            check(u16(failure, 2) and 15 == 2 && !String(failure).contains("synthetic-secret"))
            target.set(null)
            check(u16(exchange(socket, packet(8)), 2) and 15 == 5)
        }
    }
}

private fun udpTruncationAndFullTcp() {
    val all = (1..100).map { n -> ip6(n) }
    XrayDnsBridge { Target { all } }.use { bridge ->
        udp(bridge).use { socket ->
            val short = exchange(socket, packet(11, type = 28))
            check(short.size <= 512 && u16(short, 2) and 0x200 != 0)
            val edns = exchange(socket, packet(12, type = 28, edns = true))
            check(edns.size <= 1232 && u16(edns, 2) and 0x200 != 0)
            val full = tcp(bridge, packet(13, type = 28, edns = true))
            val received = addresses(full, 13, 28)
            check(received.size == all.size && u16(full, 2) and 0x200 == 0)
            check(received.zip(all).all { (actual, expected) -> actual.contentEquals(expected.address) })
        }
    }
}

private fun stuckResolversKeepTheirCapacity() {
    val entered = CountDownLatch(2)
    val release = CountDownLatch(1)
    val finished = CountDownLatch(2)
    val calls = AtomicInteger()
    val admissions = AtomicInteger()
    val hooks = XrayDnsBridge.TestHooks(afterAdmission = { admissions.incrementAndGet() }, afterResolve = { finished.countDown() })
    val target = Target {
        if (calls.incrementAndGet() <= 2) ignoreInterrupts(entered, release)
        listOf(ip(11))
    }
    val bridge = XrayDnsBridge(300L, 300L, { target }, hooks)
    try {
        udp(bridge).use { socket ->
            send(socket, packet(21)); send(socket, packet(22))
            await(entered, "Two platform resolutions did not start")
            val timedOut = listOf(receive(socket), receive(socket))
            check(timedOut.map { u16(it, 0) }.toSet() == setOf(21, 22) && timedOut.all { u16(it, 2) and 15 == 2 })
            check(release.count == 1L)
            val saturated = exchange(socket, packet(23))
            check(u16(saturated, 0) == 23 && u16(saturated, 2) and 15 == 2)
            check(calls.get() == 2 && admissions.get() == 2) { "Deadline must not free still-running platform capacity" }
            release.countDown()
            await(finished, "Resolvers did not really finish after release")
            check(addresses(exchange(socket, packet(24)), 24, 1).single().contentEquals(ip(11).address))
        }
    } finally { release.countDown(); bridge.close() }
}

private fun networkEpochAndLateSendGuards() {
    val epoch = AtomicLong(1)
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val oldFinished = CountDownLatch(1)
    val target = AtomicReference<XrayDnsTarget?>(Target(valid = { epoch.get() == 1L }) {
        ignoreInterrupts(entered, release); listOf(ip(1))
    })
    val bridge = XrayDnsBridge(3_000L, 400L, { target.get() },
        XrayDnsBridge.TestHooks(afterResolve = { if (release.count == 0L) oldFinished.countDown() }))
    try {
        udp(bridge).use { socket ->
            send(socket, packet(31)); await(entered, "Old network lookup did not start")
            epoch.set(2)
            target.set(Target(valid = { epoch.get() == 2L }) { listOf(ip(2)) })
            check(addresses(exchange(socket, packet(32)), 32, 1).single().contentEquals(ip(2).address))
            check(release.count == 1L) { "New network must not wait for the old resolver" }
            release.countDown(); await(oldFinished, "Old lookup did not exit")
            check(addresses(exchange(socket, packet(33)), 33, 1).single().contentEquals(ip(2).address))
            socket.soTimeout = 150
            try { receive(socket); error("A stale network reply escaped") } catch (_: SocketTimeoutException) { }
        }
    } finally { release.countDown(); bridge.close() }

    val active = AtomicBoolean(true)
    val sendReached = CountDownLatch(1)
    val allowSend = CountDownLatch(1)
    val first = AtomicBoolean(true)
    val guarded = Target(valid = active::get) { listOf(ip(5)) }
    val delivery = XrayDnsBridge(3_000L, 400L, { guarded }, XrayDnsBridge.TestHooks(beforeSend = {
        if (first.compareAndSet(true, false)) { sendReached.countDown(); await(allowSend, "Delivery was never released") }
    }))
    try {
        udp(delivery).use { socket ->
            send(socket, packet(34)); await(sendReached, "Response did not reach delivery gate")
            active.set(false); allowSend.countDown()
            socket.soTimeout = 200
            try { receive(socket); error("Response passed a revoked delivery guard") } catch (_: SocketTimeoutException) { }
        }
    } finally { allowSend.countDown(); delivery.close() }
}

private fun slowTcpCannotOccupyDnsWorkers() {
    val calls = AtomicInteger()
    val bridge = XrayDnsBridge(500L, 250L, { Target { calls.incrementAndGet(); listOf(ip(17)) } })
    val slow = List(4) { Socket().apply { connect(InetSocketAddress(local, port(bridge)), 1_000); soTimeout = 2_000 } }
    try {
        // Half a TCP length prefix is enough to exercise slow clients without any DNS work.
        slow.forEach { it.getOutputStream().write(0); it.getOutputStream().flush() }
        udp(bridge).use { socket ->
            check(addresses(exchange(socket, packet(41)), 41, 1).single().contentEquals(ip(17).address))
        }
        check(calls.get() == 1)
        slow.forEach { check(it.getInputStream().read() == -1) { "Slow TCP client was not expired" } }
        check(addresses(tcp(bridge, packet(42)), 42, 1).size == 1)
    } finally { slow.forEach { it.close() }; bridge.close() }
}

private fun completedUdpFloodHasBoundedPending() {
    val readerReached = CountDownLatch(1)
    val releaseReader = CountDownLatch(1)
    val firstBatchDone = CountDownLatch(1)
    val first = AtomicBoolean(true)
    val finished = Semaphore(0)
    val calls = AtomicInteger()
    val admissions = AtomicInteger()
    val hooks = XrayDnsBridge.TestHooks(
        beforeUdpBatch = { if (first.compareAndSet(true, false)) { readerReached.countDown(); await(releaseReader, "UDP batch never released") } },
        afterUdpBatch = { firstBatchDone.countDown() },
        afterAdmission = { admissions.incrementAndGet(); check(finished.tryAcquire(4, TimeUnit.SECONDS)) },
        afterResolve = { finished.release() },
    )
    val bridge = XrayDnsBridge(3_000L, 400L, { Target { calls.incrementAndGet(); listOf(ip(20)) } }, hooks)
    try {
        udp(bridge).use { socket ->
            send(socket, packet(100)); await(readerReached, "UDP batch was not held")
            for (id in 101..131) send(socket, packet(id))
            releaseReader.countDown(); await(firstBatchDone, "UDP flood batch did not complete")
            // Each lookup is already finished before the next admission. Completion delivery
            // is held naturally until the actual 32-packet reader batch ends. This reproduced
            // the gap where free worker permits let the pending collection grow without bound.
            check(calls.get() == 16 && admissions.get() == 16) { "Completed lookups bypassed the independent pending bound" }
            val responses = List(32) { receive(socket) }
            check(responses.map { u16(it, 0) }.toSet() == (100..131).toSet())
            check(responses.all { u16(it, 2) and 15 in setOf(0, 2) })
            check(responses.count { u16(it, 2) and 15 == 2 } >= 16)
        }
    } finally { releaseReader.countDown(); bridge.close() }
}

private fun closeDoesNotWaitForPlatformDns() {
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val finished = CountDownLatch(1)
    val bridge = XrayDnsBridge(3_000L, 400L, { Target { ignoreInterrupts(entered, release); listOf(ip(30)) } },
        XrayDnsBridge.TestHooks(afterResolve = { finished.countDown() }))
    val socket = Socket().apply { connect(InetSocketAddress(local, port(bridge)), 1_000); soTimeout = 2_000 }
    try {
        val query = packet(51)
        DataOutputStream(socket.getOutputStream()).apply { writeShort(query.size); write(query); flush() }
        await(entered, "TCP resolver did not start")
        bridge.close()
        check(socket.getInputStream().read() == -1) { "Bridge close waited for the platform resolver" }
        check(release.count == 1L)
    } finally { release.countDown(); socket.close(); bridge.close() }
    await(finished, "Closed bridge resolver did not finish after explicit release")
}

fun main() {
    actualLoopbackAllowlistAndFamilies()
    udpTruncationAndFullTcp()
    stuckResolversKeepTheirCapacity()
    networkEpochAndLateSendGuards()
    slowTcpCannotOccupyDnsWorkers()
    completedUdpFloodHasBoundedPending()
    closeDoesNotWaitForPlatformDns()
    println("Xray DNS bridge: 7 real loopback UDP/TCP, epoch, deadline, overload and shutdown groups passed")
}
