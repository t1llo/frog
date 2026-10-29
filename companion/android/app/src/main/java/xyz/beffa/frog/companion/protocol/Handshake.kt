package xyz.beffa.frog.companion.protocol

import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.UUID

/** The 52-byte cleartext handshake each side sends (docs/companion-protocol.md section 2). */
class Handshake(val deviceId: UUID, val nonce: ByteArray) {
    init {
        require(nonce.size == NONCE_SIZE) { "nonce must be $NONCE_SIZE bytes" }
    }

    fun encode(): ByteArray {
        val buf = ByteBuffer.allocate(SIZE)
        buf.put(MAGIC)
        buf.put(Uuids.toBytes(deviceId))
        buf.put(nonce)
        return buf.array()
    }

    companion object {
        const val SIZE = 52
        const val NONCE_SIZE = 32
        val MAGIC = byteArrayOf(0x46, 0x52, 0x47, 0x31) // "FRG1"

        fun create(deviceId: UUID, random: SecureRandom = SecureRandom()): Handshake {
            val nonce = ByteArray(NONCE_SIZE).also(random::nextBytes)
            return Handshake(deviceId, nonce)
        }

        /** Parses 52 bytes; throws [ProtocolException] on a wrong size or magic. */
        fun decode(bytes: ByteArray): Handshake {
            if (bytes.size != SIZE) throw ProtocolException("handshake must be $SIZE bytes")
            if (!bytes.copyOfRange(0, 4).contentEquals(MAGIC)) throw ProtocolException("bad magic")
            val id = Uuids.fromBytes(bytes.copyOfRange(4, 20))
            return Handshake(id, bytes.copyOfRange(20, 52))
        }
    }
}

object Uuids {
    fun toBytes(uuid: UUID): ByteArray =
        ByteBuffer.allocate(16).putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).array()

    fun fromBytes(bytes: ByteArray): UUID {
        require(bytes.size == 16)
        val buf = ByteBuffer.wrap(bytes)
        return UUID(buf.long, buf.long)
    }

    /** Lowercase hyphenated form, as the spec uses everywhere but the wire. */
    fun format(uuid: UUID): String = uuid.toString().lowercase()

    fun parse(text: String): UUID? = try {
        UUID.fromString(text.trim())
    } catch (_: IllegalArgumentException) {
        null
    }
}

open class ProtocolException(message: String, cause: Throwable? = null) : Exception(message, cause)
