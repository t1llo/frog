package xyz.beffa.frog.companion.clipboard

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import xyz.beffa.frog.companion.CompanionApp
import xyz.beffa.frog.companion.service.CompanionService

/**
 * Automatic phone → Mac copying.
 *
 * Android 10+ lets only the focused app (or the default keyboard) read the clipboard, so a background
 * app can't watch it. [CopyWatcherService] is an accessibility service that notices that something
 * was copied (a "Copy" button or menu item, a "Copied" toast, or the Android 13+ system clipboard
 * overlay that appears when an authenticator app copies a code) and opens the invisible
 * [SendClipboardActivity] for a moment. That activity has focus, reads the clip and sends it.
 * The service reads no text from other apps beyond these labels and keeps nothing.
 */
object AutoCopy {
    /** True when the copy watcher is turned on in Accessibility settings. */
    fun isOn(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        val ours = component(context)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == ours }
    }

    /** Opens this app's page in Accessibility settings, or the list when the phone has no direct page. */
    fun openSettings(context: Context) {
        val direct = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
            .putExtra(Intent.EXTRA_COMPONENT_NAME, component(context).flattenToString())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val list = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val opened = Build.VERSION.SDK_INT >= 31 && runCatching { context.startActivity(direct) }.isSuccess
        if (!opened) runCatching { context.startActivity(list) }
    }

    /**
     * Android 13+ greys out accessibility switches of apps that were not installed from a store
     * until "Allow restricted settings" is chosen on the app-info page.
     */
    fun mayNeedRestrictedSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        val installer = runCatching {
            context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
        }.getOrNull()
        return installer !in STORES
    }

    fun openAppInfo(context: Context) {
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /** Ignore copy signals until this time: Frog itself just put a clip from the Mac on the clipboard. */
    @Volatile
    internal var quietUntil = 0L

    /** Called when a clip from the Mac lands on the clipboard, so its overlay doesn't bounce it back. */
    fun appliedFromMac() {
        quietUntil = SystemClock.elapsedRealtime() + QUIET_AFTER_INCOMING_MS
    }

    private fun component(context: Context) = ComponentName(context, CopyWatcherService::class.java)

    private val STORES = setOf("com.android.vending", "com.google.android.packageinstaller.store")
    private const val QUIET_AFTER_INCOMING_MS = 2_500L
}

class CopyWatcherService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastGrabAt = 0L
    private val grab = Runnable { grabNow() }

    /** The watcher keeps the process alive, so it also keeps the link to the Mac up. */
    override fun onServiceConnected() {
        super.onServiceConnected()
        CompanionService.start(this)
        CompanionApp.controller(this).start()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (event.packageName == packageName) return
        if (!CopySignals.isCopy(event)) return
        if (SystemClock.elapsedRealtime() < AutoCopy.quietUntil) return
        // Several signals arrive for one copy (button click, then overlay or toast): grab once.
        handler.removeCallbacks(grab)
        handler.postDelayed(grab, SETTLE_MS)
    }

    private fun grabNow() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastGrabAt < MIN_GAP_MS || now < AutoCopy.quietUntil) return
        if (!CompanionApp.controller(this).status.value.paired) return
        lastGrabAt = now
        runCatching { startActivity(SendClipboardActivity.intent(this, automatic = true)) }
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        handler.removeCallbacks(grab)
        super.onDestroy()
    }

    private companion object {
        const val SETTLE_MS = 300L
        const val MIN_GAP_MS = 700L
    }
}

/** Recognises copies from the labels Android and apps show around them. Pure, so it can be tested. */
internal object CopySignals {
    private const val SYSTEM_UI = "com.android.systemui"

    /** Button and menu labels that copy, lower case. */
    private val copyLabels = setOf(
        "copy", "copy code", "copy text", "copy link", "copy to clipboard", "copy link address", "copy password", "copy username",
        "kopieren", "code kopieren", "link kopieren", "text kopieren", "in zwischenablage kopieren", "passwort kopieren",
        "copier", "copier le lien", "copiar", "copiar enlace", "copiar link", "copia", "copia link", "copiare",
        "kopiëren", "kopiuj", "kopiera", "kopier", "kopioi", "kopírovat", "kopyala", "копировать", "скопировать",
        "コピー", "复制", "複製", "복사",
    )

    /** Toast and overlay text after a copy. */
    private val copiedText = Regex(
        "copied|kopiert|zwischenablage|copié|presse-papiers|copiado|portapapeles|copiato|appunti|gekopieerd|klembord|" +
            "skopiowano|schowka|kopierad|urklipp|kopieret|kopioitu|zkopírováno|kopyalandı|скопирован|буфер обмена|" +
            "コピーしました|クリップボード|已复制|已複製|剪贴板|복사됨|클립보드",
        RegexOption.IGNORE_CASE,
    )

    fun isCopy(event: AccessibilityEvent): Boolean = when (event.eventType) {
        AccessibilityEvent.TYPE_VIEW_CLICKED -> isCopyLabel(label(event))
        AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED ->
            event.className?.contains("Toast") == true && copiedText.containsMatchIn(text(event))
        AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ->
            event.packageName == SYSTEM_UI && isClipboardOverlay(event)
        else -> false
    }

    fun isCopyLabel(label: String?): Boolean {
        val l = label?.trim()?.lowercase()?.trimEnd('.', '…') ?: return false
        return l in copyLabels
    }

    fun isCopiedMessage(text: String): Boolean = copiedText.containsMatchIn(text)

    private fun isClipboardOverlay(event: AccessibilityEvent): Boolean {
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && copiedText.containsMatchIn(text(event))) return true
        val source = event.source ?: return false
        return try {
            hasClipboardId(source, depth = 0)
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) source.recycle()
        }
    }

    /** The system overlay's views are named clipboard_* (clipboard_preview, clipboard_ui, …). */
    private fun hasClipboardId(node: AccessibilityNodeInfo, depth: Int): Boolean {
        if (node.viewIdResourceName?.contains("clipboard", ignoreCase = true) == true) return true
        if (depth >= 3) return false
        for (i in 0 until minOf(node.childCount, 8)) {
            val child = node.getChild(i) ?: continue
            if (hasClipboardId(child, depth + 1)) return true
        }
        return false
    }

    private fun label(event: AccessibilityEvent): String? =
        event.contentDescription?.toString()?.takeIf { it.isNotBlank() }
            ?: event.text.joinToString(" ").takeIf { it.isNotBlank() }

    private fun text(event: AccessibilityEvent): String =
        (event.text.joinToString(" ") + " " + (event.contentDescription ?: "")).trim()
}
