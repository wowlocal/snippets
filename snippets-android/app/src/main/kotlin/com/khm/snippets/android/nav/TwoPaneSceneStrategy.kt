package com.khm.snippets.android.nav

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.navigation3.runtime.NavEntry
import androidx.navigation3.scene.Scene
import androidx.navigation3.scene.SceneStrategy
import androidx.navigation3.scene.SceneStrategyScope
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import java.util.Objects

/**
 * Metadata of a list-pane entry.
 *
 * @param width Width of the pane for the current window.
 * @param placeholder What the detail pane shows while nothing is selected.
 */
class ListPaneSpec(val width: (WindowLayout) -> Dp, val placeholder: @Composable () -> Unit)

/** Entry metadata that gives a route its pane (DESIGN.md §3.2). */
object Panes {
    private const val ROLE = "snippets.pane.role"
    private const val LIST = "snippets.pane.list"

    fun list(width: (WindowLayout) -> Dp, placeholder: @Composable () -> Unit): Map<String, Any> =
        mapOf(ROLE to PaneRole.List, LIST to ListPaneSpec(width, placeholder))

    fun detail(): Map<String, Any> = mapOf(ROLE to PaneRole.Detail)

    internal fun role(entry: NavEntry<*>): PaneRole? = entry.metadata[ROLE] as? PaneRole
    internal fun listSpec(entry: NavEntry<*>): ListPaneSpec? = entry.metadata[LIST] as? ListPaneSpec
}

/**
 * The list-detail layout of DESIGN.md §4 as a Navigation 3 scene: a fixed-width list pane, a
 * 1 dp divider and the detail pane, both on `surface`. There is no drag handle and no rail.
 *
 * It applies only while [layout] is two-pane; otherwise it returns null and the default
 * single-pane scene shows the top entry. Which entries show and what back does is
 * [BackPolicy.twoPanePlan].
 */
class TwoPaneSceneStrategy<T : Any>(private val layout: WindowLayout) : SceneStrategy<T> {
    override fun SceneStrategyScope<T>.calculateScene(entries: List<NavEntry<T>>): Scene<T>? {
        if (!layout.isTwoPane) return null
        val plan = BackPolicy.twoPanePlan(entries.map(Panes::role)) ?: return null
        val list = entries[plan.listIndex]
        val spec = Panes.listSpec(list) ?: return null
        val detail = plan.detailIndex?.let(entries::get)
        return TwoPaneScene(
            list = list,
            detail = detail,
            previousEntries = entries.take(plan.remainingAfterBack).takeIf { it.size < entries.size }.orEmpty(),
            listWidth = spec.width(layout),
            placeholder = spec.placeholder,
        )
    }
}

private class TwoPaneScene<T : Any>(
    private val list: NavEntry<T>,
    private val detail: NavEntry<T>?,
    override val previousEntries: List<NavEntry<T>>,
    private val listWidth: Dp,
    private val placeholder: @Composable () -> Unit,
) : Scene<T> {
    // The detail is not part of the key: selecting another row changes a pane, not the scene.
    override val key: Any = "two-pane" to list.contentKey
    override val entries: List<NavEntry<T>> = listOfNotNull(list, detail)

    // The placeholder is the same for every scene of a strategy; equality is the panes'.
    override fun equals(other: Any?): Boolean =
        other is TwoPaneScene<*> && other.list == list && other.detail == detail &&
            other.previousEntries == previousEntries && other.listWidth == listWidth

    override fun hashCode(): Int = Objects.hash(list, detail, previousEntries, listWidth)

    override val content: @Composable () -> Unit = {
        val reducedMotion = SnippetsTheme.reducedMotion
        Row(modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) {
            Box(modifier = Modifier.width(listWidth).fillMaxHeight()) {
                CompositionLocalProvider(LocalPaneRole provides PaneRole.List) { list.Content() }
            }
            VerticalDivider(thickness = Dimens.borderThin, color = MaterialTheme.colorScheme.outlineVariant)
            AnimatedContent(
                targetState = detail,
                modifier = Modifier.weight(1f).fillMaxHeight(),
                transitionSpec = {
                    // Fade through; under reduced motion the same fade, shorter.
                    val duration = if (reducedMotion) Motion.REDUCED_FADE else Motion.DURATION_SHORT_4
                    fadeIn(tween(duration, easing = Motion.EasingStandard)) togetherWith
                        fadeOut(tween(duration, easing = Motion.EasingStandard))
                },
                contentKey = { it?.contentKey },
                label = "detailPane",
            ) { entry ->
                CompositionLocalProvider(LocalPaneRole provides PaneRole.Detail) {
                    if (entry == null) placeholder() else entry.Content()
                }
            }
        }
    }
}
