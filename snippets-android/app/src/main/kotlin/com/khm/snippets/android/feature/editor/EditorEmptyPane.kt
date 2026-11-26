package com.khm.snippets.android.feature.editor

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.khm.snippets.android.R
import com.khm.snippets.android.feature.library.LibraryTags
import com.khm.snippets.android.ui.components.EmptyState
import com.khm.snippets.android.ui.icons.SnippetsIcon

/** The detail pane while nothing is selected (screens-library-editor.md §1.2): `editor.empty`. */
@Composable
fun EditorEmptyPane(modifier: Modifier = Modifier) {
    EmptyState(
        tagArea = LibraryTags.DETAIL_EMPTY_AREA,
        title = stringResource(R.string.editor_empty_title),
        message = stringResource(R.string.editor_empty_message),
        modifier = modifier.fillMaxSize(),
        icon = SnippetsIcon.Description,
    )
}
