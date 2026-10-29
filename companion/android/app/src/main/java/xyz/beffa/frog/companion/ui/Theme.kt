package xyz.beffa.frog.companion.ui

import android.os.Build
import android.provider.Settings
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
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

/** Strong ease-out: fast start, gentle settle. Frog's `reveal` curve; used for every enter/state transition. */
val EaseOutStrong = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)

const val MOTION_MS = 180

/** True when the user turned animations off (animator duration scale 0). */
val LocalReducedMotion = staticCompositionLocalOf { false }

fun <T> motionSpec(reduced: Boolean, durationMs: Int = MOTION_MS): FiniteAnimationSpec<T> =
    if (reduced) snap() else tween(durationMs, easing = EaseOutStrong)

/**
 * Frog's radii (docs/design.md: small 4, control 6, card 10, panel 12 points), scaled for a phone
 * held closer than a Mac screen and keeping the same steps between them.
 */
object FrogRadius {
    /** Badges, swatches, thumbnails inside a row. */
    val small = 4.dp
    /** Buttons, fields, filter tags, rows and their pressed fill, icon tiles. */
    val control = 8.dp
    /** Cards, lists, banners. */
    val card = 12.dp
    /** Sheets and dialogs. */
    val panel = 16.dp
}

/**
 * Frog's type scale on a phone: the Mac's 13 / 12 / 11 / 10 point steps become 16 / 15 / 13 / 12 sp
 * so a row reads at arm's length while keeping the same hierarchy.
 */
object FrogType {
    /** Page titles. */
    val title = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold)
    /** Section headings, card titles, empty-state titles. */
    val section = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
    /** Subtitles and empty-state messages. */
    val lead = TextStyle(fontSize = 15.sp, lineHeight = 21.sp)
    /** Row titles and list items. */
    val body = TextStyle(fontSize = 15.sp, lineHeight = 20.sp)
    /** Buttons and titles of cards and settings. */
    val bodyMedium = TextStyle(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium)
    /** Row descriptions and secondary lines. */
    val small = TextStyle(fontSize = 13.sp, lineHeight = 18.sp)
    /** Section captions and filter tags. */
    val label = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium)
    /** Timestamps, sizes, counts. */
    val caption = TextStyle(fontSize = 12.sp, lineHeight = 16.sp)
}

/** Frog's surface and text roles (DesignSystem.swift, theme "Frog"), resolved for light or dark. */
@Immutable
data class FrogColors(
    val canvas: Color,
    val surface: Color,
    val inset: Color,
    val ink: Color,
    val muted: Color,
    val accent: Color,
    val good: Color,
    val warning: Color,
    val critical: Color,
    val link: Color,
) {
    /** What is chosen. */
    val selection: Color get() = accent.copy(alpha = 0.13f)
    /** A soft accent fill behind an accent icon. */
    val accentSoft: Color get() = accent.copy(alpha = 0.15f)
    /** A control held down. Neutral, so it reads the same with any accent. */
    val pressed: Color get() = ink.copy(alpha = 0.08f)
}

/** Frog's own green, `A3D8AF`, with a darker step that stays readable on white. */
private val FrogGreen = Color(0xFFA3D8AF)
private val FrogGreenDeep = Color(0xFF2F7A45)

private val LightFrogColors = FrogColors(
    canvas = Color(0xFFF7F7F5),
    surface = Color(0xFFFFFFFF),
    inset = Color(0xFFF0F0EE),
    ink = Color(0xFF252525),
    muted = Color(0xFF73736F),
    accent = FrogGreenDeep,
    good = Color(0xFF2F8F4E),
    warning = Color(0xFFB7791F),
    critical = Color(0xFFC8443C),
    link = Color(0xFF3B6FC4),
)

private val DarkFrogColors = FrogColors(
    canvas = Color(0xFF151515),
    surface = Color(0xFF1E1E1F),
    inset = Color(0xFF2A2A2B),
    ink = Color(0xFFE8E8E8),
    muted = Color(0xFFA0A0A3),
    accent = FrogGreen,
    good = Color(0xFF8FD9A0),
    warning = Color(0xFFE8B866),
    critical = Color(0xFFF07F78),
    link = Color(0xFF8DB4F2),
)

val LocalFrogColors = staticCompositionLocalOf { LightFrogColors }

/** Shortcut for `LocalFrogColors.current`. */
val frogColors: FrogColors
    @Composable get() = LocalFrogColors.current

private val FallbackLight = lightColorScheme(
    primary = FrogGreenDeep,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFC4EBCB),
    onPrimaryContainer = Color(0xFF0B2B15),
    secondary = Color(0xFF4F6352),
    secondaryContainer = Color(0xFFD2E8D3),
    onSecondaryContainer = Color(0xFF0D1F10),
    tertiary = Color(0xFF3A6470),
    tertiaryContainer = Color(0xFFDDEFE0),
    onTertiaryContainer = Color(0xFF15301C),
)
private val FallbackDark = darkColorScheme(
    primary = FrogGreen,
    onPrimary = Color(0xFF0D3A1C),
    primaryContainer = Color(0xFF23502F),
    onPrimaryContainer = Color(0xFFC4EBCB),
    secondary = Color(0xFFB6CCB8),
    secondaryContainer = Color(0xFF37493A),
    onSecondaryContainer = Color(0xFFD2E8D3),
    tertiary = Color(0xFFA2CDDB),
    tertiaryContainer = Color(0xFF2A3D2F),
    onTertiaryContainer = Color(0xFFDDEFE0),
)

/**
 * Accents follow the wallpaper on Android 12+ (Material You); everything else is Frog's: its quiet
 * neutral surfaces and text. Without dynamic color the accent is Frog green.
 */
private fun ColorScheme.withFrogNeutrals(f: FrogColors): ColorScheme = copy(
    background = f.canvas,
    onBackground = f.ink,
    surface = f.canvas,
    onSurface = f.ink,
    onSurfaceVariant = f.muted,
    surfaceContainerLowest = f.surface,
    surfaceContainerLow = f.surface,
    surfaceContainer = f.surface,
    surfaceContainerHigh = f.inset,
    surfaceContainerHighest = f.inset,
    surfaceVariant = f.inset,
    outlineVariant = f.inset,
)

@Composable
fun FrogTheme(
    dark: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit) {
    val context = LocalContext.current
    val preview = LocalInspectionMode.current
    val dynamic = dynamicColor && Build.VERSION.SDK_INT >= 31 && !preview
    val base = when {
        dynamic && dark -> dynamicDarkColorScheme(context)
        dynamic -> dynamicLightColorScheme(context)
        dark -> FallbackDark
        else -> FallbackLight
    }
    val neutrals = if (dark) DarkFrogColors else LightFrogColors
    val frog = neutrals.copy(accent = base.primary)
    val scheme = base.withFrogNeutrals(frog)
    val reduced = remember {
        !preview && Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    CompositionLocalProvider(LocalReducedMotion provides reduced, LocalFrogColors provides frog) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
