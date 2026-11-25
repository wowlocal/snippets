package com.khm.snippets.android.ui.model

import androidx.compose.runtime.Immutable

/** The sync states that have their own glyph and tint (components.md §7.1). */
enum class SyncGlyph {
    /** Sync is off. Settings shows `sync`; the library shows no row at all. */
    Off,

    /** Starting or preparing: `cloud`. */
    Preparing,

    /** A round is running: a 16 dp spinner in `primary`. */
    Syncing,

    /** Idle, waiting for the first fetch: `cloud_download`. */
    WaitingForFirstFetch,

    /** Idle and synced, or on and not synced yet: `cloud_done`. */
    Synced,

    /** Offline or host unreachable: `cloud_off`. */
    Offline,

    /** Needs authentication: `person_alert` in `warning`. */
    NeedsAuthentication,

    /** Needs attention: `warning` in `warning`. */
    NeedsAttention,

    /** Waiting for the vault: `lock_clock` in `secure`. */
    WaitingForVault,

    /** Halted by a newer schema: `system_update` in `warning`. */
    UpdateRequired,

    /** Halted, no data at risk: `sync_problem` in `warning`. */
    Halted,

    /** Halted by mass deletion, remote reset or integrity failure: `sync_problem` in `error`. */
    HaltedDataAtRisk,
}

/** The quiet library sync row: a glyph and its short text. */
@Immutable
data class SyncStatusUi(val glyph: SyncGlyph, val text: String)

/** Which container and title a Review card uses (components.md §7.3). */
enum class SyncReviewKind {
    /** `Sync Stopped` on `warningContainer`. */
    Halted,

    /** `Sync Stopped` on `errorContainer`: mass deletion, remote reset, integrity failure. */
    HaltedDataAtRisk,

    /** `Sync Needs Attention` on `warningContainer`. */
    NeedsAttention,

    /** `Sync Is Waiting` on `secureContainer`. */
    WaitingForVault,
}

/**
 * The Review card that replaces the quiet row while sync needs the user.
 *
 * @param text The status sentence (or the short form for a newer schema).
 * @param actionTitle The recovery action's title, `Open Sync Settings`, or null for no button.
 * @param isActionRunning The button shows a spinner and is disabled.
 */
@Immutable
data class SyncReviewUi(
    val kind: SyncReviewKind,
    val glyph: SyncGlyph,
    val text: String,
    val actionTitle: String? = null,
    val isActionRunning: Boolean = false,
)

/** Severity of a problem card: border, icon and title colour. */
enum class ProblemSeverity { Error, Warning }

/**
 * A persistent, typed failure (components.md §7.4).
 *
 * @param code The closed failure code, for example `git_http_401`. It is shown under Details and
 *   is part of the test tags. Never a host response, URL or token fragment.
 * @param message The complete sentence.
 * @param primaryAction Title of the first text button, or null.
 * @param secondaryAction Title of the second text button, or null.
 */
@Immutable
data class ProblemUi(
    val code: String,
    val title: String,
    val message: String,
    val severity: ProblemSeverity = ProblemSeverity.Error,
    val primaryAction: String? = null,
    val secondaryAction: String? = null,
)

/** State of one progress step; also its `stateDescription`. */
enum class StepState(val description: String) {
    Pending("pending"),
    Running("running"),
    Done("done"),
    Failed("failed"),
}

/** One real step of a running operation. A running label ends with `…`. */
@Immutable
data class StepUi(val label: String, val state: StepState)

/**
 * Content of the Review screen (components.md §15).
 *
 * @param title Top bar title, for example `Sync Stopped`.
 * @param heading The confirmation title, or the action title.
 * @param happened The complete status sentence.
 * @param explanation What the action does; null hides the section.
 * @param onDevice What is on this device and what has (not) changed.
 * @param code The halt code shown under Details.
 * @param confirmTitle Primary button; null for a halt without an action (the only button is
 *   then `Close`).
 * @param isDestructive The primary button uses the error colours.
 * @param isRunning The primary button shows a spinner; both buttons and close are disabled.
 * @param problem A failure of the action, shown above the buttons.
 */
@Immutable
data class ReviewUi(
    val title: String,
    val heading: String,
    val happened: String,
    val explanation: String?,
    val onDevice: String,
    val code: String,
    val confirmTitle: String?,
    val isDestructive: Boolean = false,
    val isRunning: Boolean = false,
    val problem: ProblemUi? = null,
)
