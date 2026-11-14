import AppKit
import UniformTypeIdentifiers

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
        "Teaches Claude Code, Codex and other coding agents to use snippets-cli. Rules are advice to agents; secure snippets still need your approval.")
    private let placesStack = NSStackView()
    private let addFolderButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let editRulesButton = NSButton(title: "Edit Rules…", target: nil, action: nil)
    private let rulesLabel = makeTertiaryLabel("")
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
        editRulesButton.target = self
        editRulesButton.action = #selector(editRules)
        LiquidGlassDesign.configureActionButton(editRulesButton, symbolName: "list.bullet.rectangle")
        rulesLabel.lineBreakMode = .byTruncatingMiddle
        rulesLabel.maximumNumberOfLines = 1
        configureStatusLabel(skillStatusLabel)

        let cliRow = row([cliInstallButton, NSView()])
        let skillButtonRow = row([addFolderButton, editRulesButton, NSView()])

        let views: [NSView] = [
            NSBox.horizontalSeparator(),
            makeSettingsSectionTitle("Command Line Tool"),
            makeSecondaryLabel("Install snippets-cli to /usr/local/bin so agents and terminal scripts can interact with your snippets."),
            cliRow,
            cliStatusLabel,
            NSBox.horizontalSeparator(),
            makeSettingsSectionTitle("Agent Skill"),
            skillIntroLabel,
            placesStack,
            skillButtonRow,
            rulesLabel,
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

        let enabled = cliIsInstalled
        addFolderButton.isEnabled = enabled
        editRulesButton.isEnabled = true

        guard let status = try? AgentSkill.status(in: environment) else {
            skillStatusLabel.stringValue = "Could not read the agent skill status."
            return
        }
        let rules = displayPath(status.rulesURL)
        rulesLabel.stringValue = status.rulesAreCustom
            ? "Rules: \(rules)"
            : "Rules: \(rules) (defaults until you edit it)"
        if !enabled {
            skillStatusLabel.stringValue = "Install the command line tool first. The skill runs snippets-cli."
        } else if skillStatusLabel.stringValue.hasPrefix("Install the command line tool") {
            skillStatusLabel.stringValue = ""
        }

        for place in status.places {
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
            return row([title, path, NSView(), state, remove])
        }
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
    @objc private func editRules() {
        let environment = environment
        do {
            try AgentSkill.createRulesFile(in: environment)
        } catch {
            skillStatusLabel.stringValue = "Could not create the rules file: \(error.localizedDescription)"
            return
        }
        let url = AgentSkill.rulesURL(in: environment)
        let workspace = NSWorkspace.shared
        if let editor = workspace.urlForApplication(toOpen: .plainText) {
            workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(url)
        }
        skillStatusLabel.stringValue = "Opened agent-rules.md. Rule changes apply right away; a new description reaches installed skills when you come back to Snippets."
    }
}
