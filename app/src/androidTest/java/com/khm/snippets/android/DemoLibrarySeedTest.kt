package com.khm.snippets.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Explicit developer fixture for a hands-on emulator build. It is skipped during normal
 * instrumentation runs and never changes an existing snippet with the same keyword.
 */
@RunWith(AndroidJUnit4::class)
class DemoLibrarySeedTest {
    @Test
    fun seedDemoLibraryWhenExplicitlyRequested() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue(arguments.getString("snippetsSeedDemo") == "true")

        val application = InstrumentationRegistry.getInstrumentation()
            .targetContext.applicationContext as SnippetsApplication
        val repository = application.repository
        val existingKeywords = repository.state.value.snippets.mapTo(mutableSetOf()) { it.keyword }

        for (snippet in DEMO_SNIPPETS.filterNot { it.keyword in existingKeywords }) {
            repository.save(snippet)
        }

        val actualKeywords = repository.state.value.snippets.map { it.keyword }.toSet()
        assertEquals(true, actualKeywords.containsAll(DEMO_SNIPPETS.map { it.keyword }))
    }

    private companion object {
        val DEMO_SNIPPETS = listOf(
            demo(
                name = "Git commit message",
                keyword = "commit",
                content = "feat: add concise description",
                tags = listOf("git", "work"),
                isPinned = true,
            ),
            demo(
                name = "Email follow up",
                keyword = "followup",
                content = "Hi Alex, just following up on our conversation. Let me know what works for you.",
                tags = listOf("email", "work"),
            ),
            demo(
                name = "Daily standup",
                keyword = "standup",
                content = "Yesterday: finished sync testing\nToday: Android polish\nBlockers: none",
                tags = listOf("meeting", "team"),
            ),
            demo(
                name = "Shipping address",
                keyword = "address",
                content = "123 Market Street\nSan Francisco, CA 94105",
                tags = listOf("personal", "address"),
            ),
            demo(
                name = "Support reply",
                keyword = "thanks",
                content = "Thanks for reaching out. We are looking into this and will get back to you shortly.",
                tags = listOf("support", "email"),
            ),
            demo(
                name = "Recent snippets query",
                keyword = "recent",
                content = "SELECT id, name FROM snippets ORDER BY updated_at DESC",
                tags = listOf("sql", "development"),
            ),
            demo(
                name = "Personal signature",
                keyword = "signature",
                content = "Best regards,\nMichael\nProduct Team",
                tags = listOf("email", "personal"),
            ),
        )

        fun demo(
            name: String,
            keyword: String,
            content: String,
            tags: List<String>,
            isPinned: Boolean = false,
        ) = SnippetItem(
            id = UUID.randomUUID().toString(),
            name = name,
            keyword = keyword,
            content = content,
            tags = tags,
            isEnabled = true,
            isPinned = isPinned,
        )
    }
}
