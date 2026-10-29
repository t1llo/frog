package xyz.beffa.frog.companion.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import androidx.core.content.FileProvider
import xyz.beffa.frog.companion.protocol.ClipKind
import xyz.beffa.frog.companion.protocol.Message
import java.io.File

/** Applies clips from the Mac: text and images to the clipboard, files to Downloads. */
class IncomingClips(private val context: Context) {

    sealed interface Stored {
        data class Text(val text: String) : Stored
        data class Image(val uri: Uri) : Stored
        data class File(val uri: Uri, val name: String) : Stored
    }

    fun store(clip: Message.Clip): Stored = when (clip.kind) {
        ClipKind.TEXT -> {
            val text = clip.body.toString(Charsets.UTF_8)
            clipboard()?.setPrimaryClip(ClipData.newPlainText("From Mac", text))
            Stored.Text(text)
        }
        ClipKind.IMAGE -> {
            val uri = saveImage(clip.id, clip.mime, clip.body)
            clipboard()?.setPrimaryClip(ClipData.newUri(context.contentResolver, "Image from Mac", uri))
            Stored.Image(uri)
        }
        ClipKind.FILE -> {
            val name = sanitize(clip.name ?: "Frog Companion file")
            Stored.File(saveDownload(name, clip.mime, clip.body), name)
        }
    }

    /** Writes an image to app cache and returns a shareable FileProvider URI. */
    fun saveImage(id: String, mime: String, body: ByteArray): Uri {
        val dir = File(context.cacheDir, "clips").apply { mkdirs() }
        val ext = if (mime == "image/jpeg") "jpg" else "png"
        val file = File(dir, "${sanitize(id)}.$ext")
        file.writeBytes(body)
        prune(dir)
        return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    }

    private fun saveDownload(name: String, mime: String, body: ByteArray): Uri {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime.ifBlank { "application/octet-stream" })
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("could not create download")
        try {
            resolver.openOutputStream(uri)?.use { it.write(body) } ?: error("could not open download")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri
    }

    private fun prune(dir: File) {
        val files = dir.listFiles()?.sortedByDescending { it.lastModified() } ?: return
        files.drop(KEEP_IMAGES).forEach { it.delete() }
    }

    private fun clipboard() = context.getSystemService(ClipboardManager::class.java)

    private fun sanitize(name: String): String =
        name.replace(Regex("[/\\\\:*?\"<>|\\u0000-\\u001f]"), "_").trim().ifEmpty { "file" }.take(120)

    private companion object {
        const val KEEP_IMAGES = 30
    }
}
