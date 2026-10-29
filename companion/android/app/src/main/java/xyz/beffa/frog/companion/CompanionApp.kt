package xyz.beffa.frog.companion

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import xyz.beffa.frog.companion.clipboard.SendClipboardActivity
import xyz.beffa.frog.companion.transport.useElapsedRealtimeClock
import xyz.beffa.frog.companion.service.CompanionController
import xyz.beffa.frog.companion.service.Notifications

class CompanionApp : Application() {
    val controller: CompanionController by lazy { CompanionController(this) }

    override fun onCreate() {
        super.onCreate()
        useElapsedRealtimeClock { SystemClock.elapsedRealtime() }
        Notifications(this).createChannels()
        publishShortcuts()
    }

    /**
     * The launcher's Send clipboard shortcut. Built at runtime rather than in shortcuts.xml so it
     * targets whatever applicationId this build has.
     */
    private fun publishShortcuts() {
        val send = ShortcutInfoCompat.Builder(this, "send_clipboard")
            .setShortLabel(getString(R.string.shortcut_send_short))
            .setLongLabel(getString(R.string.shortcut_send_long))
            .setIcon(IconCompat.createWithResource(this, R.drawable.ic_shortcut_send))
            .setIntent(Intent(this, SendClipboardActivity::class.java).setAction(SendClipboardActivity.ACTION_SEND_CLIPBOARD))
            .build()
        // A sharing shortcut matching res/xml/share_targets.xml, so the share sheet lists Send to Mac first.
        val share = ShortcutInfoCompat.Builder(this, "share_to_mac")
            .setShortLabel(getString(R.string.share_label))
            .setIcon(IconCompat.createWithResource(this, R.mipmap.ic_launcher))
            // Launchers may list it too; there it sends the clipboard like the shortcut above.
            .setIntent(Intent(this, SendClipboardActivity::class.java).setAction(SendClipboardActivity.ACTION_SEND_CLIPBOARD))
            .setCategories(setOf(SHARE_CATEGORY))
            .setLongLived(true)
            .build()
        runCatching { ShortcutManagerCompat.setDynamicShortcuts(this, listOf(send, share)) }
    }

    companion object {
        private const val SHARE_CATEGORY = "xyz.beffa.frog.companion.category.SEND_TO_MAC"

        fun controller(context: Context): CompanionController =
            (context.applicationContext as CompanionApp).controller
    }
}
