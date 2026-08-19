import Foundation

/// The settings navigation model is deliberately UI-agnostic so macOS and iOS
/// present the same vocabulary without putting AppKit or UIKit in shared code.
nonisolated enum SettingsPlatform: Hashable, Sendable {
    case macOS
    case iOS
}

nonisolated enum SettingsDestination: String, CaseIterable, Hashable, Sendable {
    case general
    case expansion
    case sync
    case secureSnippets
    case backup
    case integrations
    case diagnostics
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .expansion: "Expansion"
        case .sync: "Sync"
        case .secureSnippets: "Secure Snippets"
        case .backup: "Backup"
        case .integrations: "Integrations"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .expansion: "text.cursor"
        case .sync: "arrow.triangle.2.circlepath"
        case .secureSnippets: "lock"
        case .backup: "externaldrive"
        case .integrations: "puzzlepiece.extension"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }
}

nonisolated enum SettingsRowID: String, CaseIterable, Hashable, Sendable {
    case launchAtLogin
    case quitBehavior
    case globalShortcuts
    case accessibility
    case matchHighlight
    case suggestionRanking
    case selectionMemory
    case resetUsage
    case cloudProvider
    case cloudAccount
    case syncEnabled
    case syncStatus
    case syncNow
    case syncRecovery
    case vaultStatus
    case keyStorage
    case vaultSetup
    case lockVault
    case recoveryKey
    case restoreRecovery
    case forgetVault
    case importLibrary
    case exportSharing
    case encryptedBackup
    case chromiumApps
    case commandLineTool
    case persistentLogs
    case expansionLogging
    case exportLogs
    case deleteLogs
    case writeHealth
    case version
    case updates
    case projectLink
}

nonisolated struct SettingsNavigationSection: Equatable, Sendable {
    let title: String
    let destinations: [SettingsDestination]
}

nonisolated struct SettingsSearchEntry: Equatable, Sendable {
    let rowID: SettingsRowID
    let title: String
    let detail: String?
    let destination: SettingsDestination

    fileprivate let keywords: [String]
    fileprivate let platforms: Set<SettingsPlatform>
}

nonisolated enum SettingsCatalog {
    static func navigationSections(for platform: SettingsPlatform) -> [SettingsNavigationSection] {
        switch platform {
        case .macOS:
            [
                SettingsNavigationSection(
                    title: "Application",
                    destinations: [.general, .expansion]
                ),
                SettingsNavigationSection(
                    title: "Library",
                    destinations: [.sync, .secureSnippets, .backup]
                ),
                SettingsNavigationSection(
                    title: "Advanced",
                    destinations: [.integrations, .diagnostics, .about]
                ),
            ]
        case .iOS:
            [
                SettingsNavigationSection(
                    title: "Library",
                    destinations: [.sync, .secureSnippets, .backup]
                ),
                SettingsNavigationSection(
                    title: "Support",
                    destinations: [.diagnostics, .about]
                ),
            ]
        }
    }

    static func entries(for platform: SettingsPlatform) -> [SettingsSearchEntry] {
        allEntries.filter { $0.platforms.contains(platform) }
    }

    /// Searches a fixed product vocabulary. No user content or runtime state is
    /// accepted here, which keeps Settings search safe for secure libraries.
    static func search(_ query: String, platform: SettingsPlatform) -> [SettingsSearchEntry] {
        let tokens = normalized(query)
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return [] }

        return entries(for: platform)
            .compactMap { entry -> (entry: SettingsSearchEntry, score: Int)? in
                let title = normalized(entry.title)
                let destination = normalized(entry.destination.title)
                let keywords = entry.keywords.map(normalized)
                let searchable = ([title, destination] + keywords).joined(separator: " ")
                guard tokens.allSatisfy(searchable.contains) else { return nil }

                var score = 0
                for token in tokens {
                    if title == token { score += 100 }
                    else if title.hasPrefix(token) { score += 60 }
                    else if title.contains(token) { score += 35 }
                    else if destination.hasPrefix(token) { score += 20 }
                    else if keywords.contains(where: { $0.hasPrefix(token) }) { score += 12 }
                    else { score += 1 }
                }
                return (entry, score)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.entry.destination != $1.entry.destination {
                    return $0.entry.destination.title < $1.entry.destination.title
                }
                return $0.entry.title < $1.entry.title
            }
            .map(\.entry)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static let macOSOnly: Set<SettingsPlatform> = [.macOS]
    private static let iOSOnly: Set<SettingsPlatform> = [.iOS]
    private static let allPlatforms: Set<SettingsPlatform> = [.macOS, .iOS]

    private static let allEntries: [SettingsSearchEntry] = [
        entry(.launchAtLogin, "Open Snippets at Login", .general, ["start", "startup", "launch"], macOSOnly),
        entry(.quitBehavior, "Pressing Cmd+Q", .general, ["quit", "close", "keep running", "ask"], macOSOnly),

        entry(.globalShortcuts, "Global Shortcuts", .expansion, ["hotkey", "keyboard", "paste", "open"], macOSOnly),
        entry(.accessibility, "Accessibility Permission", .expansion, ["system settings", "insertion", "typing"], macOSOnly),
        entry(.matchHighlight, "Match Highlighting", .expansion, ["keyword", "suggestion", "color"], macOSOnly),
        entry(.suggestionRanking, "Suggestion Ranking", .expansion, ["frequency", "frecency", "usage"], macOSOnly),
        entry(.selectionMemory, "Remember Selections", .expansion, ["prefix", "suggestion", "choice"], macOSOnly),
        entry(.resetUsage, "Reset Usage Data", .expansion, ["ranking", "history", "memory"], macOSOnly),

        entry(.cloudProvider, "Cloud Provider", .sync, ["icloud", "snippets cloud", "backend"], allPlatforms),
        entry(.cloudAccount, "Cloud Account", .sync, ["sign in", "sign out", "account"], allPlatforms),
        entry(.syncEnabled, "Sync This Library", .sync, ["enable", "icloud", "cloud"], allPlatforms),
        entry(.syncStatus, "Sync Status", .sync, ["last sync", "state", "health"], allPlatforms),
        entry(.syncNow, "Sync Now", .sync, ["refresh", "upload", "download"], allPlatforms),
        entry(.syncRecovery, "Sync Recovery", .sync, ["review", "resume", "reset", "account"], allPlatforms),

        entry(.vaultStatus, "Secure Snippets Status", .secureSnippets, ["vault", "protected", "locked"], allPlatforms),
        entry(.keyStorage, "Key Storage", .secureSnippets, ["keychain", "device", "icloud"], allPlatforms),
        entry(.vaultSetup, "Set Up Secure Snippets", .secureSnippets, ["vault", "create", "password"], allPlatforms),
        entry(.lockVault, "Lock Now", .secureSnippets, ["vault", "secure"], allPlatforms),
        entry(.recoveryKey, "Add Recovery Key", .secureSnippets, ["backup", "offline", "vault"], allPlatforms),
        entry(.restoreRecovery, "Restore with Recovery Key", .secureSnippets, ["recover", "vault", "key"], allPlatforms),
        entry(.forgetVault, "Remove Secure Snippets from This Device", .secureSnippets, ["forget", "delete local", "vault"], allPlatforms),

        entry(.importLibrary, "Import Library", .backup, ["json", "restore", "file"], allPlatforms),
        entry(.exportSharing, "Export for Sharing", .backup, ["json", "plain text", "file"], allPlatforms),
        entry(.encryptedBackup, "Export Encrypted Backup", .backup, ["archive", "password", "restore"], allPlatforms),

        entry(.chromiumApps, "Chromium Apps", .integrations, ["browser", "chrome", "arc", "bundle identifier"], macOSOnly),
        entry(.commandLineTool, "Command Line Tool", .integrations, ["cli", "terminal", "install"], macOSOnly),

        entry(.persistentLogs, "Persistent Logs", .diagnostics, ["diagnostics", "storage", "retention"], allPlatforms),
        entry(.expansionLogging, "Expansion Diagnostics", .diagnostics, ["typing", "paste", "events"], macOSOnly),
        entry(.exportLogs, "Export Logs", .diagnostics, ["diagnostics", "support", "jsonl"], allPlatforms),
        entry(.deleteLogs, "Delete Logs", .diagnostics, ["clear", "privacy", "diagnostics"], allPlatforms),
        entry(.writeHealth, "Write Health", .diagnostics, ["storage", "logging", "status"], macOSOnly),

        entry(.version, "Version and Build", .about, ["about", "app", "release"], allPlatforms),
        entry(.updates, "Software Updates", .about, ["check now", "sparkle", "automatic"], macOSOnly),
        entry(.projectLink, "Project and License", .about, ["github", "source", "mit"], allPlatforms),
    ]

    private static func entry(
        _ rowID: SettingsRowID,
        _ title: String,
        _ destination: SettingsDestination,
        _ keywords: [String],
        _ platforms: Set<SettingsPlatform>
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            rowID: rowID,
            title: title,
            detail: destination.title,
            destination: destination,
            keywords: keywords,
            platforms: platforms
        )
    }
}
