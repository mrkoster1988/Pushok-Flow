package shop.pushok.flow

import java.net.InetAddress
import java.util.Locale

/** The bridge is an endpoint-only A/AAAA responder, never a general DNS forwarder. */
internal object XrayDnsWire {
    const val MAX_QUERY_BYTES = 4096
    const val MAX_RESPONSE_BYTES = 65535
    const val MAX_PLATFORM_ADDRESSES = 4096
    const val MAX_UDP_BYTES = 1232
    const val SERVFAIL = 2
    const val REFUSED = 5

    class Question internal constructor(
        val id: Int,
        val flags: Int,
        val hostname: String,
        val type: Int,
        val dnsClass: Int,
        val udpBytes: Int,
        internal val wire: ByteArray,
    ) {
        val supported: Boolean get() = dnsClass == 1 && (type == 1 || type == 28)
        override fun toString() = "XrayDnsQuestion(redacted)"
    }

    /** VlessProfile already performs IDNA conversion; no lookup or Unicode mapping here. */
    fun normalizeHostname(value: String): String? {
        if (value.length !in 1..254 || value.any { it.code > 127 }) return null
        val result = value.removeSuffix(".").lowercase(Locale.ROOT)
        if (result.length !in 1..253 || result.split('.').any { label ->
                label.length !in 1..63 || label.first() == '-' || label.last() == '-' ||
                    label.any { it !in 'a'..'z' && it !in '0'..'9' && it != '-' }
            }) return null
        return result
    }

    fun parse(packet: ByteArray): Question? {
        if (packet.size !in 12..MAX_QUERY_BYTES) return null
        val flags = u16(packet, 2)
        // Accept RD, AD and CD. Never echo AD: this bridge does not assert DNSSEC validation.
        if (flags and 0x0130.inv() != 0 || u16(packet, 4) != 1 ||
            u16(packet, 6) != 0 || u16(packet, 8) != 0 || u16(packet, 10) > 1) return null
        var position = 12
        val labels = ArrayList<String>()
        while (true) {
            if (position >= packet.size) return null
            val length = packet[position++].toInt() and 255
            if (length == 0) break
            // Reject pointers and reserved label encodings instead of traversing attacker-controlled offsets.
            if (length > 63 || position + length > packet.size) return null
            val text = StringBuilder(length)
            repeat(length) {
                val character = packet[position++].toInt() and 255
                if (character !in 45..122 ||
                    (character !in 65..90 && character !in 97..122 && character !in 48..57 && character != 45)) return null
                text.append(character.toChar())
            }
            labels.add(text.toString())
            if (position - 12 >= 255) return null
        }
        if (position - 12 > 255 || position + 4 > packet.size) return null
        val hostname = normalizeHostname(labels.joinToString(".")) ?: return null
        val type = u16(packet, position)
        val dnsClass = u16(packet, position + 2)
        position += 4
        val questionEnd = position
        var udpBytes = 512
        if (u16(packet, 10) == 1) {
            // Go's resolver sends EDNS0, including an optional bounded TLV options area.
            // Read its advertised UDP size, then discard it; no additional payload is forwarded.
            if (position + 11 > packet.size || packet[position].toInt() != 0 ||
                u16(packet, position + 1) != 41) return null
            udpBytes = u16(packet, position + 3).coerceIn(512, MAX_UDP_BYTES)
            if (packet[position + 5].toInt() != 0 || packet[position + 6].toInt() != 0 ||
                u16(packet, position + 7) and 0x7fff != 0) return null
            val optionLength = u16(packet, position + 9)
            position += 11
            val end = position + optionLength
            if (end != packet.size) return null
            while (position < end) {
                if (position + 4 > end) return null
                val length = u16(packet, position + 2)
                position += 4
                if (position + length > end) return null
                position += length
            }
        }
        if (position != packet.size) return null
        return Question(u16(packet, 0), flags, hostname, type, dnsClass, udpBytes,
            packet.copyOfRange(12, questionEnd))
    }

    /** Malformed packets get only a small header, without reflecting unparsed data. */
    fun refused(packet: ByteArray): ByteArray? {
        if (packet.size < 12) return null
        return ByteArray(12).also {
            put16(it, 0, u16(packet, 0))
            put16(it, 2, 0x8080 or (u16(packet, 2) and 0x0110) or REFUSED)
        }
    }

    fun response(question: Question, addresses: List<InetAddress>, tcp: Boolean, error: Int = 0): ByteArray {
        if (error != 0) return header(question, error, 0, false)
        if (!question.supported) return header(question, REFUSED, 0, false)
        if (addresses.isEmpty() || addresses.size > MAX_PLATFORM_ADDRESSES) {
            return header(question, SERVFAIL, 0, false)
        }
        val size = if (question.type == 1) 4 else 16
        val records = ArrayList<ByteArray>()
        for (address in addresses) {
            val bytes = address.address
            if (bytes.size != 4 && bytes.size != 16) return header(question, SERVFAIL, 0, false)
            if (bytes.size == size) records.add(bytes)
        }
        val base = 12 + question.wire.size
        val recordBytes = 12 + size
        if (base.toLong() + records.size.toLong() * recordBytes > MAX_RESPONSE_BYTES) {
            // Never silently lose addresses in the TCP result or advertise an unfulfillable retry.
            return header(question, SERVFAIL, 0, false)
        }
        val limit = if (tcp) MAX_RESPONSE_BYTES else question.udpBytes
        val count = records.size.coerceAtMost((limit - base).coerceAtLeast(0) / recordBytes)
        val result = header(question, 0, count, count != records.size, count * recordBytes)
        var position = base
        for (index in 0 until count) {
            put16(result, position, 0xc00c) // The sole, validated question name at offset 12.
            put16(result, position + 2, question.type)
            put16(result, position + 4, 1)
            // Four TTL bytes remain zero: Android owns caching and network-specific resolution.
            put16(result, position + 10, size)
            records[index].copyInto(result, position + 12)
            position += recordBytes
        }
        return result
    }

    private fun header(question: Question, error: Int, count: Int, truncated: Boolean, extra: Int = 0): ByteArray =
        ByteArray(12 + question.wire.size + extra).also {
            put16(it, 0, question.id)
            put16(it, 2, 0x8080 or (question.flags and 0x0110) or
                (if (truncated) 0x0200 else 0) or error)
            put16(it, 4, 1)
            put16(it, 6, count)
            question.wire.copyInto(it, 12)
        }

    private fun u16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 255) shl 8) or (bytes[offset + 1].toInt() and 255)

    private fun put16(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = (value ushr 8).toByte()
        bytes[offset + 1] = value.toByte()
    }
}
