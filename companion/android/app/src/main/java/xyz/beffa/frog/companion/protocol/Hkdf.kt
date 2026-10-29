package xyz.beffa.frog.companion.protocol

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** HKDF-SHA256 (RFC 5869), written on top of HmacSHA256. */
object Hkdf {
    private const val HASH_LEN = 32

    fun extract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val key = if (salt.isEmpty()) ByteArray(HASH_LEN) else salt
        return hmac(key, ikm)
    }

    fun expand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 0..255 * HASH_LEN) { "HKDF length out of range" }
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(prk, "HmacSHA256")) }
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            mac.update(previous)
            mac.update(info)
            mac.update(counter.toByte())
            previous = mac.doFinal()
            val n = minOf(previous.size, length - offset)
            System.arraycopy(previous, 0, out, offset, n)
            offset += n
            counter++
        }
        return out
    }

    fun derive(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray =
        expand(extract(salt, ikm), info, length)

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }
}
