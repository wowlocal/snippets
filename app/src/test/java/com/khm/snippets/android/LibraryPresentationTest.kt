package com.khm.snippets.android

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class LibraryPresentationTest {
    @Test
    fun tagIdentityIsCaseAndDiacriticInsensitiveInEveryDeviceLocale() {
        val previousLocale = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertEquals("creme", tagFilterKey("Crème"))
            assertEquals(tagFilterKey("EMAIL"), tagFilterKey("email"))
            assertEquals("strasse", tagFilterKey("Straße"))
            assertEquals("strasse", tagFilterKey("STRASSE"))
            assertEquals("σ", tagFilterKey("Σ"))
            assertEquals("σ", tagFilterKey("ς"))
        } finally {
            Locale.setDefault(previousLocale)
        }
    }

    @Test
    fun normalizedTagsMatchTheAppleWhitespaceAndDeduplicationContract() {
        assertEquals(
            listOf("Work project", "Email"),
            normalizedTags(listOf("  Work\n project  ", "work project", "", "Email")),
        )
    }

    @Test
    fun tagUsageCombinesCanonicalTagsAndPreservesFirstSpelling() {
        val snippets = listOf(
            snippet("1", tags = listOf("Work", "Crème")),
            snippet("2", tags = listOf("work", "CREME", "Email")),
        )

        assertEquals(
            listOf(
                TagUsage(tag = "Crème", key = "creme", count = 2),
                TagUsage(tag = "Email", key = "email", count = 1),
                TagUsage(tag = "Work", key = "work", count = 2),
            ),
            tagUsage(snippets),
        )
    }

    @Test
    fun libraryFilterRequiresEverySelectedTagAndCombinesWithSearch() {
        val workEmail = snippet(
            "1",
            name = "Email follow up",
            content = "Reply tomorrow",
            tags = listOf("email", "work"),
        )
        val personalEmail = snippet(
            "2",
            name = "Personal signature",
            content = "Best regards",
            tags = listOf("email", "personal"),
        )
        val snippets = listOf(workEmail, personalEmail)

        assertEquals(
            listOf(workEmail),
            filterLibrary(snippets, query = "reply", activeTagKeys = setOf("email", "work")),
        )
        assertEquals(
            emptyList<SnippetItem>(),
            filterLibrary(snippets, query = "signature", activeTagKeys = setOf("email", "work")),
        )
    }

    @Test
    fun colorSlotUsesTheSharedAppleClientFnvMapping() {
        assertEquals(7, tagColorIndex("email"))
        assertEquals(7, tagColorIndex("EMAIL"))
        assertEquals(8, tagColorIndex("work"))
        assertEquals(4, tagColorIndex("support"))
    }

    private fun snippet(
        id: String,
        name: String = "Snippet $id",
        content: String = "Content $id",
        tags: List<String> = emptyList(),
    ) = SnippetItem(
        id = id,
        name = name,
        keyword = "keyword$id",
        content = content,
        tags = tags,
        isEnabled = true,
        isPinned = false,
    )
}
