package xyz.beffa.frog.companion.ui

import android.content.ClipboardManager
import android.content.res.Configuration
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import xyz.beffa.frog.companion.protocol.PairingCode
import xyz.beffa.frog.companion.service.CompanionController
import xyz.beffa.frog.companion.service.CompanionService

@Composable
fun PairScreen(controller: CompanionController) {
    val context = LocalContext.current
    var error by remember { mutableStateOf<String?>(null) }

    fun accept(text: String?) {
        val code = text?.let(PairingCode::parse)
        if (code == null) {
            error = if (text == null) null else "That isn't a Frog pairing code. On your Mac: Frog → Settings → Phone → Pair a phone."
            return
        }
        error = null
        controller.pair(code)
        CompanionService.start(context)
    }

    val scanner = rememberLauncherForScan { accept(it) }

    PairContent(
        error = error,
        onScan = {
            scanner.launch(
                ScanOptions()
                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                    .setPrompt("Scan the code on your Mac")
                    .setBeepEnabled(false)
                    .setOrientationLocked(false),
            )
        },
        onPaste = {
            val cm = context.getSystemService(ClipboardManager::class.java)
            accept(cm?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString() ?: "")
        },
    )
}

@Composable
fun PairContent(error: String?, onScan: () -> Unit, onPaste: () -> Unit) {
    val frog = frogColors
    val reduced = LocalReducedMotion.current
    WelcomeColumn(
        title = "Pair with your Mac",
        subtitle = "Scan the code Frog shows on your Mac. Your phone and Mac connect over Wi-Fi or Bluetooth.",
        actions = {
            FrogButton("Scan pairing code", onScan, kind = FrogButtonKind.Primary, size = FrogButtonSize.Hero, fill = true)
            FrogButton("Paste a pairing link instead", onPaste, kind = FrogButtonKind.Ghost, fill = true)
        },
    ) {
        FrogSection("On your Mac") {
            row { FrogRow("Open Frog", caption = "Then Settings, then Phone.", leading = { StepNumber(1) }) }
            row { FrogRow("Choose Pair a phone", caption = "Your Mac shows a QR code.", leading = { StepNumber(2) }) }
            row { FrogRow("Scan it with this phone", caption = "The code works for 10 minutes.", leading = { StepNumber(3) }) }
        }
        AnimatedVisibility(
            visible = error != null,
            enter = fadeIn(motionSpec(reduced)) + (if (reduced) fadeIn(motionSpec(true)) else slideInVertically(motionSpec(false)) { -it / 4 }),
            exit = fadeOut(motionSpec(reduced, FrogMotion.EXIT_MS)),
        ) {
            Text(
                error.orEmpty(),
                color = frog.critical,
                style = FrogType.small,
                modifier = Modifier
                    .padding(top = 12.dp)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(FrogRadius.card))
                    .background(frog.critical.copy(alpha = 0.10f))
                    .padding(FrogSize.cardPadding),
            )
        }
    }
}

/** A step's number on a small control-filled circle. */
@Composable
private fun StepNumber(number: Int) {
    val frog = frogColors
    Box(Modifier.size(28.dp).clip(CircleShape).background(frog.control), contentAlignment = Alignment.Center) {
        Text("$number", style = FrogType.label, color = frog.ink)
    }
}

/**
 * The layout of the screens before Home: the Frog mark, a large title and one line, the content,
 * and the actions at the bottom, within reach of the thumb.
 */
@Composable
fun WelcomeColumn(
    title: String,
    subtitle: String,
    actions: @Composable ColumnScope.() -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val frog = frogColors
    Column(
        Modifier
            .fillMaxSize()
            .background(frog.canvas)
            .safeDrawingPadding(),
    ) {
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = FrogSize.pagePadding),
        ) {
            Spacer(Modifier.height(40.dp))
            Box(Modifier.padding(start = 4.dp)) { FrogMark(56.dp) }
            Spacer(Modifier.height(20.dp))
            Text(title, style = FrogType.title, color = frog.ink, modifier = Modifier.padding(horizontal = 4.dp))
            Spacer(Modifier.height(6.dp))
            Text(subtitle, style = FrogType.lead, color = frog.muted, modifier = Modifier.padding(horizontal = 4.dp))
            Spacer(Modifier.height(FrogSize.sectionSpacing))
            content()
            Spacer(Modifier.height(16.dp))
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = FrogSize.pagePadding).padding(bottom = 8.dp)) { actions() }
    }
}

@Composable
private fun rememberLauncherForScan(onResult: (String?) -> Unit) =
    androidx.activity.compose.rememberLauncherForActivityResult(ScanContract()) { result -> onResult(result.contents) }

// Previews (placeholder data only) ----------------------------------------------------------------

@Preview(name = "Pair, light", widthDp = 393, heightDp = 852, showBackground = true)
@Composable
fun PairPreviewLight() = FrogTheme(dark = false) { PairContent(error = null, onScan = {}, onPaste = {}) }

@Preview(name = "Pair, dark, error", widthDp = 393, heightDp = 852, showBackground = true, uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable
fun PairPreviewDark() = FrogTheme(dark = true) {
    PairContent(error = "That isn't a Frog pairing code.", onScan = {}, onPaste = {})
}
