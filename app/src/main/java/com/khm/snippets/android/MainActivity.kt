package com.khm.snippets.android

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.PersistableBundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.platform.LocalContext
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
}

@Composable
private fun LibraryScreen(
    state: LibraryState,
    query: String,
    onQuery: (String) -> Unit,
    onEdit: (SnippetItem) -> Unit,
    onSync: () -> Unit,
) {
    val context = LocalContext.current
    val filtered = state.snippets.filter { snippet ->
        query.isBlank() || listOf(snippet.name, snippet.keyword, snippet.content)
            .plus(snippet.tags).any { it.contains(query, ignoreCase = true) }
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(state.syncLabel, style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.weight(1f))
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
                Text(if (state.snippets.isEmpty()) "Your library is empty" else "No matches")
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(filtered, key = { it.id }) { snippet ->
                    SnippetCard(
                        snippet,
                        onOpen = { onEdit(snippet) },
                        onCopy = { copySensitive(context, snippet.content) },
                        onShare = { share(context, snippet.content) })
                }
            }
        }
    }
}

@Composable
private fun SnippetCard(
    snippet: SnippetItem,
    onOpen: () -> Unit,
    onCopy: () -> Unit,
    onShare: () -> Unit,
) {
    Card(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
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
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onCopy) { Text("Copy") }
                TextButton(onClick = onShare) { Text("Share") }
            }
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
                        tags = tags.split(',').map(String::trim).filter(String::isNotEmpty),
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

private fun copySensitive(context: Context, value: String) {
    val clip = ClipData.newPlainText("Snippet", value)
    clip.description.extras = PersistableBundle().apply {
        putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
    }
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
        .setPrimaryClip(clip)
}

private fun share(context: Context, value: String) {
    val intent = Intent(Intent.ACTION_SEND)
        .setType("text/plain")
        .putExtra(Intent.EXTRA_TEXT, value)
    context.startActivity(Intent.createChooser(intent, "Share snippet"))
}
