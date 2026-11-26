package com.khm.snippets.android.nav

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.components.EmptyState
import com.khm.snippets.android.ui.components.SnippetsIconButton
import com.khm.snippets.android.ui.components.TestTags
import com.khm.snippets.android.ui.icons.SnippetsIcon

/**
 * Stands in for a route whose screen is not built yet. It shows the route name so the gap is
 * obvious on a device and addressable in tests (`placeholder.<routeName>`); the engineer who
 * builds the screen replaces the entry in `SnippetsNavHost`.
 *
 * @param showBack False inside the detail pane of a two-pane scene.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaceholderScreen(route: Route, onBack: () -> Unit, showBack: Boolean = true) {
    val title = stringResource(R.string.placeholder_title)
    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .semantics { paneTitle = route.routeName }
            .testTag(PLACEHOLDER_TAG_PREFIX + route.routeName),
        topBar = {
            TopAppBar(
                title = { Text(route.routeName, modifier = Modifier.testTag(TestTags.TOPBAR_TITLE)) },
                navigationIcon = {
                    if (showBack) {
                        SnippetsIconButton(
                            icon = SnippetsIcon.ArrowBack,
                            contentDescription = stringResource(R.string.action_back),
                            onClick = onBack,
                            tag = TestTags.TOPBAR_BACK,
                        )
                    }
                },
            )
        },
        contentWindowInsets = WindowInsets.safeDrawing,
    ) { padding ->
        EmptyState(
            tagArea = "placeholder",
            title = title,
            message = stringResource(R.string.placeholder_message, route.routeName),
            modifier = Modifier.fillMaxSize().padding(padding),
            icon = SnippetsIcon.Info,
        )
    }
}

const val PLACEHOLDER_TAG_PREFIX = "placeholder."
