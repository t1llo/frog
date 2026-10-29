package xyz.beffa.frog.companion.clipboard

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import xyz.beffa.frog.companion.CompanionApp
import xyz.beffa.frog.companion.service.Link

/** Quick Settings tile: one tap sends the clipboard to the Mac. */
class SendTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        val status = CompanionApp.controller(this).status.value
        tile.label = "Send to Mac"
        tile.state = if (status.paired) Tile.STATE_ACTIVE else Tile.STATE_UNAVAILABLE
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = when (status.link) {
                Link.WIFI -> "Wi-Fi"
                Link.BLUETOOTH -> "Bluetooth"
                Link.SEARCHING -> "Connecting"
                Link.OFFLINE -> if (status.paired) "Offline" else "Not paired"
            }
        }
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val intent = SendClipboardActivity.intent(this)
        if (Build.VERSION.SDK_INT >= 34) {
            val pi = PendingIntent.getActivity(this, 2, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            startActivityAndCollapse(pi)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
