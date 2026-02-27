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
    private var accessibilityPrimedPIDs: Set<pid_t> = []
    private var enhancedAccessibilityPrimedPIDs: Set<pid_t> = []

    private var typedBuffer = ""
    private let maxBufferLength = 120
    private var isInjecting = false

    // Suggestion overlay state
    private var suggestionActive = false
    private var suggestionQuery = ""
    private lazy var suggestionPanel = SuggestionPanelController()
    private let optionDeleteWordCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    // On macOS some apps drop rapid synthetic key events; keep a small delay
    // between injected keystrokes to ensure trigger deletion is complete.
    private let injectedKeyDelay: TimeInterval = 0.012
    private let injectedPasteShortcutDelay: TimeInterval = 0.008
    private let prePasteDelayAfterDelete: TimeInterval = 0.02
    private let pasteboardWriteSettleDelay: TimeInterval = 0.012
    private let pasteboardRestoreDelay: Duration = .milliseconds(350)

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
        accessibilityPrimedPIDs.removeAll()
        enhancedAccessibilityPrimedPIDs.removeAll()
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

        // Fallback path for apps where focused text input detection fails
        // (for example, some custom editors). We still auto-expand on exact
        // keyword match, but without showing the suggestion panel.
        if autoExpandFromTypedBufferIfNeeded(typedCharacter: character) {
            return true
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

    private func selectSuggestion(_ snippet: Snippet, deleteCount overrideDeleteCount: Int? = nil) {
        let deleteCount = overrideDeleteCount ?? (1 + suggestionQuery.count) // backslash + query
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
        let command = event.modifierFlags.contains(.command)
        let option = event.modifierFlags.contains(.option)

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
        if ctrl && !command && !option && event.keyCode == UInt16(kVK_ANSI_H) {
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

        // Emacs Ctrl+W — delete previous word
        if ctrl && !command && !option && event.keyCode == UInt16(kVK_ANSI_W) {
            if suggestionQuery.isEmpty {
                dismissSuggestions()
                removeCharactersFromTypedBuffer(1)
            } else {
                let removedCount = removePreviousWordFromSuggestionQuery()
                removeCharactersFromTypedBuffer(removedCount)
                updateSuggestionResults()
            }
            return false
        }

        // Language/input-source switch (Cmd+Space, Ctrl+Space, Option+Space) — ignore without dismissing
        if event.keyCode == UInt16(kVK_Space) &&
            !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return false
        }

        // Dedicated exclusion: users often screenshot the suggestions panel itself.
        // Keep the session active for Cmd+Shift+3/4/5/6 (+optional Ctrl).
        if isScreenshotShortcut(event) {
            return false
        }

        // Dedicated Option+Delete handling:
        // in suggestion mode this should edit the query, not fall into the generic Option-dismiss path.
        if option && !command && event.keyCode == UInt16(kVK_Delete) {
            if suggestionQuery.isEmpty {
                dismissSuggestions()
                removeCharactersFromTypedBuffer(1)
            } else {
                let removedCount = removePreviousWordFromSuggestionQuery()
                removeCharactersFromTypedBuffer(removedCount)
                updateSuggestionResults()
            }
            return false
        }

        // Command/Option combos dismiss (Cmd+Z, Option produces special chars, etc.)
        if command || option {
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

        // Tab or Return selects — suppress so target app doesn't act on the key
        if event.keyCode == UInt16(kVK_Tab) || event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
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
            let previousQuery = suggestionQuery
            suggestionQuery.append(character)
            typedBuffer.append(character)
            trimBufferIfNeeded()

            // Auto-expand if the query is an unambiguous exact match
            if let snippet = unambiguousExactMatch(for: suggestionQuery) {
                // Consume this event: the host app has not yet inserted the final
                // character, so delete only the already-typed prefix.
                let deleteCount = 1 + previousQuery.count
                selectSuggestion(snippet, deleteCount: deleteCount)
                return true
            }

            updateSuggestionResults()
        } else {
            // Space or other disallowed character — dismiss suggestions
            dismissSuggestions()
            typedBuffer.append(character)
            trimBufferIfNeeded()
        }
        return false
    }

    /// Returns a snippet only if `query` exactly matches one keyword and no other keyword starts with `query`.
    private func unambiguousExactMatch(for query: String) -> Snippet? {
        let snippets = store.enabledSnippetsSorted()
        let lowered = query.lowercased()

        var exactMatch: Snippet?
        for snippet in snippets {
            let keyword = snippet.normalizedKeyword.lowercased()
            guard !keyword.isEmpty else { continue }

            if keyword == lowered {
                exactMatch = snippet
            } else if keyword.hasPrefix(lowered) {
                // Another keyword extends this one — ambiguous
                return nil
            }
        }
        return exactMatch
    }

    private func autoExpandFromTypedBufferIfNeeded(typedCharacter: Character) -> Bool {
        guard isValidKeywordCharacter(typedCharacter) else { return false }
        guard let query = trailingKeywordQuery(from: typedBuffer) else { return false }
        guard let snippet = unambiguousExactMatch(for: query) else { return false }

        // Current key-down has not been applied by the host app yet, so delete
        // only the already-typed prefix ("\" + query.dropLast()).
        let deleteCount = query.count
        expand(snippet: snippet, deleteCount: deleteCount)
        typedBuffer = ""
        return true
    }

    private func trailingKeywordQuery(from buffer: String) -> String? {
        guard let slashIndex = buffer.lastIndex(of: "\\") else { return nil }
        let queryStart = buffer.index(after: slashIndex)
        guard queryStart < buffer.endIndex else { return nil }

        let query = String(buffer[queryStart...])
        guard !query.isEmpty else { return nil }
        guard query.allSatisfy({ isValidKeywordCharacter($0) }) else { return nil }
        return query
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
            suggestionPanel.hide()
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

    private func isScreenshotShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control])
        guard flags.contains(.command), flags.contains(.shift) else { return false }

        switch event.keyCode {
        case UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6):
            return true
        default:
            return false
        }
    }

    private func removeCharactersFromTypedBuffer(_ count: Int) {
        guard count > 0, !typedBuffer.isEmpty else { return }
        typedBuffer.removeLast(min(count, typedBuffer.count))
    }

    private func removePreviousWordFromSuggestionQuery() -> Int {
        guard !suggestionQuery.isEmpty else { return 0 }

        let characters = Array(suggestionQuery)
        var end = characters.count

        // Match typical Option+Delete semantics:
        // drop trailing separators, then remove the previous word token.
        while end > 0 && !isOptionDeleteWordCharacter(characters[end - 1]) {
            end -= 1
        }

        while end > 0 && isOptionDeleteWordCharacter(characters[end - 1]) {
            end -= 1
        }

        let removedCount = characters.count - end
        suggestionQuery = String(characters.prefix(end))
        return removedCount
    }

    private func isOptionDeleteWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { optionDeleteWordCharacterSet.contains($0) }
    }


    private func isValidKeywordCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isNewline
    }


    private func expand(snippet: Snippet, deleteCount: Int) {
        guard deleteCount > 0 else { return }
        let adjustedDeleteCount = adjustedDeleteCountForActiveSelection(baseDeleteCount: deleteCount)

        let resolvedText = PlaceholderResolver.resolve(template: snippet.content)
        replaceTypedText(characterCount: adjustedDeleteCount, with: resolvedText)

        lastExpansionName = snippet.displayName
        statusText = "Expanded \(snippet.displayName)."
    }

    private func adjustedDeleteCountForActiveSelection(baseDeleteCount: Int) -> Int {
        guard baseDeleteCount > 0 else { return 0 }
        return focusedTextInputHasSelectedText() ? (baseDeleteCount + 1) : baseDeleteCount
    }

    private func replaceTypedText(characterCount: Int, with replacement: String) {
        isInjecting = true

        // Delete trigger text one character at a time with a small delay to avoid
        // dropped synthetic key events in some host apps.
        deleteBackward(characterCount: characterCount)
        if prePasteDelayAfterDelete > 0 {
            Thread.sleep(forTimeInterval: prePasteDelayAfterDelete)
        }
        paste(replacement)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.isInjecting = false
        }
    }

    private func deleteBackward(characterCount: Int) {
        guard characterCount > 0 else { return }
        for _ in 0..<characterCount {
            postKeyStroke(keyCode: UInt16(kVK_Delete), interKeyDelay: injectedKeyDelay)
        }
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = capturePasteboardState(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return
        }
        let injectedChangeCount = pasteboard.changeCount
        if pasteboardWriteSettleDelay > 0 {
            Thread.sleep(forTimeInterval: pasteboardWriteSettleDelay)
        }

        postPasteShortcut()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.pasteboardRestoreDelay ?? .milliseconds(350))
            // If user/app changed the clipboard since injection, keep the newer
            // content and do not restore our snapshot over it.
            guard pasteboard.changeCount == injectedChangeCount else { return }
            self?.restorePasteboardState(snapshot, to: pasteboard)
        }
    }

    private func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let commandKey = UInt16(kVK_Command)

        postKeyEvent(source: source, keyCode: commandKey, keyDown: true)
        if injectedPasteShortcutDelay > 0 {
            Thread.sleep(forTimeInterval: injectedPasteShortcutDelay)
        }
        postKeyEvent(source: source, keyCode: UInt16(kVK_ANSI_V), keyDown: true, flags: .maskCommand)
        postKeyEvent(source: source, keyCode: UInt16(kVK_ANSI_V), keyDown: false, flags: .maskCommand)
        if injectedPasteShortcutDelay > 0 {
            Thread.sleep(forTimeInterval: injectedPasteShortcutDelay)
        }
        postKeyEvent(source: source, keyCode: commandKey, keyDown: false)
    }

    private func postKeyStroke(keyCode: UInt16, flags: CGEventFlags = [], interKeyDelay: TimeInterval = 0) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        postKeyEvent(source: source, keyCode: keyCode, keyDown: true, flags: flags)
        postKeyEvent(source: source, keyCode: keyCode, keyDown: false, flags: flags)

        if interKeyDelay > 0 {
            Thread.sleep(forTimeInterval: interKeyDelay)
        }
    }

    private func postKeyEvent(source: CGEventSource, keyCode: UInt16, keyDown: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
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
        guard let focused = frontmostFocusedElement() else { return false }

        if elementAcceptsTextInput(focused) {
            return true
        }

        var current = focused
        for _ in 0..<4 {
            guard let parent = parentElement(of: current) else { break }
            if elementAcceptsTextInput(parent) {
                return true
            }
            current = parent
        }

        return false
    }

    private func focusedTextInputHasSelectedText() -> Bool {
        guard let focused = frontmostFocusedElement() else { return false }
        if selectedRangeLength(of: focused) > 0 { return true }
        if let selectedText = stringAttribute(of: focused, attribute: kAXSelectedTextAttribute as CFString),
           !selectedText.isEmpty {
            return true
        }

        var current = focused
        for _ in 0..<4 {
            guard let parent = parentElement(of: current) else { break }
            if selectedRangeLength(of: parent) > 0 { return true }
            if let selectedText = stringAttribute(of: parent, attribute: kAXSelectedTextAttribute as CFString),
               !selectedText.isEmpty {
                return true
            }
            current = parent
        }

        return false
    }

    private func frontmostFocusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        primeAccessibilityIfNeeded(for: app)

        if let focused = copyFocusedElement(from: app) {
            return deepestFocusedElement(startingAt: focused, maxDepth: 4)
        }

        // Retry once after forcing manual accessibility attributes for Chromium/Electron.
        primeAccessibilityIfNeeded(for: app, force: true)
        guard let focused = copyFocusedElement(from: app) else {
            return nil
        }
        return deepestFocusedElement(startingAt: focused, maxDepth: 4)
    }

    private func copyFocusedElement(from app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedValue as! AXUIElement)
    }

    private func deepestFocusedElement(startingAt root: AXUIElement, maxDepth: Int) -> AXUIElement {
        var current = root

        for _ in 0..<maxDepth {
            var nestedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXFocusedUIElementAttribute as CFString, &nestedValue) == .success,
                  let nestedValue,
                  CFGetTypeID(nestedValue) == AXUIElementGetTypeID() else {
                break
            }

            let nested = nestedValue as! AXUIElement
            if CFEqual(current, nested) {
                break
            }

            current = nested
        }

        return current
    }

    private func elementAcceptsTextInput(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(of: element, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(of: element, attribute: kAXSubroleAttribute as CFString) ?? ""

        if role == (kAXTextFieldRole as String) ||
            role == (kAXTextAreaRole as String) ||
            role == (kAXComboBoxRole as String) ||
            subrole == (kAXSearchFieldSubrole as String) {
            return true
        }

        if boolAttribute(of: element, attribute: "AXEditable" as CFString) == true {
            return true
        }

        // Chromium/Electron text controls often expose text-range attributes
        // even when the role isn't one of the standard text roles.
        if hasAttribute(kAXSelectedTextRangeAttribute as CFString, on: element) {
            return true
        }

        return false
    }

    private func stringAttribute(of element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(of element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func selectedRangeLength(of element: AXUIElement) -> Int {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return 0
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return 0
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return 0
        }

        return max(0, range.length)
    }

    private func hasAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var attributesValue: CFArray?
        guard AXUIElementCopyAttributeNames(element, &attributesValue) == .success,
              let attributesValue,
              let attributes = attributesValue as? [String] else {
            return false
        }

        return attributes.contains(attribute as String)
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func primeAccessibilityIfNeeded(for app: NSRunningApplication, force: Bool = false) {
        guard accessibilityGranted else { return }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        let shouldSetEnhancedUI = isChromiumFamily(bundleIdentifier: app.bundleIdentifier)
        let hasManualPriming = accessibilityPrimedPIDs.contains(pid)
        let hasEnhancedPriming = enhancedAccessibilityPrimedPIDs.contains(pid)

        if !force && hasManualPriming && (!shouldSetEnhancedUI || hasEnhancedPriming) {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Electron documents this explicit opt-in switch for third-party ATs.
        if force || !hasManualPriming {
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            accessibilityPrimedPIDs.insert(pid)
        }

        // Chromium apps may require this to expose complete accessibility data
        // for non-VoiceOver assistive tools.
        if shouldSetEnhancedUI && (force || !hasEnhancedPriming) {
            _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            enhancedAccessibilityPrimedPIDs.insert(pid)
        }
    }

    private func isChromiumFamily(bundleIdentifier: String?) -> Bool {
        ChromiumBundleIDSettings.isChromiumFamily(bundleIdentifier: bundleIdentifier)
    }
}
