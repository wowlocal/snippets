package com.khm.snippets.android

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.PersistableBundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import java.util.UUID

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val repository = (application as SnippetsApplication).repository
        val initialQuery = intent.getStringExtra(EXTRA_SEARCH_QUERY).orEmpty()
        setContent { SnippetsTheme { SnippetsApp(repository, initialQuery) } }
    }

    companion object { const val EXTRA_SEARCH_QUERY = "search_query" }
}

private enum class Screen { LIBRARY, EDITOR, SETTINGS }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SnippetsApp(repository: SnippetRepository, initialQuery: String) {
    val state by repository.state.collectAsState()
    val scope = rememberCoroutineScope()
    var screen by rememberSaveable { mutableStateOf(Screen.LIBRARY) }
    var editing by remember { mutableStateOf<SnippetItem?>(null) }
    var query by rememberSaveable { mutableStateOf(initialQuery) }
    var activeTagKeys by remember { mutableStateOf(emptySet<String>()) }
    var showsTagFilters by rememberSaveable { mutableStateOf(false) }
    val availableTags = remember(state.snippets) { tagUsage(state.snippets) }
    LaunchedEffect(availableTags) {
        activeTagKeys = activeTagKeys.intersect(availableTags.mapTo(mutableSetOf()) { it.key })
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (screen == Screen.SETTINGS) "Settings" else "Snippets") },
                navigationIcon = {
                    if (screen != Screen.LIBRARY) TextButton(onClick = { screen = Screen.LIBRARY }) {
                        Text("Back")
                    }
                },
                actions = {
                    if (screen == Screen.LIBRARY) {
                        TextButton(onClick = { screen = Screen.SETTINGS }) { Text("Cloud") }
                        TextButton(onClick = {
                            editing = SnippetRepository.newSnippet()
                            screen = Screen.EDITOR
                        }) { Text("New") }
                    }
                })
        }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (screen) {
                Screen.LIBRARY -> LibraryScreen(
                    state = state,
                    query = query,
                    onQuery = { query = it },
                    activeTagKeys = activeTagKeys,
                    availableTags = availableTags,
                    onShowTagFilters = { showsTagFilters = true },
                    onToggleTag = { tag ->
                        val key = tagFilterKey(tag)
                        activeTagKeys = if (key in activeTagKeys) {
                            activeTagKeys - key
                        } else {
                            activeTagKeys + key
                        }
                    },
                    onClearTagFilters = { activeTagKeys = emptySet() },
                    onEdit = { editing = it; screen = Screen.EDITOR },
                    onSync = { scope.launch { repository.syncNow() } })
                Screen.EDITOR -> EditorScreen(
                    initial = requireNotNull(editing),
                    onSave = { scope.launch { repository.save(it); screen = Screen.LIBRARY } },
                    onDelete = { id -> scope.launch { repository.delete(id); screen = Screen.LIBRARY } })
                Screen.SETTINGS -> SettingsScreen(repository, state)
            }
        }
    }
    if (showsTagFilters) {
        TagFilterSheet(
            tags = availableTags,
            activeTagKeys = activeTagKeys,
            onToggle = { key ->
                activeTagKeys = if (key in activeTagKeys) {
                    activeTagKeys - key
                } else {
                    activeTagKeys + key
                }
            },
            onClear = { activeTagKeys = emptySet() },
            onDismiss = { showsTagFilters = false })
    }
}

@Composable
internal fun LibraryScreen(
    state: LibraryState,
    query: String,
    onQuery: (String) -> Unit,
    activeTagKeys: Set<String>,
    availableTags: List<TagUsage>,
    onShowTagFilters: () -> Unit,
    onToggleTag: (String) -> Unit,
    onClearTagFilters: () -> Unit,
    onEdit: (SnippetItem) -> Unit,
    onSync: () -> Unit,
    copyAction: ((SnippetItem) -> Unit)? = null,
    shareAction: ((SnippetItem) -> Unit)? = null,
) {
    val context = LocalContext.current
    val filtered = filterLibrary(state.snippets, query, activeTagKeys)
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(state.syncLabel, style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.weight(1f))
            if (availableTags.isNotEmpty()) {
                OutlinedButton(onClick = onShowTagFilters) {
                    Text(if (activeTagKeys.isEmpty()) "Tags" else "Tags (${activeTagKeys.size})")
                }
            }
            if (state.provider == SyncProvider.SNIPPETS_CLOUD) {
                TextButton(enabled = !state.isBusy, onClick = onSync) {
                    Text(if (state.isBusy) "Syncing…" else "Sync now")
                }
            }
        }
        state.errorCode?.let {
            Text("Sync stopped: $it", color = MaterialTheme.colorScheme.error)
        }
        OutlinedTextField(
            value = query,
            onValueChange = onQuery,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Search") },
            singleLine = true)
        Spacer(Modifier.height(8.dp))
        if (filtered.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(when {
                        state.snippets.isEmpty() -> "Your library is empty"
                        activeTagKeys.isNotEmpty() -> "No snippets match these tags"
                        else -> "No matches"
                    })
                    if (activeTagKeys.isNotEmpty()) {
                        TextButton(onClick = onClearTagFilters) { Text("Clear tag filters") }
                    }
                }
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(filtered, key = { it.id }) { snippet ->
                    SnippetCard(
                        snippet,
                        activeTagKeys = activeTagKeys,
                        onToggleTag = onToggleTag,
                        onEdit = { onEdit(snippet) },
                        onCopy = {
                            copyAction?.invoke(snippet) ?: copySensitive(context, snippet)
                        },
                        onShare = {
                            shareAction?.invoke(snippet) ?: share(context, snippet.content)
                        })
                }
            }
        }
    }
}

@Composable
private fun SnippetCard(
    snippet: SnippetItem,
    activeTagKeys: Set<String>,
    onToggleTag: (String) -> Unit,
    onEdit: () -> Unit,
    onCopy: () -> Unit,
    onShare: () -> Unit,
) {
    Card(
        Modifier.fillMaxWidth().clickable(
            onClickLabel = "Copy snippet",
            role = Role.Button,
            onClick = onCopy)) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    snippet.name.ifBlank { "Untitled Snippet" },
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f))
                if (snippet.keyword.isNotBlank()) Text("\\${snippet.keyword}")
            }
            Text(
                snippet.content.lineSequence().firstOrNull().orEmpty(),
                maxLines = 2,
                style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(8.dp))
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically) {
                if (snippet.tags.isNotEmpty()) {
                    Row(
                        Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        snippet.tags.take(3).forEach { tag ->
                            TagPill(
                                tag = tag,
                                selected = tagFilterKey(tag) in activeTagKeys,
                                onClick = { onToggleTag(tag) })
                        }
                        if (snippet.tags.size > 3) {
                            Text(
                                "+${snippet.tags.size - 3}",
                                modifier = Modifier.padding(horizontal = 4.dp, vertical = 5.dp),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                } else {
                    Spacer(Modifier.weight(1f))
                }
                TextButton(onClick = onEdit) { Text("Edit") }
                TextButton(onClick = onShare) { Text("Share") }
            }
        }
    }
}

@Composable
private fun TagPill(
    tag: String,
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val accent = tagAccentColor(tag, isSystemInDarkTheme())
    val background = accent.copy(alpha = if (selected) 0.92f else 0.13f)
    val foreground = if (selected) {
        if (accent.luminance() > 0.55f) Color.Black.copy(alpha = 0.85f) else Color.White
    } else {
        accent
    }
    Surface(
        color = background,
        contentColor = foreground,
        shape = MaterialTheme.shapes.extraLarge,
        modifier = if (onClick == null) Modifier else Modifier.clickable(
            onClickLabel = "Filter by $tag",
            role = Role.Button,
            onClick = onClick)) {
        Text(
            tag,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Medium)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TagFilterSheet(
    tags: List<TagUsage>,
    activeTagKeys: Set<String>,
    onToggle: (String) -> Unit,
    onClear: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (activeTagKeys.isEmpty()) "Filter by tags"
                    else "Filter by tags (${activeTagKeys.size})",
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.weight(1f))
                TextButton(enabled = activeTagKeys.isNotEmpty(), onClick = onClear) {
                    Text("Clear")
                }
                TextButton(onClick = onDismiss) { Text("Done") }
            }
            Text(
                "A snippet must match every selected tag.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(8.dp))
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 480.dp)) {
                items(tags, key = { it.key }) { item ->
                    val selected = item.key in activeTagKeys
                    Row(
                        Modifier.fillMaxWidth()
                            .toggleable(
                                value = selected,
                                role = Role.Checkbox,
                                onValueChange = { onToggle(item.key) })
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        TagPill(tag = item.tag, selected = selected)
                        Spacer(Modifier.weight(1f))
                        Text(
                            "${item.count}",
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(
                            if (selected) "  ✓" else "",
                            color = MaterialTheme.colorScheme.primary,
                            fontWeight = FontWeight.Bold)
                    }
                    HorizontalDivider()
                }
            }
            Spacer(Modifier.height(20.dp))
        }
    }
}

@Composable
private fun EditorScreen(
    initial: SnippetItem,
    onSave: (SnippetItem) -> Unit,
    onDelete: (String) -> Unit,
) {
    var name by remember(initial.id) { mutableStateOf(initial.name) }
    var keyword by remember(initial.id) { mutableStateOf(initial.keyword) }
    var content by remember(initial.id) { mutableStateOf(initial.content) }
    var tags by remember(initial.id) { mutableStateOf(initial.tags.joinToString(", ")) }
    var enabled by remember(initial.id) { mutableStateOf(initial.isEnabled) }
    var pinned by remember(initial.id) { mutableStateOf(initial.isPinned) }
    val isExisting = remember(initial.id) { runCatching { UUID.fromString(initial.id) }.isSuccess && initial.name.isNotEmpty() }

    Column(
        Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Name") })
        OutlinedTextField(keyword, { keyword = it }, Modifier.fillMaxWidth(), label = { Text("Keyword") })
        OutlinedTextField(
            content, { content = it }, Modifier.fillMaxWidth().weight(1f),
            label = { Text("Content") })
        OutlinedTextField(tags, { tags = it }, Modifier.fillMaxWidth(), label = { Text("Tags, comma separated") })
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Enabled", Modifier.weight(1f)); Switch(enabled, { enabled = it })
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Pinned", Modifier.weight(1f)); Switch(pinned, { pinned = it })
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (isExisting) OutlinedButton(onClick = { onDelete(initial.id) }) { Text("Delete") }
            Spacer(Modifier.weight(1f))
            Button(
                enabled = content.isNotBlank(),
                onClick = {
                    onSave(initial.copy(
                        name = name,
                        keyword = keyword,
                        content = content,
                        tags = normalizedTags(tags.split(',')),
                        isEnabled = enabled,
                        isPinned = pinned))
                }) { Text("Save") }
        }
    }
}

@Composable
private fun SettingsScreen(repository: SnippetRepository, state: LibraryState) {
    val scope = rememberCoroutineScope()
    val initial = remember { repository.configuration() }
    var server by rememberSaveable { mutableStateOf(initial.serverURL) }
    var token by rememberSaveable { mutableStateOf(initial.accessToken) }
    var spaceID by rememberSaveable { mutableStateOf(initial.spaceID) }
    var keyBundle by rememberSaveable { mutableStateOf("") }

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Text("Active storage", style = MaterialTheme.typography.titleMedium)
            Text("One provider is writable at a time. Switching never deletes the local library or the other cloud.")
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    enabled = state.provider != SyncProvider.DEVICE,
                    onClick = { scope.launch { repository.useDeviceOnly() } }) {
                    Text("On device")
                }
                Button(
                    enabled = state.provider != SyncProvider.SNIPPETS_CLOUD,
                    onClick = {
                        scope.launch {
                            repository.configureCloud(server, token, spaceID)
                            repository.syncNow()
                        }
                    }) { Text("Snippets Cloud") }
            }
        }
        item {
            HorizontalDivider()
            Spacer(Modifier.height(8.dp))
            Text("Snippets Cloud", style = MaterialTheme.typography.titleMedium)
        }
        item {
            OutlinedTextField(
                server, { server = it }, Modifier.fillMaxWidth(),
                label = { Text("Server URL (HTTPS)") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        }
        item {
            OutlinedTextField(
                spaceID, { spaceID = it }, Modifier.fillMaxWidth(),
                label = { Text("Space ID") }, singleLine = true)
        }
        item {
            OutlinedTextField(
                token, { token = it }, Modifier.fillMaxWidth(),
                label = { Text("OIDC access token") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation())
        }
        item {
            Button(
                enabled = !state.isBusy,
                onClick = {
                    scope.launch {
                        repository.configureCloud(server, token, spaceID)
                        repository.syncNow()
                    }
                }) { Text("Switch and sync") }
        }
        item {
            HorizontalDivider()
            Spacer(Modifier.height(8.dp))
            Text("Portable library key", style = MaterialTheme.typography.titleMedium)
            Text("Import the encrypted-library key obtained by approved device pairing or recovery. The server never receives this key.")
        }
        item {
            OutlinedTextField(
                keyBundle, { keyBundle = it }, Modifier.fillMaxWidth(),
                label = { Text("Portable key bundle") }, minLines = 3,
                visualTransformation = PasswordVisualTransformation())
        }
        item {
            OutlinedButton(
                enabled = keyBundle.isNotBlank(),
                onClick = { scope.launch { repository.importPortableKeyBundle(keyBundle); keyBundle = "" } }) {
                Text("Import key")
            }
        }
        item {
            HorizontalDivider()
            Spacer(Modifier.height(8.dp))
            Text("iCloud remains available and unchanged in the Apple apps. Snippets Cloud uses the same encrypted record format, so switching providers is a sync operation rather than a data migration.")
            Spacer(Modifier.height(24.dp))
        }
    }
}

private fun copySensitive(context: Context, snippet: SnippetItem) {
    val clip = ClipData.newPlainText("Snippet", snippet.content)
    clip.description.extras = PersistableBundle().apply {
        putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
    }
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
        .setPrimaryClip(clip)
    Toast.makeText(
        context,
        "Copied ${snippet.name.ifBlank { "snippet" }}",
        Toast.LENGTH_SHORT).show()
}

private fun share(context: Context, value: String) {
    val intent = Intent(Intent.ACTION_SEND)
        .setType("text/plain")
        .putExtra(Intent.EXTRA_TEXT, value)
    context.startActivity(Intent.createChooser(intent, "Share snippet"))
}
