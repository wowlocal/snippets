package com.khm.snippets.android

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import java.util.UUID

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val repository = (application as SnippetsApplication).repository
        val initialQuery = intent.getStringExtra(EXTRA_SEARCH_QUERY).orEmpty()
        setContent { SnippetsTheme { SnippetsApp(repository, initialQuery) } }
        lifecycleScope.launch {
            repository.state.first { !it.isBusy }
            reportFullyDrawn()
        }
    }

    fun scanSnippetsQRCode(onResult: (String) -> Unit, onFailure: () -> Unit) {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { barcode ->
                barcode.rawValue?.takeIf(String::isNotBlank)?.let(onResult) ?: onFailure()
            }
            .addOnCanceledListener(onFailure)
            .addOnFailureListener { onFailure() }
    }

    fun confirmLibraryKeyDisclosure(
        confirmationCode: String? = null,
        onSuccess: () -> Unit,
        onFailure: () -> Unit,
    ) {
        val builder = BiometricPrompt.Builder(this)
            .setTitle("Approve encrypted library transfer")
            .setSubtitle(
                confirmationCode?.let { "Confirm code $it before adding this device" }
                    ?: "Confirm this security-sensitive change",
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            @Suppress("DEPRECATION")
            builder.setDeviceCredentialAllowed(true)
        } else {
            builder.setNegativeButton("Cancel", mainExecutor) { _, _ -> onFailure() }
        }
        builder.build().authenticate(
            CancellationSignal(),
            mainExecutor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) {
                    onSuccess()
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                    onFailure()
                }
            },
        )
    }

    companion object { const val EXTRA_SEARCH_QUERY = "search_query" }
}

private enum class Screen { LIBRARY, EDITOR, SETTINGS }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SnippetsApp(repository: SnippetRepository, initialQuery: String) {
    val state by repository.state.collectAsState()
    val scope = rememberCoroutineScope()
    val largeText = LocalDensity.current.fontScale >= 1.5f
    var screen by rememberSaveable { mutableStateOf(Screen.LIBRARY) }
    var editingID by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf(initialQuery) }
    var activeTagKeys by rememberSaveable(
        stateSaver = Saver<Set<String>, List<String>>(
            save = { value -> value.toList() },
            restore = { value -> value.toSet() },
        ),
    ) { mutableStateOf(emptySet<String>()) }
    var showsTagFilters by rememberSaveable { mutableStateOf(false) }
    val availableTags = remember(state.snippets) { tagUsage(state.snippets) }
    val editing = remember(editingID, state.snippets) {
        editingID?.let { id ->
            state.snippets.firstOrNull { it.id == id } ?: SnippetItem(
                id = id,
                name = "",
                keyword = "",
                content = "",
                tags = emptyList(),
                isEnabled = true,
                isPinned = false,
            )
        }
    }

    LaunchedEffect(availableTags) {
        activeTagKeys = activeTagKeys.intersect(availableTags.mapTo(mutableSetOf()) { it.key })
    }
    BackHandler(enabled = screen != Screen.LIBRARY) { screen = Screen.LIBRARY }

    BoxWithConstraints {
        val twoPane = shouldUseTwoPane(maxWidth.value, maxHeight.value)
        val title = when {
            twoPane || screen == Screen.LIBRARY -> "Snippets"
            screen == Screen.EDITOR && editing?.name.isNullOrBlank() -> "New snippet"
            screen == Screen.EDITOR -> "Edit snippet"
            else -> "Cloud & storage"
        }
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            contentWindowInsets = WindowInsets.safeDrawing,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            title,
                            style = if (largeText) MaterialTheme.typography.titleLarge
                            else MaterialTheme.typography.headlineMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    navigationIcon = {
                        if (!twoPane && screen != Screen.LIBRARY) {
                            IconButton(onClick = { screen = Screen.LIBRARY }) {
                                Icon(
                                    painterResource(R.drawable.ic_arrow_back),
                                    contentDescription = "Back",
                                )
                            }
                        }
                    },
                    actions = {
                        if (twoPane || screen == Screen.LIBRARY) {
                            IconButton(onClick = { screen = Screen.SETTINGS }) {
                                BadgedBox(
                                    badge = {
                                        if (state.errorCode != null) Badge()
                                    },
                                ) {
                                    Icon(
                                        painterResource(R.drawable.ic_cloud),
                                        contentDescription = "Cloud settings",
                                    )
                                }
                            }
                            FilledTonalIconButton(
                                onClick = {
                                    editingID = SnippetRepository.newSnippet().id
                                    screen = Screen.EDITOR
                                },
                                enabled = !state.isBusy,
                            ) {
                                Icon(
                                    painterResource(R.drawable.ic_add),
                                    contentDescription = "New snippet",
                                )
                            }
                            Spacer(Modifier.width(8.dp))
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.background,
                        scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                    ),
                )
            },
        ) { padding ->
            if (twoPane) {
                Row(Modifier.fillMaxSize().padding(padding)) {
                    LibraryScreen(
                        state = state,
                        query = query,
                        onQuery = { query = it },
                        activeTagKeys = activeTagKeys,
                        availableTags = availableTags,
                        onShowTagFilters = { showsTagFilters = true },
                        onToggleTag = { tag ->
                            activeTagKeys = activeTagKeys.toggled(tagFilterKey(tag))
                        },
                        onClearTagFilters = { activeTagKeys = emptySet() },
                        onEdit = { editingID = it.id; screen = Screen.EDITOR },
                        onSync = { scope.launch { repository.syncNow() } },
                        modifier = Modifier.weight(0.44f),
                    )
                    HorizontalDivider(
                        modifier = Modifier.fillMaxHeight().width(1.dp),
                        color = MaterialTheme.colorScheme.outlineVariant,
                    )
                    Surface(
                        modifier = Modifier.weight(0.56f).fillMaxHeight(),
                        color = MaterialTheme.colorScheme.surfaceContainerLowest,
                    ) {
                        DetailPane(
                            screen = screen,
                            editing = editing,
                            repository = repository,
                            state = state,
                            onSave = {
                                scope.launch { repository.save(it); screen = Screen.LIBRARY }
                            },
                            onDelete = { id ->
                                scope.launch { repository.delete(id); screen = Screen.LIBRARY }
                            },
                        )
                    }
                }
            } else {
                AnimatedContent(
                    targetState = screen,
                    label = "Snippets screen",
                    modifier = Modifier.fillMaxSize().padding(padding),
                ) { target ->
                    when (target) {
                        Screen.LIBRARY -> LibraryScreen(
                            state = state,
                            query = query,
                            onQuery = { query = it },
                            activeTagKeys = activeTagKeys,
                            availableTags = availableTags,
                            onShowTagFilters = { showsTagFilters = true },
                            onToggleTag = { tag ->
                                activeTagKeys = activeTagKeys.toggled(tagFilterKey(tag))
                            },
                            onClearTagFilters = { activeTagKeys = emptySet() },
                            onEdit = { editingID = it.id; screen = Screen.EDITOR },
                            onSync = { scope.launch { repository.syncNow() } },
                        )
                        Screen.EDITOR -> EditorScreen(
                            initial = requireNotNull(editing),
                            onSave = {
                                scope.launch { repository.save(it); screen = Screen.LIBRARY }
                            },
                            onDelete = { id ->
                                scope.launch { repository.delete(id); screen = Screen.LIBRARY }
                            },
                        )
                        Screen.SETTINGS -> SettingsScreen(repository, state)
                    }
                }
            }
        }
    }

    if (showsTagFilters) {
        TagFilterSheet(
            tags = availableTags,
            activeTagKeys = activeTagKeys,
            onToggle = { key -> activeTagKeys = activeTagKeys.toggled(key) },
            onClear = { activeTagKeys = emptySet() },
            onDismiss = { showsTagFilters = false },
        )
    }
}

@Composable
private fun DetailPane(
    screen: Screen,
    editing: SnippetItem?,
    repository: SnippetRepository,
    state: LibraryState,
    onSave: (SnippetItem) -> Unit,
    onDelete: (String) -> Unit,
) {
    AnimatedContent(targetState = screen, label = "Detail pane") { target ->
        when (target) {
            Screen.LIBRARY -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    modifier = Modifier.padding(40.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Surface(
                        color = MaterialTheme.colorScheme.primaryContainer,
                        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                        shape = MaterialTheme.shapes.extraLarge,
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_content_copy),
                            contentDescription = null,
                            modifier = Modifier.padding(20.dp).size(32.dp),
                        )
                    }
                    Text("Tap a snippet to copy", style = MaterialTheme.typography.titleLarge)
                    Text(
                        "Open its menu to edit or share.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Screen.EDITOR -> EditorScreen(requireNotNull(editing), onSave, onDelete)
            Screen.SETTINGS -> SettingsScreen(repository, state)
        }
    }
}

private fun Set<String>.toggled(key: String): Set<String> =
    if (key in this) this - key else this + key

internal fun shouldUseTwoPane(widthDp: Float, heightDp: Float): Boolean =
    widthDp >= 840f && heightDp >= 480f

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
    modifier: Modifier = Modifier,
    copyAction: ((SnippetItem) -> Unit)? = null,
    shareAction: ((SnippetItem) -> Unit)? = null,
) {
    val context = LocalContext.current
    val largeText = LocalDensity.current.fontScale >= 1.5f
    val filtered = filterLibrary(state.snippets, query, activeTagKeys)
    Column(modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            LibrarySearchField(
                query = query,
                onQuery = onQuery,
                activeFilterCount = activeTagKeys.size,
                onShowTagFilters = onShowTagFilters,
            )
            if (largeText) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SyncStatusChip(state, onSync)
                    Text(
                        if (filtered.size == 1) "1 snippet · Tap a row to copy"
                        else "${filtered.size} snippets · Tap a row to copy",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SyncStatusChip(state, onSync)
                    Spacer(Modifier.weight(1f))
                    Text(
                        if (filtered.size == 1) "Tap to copy · 1 snippet"
                        else "Tap to copy · ${filtered.size} snippets",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        AnimatedVisibility(visible = activeTagKeys.isNotEmpty()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val selectedName = availableTags.firstOrNull { it.key in activeTagKeys }?.tag
                FilterChip(
                    modifier = Modifier.weight(1f, fill = false),
                    selected = true,
                    onClick = onShowTagFilters,
                    label = {
                        Text(
                            if (activeTagKeys.size == 1 && selectedName != null) selectedName
                            else "${activeTagKeys.size} tags selected",
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                )
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onClearTagFilters) { Text("Clear") }
            }
        }

        AnimatedVisibility(visible = state.errorCode != null) {
            Surface(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                color = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
                shape = MaterialTheme.shapes.medium,
            ) {
                Text(
                    "Sync needs attention · ${state.errorCode.orEmpty()}",
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        }
        AnimatedVisibility(visible = state.isBusy) {
            LinearProgressIndicator(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp)
                    .semantics { contentDescription = "Loading library" },
            )
        }

        Spacer(Modifier.height(10.dp))
        if (filtered.isEmpty()) {
            EmptyLibrary(
                hasSnippets = state.snippets.isNotEmpty(),
                hasFilters = activeTagKeys.isNotEmpty(),
                onClearTagFilters = onClearTagFilters,
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = 16.dp,
                    end = 16.dp,
                    bottom = 28.dp,
                ),
            ) {
                itemsIndexed(filtered, key = { _, snippet -> snippet.id }) { index, snippet ->
                    SnippetRow(
                        snippet = snippet,
                        activeTagKeys = activeTagKeys,
                        onToggleTag = onToggleTag,
                        onEdit = { onEdit(snippet) },
                        onCopy = {
                            copyAction?.invoke(snippet) ?: copySensitive(context, snippet)
                        },
                        onShare = {
                            shareAction?.invoke(snippet) ?: share(context, snippet.content)
                        },
                        shape = segmentedShape(index, filtered.lastIndex),
                    )
                    if (index != filtered.lastIndex) {
                        HorizontalDivider(
                            modifier = Modifier.padding(horizontal = 16.dp),
                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.65f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun LibrarySearchField(
    query: String,
    onQuery: (String) -> Unit,
    activeFilterCount: Int,
    onShowTagFilters: () -> Unit,
) {
    TextField(
        value = query,
        onValueChange = onQuery,
        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search snippets" },
        placeholder = { Text("Search snippets") },
        leadingIcon = {
            Icon(painterResource(R.drawable.ic_search), contentDescription = null)
        },
        trailingIcon = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (query.isNotEmpty()) {
                    IconButton(onClick = { onQuery("") }) {
                        Icon(
                            painterResource(R.drawable.ic_close),
                            contentDescription = "Clear search",
                        )
                    }
                }
                IconButton(onClick = onShowTagFilters) {
                    BadgedBox(
                        badge = {
                            if (activeFilterCount > 0) Badge { Text("$activeFilterCount") }
                        },
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_filter),
                            contentDescription = "Tag filters",
                        )
                    }
                }
            }
        },
        singleLine = true,
        shape = MaterialTheme.shapes.extraLarge,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
        ),
    )
}

@Composable
private fun SyncStatusChip(state: LibraryState, onSync: () -> Unit) {
    if (state.provider == SyncProvider.DEVICE) {
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
            shape = MaterialTheme.shapes.extraLarge,
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Icon(
                    painterResource(R.drawable.ic_phone),
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Text(state.syncLabel, style = MaterialTheme.typography.labelLarge)
            }
        }
        return
    }
    AssistChip(
        onClick = onSync,
        enabled = !state.isBusy,
        label = { Text(state.syncLabel) },
        leadingIcon = {
            if (state.isBusy) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            } else {
                Icon(
                    painterResource(
                        if (state.provider == SyncProvider.SNIPPETS_CLOUD) R.drawable.ic_refresh
                        else R.drawable.ic_cloud,
                    ),
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
            }
        },
    )
}

@Composable
private fun EmptyLibrary(
    hasSnippets: Boolean,
    hasFilters: Boolean,
    onClearTagFilters: () -> Unit,
) {
    Box(
        Modifier.fillMaxSize().padding(16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                when {
                    !hasSnippets -> "Your library is empty"
                    hasFilters -> "No snippets match these tags"
                    else -> "No matches"
                },
                style = MaterialTheme.typography.titleLarge,
            )
            Text(
                if (hasSnippets) "Try a different search or filter."
                else "Create a snippet to copy it anywhere.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (hasFilters) {
                TextButton(onClick = onClearTagFilters) { Text("Clear tag filters") }
            }
        }
    }
}

private fun segmentedShape(index: Int, lastIndex: Int): RoundedCornerShape = when {
    lastIndex == 0 -> RoundedCornerShape(24.dp)
    index == 0 -> RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)
    index == lastIndex -> RoundedCornerShape(bottomStart = 24.dp, bottomEnd = 24.dp)
    else -> RoundedCornerShape(0.dp)
}

@Composable
private fun SnippetRow(
    snippet: SnippetItem,
    activeTagKeys: Set<String>,
    onToggleTag: (String) -> Unit,
    onEdit: () -> Unit,
    onCopy: () -> Unit,
    onShare: () -> Unit,
    shape: RoundedCornerShape,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .alpha(if (snippet.isEnabled) 1f else 0.62f)
            .clickable(
                onClickLabel = "Copy snippet",
                role = Role.Button,
                onClick = onCopy,
            ),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = shape,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(start = 16.dp, top = 14.dp, bottom = 14.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    snippet.name.ifBlank { "Untitled snippet" },
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (snippet.keyword.isNotBlank()) {
                    Surface(
                        modifier = Modifier.widthIn(max = 132.dp),
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                        shape = MaterialTheme.shapes.small,
                    ) {
                        Text(
                            "\\${snippet.keyword}",
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            style = MaterialTheme.typography.labelLarge,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                Box {
                    IconButton(onClick = { menuExpanded = true }) {
                        Icon(
                            painterResource(R.drawable.ic_more_vert),
                            contentDescription = "More options for ${snippet.name.ifBlank { "snippet" }}",
                        )
                    }
                    DropdownMenu(
                        expanded = menuExpanded,
                        onDismissRequest = { menuExpanded = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text("Edit") },
                            leadingIcon = {
                                Icon(painterResource(R.drawable.ic_edit), contentDescription = null)
                            },
                            onClick = { menuExpanded = false; onEdit() },
                        )
                        DropdownMenuItem(
                            text = { Text("Share") },
                            leadingIcon = {
                                Icon(painterResource(R.drawable.ic_share), contentDescription = null)
                            },
                            onClick = { menuExpanded = false; onShare() },
                        )
                    }
                }
            }
            Text(
                snippet.content.lineSequence().firstOrNull().orEmpty(),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(end = 16.dp),
            )
            if (snippet.tags.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                        .padding(top = 3.dp, end = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    snippet.tags.take(4).forEach { tag ->
                        TagPill(
                            tag = tag,
                            selected = tagFilterKey(tag) in activeTagKeys,
                            onClick = { onToggleTag(tag) },
                        )
                    }
                    if (snippet.tags.size > 4) {
                        Text(
                            "+${snippet.tags.size - 4}",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
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
    val content: @Composable () -> Unit = {
        Text(
            tag,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Medium,
        )
    }
    if (onClick == null) {
        Surface(
            modifier = Modifier.semantics { this.selected = selected },
            color = background,
            contentColor = foreground,
            shape = MaterialTheme.shapes.extraLarge,
            content = content,
        )
    } else {
        Surface(
            onClick = onClick,
            modifier = Modifier.semantics { this.selected = selected },
            color = background,
            contentColor = foreground,
            shape = MaterialTheme.shapes.extraLarge,
            content = content,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TagFilterSheet(
    tags: List<TagUsage>,
    activeTagKeys: Set<String>,
    onToggle: (String) -> Unit,
    onClear: () -> Unit,
    onDismiss: () -> Unit,
) {
    var tagQuery by rememberSaveable { mutableStateOf("") }
    val visibleTags = remember(tags, tagQuery) {
        val normalizedQuery = tagQuery.trim()
        if (normalizedQuery.isEmpty()) tags
        else tags.filter { it.tag.contains(normalizedQuery, ignoreCase = true) }
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Filter by tags", style = MaterialTheme.typography.titleLarge)
                    Text(
                        "Matches every selected tag",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                TextButton(enabled = activeTagKeys.isNotEmpty(), onClick = onClear) {
                    Text("Clear")
                }
                TextButton(onClick = onDismiss) { Text("Done") }
            }
            Spacer(Modifier.height(12.dp))
            TextField(
                value = tagQuery,
                onValueChange = { tagQuery = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Search tags") },
                leadingIcon = {
                    Icon(painterResource(R.drawable.ic_search), contentDescription = null)
                },
                trailingIcon = {
                    if (tagQuery.isNotEmpty()) {
                        IconButton(onClick = { tagQuery = "" }) {
                            Icon(
                                painterResource(R.drawable.ic_close),
                                contentDescription = "Clear tag search",
                            )
                        }
                    }
                },
                singleLine = true,
                shape = MaterialTheme.shapes.extraLarge,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
            )
            Spacer(Modifier.height(8.dp))
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 480.dp)) {
                items(visibleTags, key = { it.key }) { item ->
                    val selected = item.key in activeTagKeys
                    Row(
                        Modifier.fillMaxWidth()
                            .heightIn(min = 48.dp)
                            .toggleable(
                                value = selected,
                                role = Role.Checkbox,
                                onValueChange = { onToggle(item.key) },
                            )
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TagPill(tag = item.tag, selected = selected)
                        Spacer(Modifier.weight(1f))
                        Text(
                            "${item.count}",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (selected) {
                            Text(
                                "  ✓",
                                color = MaterialTheme.colorScheme.primary,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                    }
                    HorizontalDivider()
                }
            }
            Spacer(Modifier.height(20.dp))
        }
    }
}

@Composable
internal fun EditorScreen(
    initial: SnippetItem,
    onSave: (SnippetItem) -> Unit,
    onDelete: (String) -> Unit,
) {
    var name by rememberSaveable(initial.id) { mutableStateOf(initial.name) }
    var keyword by rememberSaveable(initial.id) { mutableStateOf(initial.keyword) }
    var content by rememberSaveable(initial.id) { mutableStateOf(initial.content) }
    var tags by rememberSaveable(initial.id) { mutableStateOf(initial.tags.joinToString(", ")) }
    var enabled by rememberSaveable(initial.id) { mutableStateOf(initial.isEnabled) }
    var pinned by rememberSaveable(initial.id) { mutableStateOf(initial.isPinned) }
    val isExisting = remember(initial.id) {
        runCatching { UUID.fromString(initial.id) }.isSuccess && initial.name.isNotEmpty()
    }

    Column(
        Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            if (isExisting) "Edit snippet" else "Create snippet",
            style = MaterialTheme.typography.titleLarge,
        )
        OutlinedTextField(
            name, { name = it }, Modifier.fillMaxWidth(),
            label = { Text("Name") },
            singleLine = true,
            shape = MaterialTheme.shapes.medium,
        )
        OutlinedTextField(
            keyword, { keyword = it }, Modifier.fillMaxWidth(),
            label = { Text("Keyword") },
            singleLine = true,
            shape = MaterialTheme.shapes.medium,
        )
        OutlinedTextField(
            content, { content = it }, Modifier.fillMaxWidth().weight(1f),
            label = { Text("Content") },
            shape = MaterialTheme.shapes.medium,
        )
        OutlinedTextField(
            tags, { tags = it }, Modifier.fillMaxWidth(),
            label = { Text("Tags, comma separated") },
            shape = MaterialTheme.shapes.medium,
        )
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerLow,
            shape = MaterialTheme.shapes.large,
        ) {
            Column(Modifier.animateContentSize()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Enabled", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                    Switch(enabled, { enabled = it })
                }
                HorizontalDivider(Modifier.padding(horizontal = 16.dp))
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Pinned", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                    Switch(pinned, { pinned = it })
                }
            }
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
                        isPinned = pinned,
                    ))
                },
            ) { Text("Save") }
        }
    }
}

@Composable
private fun SettingsScreen(repository: SnippetRepository, state: LibraryState) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val activity = LocalActivity.current as? MainActivity
    val cloudConfigured = BuildConfig.SNIPPETS_CLOUD_URL.isNotBlank() &&
        !BuildConfig.SNIPPETS_OAUTH_REDIRECT_URI.contains(".invalid/")
    // Recovery input is a decryption secret: never serialize it into SavedState.
    var recoveryCode by remember { mutableStateOf("") }
    var scannerFailed by rememberSaveable { mutableStateOf(false) }
    // Intentionally not saveable: leaving Settings or backgrounding the activity
    // destroys this disclosed copy and the durable kit remains biometric-locked.
    var recoveryPresentation by remember { mutableStateOf<RecoveryKitPresentation?>(null) }
    DisposableEffect(activity) {
        // Settings can contain a recovery secret. Keep the whole window out of
        // screenshots and recents until this composition (and its secret state) dies.
        activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val observer = object : DefaultLifecycleObserver {
            override fun onPause(owner: LifecycleOwner) {
                recoveryPresentation = null
                recoveryCode = ""
            }
        }
        activity?.lifecycle?.addObserver(observer)
        onDispose {
            activity?.lifecycle?.removeObserver(observer)
            recoveryPresentation = null
            recoveryCode = ""
            activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
    val signedIn = remember(state.provider, state.syncLabel, state.errorCode, state.cloudKeyStatus) {
        repository.isCloudSignedIn()
    }
    val loginLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        scope.launch {
            val completion = repository.completeCloudSignIn(result.data)
            completion.recoveryKit?.let { recoveryPresentation = it }
            if (completion.succeeded) repository.syncNow()
        }
    }

    fun launchStepUp() {
        scope.launch {
            repository.beginCloudSignIn(BuildConfig.SNIPPETS_CLOUD_URL, stepUp = true)
                ?.let(loginLauncher::launch)
        }
    }

    fun scan(onValue: suspend (String) -> Unit) {
        scannerFailed = false
        val scannerHost = activity
        if (scannerHost == null) {
            scannerFailed = true
            return
        }
        scannerHost.scanSnippetsQRCode(
            onResult = { value -> scope.launch { onValue(value) } },
            onFailure = { scannerFailed = true },
        )
    }

    fun authenticateThen(confirmationCode: String? = null, operation: () -> Unit) {
        val authenticationHost = activity
        if (authenticationHost == null) {
            scannerFailed = true
            return
        }
        authenticationHost.confirmLibraryKeyDisclosure(
            confirmationCode = confirmationCode,
            onSuccess = operation,
            onFailure = { scannerFailed = true },
        )
    }

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Text("Cloud & storage", style = MaterialTheme.typography.titleLarge)
            Text(
                "Choose the active writable provider without migrating or deleting the other cloud.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        item {
            SettingsCard(title = "Active storage") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = state.provider == SyncProvider.DEVICE,
                        onClick = { scope.launch { repository.useDeviceOnly() } },
                        label = { Text("On device") },
                    )
                    FilterChip(
                        selected = state.provider == SyncProvider.SNIPPETS_CLOUD,
                        onClick = {
                            scope.launch {
                                repository.useSnippetsCloud()
                                repository.syncNow()
                            }
                        },
                        label = { Text("Snippets Cloud") },
                    )
                }
                Text(
                    state.syncLabel,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
        item {
            SettingsCard(title = "Snippets Cloud") {
                Text(
                    if (signedIn) "Signed in. Your personal space and session renew automatically."
                    else "Continue in your browser with a passkey, Apple, or Google. Snippets has no password and does not require your email.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (cloudConfigured) {
                    Text(
                        BuildConfig.SNIPPETS_CLOUD_URL,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Text(
                        "This build has no pinned cloud endpoint and verified HTTPS sign-in callback.",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                Button(
                    enabled = !state.isBusy && cloudConfigured,
                    onClick = {
                        scope.launch {
                            repository.beginCloudSignIn(BuildConfig.SNIPPETS_CLOUD_URL)
                                ?.let(loginLauncher::launch)
                        }
                    },
                ) { Text(if (signedIn) "Sign in again" else "Continue securely") }
                if (signedIn) {
                    OutlinedButton(
                        enabled = !state.isBusy,
                        onClick = { scope.launch { repository.disconnectCloudAccount() } },
                    ) { Text("Sign out on this device") }
                }
                if (scannerFailed) {
                    Text(
                        "The secure system action was cancelled or unavailable.",
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                state.errorCode?.let { code ->
                    Text(
                        cloudErrorDescription(code),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
        if (signedIn) item {
            SettingsCard(title = "Encrypted library key") {
                val visibleRecoveryKit = recoveryPresentation
                if (visibleRecoveryKit != null) {
                    Text(
                        "Save this offline. It is the only fallback if every authorized device is lost.",
                        color = MaterialTheme.colorScheme.error,
                    )
                    SnippetsQRCode(visibleRecoveryKit.qrPayload, "Offline recovery kit QR")
                    Text(visibleRecoveryKit.longCode, style = MaterialTheme.typography.bodyMedium)
                    OutlinedButton(
                        onClick = { copySensitiveText(context, visibleRecoveryKit.longCode) },
                    ) { Text("Copy long code") }
                    Button(
                        onClick = {
                            recoveryPresentation = null
                            scope.launch { repository.acknowledgeRecoveryKitSaved() }
                        },
                    ) { Text("I saved it") }
                } else when (state.cloudKeyStatus) {
                    CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY -> {
                        Text(
                            "This account has encrypted data. Use a device that already opens it, or your offline recovery kit.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Button(
                            enabled = !state.isBusy,
                            onClick = { scope.launch { repository.beginDevicePairing() } },
                        ) { Text("Use nearby device") }
                        OutlinedButton(
                            enabled = !state.isBusy,
                            onClick = { scan(repository::restoreWithRecoveryKit) },
                        ) { Text("Scan recovery kit") }
                        OutlinedTextField(
                            recoveryCode,
                            { recoveryCode = it },
                            Modifier.fillMaxWidth(),
                            label = { Text("Long recovery code") },
                            visualTransformation = PasswordVisualTransformation(),
                            shape = MaterialTheme.shapes.medium,
                        )
                        OutlinedButton(
                            enabled = recoveryCode.isNotBlank() && !state.isBusy,
                            onClick = {
                                val value = recoveryCode
                                recoveryCode = ""
                                scope.launch { repository.restoreWithRecoveryKit(value) }
                            },
                        ) { Text("Restore encrypted library") }
                        Text(
                            "Without an authorized device or recovery kit, the account can be recovered but the old encrypted snippets cannot.",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }

                    CloudKeyStatus.WAITING_FOR_APPROVAL -> {
                        Text("Scan this one-time QR on a device that already opens the library.")
                        state.pairingQRCode?.let { SnippetsQRCode(it, "One-time device pairing QR") }
                        state.pairingConfirmationCode?.let {
                            Text("Check code: $it", style = MaterialTheme.typography.titleMedium)
                        }
                        Button(
                            enabled = !state.isBusy,
                            onClick = { scope.launch { repository.checkDevicePairing() } },
                        ) { Text("I approved it") }
                        TextButton(
                            enabled = !state.isBusy,
                            onClick = { scope.launch { repository.cancelDevicePairing() } },
                        ) { Text("Cancel pairing") }
                    }

                    CloudKeyStatus.APPROVAL_READY -> {
                        Text("Add this device to your encrypted library?")
                        state.approvalConfirmationCode?.let {
                            Text("Check code: $it", style = MaterialTheme.typography.titleMedium)
                        }
                        Button(
                            enabled = !state.isBusy,
                            onClick = {
                                authenticateThen(state.approvalConfirmationCode, ::launchStepUp)
                            },
                        ) { Text("Approve with biometrics") }
                        TextButton(
                            onClick = { scope.launch { repository.cancelPairingApproval() } },
                        ) { Text("Not this device") }
                    }

                    CloudKeyStatus.RECOVERY_AUTH_REQUIRED -> {
                        Text(
                            "Your library key is local. Confirm once to publish only its encrypted recovery envelope.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Button(
                            enabled = !state.isBusy,
                            onClick = { authenticateThen(operation = ::launchStepUp) },
                        ) { Text("Finish secure setup") }
                    }

                    CloudKeyStatus.RECOVERY_KIT_LOCKED -> {
                        Text(
                            "Your recovery kit is still waiting to be saved. Authenticate to reveal it again.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Button(
                            enabled = !state.isBusy,
                            onClick = {
                                authenticateThen {
                                    scope.launch {
                                        recoveryPresentation = repository.revealPendingRecoveryKit()
                                    }
                                }
                            },
                        ) { Text("Reveal with biometrics") }
                    }

                    CloudKeyStatus.READY -> {
                        Text(
                            "Ready. The server has encrypted snippets and envelopes only; this device holds its own credential and library key.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Button(
                            enabled = !state.isBusy,
                            onClick = { scan(repository::preparePairingApproval) },
                        ) { Text("Add another device") }
                        OutlinedButton(
                            enabled = !state.isBusy,
                            onClick = {
                                authenticateThen {
                                    scope.launch {
                                        repository.prepareRecoveryKitReplacement()
                                        launchStepUp()
                                    }
                                }
                            },
                        ) { Text("Replace recovery kit") }
                    }

                    CloudKeyStatus.SIGNED_OUT -> Unit
                }
            }
        }
        item {
            Text(
                "iCloud remains available and unchanged in the Apple apps. Snippets Cloud uses the same encrypted record format, so switching providers is a sync operation rather than a data migration.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
private fun SnippetsQRCode(payload: String, description: String) {
    val image = remember(payload) { qrBitmap(payload) }
    Image(
        bitmap = image.asImageBitmap(),
        contentDescription = description,
        modifier = Modifier.size(240.dp),
    )
}

private fun qrBitmap(payload: String): Bitmap {
    require(payload.toByteArray().size <= 4_096)
    val matrix = QRCodeWriter().encode(
        payload,
        BarcodeFormat.QR_CODE,
        512,
        512,
        mapOf(EncodeHintType.MARGIN to 2),
    )
    val pixels = IntArray(matrix.width * matrix.height)
    for (y in 0 until matrix.height) {
        for (x in 0 until matrix.width) {
            pixels[y * matrix.width + x] = if (matrix[x, y]) 0xff000000.toInt() else 0xffffffff.toInt()
        }
    }
    return Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
}

@Composable
private fun SettingsCard(
    title: String,
    content: @Composable () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        ),
        shape = MaterialTheme.shapes.large,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

private fun cloudErrorDescription(code: String): String = when (code) {
    "authorization_cancelled" -> "Sign-in was cancelled. Nothing changed."
    "sign_in_required", "authentication_required" -> "Please sign in again to continue syncing."
    "reauthentication_required" -> "Confirm this sensitive action with your passkey."
    "library_key_required" -> "Unlock this library from a trusted device or recovery kit first."
    "pairing_expired" -> "That one-time pairing expired. Create a new QR code."
    "pairing_missing" -> "That pairing is no longer available. Create a new QR code."
    "secure_setup_failed" -> "The QR, recovery code, or encrypted envelope did not validate. Nothing changed."
    "refresh_token_missing" -> "The identity provider did not grant background access. Check its native-app offline_access policy."
    "space_selection_required" -> "This account has multiple libraries. Space selection is required."
    "server_auth_insecure" -> "This server does not advertise the required secure sign-in profile."
    "identity_provider_unavailable", "server_discovery_failed", "dependency_unavailable" ->
        "Snippets Cloud sign-in is temporarily unavailable. Try again shortly."
    "scope_review_required" -> "The cloud account or library changed. Review it before resuming."
    else -> "Snippets Cloud couldn’t complete the request. Try again."
}

@SuppressLint("InlinedApi")
private fun copySensitiveText(context: Context, value: String) {
    val marker = UUID.randomUUID().toString()
    val clip = ClipData.newPlainText("Snippets recovery code", value)
    clip.description.extras = PersistableBundle().apply {
        putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
        putString("com.khm.snippets.clipboard.marker", marker)
    }
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(clip)
    Handler(Looper.getMainLooper()).postDelayed({
        val currentMarker = clipboard.primaryClipDescription?.extras
            ?.getString("com.khm.snippets.clipboard.marker")
        if (currentMarker == marker) clipboard.clearPrimaryClip()
    }, 120_000L)
    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.S_V2) {
        Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
    }
}

@SuppressLint("InlinedApi")
private fun copySensitive(context: Context, snippet: SnippetItem) {
    val clip = ClipData.newPlainText("Snippet", snippet.content)
    clip.description.extras = PersistableBundle().apply {
        putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
    }
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
        .setPrimaryClip(clip)
    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.S_V2) {
        Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
    }
}

private fun share(context: Context, value: String) {
    val intent = Intent(Intent.ACTION_SEND)
        .setType("text/plain")
        .putExtra(Intent.EXTRA_TEXT, value)
    context.startActivity(Intent.createChooser(intent, "Share snippet"))
}
