package com.khm.snippets.android.ui.gallery

import android.os.SystemClock
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import com.khm.snippets.android.ui.components.ButtonLevel
import com.khm.snippets.android.ui.components.CodeField
import com.khm.snippets.android.ui.components.ConfirmDialog
import com.khm.snippets.android.ui.components.EmptyState
import com.khm.snippets.android.ui.components.ErrorDialog
import com.khm.snippets.android.ui.components.FullScreenDialogHost
import com.khm.snippets.android.ui.components.GroupDivider
import com.khm.snippets.android.ui.components.KeywordField
import com.khm.snippets.android.ui.components.KeywordToken
import com.khm.snippets.android.ui.components.LabeledField
import com.khm.snippets.android.ui.components.LibraryCountFooter
import com.khm.snippets.android.ui.components.LibrarySearchBar
import com.khm.snippets.android.ui.components.NewSnippetFab
import com.khm.snippets.android.ui.components.PasswordField
import com.khm.snippets.android.ui.components.PinnedHeader
import com.khm.snippets.android.ui.components.ProblemCard
import com.khm.snippets.android.ui.components.ProgressDialog
import com.khm.snippets.android.ui.components.ProgressSteps
import com.khm.snippets.android.ui.components.ReviewScreen
import com.khm.snippets.android.ui.components.SecretBlock
import com.khm.snippets.android.ui.components.SecretCopyAction
import com.khm.snippets.android.ui.components.SecretLeaveDialog
import com.khm.snippets.android.ui.components.SecretScreen
import com.khm.snippets.android.ui.components.SectionHeader
import com.khm.snippets.android.ui.components.SecureBodyPanel
import com.khm.snippets.android.ui.components.SecureCopyCountdown
import com.khm.snippets.android.ui.components.SettingsRow
import com.khm.snippets.android.ui.components.SettingsRowKind
import com.khm.snippets.android.ui.components.SettingsSwitchRow
import com.khm.snippets.android.ui.components.SnackbarKind
import com.khm.snippets.android.ui.components.SnippetListItem
import com.khm.snippets.android.ui.components.SnippetRow
import com.khm.snippets.android.ui.components.SnippetsButton
import com.khm.snippets.android.ui.components.SnippetsHaptic
import com.khm.snippets.android.ui.components.SnippetsIconButton
import com.khm.snippets.android.ui.components.SnippetsMenuDivider
import com.khm.snippets.android.ui.components.SnippetsMenuItem
import com.khm.snippets.android.ui.components.SwitchRow
import com.khm.snippets.android.ui.components.SyncReviewCard
import com.khm.snippets.android.ui.components.SyncStatusGlyph
import com.khm.snippets.android.ui.components.SyncStatusRow
import com.khm.snippets.android.ui.components.TagField
import com.khm.snippets.android.ui.components.TagFilterRow
import com.khm.snippets.android.ui.components.TagFilterSheetContent
import com.khm.snippets.android.ui.components.TagPill
import com.khm.snippets.android.ui.components.rememberClipboardPaste
import com.khm.snippets.android.ui.components.rememberCopiedRowState
import com.khm.snippets.android.ui.components.rememberSnippetsHaptics
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.CodeFormat
import com.khm.snippets.android.ui.model.CountdownUi
import com.khm.snippets.android.ui.model.LockReason
import com.khm.snippets.android.ui.model.ProtectedCause
import com.khm.snippets.android.ui.model.SecretVariant
import com.khm.snippets.android.ui.model.SecurePanelState
import com.khm.snippets.android.ui.model.SnippetRowAction
import com.khm.snippets.android.ui.model.SnippetRowLayout
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.model.TextHighlight
import com.khm.snippets.android.ui.model.UnavailableCause
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

@Composable
internal fun ColumnScope.GallerySectionContent(
    section: GallerySection,
    events: GalleryEvents,
    initiallyOpen: String?,
) {
    when (section) {
        GallerySection.Theme -> ThemeSection()
        GallerySection.Rows -> RowsSection(events, SnippetRowLayout.SinglePane)
        GallerySection.RowsTwoPane -> RowsSection(events, SnippetRowLayout.TwoPane)
        GallerySection.Library -> LibrarySection(events)
        GallerySection.Tags -> TagsSection(events)
        GallerySection.Empty -> EmptySection(events)
        GallerySection.Sync -> SyncSection(events)
        GallerySection.Secure -> SecureSection(events)
        GallerySection.Secrets -> SecretsSection(events)
        GallerySection.Fields -> FieldsSection(events)
        GallerySection.Settings -> SettingsSection(events)
        GallerySection.Progress -> ProgressSection(events)
        GallerySection.Dialogs -> DialogsSection(events, initiallyOpen)
        GallerySection.Buttons -> ButtonsSection(events)
    }
}

/** A captioned sample. [padded] adds the compact screen margin around the content. */
@Composable
private fun Sample(
    label: String,
    padded: Boolean = false,
    content: @Composable () -> Unit,
) {
    Text(
        text = label,
        modifier = Modifier.padding(start = Spacing.l, end = Spacing.l, top = Spacing.l, bottom = Spacing.xs),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.outline,
    )
    Box(modifier = if (padded) Modifier.padding(horizontal = Dimens.marginCompact) else Modifier) {
        content()
    }
}

// Theme ------------------------------------------------------------------------------------

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ThemeSection() {
    val scheme = MaterialTheme.colorScheme
    val extended = SnippetsTheme.colors
    Sample("Material roles: container / content", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Swatch("primary", scheme.primary, scheme.onPrimary)
            Swatch("primaryContainer", scheme.primaryContainer, scheme.onPrimaryContainer)
            Swatch("secondary", scheme.secondary, scheme.onSecondary)
            Swatch("secondaryContainer", scheme.secondaryContainer, scheme.onSecondaryContainer)
            Swatch("tertiary", scheme.tertiary, scheme.onTertiary)
            Swatch("tertiaryContainer", scheme.tertiaryContainer, scheme.onTertiaryContainer)
            Swatch("error", scheme.error, scheme.onError)
            Swatch("errorContainer", scheme.errorContainer, scheme.onErrorContainer)
            Swatch("surface", scheme.surface, scheme.onSurface)
            Swatch("surfaceContainerLow", scheme.surfaceContainerLow, scheme.onSurface)
            Swatch("surfaceContainer", scheme.surfaceContainer, scheme.onSurfaceVariant)
            Swatch("surfaceContainerHigh", scheme.surfaceContainerHigh, scheme.onSurface)
            Swatch("surfaceContainerHighest", scheme.surfaceContainerHighest, scheme.onSurfaceVariant)
            Swatch("inverseSurface", scheme.inverseSurface, scheme.inverseOnSurface)
            Swatch("outline", scheme.outline, scheme.surface)
            Swatch("outlineVariant", scheme.outlineVariant, scheme.onSurface)
        }
    }
    Sample("Extended roles", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            Swatch("secure", extended.secure, extended.onSecure)
            Swatch("secureContainer", extended.secureContainer, extended.onSecureContainer)
            Swatch("warning", extended.warning, extended.onWarning)
            Swatch("warningContainer", extended.warningContainer, extended.onWarningContainer)
            Swatch("success", extended.success, extended.onSuccess)
            Swatch("successContainer", extended.successContainer, extended.onSuccessContainer)
        }
    }
    Sample("Tag palette: 12 slots", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            val names = listOf("red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown")
            SnippetsTheme.tagPalette.slots.forEachIndexed { index, slot -> Swatch("$index ${names[index]}", slot.fill, slot.text) }
        }
    }
    val type = MaterialTheme.typography
    val mono = SnippetsTheme.typography
    Sample("Typography: Material roles", padded = true) {
        Column {
            TypeLine("headlineSmall 24/32", type.headlineSmall)
            TypeLine("titleLarge 22/28", type.titleLarge)
            TypeLine("titleMedium 16/24 · 500", type.titleMedium)
            TypeLine("titleSmall 14/20 · 500", type.titleSmall)
            TypeLine("bodyLarge 16/24", type.bodyLarge)
            TypeLine("bodyMedium 14/20", type.bodyMedium)
            TypeLine("bodySmall 12/16", type.bodySmall)
            TypeLine("labelLarge 14/20 · 500", type.labelLarge)
            TypeLine("labelMedium 12/16 · 500", type.labelMedium)
            TypeLine("labelSmall 11/16 · 500", type.labelSmall)
        }
    }
    Sample("Typography: JetBrains Mono (ligatures off)", padded = true) {
        Column {
            TypeLine("monoBody 14/20  0O 1lI != -> ==", mono.monoBody)
            TypeLine("monoToken 13/20 · 500  \\notes", mono.monoToken)
            TypeLine("monoKey 13/20  SHA256:nThbg6kX", mono.monoKey)
            TypeLine("7K2M-9QXD", mono.monoCode)
            TypeLine("482 913", mono.monoCodeLarge)
        }
    }
    Sample("Icons", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
            SnippetsIcon.entries.forEach { Glyph(it, contentDescription = null, tint = scheme.onSurfaceVariant) }
        }
    }
}

@Composable
private fun Swatch(name: String, container: Color, content: Color) {
    Box(
        modifier = Modifier
            .width(SwatchWidth)
            .heightIn(min = Dimens.touchTarget)
            .background(container, MaterialTheme.shapes.small)
            .border(Dimens.borderThin, MaterialTheme.colorScheme.outlineVariant, MaterialTheme.shapes.small)
            .padding(Spacing.s),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text = name, color = content, style = MaterialTheme.typography.labelSmall)
    }
}

private val SwatchWidth = 108.dp

@Composable
private fun TypeLine(text: String, style: TextStyle) {
    Text(text = text, style = style, color = MaterialTheme.colorScheme.onSurface)
}

// Rows -------------------------------------------------------------------------------------

@Composable
private fun RowsSection(events: GalleryEvents, layout: SnippetRowLayout) {
    val copied = rememberCopiedRowState()
    val haptics = rememberSnippetsHaptics()
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    GallerySamples.rows.forEach { (label, row) ->
        Sample(label) {
            SnippetListItem(
                row = row,
                onClick = {
                    if (layout == SnippetRowLayout.TwoPane) {
                        selectedId = row.id
                        events.log("${row.id}: select")
                    } else {
                        copied.show(row.id)
                        haptics.perform(SnippetsHaptic.CopySucceeded)
                        events.log("${row.id}: copy")
                    }
                },
                onAction = { action ->
                    if (action == SnippetRowAction.Copy) copied.show(row.id)
                    events.log("${row.id}: $action")
                },
                layout = layout,
                selected = selectedId == row.id,
                copied = copied.isCopied(row.id),
            )
        }
    }
    val first = GallerySamples.rows.first().second
    Sample("Copied state (held)") {
        SnippetRow(row = first.copy(id = "copied-held"), onClick = {}, onAction = {}, layout = layout, copied = true, announceCopied = false)
    }
    if (layout == SnippetRowLayout.TwoPane) {
        Sample("Selected") {
            SnippetRow(row = first.copy(id = "selected-held"), onClick = {}, onAction = {}, layout = layout, selected = true)
        }
        Sample("Selected, secure and disabled") {
            SnippetRow(
                row = GallerySamples.rows[2].second.copy(id = "selected-secure", isEnabled = false),
                onClick = {},
                onAction = {},
                layout = layout,
                selected = true,
            )
        }
    } else {
        Sample("Insert Snippet picker: no trailing button") {
            SnippetRow(row = first.copy(id = "picker"), onClick = { events.log("picker: pick") }, onAction = {}, layout = SnippetRowLayout.Picker)
        }
        Sample("Menu held open: pressed state") {
            SnippetRow(row = first.copy(id = "menu-open"), onClick = {}, onAction = {}, menuOpen = true)
        }
    }
    Sample("Keyword tokens", padded = true) {
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
            KeywordToken("notes")
            KeywordToken("notes", enabled = false)
            KeywordToken("atlas-url", highlights = listOf(TextHighlight(0, 5)))
            Box(Modifier.background(MaterialTheme.colorScheme.secondaryContainer).padding(Spacing.xs)) {
                KeywordToken("notes", onSelectedRow = true)
            }
        }
    }
}

// Library chrome ----------------------------------------------------------------------------

@Composable
private fun LibrarySection(events: GalleryEvents) {
    var query by rememberSaveable { mutableStateOf("") }
    var menuOpen by remember { mutableStateOf(false) }
    Sample("Search bar (interactive; More opens the menu)", padded = true) {
        LibrarySearchBar(
            query = query,
            onQueryChange = { query = it },
            onMoreClick = { menuOpen = true },
            modifier = Modifier.fillMaxWidth(),
            onSearch = { events.log("search: $query") },
            moreMenu = {
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    SnippetsMenuItem("New from Clipboard", SnippetsIcon.ContentPaste, "new-from-clipboard", onClick = { menuOpen = false })
                    SnippetsMenuDivider()
                    SnippetsMenuItem("Import", SnippetsIcon.FileOpen, "import", onClick = { menuOpen = false })
                    SnippetsMenuItem("Export for Sharing", SnippetsIcon.FileSave, "export", onClick = { menuOpen = false })
                    SnippetsMenuItem("Encrypted Backup", SnippetsIcon.EnhancedEncryption, "backup", onClick = { menuOpen = false })
                    SnippetsMenuDivider()
                    SnippetsMenuItem("Sync Now", SnippetsIcon.Sync, "sync", onClick = { menuOpen = false })
                    SnippetsMenuItem("Settings", SnippetsIcon.Settings, "settings", onClick = { menuOpen = false })
                }
            },
        )
    }
    Sample("Search bar with a query", padded = true) {
        LibrarySearchBar(query = "atlas", onQueryChange = {}, onMoreClick = {}, modifier = Modifier.fillMaxWidth())
    }
    var filters by remember { mutableStateOf(GallerySamples.tagFilters) }
    val haptics = rememberSnippetsHaptics()
    Sample("Tag filter row (interactive)") {
        TagFilterRow(
            tags = filters.sortedByDescending { it.selected },
            onToggleTag = { tag ->
                filters = filters.map { if (it.tag == tag) it.copy(selected = !it.selected) else it }
                haptics.perform(SnippetsHaptic.TagFilterToggled)
            },
            onOpenFilters = { events.log("open tag filters") },
        )
    }
    Sample("Tag filter row, two active filters") {
        TagFilterRow(
            tags = GallerySamples.tagFilters.mapIndexed { index, filter -> filter.copy(selected = index < 2) },
            onToggleTag = {},
            onOpenFilters = {},
        )
    }
    var countdown by remember { mutableStateOf<CountdownUi>(CountdownUi.Running("Atlas API token", SystemClock.elapsedRealtime() + 42_000)) }
    Sample("Secure-copy countdown (live; Clear Now switches to cleared)") {
        SecureCopyCountdown(state = countdown, onClearNow = { countdown = CountdownUi.Cleared }, announce = false)
    }
    Sample("Countdown, long name") {
        SecureCopyCountdown(
            state = CountdownUi.Running("Production database administrator password", deadlineMillis = 58_000),
            onClearNow = {},
            nowMillis = { 0 },
            announce = false,
        )
    }
    Sample("Countdown, cleared") {
        SecureCopyCountdown(state = CountdownUi.Cleared, onClearNow = {}, announce = false)
    }
    Sample("Pinned header, group divider, count footers") {
        Column {
            PinnedHeader()
            GroupDivider()
            SectionHeader("Library")
            LibraryCountFooter(visibleCount = 42, totalCount = 42, filtered = false)
            LibraryCountFooter(visibleCount = 1, totalCount = 1, filtered = false)
            LibraryCountFooter(visibleCount = 3, totalCount = 42, filtered = true)
        }
    }
    Sample("FAB: extended, collapsed, small", padded = true) {
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.l), verticalAlignment = Alignment.CenterVertically) {
            NewSnippetFab(onClick = { events.log("fab") })
            NewSnippetFab(onClick = {}, expanded = false)
            NewSnippetFab(onClick = {}, small = true)
        }
    }
}

// Tags -------------------------------------------------------------------------------------

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TagsSection(events: GalleryEvents) {
    Sample("Tag pills: every palette slot, and the conflict tag", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Dimens.rowPillGap), verticalArrangement = Arrangement.spacedBy(Dimens.rowPillGap)) {
            GallerySamples.paletteTags.forEach { TagPill(it) }
            TagPill(GallerySamples.tag("conflict"))
            TagPill(TagUi("atlas", "atlas", highlights = listOf(TextHighlight(0, 3))))
        }
    }
    var filters by remember { mutableStateOf(GallerySamples.manyTagFilters) }
    var query by rememberSaveable { mutableStateOf("") }
    Sample("Tag filter sheet content (more than 12 tags: search shown)") {
        Box(Modifier.background(MaterialTheme.colorScheme.surfaceContainerLow).height(TagSheetSampleHeight)) {
            TagFilterSheetContent(
                tags = filters.filter { it.tag.folded.contains(query.lowercase()) },
                libraryTagCount = filters.size,
                activeFilterCount = filters.count { it.selected },
                query = query,
                onQueryChange = { query = it },
                onToggleTag = { tag -> filters = filters.map { if (it.tag == tag) it.copy(selected = !it.selected) else it } },
                onClear = {
                    filters = filters.map { it.copy(selected = false) }
                    events.log("filters cleared")
                },
            )
        }
    }
    Sample("Tag filter sheet, no match") {
        Box(Modifier.background(MaterialTheme.colorScheme.surfaceContainerLow)) {
            TagFilterSheetContent(
                tags = emptyList(),
                libraryTagCount = 20,
                activeFilterCount = 2,
                query = "zz",
                onQueryChange = {},
                onToggleTag = {},
                onClear = {},
            )
        }
    }
    Sample("Tag filter sheet, no tags yet") {
        Box(Modifier.background(MaterialTheme.colorScheme.surfaceContainerLow)) {
            TagFilterSheetContent(
                tags = emptyList(),
                libraryTagCount = 0,
                activeFilterCount = 0,
                query = "",
                onQueryChange = {},
                onToggleTag = {},
                onClear = {},
            )
        }
    }
}

private val TagSheetSampleHeight = 420.dp

// Empty states ------------------------------------------------------------------------------

@Composable
private fun EmptySection(events: GalleryEvents) {
    Sample("First run, sync off") {
        EmptyState(
            tagArea = "library",
            title = "Your Library Is Empty",
            message = "Create a snippet, import a library, or set up sync to fetch the library from your other devices.",
            icon = SnippetsIcon.Description,
            primaryAction = "New Snippet",
            onPrimaryAction = { events.log("empty: New Snippet") },
            textActions = listOf("Import…", "Set Up Sync"),
            onTextAction = { events.log("empty: text action $it") },
            note = "Sync is optional. Everything works on this device without an account.",
        )
    }
    Sample("First fetch running") {
        EmptyState(
            tagArea = "fetching",
            title = "Fetching Your Library",
            message = "Checking Git for the library from your other devices.",
            loading = true,
        )
    }
    Sample("Search, no match, with filters") {
        EmptyState(
            tagArea = "search",
            title = "No Results",
            message = "Try changing the search or clearing a tag filter.",
            icon = SnippetsIcon.SearchOff,
            textActions = listOf("Clear Filters"),
            note = "Secure snippet bodies are not searched.",
        )
    }
    Sample("Library quarantined") {
        EmptyState(
            tagArea = "quarantine",
            title = "Library Recovery Required",
            message = "The ordinary snippet library could not be read and remains preserved. Import a complete Snippets JSON export, then review Sync and choose Check Again.",
            icon = SnippetsIcon.Error,
            iconTint = MaterialTheme.colorScheme.error,
            primaryAction = "Import…",
        )
    }
    Sample("Two-pane placeholder") {
        EmptyState(
            tagArea = "editor",
            title = "Select a snippet",
            message = "Choose a snippet from the list or create a new one.",
            icon = SnippetsIcon.Description,
        )
    }
}

// Sync --------------------------------------------------------------------------------------

@Composable
private fun SyncSection(events: GalleryEvents) {
    Sample("Status glyphs", padded = true) {
        Row(horizontalArrangement = Arrangement.spacedBy(Spacing.m), verticalAlignment = Alignment.CenterVertically) {
            SyncGlyph.entries.forEach { SyncStatusGlyph(it) }
        }
    }
    GallerySamples.syncRows.forEach { status ->
        Sample("Quiet row: ${status.glyph}") {
            SyncStatusRow(status = status, onClick = { events.log("sync row") })
        }
    }
    GallerySamples.reviewCards.forEach { review ->
        Sample("Review card: ${review.kind}${if (review.isActionRunning) ", running" else ""}") {
            SyncReviewCard(review = review, onClick = { events.log("card body") }, onAction = { events.log("card action") })
        }
    }
    Sample("Problem card: error (Details expands)", padded = true) {
        ProblemCard(
            problem = GallerySamples.problemError,
            tagArea = "git",
            onCopyCode = { events.log("copy code") },
            onPrimaryAction = { events.log("problem action") },
            onSecondaryAction = { events.log("problem action 2") },
        )
    }
    Sample("Problem card: warning", padded = true) {
        ProblemCard(problem = GallerySamples.problemWarning, tagArea = "git", onCopyCode = {})
    }
}

// Secure body panel --------------------------------------------------------------------------

@Composable
private fun SecureSection(events: GalleryEvents) {
    var live by remember { mutableStateOf<SecurePanelState>(SecurePanelState.Locked()) }
    Sample("Interactive: Reveal, edit, Lock", padded = true) {
        SecureBodyPanel(
            state = live,
            onReveal = { live = SecurePanelState.Revealed("sk-live-9f3c2a7b41d8\nregion=eu-west-1") },
            onLock = { live = SecurePanelState.Locked() },
            onBodyChange = { live = SecurePanelState.Revealed(it) },
        )
    }
    val states = listOf(
        "Locked, with reason" to SecurePanelState.Locked(LockReason.IdleTimeout),
        "Unlocking" to SecurePanelState.Unlocking,
        "Revealed" to SecurePanelState.Revealed("sk-live-9f3c2a7b41d8"),
        "Revealed, empty" to SecurePanelState.Revealed(""),
        "Protected: screen recording" to SecurePanelState.Protected(ProtectedCause.ScreenRecording),
        "Protected: display" to SecurePanelState.Protected(ProtectedCause.UnprotectedDisplay),
        "Unavailable: no screen lock" to SecurePanelState.Unavailable(UnavailableCause.NoScreenLock),
        "Unavailable: Git vault not set up" to SecurePanelState.Unavailable(UnavailableCause.GitVaultNotSetUp),
        "Unavailable: vault key missing" to SecurePanelState.Unavailable(UnavailableCause.VaultKeyMissing),
    )
    states.forEach { (label, state) ->
        Sample(label, padded = true) {
            SecureBodyPanel(
                state = state,
                onReveal = {},
                onLock = {},
                onBodyChange = {},
                onUnavailableAction = { events.log("unavailable action") },
            )
        }
    }
}

// Secret blocks ------------------------------------------------------------------------------

@Composable
private fun SecretsSection(events: GalleryEvents) {
    var copied by rememberSaveable { mutableStateOf(false) }
    Sample("Code: 27 symbols in groups of 4", padded = true) {
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            SecretBlock(GallerySamples.RECOVERY_KEY)
            SecretCopyAction(
                label = "Copy",
                onCopy = {
                    copied = true
                    events.log("secret copied")
                },
                copiedMessage = if (copied) "Copied. It clears from the clipboard in 5 minutes." else null,
            )
        }
    }
    Sample("Comparison code", padded = true) {
        SecretBlock("482 913", variant = SecretVariant.Comparison)
    }
    Sample("Fingerprint (selectable)", padded = true) {
        SecretBlock(GallerySamples.FINGERPRINT, variant = SecretVariant.Fingerprint)
    }
    Sample("Public key (selectable)", padded = true) {
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            SecretBlock(GallerySamples.PUBLIC_KEY, variant = SecretVariant.PublicKey)
            SecretCopyAction(label = "Copy Public Key", onCopy = { events.log("public key copied") })
        }
    }
}

// Fields -------------------------------------------------------------------------------------

@Composable
private fun FieldsSection(events: GalleryEvents) {
    var name by rememberSaveable { mutableStateOf("Meeting notes") }
    Sample("Labeled field (interactive)", padded = true) {
        LabeledField(value = name, onValueChange = { name = it }, caption = "Name", tag = "editor.name", placeholder = "First line is used when blank")
    }
    Sample("Placeholder and supporting text", padded = true) {
        LabeledField(value = "", onValueChange = {}, caption = "Branch", placeholder = "main", supportingText = "The branch that holds the library.")
    }
    Sample("Error", padded = true) {
        LabeledField(value = "ftp://example", onValueChange = {}, caption = "Repository", errorText = "Enter an https:// or ssh address.")
    }
    Sample("Read-only value", padded = true) {
        LabeledField(value = "github.com/me/library", onValueChange = {}, caption = "Repository", readOnly = true)
    }
    var body by rememberSaveable { mutableStateOf("Meeting notes — {date:yyyy-MM-dd}\n\nAgenda\n- != -> ==") }
    Sample("Snippet body: monoBody, multi-line", padded = true) {
        LabeledField(
            value = body,
            onValueChange = { body = it },
            caption = "Snippet",
            tag = "editor.body",
            placeholder = "Paste or type",
            singleLine = false,
            minHeight = Dimens.bodyFieldMinHeight,
            textStyle = SnippetsTheme.typography.monoBody,
        )
    }
    var keyword by rememberSaveable { mutableStateOf("notes") }
    Sample("Keyword field: warning message (focus hides it)", padded = true) {
        KeywordField(
            value = keyword,
            onValueChange = { keyword = it },
            caption = "Keyword",
            message = "\\notes is already used by Meeting room.",
            messageIsWarning = true,
            helpWhileFocused = {
                Text(
                    text = "Existing · \\notes  ·  \\notes-2",
                    style = SnippetsTheme.typography.monoToken,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
        )
    }
    Sample("Keyword field: empty, info message", padded = true) {
        KeywordField(
            value = "",
            onValueChange = {},
            caption = "Keyword",
            tag = "sample.keyword-empty",
            message = "Add a keyword to make this available for expansion on Mac.",
        )
    }
    var tags by remember { mutableStateOf(listOf(GallerySamples.tag("work"), GallerySamples.tag("notes"), GallerySamples.tag("conflict"))) }
    var tagInput by rememberSaveable { mutableStateOf("") }
    fun commit(text: String) {
        val added = text.split(',', '\n').map { it.trim() }.filter { it.isNotEmpty() }.map(GallerySamples::tag)
        tags = (tags + added).distinctBy { it.folded }
        tagInput = ""
    }
    Sample("Tag field (interactive: comma, Done, Backspace, ×)", padded = true) {
        TagField(
            tags = tags,
            input = tagInput,
            onInputChange = { text -> if (text.contains(',') || text.contains('\n')) commit(text) else tagInput = text },
            onCommitInput = { commit(tagInput) },
            onRemoveTag = { removed -> tags = tags - removed },
            onRemoveLastTag = { tags = tags.dropLast(1) },
            caption = "Tags",
        )
    }
    Sample("Tag field, empty", padded = true) {
        TagField(
            tags = emptyList(),
            input = "",
            onInputChange = {},
            onCommitInput = {},
            onRemoveTag = {},
            onRemoveLastTag = {},
            caption = "Tags",
            tag = "sample.tags-empty",
        )
    }
    var password by rememberSaveable { mutableStateOf("correct horse") }
    var passwordVisible by rememberSaveable { mutableStateOf(false) }
    Sample("Password field (interactive)", padded = true) {
        PasswordField(
            value = password,
            onValueChange = { password = it },
            caption = "Backup password",
            passwordVisible = passwordVisible,
            onPasswordVisibleChange = { passwordVisible = it },
            tag = "backup.password",
            isNewPassword = true,
        )
    }
    Sample("Password field: error, with Paste", padded = true) {
        PasswordField(
            value = "ghp_example",
            onValueChange = {},
            caption = "Access Token",
            passwordVisible = true,
            onPasswordVisibleChange = {},
            errorText = "The Git host didn’t accept the access token.",
            onPasteClick = {},
        )
    }
    var code by rememberSaveable { mutableStateOf("7K2M9QXD4FTRHV3NP8WC6Y") }
    val pasteCode = rememberClipboardPaste { text ->
        code = CodeFormat.sanitize(text)
        events.log("pasted ${code.length} symbols")
    }
    Sample("Code field (interactive: live grouping, Paste, counter)", padded = true) {
        CodeField(
            value = code,
            onValueChange = { code = it },
            caption = "Recovery key",
            expectedLength = GallerySamples.RECOVERY_KEY.length,
            onPasteClick = pasteCode,
            tag = "secure.restore.field",
            placeholder = "XXXX-XXXX-XXXX-…",
        )
    }
    Sample("Code field: empty", padded = true) {
        CodeField(value = "", onValueChange = {}, caption = "Recovery code", expectedLength = 27, onPasteClick = {}, placeholder = "XXXX-XXXX-XXXX-…")
    }
    Sample("Code field: complete, with an error", padded = true) {
        CodeField(
            value = GallerySamples.RECOVERY_KEY,
            onValueChange = {},
            caption = "Recovery key",
            expectedLength = 27,
            onPasteClick = {},
            errorText = "That recovery key has a typo in it.",
        )
    }
    var enabled by rememberSaveable { mutableStateOf(true) }
    var secure by rememberSaveable { mutableStateOf(false) }
    val haptics = rememberSnippetsHaptics()
    Sample("Switch rows (interactive)") {
        Column {
            SwitchRow(
                title = "Enabled",
                checked = enabled,
                onCheckedChange = {
                    enabled = it
                    haptics.toggle(it)
                },
                tag = "editor.enabled",
                supportingText = "Allow this keyword to expand on Mac.",
            )
            SwitchRow(
                title = "Secure",
                checked = secure,
                onCheckedChange = {
                    secure = it
                    haptics.toggle(it)
                },
                tag = "editor.secure",
                supportingText = "Encrypt the body and require fingerprint, face or screen lock to reveal or copy it.",
            )
            SwitchRow(title = "Dynamic colour", checked = false, onCheckedChange = {}, enabled = false, supportingText = "Needs Android 12 or later.")
        }
    }
}

// Settings rows -------------------------------------------------------------------------------

@Composable
private fun SettingsSection(events: GalleryEvents) {
    var highlighted by remember { mutableStateOf(false) }
    var syncOn by rememberSaveable { mutableStateOf(true) }
    Sample("Rows: every variant") {
        Column {
            SectionHeader("Library")
            SettingsRow(key = "sync", title = "Sync", icon = SnippetsIcon.Sync, detail = "On. Last synced at 9:04 PM.", onClick = { events.log("sync") })
            SettingsRow(key = "secure", title = "Secure Snippets", icon = SnippetsIcon.Lock, detail = "Locked. Secure snippets stay encrypted until you authenticate.", onClick = {})
            SettingsRow(key = "backup", title = "Backup", icon = SnippetsIcon.HardDrive, onClick = {})
            SettingsRow(
                key = "highlight",
                title = "Appearance (tap: search-result highlight)",
                icon = SnippetsIcon.Palette,
                highlighted = highlighted,
                onClick = { highlighted = !highlighted },
            )
            SettingsRow(key = "vault-status", title = "Secure Snippets Status", kind = SettingsRowKind.Value, icon = SnippetsIcon.Lock, detail = "Unlocked for this session. Copying a secure snippet still asks every time.")
            SettingsRow(key = "sync-status", title = "Status", kind = SettingsRowKind.Value, icon = SnippetsIcon.SyncProblem, detail = "Stopped because an unusually large deletion arrived.", detailIsError = true)
            SettingsSwitchRow(key = "sync-library", title = "Sync This Library", checked = syncOn, onCheckedChange = { syncOn = it }, icon = SnippetsIcon.Sync, detail = "Keeps this library in step with your other devices.")
            SettingsRow(key = "sync-now", title = "Sync Now", kind = SettingsRowKind.Action, onClick = { events.log("sync now") })
            SettingsRow(key = "lock-now", title = "Lock Now", kind = SettingsRowKind.Action, working = true)
            SettingsRow(key = "repair", title = "Repair Sync", kind = SettingsRowKind.Attention, detail = "Rebuilds the sync state on this device from your library.", onClick = {})
            SettingsRow(key = "remove-vault", title = "Remove Secure Snippets from This Device", kind = SettingsRowKind.Destructive, icon = SnippetsIcon.Delete, detail = "This also removes the vault key stored on this device.", onClick = {})
            SettingsRow(key = "provider", title = "Sync Provider", kind = SettingsRowKind.Disabled, icon = SnippetsIcon.Commit, detail = "Turn off Sync This Library first.")
            SettingsRow(key = "github", title = "Snippets on GitHub", kind = SettingsRowKind.Link, icon = SnippetsIcon.Info, onClick = {})
        }
    }
}

// Progress -----------------------------------------------------------------------------------

@Composable
private fun ProgressSection(events: GalleryEvents) {
    Sample("Steps: done, running, pending, failed", padded = true) {
        ProgressSteps(steps = GallerySamples.steps)
    }
    Sample("A failed run: the problem card follows the list", padded = true) {
        Column(verticalArrangement = Arrangement.spacedBy(Spacing.m)) {
            ProgressSteps(steps = GallerySamples.steps.take(1) + GallerySamples.steps.last())
            ProblemCard(problem = GallerySamples.problemError, tagArea = "git", onCopyCode = { events.log("copy code") })
        }
    }
}

// Dialogs and templates ------------------------------------------------------------------------

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DialogsSection(events: GalleryEvents, initiallyOpen: String?) {
    var open by rememberSaveable { mutableStateOf(initiallyOpen) }
    var secretCopied by rememberSaveable { mutableStateOf(false) }
    val ids = listOf(
        "confirm" to "Confirm (destructive)",
        "confirm-3" to "Three buttons",
        "confirm-info" to "Dismiss only",
        "confirm-long" to "Long labels",
        "error" to "Error",
        "error-recovery" to "Error + recovery",
        "secret-leave" to "Secret leave",
        "progress" to "Progress",
        "secret" to "Secret screen",
        "secret-hidden" to "Secret, hidden",
        "review" to "Review screen",
        "review-running" to "Review, running",
        "review-failed" to "Review, failed",
        "review-close" to "Review, no action",
    )
    Sample("Open a dialog or template", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            ids.forEach { (id, label) ->
                SnippetsButton(label = label, onClick = { open = id }, level = ButtonLevel.Secondary)
            }
        }
    }
    Sample("Snackbars", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            SnippetsButton("Result", onClick = { events.snackbar.show("Secure snippet deleted.") }, level = ButtonLevel.Secondary)
            SnippetsButton(
                label = "With Undo",
                onClick = { events.snackbar.show("Deleted “Quick reply”.", actionLabel = "Undo") { events.log("undo") } },
                level = ButtonLevel.Secondary,
            )
            SnippetsButton("Progress note", onClick = { events.snackbar.show("Reading import…", kind = SnackbarKind.Progress) }, level = ButtonLevel.Secondary)
        }
    }
    val close = { open = null }
    when (open) {
        "confirm" -> ConfirmDialog(
            tag = "dialog.delete-secure",
            title = "Delete “Atlas API token”?",
            paragraphs = listOf("This permanently removes the encrypted snippet from this device and, when sync is on, from your other devices."),
            dismissLabel = "Cancel",
            onDismiss = close,
            confirmLabel = "Delete",
            onConfirm = close,
            destructive = true,
        )
        "confirm-3" -> ConfirmDialog(
            tag = "dialog.git-mode",
            title = "Create an Encrypted Library?",
            paragraphs = listOf(
                "Snippets encrypts every record before it is pushed to the repository.",
                "A plain-text library stores ordinary snippets as readable Markdown files instead.",
            ),
            dismissLabel = "Cancel",
            onDismiss = close,
            confirmLabel = "Create Encrypted Library",
            onConfirm = close,
            neutralLabel = "Plain Text Instead…",
            onNeutral = close,
        )
        "confirm-info" -> ConfirmDialog(
            tag = "dialog.remove-vault",
            title = "Remove Secure Snippets?",
            paragraphs = listOf("Turn off sync first."),
            dismissLabel = "Cancel",
            onDismiss = close,
        )
        "confirm-long" -> ConfirmDialog(
            tag = "dialog.git-hostkey-changed",
            title = "The Host Key Changed",
            paragraphs = listOf("The host presented a different key than the one this device trusted. Nothing was sent."),
            dismissLabel = "Keep the Trusted Key",
            onDismiss = close,
            confirmLabel = "Trust the New Host Key",
            onConfirm = close,
            destructive = true,
            warningIcon = true,
        )
        "error" -> ErrorDialog(title = "Couldn’t Copy Snippet", message = "The snippet no longer exists.", onDismiss = close)
        "error-recovery" -> ErrorDialog(
            title = "Couldn’t Set Up Secure Snippets",
            message = "Secure snippets are not set up for your Git library on this device yet.",
            onDismiss = close,
            recoveryLabel = "Open Git Repository",
            onRecovery = close,
        )
        "secret-leave" -> SecretLeaveDialog(
            message = "Snippets can’t show this recovery code again. Without it, a new device can’t open this library.",
            leaveLabel = "Done, I’ve Saved It",
            onGoBack = close,
            onLeave = close,
        )
        "progress" -> ProgressDialog(tag = "dialog.switch-progress", title = "Switching Sync") {
            Column {
                ProgressSteps(steps = GallerySamples.steps.take(3))
                SnippetsButton("Close (gallery only)", onClick = close, level = ButtonLevel.Tertiary)
            }
        }
        "secret", "secret-hidden" -> FullScreenDialogHost(onDismissRequest = close) { compact ->
            SecretScreen(
                ui = GallerySamples.secretScreen(copied = secretCopied, hidden = open == "secret-hidden"),
                onCopy = { secretCopied = true },
                onDone = close,
                onClose = close,
                compact = compact,
            )
        }
        "review", "review-running", "review-failed" -> FullScreenDialogHost(onDismissRequest = close) { compact ->
            ReviewScreen(
                ui = GallerySamples.review(running = open == "review-running", failed = open == "review-failed"),
                onConfirm = close,
                onDismiss = close,
                onCopyCode = { events.log("copy code") },
                compact = compact,
            )
        }
        "review-close" -> FullScreenDialogHost(onDismissRequest = close) { compact ->
            ReviewScreen(
                ui = GallerySamples.review(running = false, failed = false).copy(
                    heading = "Update Snippets",
                    happened = "A newer version of Snippets wrote this library.",
                    explanation = null,
                    code = "newer_schema",
                    confirmTitle = null,
                    isDestructive = false,
                ),
                onConfirm = {},
                onDismiss = close,
                onCopyCode = {},
                compact = compact,
            )
        }
        else -> Unit
    }
}

// Buttons --------------------------------------------------------------------------------------

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ButtonsSection(events: GalleryEvents) {
    Sample("Levels", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            SnippetsButton("Connect", onClick = { events.log("primary") })
            SnippetsButton("Copy", onClick = {}, level = ButtonLevel.Secondary, icon = SnippetsIcon.ContentCopy)
            SnippetsButton("Deny", onClick = {}, level = ButtonLevel.Peer)
            SnippetsButton("Cancel", onClick = {}, level = ButtonLevel.Tertiary)
        }
    }
    Sample("Destructive", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            SnippetsButton("Apply Deletions", onClick = {}, destructive = true)
            SnippetsButton("Remove", onClick = {}, level = ButtonLevel.Peer, destructive = true)
            SnippetsButton("Delete", onClick = {}, level = ButtonLevel.Tertiary, destructive = true)
        }
    }
    Sample("Working and disabled", padded = true) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Spacing.s)) {
            SnippetsButton("Working…", onClick = {}, working = true)
            SnippetsButton("Signing In…", onClick = {}, level = ButtonLevel.Secondary, working = true)
            SnippetsButton("Connect", onClick = {}, enabled = false)
        }
    }
    Sample("A long label wraps", padded = true) {
        SnippetsButton("Move Your Secure Snippets to the Library’s New Key and Reconnect", onClick = {})
    }
    Sample("Icon buttons (long-press for the tooltip)", padded = true) {
        Row {
            SnippetsIconButton(SnippetsIcon.MoreVert, contentDescription = "More", onClick = { events.log("more") })
            SnippetsIconButton(SnippetsIcon.ContentCopy, contentDescription = "Copy", onClick = {})
            SnippetsIconButton(SnippetsIcon.FilterList, contentDescription = "Filter by tags", onClick = {}, tonal = true)
            SnippetsIconButton(SnippetsIcon.Close, contentDescription = "Close", onClick = {}, enabled = false)
        }
    }
    var menuOpen by remember { mutableStateOf(false) }
    Sample("Menu: icons, divider, destructive last", padded = true) {
        Box {
            SnippetsButton("Open Menu", onClick = { menuOpen = true }, level = ButtonLevel.Secondary)
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                SnippetsMenuItem("Pin", SnippetsIcon.PushPin, "pin", onClick = { menuOpen = false })
                SnippetsMenuItem("Share Text", SnippetsIcon.Share, "share-text", onClick = { menuOpen = false })
                SnippetsMenuItem("Duplicate", SnippetsIcon.FileCopy, "duplicate", onClick = { menuOpen = false })
                SnippetsMenuDivider()
                SnippetsMenuItem("Delete", SnippetsIcon.Delete, "delete", onClick = { menuOpen = false }, destructive = true)
            }
        }
    }
    Sample("Dividers", padded = true) {
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    }
}
