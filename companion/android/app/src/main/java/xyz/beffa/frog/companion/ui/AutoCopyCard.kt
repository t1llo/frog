package xyz.beffa.frog.companion.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import xyz.beffa.frog.companion.R
import xyz.beffa.frog.companion.clipboard.AutoCopy

/** Whether automatic copy is on and whether its switch may be greyed out, re-checked each time the app returns. */
data class AutoCopyState(val on: Boolean, val mayNeedRestrictedSettings: Boolean)

@Composable
fun rememberAutoCopyState(): AutoCopyState {
    val context = LocalContext.current
    if (LocalInspectionMode.current) return AutoCopyState(on = false, mayNeedRestrictedSettings = true)
    fun read() = AutoCopyState(
        on = runCatching { AutoCopy.isOn(context) }.getOrDefault(false),
        mayNeedRestrictedSettings = runCatching { AutoCopy.mayNeedRestrictedSettings(context) }.getOrDefault(false),
    )
    var state by remember { mutableStateOf(read()) }
    LifecycleResumeEffect(Unit) {
        state = read()
        onPauseOrDispose { }
    }
    return state
}

const val AUTO_COPY_WHY =
    "Send what you copy to your Mac automatically, including codes you tap in authenticator apps. " +
        "Turn on Frog Companion in Accessibility."

const val AUTO_COPY_RESTRICTED = "If the switch is greyed out: App info → ⋮ → Allow restricted settings, then try again."

/**
 * The automatic-copy step: a card on Home while it is off, and a step of onboarding. One button opens
 * this app's page in Accessibility; a second line helps with Android's restricted settings for apps
 * installed outside a store.
 */
@Composable
fun AutoCopyCard(
    state: AutoCopyState,
    onOpenSettings: () -> Unit,
    onOpenAppInfo: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val frog = frogColors
    FrogCard(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SymbolTile(R.drawable.ic_bolt, size = 32.dp, tint = if (state.on) frog.good else frog.ink)
            Spacer(Modifier.width(12.dp))
            Text("Automatic copy", style = FrogType.section, color = frog.ink, modifier = Modifier.weight(1f))
            if (state.on) FrogBadge("On", tone = frog.good)
        }
        Spacer(Modifier.height(10.dp))
        Text(
            if (state.on) "What you copy on this phone goes to your Mac on its own, codes from authenticator apps too." else AUTO_COPY_WHY,
            style = FrogType.small,
            color = frog.muted,
        )
        if (!state.on) {
            Spacer(Modifier.height(4.dp))
            FrogButton(
                "Open Accessibility",
                onOpenSettings,
                kind = FrogButtonKind.Secondary,
                fill = true,
            )
            if (state.mayNeedRestrictedSettings) {
                RestrictedSettingsHint(onOpenAppInfo)
            }
        }
    }
}

/** One line and an App info button, for the greyed-out switch of a sideloaded app on Android 13+. */
@Composable
fun RestrictedSettingsHint(onOpenAppInfo: () -> Unit, modifier: Modifier = Modifier) {
    val frog = frogColors
    Row(modifier.fillMaxWidth().padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(AUTO_COPY_RESTRICTED, style = FrogType.caption, color = frog.muted, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        FrogButton("App info", onOpenAppInfo, size = FrogButtonSize.Compact)
    }
}

/** The settings section: Frog's switch shows the state; tapping it opens Accessibility, where it changes. */
@Composable
fun AutoCopySection(state: AutoCopyState, onOpenSettings: () -> Unit, onOpenAppInfo: () -> Unit) {
    val frog = frogColors
    FrogSection("Automatic copy") {
        row {
            FrogSwitchRow(
                title = "Send copies to your Mac",
                caption = if (state.on) "On. Change it in Accessibility." else "Turn on Frog Companion in Accessibility.",
                checked = state.on,
                onToggle = onOpenSettings,
            )
        }
        if (!state.on && state.mayNeedRestrictedSettings) {
            note { Box(Modifier.padding(bottom = 6.dp)) { RestrictedSettingsHint(onOpenAppInfo) } }
        }
    }
}

fun openAutoCopySettings(context: android.content.Context) = AutoCopy.openSettings(context)

fun openAutoCopyAppInfo(context: android.content.Context) = AutoCopy.openAppInfo(context)

// Previews (placeholder data only) ----------------------------------------------------------------

@Preview(name = "Automatic copy, off", widthDp = 393, showBackground = true)
@Composable
fun AutoCopyCardPreview() = FrogTheme {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        AutoCopyCard(AutoCopyState(on = false, mayNeedRestrictedSettings = true), {}, {})
        AutoCopySection(AutoCopyState(on = true, mayNeedRestrictedSettings = false), {}, {})
    }
}
