package xyz.beffa.frog.companion.ui

import android.content.res.Configuration
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import xyz.beffa.frog.companion.R
import xyz.beffa.frog.companion.service.CompanionController
import xyz.beffa.frog.companion.service.CompanionStatus
import xyz.beffa.frog.companion.service.Link

@Composable
fun SettingsScreen(controller: CompanionController, status: CompanionStatus, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var confirmUnpair by remember { mutableStateOf(false) }

    SettingsContent(
        status = status,
        deviceName = controller.deviceName(),
        autoCopy = rememberAutoCopyState(),
        backgroundReady = rememberBackgroundReady(),
        onBack = onBack,
        onUnpair = { confirmUnpair = true },
        onOpenAutoCopy = { openAutoCopySettings(context) },
        onOpenAppInfo = { openAutoCopyAppInfo(context) },
        onOpenBatterySettings = { openBatterySettings(context) },
        onAddTile = { requestAddSendTile(context) },
    )

    if (confirmUnpair) {
        FrogConfirmDialog(
            title = "Unpair ${status.macName ?: "Mac"}?",
            message = "Frog Companion stops syncing and forgets this Mac. Pair again any time with a new code.",
            confirm = "Unpair",
            destructive = true,
            onDismiss = { confirmUnpair = false },
            onConfirm = {
                confirmUnpair = false
                scope.launch {
                    controller.unpair()
                    Toast.makeText(context, "Unpaired", Toast.LENGTH_SHORT).show()
                }
            },
        )
    }
}

@Composable
fun SettingsContent(
    status: CompanionStatus,
    deviceName: String,
    autoCopy: AutoCopyState,
    backgroundReady: Boolean,
    onBack: () -> Unit,
    onUnpair: () -> Unit,
    onOpenAutoCopy: () -> Unit,
    onOpenAppInfo: () -> Unit,
    onOpenBatterySettings: () -> Unit,
    onAddTile: () -> Unit,
    showAddTile: Boolean = canRequestTile,
) {
    val frog = frogColors
    FrogScreen(title = "Settings", navigation = { FrogBackButton(onBack) }) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                start = FrogSize.pagePadding,
                end = FrogSize.pagePadding,
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 32.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(FrogSize.sectionSpacing),
            modifier = Modifier.fillMaxSize(),
        ) {
            item {
                FrogSection("Paired Mac") {
                    row {
                        FrogRow(
                            status.macName ?: "Mac",
                            caption = linkText(status.link),
                            leading = { SymbolTile(R.drawable.ic_laptop, size = 36.dp, tint = frog.ink) },
                        ) {
                            FrogButton("Unpair", onUnpair, kind = FrogButtonKind.Destructive, size = FrogButtonSize.Compact)
                        }
                    }
                }
            }
            item { AutoCopySection(autoCopy, onOpenAutoCopy, onOpenAppInfo) }
            item {
                FrogSection("Background") {
                    row {
                        FrogRow(
                            "Run in the background",
                            caption = if (backgroundReady) "Allowed. Copies arrive while the screen is off." else "Battery: choose Unrestricted.",
                        ) {
                            if (backgroundReady) {
                                FrogBadge("On", tone = frog.good)
                            } else {
                                FrogButton("Open", onOpenBatterySettings, size = FrogButtonSize.Compact)
                            }
                        }
                    }
                }
            }
            item {
                FrogSection("Send with one tap", footer = "Share text, photos or files to Send to Mac.") {
                    row {
                        FrogRow(
                            "Send to Mac tile",
                            caption = if (showAddTile) "In Quick Settings" else "Swipe down twice, tap the pencil, drag in Send to Mac.",
                        ) {
                            if (showAddTile) FrogButton("Add", onAddTile, size = FrogButtonSize.Compact)
                        }
                    }
                    row { FrogRow("Notification", caption = "Send clipboard, in Frog Companion's notification") }
                    row { FrogRow("App icon", caption = "Hold the Frog icon, then Send clipboard") }
                }
            }
            item {
                FrogSection("This phone") {
                    row { FrogRow(deviceName, caption = "Files from your Mac are saved to Downloads.") }
                }
            }
        }
    }
}

// Previews (placeholder data only) ----------------------------------------------------------------

@Composable
private fun SettingsPreview(dark: Boolean) = FrogTheme(dark = dark) {
    SettingsContent(
        status = CompanionStatus(paired = true, macName = "Studio Mac", link = Link.WIFI),
        deviceName = "Pixel 9 Pro",
        autoCopy = AutoCopyState(on = true, mayNeedRestrictedSettings = false),
        backgroundReady = false,
        onBack = {}, onUnpair = {}, onOpenAutoCopy = {}, onOpenAppInfo = {}, onOpenBatterySettings = {}, onAddTile = {},
        showAddTile = Build.VERSION.SDK_INT >= 33,
    )
}

@Preview(name = "Settings, light", widthDp = 393, heightDp = 852, showBackground = true)
@Composable
fun SettingsPreviewLight() = SettingsPreview(dark = false)

@Preview(name = "Settings, dark", widthDp = 393, heightDp = 852, showBackground = true, uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable
fun SettingsPreviewDark() = SettingsPreview(dark = true)
