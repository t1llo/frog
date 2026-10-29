package xyz.beffa.frog.companion.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import xyz.beffa.frog.companion.CompanionApp

/** Foreground service (type connectedDevice) that keeps the link to the Mac open. */
class CompanionService : LifecycleService() {
    private val controller get() = CompanionApp.controller(this)
    private lateinit var notifications: Notifications

    override fun onCreate() {
        super.onCreate()
        notifications = Notifications(this).apply { createChannels() }
        ServiceCompat.startForeground(
            this,
            Notifications.ID_STATUS,
            notifications.status(controller.status.value),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        lifecycleScope.launch {
            controller.status.collect { notifications.update(it) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (controller.store.pairedMac() == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        controller.start()
        return START_STICKY
    }

    override fun onDestroy() {
        controller.stop()
        super.onDestroy()
    }

    companion object {
        fun start(context: Context) {
            if (CompanionApp.controller(context).store.pairedMac() == null) return
            runCatching {
                ContextCompat.startForegroundService(context, Intent(context, CompanionService::class.java))
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CompanionService::class.java))
        }
    }
}

/** Starts the service after boot or an app update when a Mac is paired. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> CompanionService.start(context)
        }
    }
}
