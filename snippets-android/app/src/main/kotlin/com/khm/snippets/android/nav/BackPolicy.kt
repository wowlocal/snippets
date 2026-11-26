package com.khm.snippets.android.nav

/** The pane a route takes in a two-pane scene. A route without a role always fills the window. */
enum class PaneRole { List, Detail }

/**
 * Which entries a two-pane scene shows and how far back goes from it.
 *
 * @param listIndex Index of the list pane's entry in the back stack.
 * @param detailIndex Index of the detail pane's entry, or null for the placeholder.
 * @param remainingAfterBack Size of the back stack after back; equal to the current size when
 *   back leaves the app.
 */
data class TwoPanePlan(val listIndex: Int, val detailIndex: Int?, val remainingAfterBack: Int)

/** What back does, first match wins (DESIGN.md §3.3). */
sealed interface BackDecision {
    /** An open menu, dialog or sheet is dismissed. */
    data object DismissOverlay : BackDecision

    /** A full-screen dialog is working: back does nothing. */
    data object Blocked : BackDecision

    /** The library's query is cleared. Tag filters are not touched. */
    data object ClearSearch : BackDecision

    /** [count] entries leave the back stack. */
    data class Pop(val count: Int) : BackDecision

    /** The app does not handle back: the system's predictive back leaves the app. */
    data object LeaveApp : BackDecision
}

/**
 * Everything back depends on.
 *
 * @param libraryHasQuery The library is on screen with a non-empty search query.
 */
data class BackInput(
    val roles: List<PaneRole?>,
    val isTwoPane: Boolean,
    val hasOverlay: Boolean = false,
    val overlayIsWorking: Boolean = false,
    val libraryHasQuery: Boolean = false,
)

/** Back and scene decisions as pure logic; the navigation host and the screens apply them. */
object BackPolicy {
    /**
     * The two-pane scene for a back stack with these pane roles, or null when the top entry
     * fills the window.
     *
     * A list entry shows with the newest detail entry above it. Back from a list with one
     * detail drops both, so a selection is never a back-stack step of its own: from the library
     * that leaves the app, from Settings it returns to the library. A detail pushed inside the
     * detail pane (`settings/sync/git`) pops alone.
     */
    fun twoPanePlan(roles: List<PaneRole?>): TwoPanePlan? {
        val top = roles.lastIndex
        if (top < 0) return null
        return when (roles[top]) {
            null -> null
            PaneRole.List -> TwoPanePlan(listIndex = top, detailIndex = null, remainingAfterBack = top)
            PaneRole.Detail -> {
                var listIndex = top
                while (listIndex >= 0 && roles[listIndex] == PaneRole.Detail) listIndex -= 1
                if (listIndex < 0 || roles[listIndex] != PaneRole.List) return null
                val details = top - listIndex
                TwoPanePlan(listIndex, detailIndex = top, remainingAfterBack = if (details > 1) top else listIndex)
            }
        }
    }

    /** How many entries back (and Up) removes; 0 means the app does not handle back. */
    fun popCount(roles: List<PaneRole?>, isTwoPane: Boolean): Int {
        if (roles.size <= 1) return 0
        val plan = if (isTwoPane) twoPanePlan(roles) else null
        return when {
            plan == null -> 1
            // Nothing would remain: the selection is not a step of its own, back leaves the app.
            plan.remainingAfterBack == 0 -> 0
            else -> roles.size - plan.remainingAfterBack
        }
    }

    fun decide(input: BackInput): BackDecision {
        if (input.hasOverlay) return if (input.overlayIsWorking) BackDecision.Blocked else BackDecision.DismissOverlay
        if (input.libraryHasQuery) return BackDecision.ClearSearch
        val count = popCount(input.roles, input.isTwoPane)
        return if (count == 0) BackDecision.LeaveApp else BackDecision.Pop(count)
    }
}
