package xyz.beffa.frog.companion.ui

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.text.format.DateUtils
import android.text.format.Formatter
import android.util.Size
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.beffa.frog.companion.R
import xyz.beffa.frog.companion.clipboard.AutoCopy
import xyz.beffa.frog.companion.clipboard.ContentReader
import xyz.beffa.frog.companion.clipboard.OutgoingItem
import xyz.beffa.frog.companion.clipboard.TooLargeException
import xyz.beffa.frog.companion.data.DeliveryState
import xyz.beffa.frog.companion.data.Direction
import xyz.beffa.frog.companion.data.HistoryItem
import xyz.beffa.frog.companion.protocol.ClipKind
import xyz.beffa.frog.companion.service.CompanionController
import xyz.beffa.frog.companion.service.CompanionStatus
import xyz.beffa.frog.companion.service.Link
import xyz.beffa.frog.companion.service.SendResult

/** Narrows the Recent list. */
enum class HistoryFilter(val title: String, val kind: ClipKind?) {
    ALL("All", null), TEXT("Text", ClipKind.TEXT), IMAGES("Images", ClipKind.IMAGE), FILES("Files", ClipKind.FILE)
}

@Composable
fun HomeScreen(controller: CompanionController, status: CompanionStatus, onOpenSettings: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val history by controller.history.items.collectAsStateWithLifecycle()
    // Rows that exist when the screen opens don't animate; only rows added while watching do.
    val openedAt = remember { System.currentTimeMillis() }
    val now by produceState(System.currentTimeMillis()) {
        while (true) {
            delay(30_000)
            value = System.currentTimeMillis()
        }
    }
    var copied by remember { mutableStateOf<String?>(null) }
    var copies by remember { mutableIntStateOf(0) }
    LaunchedEffect(copies) {
        if (copies == 0) return@LaunchedEffect
        delay(FrogMotion.CONFIRMATION_MS)
        copied = null
    }

    fun send(read: () -> OutgoingItem?) {
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    read()?.let { controller.send(it) } ?: SendResult.Empty
                } catch (_: TooLargeException) {
                    SendResult.TooLarge
                } catch (_: Exception) {
                    SendResult.Empty
                }
            }
            val message = sendMessage(result) ?: "Sending to ${status.macName ?: "your Mac"}"
            Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
        }
    }

    HomeContent(
        status = status,
        history = history,
        now = now,
        openedAt = openedAt,
        copiedId = copied,
        autoCopy = rememberAutoCopyState(),
        onSend = {
            // The app has window focus here, so it may read the clipboard directly.
            val snapshot = runCatching { ContentReader.primaryClip(context) }.getOrNull()
            if (snapshot == null) {
                Toast.makeText(context, "Clipboard is empty", Toast.LENGTH_SHORT).show()
            } else {
                send { ContentReader.fromSnapshot(context, snapshot) }
            }
        },
        onCopy = { item ->
            // Your Mac has this clip already: the copy overlay must not send it straight back.
            AutoCopy.appliedFromMac()
            if (copyToPhone(context, item)) {
                copied = item.id
                copies++
                // Android 13+ confirms every copy with its own overlay.
                if (Build.VERSION.SDK_INT < 33) Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(context, "This one is no longer on your phone", Toast.LENGTH_SHORT).show()
            }
        },
        onResend = { item -> send { outgoing(context, item) } },
        onOpenSettings = onOpenSettings,
        onAddTile = { requestAddSendTile(context) },
        backgroundReady = rememberBackgroundReady(),
        onOpenBatterySettings = { openBatterySettings(context) },
        onOpenAutoCopy = { openAutoCopySettings(context) },
        onOpenAppInfo = { openAutoCopyAppInfo(context) },
    )
}

private fun sendMessage(result: SendResult): String? = when (result) {
    SendResult.Sending -> null
    SendResult.Queued -> "Queued until your Mac is in reach"
    SendResult.WaitingForWifi -> "Too large for Bluetooth. Sends on Wi-Fi."
    SendResult.AlreadyOnMac -> "Already on your Mac"
    SendResult.TooLarge -> "Too large to send (200 MB max)"
    SendResult.NotPaired -> "Pair with your Mac first"
    SendResult.Empty -> "Clipboard is empty"
}

@Composable
fun HomeContent(
    status: CompanionStatus,
    history: List<HistoryItem>,
    now: Long,
    openedAt: Long,
    autoCopy: AutoCopyState,
    onSend: () -> Unit,
    onCopy: (HistoryItem) -> Unit,
    onResend: (HistoryItem) -> Unit,
    onOpenSettings: () -> Unit,
    onAddTile: () -> Unit,
    backgroundReady: Boolean,
    onOpenBatterySettings: () -> Unit,
    onOpenAutoCopy: () -> Unit,
    onOpenAppInfo: () -> Unit,
    copiedId: String? = null,
    showAddTile: Boolean = canRequestTile,
) {
    val frog = frogColors
    var filter by rememberSaveable { mutableStateOf(HistoryFilter.ALL) }
    val shown = remember(history, filter) { history.filter { filter.kind == null || it.kind == filter.kind } }

    FrogScreen(
        title = "Frog Companion",
        leading = { FrogMark(30.dp) },
        actions = {
            FrogIconButton(
                rememberVectorPainter(Icons.Filled.Settings),
                contentDescription = "Settings",
                onClick = onOpenSettings,
                filled = false,
                iconSize = 22.dp,
            )
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                start = FrogSize.pagePadding,
                end = FrogSize.pagePadding,
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 32.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "mac") { MacCard(status, onSend) }
            item(key = "background") {
                BackgroundAccess(backgroundReady, onOpenBatterySettings, Modifier.padding(top = 12.dp))
            }
            if (!autoCopy.on) {
                item(key = "autocopy") {
                    AutoCopyCard(autoCopy, onOpenAutoCopy, onOpenAppInfo, Modifier.padding(top = 12.dp))
                }
            }
            item(key = "how") {
                HowToSend(autoCopy.on, showAddTile, onAddTile, Modifier.padding(top = FrogSize.sectionSpacing))
            }
            item(key = "recent-title") { RecentHeader(history.size, Modifier.padding(top = FrogSize.sectionSpacing)) }
            if (history.isNotEmpty()) {
                item(key = "filters") {
                    val kinds = HistoryFilter.entries.filter { f ->
                        // A kind with nothing in it stays out of the way, unless it is the current one.
                        f.kind == null || f == filter || history.any { it.kind == f.kind }
                    }
                    if (kinds.size > 2) {
                        FrogSegments(kinds, filter, { it.title }, { filter = it }, Modifier.padding(bottom = 6.dp))
                    }
                }
            }
            historyCard(shown, history.isEmpty(), filter, now, openedAt, status.macName, copiedId, onCopy, onResend)
            if (history.isNotEmpty()) {
                item(key = "recent-footer") {
                    Text(
                        "Tap to copy on this phone. Hold to send to your Mac again.",
                        style = FrogType.small,
                        color = frog.muted,
                        modifier = Modifier.padding(start = FrogSize.cardPadding, end = FrogSize.cardPadding, top = 8.dp),
                    )
                }
            }
        }
    }
}

// Mac --------------------------------------------------------------------------------------------

@Composable
private fun MacCard(status: CompanionStatus, onSend: () -> Unit) {
    val reduced = LocalReducedMotion.current
    val view = LocalView.current
    val frog = frogColors
    val dotColor by animateColorAsState(
        targetValue = when (status.link) {
            Link.WIFI -> frog.good
            Link.BLUETOOTH -> frog.series
            Link.SEARCHING -> frog.warning
            Link.OFFLINE -> frog.muted.copy(alpha = 0.6f)
        },
        animationSpec = motionSpec(reduced),
        label = "dot",
    )
    FrogCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SymbolTile(R.drawable.ic_laptop, size = 40.dp, tint = frog.ink)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    status.macName ?: "Your Mac",
                    style = FrogType.section,
                    color = frog.ink,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(2.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    StatusDot(dotColor, 7.dp)
                    Spacer(Modifier.width(6.dp))
                    AnimatedContent(
                        targetState = status.link,
                        transitionSpec = {
                            if (reduced) {
                                fadeIn(motionSpec(true)) togetherWith fadeOut(motionSpec(true))
                            } else {
                                (fadeIn(motionSpec(false)) + slideInVertically(motionSpec(false)) { it / 4 }) togetherWith
                                    fadeOut(motionSpec(false, FrogMotion.EXIT_MS))
                            }
                        },
                        label = "link",
                    ) { link ->
                        Text(
                            linkText(link),
                            style = FrogType.small,
                            color = frog.muted,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        FrogButton(
            "Send clipboard",
            onClick = {
                view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                onSend()
            },
            kind = FrogButtonKind.Primary,
            size = FrogButtonSize.Hero,
            fill = true,
            icon = R.drawable.ic_dir_sent,
        )
    }
}

fun linkText(link: Link): String = when (link) {
    Link.WIFI -> "Connected over Wi-Fi"
    Link.BLUETOOTH -> "Connected over Bluetooth"
    Link.SEARCHING -> "Looking for your Mac"
    Link.OFFLINE -> "Offline. Frog Companion keeps trying."
}

/**
 * How to send from the phone. Android lets an app read the clipboard only while it is on screen, so
 * every send from the phone starts with a tap, unless automatic copy is on.
 */
@Composable
private fun HowToSend(autoCopyOn: Boolean, showAddTile: Boolean, onAddTile: () -> Unit, modifier: Modifier = Modifier) {
    FrogSection(
        "How to send",
        modifier = modifier,
        footer = "Copies from your Mac arrive here on their own.",
    ) {
        row { FrogRow("Selected text", caption = "Send to Mac in the menu next to Copy.") }
        row {
            FrogRow(
                "Codes and links",
                caption = if (autoCopyOn) {
                    "Sent on their own while automatic copy is on."
                } else {
                    "The Send to Mac tile, or Send clipboard in the notification."
                },
            )
        }
        row { FrogRow("Photos and files", caption = "Share them and choose Send to Mac.") }
        if (showAddTile) {
            row {
                FrogRow("Send to Mac tile", caption = "One tap in Quick Settings") {
                    FrogButton("Add", onAddTile, size = FrogButtonSize.Compact)
                }
            }
        }
    }
}

// Recent -------------------------------------------------------------------------------------------

@Composable
private fun RecentHeader(count: Int, modifier: Modifier = Modifier) {
    val frog = frogColors
    Row(
        modifier.fillMaxWidth().heightIn(min = 28.dp).padding(horizontal = FrogSize.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Recent", style = FrogType.section, color = frog.ink, modifier = Modifier.weight(1f))
        if (count > 0) Text("$count", style = FrogType.caption, color = frog.muted)
    }
    Spacer(Modifier.height(8.dp))
}

/** Where a piece sits in the one card that holds the list, so the pieces join into one surface. */
private fun segmentShape(first: Boolean, last: Boolean): Shape {
    val r = FrogRadius.card
    return RoundedCornerShape(
        topStart = if (first) r else 0.dp, topEnd = if (first) r else 0.dp,
        bottomStart = if (last) r else 0.dp, bottomEnd = if (last) r else 0.dp,
    )
}

private fun LazyListScope.historyCard(
    shown: List<HistoryItem>,
    nothingAtAll: Boolean,
    filter: HistoryFilter,
    now: Long,
    openedAt: Long,
    macName: String?,
    copiedId: String?,
    onCopy: (HistoryItem) -> Unit,
    onResend: (HistoryItem) -> Unit,
) {
    if (shown.isEmpty()) {
        item(key = "empty") { EmptyHistory(if (nothingAtAll) null else filter, macName) }
        return
    }
    itemsIndexed(shown, key = { _, it -> it.id }) { index, item ->
        val first = index == 0
        val last = index == shown.lastIndex
        Box(
            Modifier
                .fillMaxWidth()
                .background(frogColors.card, segmentShape(first, last))
                .padding(
                    start = FrogSize.listInset,
                    end = FrogSize.listInset,
                    top = if (first) FrogSize.listInset else 1.dp,
                    bottom = if (last) FrogSize.listInset else 1.dp,
                ),
        ) {
            HistoryRow(item, now, isNew = item.timeMillis > openedAt, macName, copied = item.id == copiedId, onCopy, onResend)
        }
    }
}

@Composable
private fun EmptyHistory(filter: HistoryFilter?, macName: String?) {
    val (icon, title, message) = when (filter?.kind) {
        null -> Triple(
            R.drawable.ic_copy,
            "Nothing here yet",
            "Copy something on ${macName ?: "your Mac"} and it shows up here.",
        )
        ClipKind.TEXT -> Triple(R.drawable.ic_kind_text, "No text yet", "Copied text from either side shows up here.")
        ClipKind.IMAGE -> Triple(R.drawable.ic_kind_image, "No images yet", "Copied images and shared photos show up here.")
        ClipKind.FILE -> Triple(R.drawable.ic_kind_file, "No files yet", "Files from your Mac are saved to Downloads.")
    }
    Box(Modifier.fillMaxWidth().frogCard()) { FrogEmptyState(icon, title, message) }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HistoryRow(
    item: HistoryItem,
    now: Long,
    isNew: Boolean,
    macName: String?,
    copied: Boolean,
    onCopy: (HistoryItem) -> Unit,
    onResend: (HistoryItem) -> Unit,
) {
    val context = LocalContext.current
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    val density = LocalDensity.current
    val frog = frogColors
    val appear = remember(item.id) { Animatable(if (isNew && !reduced) 0f else 1f) }
    LaunchedEffect(item.id) {
        if (appear.value < 1f) appear.animateTo(1f, tween(FrogMotion.REVEAL_MS, easing = EaseOutStrong))
    }
    val offsetPx = with(density) { 6.dp.toPx() }
    val pending = pendingLabel(item)
    val onPhone = item.text != null || item.uri != null
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val fill = pressFill(pressed, androidx.compose.ui.graphics.Color.Transparent, frog.pressed)

    Row(
        Modifier
            .fillMaxWidth()
            .graphicsLayer {
                val v = appear.value
                alpha = v
                translationY = (1f - v) * offsetPx
            }
            .clip(RoundedCornerShape(FrogRadius.control))
            .background(fill)
            .combinedClickable(
                interactionSource = interaction,
                indication = null,
                enabled = onPhone,
                role = Role.Button,
                onClickLabel = "Copy",
                onLongClickLabel = "Send to Mac again",
                onLongClick = {
                    view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                    onResend(item)
                },
                onClick = {
                    view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                    onCopy(item)
                },
            )
            .heightIn(min = 56.dp)
            .padding(start = 10.dp, end = 2.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Crossfade(copied, animationSpec = motionSpec(reduced), label = "copied") { done ->
            if (done) {
                Box(
                    Modifier.size(36.dp).clip(RoundedCornerShape(FrogRadius.control)).background(frog.good.copy(alpha = 0.14f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Check, contentDescription = "Copied", tint = frog.good, modifier = Modifier.size(18.dp))
                }
            } else {
                Leading(item)
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title(item),
                style = FrogType.body,
                color = frog.ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                val sent = item.direction == Direction.SENT
                Icon(
                    painterResource(if (sent) R.drawable.ic_dir_sent else R.drawable.ic_dir_received),
                    contentDescription = if (sent) "Sent" else "Received",
                    tint = if (sent) frog.muted else frog.accent,
                    modifier = Modifier.size(12.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    meta(context, item, now, macName),
                    style = FrogType.caption,
                    color = frog.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (pending != null) {
                    Text(" · ", style = FrogType.caption, color = frog.muted)
                    Text(pending, style = FrogType.caption, color = frog.warning, maxLines = 1)
                }
            }
        }
        if (onPhone) {
            FrogIconButton(
                painterResource(R.drawable.ic_dir_sent),
                contentDescription = "Send to Mac again",
                onClick = { onResend(item) },
                visualSize = 32.dp,
                iconSize = 16.dp,
            )
        } else {
            Spacer(Modifier.width(8.dp))
        }
    }
}

private fun title(item: HistoryItem): String = when (item.kind) {
    ClipKind.TEXT -> item.preview.replace('\n', ' ').trim().ifBlank { "Empty text" }
    else -> item.name ?: item.preview.ifBlank { if (item.kind == ClipKind.IMAGE) "Image" else "File" }
}

/** A 36 dp tile: the image itself for images, otherwise the kind's icon on the control fill. */
@Composable
private fun Leading(item: HistoryItem) {
    val context = LocalContext.current
    val frog = frogColors
    val uri = item.uri
    val tile = Modifier.size(36.dp).clip(RoundedCornerShape(FrogRadius.control))
    if (item.kind == ClipKind.IMAGE && uri != null && !LocalInspectionMode.current) {
        val thumb by produceState<Bitmap?>(null, uri) {
            value = withContext(Dispatchers.IO) {
                runCatching { context.contentResolver.loadThumbnail(Uri.parse(uri), Size(144, 144), null) }.getOrNull()
            }
        }
        thumb?.let {
            Image(bitmap = it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = tile.background(frog.control))
            return
        }
    }
    SymbolTile(kindIcon(item.kind), size = 36.dp)
}

@DrawableRes
private fun kindIcon(kind: ClipKind): Int = when (kind) {
    ClipKind.TEXT -> R.drawable.ic_kind_text
    ClipKind.IMAGE -> R.drawable.ic_kind_image
    ClipKind.FILE -> R.drawable.ic_kind_file
}

private fun meta(context: Context, item: HistoryItem, now: Long, macName: String?): String {
    val mac = macName ?: "Mac"
    val dir = if (item.direction == Direction.SENT) "To $mac" else "From $mac"
    val time = if (now - item.timeMillis < DateUtils.MINUTE_IN_MILLIS) {
        "Just now"
    } else {
        DateUtils.getRelativeTimeSpanString(item.timeMillis, now, DateUtils.MINUTE_IN_MILLIS, DateUtils.FORMAT_ABBREV_RELATIVE).toString()
    }
    val size = if (item.kind == ClipKind.TEXT) null else Formatter.formatShortFileSize(context, item.size)
    return listOfNotNull(time, dir, size).joinToString(" · ")
}

private fun pendingLabel(item: HistoryItem): String? = when {
    item.direction == Direction.RECEIVED -> null
    item.waitingForWifi && item.state != DeliveryState.DELIVERED -> "Waiting for Wi-Fi"
    item.state == DeliveryState.QUEUED -> "Queued"
    item.state == DeliveryState.SENDING -> "Sending"
    else -> null
}

/** Puts a history item on the phone's clipboard: its text, or its image or file through the content resolver. */
private fun copyToPhone(context: Context, item: HistoryItem): Boolean {
    item.text?.let {
        ContentReader.copyText(context, it)
        return true
    }
    val uri = item.uri ?: return false
    return runCatching { ContentReader.copyUri(context, Uri.parse(uri), item.name ?: "Frog Companion") }.isSuccess
}

/** The item as something to send again. Reads files, so call it off the main thread. */
private fun outgoing(context: Context, item: HistoryItem): OutgoingItem? {
    item.text?.let { return OutgoingItem.text(it) }
    val uri = Uri.parse(item.uri ?: return null)
    return if (item.kind == ClipKind.IMAGE) ContentReader.image(context, uri) else ContentReader.file(context, uri)
}

// Previews (placeholder data only) ----------------------------------------------------------------

private const val PREVIEW_NOW = 1_800_000_000_000L

private fun sampleHistory(): List<HistoryItem> {
    fun item(
        id: Int, dir: Direction, kind: ClipKind, preview: String, minutesAgo: Long,
        name: String? = null, size: Long = preview.length.toLong(), state: DeliveryState = DeliveryState.DELIVERED,
        mime: String = "text/plain",
    ) = HistoryItem(
        id = "preview-$id", direction = dir, kind = kind, mime = mime, name = name, size = size, preview = preview,
        text = if (kind == ClipKind.TEXT) preview else null, uri = null,
        timeMillis = PREVIEW_NOW - minutesAgo * 60_000, state = state,
    )
    return listOf(
        item(1, Direction.SENT, ClipKind.TEXT, "Pick up the parcel before six, the counter closes early on Fridays", 0, state = DeliveryState.SENDING),
        item(2, Direction.RECEIVED, ClipKind.TEXT, "https://example.com/docs/getting-started", 3),
        item(3, Direction.RECEIVED, ClipKind.IMAGE, "", 12, name = "Screenshot.png", size = 842_000, mime = "image/png"),
        item(4, Direction.RECEIVED, ClipKind.FILE, "", 47, name = "Quarterly report.pdf", size = 2_400_000, mime = "application/pdf"),
        item(5, Direction.SENT, ClipKind.IMAGE, "", 95, name = "Photo.jpg", size = 3_100_000, mime = "image/jpeg"),
        item(6, Direction.RECEIVED, ClipKind.TEXT, "Booking reference: ABC123", 180),
        item(7, Direction.SENT, ClipKind.TEXT, "Remember to water the plants", 1440),
    )
}

@Composable
private fun HomePreview(history: List<HistoryItem>, link: Link, dark: Boolean = false, backgroundReady: Boolean = true) {
    FrogTheme(dark = dark) {
        HomeContent(
            status = CompanionStatus(paired = true, macName = "Studio Mac", link = link),
            history = history,
            now = PREVIEW_NOW,
            openedAt = PREVIEW_NOW,
            autoCopy = AutoCopyState(on = false, mayNeedRestrictedSettings = true),
            onSend = {},
            onCopy = {},
            onResend = {},
            onOpenSettings = {},
            onAddTile = {},
            backgroundReady = backgroundReady,
            onOpenBatterySettings = {},
            onOpenAutoCopy = {},
            onOpenAppInfo = {},
            showAddTile = true,
        )
    }
}

@Preview(name = "Home, light", widthDp = 393, heightDp = 852, showBackground = true)
@Composable
fun HomePreviewLight() = HomePreview(sampleHistory(), Link.WIFI)

@Preview(name = "Home, dark", widthDp = 393, heightDp = 852, showBackground = true, uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable
fun HomePreviewDark() = HomePreview(sampleHistory(), Link.BLUETOOTH, dark = true)

@Preview(name = "Home, empty", widthDp = 393, heightDp = 852, showBackground = true)
@Composable
fun HomePreviewEmpty() = HomePreview(emptyList(), Link.SEARCHING, backgroundReady = false)
