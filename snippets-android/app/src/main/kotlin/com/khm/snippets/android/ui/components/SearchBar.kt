package com.khm.snippets.android.ui.components

import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Spacing

/**
 * The library's always-visible search bar (components.md §4.1). It never expands into a search
 * view: the list below is the result set.
 *
 * The leading icon is decorative until the field has focus or a query; then it is a back arrow
 * that clears the query and the focus. IME `Search` hides the keyboard and keeps the query.
 *
 * @param onMoreClick Opens the More menu.
 * @param focusRequester Lets the screen focus the field (Ctrl+F, the Search shortcut). The field
 *   never takes focus by itself.
 * @param moreMenu Slot for the `DropdownMenu`; it is anchored to the More button.
 */
@Composable
fun LibrarySearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    onMoreClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester = remember { FocusRequester() },
    onSearch: () -> Unit = {},
    moreMenu: @Composable () -> Unit = {},
) {
    val focusManager = LocalFocusManager.current
    SearchField(
        query = query,
        onQueryChange = onQueryChange,
        placeholder = stringResource(R.string.library_search_placeholder),
        modifier = modifier,
        fieldTag = TestTags.LIBRARY_SEARCH,
        clearTag = TestTags.LIBRARY_SEARCH_CLEAR,
        focusRequester = focusRequester,
        onSearch = onSearch,
        leading = { active ->
            if (active) {
                SnippetsIconButton(
                    icon = SnippetsIcon.ArrowBack,
                    contentDescription = stringResource(R.string.library_search_back_description),
                    onClick = {
                        onQueryChange("")
                        focusManager.clearFocus()
                    },
                    tag = TestTags.LIBRARY_SEARCH_BACK,
                )
            } else {
                DecorativeSearchIcon()
            }
        },
        trailing = {
            Box {
                SnippetsIconButton(
                    icon = SnippetsIcon.MoreVert,
                    contentDescription = stringResource(R.string.action_more),
                    onClick = onMoreClick,
                    tag = TestTags.LIBRARY_MORE,
                )
                moreMenu()
            }
        },
    )
}

@Composable
private fun DecorativeSearchIcon() {
    Box(modifier = Modifier.size(Dimens.touchTarget), contentAlignment = Alignment.Center) {
        Glyph(SnippetsIcon.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * The search-bar visuals: a full-shape `surfaceContainerHigh` surface with a single-line field,
 * a clear button while there is text, and optional leading and trailing content. Autocorrect and
 * capitalisation are off; the IME action is `Search`.
 *
 * @param leading Receives true while the field has focus or a query.
 */
@Composable
fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    fieldTag: String? = null,
    clearTag: String? = null,
    focusRequester: FocusRequester = remember { FocusRequester() },
    onSearch: () -> Unit = {},
    leading: @Composable (active: Boolean) -> Unit = { DecorativeSearchIcon() },
    trailing: @Composable () -> Unit = {},
) {
    val colors = MaterialTheme.colorScheme
    val keyboard = LocalSoftwareKeyboardController.current
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.onSurface)
    Surface(
        modifier = modifier.heightIn(min = Dimens.searchBarMinHeight),
        shape = CircleShape,
        color = colors.surfaceContainerHigh,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = Spacing.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            leading(focused || query.isNotEmpty())
            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = Spacing.xs)
                    .focusRequester(focusRequester)
                    .then(if (fieldTag != null) Modifier.testTag(fieldTag) else Modifier),
                textStyle = textStyle,
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Text,
                    imeAction = ImeAction.Search,
                ),
                keyboardActions = KeyboardActions(
                    onSearch = {
                        keyboard?.hide()
                        onSearch()
                    },
                ),
                interactionSource = interactionSource,
                cursorBrush = SolidColor(colors.primary),
                decorationBox = { innerTextField ->
                    // As tall as a touch target, so a tap anywhere beside the icons focuses the field.
                    Box(
                        modifier = Modifier.heightIn(min = Dimens.touchTarget),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        if (query.isEmpty()) {
                            Text(
                                text = placeholder,
                                style = textStyle,
                                color = colors.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        innerTextField()
                    }
                },
            )
            if (query.isNotEmpty()) {
                SnippetsIconButton(
                    icon = SnippetsIcon.Close,
                    contentDescription = stringResource(R.string.library_search_clear_description),
                    onClick = {
                        onQueryChange("")
                        focusRequester.requestFocus()
                    },
                    tag = clearTag,
                )
            }
            trailing()
        }
    }
}

@Preview(name = "Search bar, light")
@Composable
private fun SearchBarPreviewLight() = PreviewSurface(darkTheme = false) { SearchBarPreviewContent() }

@Preview(name = "Search bar, dark")
@Composable
private fun SearchBarPreviewDark() = PreviewSurface(darkTheme = true) { SearchBarPreviewContent() }

@Composable
private fun SearchBarPreviewContent() {
    Column {
        LibrarySearchBar(query = "", onQueryChange = {}, onMoreClick = {}, modifier = Modifier.fillMaxWidth())
        LibrarySearchBar(
            query = "atlas",
            onQueryChange = {},
            onMoreClick = {},
            modifier = Modifier.fillMaxWidth().padding(top = Spacing.s),
        )
    }
}
