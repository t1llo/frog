package xyz.beffa.frog.companion.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect

private data class PermissionAsk(val title: String, val why: String, val permissions: List<String>)

private fun permissionAsks(): List<PermissionAsk> = buildList {
    if (Build.VERSION.SDK_INT >= 33) {
        add(
            PermissionAsk(
                "Notifications",
                "Shows whether your Mac is connected and puts a Send clipboard button in the notification shade.",
                listOf(Manifest.permission.POST_NOTIFICATIONS),
            ),
        )
    }
    if (Build.VERSION.SDK_INT >= 31) {
        add(
            PermissionAsk(
                "Nearby devices",
                "Lets Frog Companion reach your Mac over Bluetooth when you are not on the same Wi-Fi. It never uses your location.",
                listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT),
            ),
        )
    } else {
        add(
            PermissionAsk(
                "Location (for Bluetooth)",
                "Android 11 and older require it to find your Mac over Bluetooth. Frog Companion never reads your location.",
                listOf(Manifest.permission.ACCESS_FINE_LOCATION),
            ),
        )
    }
    add(
        PermissionAsk(
            "Camera",
            "Scans the pairing code your Mac shows. Only used while you scan.",
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

    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 32.dp),
        ) {
            Text("Frog Companion", style = MaterialTheme.typography.displaySmall)
            Spacer(Modifier.height(8.dp))
            Text(
                "Copy on your Mac, paste on your phone. And back.",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(32.dp))
            Text(
                "Frog Companion needs a few permissions. You can skip any of them and allow it later in Settings.",
                style = MaterialTheme.typography.bodyMedium,
            )
            Spacer(Modifier.height(16.dp))
            // Reading `refresh` makes the rows re-check after each result or resume.
            refresh.let { _ ->
                asks.forEach { ask ->
                    PermissionRow(ask, granted(context, ask)) { launcher.launch(ask.permissions.toTypedArray()) }
                    Spacer(Modifier.height(12.dp))
                }
            }
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.height(24.dp))
            Button(onClick = onDone, modifier = Modifier.fillMaxWidth().height(56.dp)) {
                Text("Continue")
            }
        }
    }
}

@Composable
private fun PermissionRow(ask: PermissionAsk, isGranted: Boolean, onAllow: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = MaterialTheme.shapes.large,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(ask.title, style = MaterialTheme.typography.titleSmall)
                Text(ask.why, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(12.dp))
            if (isGranted) {
                Icon(
                    Icons.Filled.Check,
                    contentDescription = "Allowed",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(24.dp),
                )
            } else {
                FilledTonalButton(onClick = onAllow) { Text("Allow") }
            }
        }
    }
}
