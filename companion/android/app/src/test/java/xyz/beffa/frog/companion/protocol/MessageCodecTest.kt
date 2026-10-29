package xyz.beffa.frog.companion.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageCodecTest {
    @Test
    fun pingIsExactBytes() {
        val bytes = MessageCodec.encode(Message.Ping)
        assertEquals("0000000f" + "{\"type\":\"ping\"}".toByteArray().hex(), bytes.hex())
    }

    @Test
    fun helloRoundTrip() {
        val hello = Message.Hello("Pixel 9", "android", 1)
        val header = String(MessageCodec.encode(hello), Charsets.UTF_8).substring(4)
        assertEquals("{\"type\":\"hello\",\"name\":\"Pixel 9\",\"platform\":\"android\",\"version\":1}", header)
        assertEquals(hello, MessageCodec.decode(MessageCodec.encode(hello)))
    }

    @Test
    fun clipRoundTripWithBody() {
        val body = "héllo \"quoted\"\n".toByteArray()
        val clip = Message.Clip("00000000-0000-4000-8000-000000000002", ClipKind.TEXT, "text/plain", null, body)
        val decoded = MessageCodec.decode(MessageCodec.encode(clip)) as Message.Clip
        assertEquals(clip.id, decoded.id)
        assertEquals(ClipKind.TEXT, decoded.kind)
        assertEquals("text/plain", decoded.mime)
        assertNull(decoded.name)
        assertArrayEquals(body, decoded.body)
        val header = String(MessageCodec.encode(clip), Charsets.UTF_8).substring(4).substringBefore("}") + "}"
        assertTrue(header.contains("\"size\":${body.size}"))
    }

    @Test
    fun fileClipKeepsName() {
        val clip = Message.Clip("id-1", ClipKind.FILE, "application/pdf", "Report Q3.pdf", ByteArray(3) { 9 })
        val decoded = MessageCodec.decode(MessageCodec.encode(clip)) as Message.Clip
        assertEquals("Report Q3.pdf", decoded.name)
        assertEquals(ClipKind.FILE, decoded.kind)
    }

    @Test
    fun simpleTypes() {
        for (m in listOf(Message.Ping, Message.Pong, Message.Unpair, Message.Ack("abc"))) {
            assertEquals(m, MessageCodec.decode(MessageCodec.encode(m)))
        }
    }

    @Test
    fun unknownTypesAndFieldsAreIgnored() {
        val raw = MessageCodec.encodeRaw("{\"type\":\"future\",\"x\":1}".toByteArray(), ByteArray(0))
        assertEquals(Message.Unknown("future"), MessageCodec.decode(raw))
        val ping = MessageCodec.encodeRaw("{\"extra\":[1,2],\"type\":\"ping\"}".toByteArray(), ByteArray(0))
        assertEquals(Message.Ping, MessageCodec.decode(ping))
    }

    @Test
    fun malformedMessagesThrow() {
        assertThrows(ProtocolException::class.java) { MessageCodec.decode(hex("000000")) }
        assertThrows(ProtocolException::class.java) { MessageCodec.decode(hex("00000010") + "{}".toByteArray()) }
        assertThrows(ProtocolException::class.java) { MessageCodec.decode(MessageCodec.encodeRaw("[1]".toByteArray(), ByteArray(0))) }
    }
}
