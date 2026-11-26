package com.khm.snippets.android.app

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.scene.Scene
import androidx.navigation3.scene.SinglePaneSceneStrategy
import androidx.navigation3.ui.NavDisplay
import com.khm.snippets.android.feature.editor.EditorDestination
import com.khm.snippets.android.feature.editor.EditorEmptyPane
import com.khm.snippets.android.feature.library.LibraryDestination
import com.khm.snippets.android.nav.AppNavigator
import com.khm.snippets.android.nav.BackupNewPasswordRoute
import com.khm.snippets.android.nav.EditorRoute
import com.khm.snippets.android.nav.ExportRoute
import com.khm.snippets.android.nav.ImportRoute
import com.khm.snippets.android.nav.LibraryRoute
import com.khm.snippets.android.nav.Panes
import com.khm.snippets.android.nav.PlaceholderScreen
import com.khm.snippets.android.nav.Route
import com.khm.snippets.android.nav.RouteSavedStateConfiguration
import com.khm.snippets.android.nav.SettingsAboutRoute
import com.khm.snippets.android.nav.SettingsAppearanceRoute
import com.khm.snippets.android.nav.SettingsBackupRoute
import com.khm.snippets.android.nav.SettingsDiagnosticsRoute
import com.khm.snippets.android.nav.SettingsNoticesRoute
import com.khm.snippets.android.nav.SettingsRoute
import com.khm.snippets.android.nav.SettingsSecureRoute
import com.khm.snippets.android.nav.SettingsSyncCloudRoute
import com.khm.snippets.android.nav.SettingsSyncGitRoute
import com.khm.snippets.android.nav.SettingsSyncRoute
import com.khm.snippets.android.nav.SyncReviewRoute
import com.khm.snippets.android.nav.TwoPaneSceneStrategy
import com.khm.snippets.android.nav.WindowLayout
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme

/**
 * The one navigation host (DESIGN.md §3): a Navigation 3 back stack of [Route]s that is saved
 * across process death, the two-pane scene of §4, and shared-axis transitions. Back and Up go
 * through [AppNavigator.back], which applies [com.khm.snippets.android.nav.BackPolicy].
 *
 * Every route has an entry. Routes whose screen is not built yet show [PlaceholderScreen] with
 * their route name; whoever builds one replaces its line here.
 */
@Composable
fun SnippetsNavHost(container: AppContainer, layout: WindowLayout) {
    val backStack = rememberNavBackStack(RouteSavedStateConfiguration, LibraryRoute)
    val navigator = remember(backStack) { AppNavigator(backStack) }
    val twoPane = remember(layout) { TwoPaneSceneStrategy<NavKey>(layout) }
    val reducedMotion = SnippetsTheme.reducedMotion
    val slidePx = with(LocalDensity.current) { Dimens.sharedAxisOffset.roundToPx() }
    val back: () -> Unit = remember(navigator, layout.isTwoPane) { { navigator.back(layout.isTwoPane) } }
    NavDisplay(
        backStack = backStack,
        modifier = Modifier.fillMaxSize(),
        onBack = back,
        entryDecorators = listOf(
            rememberSaveableStateHolderNavEntryDecorator(),
            rememberViewModelStoreNavEntryDecorator(),
        ),
        sceneStrategies = listOf(twoPane, SinglePaneSceneStrategy()),
        transitionSpec = { sharedAxis(forward = true, slidePx, reducedMotion) },
        popTransitionSpec = { sharedAxis(forward = false, slidePx, reducedMotion) },
        entryProvider = entryProvider {
            entry<LibraryRoute>(metadata = Panes.list(width = { it.listPaneWidth }, placeholder = { EditorEmptyPane() })) {
                LibraryDestination(container, navigator, layout)
            }
            entry<EditorRoute>(metadata = Panes.detail()) { route ->
                EditorDestination(route, container, navigator, layout)
            }
            entry<SettingsRoute>(metadata = Panes.list(width = { it.settingsPaneWidth }, placeholder = { Box(Modifier.fillMaxSize()) })) {
                PlaceholderScreen(it, onBack = back)
            }
            settingsPane<SettingsSyncRoute>(back, layout)
            settingsPane<SettingsSecureRoute>(back, layout)
            settingsPane<SettingsBackupRoute>(back, layout)
            settingsPane<SettingsAppearanceRoute>(back, layout)
            settingsPane<SettingsDiagnosticsRoute>(back, layout)
            settingsPane<SettingsAboutRoute>(back, layout)
            // Pushed inside the detail pane, so they keep their Up arrow there.
            settingsPane<SettingsSyncGitRoute>(back, layout, nested = true)
            settingsPane<SettingsSyncCloudRoute>(back, layout, nested = true)
            settingsPane<SettingsNoticesRoute>(back, layout, nested = true)
            entry<SyncReviewRoute> { PlaceholderScreen(it, onBack = back) }
            entry<BackupNewPasswordRoute> { PlaceholderScreen(it, onBack = back) }
            entry<ImportRoute> { PlaceholderScreen(it, onBack = back) }
            entry<ExportRoute> { PlaceholderScreen(it, onBack = back) }
        },
    )
}

/** A Settings pane: the detail pane in two panes, where only a nested pane has an Up arrow. */
private inline fun <reified K : Route> EntryProviderScope<NavKey>.settingsPane(
    noinline back: () -> Unit,
    layout: WindowLayout,
    nested: Boolean = false,
) {
    entry<K>(metadata = Panes.detail()) { route ->
        PlaceholderScreen(route, onBack = back, showBack = nested || !layout.isTwoPane)
    }
}

/** Shared axis X (DESIGN.md §9): a 30 dp slide with a fade; a short fade under reduced motion. */
private fun <T : Any> AnimatedContentTransitionScope<Scene<T>>.sharedAxis(
    forward: Boolean,
    slidePx: Int,
    reducedMotion: Boolean,
): ContentTransform {
    if (reducedMotion) return fadeIn(tween(Motion.REDUCED_FADE)) togetherWith fadeOut(tween(Motion.REDUCED_FADE))
    val enter = slideInHorizontally(tween(Motion.DURATION_MEDIUM_2, easing = Motion.EasingEmphasizedDecelerate)) { if (forward) slidePx else -slidePx } +
        fadeIn(tween(Motion.DURATION_MEDIUM_2, easing = Motion.EasingEmphasizedDecelerate))
    val exit = slideOutHorizontally(tween(Motion.DURATION_MEDIUM_2, easing = Motion.EasingEmphasizedAccelerate)) { if (forward) -slidePx else slidePx } +
        fadeOut(tween(Motion.DURATION_SHORT_4, easing = Motion.EasingEmphasizedAccelerate))
    return enter togetherWith exit
}

