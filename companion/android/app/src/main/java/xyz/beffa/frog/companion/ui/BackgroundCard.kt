package xyz.beffa.frog.companion.ui

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import xyz.beffa.frog.companion.R

/**
 * Whether Android lets the app run unrestricted in the background, re-checked each time the app
 * returns to the screen. Without it, Doze and OEM battery managers (ColorOS, MIUI, One UI) cut the
 * app's network while the screen is off, even though its foreground service keeps running.
 */
@Composable
fun rememberBackgroundReady(): Boolean {
    val context = LocalContext.current
    var ready by remember { mutableStateOf(isIgnoringBatteryOptimizations(context)) }
    LifecycleResumeEffect(Unit) {
        ready = isIgnoringBatteryOptimizations(context)
        onPauseOrDispose { }
    }
    return ready
}

/**
 * The background-access step, shown rather than explained: a small picture of the battery page
 * with the option to choose marked in the good tone, and one button that opens that page. Once it is
 * done the card fades into a compact "Runs in the background" pill.
 */
@Composable
fun BackgroundAccess(ready: Boolean, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    val reduced = LocalReducedMotion.current
    AnimatedContent(
        targetState = ready,
        transitionSpec = {
            val enter = if (reduced) fadeIn(motionSpec(true)) else fadeIn(motionSpec(false)) + scaleIn(motionSpec(false), initialScale = 0.95f)
            enter togetherWith fadeOut(motionSpec(reduced, 150))
        },
        contentAlignment = Alignment.TopStart,
        label = "background",
        modifier = modifier,
    ) { done ->
        if (done) ReadyChip() else SetupCard(onOpen)
    }
}

@Composable
private fun SetupCard(onOpen: () -> Unit) {
    val frog = frogColors
    FrogCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SymbolTile(R.drawable.ic_battery, size = 32.dp, tint = frog.warning, background = frog.warning.copy(alpha = 0.14f))
            Spacer(Modifier.width(12.dp))
            Text("Keep it running", style = FrogType.section, color = frog.ink, modifier = Modifier.weight(1f))
        }
        Spacer(Modifier.height(10.dp))
        Text(
            "Let Frog Companion run in the background, so copies arrive while the screen is off.",
            style = FrogType.small,
            color = frog.muted,
        )
        Spacer(Modifier.height(12.dp))
        BatteryPageMock()
        Spacer(Modifier.height(4.dp))
        FrogButton("Open battery settings", onOpen, kind = FrogButtonKind.Secondary, fill = true)
    }
}

/**
 * A neutral miniature of the system battery page: App info › Battery, then the three choices,
 * with Unrestricted (ColorOS: Allow background activity) picked and marked in the good tone. Purely
 * decorative; screen readers hear nothing of it, the card's sentence says it.
 */
@Composable
private fun BatteryPageMock() {
    val frog = frogColors
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(FrogRadius.control))
            .background(frog.control)
            .padding(FrogSize.listInset)
            .clearAndSetSemantics { },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(Modifier.padding(start = 10.dp, top = 6.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("App info", style = FrogType.caption, color = frog.muted)
            Text("  ›  ", style = FrogType.caption, color = frog.muted)
            Text("Battery", style = FrogType.caption.copy(fontWeight = FontWeight.Medium), color = frog.ink)
        }
        MockOption("Unrestricted", note = "Allow background activity", chosen = true)
        MockOption("Optimized", note = null, chosen = false)
        MockOption("Restricted", note = null, chosen = false)
    }
}

@Composable
private fun MockOption(title: String, note: String?, chosen: Boolean) {
    val frog = frogColors
    val green = frog.good
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(FrogRadius.control - FrogSize.listInset))
            .background(if (chosen) green.copy(alpha = 0.14f) else androidx.compose.ui.graphics.Color.Transparent)
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(16.dp)
                .clip(CircleShape)
                .border(1.5.dp, if (chosen) green else frog.muted.copy(alpha = 0.5f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (chosen) Box(Modifier.size(8.dp).clip(CircleShape).background(green))
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = if (chosen) FrogType.label else FrogType.small,
                color = if (chosen) frog.ink else frog.muted,
            )
            if (note != null) Text("or “$note”", style = FrogType.caption, color = frog.muted)
        }
        if (chosen) {
            Icon(Icons.Filled.Check, contentDescription = null, tint = green, modifier = Modifier.size(16.dp))
        }
    }
}

/** Once it is done: Frog's status pill. */
@Composable
private fun ReadyChip() {
    FrogStatusPill("Runs in the background")
}

fun isIgnoringBatteryOptimizations(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true

/**
 * Opens the most direct battery page this phone has. ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
 * is off limits under Play policy, so: the app's own battery page (Android 14+), then App info
 * (one tap from Battery), then the list of all apps' battery optimization.
 */
fun openBatterySettings(context: Context) {
    val pkg = Uri.parse("package:${context.packageName}")
    val candidates = buildList {
        if (Build.VERSION.SDK_INT >= 34) add(Intent(ACTION_APP_BATTERY_PAGE, pkg))
        add(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg))
        add(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }
    val pm = context.packageManager
    for (intent in candidates) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent.resolveActivity(pm) == null && !canResolve(pm, intent)) continue
        if (runCatching { context.startActivity(intent) }.isSuccess) return
    }
}

private fun canResolve(pm: PackageManager, intent: Intent): Boolean =
    pm.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY).isNotEmpty()

private const val ACTION_APP_BATTERY_PAGE = "android.settings.VIEW_ADVANCED_POWER_USAGE_DETAIL"

// Previews (placeholder data only) ----------------------------------------------------------------

@Preview(name = "Background access, to do", widthDp = 393, showBackground = true)
@Composable
fun BackgroundAccessPreview() = FrogTheme(dark = false) {
    Box(Modifier.background(frogColors.canvas).padding(16.dp)) { BackgroundAccess(ready = false, onOpen = {}) }
}

@Preview(name = "Background access, done", widthDp = 393, showBackground = true)
@Composable
fun BackgroundAccessReadyPreview() = FrogTheme(dark = false) {
    Box(Modifier.background(frogColors.canvas).padding(16.dp)) { BackgroundAccess(ready = true, onOpen = {}) }
}

@Preview(name = "Background access, dark", widthDp = 393, showBackground = true)
@Composable
fun BackgroundAccessDarkPreview() = FrogTheme(dark = true) {
    Box(Modifier.background(frogColors.canvas).padding(16.dp)) { BackgroundAccess(ready = false, onOpen = {}) }
}
