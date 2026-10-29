package xyz.beffa.frog.companion.ui

import android.content.ClipboardManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import xyz.beffa.frog.companion.protocol.PairingCode
import xyz.beffa.frog.companion.service.CompanionController
import xyz.beffa.frog.companion.service.CompanionService

@Composable
fun PairScreen(controller: CompanionController) {
    val context = LocalContext.current
    val reduced = LocalReducedMotion.current
    var error by remember { mutableStateOf<String?>(null) }

    fun accept(text: String?) {
        val code = text?.let(PairingCode::parse)
        if (code == null) {
            error = if (text == null) null else "That isn't a Frog pairing code. Open Frog on your Mac, then Settings → Phone → Pair a phone."
            return
        }
        error = null
        controller.pair(code)
        CompanionService.start(context)
    }

    val scanner = rememberLauncherForScan { accept(it) }

    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 32.dp),
        ) {
            Text("Pair with your Mac", style = MaterialTheme.typography.headlineMedium)
            Spacer(Modifier.height(24.dp))
            Step(1, "Open Frog on your Mac", "In Frog's main window, open Settings, then Phone.")
            Step(2, "Choose Pair a phone", "Your Mac shows a QR code.")
            Step(3, "Scan it", "Your phone and Mac connect right away, over Wi-Fi or Bluetooth.")
            Spacer(Modifier.height(16.dp))
            AnimatedVisibility(
                visible = error != null,
                enter = fadeIn(motionSpec(reduced)) + scaleIn(motionSpec(reduced), initialScale = 0.95f),
                exit = fadeOut(motionSpec(reduced, 120)),
            ) {
                Text(
                    error.orEmpty(),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.height(24.dp))
            Button(
                onClick = {
                    scanner.launch(
                        ScanOptions()
                            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                            .setPrompt("Scan the code on your Mac")
                            .setBeepEnabled(false)
                            .setOrientationLocked(false),
                    )
                },
                modifier = Modifier.fillMaxWidth().height(56.dp),
            ) { Text("Scan pairing code") }
            TextButton(
                onClick = {
                    val cm = context.getSystemService(ClipboardManager::class.java)
                    accept(cm?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString() ?: "")
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Paste a pairing link instead") }
        }
    }
}

@Composable
private fun rememberLauncherForScan(onResult: (String?) -> Unit) =
    androidx.activity.compose.rememberLauncherForActivityResult(ScanContract()) { result -> onResult(result.contents) }

@Composable
private fun Step(number: Int, title: String, detail: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.Top) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primaryContainer, modifier = Modifier.size(32.dp)) {
            Box(contentAlignment = Alignment.Center) {
                Text("$number", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimaryContainer)
            }
        }
        Spacer(Modifier.width(16.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
