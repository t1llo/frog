package xyz.beffa.frog.companion.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import xyz.beffa.frog.companion.protocol.ClipKind
import java.io.File

enum class Direction { SENT, RECEIVED }

enum class DeliveryState { QUEUED, SENDING, DELIVERED }

data class HistoryItem(
    val id: String,
    val direction: Direction,
    val kind: ClipKind,
    val mime: String,
    val name: String?,
    val size: Long,
    val preview: String,
    /** Full text for text items up to [MAX_TEXT]; otherwise null. */
    val text: String?,
    /** A content URI to copy again (image cache file or saved download). */
    val uri: String?,
    val timeMillis: Long,
    val state: DeliveryState,
    /** Set when a clip waits for Wi-Fi because it is too large for Bluetooth. */
    val waitingForWifi: Boolean = false,
) {
    companion object {
        const val MAX_TEXT = 100_000
    }
}

/** Recent items, newest first, persisted as a small JSON file. */
class HistoryStore(context: Context) {
    private val file = File(context.filesDir, "history.json")
    private val _items = MutableStateFlow(load())
    val items: StateFlow<List<HistoryItem>> = _items.asStateFlow()

    fun add(item: HistoryItem) {
        _items.update { (listOf(item) + it.filter { old -> old.id != item.id }).take(MAX_ITEMS) }
        save()
    }

    fun update(id: String, transform: (HistoryItem) -> HistoryItem) {
        _items.update { list -> list.map { if (it.id == id) transform(it) else it } }
        save()
    }

    fun clear() {
        _items.value = emptyList()
        save()
    }

    private fun save() {
        val json = buildJsonArray {
            for (i in _items.value) add(
                buildJsonObject {
                    put("id", i.id)
                    put("dir", i.direction.name)
                    put("kind", i.kind.wire)
                    put("mime", i.mime)
                    i.name?.let { put("name", it) }
                    put("size", i.size)
                    put("preview", i.preview)
                    i.text?.let { put("text", it) }
                    i.uri?.let { put("uri", it) }
                    put("time", i.timeMillis)
                    put("state", i.state.name)
                    put("wifi", i.waitingForWifi)
                },
            )
        }
        runCatching {
            val tmp = File(file.parentFile, "history.json.tmp")
            tmp.writeText(json.toString())
            tmp.renameTo(file)
        }
    }

    private fun load(): List<HistoryItem> = runCatching {
        if (!file.exists()) return emptyList()
        (Json.parseToJsonElement(file.readText()) as JsonArray).mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            fun s(k: String) = (o[k] as? JsonPrimitive)?.contentOrNull
            val state = runCatching { DeliveryState.valueOf(s("state")!!) }.getOrDefault(DeliveryState.DELIVERED)
            HistoryItem(
                id = s("id") ?: return@mapNotNull null,
                direction = runCatching { Direction.valueOf(s("dir")!!) }.getOrNull() ?: return@mapNotNull null,
                kind = ClipKind.fromWire(s("kind")) ?: return@mapNotNull null,
                mime = s("mime") ?: "",
                name = s("name"),
                size = (o["size"] as? JsonPrimitive)?.longOrNull ?: 0,
                preview = s("preview") ?: "",
                text = s("text"),
                uri = s("uri"),
                timeMillis = (o["time"] as? JsonPrimitive)?.longOrNull ?: 0,
                // Anything still in flight when the app died was lost with the in-memory outbox.
                state = if (state == DeliveryState.DELIVERED) state else DeliveryState.DELIVERED,
                waitingForWifi = (o["wifi"] as? JsonPrimitive)?.booleanOrNull ?: false,
            ).let { if (state != DeliveryState.DELIVERED) null else it }
        }
    }.getOrDefault(emptyList())

    private companion object {
        const val MAX_ITEMS = 50
    }
}
