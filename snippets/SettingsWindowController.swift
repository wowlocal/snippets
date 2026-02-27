import AppKit
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsViewController = SettingsViewController()

    init() {
        let window = NSWindow(contentViewController: settingsViewController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 460))
        window.minSize = NSSize(width: 620, height: 380)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        settingsViewController.reloadFromStorage()
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class SettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct BundleIDRow {
        let appName: String
        let bundleID: String
        let installed: Bool
    }

    private enum ColumnID {
        static let app = NSUserInterfaceItemIdentifier("SettingsAppColumn")
        static let bundleID = NSUserInterfaceItemIdentifier("SettingsBundleIDColumn")
    }

    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let removeButton = NSButton(title: "Remove Selected", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear All", target: nil, action: nil)

    private var customBundleIDs: [String] = []
    private var rows: [BundleIDRow] = []

    override func loadView() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        view = rootView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(stack)

        let titleLabel = NSTextField(labelWithString: "Chromium Bundle IDs")
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)

        let descriptionLabel = NSTextField(wrappingLabelWithString: "Add custom Chromium-based apps for enhanced accessibility priming.")
        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabelColor

        let builtInLabel = NSTextField(wrappingLabelWithString: "Built-in apps: Chrome, Chromium, Edge, Brave, Opera, Vivaldi, Arc")
        builtInLabel.font = .systemFont(ofSize: 12)
        builtInLabel.textColor = .tertiaryLabelColor

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let appColumn = NSTableColumn(identifier: ColumnID.app)
        appColumn.title = "App"
        appColumn.width = 220
        appColumn.resizingMask = .userResizingMask

        let bundleIDColumn = NSTableColumn(identifier: ColumnID.bundleID)
        bundleIDColumn.title = "Bundle ID"
        bundleIDColumn.width = 420
        bundleIDColumn.resizingMask = .autoresizingMask

        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(bundleIDColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28
        tableView.allowsEmptySelection = true
        tableView.delegate = self
        tableView.dataSource = self
        scrollView.documentView = tableView

        let addAppButton = NSButton(title: "Add App...", target: self, action: #selector(addApp))
        let addBundleIDButton = NSButton(title: "Add Bundle ID...", target: self, action: #selector(addBundleID))
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        clearButton.target = self
        clearButton.action = #selector(clearAll)

        let buttonRow = NSStackView(views: [addAppButton, addBundleIDButton, NSView(), removeButton, clearButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(descriptionLabel)
        stack.addArrangedSubview(builtInLabel)
        stack.addArrangedSubview(countLabel)
        stack.addArrangedSubview(scrollView)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(statusLabel)

        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18)
        ])

        reloadFromStorage()
    }

    func reloadFromStorage() {
        customBundleIDs = ChromiumBundleIDSettings.additionalBundleIDs()
        statusLabel.stringValue = ""
        rebuildRows()
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.prompt = "Add App"
        panel.message = "Choose an app to add its bundle identifier."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
            showWarningAlert(
                title: "Couldn't Read Bundle ID",
                message: "\(url.lastPathComponent) doesn't expose a bundle identifier."
            )
            return
        }

        appendBundleIDs([bundleID], source: url.lastPathComponent)
    }

    @objc private func addBundleID() {
        let alert = NSAlert()
        alert.messageText = "Add Bundle ID"
        alert.informativeText = "Paste one or more bundle IDs (one per line; commas and semicolons also work)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let inputScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 86))
        inputScrollView.borderType = .bezelBorder
        inputScrollView.hasVerticalScroller = true

        let inputTextView = NSTextView(frame: inputScrollView.bounds)
        inputTextView.isRichText = false
        inputTextView.isAutomaticQuoteSubstitutionEnabled = false
        inputTextView.isAutomaticTextReplacementEnabled = false
        inputTextView.isAutomaticSpellingCorrectionEnabled = false
        inputTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inputTextView.textContainerInset = NSSize(width: 6, height: 6)
        inputTextView.textContainer?.widthTracksTextView = true
        inputScrollView.documentView = inputTextView
        alert.accessoryView = inputScrollView

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let incoming = ChromiumBundleIDSettings.normalizedBundleIDs(from: inputTextView.string)
        guard !incoming.isEmpty else {
            statusLabel.stringValue = "No bundle IDs were added."
            return
        }

        appendBundleIDs(incoming, source: nil)
    }

    @objc private func removeSelected() {
        let selected = tableView.selectedRow
        guard selected >= 0 && selected < customBundleIDs.count else { return }

        var updated = customBundleIDs
        let removed = updated.remove(at: selected)
        applyAndPersist(updated)
        statusLabel.stringValue = "Removed \(removed)."
    }

    @objc private func clearAll() {
        guard !customBundleIDs.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Clear All Custom Bundle IDs?"
        alert.informativeText = "Built-in browser IDs stay enabled. This only removes your custom entries."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyAndPersist([])
        statusLabel.stringValue = "Cleared all custom bundle IDs."
    }

    @objc private func selectionChanged() {
        updateButtonStates()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
    }

    private func appendBundleIDs(_ incoming: [String], source: String?) {
        var updated = customBundleIDs
        var seen = Set(customBundleIDs.map { $0.lowercased() })
        var addedCount = 0

        for bundleID in incoming {
            let key = bundleID.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            updated.append(bundleID)
            addedCount += 1
        }

        guard addedCount > 0 else {
            statusLabel.stringValue = "Those bundle IDs are already in the list."
            return
        }

        applyAndPersist(updated)
        if let source {
            statusLabel.stringValue = "Added \(addedCount) bundle ID from \(source)."
        } else {
            statusLabel.stringValue = "Added \(addedCount) bundle ID(s)."
        }
    }

    private func applyAndPersist(_ updatedBundleIDs: [String]) {
        customBundleIDs = updatedBundleIDs
        ChromiumBundleIDSettings.saveAdditionalBundleIDs(updatedBundleIDs)
        rebuildRows()
    }

    private func rebuildRows() {
        rows = customBundleIDs.map { bundleID in
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return BundleIDRow(
                    appName: appName(from: appURL),
                    bundleID: bundleID,
                    installed: true
                )
            }

            return BundleIDRow(
                appName: "Unknown App",
                bundleID: bundleID,
                installed: false
            )
        }

        countLabel.stringValue = "\(customBundleIDs.count) custom app(s)"
        tableView.reloadData()
        updateButtonStates()
    }

    private func appName(from appURL: URL) -> String {
        guard let bundle = Bundle(url: appURL) else {
            return appURL.deletingPathExtension().lastPathComponent
        }

        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let name = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String,
           !name.isEmpty {
            return name
        }

        return appURL.deletingPathExtension().lastPathComponent
    }

    private func updateButtonStates() {
        let hasSelection = tableView.selectedRow >= 0 && tableView.selectedRow < rows.count
        removeButton.isEnabled = hasSelection
        clearButton.isEnabled = !rows.isEmpty
    }

    private func showWarningAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < rows.count, let tableColumn else { return nil }
        let item = rows[row]

        if tableColumn.identifier == ColumnID.app {
            let text = item.installed ? item.appName : "Unknown App (not installed)"
            return configuredCell(
                identifier: NSUserInterfaceItemIdentifier("SettingsAppCell"),
                text: text,
                font: .systemFont(ofSize: 12),
                color: item.installed ? .labelColor : .secondaryLabelColor
            )
        }

        return configuredCell(
            identifier: NSUserInterfaceItemIdentifier("SettingsBundleIDCell"),
            text: item.bundleID,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: .labelColor
        )
    }

    private func configuredCell(
        identifier: NSUserInterfaceItemIdentifier,
        text: String,
        font: NSFont,
        color: NSColor
    ) -> NSTableCellView {
        let cell: NSTableCellView
        let textField: NSTextField

        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView,
           let existing = reused.textField {
            cell = reused
            textField = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        textField.font = font
        textField.textColor = color
        textField.lineBreakMode = .byTruncatingMiddle
        textField.stringValue = text
        return cell
    }
}
