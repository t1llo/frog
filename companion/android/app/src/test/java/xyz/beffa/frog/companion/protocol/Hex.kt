package xyz.beffa.frog.companion.protocol

fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

fun hex(s: String): ByteArray = s.replace(" ", "").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
