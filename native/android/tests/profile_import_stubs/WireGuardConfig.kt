package com.wireguard.config

import java.io.InputStream

class BadConfigException : Exception()
class Config {
    val peers: List<Any> = emptyList()
    companion object {
        // These tests use only HTTPS and VLESS. WireGuard grammar remains an
        // upstream parser gate in the real Android build, not a copied test parser.
        fun parse(input: InputStream): Config = error("Unexpected WireGuard fixture")
    }
}
