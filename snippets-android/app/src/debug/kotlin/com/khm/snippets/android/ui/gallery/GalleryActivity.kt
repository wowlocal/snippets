package com.khm.snippets.android.ui.gallery

import android.graphics.Color as AndroidColor
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import com.khm.snippets.android.ui.components.SnackbarController
import com.khm.snippets.android.ui.components.SnippetsSnackbarHost
import com.khm.snippets.android.ui.components.rememberSnackbarController
import com.khm.snippets.android.ui.theme.LocalReducedMotion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

/**
 * Debug-only gallery of the component library: every component in every state, in sections,
 * with a light / dark toggle and a font-scale preview.
 *
 * Start it with adb; optional extras choose the first view:
 * `--es section <id>` (see [GallerySection]), `--ez dark true`, `--ef fontScale 2.0`,
 * `--es open <dialog id>`, `--ez motion true` (shows full-motion states on a device whose
 * animator duration scale is 0; the system setting itself is never touched).
 */
class GalleryActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val startSection = GallerySection.entries.firstOrNull { it.id == intent.getStringExtra(EXTRA_SECTION) }
            ?: GallerySection.Theme
        val startDark = intent.getBooleanExtra(EXTRA_DARK, false)
        val startFontScale = intent.getFloatExtra(EXTRA_FONT_SCALE, 1f)
        val startOpen = intent.getStringExtra(EXTRA_OPEN)
        val startMotion = intent.getBooleanExtra(EXTRA_MOTION, false)
        setContent {
            var dark by rememberSaveable { mutableStateOf(startDark) }
            var fontScale by rememberSaveable { mutableFloatStateOf(startFontScale) }
            var section by rememberSaveable { mutableStateOf(startSection) }
            var forceMotion by rememberSaveable { mutableStateOf(startMotion) }
            DisposableEffect(dark) {
                enableEdgeToEdge(
                    statusBarStyle = if (dark) {
                        SystemBarStyle.dark(AndroidColor.TRANSPARENT)
                    } else {
                        SystemBarStyle.light(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT)
                    },
                    navigationBarStyle = if (dark) {
                        SystemBarStyle.dark(AndroidColor.TRANSPARENT)
                    } else {
                        SystemBarStyle.light(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT)
                    },
                )
                onDispose { }
            }
            SnippetsTheme(darkTheme = dark) {
                val density = LocalDensity.current
                // The font-scale preview: the gallery's own density, not a system setting.
                CompositionLocalProvider(
                    LocalDensity provides Density(density.density, fontScale),
                    LocalReducedMotion provides (LocalReducedMotion.current && !forceMotion),
                ) {
                    GalleryScreen(
                        section = section,
                        onSectionChange = { section = it },
                        dark = dark,
                        onDarkChange = { dark = it },
                        fontScale = fontScale,
                        onFontScaleChange = { fontScale = it },
                        forceMotion = forceMotion,
                        onForceMotionChange = { forceMotion = it },
                        initiallyOpen = startOpen,
                    )
                }
            }
        }
    }

    companion object {
        const val EXTRA_SECTION = "section"
        const val EXTRA_DARK = "dark"
        const val EXTRA_FONT_SCALE = "fontScale"
        const val EXTRA_OPEN = "open"
        const val EXTRA_MOTION = "motion"
    }
}

/** The gallery's sections. [id] is the value of the `section` extra. */
enum class GallerySection(val id: String, val title: String) {
    Theme("theme", "Theme"),
    Rows("rows", "Rows"),
    RowsTwoPane("rows-two-pane", "Rows 2-pane"),
    Library("library", "Library"),
    Tags("tags", "Tags"),
    Empty("empty", "Empty"),
    Sync("sync", "Sync"),
    Secure("secure", "Secure"),
    Secrets("secrets", "Secrets"),
    Fields("fields", "Fields"),
    Settings("settings", "Settings"),
    Progress("progress", "Progress"),
    Dialogs("dialogs", "Dialogs"),
    Buttons("buttons", "Buttons"),
}

internal val FontScales = listOf(1f, 1.3f, 2f)

/** What sections use to report interaction and to show snackbars. */
internal class GalleryEvents(
    val snackbar: SnackbarController,
    val log: (String) -> Unit,
)

@Composable
private fun GalleryScreen(
    section: GallerySection,
    onSectionChange: (GallerySection) -> Unit,
    dark: Boolean,
    onDarkChange: (Boolean) -> Unit,
    fontScale: Float,
    onFontScaleChange: (Float) -> Unit,
    forceMotion: Boolean,
    onForceMotionChange: (Boolean) -> Unit,
    initiallyOpen: String?,
) {
    val hostState = remember { SnackbarHostState() }
    val snackbar = rememberSnackbarController(hostState)
    var lastEvent by rememberSaveable { mutableStateOf("") }
    val events = remember(snackbar) { GalleryEvents(snackbar) { lastEvent = it } }
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        contentWindowInsets = WindowInsets.safeDrawing,
        snackbarHost = { SnippetsSnackbarHost(hostState) },
        topBar = {
            Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
                Column(
                    modifier = Modifier.windowInsetsPadding(
                        WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal),
                    ),
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = Spacing.s),
                        horizontalArrangement = Arrangement.spacedBy(Spacing.s),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FilterChip(
                            selected = dark,
                            onClick = { onDarkChange(!dark) },
                            label = { Text("Dark") },
                            modifier = Modifier.testTag("gallery.dark"),
                        )
                        FontScales.forEach { scale ->
                            FilterChip(
                                selected = fontScale == scale,
                                onClick = { onFontScaleChange(scale) },
                                label = { Text("${scale}×") },
                                modifier = Modifier.testTag("gallery.font-scale.$scale"),
                            )
                        }
                        FilterChip(
                            selected = forceMotion,
                            onClick = { onForceMotionChange(!forceMotion) },
                            label = { Text("Motion") },
                            modifier = Modifier.testTag("gallery.motion"),
                        )
                        Text(
                            text = lastEvent,
                            modifier = Modifier.testTag("gallery.event"),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = Spacing.s),
                        horizontalArrangement = Arrangement.spacedBy(Spacing.s),
                    ) {
                        GallerySection.entries.forEach { entry ->
                            FilterChip(
                                selected = entry == section,
                                onClick = { onSectionChange(entry) },
                                label = { Text(entry.title) },
                                modifier = Modifier.testTag("gallery.section.${entry.id}"),
                            )
                        }
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            key(section) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(bottom = Spacing.xxl)
                        .testTag("gallery.content"),
                ) {
                    GallerySectionContent(section = section, events = events, initiallyOpen = initiallyOpen)
                }
            }
        }
    }
}
