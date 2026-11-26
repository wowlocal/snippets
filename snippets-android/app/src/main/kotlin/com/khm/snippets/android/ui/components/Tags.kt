package com.khm.snippets.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.TagFilterUi
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.model.highlightedString
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing
import com.khm.snippets.android.ui.theme.TagColor

/** Text colour and fill of [tag]: its palette slot, or the warning pair for `conflict`. */
@Composable
fun tagColorOf(tag: TagUi): TagColor = if (tag.isConflict) {
    TagColor(
        text = SnippetsTheme.colors.onWarningContainer,
        fill = SnippetsTheme.colors.warningContainer,
    )
} else {
    SnippetsTheme.tagPalette.colorFor(tag.folded)
}

/**
 * A read-only tag pill (components.md §3.1). It always carries text; the fill is opaque. The
 * `conflict` tag uses the warning colours and a warning icon.
 */
@Composable
fun TagPill(
    tag: TagUi,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val tagColor = tagColorOf(tag)
    val highlightBackground = colors.tertiaryContainer
    val highlightForeground = colors.onTertiaryContainer
    val text = remember(tag, highlightBackground, highlightForeground) {
        highlightedString(tag.name, tag.highlights, highlightBackground, highlightForeground)
    }
    Row(
        modifier = modifier
            .heightIn(min = Dimens.pillMinHeight)
            .background(color = tagColor.fill, shape = MaterialTheme.shapes.small)
            .padding(horizontal = Dimens.pillPaddingHorizontal),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (tag.isConflict) {
            Glyph(SnippetsIcon.Warning, contentDescription = null, tint = tagColor.text, size = Dimens.iconPill)
            Spacer(Modifier.width(Dimens.pillIconGap))
        }
        Text(
            text = text,
            color = tagColor.text,
            style = MaterialTheme.typography.labelSmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The chip row under the search bar (components.md §3.2). It does not scroll with the list.
 *
 * @param tags In display order: selected chips first, in the order they were selected, then the
 *   rest alphabetically. The caller owns that order.
 * @param onToggleTag Toggles one filter. Perform [SnippetsHaptic.TagFilterToggled] there.
 * @param onOpenFilters Opens the tag filter sheet.
 */
@Composable
fun TagFilterRow(
    tags: List<TagFilterUi>,
    onToggleTag: (TagUi) -> Unit,
    onOpenFilters: () -> Unit,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
) {
    val activeCount = tags.count { it.selected }
    // Selecting a chip moves it to the front; follow it.
    var previousActiveCount by remember { mutableIntStateOf(activeCount) }
    LaunchedEffect(activeCount) {
        if (activeCount > previousActiveCount) listState.animateScrollToItem(0)
        previousActiveCount = activeCount
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = Dimens.filterRowMinHeight),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FilterButton(
            activeCount = activeCount,
            onClick = onOpenFilters,
            modifier = Modifier.padding(start = Spacing.xs),
        )
        LazyRow(
            modifier = Modifier.weight(1f).testTag(TestTags.LIBRARY_TAG_ROW),
            state = listState,
            contentPadding = PaddingValues(start = Spacing.xs, end = Dimens.marginCompact),
            horizontalArrangement = Arrangement.spacedBy(Dimens.chipGap),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            items(items = tags, key = { it.tag.folded }) { filter ->
                TagFilterChip(
                    filter = filter,
                    onClick = { onToggleTag(filter.tag) },
                    modifier = Modifier.animateItem(),
                )
            }
        }
    }
}

@Composable
private fun FilterButton(
    activeCount: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state = if (activeCount == 0) {
        stringResource(R.string.library_filter_state_none)
    } else {
        pluralStringResource(R.plurals.library_filter_state_active, activeCount, activeCount)
    }
    val clickLabel = stringResource(R.string.library_filter_click_label)
    BadgedBox(
        badge = {
            if (activeCount > 0) {
                Badge(modifier = Modifier.testTag(TestTags.LIBRARY_FILTER_BADGE)) {
                    Text(text = activeCount.toString(), modifier = Modifier.clearAndSetSemantics { })
                }
            }
        },
        modifier = modifier,
    ) {
        SnippetsIconButton(
            icon = SnippetsIcon.FilterList,
            contentDescription = stringResource(R.string.library_filter_description),
            onClick = onClick,
            tag = TestTags.LIBRARY_FILTER,
            tonal = activeCount > 0,
            stateDescription = state,
            clickLabel = clickLabel,
        )
    }
}

@Composable
private fun TagFilterChip(
    filter: TagFilterUi,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tag = filter.tag
    val tagColor = tagColorOf(tag)
    val label = stringResource(R.string.library_tag_chip_description, tag.name)
    val onOff = stringResource(
        if (filter.selected) R.string.library_tag_chip_state_on else R.string.library_tag_chip_state_off,
    )
    val state = stringResource(
        R.string.library_tag_chip_state,
        onOff,
        pluralStringResource(R.plurals.library_count, filter.count, filter.count),
    )
    FilterChip(
        selected = filter.selected,
        onClick = onClick,
        label = {
            Row(
                modifier = Modifier.clearAndSetSemantics { },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(text = tag.name, style = MaterialTheme.typography.labelLarge, maxLines = 1)
                Spacer(Modifier.width(Spacing.xs))
                Text(
                    text = filter.count.toString(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        },
        modifier = modifier
            .testTag(TestTags.tagChip(tag.folded))
            .semantics {
                contentDescription = label
                stateDescription = state
            },
        leadingIcon = {
            if (filter.selected) {
                Glyph(SnippetsIcon.Check, contentDescription = null, size = Dimens.iconSmall)
            } else {
                Box(
                    modifier = Modifier.size(Dimens.iconSmall),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(Modifier.size(Dimens.chipDot).background(tagColor.text, CircleShape))
                }
            }
        },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = MaterialTheme.colorScheme.secondaryContainer,
        ),
    )
}

/**
 * Content of the tag filter sheet (components.md §3.3); host it in a `ModalBottomSheet` with
 * `skipPartiallyExpanded = false` and a 640 dp maximum width. There is no Done button: handle,
 * scrim and back dismiss.
 *
 * @param tags The rows to show, alphabetical and already narrowed by [query].
 * @param libraryTagCount Number of tags in the library; the search field shows above 12, the
 *   empty state at 0.
 * @param activeFilterCount Number of active filters, for the title and the `Clear` button.
 * @param onToggleTag Applies or removes one filter immediately.
 * @param onClear Removes every filter; the sheet stays open.
 */
@Composable
fun TagFilterSheetContent(
    tags: List<TagFilterUi>,
    libraryTagCount: Int,
    activeFilterCount: Int,
    query: String,
    onQueryChange: (String) -> Unit,
    onToggleTag: (TagUi) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val announcer = rememberAnnouncer()
    val clearedAnnouncement = stringResource(R.string.tags_cleared_announcement)
    val clearClickLabel = stringResource(R.string.tags_clear_click_label)
    Column(modifier = modifier.fillMaxWidth().testTag(TestTags.TAGS_SHEET)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = Dimens.marginCompact, end = Spacing.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (activeFilterCount > 0) {
                    stringResource(R.string.tags_sheet_title_count, activeFilterCount)
                } else {
                    stringResource(R.string.tags_sheet_title)
                },
                modifier = Modifier
                    .weight(1f)
                    .testTag(TestTags.TAGS_TITLE)
                    .semantics { heading() },
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            TextButton(
                onClick = {
                    onClear()
                    announcer.announce(clearedAnnouncement)
                },
                modifier = Modifier
                    .testTag(TestTags.TAGS_CLEAR)
                    .semantics { onClick(label = clearClickLabel, action = null) },
                enabled = activeFilterCount > 0,
            ) {
                Text(stringResource(R.string.tags_clear))
            }
        }
        if (libraryTagCount == 0) {
            EmptyState(
                tagArea = "tags",
                title = stringResource(R.string.tags_empty_title),
                message = stringResource(R.string.tags_empty_message),
                icon = SnippetsIcon.Label,
                modifier = Modifier.padding(vertical = Spacing.xl),
            )
            return@Column
        }
        if (libraryTagCount > TAG_SEARCH_THRESHOLD) {
            SearchField(
                query = query,
                onQueryChange = onQueryChange,
                placeholder = stringResource(R.string.tags_search_placeholder),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Dimens.marginCompact, vertical = Spacing.s),
                fieldTag = TestTags.TAGS_SEARCH,
            )
        }
        if (tags.isEmpty()) {
            Text(
                text = stringResource(R.string.tags_no_match, query),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Dimens.marginCompact, vertical = Spacing.xl)
                    .testTag(TestTags.TAGS_NO_MATCH),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        } else {
            LazyColumn(modifier = Modifier.weight(1f, fill = false)) {
                items(items = tags, key = { it.tag.folded }) { filter ->
                    TagSheetRow(filter = filter, onToggle = { onToggleTag(filter.tag) })
                }
            }
        }
        Text(
            text = stringResource(R.string.tags_footer),
            modifier = Modifier
                .fillMaxWidth()
                .padding(Dimens.marginCompact)
                .testTag(TestTags.TAGS_FOOTER),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** The filter sheet offers its search field when the library has more tags than this. */
const val TAG_SEARCH_THRESHOLD = 12

@Composable
private fun TagSheetRow(
    filter: TagFilterUi,
    onToggle: () -> Unit,
) {
    val tag = filter.tag
    val value = pluralStringResource(
        if (filter.selected) R.plurals.tags_row_value_selected else R.plurals.tags_row_value_not_selected,
        filter.count,
        filter.count,
    )
    val clickLabel = stringResource(
        if (filter.selected) R.string.tags_row_click_remove else R.string.tags_row_click_apply,
    )
    ListItem(
        headlineContent = { Text(text = tag.name, modifier = Modifier.clearAndSetSemantics { }) },
        modifier = Modifier
            .testTag(TestTags.tagsRow(tag.folded))
            .toggleable(value = filter.selected, role = Role.Checkbox, onValueChange = { onToggle() })
            .semantics {
                contentDescription = tag.name
                stateDescription = value
                onClick(label = clickLabel, action = null)
            },
        leadingContent = {
            Glyph(SnippetsIcon.Label, contentDescription = null, tint = tagColorOf(tag).text)
        },
        trailingContent = {
            Row(
                modifier = Modifier.clearAndSetSemantics { },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = filter.count.toString(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.width(Spacing.m))
                Checkbox(checked = filter.selected, onCheckedChange = null)
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

private val PreviewTags = listOf(
    TagFilterUi(TagUi("work", "work"), count = 12, selected = true),
    TagFilterUi(TagUi("links", "links"), count = 7, selected = false),
    TagFilterUi(TagUi("conflict", "conflict"), count = 2, selected = false),
    TagFilterUi(TagUi("personal", "personal"), count = 5, selected = false),
)

@Preview(name = "Tags, light")
@Composable
private fun TagsPreviewLight() = PreviewSurface(darkTheme = false, padded = false) { TagsPreviewContent() }

@Preview(name = "Tags, dark")
@Composable
private fun TagsPreviewDark() = PreviewSurface(darkTheme = true, padded = false) { TagsPreviewContent() }

@Composable
private fun TagsPreviewContent() {
    Column {
        Row(
            modifier = Modifier.padding(Dimens.marginCompact),
            horizontalArrangement = Arrangement.spacedBy(Dimens.rowPillGap),
        ) {
            PreviewTags.forEach { TagPill(it.tag) }
        }
        TagFilterRow(tags = PreviewTags, onToggleTag = {}, onOpenFilters = {})
        TagFilterSheetContent(
            tags = PreviewTags,
            libraryTagCount = PreviewTags.size,
            activeFilterCount = 1,
            query = "",
            onQueryChange = {},
            onToggleTag = {},
            onClear = {},
        )
    }
}
