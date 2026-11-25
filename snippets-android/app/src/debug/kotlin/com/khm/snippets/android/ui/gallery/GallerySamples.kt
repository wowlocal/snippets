package com.khm.snippets.android.ui.gallery

import com.khm.snippets.android.ui.model.ProblemSeverity
import com.khm.snippets.android.ui.model.ProblemUi
import com.khm.snippets.android.ui.model.ReviewUi
import com.khm.snippets.android.ui.model.RowPreviewUi
import com.khm.snippets.android.ui.model.SecretScreenUi
import com.khm.snippets.android.ui.model.SnippetRowUi
import com.khm.snippets.android.ui.model.StepState
import com.khm.snippets.android.ui.model.StepUi
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.SyncReviewKind
import com.khm.snippets.android.ui.model.SyncReviewUi
import com.khm.snippets.android.ui.model.SyncStatusUi
import com.khm.snippets.android.ui.model.TagFilterUi
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.model.TextHighlight

/** Sample data for the gallery. Nothing here is real. */
internal object GallerySamples {
    fun tag(name: String) = TagUi(name = name, folded = name.lowercase())

    val paletteTags = listOf(
        "red", "amber", "sun", "leaf", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown",
        "work", "links", "tokens", "notes", "personal", "travel", "email", "support",
    ).map(::tag)

    val rows: List<Pair<String, SnippetRowUi>> = listOf(
        "Default: keyword, content, tags" to SnippetRowUi(
            id = "meeting-notes",
            name = "Meeting notes",
            time = "9:04 PM",
            preview = RowPreviewUi.Text("Meeting notes — {date:yyyy-MM-dd}"),
            keyword = "notes",
            tags = listOf(tag("work"), tag("notes"), tag("links")),
        ),
        "Pinned" to SnippetRowUi(
            id = "meeting-room",
            name = "Meeting room",
            time = "9:02 PM",
            preview = RowPreviewUi.Text("https://meet.example.com/design-review-weekly"),
            keyword = "meet",
            tags = listOf(tag("work"), tag("links")),
            isPinned = true,
        ),
        "Secure, with keyword" to SnippetRowUi(
            id = "atlas-token",
            name = "Atlas API token",
            time = "Yesterday",
            preview = RowPreviewUi.Secure,
            keyword = "atlas-token",
            tags = listOf(tag("work"), tag("tokens")),
            isSecure = true,
        ),
        "Secure, no keyword, no name" to SnippetRowUi(
            id = "secure-untitled",
            name = "",
            time = "Mon",
            preview = RowPreviewUi.Secure,
            isSecure = true,
            isPinned = true,
        ),
        "Disabled keyword" to SnippetRowUi(
            id = "quick-reply",
            name = "Quick reply",
            time = "Mon",
            preview = RowPreviewUi.Text("Thanks for reaching out. I will take a look and reply shortly."),
            keyword = "reply",
            isEnabled = false,
        ),
        "Disabled, keyword only" to SnippetRowUi(
            id = "disabled-keyword-only",
            name = "Signature",
            time = "Nov 12",
            preview = RowPreviewUi.None,
            keyword = "sig",
            isEnabled = false,
        ),
        "Conflict copy (disabled, conflict tag)" to SnippetRowUi(
            id = "conflict-copy",
            name = "Meeting notes (conflict)",
            time = "Nov 9",
            preview = RowPreviewUi.Text("Meeting notes — {date}"),
            keyword = "notes-2",
            tags = listOf(tag("conflict"), tag("work")),
            isEnabled = false,
        ),
        "Keyword only" to SnippetRowUi(
            id = "keyword-only",
            name = "Shrug",
            time = "Nov 3",
            preview = RowPreviewUi.None,
            keyword = "shrug",
        ),
        "Content only" to SnippetRowUi(
            id = "content-only",
            name = "Office address",
            time = "Oct 28",
            preview = RowPreviewUi.Text("221B Baker Street, London NW1 6XE, United Kingdom"),
        ),
        "Neither keyword nor content" to SnippetRowUi(
            id = "empty",
            name = "Untitled draft",
            time = "Oct 2",
            preview = RowPreviewUi.NoContent,
        ),
        "Search highlights: name, keyword, tag, content" to SnippetRowUi(
            id = "highlight",
            name = "Atlas staging URL",
            time = "8:15 AM",
            preview = RowPreviewUi.Text("https://atlas.example.com/staging", highlights = listOf(TextHighlight(8, 13))),
            keyword = "atlas-url",
            tags = listOf(TagUi("atlas", "atlas", highlights = listOf(TextHighlight(0, 5))), tag("links")),
            nameHighlights = listOf(TextHighlight(0, 5)),
            keywordHighlights = listOf(TextHighlight(0, 5)),
        ),
        "Search excerpt (hit below the first line)" to SnippetRowUi(
            id = "excerpt",
            name = "Release checklist",
            time = "Sun",
            preview = RowPreviewUi.Text("notarize with the atlas profile, then staple", highlights = listOf(TextHighlight(18, 23)), isExcerpt = true),
            keyword = "release",
            tags = listOf(tag("work")),
        ),
        "Many tags (+N), long name and keyword" to SnippetRowUi(
            id = "overflow",
            name = "A very long snippet name that cannot fit on a single line of the row",
            time = "Sat",
            preview = RowPreviewUi.Text("The preview follows the token and is cut with an ellipsis"),
            keyword = "a-very-long-keyword-that-is-cut",
            tags = listOf(tag("personal"), tag("travel"), tag("email"), tag("support"), tag("notes"), tag("links")),
            isSecure = false,
            isPinned = true,
            isEnabled = false,
        ),
    )

    val tagFilters = listOf(
        TagFilterUi(tag("work"), count = 12, selected = false),
        TagFilterUi(tag("links"), count = 7, selected = false),
        TagFilterUi(tag("personal"), count = 5, selected = false),
        TagFilterUi(tag("travel"), count = 3, selected = false),
        TagFilterUi(tag("notes"), count = 2, selected = false),
        TagFilterUi(tag("conflict"), count = 1, selected = false),
    )

    val manyTagFilters = paletteTags.mapIndexed { index, tag -> TagFilterUi(tag, count = 20 - index, selected = false) }

    val syncRows = listOf(
        SyncStatusUi(SyncGlyph.Preparing, "Preparing the first fetch…"),
        SyncStatusUi(SyncGlyph.Syncing, "Syncing changes…"),
        SyncStatusUi(SyncGlyph.WaitingForFirstFetch, "Waiting to fetch your library…"),
        SyncStatusUi(SyncGlyph.Synced, "Synced at 9:04 PM"),
        SyncStatusUi(SyncGlyph.Offline, "Git unavailable"),
    )

    val reviewCards = listOf(
        SyncReviewUi(
            kind = SyncReviewKind.HaltedDataAtRisk,
            glyph = SyncGlyph.HaltedDataAtRisk,
            text = "Stopped because an unusually large deletion arrived: sync reported a batch that would remove 96 of 128 snippets. Nothing has been deleted on this device.",
            actionTitle = "Confirm Deletions",
        ),
        SyncReviewUi(
            kind = SyncReviewKind.Halted,
            glyph = SyncGlyph.UpdateRequired,
            text = "Update Snippets to resume sync",
        ),
        SyncReviewUi(
            kind = SyncReviewKind.NeedsAttention,
            glyph = SyncGlyph.NeedsAuthentication,
            text = "The Git host didn’t accept the access token.",
            actionTitle = "Open Sync Settings",
        ),
        SyncReviewUi(
            kind = SyncReviewKind.WaitingForVault,
            glyph = SyncGlyph.WaitingForVault,
            text = "Sync is waiting for the vault key on this device.",
            actionTitle = "Check Again",
            isActionRunning = true,
        ),
    )

    val problemError = ProblemUi(
        code = "git_http_401",
        title = "Access Token Refused",
        message = "The Git host didn’t accept the access token. It may have expired or lack access to this repository. Nothing was changed.",
        primaryAction = "Enter a New Token",
        secondaryAction = "Open Token Page",
    )

    val problemWarning = ProblemUi(
        code = "git_host_unreachable",
        title = "Host Unreachable",
        message = "Snippets couldn’t reach the Git host. Your library on this device is unchanged.",
        severity = ProblemSeverity.Warning,
        primaryAction = "Try Again",
    )

    val steps = listOf(
        StepUi("Checking the repository", StepState.Done),
        StepUi("Creating the library…", StepState.Running),
        StepUi("Opening the library", StepState.Pending),
        StepUi("Connecting", StepState.Failed),
    )

    const val RECOVERY_KEY = "7K2M9QXD4FTRHV3NP8WC6YJAB5G"
    const val FINGERPRINT = "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"
    const val PUBLIC_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl snippets-device"

    fun secretScreen(copied: Boolean, hidden: Boolean) = SecretScreenUi(
        routeTag = "secure.recovery-key",
        title = "Recovery Key",
        heading = "Save Your Recovery Key",
        body = "Store this somewhere safe. It is the only way to recover secure snippets if the vault key on this device is lost. Snippets can’t show it again.",
        code = RECOVERY_KEY,
        doneTitle = "I’ve Saved It",
        copiedMessage = if (copied) "Copied. It clears from the clipboard in 5 minutes." else null,
        canClose = true,
        isHidden = hidden,
    )

    fun review(running: Boolean, failed: Boolean) = ReviewUi(
        title = "Sync Stopped",
        heading = "Apply These Deletions?",
        happened = "Stopped because an unusually large deletion arrived: sync reported a batch that would remove 96 of 128 snippets.",
        explanation = "These deletions did not include proof of intent. Applying them removes the snippets from this device and keeps sync running.",
        onDevice = "128 snippets. Nothing has been changed on this device yet.",
        code = "mass_deletion",
        confirmTitle = "Apply Deletions",
        isDestructive = true,
        isRunning = running,
        problem = if (failed) problemWarning else null,
    )
}
