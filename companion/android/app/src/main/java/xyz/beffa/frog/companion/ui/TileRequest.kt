package xyz.beffa.frog.companion.ui

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import xyz.beffa.frog.companion.R
import xyz.beffa.frog.companion.clipboard.SendTileService

/** Android 13+ can add the Send to Mac tile from inside the app, after the user confirms. */
val canRequestTile: Boolean get() = Build.VERSION.SDK_INT >= 33

/** Asks the system to add the Send to Mac Quick Settings tile. Does nothing before Android 13. */
fun requestAddSendTile(context: Context) {
    if (Build.VERSION.SDK_INT < 33) return
    val sbm = context.getSystemService(StatusBarManager::class.java) ?: return
    runCatching {
        sbm.requestAddTileService(
            ComponentName(context, SendTileService::class.java),
            context.getString(R.string.tile_label),
            Icon.createWithResource(context, R.drawable.ic_send),
            context.mainExecutor,
        ) { }
    }
}
