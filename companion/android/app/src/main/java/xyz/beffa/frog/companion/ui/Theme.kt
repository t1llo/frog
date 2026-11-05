package xyz.beffa.frog.companion.ui

import android.provider.Settings
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Motion -------------------------------------------------------------------------------------------

/** Strong ease-out (0.23, 1, 0.32, 1): moves at once and settles slowly. Frog's `reveal` curve. */
val EaseOutStrong = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)

/** CSS `ease`, for a fill fading out after a press. */
private val EaseColor = CubicBezierEasing(0.25f, 0.1f, 0.25f, 1f)

/** Durations of Frog's motion tokens (native/FrogApp/Views/Motion.swift). */
object FrogMotion {
    /** A control answering a press: scale 0.97 and a deeper fill. */
    const val PRESS_MS = 140
    /** A pressed fill leaving. It arrives at once. */
    const val RELEASE_MS = 150
    /** Occasional arrivals: a banner, a copy confirmation, a card appearing. */
    const val REVEAL_MS = 200
    /** The same leaving, faster than it came. */
    const val EXIT_MS = 150
    /** How long a copy stays confirmed. */
    const val CONFIRMATION_MS = 1_500L

    /** A choice moving to another option (a switch's knob, the thumb of segments): a spring with no bounce. */
    fun <T> slide(reduced: Boolean): FiniteAnimationSpec<T> =
        if (reduced) snap() else spring(dampingRatio = 1f, stiffness = 500f)

    /** A fill fading after release; instant on the way in. */
    fun <T> release(active: Boolean, reduced: Boolean): FiniteAnimationSpec<T> =
        if (active || reduced) snap() else tween(RELEASE_MS, easing = EaseColor)
}

const val MOTION_MS = FrogMotion.REVEAL_MS

/** True when the user turned animations off (animator duration scale 0). */
val LocalReducedMotion = staticCompositionLocalOf { false }

fun <T> motionSpec(reduced: Boolean, durationMs: Int = MOTION_MS): FiniteAnimationSpec<T> =
    if (reduced) snap() else tween(durationMs, easing = EaseOutStrong)

// Shape and size -----------------------------------------------------------------------------------

/**
 * Frog's radii (docs/design.md). Corners nest: a shape inside another has the outer radius minus the
 * gap between them. Buttons, segments, switches and search fields are capsules.
 */
object FrogRadius {
    /** Badges, swatches: marks inside a control. */
    val small = 4.dp
    /** Rows and their pressed fill, fields, symbol tiles, blocks inside a card. */
    val control = 10.dp
    /** Cards, section cards, lists, banners: their rows sit [FrogSize.listInset] in. */
    val card = 14.dp
    /** Dialogs and floating panels. */
    val panel = 18.dp
    val sidebar = 20.dp
    val window = 28.dp
}

/**
 * Frog's sizes on a phone. The Mac's 28-point controls and 38-point rows keep their proportions at
 * phone scale; every control's touch target is at least [touch] tall around its visual height.
 */
object FrogSize {
    /** Least touch target. */
    val touch = 48.dp
    /** The visual height of a control in a row (Mac: 28). */
    val control = 32.dp
    /** A standalone button (Mac: 28 at a larger type size). */
    val button = 40.dp
    /** The one main action of a screen. */
    val hero = 48.dp
    /** The least height of a row in a section card (Mac: 38). */
    val row = 48.dp
    /** The gap between a card's edge and the rows of a list inside it. */
    val listInset = 4.dp
    /** Where text starts inside a card, and where a section's caption and footer line up. */
    val cardPadding = 14.dp
    /** Space around a screen's content. */
    val pagePadding = 16.dp
    /** Space between sections. */
    val sectionSpacing = 28.dp
    /** The bar above a screen. */
    val toolbar = 56.dp
}

/**
 * Frog's type scale on a phone: the Mac's 13 / 11 / 10 point steps become 15 / 13 / 12 sp so a row
 * reads at arm's length while keeping the same hierarchy.
 */
object FrogType {
    /** Large titles inside a screen, such as the welcome screen's headline. */
    val title = TextStyle(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.6).sp)
    /** The screen's title in the bar above it. */
    val toolbarTitle = TextStyle(fontSize = 20.sp, lineHeight = 26.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.3).sp)
    /** Section headings, card titles, empty-state titles. */
    val section = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.1).sp)
    /** Subtitles and empty-state messages. */
    val lead = TextStyle(fontSize = 15.sp, lineHeight = 21.sp)
    /** Row titles and list items. */
    val body = TextStyle(fontSize = 15.sp, lineHeight = 20.sp)
    /** Buttons and the titles of cards and settings. */
    val bodyMedium = TextStyle(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium)
    /** Row captions and secondary lines. */
    val small = TextStyle(fontSize = 13.sp, lineHeight = 18.sp)
    /** Small labels above content, compact buttons. */
    val label = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium)
    /** Timestamps, sizes, counts, badges. */
    val caption = TextStyle(fontSize = 12.sp, lineHeight = 16.sp)
}

// Colour -------------------------------------------------------------------------------------------

/**
 * Frog's colour roles (DesignSystem.swift), from its default theme, Minimal. Cards, controls, fills
 * and lines are thin layers of the ink colour over the canvas, so nothing needs a border.
 */
@Immutable
data class FrogColors(
    val dark: Boolean,
    val canvas: Color,
    val surface: Color,
    val inset: Color,
    val ink: Color,
    val muted: Color,
    val accent: Color,
    val onAccent: Color,
    val good: Color,
    val warning: Color,
    val critical: Color,
    /** A second, coloured status hue (graph lines, Bluetooth). */
    val series: Color,
) {
    private fun layer(light: Float, dark: Float) = ink.copy(alpha = if (this.dark) dark else light)

    /** Cards and section cards. */
    val card: Color get() = layer(0.035f, 0.05f)
    /** Buttons, fields, segments, symbol tiles: one step above a card. */
    val control: Color get() = layer(0.06f, 0.10f)
    /** A control or row held down. */
    val pressed: Color get() = ink.copy(alpha = 0.10f)
    /** The one line Frog draws: between two rows of a section card. */
    val separator: Color get() = layer(0.09f, 0.15f)
    /** What is chosen. Neutral; the accent shows state. */
    val selection: Color get() = layer(0.08f, 0.10f)
    /** A switch that is off. */
    val switchTrack: Color get() = layer(0.12f, 0.16f)
    /** A soft accent fill behind accent text. */
    val accentSoft: Color get() = accent.copy(alpha = 0.15f)
}

/** The Frog mark: the frog's face in light green on the app icon's sage, in every theme. */
object FrogBrand {
    val tile = Color(0xFF5E8F5F)
    val face = Color(0xFFB4E2BE)
}

private val LightFrogColors = FrogColors(
    dark = false,
    canvas = Color(0xFFFFFFFF),
    surface = Color(0xFFFFFFFF),
    inset = Color(0xFFF0F0F2),
    ink = Color(0xFF23252A),
    muted = Color(0xFF6B6F76),
    accent = Color(0xFF3C4149),
    onAccent = Color(0xFFFFFFFF),
    good = Color(0xFF2B8A57),
    warning = Color(0xFFB7791F),
    critical = Color(0xFFD0443C),
    series = Color(0xFF5E6AD2),
)

private val DarkFrogColors = FrogColors(
    dark = true,
    canvas = Color(0xFF0F1011),
    surface = Color(0xFF141516),
    inset = Color(0xFF1C1C1F),
    ink = Color(0xFFF7F8F8),
    muted = Color(0xFF8A8F98),
    accent = Color(0xFFD0D6E0),
    onAccent = Color(0xFF141516),
    good = Color(0xFF4CB782),
    warning = Color(0xFFF2C94C),
    critical = Color(0xFFEB5757),
    series = Color(0xFF7B84EC),
)

val LocalFrogColors = staticCompositionLocalOf { LightFrogColors }

/** Shortcut for `LocalFrogColors.current`. */
val frogColors: FrogColors
    @Composable get() = LocalFrogColors.current

/**
 * Frog's own look, following the system's light or dark appearance. Material is only the plumbing
 * underneath: no wallpaper colours and no tonal elevation, so every surface is one of Frog's.
 */
@Composable
fun FrogTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val context = LocalContext.current
    val preview = LocalInspectionMode.current
    val frog = if (dark) DarkFrogColors else LightFrogColors
    val base = if (dark) darkColorScheme() else lightColorScheme()
    val scheme = base.copy(
        primary = frog.accent,
        onPrimary = frog.onAccent,
        secondary = frog.accent,
        onSecondary = frog.onAccent,
        tertiary = frog.accent,
        background = frog.canvas,
        onBackground = frog.ink,
        surface = frog.canvas,
        onSurface = frog.ink,
        onSurfaceVariant = frog.muted,
        surfaceTint = Color.Transparent,
        surfaceContainerLowest = frog.surface,
        surfaceContainerLow = frog.surface,
        surfaceContainer = frog.surface,
        surfaceContainerHigh = frog.surface,
        surfaceContainerHighest = frog.inset,
        surfaceVariant = frog.inset,
        outline = frog.separator,
        outlineVariant = frog.separator,
        error = frog.critical,
    )
    val reduced = remember {
        !preview && Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    CompositionLocalProvider(LocalReducedMotion provides reduced, LocalFrogColors provides frog) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
