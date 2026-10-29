package xyz.beffa.frog.companion.transport

import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.beffa.frog.companion.protocol.ClipKind
import xyz.beffa.frog.companion.protocol.FrameCipher
import xyz.beffa.frog.companion.protocol.FrameLimits
import xyz.beffa.frog.companion.protocol.Handshake
import xyz.beffa.frog.companion.protocol.Message
import xyz.beffa.frog.companion.protocol.MessageCodec
import xyz.beffa.frog.companion.protocol.SessionKeys
import java.util.UUID

/** Runs the client [Session] against a minimal fake Mac over an in-memory pipe. */
class SessionTest {

    private class MemoryPipe(
        private val incoming: Channel<ByteArray>,
        private val outgoing: Channel<ByteArray>,
        override val transport: Transport = Transport.WIFI,
    ) : BytePipe {
        override val lastReceiveMillis: Long get() = monotonicMillis()
        private var buf = ByteArray(0)

        override suspend fun readExactly(n: Int): ByteArray {
            while (buf.size < n) {
                val next = incoming.receiveCatching().getOrNull() ?: throw PipeClosedException()
                buf += next
            }
            val out = buf.copyOfRange(0, n)
            buf = buf.copyOfRange(n, buf.size)
            return out
        }

        override suspend fun write(vararg chunks: ByteArray) {
            // Split into 7-byte pieces: chunk boundaries must not matter.
            for (c in chunks) c.toList().chunked(7).forEach { outgoing.send(it.toByteArray()) }
        }

        override fun close() {
            incoming.close()
            outgoing.close()
        }
    }

    private class FakeMac(val id: UUID, val secret: ByteArray, toPhone: Channel<ByteArray>, fromPhone: Channel<ByteArray>) {
        val pipe = MemoryPipe(fromPhone, toPhone)
        lateinit var sealer: FrameCipher
        lateinit var opener: FrameCipher

        suspend fun handshake(): Handshake {
            val client = Handshake.decode(pipe.readExactly(Handshake.SIZE))
            val server = Handshake.create(id)
            pipe.write(server.encode())
            val keys = SessionKeys.derive(secret, client.nonce, server.nonce)
            opener = FrameCipher(keys.c2sKey)
            sealer = FrameCipher(keys.s2cKey)
            return client
        }

        suspend fun read(): Message {
            val n = FrameLimits.readLength(pipe.readExactly(4))
            FrameLimits.check(n)
            return MessageCodec.decode(opener.open(pipe.readExactly(n.toInt())))
        }

        suspend fun send(m: Message) {
            pipe.write(FrameLimits.frame(sealer.seal(MessageCodec.encode(m))))
        }
    }

    private class RecordingHandler : Session.Handler {
        var opened: Message.Hello? = null
        val clips = mutableListOf<Message.Clip>()
        val acks = mutableListOf<String>()
        var unpaired = false

        override suspend fun onOpen(session: Session, mac: Message.Hello) {
            opened = mac
        }

        override suspend fun onClip(session: Session, clip: Message.Clip): Boolean {
            clips += clip
            return true
        }

        override suspend fun onAck(session: Session, id: String) {
            acks += id
        }

        override suspend fun onUnpair(session: Session) {
            unpaired = true
        }
    }

    @Test
    fun fullConversation() = runBlocking {
        withTimeout(10_000) {
            val macId = UUID.randomUUID()
            val phoneId = UUID.randomUUID()
            val secret = ByteArray(32) { 3 }
            val toPhone = Channel<ByteArray>(Channel.UNLIMITED)
            val fromPhone = Channel<ByteArray>(Channel.UNLIMITED)
            val mac = FakeMac(macId, secret, toPhone, fromPhone)
            val handler = RecordingHandler()
            val session = Session(MemoryPipe(toPhone, fromPhone), phoneId, "Test Phone", macId, secret, handler)

            val run = async { session.run() }

            val client = mac.handshake()
            assertEquals(phoneId, client.deviceId)
            val hello = mac.read() as Message.Hello
            assertEquals("android", hello.platform)
            assertEquals(1, hello.version)
            assertEquals("Test Phone", hello.name)
            mac.send(Message.Hello("Test Mac", "macos", 1))

            mac.send(Message.Clip("clip-1", ClipKind.TEXT, "text/plain", null, "hi".toByteArray()))
            assertEquals(Message.Ack("clip-1"), mac.read())
            mac.send(Message.Ping)
            assertEquals(Message.Pong, mac.read())

            session.send(Message.Clip("clip-2", ClipKind.IMAGE, "image/png", null, ByteArray(10) { 5 }))
            val sent = mac.read() as Message.Clip
            assertEquals("clip-2", sent.id)
            assertArrayEquals(ByteArray(10) { 5 }, sent.body)
            mac.send(Message.Ack("clip-2"))
            mac.send(Message.Unpair)

            run.await()
            assertEquals("Test Mac", handler.opened?.name)
            assertEquals(listOf("clip-1"), handler.clips.map { it.id })
            assertEquals(listOf("clip-2"), handler.acks)
            assertTrue(handler.unpaired)
        }
    }

    @Test
    fun wrongMacIsRejected() = runBlocking {
        withTimeout(10_000) {
            val secret = ByteArray(32) { 3 }
            val toPhone = Channel<ByteArray>(Channel.UNLIMITED)
            val fromPhone = Channel<ByteArray>(Channel.UNLIMITED)
            val impostor = FakeMac(UUID.randomUUID(), secret, toPhone, fromPhone)
            val session = Session(MemoryPipe(toPhone, fromPhone), UUID.randomUUID(), "P", UUID.randomUUID(), secret, RecordingHandler())
            val run = async { runCatching { session.run() } }
            impostor.handshake()
            val result = run.await()
            assertTrue(result.exceptionOrNull() is Session.WrongMacException)
        }
    }
}
