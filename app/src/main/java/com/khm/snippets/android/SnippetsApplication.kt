package com.khm.snippets.android

import android.app.Application

class SnippetsApplication : Application() {
    val repository: SnippetRepository by lazy { SnippetRepository(this) }
}
