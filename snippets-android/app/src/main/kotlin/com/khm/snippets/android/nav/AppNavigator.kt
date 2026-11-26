package com.khm.snippets.android.nav

import androidx.compose.runtime.Stable
import androidx.navigation3.runtime.NavKey

/** The pane role of each route; the same table drives scenes and back. */
fun paneRoleOf(key: NavKey): PaneRole? = when (key) {
    LibraryRoute, SettingsRoute -> PaneRole.List
    is EditorRoute -> PaneRole.Detail
    is SettingsDestination -> PaneRole.Detail
    else -> null
}

/**
 * Changes the back stack. The back stack is the single source of truth for where the user is:
 * the selected snippet of a two-pane window is the [EditorRoute] on top, so rotating or resizing
 * between one and two panes needs no translation.
 */
@Stable
class AppNavigator(private val backStack: MutableList<NavKey>) {
    /** The snippet shown in the editor, which in two panes is the selected row. */
    val selectedSnippetId: String? get() = (backStack.lastOrNull() as? EditorRoute)?.id

    /** Opens [id] in the editor. An editor already on top is replaced, never stacked. */
    fun openEditor(id: String, focusBody: Boolean = false) {
        val route = EditorRoute(id, focusBody)
        val top = backStack.lastOrNull()
        when {
            top is EditorRoute && top.id == id -> Unit
            top is EditorRoute -> backStack[backStack.lastIndex] = route
            else -> backStack.add(route)
        }
    }

    /** Leaves the editor of [id], if it is on top. */
    fun closeEditor(id: String) {
        val top = backStack.lastOrNull()
        if (top is EditorRoute && top.id == id) backStack.removeAt(backStack.lastIndex)
    }

    fun navigate(route: Route) {
        if (backStack.lastOrNull() != route) backStack.add(route)
    }

    /** Opens Settings with a pane preselected when two panes show (DESIGN.md §3.2). */
    fun openSettings(pane: SettingsDestination?, isTwoPane: Boolean) {
        navigate(SettingsRoute)
        val detail = pane ?: if (isTwoPane) SettingsSyncRoute else null
        if (detail != null && detail != SettingsRoute) navigate(detail)
    }

    /** Back and Up: the same decision as the system back button. */
    fun back(isTwoPane: Boolean) {
        repeat(BackPolicy.popCount(backStack.map(::paneRoleOf), isTwoPane)) { pop() }
    }

    /** Removes the top entry; the start destination always stays. */
    fun pop() {
        if (backStack.size > 1) backStack.removeAt(backStack.lastIndex)
    }
}
