package xyz.beffa.frog.companion.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.nio.ByteBuffer

enum class ClipKind(val wire: String) {
    TEXT("text"), IMAGE("image"), FILE("file");

    companion object {
        fun fromWire(s: String?): ClipKind? = entries.firstOrNull { it.wire == s }
    }
}

/** Plaintext of a frame (docs/companion-protocol.md section 5). */
sealed interface Message {
    data class Hello(val name: String, val platform: String, val version: Int) : Message

    class Clip(
        val id: String,
        val kind: ClipKind,
        val mime: String,
        val name: String?,
        val body: ByteArray,
    ) : Message {
        val size: Long get() = body.size.toLong()
    }

    data class Ack(val id: String) : Message
    data object Ping : Message
    data object Pong : Message
    data object Unpair : Message

    /** Any type this version does not know; ignored by the session. */
    data class Unknown(val type: String) : Message
}

object MessageCodec {
    private val json = Json { ignoreUnknownKeys = true }

    fun header(message: Message): JsonObject = when (message) {
        is Message.Hello -> buildJsonObject {
            put("type", "hello")
            put("name", message.name)
            put("platform", message.platform)
            put("version", message.version)
        }
        is Message.Clip -> buildJsonObject {
            put("type", "clip")
            put("id", message.id)
            put("kind", message.kind.wire)
            put("mime", message.mime)
            if (message.name != null) put("name", message.name)
            put("size", message.size)
        }
        is Message.Ack -> buildJsonObject {
            put("type", "ack")
            put("id", message.id)
        }
        Message.Ping -> buildJsonObject { put("type", "ping") }
        Message.Pong -> buildJsonObject { put("type", "pong") }
        Message.Unpair -> buildJsonObject { put("type", "unpair") }
        is Message.Unknown -> buildJsonObject { put("type", message.type) }
    }

    fun encode(message: Message): ByteArray {
        val body = (message as? Message.Clip)?.body ?: EMPTY
        return encodeRaw(header(message).toString().toByteArray(Charsets.UTF_8), body)
    }

    /** u32 header length || header || body. */
    fun encodeRaw(header: ByteArray, body: ByteArray): ByteArray =
        ByteBuffer.allocate(4 + header.size + body.size).putInt(header.size).put(header).put(body).array()

    fun decode(plaintext: ByteArray): Message {
        if (plaintext.size < 4) throw ProtocolException("message shorter than header length")
        val h = ByteBuffer.wrap(plaintext, 0, 4).int.toLong() and 0xFFFF_FFFFL
        if (h > plaintext.size - 4) throw ProtocolException("header length exceeds message")
        val headerText = String(plaintext, 4, h.toInt(), Charsets.UTF_8)
        val header = try {
            json.parseToJsonElement(headerText) as? JsonObject
        } catch (e: Exception) {
            throw ProtocolException("header is not JSON", e)
        } ?: throw ProtocolException("header is not a JSON object")
        val bodyStart = 4 + h.toInt()

        return when (val type = header.string("type")) {
            "hello" -> Message.Hello(
                name = header.string("name") ?: "",
                platform = header.string("platform") ?: "",
                version = (header["version"] as? JsonPrimitive)?.intOrNull ?: 0,
            )
            "clip" -> {
                val id = header.string("id")
                val kind = ClipKind.fromWire(header.string("kind"))
                if (id == null || kind == null) {
                    Message.Unknown("clip")
                } else {
                    Message.Clip(
                        id = id,
                        kind = kind,
                        mime = header.string("mime") ?: defaultMime(kind),
                        name = header.string("name"),
                        body = plaintext.copyOfRange(bodyStart, plaintext.size),
                    )
                }
            }
            "ack" -> header.string("id")?.let { Message.Ack(it) } ?: Message.Unknown("ack")
            "ping" -> Message.Ping
            "pong" -> Message.Pong
            "unpair" -> Message.Unpair
            else -> Message.Unknown(type ?: "")
        }
    }

    private fun defaultMime(kind: ClipKind) = when (kind) {
        ClipKind.TEXT -> "text/plain"
        ClipKind.IMAGE -> "image/png"
        ClipKind.FILE -> "application/octet-stream"
    }

    private fun JsonObject.string(key: String): String? {
        val e: JsonElement = this[key] ?: return null
        return (e as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    }

    @Suppress("unused")
    private fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull

    private val EMPTY = ByteArray(0)
}

object Limits {
    const val MAX_CLIP_TCP: Long = 200L * 1024 * 1024
    const val MAX_CLIP_BLE: Long = 1L * 1024 * 1024
    const val PING_AFTER_TCP_MS = 15_000L
    const val PING_AFTER_BLE_MS = 25_000L
    const val RECEIVE_TIMEOUT_MS = 60_000L
    const val DEDUPE_WINDOW = 64
    const val TCP_PORT = 47321
    const val CONNECT_TIMEOUT_MS = 3_000
    const val BLE_TCP_RETRY_MS = 30_000L
}
