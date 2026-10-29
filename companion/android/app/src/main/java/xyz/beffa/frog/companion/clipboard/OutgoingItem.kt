package xyz.beffa.frog.companion.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.OpenableColumns
import xyz.beffa.frog.companion.protocol.ClipKind
import xyz.beffa.frog.companion.protocol.Limits
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/** Something the phone wants to send to the Mac. */
class OutgoingItem(
    val kind: ClipKind,
    val mime: String,
    val name: String?,
    val body: ByteArray,
    /** Content URI kept for "copy again" (images); null for text and files. */
    val sourceUri: Uri? = null,
) {
    val fingerprint: String by lazy { fingerprint(kind, body) }

    val previewText: String
        get() = when (kind) {
            ClipKind.TEXT -> body.toString(Charsets.UTF_8).trim().take(300)
            ClipKind.IMAGE -> name ?: "Image"
            ClipKind.FILE -> name ?: "File"
        }

    companion object {
        fun text(text: String) = OutgoingItem(ClipKind.TEXT, "text/plain", null, text.toByteArray(Charsets.UTF_8))
    }
}

class TooLargeException(val size: Long) : Exception("item too large: $size bytes")

fun fingerprint(kind: ClipKind, body: ByteArray): String {
    val md = MessageDigest.getInstance("SHA-256")
    md.update(kind.wire.toByteArray())
    md.update(0)
    md.update(body)
    return md.digest().joinToString("") { "%02x".format(it) }
}

/** Reads clipboards and shared content into [OutgoingItem]s. Call off the main thread for URIs. */
object ContentReader {

    /** Reads the primary clip. Must run while the calling activity has window focus. */
    fun primaryClip(context: Context): ClipSnapshot? {
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return null
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        val desc = clip.description
        val uri = item.uri
        if (uri != null) {
            val mime = context.contentResolver.getType(uri) ?: (0 until desc.mimeTypeCount).map(desc::getMimeType)
                .firstOrNull { it.startsWith("image/") }
            if (mime != null && mime.startsWith("image/")) return ClipSnapshot.Image(uri)
            if (desc.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST) && item.text == null) {
                return ClipSnapshot.Text(uri.toString())
            }
        }
        val text = item.text?.toString() ?: item.coerceToText(context)?.toString()
        return if (text.isNullOrEmpty()) null else ClipSnapshot.Text(text)
    }

    sealed interface ClipSnapshot {
        data class Text(val text: String) : ClipSnapshot
        data class Image(val uri: Uri) : ClipSnapshot
    }

    fun fromSnapshot(context: Context, snapshot: ClipSnapshot): OutgoingItem = when (snapshot) {
        is ClipSnapshot.Text -> OutgoingItem.text(snapshot.text)
        is ClipSnapshot.Image -> image(context, snapshot.uri)
    }

    /** PNG and JPEG pass through; any other image type is converted to PNG. */
    fun image(context: Context, uri: Uri): OutgoingItem {
        val resolver = context.contentResolver
        val mime = resolver.getType(uri)?.lowercase()
        val name = displayName(context, uri)
        if (mime == "image/png" || mime == "image/jpeg") {
            return OutgoingItem(ClipKind.IMAGE, mime, name, readAll(context, uri), uri)
        }
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, _, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        val pngName = name?.substringBeforeLast('.')?.plus(".png")
        return OutgoingItem(ClipKind.IMAGE, "image/png", pngName, out.toByteArray(), uri)
    }

    fun file(context: Context, uri: Uri): OutgoingItem {
        val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
        val name = displayName(context, uri) ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        return OutgoingItem(ClipKind.FILE, mime, name, readAll(context, uri))
    }

    fun displayName(context: Context, uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull()

    private fun size(context: Context, uri: Uri): Long? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
        }
    }.getOrNull()

    private fun readAll(context: Context, uri: Uri): ByteArray {
        size(context, uri)?.let { if (it > Limits.MAX_CLIP_TCP) throw TooLargeException(it) }
        val input = context.contentResolver.openInputStream(uri) ?: error("cannot open $uri")
        return input.use { stream ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(256 * 1024)
            var total = 0L
            while (true) {
                val n = stream.read(buf)
                if (n < 0) break
                total += n
                if (total > Limits.MAX_CLIP_TCP) throw TooLargeException(total)
                out.write(buf, 0, n)
            }
            out.toByteArray()
        }
    }

    /** Puts plain text on the clipboard (used by "copy again"). */
    fun copyText(context: Context, text: String) {
        context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Frog Companion", text))
    }

    fun copyUri(context: Context, uri: Uri, label: String = "Frog Companion") {
        context.getSystemService(ClipboardManager::class.java)
            ?.setPrimaryClip(ClipData.newUri(context.contentResolver, label, uri))
    }
}
