package com.khm.snippets.core.settings

/** The platforms the Swift catalog describes. */
enum class SettingsPlatform { MAC_OS, IOS }

/** `SettingsDestination`: the settings screens of the Mac and iOS apps. */
enum class SettingsDestination(override val title: String) : SettingsScreen {
    GENERAL("General"),
    EXPANSION("Expansion"),
    CLIPBOARD_HISTORY("Clipboard History"),
    SYNC("Sync"),
    SECURE_SNIPPETS("Secure Snippets"),
    BACKUP("Backup"),
    INTEGRATIONS("Integrations"),
    DIAGNOSTICS("Diagnostics"),
    ABOUT("About"),
}

/** `SettingsRowID`. [swiftName] is the Swift case name. */
enum class SettingsRowId(val swiftName: String) {
    LAUNCH_AT_LOGIN("launchAtLogin"),
    QUIT_BEHAVIOR("quitBehavior"),
    GLOBAL_SHORTCUTS("globalShortcuts"),
    ACCESSIBILITY("accessibility"),
    MATCH_HIGHLIGHT("matchHighlight"),
    SUGGESTION_RANKING("suggestionRanking"),
    SELECTION_MEMORY("selectionMemory"),
    RESET_USAGE("resetUsage"),
    CLIPBOARD_HISTORY_ENABLED("clipboardHistoryEnabled"),
    CLEAR_CLIPBOARD_HISTORY("clearClipboardHistory"),
    CLIPBOARD_EXCLUDED_APPS("clipboardExcludedApps"),
    CLOUD_PROVIDER("cloudProvider"),
    CLOUD_ACCOUNT("cloudAccount"),
    SYNC_ENABLED("syncEnabled"),
    SYNC_STATUS("syncStatus"),
    SYNC_NOW("syncNow"),
    SYNC_RECOVERY("syncRecovery"),
    VAULT_STATUS("vaultStatus"),
    KEY_STORAGE("keyStorage"),
    VAULT_SETUP("vaultSetup"),
    LOCK_VAULT("lockVault"),
    RECOVERY_KEY("recoveryKey"),
    RESTORE_RECOVERY("restoreRecovery"),
    FORGET_VAULT("forgetVault"),
    IMPORT_LIBRARY("importLibrary"),
    EXPORT_SHARING("exportSharing"),
    ENCRYPTED_BACKUP("encryptedBackup"),
    CHROMIUM_APPS("chromiumApps"),
    COMMAND_LINE_TOOL("commandLineTool"),
    PERSISTENT_LOGS("persistentLogs"),
    EXPANSION_LOGGING("expansionLogging"),
    EXPORT_LOGS("exportLogs"),
    DELETE_LOGS("deleteLogs"),
    WRITE_HEALTH("writeHealth"),
    VERSION("version"),
    UPDATES("updates"),
    PROJECT_LINK("projectLink"),
}

/**
 * The catalogs of the Mac and iOS apps, word for word (`SettingsCatalog.allEntries` and
 * `navigationSections(for:)`).
 *
 * The iOS catalog is the starting point for Android, not its catalog: it names iCloud and
 * has no row for anything Android adds. The Android app builds its own [SettingsCatalog]
 * from its own rows.
 */
object SnippetsSettings {

    private val MAC_ONLY = setOf(SettingsPlatform.MAC_OS)
    private val ALL = setOf(SettingsPlatform.MAC_OS, SettingsPlatform.IOS)

    private class Row(
        val id: SettingsRowId,
        val title: String,
        val destination: SettingsDestination,
        val keywords: List<String>,
        val platforms: Set<SettingsPlatform>,
    )

    private val ROWS: List<Row> = listOf(
        Row(SettingsRowId.LAUNCH_AT_LOGIN, "Open Snippets at Login", SettingsDestination.GENERAL, listOf("start", "startup", "launch"), MAC_ONLY),
        Row(SettingsRowId.QUIT_BEHAVIOR, "Pressing Cmd+Q", SettingsDestination.GENERAL, listOf("quit", "close", "keep running", "ask"), MAC_ONLY),

        Row(SettingsRowId.GLOBAL_SHORTCUTS, "Global Shortcuts", SettingsDestination.EXPANSION, listOf("hotkey", "keyboard", "paste", "open"), MAC_ONLY),
        Row(SettingsRowId.ACCESSIBILITY, "Accessibility Permission", SettingsDestination.EXPANSION, listOf("system settings", "insertion", "typing"), MAC_ONLY),
        Row(SettingsRowId.MATCH_HIGHLIGHT, "Match Highlighting", SettingsDestination.EXPANSION, listOf("keyword", "suggestion", "color"), MAC_ONLY),
        Row(SettingsRowId.SUGGESTION_RANKING, "Suggestion Ranking", SettingsDestination.EXPANSION, listOf("frequency", "frecency", "usage"), MAC_ONLY),
        Row(SettingsRowId.SELECTION_MEMORY, "Remember Selections", SettingsDestination.EXPANSION, listOf("prefix", "suggestion", "choice"), MAC_ONLY),
        Row(SettingsRowId.RESET_USAGE, "Reset Usage Data", SettingsDestination.EXPANSION, listOf("ranking", "history", "memory"), MAC_ONLY),

        Row(
            SettingsRowId.CLIPBOARD_HISTORY_ENABLED, "Keep Clipboard History", SettingsDestination.CLIPBOARD_HISTORY,
            listOf("enable", "pause", "copied text", "links", "command shift v", "retention", "7 days", "encrypted"), MAC_ONLY,
        ),
        Row(SettingsRowId.CLEAR_CLIPBOARD_HISTORY, "Clear Clipboard History", SettingsDestination.CLIPBOARD_HISTORY, listOf("delete", "remove", "privacy", "copied text"), MAC_ONLY),
        Row(SettingsRowId.CLIPBOARD_EXCLUDED_APPS, "Excluded Apps", SettingsDestination.CLIPBOARD_HISTORY, listOf("ignore", "exclude", "applications", "clipboard"), MAC_ONLY),

        Row(
            SettingsRowId.CLOUD_PROVIDER, "Cloud Provider", SettingsDestination.SYNC,
            listOf("icloud", "snippets cloud", "backend", "git", "github", "gitlab", "gitea", "gitverse", "repository"), ALL,
        ),
        Row(SettingsRowId.CLOUD_ACCOUNT, "Cloud Account", SettingsDestination.SYNC, listOf("sign in", "sign out", "account", "create account", "account key"), ALL),
        Row(SettingsRowId.SYNC_ENABLED, "Sync This Library", SettingsDestination.SYNC, listOf("enable", "icloud", "cloud"), ALL),
        Row(SettingsRowId.SYNC_STATUS, "Sync Status", SettingsDestination.SYNC, listOf("last sync", "state", "health"), ALL),
        Row(SettingsRowId.SYNC_NOW, "Sync Now", SettingsDestination.SYNC, listOf("refresh", "upload", "download"), ALL),
        Row(SettingsRowId.SYNC_RECOVERY, "Sync Recovery", SettingsDestination.SYNC, listOf("review", "resume", "reset", "account"), ALL),

        Row(SettingsRowId.VAULT_STATUS, "Secure Snippets Status", SettingsDestination.SECURE_SNIPPETS, listOf("vault", "protected", "locked"), ALL),
        Row(SettingsRowId.KEY_STORAGE, "Key Storage", SettingsDestination.SECURE_SNIPPETS, listOf("keychain", "device", "icloud"), ALL),
        Row(SettingsRowId.VAULT_SETUP, "Set Up Secure Snippets", SettingsDestination.SECURE_SNIPPETS, listOf("vault", "create", "password"), ALL),
        Row(SettingsRowId.LOCK_VAULT, "Lock Now", SettingsDestination.SECURE_SNIPPETS, listOf("vault", "secure"), ALL),
        Row(SettingsRowId.RECOVERY_KEY, "Add Recovery Key", SettingsDestination.SECURE_SNIPPETS, listOf("backup", "offline", "vault"), ALL),
        Row(SettingsRowId.RESTORE_RECOVERY, "Restore with Recovery Key", SettingsDestination.SECURE_SNIPPETS, listOf("recover", "vault", "key"), ALL),
        Row(SettingsRowId.FORGET_VAULT, "Remove Secure Snippets from This Device", SettingsDestination.SECURE_SNIPPETS, listOf("forget", "delete local", "vault"), ALL),

        Row(SettingsRowId.IMPORT_LIBRARY, "Import Library", SettingsDestination.BACKUP, listOf("json", "restore", "file"), ALL),
        Row(SettingsRowId.EXPORT_SHARING, "Export for Sharing", SettingsDestination.BACKUP, listOf("json", "plain text", "file"), ALL),
        Row(SettingsRowId.ENCRYPTED_BACKUP, "Export Encrypted Backup", SettingsDestination.BACKUP, listOf("archive", "password", "restore"), ALL),

        Row(SettingsRowId.CHROMIUM_APPS, "Chromium Apps", SettingsDestination.INTEGRATIONS, listOf("browser", "chrome", "arc", "bundle identifier"), MAC_ONLY),
        Row(SettingsRowId.COMMAND_LINE_TOOL, "Command Line Tool", SettingsDestination.INTEGRATIONS, listOf("cli", "terminal", "install"), MAC_ONLY),

        Row(SettingsRowId.PERSISTENT_LOGS, "Persistent Logs", SettingsDestination.DIAGNOSTICS, listOf("diagnostics", "storage", "retention"), ALL),
        Row(SettingsRowId.EXPANSION_LOGGING, "Expansion Diagnostics", SettingsDestination.DIAGNOSTICS, listOf("typing", "paste", "events"), MAC_ONLY),
        Row(SettingsRowId.EXPORT_LOGS, "Export Logs", SettingsDestination.DIAGNOSTICS, listOf("diagnostics", "support", "jsonl"), ALL),
        Row(SettingsRowId.DELETE_LOGS, "Delete Logs", SettingsDestination.DIAGNOSTICS, listOf("clear", "privacy", "diagnostics"), ALL),
        Row(SettingsRowId.WRITE_HEALTH, "Write Health", SettingsDestination.DIAGNOSTICS, listOf("storage", "logging", "status"), MAC_ONLY),

        Row(SettingsRowId.VERSION, "Version and Build", SettingsDestination.ABOUT, listOf("about", "app", "release"), ALL),
        Row(SettingsRowId.UPDATES, "Software Updates", SettingsDestination.ABOUT, listOf("check now", "sparkle", "automatic"), MAC_ONLY),
        Row(SettingsRowId.PROJECT_LINK, "Project and License", SettingsDestination.ABOUT, listOf("github", "source", "mit"), ALL),
    )

    /** `navigationSections(for:)`. */
    fun navigationSections(platform: SettingsPlatform): List<SettingsNavigationSection<SettingsDestination>> = when (platform) {
        SettingsPlatform.MAC_OS -> listOf(
            SettingsNavigationSection("Application", listOf(SettingsDestination.GENERAL, SettingsDestination.EXPANSION, SettingsDestination.CLIPBOARD_HISTORY)),
            SettingsNavigationSection("Library", listOf(SettingsDestination.SYNC, SettingsDestination.SECURE_SNIPPETS, SettingsDestination.BACKUP)),
            SettingsNavigationSection("Advanced", listOf(SettingsDestination.INTEGRATIONS, SettingsDestination.DIAGNOSTICS, SettingsDestination.ABOUT)),
        )
        SettingsPlatform.IOS -> listOf(
            SettingsNavigationSection("Library", listOf(SettingsDestination.SYNC, SettingsDestination.SECURE_SNIPPETS, SettingsDestination.BACKUP)),
            SettingsNavigationSection("Support", listOf(SettingsDestination.DIAGNOSTICS, SettingsDestination.ABOUT)),
        )
    }

    /** `entries(for:)`, in catalog order. */
    fun entries(platform: SettingsPlatform): List<SettingsSearchEntry<SettingsRowId, SettingsDestination>> =
        ROWS.filter { platform in it.platforms }
            .map { SettingsSearchEntry(it.id, it.title, it.destination.title, it.destination, it.keywords) }

    /** The navigation and the search for one platform. */
    fun catalog(platform: SettingsPlatform): SettingsCatalog<SettingsRowId, SettingsDestination> =
        SettingsCatalog(navigationSections(platform), entries(platform))
}
