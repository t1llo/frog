package xyz.beffa.frog.companion.ui

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.launch
import xyz.beffa.frog.companion.R
import xyz.beffa.frog.companion.clipboard.ContentReader
import xyz.beffa.frog.companion.clipboard.SendTileService
import xyz.beffa.frog.companion.service.CompanionController
import xyz.beffa.frog.companion.service.CompanionStatus
import xyz.beffa.frog.companion.service.Link

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(controller: CompanionController, status: CompanionStatus, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val frog = frogColors
    var confirmUnpair by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = frog.canvas,
        topBar = {
            TopAppBar(
                title = { Text("Settings", style = FrogType.title, color = frog.ink) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = frog.muted)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = frog.canvas),
            )
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = padding.calculateTopPadding() + 4.dp,
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item {
                Section("Paired Mac") {
                    Text(status.macName ?: "Mac", style = FrogType.bodyMedium, color = frog.ink)
                    Text(
                        when (status.link) {
                            Link.WIFI -> "Connected over Wi-Fi"
                            Link.BLUETOOTH -> "Connected over Bluetooth"
                            Link.SEARCHING -> "Looking for it"
                            Link.OFFLINE -> "Offline"
                        },
                        style = FrogType.small,
                        color = frog.muted,
                    )
                    Spacer(Modifier.height(12.dp))
                    OutlinedButton(onClick = { confirmUnpair = true }, shape = RoundedCornerShape(FrogRadius.control)) { Text("Unpair") }
                }
            }
            item {
                Section("Send with one tap") {
                    Text(
                        "Add the Send to Mac tile: swipe down twice, tap the pencil, and drag Send to Mac into your tiles. " +
                            "Tapping it sends whatever you copied.",
                        style = FrogType.small,
                        color = frog.muted,
                    )
                    if (Build.VERSION.SDK_INT >= 33) {
                        Spacer(Modifier.height(12.dp))
                        FilledTonalButton(
                            shape = RoundedCornerShape(FrogRadius.control),
                            onClick = { requestAddSendTile(context) },
                        ) { Text("Add the tile") }
                    }
                }
            }
            item {
                Section("Other ways to send") {
                    Text(
                        "• The Send clipboard button in Frog Companion's notification.\n" +
                            "• Long-press the Frog icon and choose Send clipboard.\n" +
                            "• Share text, photos or any file to Frog Companion.",
                        style = FrogType.small,
                        color = frog.muted,
                    )
                }
            }
            item {
                Section("This phone") {
                    Text(controller.deviceName(), style = FrogType.bodyMedium, color = frog.ink)
                    Text(
                        "Files from your Mac are saved to Downloads. Text and images go straight to the clipboard.",
                        style = FrogType.small,
                        color = frog.muted,
                    )
                }
            }
        }
    }

    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            shape = RoundedCornerShape(FrogRadius.panel),
            title = { Text("Unpair ${status.macName ?: "Mac"}?") },
            text = { Text("Frog Companion stops syncing and forgets this Mac. Pair again any time by scanning a new code.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmUnpair = false
                    scope.launch {
                        controller.unpair()
                        Toast.makeText(context, "Unpaired", Toast.LENGTH_SHORT).show()
                    }
                }) { Text("Unpair") }
            },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel") } },
        )
    }
}

/** Frog's SettingsSection: a caption, then one card. */
@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    val frog = frogColors
    Column {
        Text(title, style = FrogType.label, color = frog.muted, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(FrogRadius.card))
                .background(frog.surface)
                .padding(14.dp),
        ) {
            content()
        }
    }
}
