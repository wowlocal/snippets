import SwiftUI

struct SnippetsRootView: View {
    @ObservedObject var store: SnippetStore
    @ObservedObject var engine: SnippetExpansionEngine

    @State private var selectedSnippetID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            permissionsBanner
            Divider()

            HSplitView {
                sidebar
                editor
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            engine.startIfNeeded()
            if selectedSnippetID == nil {
                selectedSnippetID = store.snippets.first?.id
            }
        }
        .onChange(of: store.snippets.map(\.id)) { _, ids in
            if let selectedSnippetID, !ids.contains(selectedSnippetID) {
                self.selectedSnippetID = ids.first
            }

            if self.selectedSnippetID == nil {
                self.selectedSnippetID = ids.first
            }
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

            Button("Input Monitoring") {
                engine.openInputMonitoringSettings()
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
                    let snippet = store.addSnippet()
                    selectedSnippetID = snippet.id
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            List(selection: $selectedSnippetID) {
                ForEach(store.snippets) { snippet in
                    SnippetRow(snippet: snippet)
                        .tag(snippet.id)
                }
            }
            .listStyle(.inset)

            HStack {
                Button(role: .destructive) {
                    guard let selectedSnippetID else { return }
                    store.delete(snippetID: selectedSnippetID)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedSnippetID == nil)

                Spacer()

                if let lastExpansionName = engine.lastExpansionName {
                    Text("Last expanded: \(lastExpansionName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
    }

    private var editor: some View {
        Group {
            if let selectedSnippetID {
                SnippetEditorView(
                    snippet: Binding(
                        get: { store.snippet(id: selectedSnippetID) ?? Snippet(name: "", keyword: "", content: "") },
                        set: { store.update($0) }
                    )
                )
            } else {
                ContentUnavailableView("No Snippet Selected", systemImage: "text.quote", description: Text("Create a snippet to begin."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(snippet.isEnabled ? Color.green : Color.gray)
                .frame(width: 9, height: 9)

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

private struct SnippetEditorView: View {
    @Binding var snippet: Snippet

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Name")
                    .font(.headline)
                TextField("Temporary Password", text: $snippet.name)
                    .textFieldStyle(.roundedBorder)

                Text("Snippet")
                    .font(.headline)

                TextEditor(text: $snippet.content)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
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
