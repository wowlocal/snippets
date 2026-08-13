package com.khm.snippets.android

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/** Explicit Android text action; intentionally not an IME, Accessibility service or overlay. */
class ProcessTextActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.action != Intent.ACTION_PROCESS_TEXT) {
            finish()
            return
        }
        val repository = (application as SnippetsApplication).repository
        val selected = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString().orEmpty()
        val readOnly = intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false)
        setContent {
            SnippetsTheme {
                val scope = rememberCoroutineScope()
                var query by remember { mutableStateOf(selected) }
                var results by remember { mutableStateOf(repository.state.value.snippets) }
                Column(Modifier.fillMaxSize().padding(16.dp)) {
                    Text("Insert Snippet", style = MaterialTheme.typography.titleLarge)
                    OutlinedTextField(
                        query,
                        {
                            query = it
                            scope.launch { results = repository.search(it) }
                        },
                        Modifier.fillMaxWidth(),
                        label = { Text("Search") })
                    if (results.isEmpty()) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Text("No snippets")
                        }
                    } else {
                        LazyColumn {
                            items(results.filter(SnippetItem::isEnabled), key = SnippetItem::id) { snippet ->
                                Card(
                                    Modifier.fillMaxWidth().padding(top = 8.dp)
                                        .clickable { complete(snippet.content, readOnly) }) {
                                    Column(Modifier.padding(16.dp)) {
                                        Text(snippet.name.ifBlank { "Untitled Snippet" })
                                        Text(snippet.content, maxLines = 2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private fun complete(content: String, readOnly: Boolean) {
        if (readOnly) {
            (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                .setPrimaryClip(ClipData.newPlainText("Snippet", content))
            setResult(Activity.RESULT_CANCELED)
        } else {
            setResult(Activity.RESULT_OK, Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, content))
        }
        finish()
    }
}
