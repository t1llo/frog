package xyz.beffa.frog.companion.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect

private data class PermissionAsk(val title: String, val why: String, val permissions: List<String>)

private fun permissionAsks(): List<PermissionAsk> = buildList {
    if (Build.VERSION.SDK_INT >= 33) {
        add(
            PermissionAsk(
                "Notifications",
                "Shows the connection and a Send clipboard button.",
                listOf(Manifest.permission.POST_NOTIFICATIONS),
            ),
        )
    }
    if (Build.VERSION.SDK_INT >= 31) {
        add(
            PermissionAsk(
                "Nearby devices",
                "Reaches your Mac over Bluetooth, away from Wi-Fi. Never your location.",
                listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT),
            ),
        )
    } else {
        add(
            PermissionAsk(
                "Location (for Bluetooth)",
                "Android 11 needs it for Bluetooth. Your location is never read.",
                listOf(Manifest.permission.ACCESS_FINE_LOCATION),
            ),
        )
    }
    add(
        PermissionAsk(
            "Camera",
            "Scans the pairing code, only while you scan.",
            listOf(Manifest.permission.CAMERA),
        ),
    )
}

private fun granted(context: Context, ask: PermissionAsk) =
    ask.permissions.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

@Composable
fun OnboardingScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val asks = remember { permissionAsks() }
    var refresh by remember { mutableIntStateOf(0) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
    LifecycleResumeEffect(Unit) {
        refresh++
        onPauseOrDispose { }
    }
    // Reading `refresh` makes the rows re-check after each result or resume.
    val grants = refresh.let { _ -> asks.map { granted(context, it) } }
    OnboardingContent(
        asks = asks,
        granted = grants,
        autoCopy = rememberAutoCopyState(),
        onAllow = { ask -> launcher.launch(ask.permissions.toTypedArray()) },
        onOpenAutoCopy = { openAutoCopySettings(context) },
        onOpenAppInfo = { openAutoCopyAppInfo(context) },
        onDone = onDone,
    )
}

@Composable
private fun OnboardingContent(
    asks: List<PermissionAsk>,
    granted: List<Boolean>,
    autoCopy: AutoCopyState,
    onAllow: (PermissionAsk) -> Unit,
    onOpenAutoCopy: () -> Unit,
    onOpenAppInfo: () -> Unit,
    onDone: () -> Unit,
) {
    val frog = frogColors
    WelcomeColumn(
        title = "Frog Companion",
        subtitle = "Copy on your Mac, paste on your phone. And back.",
        actions = { FrogButton("Continue", onDone, kind = FrogButtonKind.Primary, size = FrogButtonSize.Hero, fill = true) },
    ) {
        FrogSection("Permissions", footer = "Skip any of them and allow it later in Android's settings.") {
            asks.forEachIndexed { i, ask ->
                row {
                    FrogRow(ask.title, caption = ask.why) {
                        if (granted[i]) {
                            Icon(Icons.Filled.Check, contentDescription = "Allowed", tint = frog.good, modifier = Modifier.padding(end = 8.dp).size(22.dp))
                        } else {
                            FrogButton("Allow", { onAllow(ask) }, size = FrogButtonSize.Compact)
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(FrogSize.sectionSpacing))
        AutoCopyCard(autoCopy, onOpenAutoCopy, onOpenAppInfo)
    }
}

// Previews (placeholder data only) ----------------------------------------------------------------

@Composable
private fun OnboardingPreview(dark: Boolean) = FrogTheme(dark = dark) {
    val asks = permissionAsks()
    OnboardingContent(
        asks = asks,
        granted = asks.mapIndexed { i, _ -> i == 0 },
        autoCopy = AutoCopyState(on = false, mayNeedRestrictedSettings = true),
        onAllow = {}, onOpenAutoCopy = {}, onOpenAppInfo = {}, onDone = {},
    )
}

@Preview(name = "Onboarding, light", widthDp = 393, heightDp = 852, showBackground = true)
@Composable
fun OnboardingPreviewLight() = OnboardingPreview(dark = false)

@Preview(name = "Onboarding, dark", widthDp = 393, heightDp = 852, showBackground = true, uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable
fun OnboardingPreviewDark() = OnboardingPreview(dark = true)
