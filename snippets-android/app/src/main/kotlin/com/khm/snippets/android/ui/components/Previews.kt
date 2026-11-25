package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme

/** The container every component preview uses: the theme, a surface and the compact margin. */
@Composable
internal fun PreviewSurface(
    darkTheme: Boolean,
    padded: Boolean = true,
    content: @Composable () -> Unit,
) {
    SnippetsTheme(darkTheme = darkTheme) {
        Surface(color = MaterialTheme.colorScheme.surface) {
            Box(modifier = if (padded) Modifier.padding(Dimens.marginCompact) else Modifier) {
                content()
            }
        }
    }
}
