package xyz.beffa.frog.companion.clipboard

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.core.content.IntentCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.beffa.frog.companion.CompanionApp
import xyz.beffa.frog.companion.service.CompanionService
import xyz.beffa.frog.companion.service.SendResult

/**
 * Share-sheet target for text, images and any file, single or multiple, and the
 * "Send to Mac" item of the text selection menu, which also copies the text on the phone.
 */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        noTransition(true)
        if (savedInstanceState != null) return
        CompanionService.start(this)
        val intent = intent
        lifecycleScope.launch {
            val results = withContext(Dispatchers.IO) { sendAll(intent) }
            val controller = CompanionApp.controller(this@ShareActivity)
            val summary = when {
                results.isEmpty() -> SendResult.Empty
                results.any { it == SendResult.TooLarge } -> SendResult.TooLarge
                results.all { it == SendResult.AlreadyOnMac } -> SendResult.AlreadyOnMac
                results.any { it == SendResult.WaitingForWifi } -> SendResult.WaitingForWifi
                results.any { it == SendResult.Queued } -> SendResult.Queued
                else -> results.first()
            }
            feedback(this@ShareActivity, summary, controller.status.value.macName, results.size)
            finish()
            noTransition(false)
        }
    }

    private suspend fun sendAll(intent: Intent): List<SendResult> {
        val controller = CompanionApp.controller(this)
        if (intent.action == Intent.ACTION_PROCESS_TEXT) {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            if (text.isNullOrEmpty()) return emptyList()
            withContext(Dispatchers.Main) { ContentReader.copyText(this@ShareActivity, text) }
            return listOf(controller.send(OutgoingItem.text(text)))
        }
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> emptyList()
        }
        if (uris.isEmpty()) {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            return if (text.isNullOrEmpty()) emptyList() else listOf(controller.send(OutgoingItem.text(text)))
        }
        return uris.map { uri ->
            try {
                val type = contentResolver.getType(uri) ?: intent.type
                val item = if (type?.startsWith("image/") == true) {
                    ContentReader.image(this, uri)
                } else {
                    ContentReader.file(this, uri)
                }
                controller.send(item)
            } catch (_: TooLargeException) {
                SendResult.TooLarge
            } catch (_: Exception) {
                SendResult.Empty
            }
        }
    }

    private fun noTransition(opening: Boolean) {
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(
                if (opening) Activity.OVERRIDE_TRANSITION_OPEN else Activity.OVERRIDE_TRANSITION_CLOSE, 0, 0,
            )
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }
}
