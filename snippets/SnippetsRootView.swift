import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum KeyboardFocusField: Hashable {
    case search
    case list
    case name
    case snippet
    case keyword
}

struct SnippetsRootView: View {
    var store: SnippetStore
    var engine: SnippetExpansionEngine

    @State private var selectedSnippetID: UUID?
    @State private var importExportMessage: String?
    @State private var importExportErrorMessage = ""
    @State private var showingImportExportError = false
    @State private var searchText = ""
    @State private var showingActionPanel = false

    @FocusState private var focusedField: KeyboardFocusField?

    var body: some View {
        VStack(spacing: 0) {
            permissionsBanner
            Divider()

            HSplitView {
                sidebar
                editor
            }
        }
        .overlay(alignment: .topLeading) {
            shortcutHandlers
        }
        .overlay {
            if showingActionPanel {
                actionPanelOverlay
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            engine.startIfNeeded()
            reconcileSelection(availableIDs: visibleSnippets.map(\.id))
            if focusedField == nil {
                focusedField = .list
            }
        }
        .onChange(of: visibleSnippets.map(\.id)) { _, ids in
            reconcileSelection(availableIDs: ids)
        }
        .onReceive(NotificationCenter.default.publisher(for: .snippetsCreateNew)) { _ in
            createSnippet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snippetsToggleActions)) { _ in
            toggleActionPanel()
        }
        .alert("Import / Export Failed", isPresented: $showingImportExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importExportErrorMessage)
        }
    }

    private var permissionsBanner: some View {
        HStack(spacing: 12) {
            Label(
                engine.accessibilityGranted ? "Permissions Ready" : "Permissions Required",
                systemImage: engine.accessibilityGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(engine.accessibilityGranted ? .green : .orange)

            Text(engine.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Refresh") {
                engine.refreshAccessibilityStatus(prompt: false)
            }

            Button("Request Permission") {
                engine.requestAccessibilityPermission()
            }

            Button("Accessibility") {
                engine.openAccessibilitySettings()
            }
        }
        .padding(12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Snippets")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button {
                    runImport()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button {
                    runExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button {
                    createSnippet()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            TextField("Search snippets", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .search)
                .padding(.horizontal, 12)

            List(selection: $selectedSnippetID) {
                ForEach(visibleSnippets) { snippet in
                    SnippetRow(snippet: snippet)
                        .tag(snippet.id)
                }
            }
            .listStyle(.inset)
            .focused($focusedField, equals: .list)

            HStack {
                Button(role: .destructive) {
                    deleteSelectedSnippet()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedSnippetID == nil)
                .keyboardShortcut(.delete, modifiers: [.command])

                Spacer()

                if let lastExpansionName = engine.lastExpansionName {
                    Text("Last action: \(lastExpansionName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Text("Raycast map: ↩ copy, ⌘K actions, ⌘N new, arrows move, Esc back")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)

            if let importExportMessage {
                Text(importExportMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                Spacer(minLength: 10)
            }
        }
        .frame(minWidth: 320, idealWidth: 340, maxWidth: 390)
    }

    private var editor: some View {
        Group {
            if let selectedSnippetID, store.snippet(id: selectedSnippetID) != nil {
                SnippetEditorView(
                    snippet: Binding(
                        get: { store.snippet(id: selectedSnippetID) ?? Snippet(name: "", keyword: "", content: "") },
                        set: { store.update($0) }
                    ),
                    focusedField: $focusedField
                )
            } else {
                ContentUnavailableView("No Snippet Selected", systemImage: "text.quote", description: Text("Create a snippet to begin."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionPanelOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    closeActionPanel()
                }

            VStack(alignment: .leading, spacing: 12) {
                Text("Actions")
                    .font(.title3.weight(.semibold))

                ActionRow(title: "Paste Snippet", shortcut: "⌘↩")
                ActionRow(title: "Edit Snippet", shortcut: "⌘E")
                ActionRow(title: "Duplicate Snippet", shortcut: "⌘D")
                ActionRow(title: selectedSnippet?.isPinned == true ? "Unpin Snippet" : "Pin Snippet", shortcut: "⌘.")
                ActionRow(title: "Create New Snippet", shortcut: "⌘N")

                Text("Esc to close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .frame(width: 320)
        }
    }

    private var visibleSnippets: [Snippet] {
        let sorted = store.snippetsSortedForDisplay()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sorted }

        return sorted.filter { snippet in
            snippet.displayName.lowercased().contains(query)
                || snippet.normalizedKeyword.lowercased().contains(query)
                || snippet.content.lowercased().contains(query)
        }
    }

    private var selectedSnippet: Snippet? {
        guard let selectedSnippetID else { return nil }
        return store.snippet(id: selectedSnippetID)
    }

    private var isListContext: Bool {
        focusedField == .list || focusedField == .search || focusedField == nil
    }

    private var shortcutHandlers: some View {
        Group {
            Button("Open Actions") {
                toggleActionPanel()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Focus Search") {
                focusedField = .search
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Create New Snippet") {
                createSnippet()
            }
            .keyboardShortcut("n", modifiers: [.command])

            if isListContext {
                Button("Copy Snippet") {
                    copySelectedSnippet()
                }
                .keyboardShortcut(.return, modifiers: [])
            }

            if showingActionPanel {
                Button("Paste Snippet") {
                    pasteSelectedSnippet()
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("Edit Snippet") {
                    editSelectedSnippet()
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button("Duplicate Snippet") {
                    duplicateSelectedSnippet()
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Pin Toggle") {
                    togglePinnedSelectedSnippet()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }

            Button("Escape") {
                handleEscape()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .labelsHidden()
        .buttonStyle(.plain)
        .frame(width: 1, height: 1)
        .clipped()
        .opacity(0.001)
        .accessibilityHidden(true)
    }

    private func handleEscape() {
        if showingActionPanel {
            closeActionPanel()
        } else {
            focusedField = .list
        }
    }

    private func toggleActionPanel() {
        if showingActionPanel {
            closeActionPanel()
        } else {
            openActionPanel()
        }
    }

    private func openActionPanel() {
        showingActionPanel = true
        focusedField = .list
    }

    private func closeActionPanel() {
        showingActionPanel = false
        focusedField = .list
    }

    private func createSnippet() {
        let snippet = store.addSnippet()
        selectedSnippetID = snippet.id
        showingActionPanel = false
        focusedField = .name
        importExportMessage = nil
    }

    private func deleteSelectedSnippet() {
        guard let selectedSnippetID else { return }
        store.delete(snippetID: selectedSnippetID)
        reconcileSelection(availableIDs: visibleSnippets.map(\.id))
        focusedField = .list
    }

    private func editSelectedSnippet() {
        guard selectedSnippet != nil else { return }
        focusedField = .name
        closeActionPanel()
    }

    private func duplicateSelectedSnippet() {
        guard let selectedSnippetID, let duplicate = store.duplicate(snippetID: selectedSnippetID) else { return }
        self.selectedSnippetID = duplicate.id
        importExportMessage = "Duplicated \(duplicate.displayName)."
        closeActionPanel()
        focusedField = .name
    }

    private func togglePinnedSelectedSnippet() {
        guard let selectedSnippetID else { return }
        store.togglePinned(snippetID: selectedSnippetID)
        importExportMessage = selectedSnippet?.isPinned == true ? "Pinned snippet." : "Unpinned snippet."
        closeActionPanel()
    }

    private func copySelectedSnippet() {
        guard let selectedSnippet else { return }
        engine.copySnippetToClipboard(selectedSnippet)
        importExportMessage = "Copied \(selectedSnippet.displayName) to clipboard."
    }

    private func pasteSelectedSnippet() {
        guard let selectedSnippet else { return }
        engine.pasteSnippetIntoFrontmostApp(selectedSnippet)
        importExportMessage = "Pasting \(selectedSnippet.displayName)."
        closeActionPanel()
    }

    private func reconcileSelection(availableIDs: [UUID]) {
        if let selectedSnippetID, availableIDs.contains(selectedSnippetID) {
            return
        }

        selectedSnippetID = availableIDs.first
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a snippets JSON file to import."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let count = try store.importSnippets(from: url)
            importExportMessage = "Imported \(count) snippet(s) from \(url.lastPathComponent)."
            reconcileSelection(availableIDs: visibleSnippets.map(\.id))
            focusedField = .list
        } catch {
            importExportErrorMessage = error.localizedDescription
            showingImportExportError = true
        }
    }

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "snippets-export.json"
        panel.message = "Choose where to save your snippets export."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let count = try store.exportSnippets(to: url)
            importExportMessage = "Exported \(count) snippet(s) to \(url.lastPathComponent)."
            focusedField = .list
        } catch {
            importExportErrorMessage = error.localizedDescription
            showingImportExportError = true
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(spacing: 10) {
            if snippet.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            } else {
                Circle()
                    .fill(snippet.isEnabled ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.displayName)
                    .lineLimit(1)

                Text(snippet.normalizedKeyword)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ActionRow: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct SnippetEditorView: View {
    @Binding var snippet: Snippet
    let focusedField: FocusState<KeyboardFocusField?>.Binding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Name")
                    .font(.headline)
                TextField("Temporary Password", text: $snippet.name)
                    .textFieldStyle(.roundedBorder)
                    .focused(focusedField, equals: .name)

                Text("Snippet")
                    .font(.headline)

                TextEditor(text: $snippet.content)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .focused(focusedField, equals: .snippet)
                    .frame(minHeight: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )

                Text("Dynamic placeholders: {clipboard}, {date}, {time}, {datetime}, {date:yyyy-MM-dd}")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Keyword")
                    .font(.headline)

                TextField("\\tp", text: $snippet.keyword)
                    .textFieldStyle(.roundedBorder)
                    .focused(focusedField, equals: .keyword)
                    .onChange(of: snippet.keyword) { _, keyword in
                        snippet.keyword = keyword.replacingOccurrences(of: " ", with: "")
                    }

                Toggle("Enabled", isOn: $snippet.isEnabled)

                Divider()

                Text("Preview")
                    .font(.headline)

                Text(previewText)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)
        }
    }

    private var previewText: String {
        let rendered = PlaceholderResolver.resolve(template: snippet.content)
        if rendered.isEmpty {
            return "Preview appears here once snippet text is entered"
        }
        return rendered
    }
}
