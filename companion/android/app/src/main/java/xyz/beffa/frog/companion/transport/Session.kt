package xyz.beffa.frog.companion.transport

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import xyz.beffa.frog.companion.protocol.FrameCipher
import xyz.beffa.frog.companion.protocol.FrameLimits
import xyz.beffa.frog.companion.protocol.Handshake
import xyz.beffa.frog.companion.protocol.Limits
import xyz.beffa.frog.companion.protocol.Message
import xyz.beffa.frog.companion.protocol.MessageCodec
import xyz.beffa.frog.companion.protocol.ProtocolException
import xyz.beffa.frog.companion.protocol.SessionKeys
import java.util.UUID

/**
 * Client side of one Frog Companion connection over any [BytePipe]: handshake, keys, hello exchange,
 * then frames until either side closes (docs/companion-protocol.md sections 2 to 5).
 */
class Session(
    private val pipe: BytePipe,
    private val localId: UUID,
    private val localName: String,
    private val macId: UUID,
    private val secret: ByteArray,
    private val handler: Handler,
) {
    interface Handler {
        /** Both hellos exchanged; the session can carry clips now. */
        suspend fun onOpen(session: Session, mac: Message.Hello)

        /** Store the clip (or recognise a duplicate). Return true to ack it. */
        suspend fun onClip(session: Session, clip: Message.Clip): Boolean

        suspend fun onAck(session: Session, id: String)

        suspend fun onUnpair(session: Session)
    }

    class WrongMacException : ProtocolException("server is not the paired Mac")

    val transport: Transport get() = pipe.transport

    private val writeLock = Mutex()
    private var sealer: FrameCipher? = null

    @Volatile
    private var lastSentMillis = monotonicMillis()

    @Volatile
    var isOpen = false
        private set

    @Volatile
    private var closedByUs = false

    private val pingAfterMs =
        if (pipe.transport == Transport.WIFI) Limits.PING_AFTER_TCP_MS else Limits.PING_AFTER_BLE_MS

    /** Runs until the connection ends. Returns normally when closed by [close] or unpair. */
    suspend fun run() {
        try {
            coroutineScope {
                val local = Handshake.create(localId)
                pipe.write(local.encode())
                val server = withTimeout(Limits.RECEIVE_TIMEOUT_MS) {
                    Handshake.decode(pipe.readExactly(Handshake.SIZE))
                }
                if (server.deviceId != macId) throw WrongMacException()

                val keys = SessionKeys.derive(secret, local.nonce, server.nonce)
                sealer = FrameCipher(keys.c2sKey)
                val opener = FrameCipher(keys.s2cKey)

                send(Message.Hello(name = localName, platform = "android", version = 1))
                val first = withTimeout(Limits.RECEIVE_TIMEOUT_MS) { readMessage(opener) }
                if (first !is Message.Hello) throw ProtocolException("first frame was not hello")

                val keepalive = launch { keepalive() }
                isOpen = true
                handler.onOpen(this@Session, first)
                try {
                    while (isActive) {
                        if (!dispatch(readMessage(opener))) break
                    }
                } finally {
                    keepalive.cancel()
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (!closedByUs) throw e
        } finally {
            isOpen = false
            pipe.close()
        }
    }

    /** Sends one message; frames go out in counter order. */
    suspend fun send(message: Message) {
        val plaintext = MessageCodec.encode(message)
        writeLock.withLock {
            val cipher = sealer ?: throw IllegalStateException("handshake not done")
            val sealed = cipher.seal(plaintext)
            pipe.write(lengthPrefix(sealed.size), sealed)
            lastSentMillis = monotonicMillis()
        }
    }

    fun close() {
        closedByUs = true
        pipe.close()
    }

    private suspend fun readMessage(opener: FrameCipher): Message {
        val n = FrameLimits.readLength(pipe.readExactly(4))
        FrameLimits.check(n)
        val sealed = pipe.readExactly(n.toInt())
        return MessageCodec.decode(opener.open(sealed))
    }

    /** Returns false when the session should end. */
    private suspend fun dispatch(message: Message): Boolean {
        when (message) {
            is Message.Clip -> {
                if (handler.onClip(this, message)) send(Message.Ack(message.id))
            }
            is Message.Ack -> handler.onAck(this, message.id)
            Message.Ping -> send(Message.Pong)
            Message.Pong -> Unit
            Message.Unpair -> {
                closedByUs = true
                handler.onUnpair(this)
                return false
            }
            is Message.Hello, is Message.Unknown -> Unit
        }
        return true
    }

    private suspend fun keepalive() {
        while (true) {
            delay(1_000)
            val now = monotonicMillis()
            if (now - pipe.lastReceiveMillis >= Limits.RECEIVE_TIMEOUT_MS) {
                pipe.close() // unblocks the reader, which ends the session
                return
            }
            if (now - lastSentMillis >= pingAfterMs) {
                try {
                    send(Message.Ping)
                } catch (_: Exception) {
                    pipe.close()
                    return
                }
            }
        }
    }

    private fun lengthPrefix(n: Int): ByteArray =
        byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte())
}
