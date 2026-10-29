package xyz.beffa.frog.companion.clipboard

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.beffa.frog.companion.CompanionApp
import xyz.beffa.frog.companion.service.CompanionService
import xyz.beffa.frog.companion.service.SendResult

/**
 * Invisible, animation-free activity that reads the clipboard once it has window focus
 * (Android 10+ only lets the focused app read it), hands the item to the controller and finishes.
 * Used by the notification action, the Quick Settings tile and the launcher shortcut.
 */
class SendClipboardActivity : ComponentActivity() {
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        noTransition(opening = true)
        handled = savedInstanceState?.getBoolean(KEY_HANDLED) ?: false
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_HANDLED, handled)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handled = false
        if (hasWindowFocus()) onWindowFocusChanged(true)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true
        val snapshot = runCatching { ContentReader.primaryClip(this) }.getOrNull()
        if (snapshot == null) {
            finishWith(SendResult.Empty, null)
            return
        }
        CompanionService.start(this)
        lifecycleScope.launch {
            val (result, mac) = withContext(Dispatchers.IO) {
                val controller = CompanionApp.controller(this@SendClipboardActivity)
                val r = try {
                    controller.send(ContentReader.fromSnapshot(this@SendClipboardActivity, snapshot))
                } catch (_: TooLargeException) {
                    SendResult.TooLarge
                } catch (_: Exception) {
                    SendResult.Empty
                }
                r to controller.status.value.macName
            }
            finishWith(result, mac)
        }
    }

    private fun finishWith(result: SendResult, mac: String?) {
        feedback(this, result, mac, count = 1)
        finish()
        noTransition(opening = false)
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

    companion object {
        private const val KEY_HANDLED = "handled"

        fun intent(context: Context): Intent =
            Intent(context, SendClipboardActivity::class.java)
                .setAction(ACTION_SEND_CLIPBOARD)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)

        const val ACTION_SEND_CLIPBOARD = "xyz.beffa.frog.companion.action.SEND_CLIPBOARD"
    }
}

/** Haptic confirm/reject plus a short toast describing what happened. */
internal fun feedback(activity: Activity, result: SendResult, mac: String?, count: Int) {
    val where = mac ?: "your Mac"
    val ok = result == SendResult.Sending || result == SendResult.Queued || result == SendResult.WaitingForWifi
    val message = when (result) {
        SendResult.Sending -> if (count > 1) "Sending $count items to $where" else "Sent to $where"
        SendResult.Queued -> "Queued. Frog Companion sends it when $where is in reach."
        SendResult.WaitingForWifi -> "Too large for Bluetooth. Sends on Wi-Fi."
        SendResult.AlreadyOnMac -> "Already on your Mac"
        SendResult.TooLarge -> "Too large to send (200 MB max)"
        SendResult.NotPaired -> "Pair Frog Companion with your Mac first"
        SendResult.Empty -> "Clipboard is empty"
    }
    val view = activity.window?.decorView
    if (view != null) {
        val constant = if (Build.VERSION.SDK_INT >= 30) {
            if (ok) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.REJECT
        } else {
            HapticFeedbackConstants.CONTEXT_CLICK
        }
        view.performHapticFeedback(constant)
    }
    Toast.makeText(activity.applicationContext, message, Toast.LENGTH_SHORT).show()
}
