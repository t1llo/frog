package xyz.beffa.frog.companion.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.app.NotificationCompat
import xyz.beffa.frog.companion.R
import xyz.beffa.frog.companion.clipboard.SendClipboardActivity
import xyz.beffa.frog.companion.ui.MainActivity

class Notifications(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    fun createChannels() {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_STATUS, "Connection", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Keeps the link to your Mac open and shows its state."
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_FILES, "Received files", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Files your Mac sent, saved to Downloads."
            },
        )
    }

    fun status(status: CompanionStatus): Notification {
        val mac = status.macName ?: "your Mac"
        val title = when (status.link) {
            Link.WIFI -> "Connected over Wi-Fi"
            Link.BLUETOOTH -> "Connected over Bluetooth"
            Link.SEARCHING -> "Looking for $mac"
            Link.OFFLINE -> "Offline"
        }
        val text = when (status.link) {
            Link.WIFI, Link.BLUETOOTH -> mac
            Link.SEARCHING -> "Same Wi-Fi or Bluetooth nearby"
            Link.OFFLINE -> "$mac isn't reachable. Frog Companion keeps trying."
        }
        val open = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val send = PendingIntent.getActivity(
            context, 1,
            SendClipboardActivity.intent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(context, CHANNEL_STATUS)
            .setSmallIcon(R.drawable.ic_stat_frog)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(R.drawable.ic_send, "Send clipboard", send)
            .build()
    }

    fun update(status: CompanionStatus) {
        if (canPost()) manager.notify(ID_STATUS, status(status))
    }

    fun fileReceived(uri: Uri, name: String, mime: String) {
        if (!canPost()) return
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime.ifBlank { "*/*" })
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val pi = PendingIntent.getActivity(
            context, uri.hashCode(), Intent.createChooser(view, name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CHANNEL_FILES)
            .setSmallIcon(R.drawable.ic_stat_frog)
            .setContentTitle(name)
            .setContentText("Saved to Downloads")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        manager.notify(uri.hashCode(), n)
    }

    private fun canPost(): Boolean =
        android.os.Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    companion object {
        const val CHANNEL_STATUS = "frog_companion_status"
        const val CHANNEL_FILES = "frog_companion_files"
        const val ID_STATUS = 1
    }
}
