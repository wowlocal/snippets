import CryptoKit
import Foundation

// Compiled into the app, snippets-cli and CorePackage. Foundation and CryptoKit only.

/// The `snippets-cli` skill for AI coding agents (Claude Code, Codex and others that
/// read `SKILL.md`). Mirrored on Linux by `snippets-linux/src/agent_skill.rs`.
///
/// Three pieces, deliberately kept apart:
///
/// - **The guide** is built into the binary (`AgentSkillText.guide`, generated from
///   `agent-skill/guide.md`), so it always describes the commands this version has.
///   `snippets-cli skill` prints it.
/// - **The stub** is what `install` writes into a skills folder. It only tells the agent
///   to run `snippets-cli skill`, plus the one rule that must hold even if it never
///   does. Install rewrites it freely: nobody edits it by hand.
/// - **The guide and the rules** are the user's to edit: `guide.md` and `rules.md` (the
///   do/don't lines and the skill's description) in `~/.config/snippets/agent-skill/`.
///   Until they exist, the built-in defaults apply. Read-only originals of the defaults
///   are kept in the support folder's `AgentSkill/` to compare against, and Reset puts
///   them back (keeping the previous copy as `.bak`). An unedited copy follows updates;
///   an edited one is never overwritten, only reported as `outdated` once the defaults
///   change under it, because a stale guide can name commands this CLI no longer has.
///
/// A stub goes to the built-in places (`Target`) or to folders the user named. The
/// owned stubs on disk are the record of which built-in places the user chose; only
/// custom folders are remembered, in the hidden `.state.json` beside the guide, so
/// status, refresh and uninstall can find them again.
///
/// The rules are advice to an agent, not a security boundary. Secure reveals stay
/// gated by the app's own approval and authentication.
///
/// The editable files live in `~/.config/snippets/` rather than the support directory,
/// whose root `SnippetStore` watches (the read-only originals sit in a subfolder that
/// `createAllDirectories` makes before the watcher starts). On the Mac that path ignores
/// `XDG_CONFIG_HOME`: the app never sees the shell's variables, and the CLI and Settings
/// must edit the same files.
nonisolated enum AgentSkill {

    static let skillName = "snippets-cli"
    static let stubMarker = "snippets-cli-stub:"
    /// Agents truncate or reject longer descriptions.
    static let maximumDescriptionLength = 1024

    /// A built-in place an agent looks for skills.
    enum Target: String, CaseIterable, Sendable {
        case claude, agents, codex

        var displayName: String {
            switch self {
            case .claude: "Claude Code"
            case .agents: "Codex and other agents"
            case .codex: "Codex (older folder)"
            }
        }
    }

    /// Where a stub can go: a built-in target or a skills folder the user chose.
    enum Place: Hashable, Sendable {
        case target(Target)
        /// An absolute skills folder; the stub goes in `snippets-cli/SKILL.md` inside it.
        case folder(URL)

        var displayName: String {
            switch self {
            case .target(let target): target.displayName
            case .folder: "Custom folder"
            }
        }
    }

    /// The parts of the process environment this type reads, so tests never touch
    /// the real home directory.
    struct Environment: Sendable {
        var home: URL
        var variables: [String: String]
        /// Where the read-only originals go. Nil means inside `home`, as tests want.
        var originalsFolder: URL?

        /// `$HOME` when set, as for any command-line tool; the account's home otherwise.
        static var current: Environment {
            let variables = ProcessInfo.processInfo.environment
            let home = variables["HOME"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            return Environment(
                home: home, variables: variables,
                originalsFolder: SnippetStorageLocations.agentSkillOriginalsFolderURL)
        }

        func directory(_ variable: String, default relativePath: String) -> URL {
            if let value = variables[variable], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return home.appendingPathComponent(relativePath, isDirectory: true)
        }
    }

    enum Outcome: String, Sendable {
        /// Created or replaced with the current stub.
        case wrote
        /// Already the current stub.
        case unchanged
        /// A `SKILL.md` that `install` did not write. Never touched.
        case skipped
        /// The custom folder no longer exists. Never recreated.
        case missing
        /// Uninstalled.
        case removed
        /// Nothing to uninstall there.
        case absent
    }

    struct Change: Equatable, Sendable {
        var place: Place
        var url: URL
        var outcome: Outcome
    }

    enum PlaceState: String, Sendable {
        case installed, notInstalled, foreign, missing
    }

    struct PlaceStatus: Equatable, Sendable {
        var place: Place
        var skillsFolder: URL
        var stubURL: URL
        /// For a built-in target: whether that agent's folder exists here.
        var detected: Bool
        var state: PlaceState
    }

    /// One of the two editable files.
    enum SkillFile: String, CaseIterable, Sendable {
        case guide, rules

        var fileName: String { "\(rawValue).md" }

        var defaultText: String {
            switch self {
            case .guide: AgentSkillText.guide
            case .rules: AgentSkillText.defaultRules
            }
        }
    }

    enum FileState: String, Sendable {
        /// No copy yet, or the copy matches the current defaults.
        case `default`
        /// The user changed it; the defaults it came from are still current.
        case edited
        /// The user changed it, and an update changed the defaults since.
        case outdated
    }

    struct Files: Equatable, Sendable {
        var folder: URL
        var originalsFolder: URL
        var guide: FileState
        var rules: FileState

        var areDefaults: Bool { guide == .default && rules == .default }
    }

    struct Status: Equatable, Sendable {
        var files: Files
        /// Every built-in target, then every remembered folder.
        var places: [PlaceStatus]
    }

    struct Rules: Equatable, Sendable {
        var description: String
        var body: String
        /// False when the defaults apply.
        var isCustom: Bool
    }

    enum FolderError: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case looksLikeProject(String)

        var description: String {
            switch self {
            case .notFound(let path):
                "\(path) does not exist."
            case .looksLikeProject(let path):
                "\(path) looks like a project folder. Use \(path)/.claude/skills or \(path)/.agents/skills."
            }
        }
    }

    // MARK: - Locations

    static func skillsFolder(for place: Place, in environment: Environment) -> URL {
        switch place {
        case .target(.claude):
            environment.directory("CLAUDE_CONFIG_DIR", default: ".claude")
                .appendingPathComponent("skills", isDirectory: true)
        case .target(.agents):
            environment.home.appendingPathComponent(".agents/skills", isDirectory: true)
        case .target(.codex):
            environment.directory("CODEX_HOME", default: ".codex")
                .appendingPathComponent("skills", isDirectory: true)
        case .folder(let url):
            url
        }
    }

    /// A short name for a custom skills folder in Settings: the project for
    /// `app/.claude/skills`, otherwise the folder's own name.
    static func folderTitle(_ url: URL) -> String {
        let parts = url.pathComponents
        if parts.count >= 3, parts[parts.count - 1] == "skills",
           [".claude", ".agents", ".codex"].contains(parts[parts.count - 2]) {
            return parts[parts.count - 3]
        }
        return url.lastPathComponent
    }

    /// The one way to make a folder place, so equal paths make equal places.
    static func folder(_ path: String) -> Place {
        .folder(URL(fileURLWithPath: normalizedPath(path), isDirectory: true))
    }

    /// Removes `.` and `..` without touching the disk. Not `standardizedFileURL`: that
    /// strips `/private` only from paths that exist, so a folder saved while it existed
    /// would no longer match itself once deleted.
    static func normalizedPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolves symlinks through the deepest part of the path that exists, then appends
    /// the rest, so a vanished folder still compares equal to how it was saved.
    private static func canonicalPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: normalizedPath(path))
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let resolved = existing.resolvingSymlinksInPath().path
        return normalizedPath(([resolved] + rest).joined(separator: "/"))
    }

    static func stubURL(for place: Place, in environment: Environment) -> URL {
        skillsFolder(for: place, in: environment)
            .appendingPathComponent(skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
    }

    static func configFolder(in environment: Environment) -> URL {
        environment.home.appendingPathComponent(".config/snippets", isDirectory: true)
    }

    /// The folder the user edits: `guide.md` and `rules.md`.
    static func filesFolder(in environment: Environment) -> URL {
        configFolder(in: environment).appendingPathComponent("agent-skill", isDirectory: true)
    }

    static func fileURL(_ file: SkillFile, in environment: Environment) -> URL {
        filesFolder(in: environment).appendingPathComponent(file.fileName, isDirectory: false)
    }

    static func rulesURL(in environment: Environment) -> URL { fileURL(.rules, in: environment) }

    static func originalsFolder(in environment: Environment) -> URL {
        environment.originalsFolder
            ?? environment.home.appendingPathComponent(
                "Library/Application Support/SnippetsClone/AgentSkill", isDirectory: true)
    }

    /// Hidden: remembered folders and which defaults each editable file came from.
    static func stateURL(in environment: Environment) -> URL {
        filesFolder(in: environment).appendingPathComponent(".state.json", isDirectory: false)
    }

    /// The root folder of a built-in target's agent: whether it exists says whether
    /// that agent is set up here.
    private static func agentHome(for target: Target, in environment: Environment) -> URL {
        skillsFolder(for: .target(target), in: environment).deletingLastPathComponent()
    }

    /// Claude Code when it is set up on this computer, and always `~/.agents/skills`,
    /// which Codex and other agents read. Not `~/.codex/skills` as well: an agent
    /// reading both would list the skill twice.
    static func defaultTargets(in environment: Environment) -> [Target] {
        isDirectory(agentHome(for: .claude, in: environment)) ? [.claude, .agents] : [.agents]
    }

    // MARK: - Custom folders

    /// Turns what the user typed or picked into a place. Relative paths resolve against
    /// `currentDirectory`; symlinks are kept as typed.
    ///
    /// | Input ends in                         | Means                         |
    /// |---------------------------------------|-------------------------------|
    /// | `snippets-cli`                        | its parent (the skill folder) |
    /// | `.claude`, `.agents`, `.codex`        | that folder's `skills`        |
    /// | a folder holding `.claude`/`.agents`  | refused: a project root       |
    /// | anything else                         | the skills folder itself      |
    ///
    /// The folder must exist, except that a final `skills` may be created later. A
    /// result that is a built-in target's folder becomes that target. To forget a
    /// folder (`mustExist: false`) only the path is normalised: it may be long gone.
    static func resolveFolder(
        _ input: String, currentDirectory: URL, in environment: Environment,
        mustExist: Bool = true
    ) throws -> Place {
        let expanded = input.hasPrefix("~/")
            ? environment.home.path + input.dropFirst(1)
            : (input == "~" ? environment.home.path : input)
        var url = URL(fileURLWithPath: normalizedPath(expanded.hasPrefix("/")
            ? expanded
            : currentDirectory.path + "/" + expanded), isDirectory: true)
        if url.lastPathComponent == skillName { url.deleteLastPathComponent() }
        if [".claude", ".agents", ".codex"].contains(url.lastPathComponent) {
            url.appendPathComponent("skills", isDirectory: true)
        }
        // A built-in folder is that target, even before install creates it.
        for target in Target.allCases where sameFolder(
            skillsFolder(for: .target(target), in: environment), url) {
            return .target(target)
        }
        guard mustExist else { return folder(url.path) }
        if url.lastPathComponent != "skills", isDirectory(url),
                  isDirectory(url.appendingPathComponent(".claude"))
                    || isDirectory(url.appendingPathComponent(".agents")) {
            throw FolderError.looksLikeProject(url.path)
        }
        guard isDirectory(url)
            || (url.lastPathComponent == "skills" && isDirectory(url.deletingLastPathComponent()))
        else { throw FolderError.notFound(url.path) }
        return folder(url.path)
    }

    private struct StateFile: Codable {
        var version = 1
        var folders: [String] = []
        /// Per editable file, the SHA-256 of the defaults it was copied from.
        var defaults: [String: String] = [:]
    }

    private static func readState(in environment: Environment) -> StateFile {
        guard let data = try? Data(contentsOf: stateURL(in: environment)),
              let state = try? JSONDecoder().decode(StateFile.self, from: data)
        else { return StateFile() }
        return state
    }

    private static func writeState(_ state: StateFile, in environment: Environment) throws {
        let url = stateURL(in: environment)
        let fileManager = FileManager.default
        if state.folders.isEmpty && state.defaults.isEmpty {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    static func rememberedFolders(in environment: Environment) -> [URL] {
        readState(in: environment).folders.filter { $0.hasPrefix("/") }.compactMap {
            if case .folder(let url) = folder($0) { url } else { nil }
        }
    }

    private static func saveFolders(_ folders: [URL], in environment: Environment) throws {
        var state = readState(in: environment)
        state.folders = folders.map(\.path)
        try writeState(state, in: environment)
    }

    /// Same folder by path, or once symlinks in the existing part are resolved.
    private static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        normalizedPath(a.path) == normalizedPath(b.path) || canonicalPath(a.path) == canonicalPath(b.path)
    }

    private static func remember(_ folder: URL, in environment: Environment) throws {
        var folders = rememberedFolders(in: environment)
        guard !folders.contains(where: { sameFolder($0, folder) }) else { return }
        folders.append(folder)
        try saveFolders(folders, in: environment)
    }

    private static func forget(_ folder: URL, in environment: Environment) throws {
        let folders = rememberedFolders(in: environment)
        let kept = folders.filter { !sameFolder($0, folder) }
        if kept.count != folders.count { try saveFolders(kept, in: environment) }
    }

    // MARK: - Status

    static func status(in environment: Environment) throws -> Status {
        let places = Target.allCases.map(Place.target)
            + rememberedFolders(in: environment).map(Place.folder)
        return Status(
            files: try syncFiles(in: environment),
            places: places.map { placeStatus($0, in: environment) })
    }

    static func placeStatus(_ place: Place, in environment: Environment) -> PlaceStatus {
        let folder = skillsFolder(for: place, in: environment)
        let stub = stubURL(for: place, in: environment)
        let detected: Bool
        if case .target(let target) = place {
            detected = target == .agents || isDirectory(agentHome(for: target, in: environment))
        } else {
            detected = true
        }
        let state: PlaceState
        if case .folder = place, !canHold(folder) {
            state = .missing
        } else if let text = try? String(contentsOf: stub, encoding: .utf8) {
            state = isStub(text) ? .installed : .foreign
        } else {
            state = FileManager.default.fileExists(atPath: stub.path) ? .foreign : .notInstalled
        }
        return PlaceStatus(
            place: place, skillsFolder: folder, stubURL: stub, detected: detected, state: state)
    }

    /// What a plain `install` rewrites: every built-in target holding our stub and every
    /// remembered folder (a vanished one is reported, not recreated). Only when the user
    /// has chosen nothing yet does it fall back to the default targets.
    static func refreshPlaces(in environment: Environment) throws -> [Place] {
        let chosen = try status(in: environment).places.filter {
            if case .folder = $0.place { return true }
            return $0.state == .installed
        }.map(\.place)
        return chosen.isEmpty ? defaultTargets(in: environment).map(Place.target) : chosen
    }

    /// Places holding our stub, without falling back to defaults.
    static func installedPlaces(in environment: Environment) throws -> [Place] {
        try status(in: environment).places.filter { $0.state == .installed }.map(\.place)
    }

    // MARK: - Rules

    static var defaultRules: Rules {
        let parsed = parseRules(AgentSkillText.defaultRules)
        return Rules(description: parsed.description ?? "", body: parsed.body, isCustom: false)
    }

    static func currentRules(in environment: Environment) throws -> Rules {
        guard let text = try editableText(.rules, in: environment),
              text != SkillFile.rules.defaultText
        else { return defaultRules }
        let parsed = parseRules(text)
        let description = parsed.description.map(sanitizedDescription) ?? ""
        return Rules(
            description: description.isEmpty ? defaultRules.description : description,
            body: parsed.body,
            isCustom: true)
    }

    /// Splits an optional `---` front matter holding `description:` from the body.
    static func parseRules(_ text: String) -> (description: String?, body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return (nil, normalized.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var description: String?
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("description:") else { continue }
            description = unquoted(String(trimmed.dropFirst("description:".count)))
        }
        lines.removeSubrange(0...end)
        return (description, lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One line, bounded, so it cannot break the stub's front matter.
    static func sanitizedDescription(_ description: String) -> String {
        let words = description.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(maximumDescriptionLength))
    }

    // MARK: - Editable files

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The user's copy, or nil when there is none.
    private static func editableText(_ file: SkillFile, in environment: Environment) throws -> String? {
        do {
            return try String(contentsOf: fileURL(file, in: environment), encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    /// The text in effect: the user's copy, or the defaults.
    static func currentText(_ file: SkillFile, in environment: Environment) throws -> String {
        try editableText(file, in: environment) ?? file.defaultText
    }

    /// Brings the files up to date and says what state each is in:
    ///
    /// - writes the read-only originals when they differ from this version's defaults;
    /// - replaces a copy the user never changed when the defaults changed since;
    /// - leaves an edited copy alone, reporting it `outdated` once the defaults moved on.
    @discardableResult
    static func syncFiles(in environment: Environment) throws -> Files {
        try writeOriginals(in: environment)
        var state = readState(in: environment)
        var states: [SkillFile: FileState] = [:]
        for file in SkillFile.allCases {
            let current = sha256(file.defaultText)
            guard let text = try editableText(file, in: environment) else {
                states[file] = .default
                continue
            }
            let base = state.defaults[file.rawValue]
            if text == file.defaultText {
                states[file] = .default
                state.defaults[file.rawValue] = current
            } else if base != current, base == sha256(text) {
                // Never edited, and an update changed the defaults: follow them.
                try Data(file.defaultText.utf8).write(to: fileURL(file, in: environment), options: .atomic)
                state.defaults[file.rawValue] = current
                states[file] = .default
            } else {
                states[file] = base == current ? .edited : .outdated
            }
        }
        if state.defaults != readState(in: environment).defaults {
            try writeState(state, in: environment)
        }
        return Files(
            folder: filesFolder(in: environment), originalsFolder: originalsFolder(in: environment),
            guide: states[.guide] ?? .default, rules: states[.rules] ?? .default)
    }

    /// Read-only copies of this version's defaults, to compare an edited file against.
    private static func writeOriginals(in environment: Environment) throws {
        let folder = originalsFolder(in: environment)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in SkillFile.allCases {
            let url = folder.appendingPathComponent(file.fileName, isDirectory: false)
            if (try? String(contentsOf: url, encoding: .utf8)) == file.defaultText { continue }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
                try fileManager.removeItem(at: url)
            }
            try Data(file.defaultText.utf8).write(to: url)
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
    }

    /// Writes the defaults for each file the user has no copy of yet, so the folder holds
    /// both files to edit. Returns the files it created.
    @discardableResult
    static func createEditableFiles(in environment: Environment) throws -> [SkillFile] {
        try syncFiles(in: environment)
        try FileManager.default.createDirectory(
            at: filesFolder(in: environment), withIntermediateDirectories: true)
        var state = readState(in: environment)
        var created: [SkillFile] = []
        for file in SkillFile.allCases where try editableText(file, in: environment) == nil {
            try Data(file.defaultText.utf8).write(
                to: fileURL(file, in: environment), options: .withoutOverwriting)
            state.defaults[file.rawValue] = sha256(file.defaultText)
            created.append(file)
        }
        if !created.isEmpty { try writeState(state, in: environment) }
        return created
    }

    /// Puts the defaults back. A copy the user changed is kept beside it as `.bak`
    /// (replacing an older one). Returns those backups.
    @discardableResult
    static func resetFiles(in environment: Environment) throws -> [URL] {
        try syncFiles(in: environment)
        let fileManager = FileManager.default
        var state = readState(in: environment)
        var backups: [URL] = []
        for file in SkillFile.allCases {
            let url = fileURL(file, in: environment)
            if let text = try editableText(file, in: environment), text != file.defaultText {
                let backup = url.appendingPathExtension("bak")
                if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
                try fileManager.moveItem(at: url, to: backup)
                backups.append(backup)
            }
            if try editableText(file, in: environment) == nil, fileManager.fileExists(
                atPath: filesFolder(in: environment).path) {
                try Data(file.defaultText.utf8).write(to: url, options: .atomic)
            }
            state.defaults[file.rawValue] = sha256(file.defaultText)
        }
        try writeState(state, in: environment)
        return backups
    }

    // MARK: - The printed guide

    /// What `snippets-cli skill` prints: the guide, the user's rules, and where they live.
    static func guide(in environment: Environment) throws -> String {
        let files = try syncFiles(in: environment)
        let rules = try currentRules(in: environment)
        var text = try currentText(.guide, in: environment)
        if !text.hasSuffix("\n") { text += "\n" }
        let folder = files.folder.path
        let source = files.areDefaults
            ? "These are the defaults. To change the guide or the rules, `snippets-cli skill edit` creates editable copies in \(folder); edit those when the user asks."
            : "The guide and rules are the user's files in \(folder) (guide.md, rules.md). Edit them when the user asks to change them."
        var notes = ""
        if files.guide == .outdated {
            notes = "\nThe user edited this guide before Snippets was updated, so it may name commands or flags this version does not have. `snippets-cli help` lists the exact ones.\n"
        }
        return text + "\n" + rules.body + "\n\n" + source + "\n" + notes
    }

    // MARK: - Stubs

    static func stub(description: String) -> String {
        AgentSkillText.stubTemplate.replacingOccurrences(
            of: "{{description}}", with: yamlQuoted(sanitizedDescription(description)))
    }

    /// Whether a `SKILL.md` is one `install` wrote.
    static func isStub(_ text: String) -> Bool {
        guard text.hasPrefix("---\n") else { return false }
        let frontMatter = text.dropFirst(4).components(separatedBy: "\n---").first ?? ""
        return frontMatter.contains(stubMarker)
    }

    /// Writes the current stub to each place. A custom folder is remembered once it holds
    /// the stub; one that has disappeared is reported and never recreated.
    static func install(_ places: [Place], in environment: Environment) throws -> [Change] {
        let text = stub(description: try currentRules(in: environment).description)
        let fileManager = FileManager.default
        return try places.map { place in
            let url = stubURL(for: place, in: environment)
            let change = { (outcome: Outcome) in Change(place: place, url: url, outcome: outcome) }
            let folder = skillsFolder(for: place, in: environment)
            if case .folder = place, !canHold(folder) { return change(.missing) }
            if let existing = try? String(contentsOf: url, encoding: .utf8) {
                guard isStub(existing) else { return change(.skipped) }
                if existing == text {
                    if case .folder(let folder) = place { try remember(folder, in: environment) }
                    return change(.unchanged)
                }
            } else if fileManager.fileExists(atPath: url.path) {
                // Present but unreadable as text: not ours to replace.
                return change(.skipped)
            }
            if case .folder = place {
                // Only the final `skills` folder may be created, never its parents.
                if !isDirectory(folder) {
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                }
            }
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            if case .folder(let folder) = place { try remember(folder, in: environment) }
            return change(.wrote)
        }
    }

    /// Removes stubs `install` wrote, and their folder when nothing else is in it. A custom
    /// folder is forgotten whatever was there. Never touches the rules file.
    static func uninstall(_ places: [Place], in environment: Environment) throws -> [Change] {
        let fileManager = FileManager.default
        return try places.map { place in
            let url = stubURL(for: place, in: environment)
            defer { if case .folder(let folder) = place { try? forget(folder, in: environment) } }
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                let outcome: Outcome = fileManager.fileExists(atPath: url.path) ? .skipped : .absent
                return Change(place: place, url: url, outcome: outcome)
            }
            guard isStub(existing) else { return Change(place: place, url: url, outcome: .skipped) }
            try fileManager.removeItem(at: url)
            let skillFolder = url.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: skillFolder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: skillFolder)
            }
            return Change(place: place, url: url, outcome: .removed)
        }
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Whether a custom skills folder exists or may be created (only its last part).
    private static func canHold(_ folder: URL) -> Bool {
        isDirectory(folder)
            || (folder.lastPathComponent == "skills" && isDirectory(folder.deletingLastPathComponent()))
    }

    /// A YAML double-quoted scalar. JSON string syntax is a subset of it.
    private static func yamlQuoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value), let quoted = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return quoted
    }

    private static func unquoted(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}
