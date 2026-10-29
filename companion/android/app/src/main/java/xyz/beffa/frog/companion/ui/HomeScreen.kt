package xyz.beffa.frog.companion.ui

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import android.text.format.DateUtils
import android.text.format.Formatter
import android.util.Size
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.beffa.frog.companion.R
import xyz.beffa.frog.companion.clipboard.ContentReader
import xyz.beffa.frog.companion.clipboard.TooLargeException
import xyz.beffa.frog.companion.data.DeliveryState
import xyz.beffa.frog.companion.data.Direction
import xyz.beffa.frog.companion.data.HistoryItem
import xyz.beffa.frog.companion.protocol.ClipKind
import xyz.beffa.frog.companion.service.CompanionController
import xyz.beffa.frog.companion.service.CompanionStatus
import xyz.beffa.frog.companion.service.Link
import xyz.beffa.frog.companion.service.SendResult

/** Narrows the Recent list, like Frog's FilterTag row on the Mac. */
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

    HomeContent(
        status = status,
        history = history,
        now = now,
        openedAt = openedAt,
        onSend = {
            // The app has window focus here, so it may read the clipboard directly.
            val snapshot = runCatching { ContentReader.primaryClip(context) }.getOrNull()
            if (snapshot == null) {
                Toast.makeText(context, "Clipboard is empty", Toast.LENGTH_SHORT).show()
                return@HomeContent
            }
            scope.launch {
                val result = withContext(Dispatchers.IO) {
                    try {
                        controller.send(ContentReader.fromSnapshot(context, snapshot))
                    } catch (_: TooLargeException) {
                        SendResult.TooLarge
                    } catch (_: Exception) {
                        SendResult.Empty
                    }
                }
                sendMessage(result)?.let { Toast.makeText(context, it, Toast.LENGTH_SHORT).show() }
            }
        },
        onCopy = { item ->
            if (copyAgain(context, item)) Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
        },
        onOpenSettings = onOpenSettings,
        onAddTile = { requestAddSendTile(context) },
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeContent(
    status: CompanionStatus,
    history: List<HistoryItem>,
    now: Long,
    openedAt: Long,
    onSend: () -> Unit,
    onCopy: (HistoryItem) -> Unit,
    onOpenSettings: () -> Unit,
    onAddTile: () -> Unit,
    showBackgroundCard: Boolean = true,
    showAddTile: Boolean = canRequestTile,
) {
    val frog = frogColors
    var filter by rememberSaveable { mutableStateOf(HistoryFilter.ALL) }
    val shown = remember(history, filter) { history.filter { filter.kind == null || it.kind == filter.kind } }

    Scaffold(
        containerColor = frog.canvas,
        topBar = {
            TopAppBar(
                title = { Text("Frog Companion", style = FrogType.title, color = frog.ink) },
                actions = {
                    IconButton(onClick = onOpenSettings) {
                        Icon(Icons.Filled.Settings, contentDescription = "Settings", tint = frog.muted)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = frog.canvas),
            )
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                start = 16.dp,
                end = 16.dp,
                top = padding.calculateTopPadding() + 4.dp,
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "status") { StatusCard(status) }
            if (showBackgroundCard) {
                item(key = "background") { BackgroundCard(Modifier.padding(top = 12.dp)) }
            }
            item(key = "send") { SendButton(onSend, Modifier.padding(top = 12.dp)) }
            item(key = "send-hint") { SendHint(showAddTile, onAddTile, Modifier.padding(top = 8.dp, bottom = 20.dp)) }
            item(key = "recent-title") {
                SectionCaption("Recent", trailing = if (history.isEmpty()) null else "${history.size}")
            }
            if (history.isNotEmpty()) {
                item(key = "filters") { FilterRow(filter, history) { filter = it } }
            }
            historyCard(shown, history.isEmpty(), filter, now, openedAt, status.macName, onCopy)
        }
    }
}

// Status ---------------------------------------------------------------------------------------

@Composable
private fun StatusCard(status: CompanionStatus) {
    val reduced = LocalReducedMotion.current
    val frog = frogColors
    val dotColor by animateColorAsState(
        targetValue = when (status.link) {
            Link.WIFI -> frog.good
            Link.BLUETOOTH -> frog.link
            Link.SEARCHING -> frog.warning
            Link.OFFLINE -> frog.muted.copy(alpha = 0.5f)
        },
        animationSpec = motionSpec(reduced),
        label = "dot",
    )
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(FrogRadius.card))
            .background(frog.surface)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(44.dp).clip(RoundedCornerShape(FrogRadius.control)).background(frog.accentSoft),
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(R.drawable.ic_frog_glyph), contentDescription = null, tint = frog.accent, modifier = Modifier.size(26.dp))
        }
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
                Box(Modifier.size(8.dp).clip(CircleShape).background(dotColor))
                Spacer(Modifier.width(6.dp))
                AnimatedContent(
                    targetState = status.link,
                    transitionSpec = {
                        if (reduced) {
                            fadeIn(motionSpec(true)) togetherWith fadeOut(motionSpec(true))
                        } else {
                            (fadeIn(motionSpec(false)) + slideInVertically(motionSpec(false)) { it / 4 } +
                                scaleIn(motionSpec(false), initialScale = 0.95f)) togetherWith fadeOut(motionSpec(false, 120))
                        }
                    },
                    label = "link",
                ) { link ->
                    Text(
                        when (link) {
                            Link.WIFI -> "Connected over Wi-Fi"
                            Link.BLUETOOTH -> "Connected over Bluetooth"
                            Link.SEARCHING -> "Looking for your Mac"
                            Link.OFFLINE -> "Offline. Frog Companion keeps trying."
                        },
                        style = FrogType.small,
                        color = frog.muted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun SendButton(onSend: () -> Unit, modifier: Modifier = Modifier) {
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && !reduced) 0.97f else 1f,
        animationSpec = tween(120, easing = EaseOutStrong),
        label = "press",
    )

    Button(
        onClick = {
            view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
            onSend()
        },
        interactionSource = interaction,
        shape = RoundedCornerShape(FrogRadius.control),
        contentPadding = PaddingValues(horizontal = 16.dp),
        colors = ButtonDefaults.buttonColors(),
        modifier = modifier
            .fillMaxWidth()
            .height(56.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            },
    ) {
        Icon(painterResource(R.drawable.ic_dir_sent), contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text("Send clipboard", style = FrogType.bodyMedium)
    }
}

/**
 * Why sending takes a tap, and the other places to tap. Android lets an app read the clipboard
 * only while it is on screen, so every send from the phone starts with a tap.
 */
@Composable
private fun SendHint(showAddTile: Boolean, onAddTile: () -> Unit, modifier: Modifier = Modifier) {
    val frog = frogColors
    Column(modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
        Text(
            "Android only lets apps read your clipboard when you tap. Send from here, the notification's " +
                "Send clipboard button, the Send to Mac tile, or the share sheet.",
            style = FrogType.small,
            color = frog.muted,
        )
        if (showAddTile) {
            Box(
                Modifier
                    .padding(top = 2.dp)
                    .heightIn(min = 48.dp)
                    .clip(RoundedCornerShape(FrogRadius.control))
                    .clickable(role = Role.Button, onClick = onAddTile)
                    .padding(horizontal = 4.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                Text("Add the Send to Mac tile", style = FrogType.label, color = frog.accent)
            }
        }
    }
}

// Recent -------------------------------------------------------------------------------------

/** A small medium-weight label above content, like Frog's SectionCaption. */
@Composable
private fun SectionCaption(title: String, trailing: String? = null) {
    val frog = frogColors
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = FrogType.label, color = frog.muted, modifier = Modifier.weight(1f))
        if (trailing != null) Text(trailing, style = FrogType.caption, color = frog.muted)
    }
}

@Composable
private fun FilterRow(selected: HistoryFilter, history: List<HistoryItem>, onSelect: (HistoryFilter) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        for (f in HistoryFilter.entries) {
            // A kind with nothing in it stays out of the way, as long as it isn't the current one.
            if (f.kind != null && f != selected && history.none { it.kind == f.kind }) continue
            FilterTag(f.title, f == selected) { onSelect(f) }
        }
    }
}

/**
 * Frog's FilterTag: plain text, muted until chosen; the chosen one is medium weight on the
 * selection fill. The touch target is 48 dp tall around a 32 dp tag.
 */
@Composable
private fun FilterTag(title: String, selected: Boolean, onClick: () -> Unit) {
    val frog = frogColors
    val reduced = LocalReducedMotion.current
    val fill by animateColorAsState(if (selected) frog.selection else Color.Transparent, motionSpec(reduced, 150), label = "tag")
    Box(
        Modifier
            .heightIn(min = 48.dp)
            .selectable(selected = selected, role = Role.Tab, onClick = onClick, interactionSource = null, indication = null),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title,
            style = if (selected) FrogType.label else FrogType.small,
            color = if (selected) frog.ink else frog.muted,
            modifier = Modifier
                .clip(RoundedCornerShape(FrogRadius.control))
                .background(fill)
                .padding(horizontal = 12.dp, vertical = 7.dp),
        )
    }
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
    onCopy: (HistoryItem) -> Unit,
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
                .background(frogColors.surface, segmentShape(first, last))
                .padding(start = 6.dp, end = 6.dp, top = if (first) 6.dp else 1.dp, bottom = if (last) 6.dp else 1.dp),
        ) {
            HistoryRow(item, now, isNew = item.timeMillis > openedAt, macName = macName, onCopy = onCopy)
        }
    }
}

@Composable
private fun EmptyHistory(filter: HistoryFilter?, macName: String?) {
    val frog = frogColors
    val (title, message) = when (filter?.kind) {
        null -> "Nothing here yet" to
            "Copy something on ${macName ?: "your Mac"} and it shows up here. To send from your phone, " +
            "tap Send clipboard, use the Quick Settings tile, or share to Frog Companion."
        ClipKind.TEXT -> "No text yet" to "Copied text from either side shows up here."
        ClipKind.IMAGE -> "No images yet" to "Copied images and shared photos show up here."
        ClipKind.FILE -> "No files yet" to "Files from your Mac are saved to Downloads and listed here."
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(FrogRadius.card))
            .background(frog.surface)
            .padding(horizontal = 24.dp, vertical = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = FrogType.bodyMedium, color = frog.ink)
        Spacer(Modifier.height(4.dp))
        Text(message, style = FrogType.small, color = frog.muted, textAlign = TextAlign.Center)
    }
}

@Composable
private fun HistoryRow(item: HistoryItem, now: Long, isNew: Boolean, macName: String?, onCopy: (HistoryItem) -> Unit) {
    val context = LocalContext.current
    val view = LocalView.current
    val reduced = LocalReducedMotion.current
    val density = LocalDensity.current
    val frog = frogColors
    val appear = remember(item.id) { Animatable(if (isNew && !reduced) 0f else 1f) }
    LaunchedEffect(item.id) {
        if (appear.value < 1f) appear.animateTo(1f, tween(MOTION_MS, easing = EaseOutStrong))
    }
    val offsetPx = with(density) { 6.dp.toPx() }
    val pending = pendingLabel(item)

    Row(
        Modifier
            .fillMaxWidth()
            .graphicsLayer {
                val v = appear.value
                alpha = v
                scaleX = 0.95f + 0.05f * v
                scaleY = 0.95f + 0.05f * v
                translationY = (1f - v) * offsetPx
            }
            .clip(RoundedCornerShape(FrogRadius.control))
            .clickable(onClickLabel = "Copy") {
                view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                onCopy(item)
            }
            .heightIn(min = 56.dp)
            .padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Leading(item)
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
                    tint = frog.muted,
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
    }
}

private fun title(item: HistoryItem): String = when (item.kind) {
    ClipKind.TEXT -> item.preview.replace('\n', ' ').trim().ifBlank { "Empty text" }
    else -> item.name ?: item.preview.ifBlank { if (item.kind == ClipKind.IMAGE) "Image" else "File" }
}

/** A 36 dp tile: the image itself for images, otherwise the kind's icon on the inset fill. */
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
            Image(bitmap = it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = tile.background(frog.inset))
            return
        }
    }
    Box(tile.background(frog.inset), contentAlignment = Alignment.Center) {
        Icon(painterResource(kindIcon(item.kind)), contentDescription = null, tint = frog.muted, modifier = Modifier.size(18.dp))
    }
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

private fun copyAgain(context: Context, item: HistoryItem): Boolean {
    item.text?.let {
        ContentReader.copyText(context, it)
        return true
    }
    val uri = item.uri ?: return false
    return runCatching { ContentReader.copyUri(context, Uri.parse(uri), item.name ?: "Frog Companion") }.isSuccess
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
private fun HomePreview(history: List<HistoryItem>, link: Link, dark: Boolean = false) {
    FrogTheme(dark = dark, dynamicColor = false) {
        HomeContent(
            status = CompanionStatus(paired = true, macName = "Studio Mac", link = link),
            history = history,
            now = PREVIEW_NOW,
            openedAt = PREVIEW_NOW,
            onSend = {},
            onCopy = {},
            onOpenSettings = {},
            onAddTile = {},
            showBackgroundCard = false,
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
fun HomePreviewEmpty() = HomePreview(emptyList(), Link.SEARCHING)
