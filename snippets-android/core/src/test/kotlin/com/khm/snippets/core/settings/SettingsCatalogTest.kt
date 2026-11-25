package com.khm.snippets.core.settings

import com.khm.snippets.core.search.UtilitiesFixture
import com.khm.snippets.core.text.SeededRandom
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** `Tests/Core/SettingsCatalogTests.swift`, and the Swift catalog and its search results as emitted from Swift. */
class SettingsCatalogTest {

    private val mac = SnippetsSettings.catalog(SettingsPlatform.MAC_OS)
    private val ios = SnippetsSettings.catalog(SettingsPlatform.IOS)

    @Test
    fun macNavigationMatchesProductInformationArchitecture() {
        assertEquals(
            listOf(
                SettingsDestination.GENERAL, SettingsDestination.EXPANSION, SettingsDestination.CLIPBOARD_HISTORY,
                SettingsDestination.SYNC, SettingsDestination.SECURE_SNIPPETS, SettingsDestination.BACKUP,
                SettingsDestination.INTEGRATIONS, SettingsDestination.DIAGNOSTICS, SettingsDestination.ABOUT,
            ),
            mac.navigationSections.flatMap { it.destinations },
        )
    }

    @Test
    fun iosNavigationContainsOnlyMobileDestinations() {
        assertEquals(
            listOf(
                SettingsDestination.SYNC, SettingsDestination.SECURE_SNIPPETS, SettingsDestination.BACKUP,
                SettingsDestination.DIAGNOSTICS, SettingsDestination.ABOUT,
            ),
            ios.navigationSections.flatMap { it.destinations },
        )
        assertEquals(listOf("Library", "Support"), ios.navigationSections.map { it.title })
    }

    @Test
    fun searchRoutesIndividualRowsToTheirDestination() {
        val results = mac.search("encrypted backup")
        assertEquals(SettingsRowId.ENCRYPTED_BACKUP, results.first().rowId)
        assertEquals(SettingsDestination.BACKUP, results.first().destination)
    }

    @Test
    fun searchSupportsKeywordsAndMultipleTokens() {
        val result = mac.search("browser bundle").first()
        assertEquals(SettingsRowId.CHROMIUM_APPS, result.rowId)
        assertEquals(SettingsDestination.INTEGRATIONS, result.destination)
    }

    @Test
    fun iosSearchDoesNotExposeMacOnlyRows() {
        assertTrue(ios.search("launch startup").isEmpty())
        assertTrue(ios.search("command line").isEmpty())
        assertTrue(ios.search("clipboard").isEmpty())
    }

    @Test
    fun clipboardHistorySearchFindsCapturePrivacyAndClearControlsOnMac() {
        assertEquals(SettingsRowId.CLIPBOARD_HISTORY_ENABLED, mac.search("command shift v").first().rowId)
        assertEquals(SettingsRowId.CLEAR_CLIPBOARD_HISTORY, mac.search("clear clipboard").first().rowId)
        assertEquals(SettingsRowId.CLIPBOARD_EXCLUDED_APPS, mac.search("clipboard exclude").first().rowId)
        assertTrue(mac.search("clipboard").all { it.destination == SettingsDestination.CLIPBOARD_HISTORY })
    }

    @Test
    fun catalogContainsOnlyStaticProductCopy() {
        val indexedText = mac.entries.flatMap { listOf(it.title, it.detail ?: "") }.joinToString(" ").lowercase(Locale.ROOT)
        assertFalse(indexedText.contains("snippet body"))
        assertFalse(indexedText.contains("ciphertext"))
        assertFalse(indexedText.contains("record uuid"))
    }

    private fun platform(name: String) = if (name == "macOS") SettingsPlatform.MAC_OS else SettingsPlatform.IOS

    private val swiftDestination = mapOf(
        "general" to SettingsDestination.GENERAL, "expansion" to SettingsDestination.EXPANSION,
        "clipboardHistory" to SettingsDestination.CLIPBOARD_HISTORY, "sync" to SettingsDestination.SYNC,
        "secureSnippets" to SettingsDestination.SECURE_SNIPPETS, "backup" to SettingsDestination.BACKUP,
        "integrations" to SettingsDestination.INTEGRATIONS, "diagnostics" to SettingsDestination.DIAGNOSTICS,
        "about" to SettingsDestination.ABOUT,
    )

    /** Every row and section of both Swift catalogs, in order: ids, titles, details and destinations. */
    @Test
    fun theCatalogsAreTheSwiftCatalogs() {
        val rows = UtilitiesFixture.rows("swift-settings-catalog.tsv")
        for (name in listOf("macOS", "iOS")) {
            val wantedEntries = rows.filter { it[0] == name && it[1] != "#section" }
            val wantedSections = rows.filter { it[0] == name && it[1] == "#section" }
            assertEquals(
                wantedEntries.map { listOf(it[2], it[3], it[1], swiftDestination.getValue(it[4])) },
                SnippetsSettings.entries(platform(name)).map { listOf(it.title, it.detail, it.rowId.swiftName, it.destination) },
                name,
            )
            assertEquals(
                wantedSections.map { it[2] to it[3].split(',').map(swiftDestination::getValue) },
                SnippetsSettings.navigationSections(platform(name)).map { it.title to it.destinations },
                name,
            )
        }
        assertEquals(37, mac.entries.size)
        assertEquals(21, ios.entries.size)
        assertEquals(SettingsRowId.entries.map { it.swiftName }, mac.entries.map { it.rowId.swiftName })
        assertEquals(swiftDestination.values.toList(), SettingsDestination.entries.toList())
    }

    /** 141 queries on each platform, with the rows Swift returns in Swift's order (emitted under en_US). */
    @Test
    fun searchResultsAndOrderMatchSwift() {
        val rows = UtilitiesFixture.rows("swift-settings.tsv")
        assertEquals(282, rows.size)
        for (row in rows) {
            val query = UtilitiesFixture.text(row[1])
            val wanted = if (row[2] == "-") emptyList() else row[2].split(',')
            val catalog = if (platform(row[0]) == SettingsPlatform.MAC_OS) mac else ios
            assertEquals(wanted, catalog.search(query).map { it.rowId.swiftName }, "${row[0]} ${UtilitiesFixture.scalars(query)}")
        }
    }

    /** The mechanism with rows of the app's own: any row and screen types work, and nothing is assumed about the Swift ids. */
    @Test
    fun anAppSuppliesItsOwnCatalog() {
        data class Screen(override val title: String) : SettingsScreen
        val textAction = Screen("Text Action")
        val git = Screen("Git Sync")
        val catalog = SettingsCatalog(
            listOf(SettingsNavigationSection("Android", listOf(textAction, git))),
            listOf(
                SettingsSearchEntry("process-text", "Show in Text Selection Menu", textAction.title, textAction, listOf("process text", "expand")),
                SettingsSearchEntry("git-token", "Access Token", git.title, git, listOf("github", "password", "https")),
                SettingsSearchEntry("git-ssh", "SSH Key", git.title, git, listOf("github", "ed25519")),
                SettingsSearchEntry("git", "Git Sync", null, git, emptyList()),
            ),
        )
        // The title match leads; the two rows found through their screen tie and go by title.
        assertEquals(listOf("git", "git-token", "git-ssh"), catalog.search("git").map { it.rowId })
        assertEquals(listOf("git-ssh"), catalog.search("GITHUB  ssh").map { it.rowId })
        assertEquals(listOf("process-text"), catalog.search("séléction").map { it.rowId })
        assertEquals(emptyList(), catalog.search(" \t\n"))
        assertEquals(emptyList(), catalog.search("git nothing"))
        assertEquals(4, catalog.entries.size)
    }

    /** Whatever is typed: no exception, only rows of the catalog, none twice, and every token found in each result. */
    @Test
    fun arbitraryQueriesNeverThrow() {
        val pieces = listOf("sync", "KEY", " ", "\t", "é", "e\u0301", "ß", "\u00A0", "\r\n", "👩🏽\u200D💻", "\u0000", "\uDC00", "now", "v", "\u3000", "İ")
        val random = SeededRandom(0x5E77)
        repeat(3_000) {
            val query = buildString { repeat(random.int(7)) { append(random.pick(pieces)) } }
            val results = mac.search(query)
            assertEquals(results.size, results.map { it.rowId }.distinct().size)
            assertTrue(mac.entries.containsAll(results))
            assertTrue(ios.search(query).all { it in results })
        }
    }
}
