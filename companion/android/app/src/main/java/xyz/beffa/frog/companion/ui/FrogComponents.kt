package xyz.beffa.frog.companion.ui

import androidx.annotation.DrawableRes
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import xyz.beffa.frog.companion.R

/*
 * Frog's components on a phone, after native/FrogApp/Views/DesignSystem.swift and Views/Design: one
 * button, one switch, one segmented control, cards that are a thin layer of ink, and a line only
 * between two rows of a section card. Screens never invent their own.
 */

val Capsule = RoundedCornerShape(percent = 50)

// Press --------------------------------------------------------------------------------------------

/** Scale 0.97 while held, on Frog's `press` curve; none under reduced motion. */
@Composable
internal fun pressScale(pressed: Boolean): Float {
    val reduced = LocalReducedMotion.current
    val scale by animateFloatAsState(
        targetValue = if (pressed && !reduced) 0.97f else 1f,
        animationSpec = tween(FrogMotion.PRESS_MS, easing = EaseOutStrong),
        label = "press",
    )
    return scale
}

/** A fill that arrives at once on press and fades out after release. */
@Composable
internal fun pressFill(pressed: Boolean, rest: Color, held: Color): Color {
    val reduced = LocalReducedMotion.current
    val fill by animateColorAsState(if (pressed) held else rest, FrogMotion.release(pressed, reduced), label = "fill")
    return fill
}

// Buttons ------------------------------------------------------------------------------------------

enum class FrogButtonKind {
    /** The one main action of a screen or card: the accent. */
    Primary,
    /** Every other action. */
    Secondary,
    /** Actions beside content, such as Cancel or Skip: no fill until pressed. */
    Ghost,
    /** Removes something. */
    Destructive,
}

enum class FrogButtonSize(val height: Dp) { Compact(FrogSize.control), Regular(FrogSize.button), Hero(FrogSize.hero) }

/**
 * Frog's one button: a capsule, at least [FrogSize.touch] tall to the finger whatever it shows. A
 * press answers on the down event with a deeper fill and a slight shrink.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FrogButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: FrogButtonKind = FrogButtonKind.Secondary,
    size: FrogButtonSize = FrogButtonSize.Regular,
    fill: Boolean = false,
    enabled: Boolean = true,
    @DrawableRes icon: Int? = null,
) {
    val frog = frogColors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val held = pressed && enabled
    val (rest, down) = when (kind) {
        FrogButtonKind.Primary -> frog.accent to frog.accent.copy(alpha = 0.76f)
        FrogButtonKind.Secondary, FrogButtonKind.Destructive -> frog.control to frog.control.compositeOver(frog.pressed)
        FrogButtonKind.Ghost -> Color.Transparent to frog.pressed
    }
    val background = pressFill(held, rest, down)
    val foreground = when (kind) {
        FrogButtonKind.Primary -> frog.onAccent
        FrogButtonKind.Secondary -> frog.ink
        FrogButtonKind.Ghost -> if (held) frog.ink else frog.muted
        FrogButtonKind.Destructive -> frog.critical
    }
    val scale = pressScale(held)
    val compact = size == FrogButtonSize.Compact
    Box(
        modifier
            .heightIn(min = FrogSize.touch)
            .then(if (fill) Modifier.fillMaxWidth() else Modifier)
            .combinedClickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier
                .then(if (fill) Modifier.fillMaxWidth() else Modifier)
                .height(size.height)
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    alpha = if (enabled) 1f else 0.4f
                }
                .clip(Capsule)
                .background(background)
                .padding(horizontal = if (compact) 12.dp else 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            if (icon != null) {
                Icon(painterResource(icon), contentDescription = null, tint = foreground, modifier = Modifier.size(if (compact) 16.dp else 18.dp))
                Spacer(Modifier.width(if (compact) 6.dp else 8.dp))
            }
            Text(
                text,
                style = if (compact) FrogType.label else FrogType.bodyMedium,
                color = foreground,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private fun Color.compositeOver(top: Color): Color {
    // A deeper control fill: the pressed layer over the control layer, both translucent ink.
    val a = top.alpha + alpha * (1 - top.alpha)
    return copy(alpha = a.coerceAtMost(1f))
}

/**
 * An icon-only action: a symbol on a [FrogSize.control]-sized control capsule ([filled]), or a muted
 * symbol that gets a fill only while pressed.
 */
@Composable
fun FrogIconButton(
    painter: Painter,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    filled: Boolean = true,
    visualSize: Dp = 40.dp,
    iconSize: Dp = 20.dp,
    tint: Color? = null,
    onLongClick: (() -> Unit)? = null,
) {
    val frog = frogColors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val rest = if (filled) frog.control else Color.Transparent
    val background = pressFill(pressed, rest, if (filled) rest.compositeOver(frog.pressed) else frog.pressed)
    val scale = pressScale(pressed)
    @OptIn(ExperimentalFoundationApi::class)
    Box(
        modifier
            .size(FrogSize.touch)
            .combinedClickable(
                interactionSource = interaction,
                indication = null,
                role = Role.Button,
                onClickLabel = contentDescription,
                onLongClick = onLongClick,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(visualSize)
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                }
                .clip(CircleShape)
                .background(background),
            contentAlignment = Alignment.Center,
        ) {
            Icon(painter, contentDescription = contentDescription, tint = tint ?: if (filled) frog.ink else frog.muted, modifier = Modifier.size(iconSize))
        }
    }
}

// Switch -------------------------------------------------------------------------------------------

/**
 * Frog's switch (Rex's): a 2:1 capsule track, the accent when on, with a wide light knob that slides
 * on a spring with no bounce. The row around it carries the touch target and the label.
 */
@Composable
fun FrogSwitchVisual(checked: Boolean, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val frog = frogColors
    val reduced = LocalReducedMotion.current
    val width = 44.dp
    val height = 22.dp
    val knobWidth = width * 0.66f
    val knobHeight = height - 4.dp
    val offset by animateDpAsState(if (checked) width - knobWidth - 2.dp else 2.dp, FrogMotion.slide(reduced), label = "knob")
    val track by animateColorAsState(if (checked) frog.accent else frog.switchTrack, FrogMotion.slide(reduced), label = "track")
    val knob = when {
        checked -> Color.White.copy(alpha = 0.92f).let { if (frog.dark) frog.onAccent else it }
        frog.dark -> Color(0xFFE6E6E6)
        else -> Color.White
    }
    Box(
        modifier
            .size(width, height)
            .graphicsLayer { alpha = if (enabled) 1f else 0.45f }
            .clip(Capsule)
            .background(track)
            .clearAndSetSemantics { },
    ) {
        Box(
            Modifier
                .offset(x = offset, y = 2.dp)
                .size(knobWidth, knobHeight)
                .then(if (frog.dark) Modifier else Modifier.shadow(1.dp, Capsule, clip = false))
                .clip(Capsule)
                .background(knob),
        )
    }
}

// Surfaces -----------------------------------------------------------------------------------------

/** The card every grouped surface uses: a thin layer of ink over the canvas, no border, no shadow. */
fun Modifier.frogCard(): Modifier = composed { clip(RoundedCornerShape(FrogRadius.card)).background(frogColors.card) }

/** A padded card. */
@Composable
fun FrogCard(modifier: Modifier = Modifier, padding: PaddingValues = PaddingValues(FrogSize.cardPadding), content: @Composable () -> Unit) {
    Column(modifier.fillMaxWidth().frogCard().padding(padding)) { content() }
}

/** What goes in a [FrogSection]: rows, which get a thin line between each two, and notes, which stay with the row above. */
class FrogSectionScope {
    internal val items = mutableListOf<Pair<Boolean, @Composable () -> Unit>>()
    fun row(content: @Composable () -> Unit) { items += true to content }
    fun note(content: @Composable () -> Unit) { items += false to content }
}

/**
 * A group of rows: an optional heading above one card, and an optional one-sentence footer. The card
 * draws a thin line between two rows, inset to the content edge; nothing else in Frog draws lines.
 */
@Composable
fun FrogSection(
    title: String? = null,
    modifier: Modifier = Modifier,
    footer: String? = null,
    accessory: (@Composable RowScope.() -> Unit)? = null,
    content: FrogSectionScope.() -> Unit,
) {
    val frog = frogColors
    val scope = FrogSectionScope().apply(content)
    Column(modifier.fillMaxWidth()) {
        if (title != null || accessory != null) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 28.dp).padding(horizontal = FrogSize.cardPadding),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (title != null) {
                    Text(title, style = FrogType.section, color = frog.ink, modifier = Modifier.weight(1f).semantics { heading() })
                } else {
                    Spacer(Modifier.weight(1f))
                }
                accessory?.invoke(this)
            }
            Spacer(Modifier.height(8.dp))
        }
        Column(Modifier.fillMaxWidth().frogCard().padding(horizontal = FrogSize.cardPadding)) {
            scope.items.forEachIndexed { index, (isRow, item) ->
                if (isRow && index > 0 && scope.items[index - 1].first) {
                    Box(Modifier.fillMaxWidth().height(0.5.dp).background(frog.separator))
                }
                item()
            }
        }
        if (footer != null) {
            Text(
                footer,
                style = FrogType.small,
                color = frog.muted,
                modifier = Modifier.padding(start = FrogSize.cardPadding, end = FrogSize.cardPadding, top = 8.dp),
            )
        }
    }
}

/**
 * One setting: a title, at most one short caption, and its control on the trailing side. At least
 * [FrogSize.row] tall. With [onClick] the whole row answers a tap with a pressed fill.
 */
@Composable
fun FrogRow(
    title: String,
    modifier: Modifier = Modifier,
    caption: String? = null,
    captionColor: Color? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    val frog = frogColors
    Row(
        modifier.fillMaxWidth().heightIn(min = FrogSize.row).padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            leading()
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = FrogType.body, color = frog.ink)
            if (caption != null) Text(caption, style = FrogType.small, color = captionColor ?: frog.muted)
        }
        if (trailing != null) {
            Spacer(Modifier.width(12.dp))
            trailing()
        }
    }
}

/** A row whose trailing control is Frog's switch; the whole row toggles it. */
@Composable
fun FrogSwitchRow(title: String, checked: Boolean, onToggle: () -> Unit, caption: String? = null, leading: (@Composable () -> Unit)? = null) {
    Box(
        Modifier
            .fillMaxWidth()
            .toggleable(
                value = checked,
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                role = Role.Switch,
                onValueChange = { onToggle() },
            ),
    ) {
        FrogRow(title, caption = caption, leading = leading) { FrogSwitchVisual(checked) }
    }
}

/** A sentence inside a section card that belongs to no row: a status, a warning, a hint. */
@Composable
fun FrogRowNote(text: String, tone: Color? = null) {
    Text(
        text,
        style = FrogType.small,
        color = tone ?: frogColors.muted,
        modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
    )
}

/** A neutral symbol on a control-filled tile. */
@Composable
fun SymbolTile(@DrawableRes icon: Int, size: Dp = 36.dp, tint: Color? = null, background: Color? = null) {
    val frog = frogColors
    Box(
        Modifier.size(size).clip(RoundedCornerShape(FrogRadius.control)).background(background ?: frog.control),
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(icon), contentDescription = null, tint = tint ?: frog.muted, modifier = Modifier.size(size * 0.5f))
    }
}

/** Frog's mark: the frog's face on the app icon's sage tile. */
@Composable
fun FrogMark(size: Dp = 32.dp) {
    val radius = when {
        size >= 56.dp -> FrogRadius.card
        size >= 36.dp -> FrogRadius.control
        else -> 8.dp
    }
    Box(
        Modifier.size(size).clip(RoundedCornerShape(radius)).background(FrogBrand.tile).clearAndSetSemantics { },
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(R.drawable.ic_frog_glyph), contentDescription = null, tint = FrogBrand.face, modifier = Modifier.size(size * 0.72f))
    }
}

/** A small tag beside a title: the accent's soft fill when [active]. */
@Composable
fun FrogBadge(text: String, active: Boolean = false, tone: Color? = null) {
    val frog = frogColors
    val color = tone ?: if (active) frog.accent else frog.muted
    Text(
        text,
        style = FrogType.caption.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
        color = color,
        modifier = Modifier
            .clip(RoundedCornerShape(FrogRadius.small))
            .background(if (tone != null) tone.copy(alpha = 0.14f) else if (active) frog.accentSoft else frog.control)
            .padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

/** A capsule with a check, in the good tone: something that is set up. */
@Composable
fun FrogStatusPill(text: String, icon: ImageVector = Icons.Filled.Check) {
    val frog = frogColors
    Row(
        Modifier.height(32.dp).clip(Capsule).background(frog.good.copy(alpha = 0.14f)).padding(start = 10.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = frog.good, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, style = FrogType.label, color = frog.ink)
    }
}

/** A coloured dot for status. */
@Composable
fun StatusDot(color: Color, size: Dp = 8.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

// Segments -----------------------------------------------------------------------------------------

/**
 * Frog's segmented control: a capsule track with one accent thumb that slides to the chosen segment.
 * Under reduced motion the thumb jumps. Each segment is a full touch target tall.
 */
@Composable
fun <T> FrogSegments(values: List<T>, selected: T, title: (T) -> String, onSelect: (T) -> Unit, modifier: Modifier = Modifier) {
    val frog = frogColors
    val reduced = LocalReducedMotion.current
    val density = LocalDensity.current
    val bounds = remember { mutableStateMapOf<Int, Pair<Float, Float>>() }
    val index = values.indexOf(selected).coerceAtLeast(0)
    val target = bounds[index]
    val thumbX by animateFloatAsState(target?.first ?: 0f, FrogMotion.slide(reduced), label = "thumbX")
    val thumbW by animateFloatAsState(target?.second ?: 0f, FrogMotion.slide(reduced), label = "thumbW")
    val trackHeight = 36.dp
    Box(modifier.height(FrogSize.touch), contentAlignment = Alignment.CenterStart) {
        Box(Modifier.matchParentWidthOfRow(bounds, values.size).height(trackHeight).clip(Capsule).background(frog.control))
        if (target != null) {
            Box(
                Modifier
                    .offset(x = with(density) { thumbX.toDp() })
                    .width(with(density) { thumbW.toDp() })
                    .height(trackHeight)
                    .clip(Capsule)
                    .background(frog.accent),
            )
        }
        Row(Modifier.fillMaxHeight()) {
            values.forEachIndexed { i, value ->
                val chosen = i == index
                val color by animateColorAsState(if (chosen) frog.onAccent else frog.ink, FrogMotion.slide(reduced), label = "segText")
                Box(
                    Modifier
                        .fillMaxHeight()
                        .onGloballyPositioned { bounds[i] = it.positionInParentX() to it.size.width.toFloat() }
                        .selectable(selected = chosen, role = Role.Tab, interactionSource = null, indication = null) { onSelect(value) }
                        .padding(horizontal = 14.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(title(value), style = if (chosen) FrogType.label else FrogType.small, color = color, maxLines = 1)
                }
            }
        }
    }
}

private fun androidx.compose.ui.layout.LayoutCoordinates.positionInParentX(): Float =
    parentLayoutCoordinates?.let { parent -> parent.localPositionOf(this, androidx.compose.ui.geometry.Offset.Zero).x } ?: 0f

/** The track spans the segments it holds. */
@Composable
private fun Modifier.matchParentWidthOfRow(bounds: Map<Int, Pair<Float, Float>>, count: Int): Modifier {
    val density = LocalDensity.current
    val last = bounds[count - 1] ?: return this.width(0.dp)
    return this.width(with(density) { (last.first + last.second).toDp() })
}

// Screen -------------------------------------------------------------------------------------------

/**
 * A screen: the bar on top in the canvas colour, with a veil that fades content scrolled up beneath
 * it, and the content under it, given the padding it needs to clear the bar and the system bars.
 */
@Composable
fun FrogScreen(
    title: String?,
    navigation: (@Composable () -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    actions: (@Composable RowScope.() -> Unit)? = null,
    content: @Composable BoxScope.(PaddingValues) -> Unit,
) {
    val frog = frogColors
    val status = WindowInsets.statusBars.asPaddingValues()
    val nav = WindowInsets.navigationBars.asPaddingValues()
    val top = status.calculateTopPadding()
    Box(Modifier.fillMaxSize().background(frog.canvas)) {
        content(PaddingValues(top = top + FrogSize.toolbar, bottom = nav.calculateBottomPadding()))
        Column(Modifier.fillMaxWidth()) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(frog.canvas)
                    .padding(top = top)
                    .height(FrogSize.toolbar)
                    .padding(start = if (navigation != null) 4.dp else FrogSize.pagePadding, end = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                navigation?.invoke()
                if (leading != null) {
                    leading()
                    Spacer(Modifier.width(10.dp))
                }
                if (title != null) {
                    Text(
                        title,
                        style = FrogType.toolbarTitle,
                        color = frog.ink,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f).semantics { heading() },
                    )
                } else {
                    Spacer(Modifier.weight(1f))
                }
                actions?.invoke(this)
            }
            Box(Modifier.fillMaxWidth().height(12.dp).background(Brush.verticalGradient(listOf(frog.canvas, frog.canvas.copy(alpha = 0f)))))
        }
    }
}

/** The back action in a screen's bar. */
@Composable
fun FrogBackButton(onBack: () -> Unit) {
    FrogIconButton(rememberVectorPainter(Icons.AutoMirrored.Filled.ArrowBack), contentDescription = "Back", onClick = onBack, filled = true, visualSize = 36.dp)
}

/** An empty list: a symbol, a title and one sentence. */
@Composable
fun FrogEmptyState(@DrawableRes icon: Int, title: String, message: String, modifier: Modifier = Modifier) {
    val frog = frogColors
    Column(
        modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        SymbolTile(icon, size = 40.dp)
        Spacer(Modifier.height(12.dp))
        Text(title, style = FrogType.section, color = frog.ink, textAlign = TextAlign.Center)
        Spacer(Modifier.height(4.dp))
        Text(message, style = FrogType.small, color = frog.muted, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 320.dp))
    }
}

// Dialog -------------------------------------------------------------------------------------------

/** A confirmation on Frog's panel: title, one sentence, and Cancel beside the action. */
@Composable
fun FrogConfirmDialog(
    title: String,
    message: String,
    confirm: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    destructive: Boolean = false,
) {
    val frog = frogColors
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(FrogRadius.panel))
                .background(frog.surface)
                .background(frog.card)
                .padding(start = 20.dp, end = 12.dp, top = 20.dp, bottom = 8.dp),
        ) {
            Text(title, style = FrogType.section, color = frog.ink, modifier = Modifier.padding(end = 8.dp))
            Spacer(Modifier.height(6.dp))
            Text(message, style = FrogType.small, color = frog.muted, modifier = Modifier.padding(end = 8.dp))
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                FrogButton("Cancel", onDismiss, kind = FrogButtonKind.Ghost)
                FrogButton(confirm, onConfirm, kind = if (destructive) FrogButtonKind.Destructive else FrogButtonKind.Primary)
            }
        }
    }
}

/** Gives a composable a spoken label without changing what it draws. */
fun Modifier.spoken(label: String): Modifier = semantics { contentDescription = label }
