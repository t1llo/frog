package xyz.beffa.frog.companion.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class FrameCipherTest {
    private val key = ByteArray(32) { (it * 7).toByte() }

    @Test
    fun nonceIsFourZeroBytesThenBigEndianCounter() {
        assertEquals("000000000000000000000000", FrameCipher.nonce(0).hex())
        assertEquals("000000000000000000000001", FrameCipher.nonce(1).hex())
        assertEquals("000000000102030405060708", FrameCipher.nonce(0x0102030405060708).hex())
    }

    @Test
    fun knownAnswer_zeroKeyZeroNonceEmptyPlaintext() {
        // NIST GCM test case 13: K = 0^256, IV = 0^96, P = empty -> T = 530f8afb...
        val sealed = FrameCipher(ByteArray(32)).seal(ByteArray(0))
        assertEquals("530f8afbc74536b9a963b4f1c4cb738b", sealed.hex())
    }

    @Test
    fun knownAnswer_zeroKeyZeroNonceOneZeroBlock() {
        // NIST GCM test case 14: P = 0^128 -> C = cea7403d..., T = d0d1c8a7...
        val sealed = FrameCipher(ByteArray(32)).seal(ByteArray(16))
        assertEquals("cea7403d4d606b6e074ec5d3baf39d18" + "d0d1c8a799996bf0265b98b5d48ab919", sealed.hex())
    }

    @Test
    fun sealOpenRoundTripAdvancesCounters() {
        val tx = FrameCipher(key)
        val rx = FrameCipher(key)
        repeat(5) { i ->
            val msg = "frame $i".toByteArray()
            val sealed = tx.seal(msg)
            assertEquals(msg.size + 16, sealed.size)
            assertArrayEquals(msg, rx.open(sealed))
        }
        assertEquals(5, tx.counter)
        assertEquals(5, rx.counter)
    }

    @Test
    fun sameInputDiffersPerCounter() {
        val tx = FrameCipher(key)
        val a = tx.seal("x".toByteArray())
        val b = tx.seal("x".toByteArray())
        assert(!a.contentEquals(b))
    }

    @Test
    fun outOfOrderFrameFailsToOpen() {
        val tx = FrameCipher(key)
        tx.seal("first".toByteArray())
        val second = tx.seal("second".toByteArray())
        assertThrows(ProtocolException::class.java) { FrameCipher(key).open(second) }
    }

    @Test
    fun tamperedFrameFailsToOpen() {
        val sealed = FrameCipher(key).seal("hello".toByteArray())
        sealed[0] = (sealed[0].toInt() xor 1).toByte()
        assertThrows(ProtocolException::class.java) { FrameCipher(key).open(sealed) }
    }

    @Test
    fun frameLengthLimits() {
        FrameLimits.check(16)
        FrameLimits.check(268_436_480)
        assertThrows(ProtocolException::class.java) { FrameLimits.check(15) }
        assertThrows(ProtocolException::class.java) { FrameLimits.check(268_436_481) }
        assertEquals(0xFFFF_FFFFL, FrameLimits.readLength(hex("ffffffff")))
        assertEquals("0000001001", FrameLimits.frame(ByteArray(16) { 1 }).hex().take(10))
    }
}
