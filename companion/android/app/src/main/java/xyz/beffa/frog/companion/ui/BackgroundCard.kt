package xyz.beffa.frog.companion.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect

/**
 * Asks the user to take Frog Companion off battery optimization. Without it, Doze and OEM
 * battery managers (ColorOS, MIUI, One UI) cut the app's network while the screen is off, even
 * though its foreground service keeps running, so copies from the Mac stop arriving.
 *
 * Play policy restricts the direct exemption prompt, so the button opens the app's own
 * details page and the card says where to tap. It hides once the exemption is in place.
 */
@Composable
fun BackgroundCard(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var exempt by remember { mutableStateOf(isExempt(context)) }
    LifecycleResumeEffect(Unit) {
        exempt = isExempt(context)
        onPauseOrDispose { }
    }

    AnimatedVisibility(
        visible = !exempt,
        enter = fadeIn(tween(180, easing = EaseOutStrong)) + scaleIn(tween(180, easing = EaseOutStrong), initialScale = 0.95f),
        exit = fadeOut(tween(120)),
        modifier = modifier,
    ) {
        Surface(
            color = MaterialTheme.colorScheme.tertiaryContainer,
            contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(16.dp)) {
                Text("Stay connected with the screen off", style = MaterialTheme.typography.titleSmall)
                Text(
                    "Your phone limits Frog Companion in the background, so copies from your Mac stop arriving " +
                        "when the screen turns off.",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 4.dp),
                )
                Text(
                    "In App info, choose Battery, then Unrestricted (or turn on Allow background activity).",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
                )
                FilledTonalButton(onClick = { openAppDetails(context) }) { Text("Open App info") }
            }
        }
    }
}

private fun isExempt(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

private fun openAppDetails(context: Context) {
    val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
    runCatching { context.startActivity(details) }
        .onFailure { runCatching { context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) } }
}
