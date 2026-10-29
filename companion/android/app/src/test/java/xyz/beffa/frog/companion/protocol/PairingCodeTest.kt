package xyz.beffa.frog.companion.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.UUID

class PairingCodeTest {
    private val secret = ByteArray(32) { (it + 1).toByte() }
    private val k = PairingCode.encodeBase64Url(secret)
    private val id = "00000000-0000-4000-8000-000000000001"

    @Test
    fun parsesFullCode() {
        val code = PairingCode.parse("frog://pair?v=1&id=$id&n=Example%E2%80%99s%20Mac&k=$k&p=47321&h=192.0.2.10,192.0.2.20")!!
        assertEquals(UUID.fromString(id), code.macId)
        assertEquals("Example’s Mac", code.macName)
        assertArrayEquals(secret, code.secret)
        assertEquals(47321, code.port)
        assertEquals(listOf("192.0.2.10", "192.0.2.20"), code.hosts)
    }

    @Test
    fun base64UrlHasNoPadding() {
        assertEquals(43, k.length)
        assert(!k.contains('=') && !k.contains('+') && !k.contains('/'))
    }

    @Test
    fun acceptsEncodedCommasUppercaseIdAndPlus() {
        val code = PairingCode.parse("frog://pair?v=1&id=${id.uppercase()}&n=Mac+Studio&k=$k&p=50000&h=192.0.2.10%2C192.0.2.11")!!
        assertEquals(UUID.fromString(id), code.macId)
        assertEquals("Mac+Studio", code.macName)
        assertEquals(50000, code.port)
        assertEquals(listOf("192.0.2.10", "192.0.2.11"), code.hosts)
    }

    @Test
    fun emptyHostsAndDefaultPort() {
        val code = PairingCode.parse("frog://pair?v=1&id=$id&n=Mac&k=$k&h=")!!
        assertEquals(emptyList<String>(), code.hosts)
        assertEquals(47321, code.port)
    }

    @Test
    fun rejectsBadCodes() {
        assertNull(PairingCode.parse("https://example.com"))
        assertNull(PairingCode.parse("frog://pair?v=2&id=$id&n=Mac&k=$k&p=1&h="))
        assertNull(PairingCode.parse("frog://pair?v=1&id=nope&n=Mac&k=$k&p=1&h="))
        assertNull(PairingCode.parse("frog://pair?v=1&id=$id&n=Mac&k=AAAA&p=1&h="))
        assertNull(PairingCode.parse("frog://pair?v=1&id=$id&n=Mac&k=$k&p=99999&h="))
        assertNull(PairingCode.parse("frog://pair?v=1&id=$id&n=%ZZ&k=$k&p=1&h="))
    }
}
