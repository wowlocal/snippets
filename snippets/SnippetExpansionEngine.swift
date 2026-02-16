import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class SnippetExpansionEngine {
    private(set) var accessibilityGranted = false { didSet { onStateChange?() } }
    private(set) var listening = false
    private(set) var lastExpansionName: String? { didSet { onStateChange?() } }
    private(set) var statusText = "Grant Accessibility permissions to start snippet expansion." { didSet { onStateChange?() } }

    var onStateChange: (() -> Void)?

    private let store: SnippetStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?

    private var typedBuffer = ""
    private let maxBufferLength = 120
    private var isInjecting = false

    // Suggestion overlay state
    private var suggestionActive = false
    private var suggestionQuery = ""
    private lazy var suggestionPanel = SuggestionPanelController()

    init(store: SnippetStore) {
        self.store = store
        refreshAccessibilityStatus(prompt: false)
    }

    func startIfNeeded() {
        if eventTap == nil {
            installEventTap()
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

    /// Install a CGEvent tap so we can intercept (suppress) keys like TAB
    /// while the suggestion overlay is active.
    private func installEventTap() {
        // Store a raw pointer to self for the C callback. The tap lives as
        // long as the engine, so the unretained reference is safe.
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // active tap — can modify/suppress events
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<SnippetExpansionEngine>.fromOpaque(refcon).takeUnretainedValue()
                // Must dispatch to main actor synchronously — we need the
                // return value now to decide whether to suppress the event.
                // CGEvent tap callbacks run on the run loop thread (main).
                let consumed = engine.handleEventTap(event)
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Called from the CGEvent tap callback on the main thread.
    /// Returns `true` if the event should be suppressed (consumed by us).
    nonisolated private func handleEventTap(_ cgEvent: CGEvent) -> Bool {
        // We're on the main thread (run loop), so we can safely access
        // MainActor-isolated state via MainActor.assumeIsolated.
        return MainActor.assumeIsolated {
            guard listening, !isInjecting else { return false }
            if frontmostProcessIsThisApp() { return false }

            guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return false }
            return handle(event: nsEvent)
        }
    }

    func requestAccessibilityPermission() {
        refreshAccessibilityStatus(prompt: true)
    }

    private func restartEventMonitors() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            runLoopSource = nil
            eventTap = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        startIfNeeded()
    }

    func refreshAccessibilityStatus(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let wasGranted = accessibilityGranted
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)

        if accessibilityGranted {
            // Permission was just granted — restart event monitors so they
            // pick up the new trust status without requiring an app relaunch.
            if !wasGranted {
                restartEventMonitors()
            }
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


    func copySnippetToClipboard(_ snippet: Snippet) {
        let rendered = PlaceholderResolver.resolve(template: snippet.content)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rendered, forType: .string)

        lastExpansionName = snippet.displayName
        statusText = "Copied \(snippet.displayName)."
    }

    func pasteSnippetIntoFrontmostApp(_ snippet: Snippet) {
        let rendered = PlaceholderResolver.resolve(template: snippet.content)

        if frontmostProcessIsThisApp() {
            NSApp.hide(nil)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            self.paste(rendered)
            self.lastExpansionName = snippet.displayName
            self.statusText = "Pasted \(snippet.displayName)."
        }
    }

    /// Returns `true` if the event was consumed and should be suppressed.
    @discardableResult
    private func handle(event: NSEvent) -> Bool {
        guard listening, !isInjecting else { return false }

        if frontmostProcessIsThisApp() {
            typedBuffer = ""
            dismissSuggestions()
            return false
        }

        // Suggestion mode handling — check before modifier guard so
        // Ctrl+N / Ctrl+P can navigate the list.
        if suggestionActive {
            return handleSuggestionEvent(event)
        }

        if !event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty {
            typedBuffer = ""
            dismissSuggestions()
            return false
        }

        if event.keyCode == UInt16(kVK_Delete) {
            if !typedBuffer.isEmpty {
                typedBuffer.removeLast()
            }
            return false
        }

        if event.keyCode == UInt16(kVK_Escape) {
            typedBuffer = ""
            return false
        }

        guard let character = typedCharacter(from: event) else {
            return false
        }

        typedBuffer.append(character)
        trimBufferIfNeeded()

        // Activate suggestion mode on backslash, only if a text field is focused
        if character == "\\" && focusedElementIsTextInput() {
            activateSuggestions()
            return false
        }

        if let immediateMatch = matchForImmediateExpansion() {
            expand(snippet: immediateMatch, deleteCount: immediateMatch.normalizedKeyword.count)
            typedBuffer = ""
            return false
        }

        if isTriggerCharacter(character), let delimiterMatch = matchForDelimiterExpansion(trigger: character) {
            expand(snippet: delimiterMatch, deleteCount: delimiterMatch.normalizedKeyword.count + 1)
            typedBuffer = ""
        }

        return false
    }

    // MARK: - Suggestion Mode

    private func activateSuggestions() {
        suggestionActive = true
        suggestionQuery = ""

        suggestionPanel.onSelect = { [weak self] snippet in
            self?.selectSuggestion(snippet)
        }
        suggestionPanel.onDismiss = { [weak self] in
            self?.dismissSuggestions()
        }

        updateSuggestionResults()
    }

    private func selectSuggestion(_ snippet: Snippet) {
        let deleteCount = 1 + suggestionQuery.count // backslash + query
        dismissSuggestions()
        expand(snippet: snippet, deleteCount: deleteCount)
        typedBuffer = ""
    }

    private func dismissSuggestions() {
        guard suggestionActive else { return }
        suggestionActive = false
        suggestionQuery = ""
        suggestionPanel.dismiss()
    }

    /// Returns `true` if the event should be suppressed (consumed by us).
    private func handleSuggestionEvent(_ event: NSEvent) -> Bool {
        let ctrl = event.modifierFlags.contains(.control)

        // Arrow keys / Ctrl+N/P navigate the list — suppress so target app doesn't see them
        if event.keyCode == UInt16(kVK_DownArrow) || (ctrl && event.keyCode == UInt16(kVK_ANSI_N)) {
            suggestionPanel.moveSelectionDown()
            return true
        }
        if event.keyCode == UInt16(kVK_UpArrow) || (ctrl && event.keyCode == UInt16(kVK_ANSI_P)) {
            suggestionPanel.moveSelectionUp()
            return true
        }

        // Emacs Ctrl+H — treat as backspace
        if ctrl && event.keyCode == UInt16(kVK_ANSI_H) {
            if suggestionQuery.isEmpty {
                dismissSuggestions()
                if !typedBuffer.isEmpty { typedBuffer.removeLast() }
            } else {
                suggestionQuery.removeLast()
                if !typedBuffer.isEmpty { typedBuffer.removeLast() }
                updateSuggestionResults()
            }
            return false
        }

        // Command/Option combos dismiss (Cmd+Z, Option produces special chars, etc.)
        if !event.modifierFlags.intersection([.command, .option]).isEmpty {
            typedBuffer = ""
            dismissSuggestions()
            return false
        }

        // Other Ctrl combos and function keys — ignore without dismissing
        if ctrl {
            return false
        }

        // Escape dismisses — suppress
        if event.keyCode == UInt16(kVK_Escape) {
            dismissSuggestions()
            typedBuffer = ""
            return true
        }

        // Tab selects — suppress so target app doesn't move focus
        if event.keyCode == UInt16(kVK_Tab) {
            if let snippet = suggestionPanel.selectedSnippet() {
                let deleteCount = 1 + suggestionQuery.count // backslash + query
                dismissSuggestions()
                expand(snippet: snippet, deleteCount: deleteCount)
                typedBuffer = ""
            } else {
                dismissSuggestions()
            }
            return true
        }

        // Backspace — let through to target app (it needs to delete characters too)
        if event.keyCode == UInt16(kVK_Delete) {
            if suggestionQuery.isEmpty {
                // Query is empty — deleting the backslash, so dismiss
                dismissSuggestions()
                if !typedBuffer.isEmpty { typedBuffer.removeLast() }
            } else {
                suggestionQuery.removeLast()
                if !typedBuffer.isEmpty { typedBuffer.removeLast() }
                updateSuggestionResults()
            }
            return false
        }

        guard let character = typedCharacter(from: event) else {
            // No printable character (e.g. language switch, function key) — ignore
            return false
        }

        // Allow any character that is valid in a keyword (non-space); dismiss on space
        if isValidKeywordCharacter(character) {
            suggestionQuery.append(character)
            typedBuffer.append(character)
            trimBufferIfNeeded()
            updateSuggestionResults()
        } else {
            // Space or other disallowed character — dismiss suggestions
            dismissSuggestions()
            typedBuffer.append(character)
            trimBufferIfNeeded()
        }
        return false
    }

    private func updateSuggestionResults() {
        let snippets = store.enabledSnippetsSorted()

        let scored: [SuggestionItem]
        if suggestionQuery.isEmpty {
            // Show all enabled snippets when no query yet
            scored = snippets.prefix(8).map { SuggestionItem(snippet: $0, score: 0) }
        } else {
            scored = snippets.compactMap { snippet in
                let nameResult = FuzzyMatch.score(query: suggestionQuery, target: snippet.displayName)
                let keywordResult = FuzzyMatch.score(query: suggestionQuery, target: snippet.normalizedKeyword)
                let best = max(nameResult.score, keywordResult.score)
                let matched = nameResult.matched || keywordResult.matched
                guard matched else { return nil }
                return SuggestionItem(snippet: snippet, score: best)
            }
            .sorted { $0.score > $1.score }
            .prefix(8)
            .map { $0 }
        }

        if scored.isEmpty {
            suggestionPanel.dismiss()
        } else {
            suggestionPanel.show(items: Array(scored))
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

    private func isValidKeywordCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isNewline
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

    private func focusedElementIsTextInput() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success else {
            return false
        }
        let focused = focusedValue as! AXUIElement

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue) == .success else {
            return false
        }
        let role = roleValue as? String ?? ""

        return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }
}
