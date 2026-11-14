import AppKit

extension Notification.Name {
    /// A Settings pane changed how much it shows; the window re-measures the current pane.
    static let settingsPaneContentDidChange = Notification.Name("SnippetsSettingsPaneContentDidChange")
}

/// Settings › Integrations: the command line tool and the agent skill that teaches AI
/// coding agents to use it (`AgentSkill`).
///
/// Changes apply as soon as a box is ticked or a folder added or removed, as elsewhere in
/// Settings. The rows show `AgentSkill.status`, the same model `snippets-cli skill status`
/// prints. The app does not see the shell's `CLAUDE_CONFIG_DIR`; "Add Folder…" covers an
/// agent that keeps its skills somewhere else.
@MainActor
final class CommandLineSettingsSection: NSObject {

    private static let cliInstallURL = URL(filePath: "/usr/local/bin/snippets-cli")
    private static let cliBinaryName = "snippets-cli"

    private let cliInstallButton = NSButton(title: "Install CLI Tool", target: nil, action: nil)
    private let cliStatusLabel = NSTextField(wrappingLabelWithString: "")

    private let skillIntroLabel = makeSecondaryLabel(
        "Teaches coding agents such as Claude Code and Codex to use snippets-cli. Secure snippets still need your approval.")
    private let placesStack = NSStackView()
    private let addFolderButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let showFilesButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let resetFilesButton = NSButton(title: "Reset to Defaults…", target: nil, action: nil)
    private let filesLabel = makeTertiaryLabel("")
    private let skillStatusLabel = NSTextField(wrappingLabelWithString: "")

    private var environment: AgentSkill.Environment { .current }
    private var activationObserver: NSObjectProtocol?

    // MARK: - Layout

    func add(to stack: NSStackView) {
        cliInstallButton.target = self
        cliInstallButton.action = #selector(installCLI)
        LiquidGlassDesign.configureActionButton(cliInstallButton, symbolName: "terminal")
        configureStatusLabel(cliStatusLabel)

        placesStack.orientation = .vertical
        placesStack.alignment = .leading
        placesStack.spacing = 6

        addFolderButton.target = self
        addFolderButton.action = #selector(addFolder)
        LiquidGlassDesign.configureActionButton(addFolderButton, symbolName: "folder.badge.plus")
        showFilesButton.target = self
        showFilesButton.action = #selector(showFiles)
        LiquidGlassDesign.configureActionButton(showFilesButton, symbolName: "folder")
        resetFilesButton.target = self
        resetFilesButton.action = #selector(resetFiles)
        LiquidGlassDesign.configureActionButton(resetFilesButton, symbolName: "arrow.counterclockwise")
        filesLabel.lineBreakMode = .byTruncatingMiddle
        filesLabel.maximumNumberOfLines = 2
        configureStatusLabel(skillStatusLabel)

        let cliRow = row([cliInstallButton, NSView()])
        let skillButtonRow = row([addFolderButton, showFilesButton, NSView(), resetFilesButton])

        let views: [NSView] = [
            makeSettingsSectionTitle("Command Line Tool"),
            makeSecondaryLabel("Install snippets-cli to /usr/local/bin so agents and terminal scripts can interact with your snippets."),
            cliRow,
            cliStatusLabel,
            NSBox.horizontalSeparator(),
            makeSettingsSectionTitle("Agent Skill"),
            skillIntroLabel,
            placesStack,
            skillButtonRow,
            filesLabel,
            skillStatusLabel,
        ]
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // The rules file may have changed in an editor while Snippets was in the
        // background; bring the installed descriptions up to date when it returns.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        updateCLIStatus()
        refreshInstalledDescriptions()
        rebuildPlaces()
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func configureStatusLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
    }

    // MARK: - Command line tool

    private var cliSourceURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent(Self.cliBinaryName)
    }

    private var cliIsInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.cliInstallURL.path)
    }

    private func updateCLIStatus() {
        let installURL = Self.cliInstallURL
        let fm = FileManager.default

        guard let cliSourceURL else {
            cliInstallButton.isEnabled = false
            cliStatusLabel.stringValue = "snippets-cli not found in app bundle."
            return
        }

        cliInstallButton.isEnabled = true

        let destExists = fm.fileExists(atPath: installURL.path)
        let pointsHere: Bool = {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: installURL.path) else { return false }
            return dest == cliSourceURL.path
        }()

        if destExists && pointsHere {
            cliInstallButton.title = "Reinstall CLI Tool"
            cliStatusLabel.stringValue = "Installed at \(installURL.path)"
        } else if destExists {
            cliInstallButton.title = "Install CLI Tool"
            cliStatusLabel.stringValue = "\(installURL.path) exists but points elsewhere. Clicking install will replace it."
        } else {
            cliInstallButton.title = "Install CLI Tool"
            cliStatusLabel.stringValue = "Not installed."
        }
    }

    @objc private func installCLI() {
        guard let cliSourceURL else {
            cliStatusLabel.stringValue = "Could not locate snippets-cli inside the app bundle."
            return
        }

        let installURL = Self.cliInstallURL
        let fm = FileManager.default

        do {
            let binDir = installURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: binDir.path) {
                try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: installURL.path) {
                try fm.removeItem(at: installURL)
            }
            try fm.createSymbolicLink(at: installURL, withDestinationURL: cliSourceURL)
            reload()
        } catch {
            installCLIWithPrivileges(source: cliSourceURL, destination: installURL)
        }
    }

    /// Escapes a value for embedding in an AppleScript double-quoted string
    /// literal (backslashes and double quotes are the only escapes needed).
    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func installCLIWithPrivileges(source: URL, destination: URL) {
        // Two escaping layers: paths become AppleScript string literals (escaping
        // \ and "), and AppleScript's `quoted form of` handles shell quoting.
        // Raw paths are never interpolated into the shell command itself.
        let script = """
        set srcPath to \(appleScriptStringLiteral(source.path))
        set dstPath to \(appleScriptStringLiteral(destination.path))
        set dirPath to \(appleScriptStringLiteral(destination.deletingLastPathComponent().path))
        do shell script "mkdir -p " & quoted form of dirPath & " && ln -sf " & quoted form of srcPath & " " & quoted form of dstPath with administrator privileges
        """

        var appleScriptError: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&appleScriptError)

        if let errDict = appleScriptError {
            let msg = errDict[NSAppleScript.errorMessage] as? String ?? "unknown error"
            cliStatusLabel.stringValue = "Installation failed: \(msg)"
        } else {
            reload()
        }
    }

    // MARK: - Agent skill

    private func displayPath(_ url: URL) -> String {
        let path = url.path, home = environment.home.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Rewrites installed stubs whose description no longer matches the rules file.
    /// Writes nothing when they already match.
    private func refreshInstalledDescriptions() {
        guard let places = try? AgentSkill.installedPlaces(in: environment), !places.isEmpty else { return }
        _ = try? AgentSkill.install(places, in: environment)
    }

    private func rebuildPlaces() {
        // Rows and a wrapping status line change the pane's height; re-measuring is cheap.
        defer { NotificationCenter.default.post(name: .settingsPaneContentDidChange, object: nil) }
        placesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        replaceablePlaces.removeAll()

        let enabled = cliIsInstalled
        addFolderButton.isEnabled = enabled
        showFilesButton.isEnabled = true

        guard let status = try? AgentSkill.status(in: environment) else {
            skillStatusLabel.stringValue = "Could not read the agent skill status."
            return
        }
        filesLabel.stringValue = filesText(status.files)
        resetFilesButton.isEnabled = !status.files.areDefaults
        if !enabled {
            skillStatusLabel.stringValue = "Install the command line tool first. The skill runs snippets-cli."
        } else if skillStatusLabel.stringValue.hasPrefix("Install the command line tool") {
            skillStatusLabel.stringValue = ""
        }

        // Codex also reads ~/.agents/skills, so its own folder is shown only when
        // something is in it.
        for place in status.places
        where !(place.place == .target(.codex) && place.state == .notInstalled) {
            let rowView = makeRow(for: place, enabled: enabled)
            placesStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: placesStack.widthAnchor).isActive = true
        }
    }

    private static let foreignSentence = "Another skill named snippets-cli is already here."

    private func stateText(_ place: AgentSkill.PlaceStatus) -> String {
        switch place.state {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        case .foreign: "Another skill is here"
        case .missing: "Folder not found"
        }
    }

    private func makeRow(for place: AgentSkill.PlaceStatus, enabled: Bool) -> NSView {
        let path = makeTertiaryLabel(displayPath(place.skillsFolder))
        path.maximumNumberOfLines = 1
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = place.skillsFolder.path
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The state never truncates; the path gives way instead.
        let state = NSTextField(labelWithString: stateText(place))
        state.font = .systemFont(ofSize: 12)
        state.textColor = place.state == .installed ? .secondaryLabelColor : .tertiaryLabelColor
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        if place.state == .foreign { state.toolTip = Self.foreignSentence }

        switch place.place {
        case .target(let target):
            let checkbox = NSButton(
                checkboxWithTitle: target.displayName, target: self, action: #selector(toggleTarget(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(target.rawValue)
            checkbox.state = place.state == .installed ? .on : .off
            // Unticking stays possible without the CLI, so the skill can always be removed.
            checkbox.isEnabled = place.state != .foreign && (enabled || place.state == .installed)
            checkbox.widthAnchor.constraint(equalToConstant: 200).isActive = true
            if place.state == .foreign {
                return row([checkbox, path, NSView(), state, replaceButton(for: place.place)])
            }
            return row([checkbox, path, NSView(), state])

        case .folder(let url):
            let icon = NSImageView(image: NSImage(
                systemSymbolName: place.state == .missing ? "exclamationmark.triangle" : "folder",
                accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = place.state == .missing ? .systemOrange : .secondaryLabelColor
            let name = NSTextField(labelWithString: AgentSkill.folderTitle(url))
            name.font = .systemFont(ofSize: 13)
            name.lineBreakMode = .byTruncatingMiddle
            let title = row([icon, name])
            title.spacing = 4
            title.widthAnchor.constraint(equalToConstant: 200).isActive = true
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeFolder(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(url.path)
            remove.toolTip = "Remove the skill from this folder"
            LiquidGlassDesign.configureActionButton(remove, symbolName: "minus.circle")
            if place.state == .foreign {
                return row([title, path, NSView(), state, replaceButton(for: place.place), remove])
            }
            return row([title, path, NSView(), state, remove])
        }
    }

    private var replaceablePlaces: [Int: AgentSkill.Place] = [:]

    private func replaceButton(for place: AgentSkill.Place) -> NSButton {
        let button = NSButton(title: "Replace…", target: self, action: #selector(replaceSkill(_:)))
        button.tag = replaceablePlaces.count + 1
        replaceablePlaces[button.tag] = place
        button.toolTip = Self.foreignSentence
        LiquidGlassDesign.configureActionButton(button, symbolName: "arrow.triangle.2.circlepath")
        return button
    }

    @objc private func replaceSkill(_ sender: NSButton) {
        guard let place = replaceablePlaces[sender.tag] else { return }
        let folder = displayPath(AgentSkill.skillsFolder(for: place, in: environment))
        let alert = NSAlert()
        alert.messageText = "Replace the other snippets-cli skill in \(folder)?"
        alert.informativeText = "Snippets didn't write it. Its SKILL.md is kept beside it as SKILL.md.bak, so agents stop loading it, and Snippets installs its own skill there."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let backup = try AgentSkill.replace(place, in: environment)
            skillStatusLabel.stringValue = backup.map {
                "Replaced. The other skill is kept as \(displayPath($0))."
            } ?? "Installed."
        } catch {
            skillStatusLabel.stringValue = "Could not replace the skill: \(error.localizedDescription)"
        }
        rebuildPlaces()
    }

    private func apply(_ action: () throws -> [AgentSkill.Change]) {
        do {
            let changes = try action()
            let folder = { (change: AgentSkill.Change) in
                self.displayPath(change.url.deletingLastPathComponent().deletingLastPathComponent())
            }
            if let removed = changes.first(where: { $0.outcome == .removed }) {
                skillStatusLabel.stringValue = "Removed from \(folder(removed))."
            } else if let skipped = changes.first(where: { $0.outcome == .skipped }) {
                skillStatusLabel.stringValue = "Not changed: another skill named snippets-cli is already in \(folder(skipped))."
            } else if let missing = changes.first(where: { $0.outcome == .missing }) {
                skillStatusLabel.stringValue = "\(folder(missing)) was not found."
            } else if let forgotten = changes.first(where: {
                if case .folder = $0.place { return $0.outcome == .absent }
                return false
            }) {
                // A vanished folder: nothing to delete, but it leaves the list.
                skillStatusLabel.stringValue = "Removed \(folder(forgotten)) from the list."
            } else if changes.contains(where: { $0.outcome == .wrote }) {
                skillStatusLabel.stringValue = "Installed. Restart running agent sessions to pick up the skill."
            } else {
                skillStatusLabel.stringValue = ""
            }
        } catch {
            skillStatusLabel.stringValue = "Could not change the agent skill: \(error.localizedDescription)"
        }
        rebuildPlaces()
    }

    @objc private func toggleTarget(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let target = AgentSkill.Target(rawValue: raw) else { return }
        let place = AgentSkill.Place.target(target)
        if sender.state == .on {
            apply { try AgentSkill.install([place], in: environment) }
        } else {
            apply { try AgentSkill.uninstall([place], in: environment) }
        }
    }

    @objc private func removeFolder(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        apply { try AgentSkill.uninstall([AgentSkill.folder(path)], in: environment) }
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Add Folder"
        panel.message = "Choose an agent's skills folder, such as a project's .claude/skills."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let place = try AgentSkill.resolveFolder(
                url.path, currentDirectory: environment.home, in: environment)
            apply { try AgentSkill.install([place], in: environment) }
        } catch {
            skillStatusLabel.stringValue = "\(error)"
        }
    }

    /// Creates the rules file from the defaults if needed, then opens it in the default
    /// plain-text editor: opening a `.md` directly can land in Xcode or in nothing.
    /// "Guide and rules: … · Defaults", or which one was edited, or that the defaults
    /// changed under an edited file.
    private func filesText(_ files: AgentSkill.Files) -> String {
        let folder = displayPath(files.folder)
        let changed = [("guide", files.guide), ("rules", files.rules)].filter { $0.1 != .default }
        if changed.isEmpty { return "Guide and rules: \(folder) · Defaults" }
        let names = changed.map(\.0).joined(separator: " and ")
        if changed.contains(where: { $0.1 == .outdated }) {
            return "Guide and rules: \(folder) · You edited the \(names); an update changed the defaults since. The originals are in \(displayPath(files.originalsFolder))."
        }
        return "Guide and rules: \(folder) · You edited the \(names)"
    }

    /// Makes editable copies of the guide and rules if there are none yet, then shows
    /// them in Finder, where the user edits them in any editor.
    @objc private func showFiles() {
        let environment = environment
        do {
            try AgentSkill.createEditableFiles(in: environment)
        } catch {
            skillStatusLabel.stringValue = "Could not create the guide and rules: \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(
            AgentSkill.SkillFile.allCases.map { AgentSkill.fileURL($0, in: environment) })
        skillStatusLabel.stringValue = ""
        rebuildPlaces()
    }

    @objc private func resetFiles() {
        let alert = NSAlert()
        alert.messageText = "Reset the agent guide and rules?"
        alert.informativeText = "Snippets puts the default guide.md and rules.md back. Your versions are kept beside them as guide.md.bak and rules.md.bak."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let environment = environment
        do {
            let backups = try AgentSkill.resetFiles(in: environment)
            refreshInstalledDescriptions()
            skillStatusLabel.stringValue = backups.isEmpty
                ? "The guide and rules are the defaults."
                : "Put the defaults back. Your versions are kept as \(backups.map(\.lastPathComponent).joined(separator: " and "))."
        } catch {
            skillStatusLabel.stringValue = "Could not reset the guide and rules: \(error.localizedDescription)"
        }
        rebuildPlaces()
    }
}

/// Settings › Agents: the command line tool and the agent skill.
@MainActor
final class AgentsSettingsViewController: NSViewController {
    private let section = CommandLineSettingsSection()

    override func loadView() {
        let (rootView, stack) = makeSettingsPane()
        view = rootView
        section.add(to: stack)
        section.reload()
    }

    func reloadFromStorage() {
        guard isViewLoaded else { return }
        section.reload()
    }
}
