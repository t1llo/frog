package xyz.beffa.frog.companion.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import xyz.beffa.frog.companion.CompanionApp
import xyz.beffa.frog.companion.service.CompanionService

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            FrogTheme { CompanionRoot() }
        }
    }

    override fun onStart() {
        super.onStart()
        // Opening the app (re)starts the link if a Mac is paired.
        CompanionService.start(this)
    }
}

private enum class Screen { ONBOARDING, PAIR, HOME, SETTINGS }

@Composable
private fun CompanionRoot() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val controller = remember { CompanionApp.controller(context) }
    val status by controller.status.collectAsStateWithLifecycle()
    var onboarded by remember { mutableStateOf(controller.store.onboardingDone) }
    var showSettings by rememberSaveable { mutableStateOf(false) }
    val reduced = LocalReducedMotion.current

    val screen = when {
        !onboarded -> Screen.ONBOARDING
        !status.paired -> Screen.PAIR
        showSettings -> Screen.SETTINGS
        else -> Screen.HOME
    }
    BackHandler(enabled = screen == Screen.SETTINGS) { showSettings = false }

    AnimatedContent(
        targetState = screen,
        transitionSpec = { fadeIn(motionSpec(reduced)) togetherWith fadeOut(motionSpec(reduced, 120)) },
        label = "screen",
    ) { target ->
        when (target) {
            Screen.ONBOARDING -> OnboardingScreen(onDone = {
                controller.store.onboardingDone = true
                onboarded = true
            })
            Screen.PAIR -> PairScreen(controller)
            Screen.HOME -> HomeScreen(controller, status, onOpenSettings = { showSettings = true })
            Screen.SETTINGS -> SettingsScreen(controller, status, onBack = { showSettings = false })
        }
    }
}
