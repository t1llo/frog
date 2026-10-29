package xyz.beffa.frog.companion.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/** Shared cross-platform vector; the Mac side computes the same values. */
class TestVectorTest {
    private val secret = ByteArray(32) { (it + 1).toByte() } // 0x01..0x20
    private val clientNonce = ByteArray(32) { 0xAA.toByte() }
    private val serverNonce = ByteArray(32) { 0xBB.toByte() }

    @Test
    fun vector() {
        val keys = SessionKeys.derive(secret, clientNonce, serverNonce)
        val plaintext = MessageCodec.encodeRaw("{\"type\":\"ping\"}".toByteArray(Charsets.UTF_8), ByteArray(0))
        assertEquals(plaintext.hex(), MessageCodec.encode(Message.Ping).hex())
        val sealed = FrameCipher(keys.c2sKey).seal(plaintext)

        println("FROG_VECTOR c2sKey=${keys.c2sKey.hex()}")
        println("FROG_VECTOR s2cKey=${keys.s2cKey.hex()}")
        println("FROG_VECTOR plaintext=${plaintext.hex()}")
        println("FROG_VECTOR sealed=${sealed.hex()}")

        assertEquals(EXPECTED_C2S, keys.c2sKey.hex())
        assertEquals(EXPECTED_S2C, keys.s2cKey.hex())
        assertEquals(EXPECTED_SEALED, sealed.hex())
    }

    // Values from docs/companion-protocol.md; the Mac side checks the same vector with CryptoKit.
    companion object {
        const val EXPECTED_C2S = "5355498ae5f203661e50e4e064acb33cbbeb43f4851f39e2dc2d2ed5668984b5"
        const val EXPECTED_S2C = "8055a20a0dfd55bffdc36ad3d33186134b5e86d31f725fa423f05d4305ac5567"
        const val EXPECTED_SEALED = "a19c5320891251aad8d438e524d9aac75ab0589cb4e3edcf9857dc1e616bce7fa29458"
    }
}
