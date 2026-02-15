import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

@MainActor
final class SnippetExpansionEngine: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var listening = false
    @Published private(set) var lastExpansionName: String?
    @Published private(set) var statusText = "Grant Accessibility permissions to start snippet expansion."

    private let store: SnippetStore
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var typedBuffer = ""
    private let maxBufferLength = 120
    private var isInjecting = false

    init(store: SnippetStore) {
        self.store = store
        refreshAccessibilityStatus(prompt: false)
    }

    func startIfNeeded() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in
                    self?.handle(event: event)
                }
            }
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event: event)
                return event
            }
        }

        listening = true
        refreshAccessibilityStatus(prompt: false)
    }

    func requestAccessibilityPermission() {
        refreshAccessibilityStatus(prompt: true)
    }

    func refreshAccessibilityStatus(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)

        if accessibilityGranted {
            statusText = listening ? "Listening for snippet keywords in all apps." : "Ready to start listening."
        } else {
            statusText = "Accessibility access is required to watch typing and insert snippets."
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func handle(event: NSEvent) {
        guard listening, !isInjecting else { return }

        if frontmostProcessIsThisApp() {
            typedBuffer = ""
            return
        }

        if !event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty {
            typedBuffer = ""
            return
        }

        if event.keyCode == UInt16(kVK_Delete) {
            if !typedBuffer.isEmpty {
                typedBuffer.removeLast()
            }
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            typedBuffer = ""
            return
        }

        guard let character = typedCharacter(from: event) else {
            return
        }

        typedBuffer.append(character)
        trimBufferIfNeeded()

        if let immediateMatch = matchForImmediateExpansion() {
            expand(snippet: immediateMatch, deleteCount: immediateMatch.normalizedKeyword.count)
            typedBuffer = ""
            return
        }

        if isTriggerCharacter(character), let delimiterMatch = matchForDelimiterExpansion(trigger: character) {
            expand(snippet: delimiterMatch, deleteCount: delimiterMatch.normalizedKeyword.count + 1)
            typedBuffer = ""
        }
    }

    private func typedCharacter(from event: NSEvent) -> Character? {
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            return "\n"
        }

        if event.keyCode == UInt16(kVK_Tab) {
            return "\t"
        }

        guard let characters = event.characters, characters.count == 1 else {
            return nil
        }

        guard let character = characters.first else {
            return nil
        }

        return isControl(character) ? nil : character
    }

    private func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
    }

    private func trimBufferIfNeeded() {
        if typedBuffer.count > maxBufferLength {
            typedBuffer = String(typedBuffer.suffix(maxBufferLength))
        }
    }

    private func matchForImmediateExpansion() -> Snippet? {
        for snippet in store.enabledSnippetsSorted() {
            let keyword = snippet.normalizedKeyword
            guard !keyword.isEmpty else { continue }

            let startsWithWordChar = keyword.first.map { isWordCharacter($0) } ?? false
            guard !startsWithWordChar else { continue }

            guard typedBuffer.hasSuffix(keyword) else { continue }

            let previousCharacter = typedBuffer.dropLast(keyword.count).last
            if previousCharacter == nil || isBoundaryCharacter(previousCharacter!) {
                return snippet
            }
        }

        return nil
    }

    private func matchForDelimiterExpansion(trigger: Character) -> Snippet? {
        for snippet in store.enabledSnippetsSorted() {
            let keyword = snippet.normalizedKeyword
            guard !keyword.isEmpty else { continue }

            let expectedSuffix = keyword + String(trigger)
            if typedBuffer.hasSuffix(expectedSuffix) {
                return snippet
            }
        }

        return nil
    }

    private func isTriggerCharacter(_ character: Character) -> Bool {
        character == " " || character == "\n" || character == "\t"
    }

    private func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private func isBoundaryCharacter(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline {
            return true
        }

        let boundarySet = CharacterSet.punctuationCharacters.union(.symbols)
        return character.unicodeScalars.allSatisfy { boundarySet.contains($0) }
    }

    private func expand(snippet: Snippet, deleteCount: Int) {
        guard deleteCount > 0 else { return }

        let resolvedText = PlaceholderResolver.resolve(template: snippet.content)
        replaceTypedText(characterCount: deleteCount, with: resolvedText)

        lastExpansionName = snippet.displayName
        statusText = "Expanded \(snippet.displayName)."
    }

    private func replaceTypedText(characterCount: Int, with replacement: String) {
        isInjecting = true

        deleteBackward(characterCount: characterCount)
        paste(replacement)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.isInjecting = false
        }
    }

    private func deleteBackward(characterCount: Int) {
        guard characterCount > 0 else { return }
        for _ in 0..<characterCount {
            postKeyStroke(keyCode: UInt16(kVK_Delete))
        }
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = capturePasteboardState(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postKeyStroke(keyCode: UInt16(kVK_ANSI_V), flags: .maskCommand)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.restorePasteboardState(snapshot, to: pasteboard)
        }
    }

    private func postKeyStroke(keyCode: UInt16, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    private func capturePasteboardState(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pasteboard.pasteboardItems else { return [] }

        return items.map { item in
            var typeToData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeToData[type] = data
                }
            }
            return typeToData
        }
    }

    private func restorePasteboardState(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !snapshot.isEmpty else { return }

        let items: [NSPasteboardItem] = snapshot.map { typeToData in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in typeToData {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }

        pasteboard.writeObjects(items)
    }

    private func frontmostProcessIsThisApp() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}
