package shop.pushok.flow

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.net.InetAddress

private fun bytes(hex: String): ByteArray = hex.filterNot(Char::isWhitespace).chunked(2).map { it.toInt(16).toByte() }.toByteArray()
private fun word(value: ByteArray, offset: Int): Int = ((value[offset].toInt() and 255) shl 8) or (value[offset + 1].toInt() and 255)

private fun question(type: Int = 1): ByteArray = bytes(
    "123401000001000000000000 066c6f6f6b7570 076578616d706c65 00 00010001"
).also { it[it.size - 3] = type.toByte() }

private fun edns(query: ByteArray, udp: Int = 1232, options: ByteArray = byteArrayOf()): ByteArray {
    val out = ByteArrayOutputStream()
    DataOutputStream(out).use {
        it.write(query.copyOf().also { copy -> copy[11] = 1 })
        it.writeByte(0)
        it.writeShort(41)
        it.writeShort(udp)
        it.writeInt(0)
        it.writeShort(options.size)
        it.write(options)
    }
    return out.toByteArray()
}

private fun v4(last: Int): InetAddress = InetAddress.getByAddress(byteArrayOf(203.toByte(), 0, 113, last.toByte()))
private fun v6(last: Int): InetAddress = InetAddress.getByAddress(
    bytes("20010db8000000000000000000000000").also { it[14] = (last ushr 8).toByte(); it[15] = last.toByte() })

private fun wireGoldenAnswers() {
    val query = checkNotNull(XrayDnsWire.parse(question()))
    check(query.hostname == "lookup.example" && query.type == 1 && query.dnsClass == 1)
    check(!query.toString().contains("lookup"))
    val answer = XrayDnsWire.response(query, listOf(v4(7)), tcp = false)
    val expected = bytes("123481800001000100000000 066c6f6f6b7570 076578616d706c65 00 00010001 c00c00010001000000000004 cb007107")
    check(answer.contentEquals(expected)) { "A response differs from independent DNS wire fixture" }
    val aaaa = checkNotNull(XrayDnsWire.parse(question(28)))
    val expected6 = bytes("123481800001000100000000 066c6f6f6b7570 076578616d706c65 00 001c0001 c00c001c0001000000000010 20010db8000000000000000000000007")
    check(XrayDnsWire.response(aaaa, listOf(v6(7)), tcp = true).contentEquals(expected6))
    for ((selected, addresses) in listOf(query to listOf(v6(8)), aaaa to listOf(v4(8)))) {
        val emptyFamily = XrayDnsWire.response(selected, addresses, tcp = false)
        check(word(emptyFamily, 2) and 15 == 0 && word(emptyFamily, 6) == 0)
    }
    val mixed = listOf(v6(1), v4(1), v6(2), v4(2))
    check(word(XrayDnsWire.response(query, mixed, true), 6) == 2)
    check(word(XrayDnsWire.response(aaaa, mixed, true), 6) == 2)
    check(word(XrayDnsWire.response(query, emptyList(), true), 2) and 15 == XrayDnsWire.SERVFAIL)
    check(word(XrayDnsWire.response(query, listOf(v4(1)), true, XrayDnsWire.REFUSED), 2) and 15 == 5)
    val txt = checkNotNull(XrayDnsWire.parse(question(16)))
    check(!txt.supported && word(XrayDnsWire.response(txt, listOf(v4(1)), true), 2) and 15 == 5)
    val otherClass = question().also { it[it.lastIndex] = 3 }
    check(!checkNotNull(XrayDnsWire.parse(otherClass)).supported)
    val ad = question().also { it[3] = 0x30 }
    val adAnswer = XrayDnsWire.response(checkNotNull(XrayDnsWire.parse(ad)), listOf(v4(7)), true)
    check(word(adAnswer, 2) and 0x20 == 0 && word(adAnswer, 2) and 0x10 != 0)
}

private fun wireEdnsAndTruncation() {
    val padding = bytes("000c00080000000000000000")
    val query = edns(question(28), options = padding)
    val parsed = checkNotNull(XrayDnsWire.parse(query))
    check(parsed.udpBytes == 1232)
    val records = (1..100).map(::v6)
    val udp = XrayDnsWire.response(parsed, records, false)
    check(udp.size <= 1232 && word(udp, 2) and 0x200 != 0 && word(udp, 6) == 42)
    check(word(udp, 10) == 0) { "EDNS options must not be reflected or forwarded" }
    val noOpt = checkNotNull(XrayDnsWire.parse(question(28)))
    val short = XrayDnsWire.response(noOpt, records, false)
    check(short.size <= 512 && word(short, 2) and 0x200 != 0 && word(short, 6) == 17)
    val tcp = XrayDnsWire.response(parsed, records, true)
    check(tcp.size == 32 + 100 * 28 && word(tcp, 2) and 0x200 == 0 && word(tcp, 6) == 100)
    for (index in records.indices) {
        val start = 32 + index * 28
        check(tcp.copyOfRange(start + 6, start + 10).all { it == 0.toByte() }) { "TTL must be zero" }
        check(tcp.copyOfRange(start + 12, start + 28).contentEquals(records[index].address))
    }
    check(checkNotNull(XrayDnsWire.parse(edns(question(), 128))).udpBytes == 512)
    check(checkNotNull(XrayDnsWire.parse(edns(question(), 65535))).udpBytes == 1232)
    val dnssecOk = edns(question()).also { it[it.lastIndex - 3] = 0x80.toByte() }
    check(XrayDnsWire.parse(dnssecOk) != null)
    val tooMany = List(XrayDnsWire.MAX_PLATFORM_ADDRESSES + 1) { v4(1) }
    check(word(XrayDnsWire.response(noOpt, tooMany, true), 2) and 15 == 2)
    val tooLarge = (1..2340).map(::v6)
    check(word(XrayDnsWire.response(noOpt, tooLarge, true), 2) and 15 == 2)
}

private fun wireRejectsMalformedMessages() {
    val good = question()
    for (length in good.indices) check(XrayDnsWire.parse(good.copyOf(length)) == null)
    for (offset in listOf(4, 6, 8, 10)) {
        val altered = good.copyOf().also { it[offset + 1] = if (offset == 4 || offset == 10) 2 else 1 }
        check(XrayDnsWire.parse(altered) == null)
    }
    for (mask in listOf(0x8000, 0x0800, 0x0400, 0x0200, 0x0080, 0x0040, 1)) {
        val malformed = good.copyOf()
        malformed[2] = (mask ushr 8).toByte(); malformed[3] = mask.toByte()
        check(XrayDnsWire.parse(malformed) == null)
    }
    val compressionCycle = good.copyOf().also { it[12] = 0xc0.toByte(); it[13] = 12 }
    check(XrayDnsWire.parse(compressionCycle) == null)
    for (value in listOf(64, 0x80, 0xff)) {
        check(XrayDnsWire.parse(good.copyOf().also { it[12] = value.toByte() }) == null)
    }
    for (value in listOf(0, '.', '/', '_', '\u00e9').map { if (it is Char) it.code else it as Int }) {
        check(XrayDnsWire.parse(good.copyOf().also { it[13] = value.toByte() }) == null)
    }
    check(XrayDnsWire.parse(good + byteArrayOf(0)) == null)
    check(XrayDnsWire.parse(ByteArray(XrayDnsWire.MAX_QUERY_BYTES + 1)) == null)
    val opt = edns(good)
    for (length in good.size until opt.size) check(XrayDnsWire.parse(opt.copyOf(length)) == null)
    check(XrayDnsWire.parse(opt.copyOf().also { it[good.size + 2] = 1 }) == null) // Additional A, not OPT.
    check(XrayDnsWire.parse(opt.copyOf().also { it[good.size] = 0xc0.toByte() }) == null)
    check(XrayDnsWire.parse(opt.copyOf().also { it[good.size + 6] = 1 }) == null) // Unsupported EDNS version.
    check(XrayDnsWire.parse(opt.copyOf().also { it[good.size + 5] = 1 }) == null) // Extended query RCODE.
    check(XrayDnsWire.parse(opt.copyOf().also { it[good.size + 8] = 1 }) == null) // Reserved EDNS flags.
    check(XrayDnsWire.parse(edns(good, options = bytes("000c0004 00"))) == null)
    check(XrayDnsWire.parse(edns(good, options = bytes("000c00"))) == null)
    check(XrayDnsWire.parse(opt + byteArrayOf(0)) == null)
    val refused = checkNotNull(XrayDnsWire.refused(compressionCycle))
    check(refused.size == 12 && word(refused, 0) == 0x1234 && word(refused, 2) and 15 == 5 && word(refused, 4) == 0)
    check(XrayDnsWire.refused(byteArrayOf(1, 2)) == null)
}

private fun wireHostnameAllowlist() {
    check(XrayDnsWire.normalizeHostname("LoOkUp.Example.") == "lookup.example")
    check(XrayDnsWire.normalizeHostname("xn--e1afmkfd.xn--p1ai") == "xn--e1afmkfd.xn--p1ai")
    for (invalid in listOf("", ".", "lookup..example", "lookup.example..", " lookup.example", "lookup.example\n",
        "*.example", "lookup.example/", "-lookup.example", "lookup-.example", "lookup_1.example", "пример.рф",
        "a".repeat(64) + ".example", "a.".repeat(128))) check(XrayDnsWire.normalizeHostname(invalid) == null)
    val max = List(3) { "a".repeat(63) }.joinToString(".") + "." + "b".repeat(61)
    check(max.length == 253 && XrayDnsWire.normalizeHostname(max + ".") == max)
}

fun main() {
    wireGoldenAnswers()
    wireEdnsAndTruncation()
    wireRejectsMalformedMessages()
    wireHostnameAllowlist()
    println("Xray DNS wire: golden A/AAAA, EDNS0, bounds, compression rejection and hostname checks passed")
}
