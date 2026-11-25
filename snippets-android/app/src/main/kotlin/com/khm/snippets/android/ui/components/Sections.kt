package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.theme.Dimens

/**
 * A section header (components.md §5): `Pinned` in the library, `Library`, `General`, `Support`
 * in Settings, and form sections. It is a heading and is not sticky.
 */
@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    tag: String? = null,
) {
    Text(
        text = title,
        modifier = modifier
            .fillMaxWidth()
            .padding(
                start = Dimens.marginCompact,
                end = Dimens.marginCompact,
                top = Dimens.headerPaddingTop,
                bottom = Dimens.headerPaddingBottom,
            )
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .semantics { heading() },
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** The `Pinned` header above pinned matches. */
@Composable
fun PinnedHeader(modifier: Modifier = Modifier) {
    SectionHeader(
        title = stringResource(R.string.library_header_pinned),
        modifier = modifier,
        tag = TestTags.LIBRARY_HEADER_PINNED,
    )
}

/** The full-width divider between the pinned group and the rest: 8 dp above and below. */
@Composable
fun GroupDivider(modifier: Modifier = Modifier) {
    HorizontalDivider(
        modifier = modifier.padding(vertical = Dimens.groupDividerSpace),
        thickness = Dimens.borderThin,
        color = MaterialTheme.colorScheme.outlineVariant,
    )
}

/**
 * The library's count footer: `42 snippets`, or `3 of 42 snippets` while a query or filters are
 * active.
 *
 * @param visibleCount Entries currently listed.
 * @param totalCount Entries in the library.
 * @param filtered True while a query or tag filters narrow the list.
 */
@Composable
fun LibraryCountFooter(
    visibleCount: Int,
    totalCount: Int,
    filtered: Boolean,
    modifier: Modifier = Modifier,
) {
    Text(
        text = if (filtered) {
            pluralStringResource(R.plurals.library_count_filtered, totalCount, visibleCount, totalCount)
        } else {
            pluralStringResource(R.plurals.library_count, totalCount, totalCount)
        },
        modifier = modifier
            .fillMaxWidth()
            .padding(Dimens.marginCompact)
            .testTag(TestTags.LIBRARY_COUNT),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
    )
}

@Preview(name = "Sections, light")
@Composable
private fun SectionsPreviewLight() = PreviewSurface(darkTheme = false, padded = false) { SectionsPreviewContent() }

@Preview(name = "Sections, dark")
@Composable
private fun SectionsPreviewDark() = PreviewSurface(darkTheme = true, padded = false) { SectionsPreviewContent() }

@Composable
private fun SectionsPreviewContent() {
    Column {
        PinnedHeader()
        GroupDivider()
        LibraryCountFooter(visibleCount = 42, totalCount = 42, filtered = false)
        LibraryCountFooter(visibleCount = 3, totalCount = 42, filtered = true)
    }
}
