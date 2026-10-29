package xyz.beffa.frog.companion.protocol

import java.nio.ByteBuffer
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * One direction of AES-256-GCM framing (docs/companion-protocol.md section 4).
 * Nonce = 4 zero bytes || u64 big-endian counter; no AAD; output = ciphertext || 16-byte tag.
 * Not thread-safe: callers serialize use so counters match wire order.
 */
class FrameCipher(key: ByteArray) {
    private val keySpec = SecretKeySpec(key.copyOf(), "AES")
    var counter: Long = 0
        private set

    init {
        require(key.size == 32) { "AES-256 key must be 32 bytes" }
    }

    fun seal(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(TAG_BITS, nonce(counter)))
        val out = cipher.doFinal(plaintext)
        counter++
        return out
    }

    /** Throws [ProtocolException] if the frame fails to authenticate. */
    fun open(sealed: ByteArray): ByteArray {
        if (sealed.size < TAG_BYTES) throw ProtocolException("frame shorter than tag")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(TAG_BITS, nonce(counter)))
        val out = try {
            cipher.doFinal(sealed)
        } catch (e: AEADBadTagException) {
            throw ProtocolException("frame failed to decrypt", e)
        } catch (e: java.security.GeneralSecurityException) {
            throw ProtocolException("frame failed to decrypt", e)
        }
        counter++
        return out
    }

    companion object {
        const val TAG_BITS = 128
        const val TAG_BYTES = 16

        fun nonce(counter: Long): ByteArray =
            ByteBuffer.allocate(12).putInt(0).putLong(counter).array()
    }
}

object FrameLimits {
    const val MIN_SEALED = 16
    const val MAX_SEALED = 268_436_480 // 256 MiB + 1 KiB

    fun check(n: Long) {
        if (n < MIN_SEALED || n > MAX_SEALED) throw ProtocolException("bad frame length $n")
    }

    /** The 4-byte big-endian length prefix followed by [sealed]. */
    fun frame(sealed: ByteArray): ByteArray =
        ByteBuffer.allocate(4 + sealed.size).putInt(sealed.size).put(sealed).array()

    fun readLength(prefix: ByteArray): Long {
        require(prefix.size == 4)
        return ByteBuffer.wrap(prefix).int.toLong() and 0xFFFF_FFFFL
    }
}
