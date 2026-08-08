import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class SnippetExpansionEngine {
    typealias SecureSnippetContentResolver = @MainActor (
        _ snippet: Snippet,
        _ authenticationReason: String
    ) async throws -> SecurePlaintextLease

    private(set) var accessibilityGranted = false { didSet { onStateChange?() } }
    private(set) var listening = false
    private(set) var lastExpansionName: String? { didSet { onStateChange?() } }
    private(set) var statusText = "Grant Accessibility permissions to start snippet expansion." { didSet { onStateChange?() } }

    var onStateChange: (() -> Void)?
    /// Supplied by the app layer so this engine can request one decrypted record without
    /// learning how the vault key is stored. The lease carries bytes rather than a
    /// `String`, and a secure shell never reaches injection unless this resolver returns
    /// after explicit authentication.
    var secureSnippetContentResolver: SecureSnippetContentResolver?

    private let store: SnippetStore
    private let usage: SnippetUsageStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var globalMouseMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var accessibilityPrimedPIDs: Set<pid_t> = []
    private var enhancedAccessibilityPrimedPIDs: Set<pid_t> = []

    private var typedBuffer = ""
    private let maxBufferLength = 120
    /// Counts overlapping expansions. As a plain `Bool` with a timed reset, an earlier expansion's
    /// timer could unlock user input while a later one was still writing into the host.
    private var injectionDepth = 0
    private var isInjecting: Bool { injectionDepth > 0 }
    private let injectionQueue = SnippetInjectionQueue()
    /// Bumped whenever the caret may have moved, so a queued delete count that no longer describes
    /// the text before it is discarded rather than applied to whatever is there now.
    private var injectionContextGeneration: UInt = 0
    private var activePasteboardLease: TemporaryPasteboardLease?
    private var suggestionSecureInputWatchdog: Timer?

    // Suggestion overlay state
    private var suggestionActive = false
    private var suggestionQuery = ""
    private var suggestionDeleteCount = 1
    private var suggestionLocalFallbackUsable = false
    private var suggestionHasSyncedAXContext = false
    private var suggestionSyncGeneration = 0
    /// Non-nil only while LocalAuthentication is servicing an explicit secure
    /// suggestion. Its own activation/secure-input transitions must not invalidate
    /// the target we are about to restore and re-check.
    private var secureSuggestionAuthenticationTargetPID: pid_t?
    /// Survives the prompt itself until the authenticated insertion finishes. NSWorkspace
    /// sometimes delivers the restored target's activation notification late; only
    /// that exact PID gets this grace, while activating any other app still cancels.
    private var secureExpansionActivationTargetPID: pid_t?
    /// Frozen for the lifetime of one suggestion session so the three refreshes
    /// per keystroke cannot reshuffle rows under the user's fingers.
    private var suggestionFrecency: FrecencySnapshot = .empty
    /// The query the user had typed when they accepted from the panel, held
    /// only until `expand()` consumes it. Never set on an auto-expand path.
    private var pendingSelectionMemoryQuery: String?
    private lazy var suggestionPanel = SuggestionPanelController()
    // Host apps can apply text edits asynchronously; reread focused text more
    // than once before trusting the suggestion context for expansion.
    private let suggestionTextSyncDelays: [Duration] = [
        .milliseconds(18),
        .milliseconds(60)
    ]
    /// LocalAuthentication can return just before the host regains its focused AX
    /// element. During this bounded handoff, keep polling; only an exact fresh match
    /// authorizes deletion, so transient system-UI focus cannot cause a blind write.
    private let secureSuggestionRevalidationDelays: [Duration] = [
        .zero,
        .milliseconds(60),
        .milliseconds(120),
        .milliseconds(220),
        .milliseconds(400),
        .milliseconds(700)
    ]
    // On macOS some apps drop rapid synthetic key events; keep a small delay
    // between injected keystrokes to ensure trigger deletion is complete.
    private let injectedKeyDelay: Duration = .milliseconds(12)
    private let prePasteDelayAfterDelete: Duration = .milliseconds(20)
    private let pasteboardWriteSettleDelay: Duration = .milliseconds(12)
    // AX calls into a beachballing host block for ~6s by default, which is
    // long enough for macOS to disable our event tap. Bound every AX message
    // we send so the tap callback can always return quickly.
    private let axMessagingTimeoutSeconds: Float = 0.4
    // A slow answer is worthless in a progress probe, and paying the full timeout on every poll is
    // exactly what gets the tap disabled.
    private let confirmationAXMessagingTimeoutSeconds: Float = 0.1
    // Bounds on what may be rewritten wholesale. A browser's address bar holds one URL and sits a
    // few levels under its window; anything longer, multi-line, or deeper is not the field this
    // strategy was measured against.
    private let maxBrowserChromeValueLength = 8192
    private let maxBrowserChromeAncestorDepth = 16
    private let pasteConfirmationTuning = SnippetPasteConfirmationPolicy.Tuning.default

    private enum FocusedSelection {
        case none
        case text(String)
        case unreadable(length: Int)

        var hasSelection: Bool {
            switch self {
            case .none:
                return false
            case .text, .unreadable:
                return true
            }
        }
    }

    private enum ExpansionAuthorization {
        case ordinary
        case authenticatedSecure

        var authenticatesSecureSnippet: Bool { self == .authenticatedSecure }
        var concealsPasteboard: Bool { self == .authenticatedSecure }
    }

    private enum FocusedTriggerContextRead {
        case found(SuggestionTriggerContext)
        case missingTrigger
        case unavailable
    }

    private enum SecureDeletionRevalidation {
        case confirmed(TriggerDeletion)
        case contextChanged
        case secureInputDidNotSettle
        case triggerNotConfirmed
    }

    /// The exact host control that owned keyboard focus when a secure suggestion was
    /// accepted. LocalAuthentication can leave the host process frontmost while its
    /// sheet still owns keyboard focus, so a PID alone is not a safe insertion target.
    private struct SecureExpansionFocusTarget {
        let element: AXUIElement
        let window: AXUIElement?
    }

    init(store: SnippetStore, usage: SnippetUsageStore) {
        self.store = store
        self.usage = usage
        refreshAccessibilityStatus(prompt: false)
    }

    func startIfNeeded() {
        if eventTap == nil {
            installEventTap()
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(
                    event: event,
                    eventUserData: event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                )
                return event
            }
        }

        // A mouse click moves the caret (or focus), so previously typed
        // characters no longer sit before it — any tracked trigger state
        // would delete unrelated text. Global monitors observe without
        // consuming, which is all we need.
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                guard let self,
                      SnippetInjectionGate.pointerInteractionInvalidatesContext(
                          secureAuthenticationTargetPID: self.secureSuggestionAuthenticationTargetPID)
                else { return }
                self.resetTypingContext()
            }
        }

        // Switching apps (Cmd+Tab, Dock, Spotlight, …) also invalidates the
        // typing context even without a click.
        if workspaceActivationObserver == nil {
            workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Delivered on the main queue, so the isolation is real rather than assumed away.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let activatedPID = (
                        notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication
                    )?.processIdentifier
                    if SnippetInjectionGate.applicationActivationInvalidatesContext(
                        activatedPID: activatedPID,
                        currentFrontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        ownPID: ProcessInfo.processInfo.processIdentifier,
                        secureAuthenticationTargetPID: self.secureSuggestionAuthenticationTargetPID,
                        secureExpansionTargetPID: self.secureExpansionActivationTargetPID,
                        secureEventInputEnabled: self.secureEventInputEnabled
                    ) {
                        self.resetTypingContext()
                    }
                }
            }
        }

        listening = true
        refreshAccessibilityStatus(prompt: false)
    }

    /// The typed buffer and suggestion session describe text immediately
    /// before the caret; once the caret or focus may have moved, that state
    /// must not authorize deletions any more.
    private func resetTypingContext() {
        typedBuffer = ""
        // Anything already queued was measured against a caret that has since moved.
        injectionContextGeneration &+= 1
        dismissSuggestions()
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
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<SnippetExpansionEngine>.fromOpaque(refcon).takeUnretainedValue()

                // macOS disables the tap if the callback stalls (timeout) or on
                // user-input protection; without re-enabling here the tap stays
                // dead until app restart and expansion silently stops.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    engine.reenableEventTap()
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }

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

    /// Called from the CGEvent tap callback on the main thread when macOS
    /// reports the tap as disabled (`.tapDisabledByTimeout` /
    /// `.tapDisabledByUserInput`).
    nonisolated private func reenableEventTap() {
        MainActor.assumeIsolated {
            guard let tap = eventTap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Called from the CGEvent tap callback on the main thread.
    /// Returns `true` if the event should be suppressed (consumed by us).
    nonisolated private func handleEventTap(_ cgEvent: CGEvent) -> Bool {
        // Read the marker before bridging to NSEvent: our own injection is the hot path here — one
        // event per deleted character, plus the paste shortcut — and must cost nothing.
        let eventUserData = cgEvent.getIntegerValueField(.eventSourceUserData)
        // Never `true`. Consuming our own backspace would break the very expansion we are running.
        guard SnippetSyntheticEvent.origin(eventUserData: eventUserData) == .user else { return false }

        // We're on the main thread (run loop), so we can safely access
        // MainActor-isolated state via MainActor.assumeIsolated.
        return MainActor.assumeIsolated {
            guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return false }
            return handle(event: nsEvent, eventUserData: eventUserData)
        }
    }

    func requestAccessibilityPermission() {
        refreshAccessibilityStatus(prompt: true)
    }

    private func restartEventMonitors() {
        injectionContextGeneration &+= 1
        injectionQueue.cancelAll()
        stopSuggestionSecureInputWatchdog()
        finishPendingPasteboardOwnership()
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
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let observer = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceActivationObserver = nil
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
            if secureEventInputEnabled {
                // Names the cause, because the flag is global: another app can hold it on and leave
                // expansion silently dead with nothing else to go on.
                statusText = "Paused while an app has secure keyboard entry on."
            } else {
                statusText = listening ? "Listening for snippet keywords in all apps." : "Ready to start listening."
            }
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

    func chromiumBundleIDSettingsDidChange() {
        accessibilityPrimedPIDs.removeAll()
        enhancedAccessibilityPrimedPIDs.removeAll()
        suggestionPanel.resetAccessibilityPrimingCache()

        guard accessibilityGranted, let app = NSWorkspace.shared.frontmostApplication else { return }
        primeAccessibilityIfNeeded(for: app, force: true)
    }


    func copySnippetToClipboard(_ snippet: Snippet) {
        // An explicit copy is the user taking the clipboard back; hand it over before reading
        // `{clipboard}`, or the snippet would resolve against a snippet we are still holding.
        finishPendingPasteboardOwnership()
        let rendered = PlaceholderResolver.resolve(template: snippet.content)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rendered, forType: .string)

        usage.record(.copyFromApp, snippetID: snippet.id)
        lastExpansionName = snippet.displayName
        statusText = "Copied \(snippet.displayName)."
    }

    func pasteSnippetIntoFrontmostApp(_ snippet: Snippet) {
        finishPendingPasteboardOwnership()
        let rendered = PlaceholderResolver.resolve(template: snippet.content)

        if frontmostProcessIsThisApp() {
            NSApp.hide(nil)
        }

        // Raised for the whole trip, which the old code never did: this path posts a synthetic
        // Cmd+V too, and it used to come back through our own tap unguarded.
        beginInjection()
        injectionQueue.enqueue(isAutomatic: false) { [weak self] in
            guard let self else { return }
            defer { self.endInjection() }
            guard !Task.isCancelled else { return }
            await self.settle(for: .milliseconds(140))
            // Read after hiding: hiding ourselves activates another app, which bumps the generation.
            let delivered = await self.replaceTypedText(
                characterCount: 0,
                with: rendered,
                generation: self.injectionContextGeneration,
                targetPID: nil
            )
            guard delivered else {
                self.statusText = "Could not paste \(snippet.displayName)."
                return
            }
            self.usage.record(.pasteFromApp, snippetID: snippet.id)
            self.lastExpansionName = snippet.displayName
            self.statusText = "Pasted \(snippet.displayName)."
        }
    }

    /// Synchronous on purpose: `applicationWillTerminate` cannot await, and leaving the process with
    /// a snippet still sitting in the user's clipboard is exactly what the lease exists to prevent.
    func prepareForTermination() {
        injectionContextGeneration &+= 1
        injectionQueue.cancelAll()
        finishPendingPasteboardOwnership()
    }

    func releaseBorrowedPasteboard() {
        finishPendingPasteboardOwnership()
    }

    /// Returns `true` if the event was consumed and should be suppressed.
    @discardableResult
    private func handle(event: NSEvent, eventUserData: Int64?) -> Bool {
        let origin = SnippetSyntheticEvent.origin(eventUserData: eventUserData)
        let isAuthenticatingSecureSuggestion = secureSuggestionAuthenticationTargetPID != nil
        switch SnippetInjectionGate.inputDisposition(
            origin: origin,
            secureEventInputEnabled: secureEventInputEnabled,
            isListening: listening,
            isInjecting: isInjecting,
            ownAppIsFrontmost: frontmostProcessIsThisApp(),
            isAuthenticatingSecureSuggestion: isAuthenticatingSecureSuggestion
        ) {
        case .ignore:
            // Real typing during an injection moves the text our queued delete counts were measured
            // against, so they must not be applied afterwards. LocalAuthentication's
            // password events are the exception: they never reached the target, and
            // that target plus its exact trigger are revalidated after the prompt.
            if origin == .user, isInjecting, !isAuthenticatingSecureSuggestion {
                injectionContextGeneration &+= 1
            }
            return false
        case .resetAndPassThrough:
            resetTypingContext()
            return false
        case .process:
            break
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
        suggestionDeleteCount = 1
        suggestionLocalFallbackUsable = true
        suggestionHasSyncedAXContext = false
        suggestionFrecency = usage.makeRankingSnapshot()
        pendingSelectionMemoryQuery = nil

        suggestionPanel.onSelect = { [weak self] snippet in
            self?.selectSuggestion(snippet)
        }
        suggestionPanel.onDismiss = { [weak self] in
            self?.dismissSuggestions()
        }

        updateSuggestionResults()
        scheduleSuggestionContextRefresh(allowAutoExpand: false, dismissOnMissingTrigger: false)
        startSuggestionSecureInputWatchdog()
    }

    /// Secure Event Input stops key events reaching a session tap at all, so the usual dismissal
    /// paths go quiet exactly when they are needed: the panel would sit over the password prompt
    /// and the query typed next to it would stay in memory. Scoped to a live session so a menu-bar
    /// app is not waking the run loop for a window that lasts seconds.
    private func startSuggestionSecureInputWatchdog() {
        guard suggestionSecureInputWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.secureEventInputEnabled else { return }
                self.resetTypingContext()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        suggestionSecureInputWatchdog = timer
    }

    private func stopSuggestionSecureInputWatchdog() {
        suggestionSecureInputWatchdog?.invalidate()
        suggestionSecureInputWatchdog = nil
    }

    private func selectSuggestion(_ snippet: Snippet, deletion overrideDeletion: TriggerDeletion? = nil) {
        if let overrideDeletion {
            // Auto-expand callers pass a deletion from a context they
            // just synced; expand with it directly.
            dismissSuggestions()
            enqueueExpansion(of: snippet, deletion: overrideDeletion)
            typedBuffer = ""
            return
        }

        acceptSelectedSuggestion(snippet)
    }

    /// How a fresh AX read relates to the query the user accepted.
    private enum AcceptContextRead {
        /// Carries the context itself: the Accessibility path needs the trigger text, not just its
        /// length, to prove what sits before the caret before it overwrites anything.
        case confirmed(SuggestionTriggerContext)
        case mismatch
        case missingTrigger
        case unavailable
        /// The host text before the caret contains multi-scalar graphemes;
        /// no backspace count is reliable there.
        case unsafe

        var isConfirmed: Bool {
            if case .confirmed = self { return true }
            return false
        }
    }

    private func readAcceptContext(matchingQuery query: String) -> AcceptContextRead {
        switch focusedTriggerContext() {
        case .found(let context):
            // Even a confirming AX read may carry a different scalar
            // composition than what was typed (e.g. decomposed form);
            // refuse to count backspaces over multi-scalar graphemes.
            if containsMultiScalarGrapheme(context.query) {
                return .unsafe
            }
            if normalizedForSuggestionMatching(context.query) == normalizedForSuggestionMatching(query) {
                return .confirmed(context)
            }
            return .mismatch
        case .missingTrigger:
            return .missingTrigger
        case .unavailable:
            return .unavailable
        }
    }

    /// Accepts an explicit user selection (Tab/Return or a click in the
    /// panel). The snippet must be captured by the caller BEFORE any context
    /// refresh so that re-ranking can never change what the user picked.
    ///
    /// The delete count is taken from a fresh AX read only when that read
    /// confirms the accepted query; async hosts (Electron/Slack) often have
    /// not applied the last keystrokes to AX yet, so unconfirmed reads are
    /// retried with the same delays as the regular resync path
    /// (`suggestionTextSyncDelays`) before falling back to the locally
    /// tracked count.
    private func acceptSelectedSuggestion(_ snippet: Snippet) {
        let localQuery = suggestionQuery
        let localFallbackUsable = suggestionLocalFallbackUsable
        let hadSyncedAXContext = suggestionHasSyncedAXContext
        let acceptedGeneration = injectionContextGeneration
        let acceptedTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let acceptedFocusTarget = store.isSecure(snippet.id)
            ? captureSecureExpansionFocusTarget(targetPID: acceptedTargetPID)
            : nil

        // Captured before `dismissSuggestions()` clears the query. Only an
        // explicit accept teaches selection memory; auto-expansions never do.
        pendingSelectionMemoryQuery = localQuery

        dismissSuggestions()

        // Multi-scalar graphemes (ZWJ emoji, flags, combining marks) in the
        // query make the backspace count unreliable in web hosts — skip the
        // accept instead of corrupting host text.
        guard !containsMultiScalarGrapheme(localQuery) else {
            // Without this the query would outlive the abandoned accept and be
            // attributed to whatever expanded next — including an auto-expand,
            // which must never write a binding.
            pendingSelectionMemoryQuery = nil
            return
        }

        // Ignore key events while the short confirmation reads run, exactly
        // as a synchronous expansion did by blocking the run loop.
        beginInjection()

        Task { @MainActor [weak self] in
            guard let self else { return }

            var lastRead = self.readAcceptContext(matchingQuery: localQuery)
            for delay in self.suggestionTextSyncDelays where !lastRead.isConfirmed {
                try? await Task.sleep(for: delay)
                // Secure input can come up mid-read; nothing we send afterwards would reach the host.
                guard !self.secureEventInputEnabled else {
                    self.pendingSelectionMemoryQuery = nil
                    self.endInjection()
                    return
                }
                lastRead = self.readAcceptContext(matchingQuery: localQuery)
            }

            let deletion: TriggerDeletion?
            switch lastRead {
            case .confirmed(let context):
                deletion = .confirmed(context)
            case .missingTrigger:
                // AX previously showed this trigger and no longer does — the
                // host text really changed, so deleting anything would be
                // blind. Only trust local tracking if AX never synced at all.
                deletion = (hadSyncedAXContext || !localFallbackUsable)
                    ? nil
                    : .localTracking(query: localQuery)
            case .mismatch, .unavailable:
                // AX is behind or unreadable; trust local tracking while it
                // has stayed authoritative.
                deletion = localFallbackUsable ? .localTracking(query: localQuery) : nil
            case .unsafe:
                // No backspace count is reliable over multi-scalar graphemes.
                deletion = nil
            }

            guard let deletion, deletion.characterCount > 0 else {
                // Nothing can vouch for the text before the caret — abort
                // rather than delete blindly.
                self.pendingSelectionMemoryQuery = nil
                self.endInjection()
                return
            }
            if self.store.isSecure(snippet.id) {
                await self.authenticateAndPerformSecureExpansion(
                    shell: snippet,
                    query: localQuery,
                    acceptedGeneration: acceptedGeneration,
                    acceptedTargetPID: acceptedTargetPID,
                    acceptedFocusTarget: acceptedFocusTarget)
            } else {
                self.enqueueExpansion(of: snippet, deletion: deletion)
            }
            self.endInjection()
        }
    }

    /// Turns a content-free secure shell into a one-use expansion only after the user
    /// authenticates. The prompt can remain open for seconds, so the pre-prompt delete
    /// count is never reused: the original app, focused control, generation, and exact
    /// trigger are all checked again before plaintext is converted to a String or inserted.
    private func authenticateAndPerformSecureExpansion(
        shell: Snippet,
        query: String,
        acceptedGeneration: UInt,
        acceptedTargetPID: pid_t?,
        acceptedFocusTarget: SecureExpansionFocusTarget?
    ) async {
        guard let resolver = secureSnippetContentResolver else {
            pendingSelectionMemoryQuery = nil
            statusText = "Secure expansion is not configured."
            return
        }
        guard let targetPID = acceptedTargetPID,
              let focusTarget = acceptedFocusTarget,
              targetPID != ProcessInfo.processInfo.processIdentifier,
              acceptedGeneration == injectionContextGeneration,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
              currentFocusMatches(focusTarget.element)
        else {
            pendingSelectionMemoryQuery = nil
            statusText = "Skipped \(shell.displayName): the original input field is no longer focused."
            return
        }

        let targetName = NSRunningApplication(processIdentifier: targetPID)?.localizedName
            ?? "the current app"
        let reason = "Insert \u{201C}\(shell.displayName)\u{201D} into \(targetName)"
        statusText = "Waiting for authentication to expand \(shell.displayName)\u{2026}"
        secureSuggestionAuthenticationTargetPID = targetPID
        secureExpansionActivationTargetPID = targetPID
        defer {
            if secureSuggestionAuthenticationTargetPID == targetPID {
                secureSuggestionAuthenticationTargetPID = nil
            }
            if secureExpansionActivationTargetPID == targetPID {
                secureExpansionActivationTargetPID = nil
            }
        }

        let plaintext: SecurePlaintextLease
        do {
            plaintext = try await resolver(shell, reason)
        } catch {
            pendingSelectionMemoryQuery = nil
            statusText = "Could not expand \(shell.displayName): \(error)"
            return
        }
        defer { plaintext.wipe() }

        guard await restoreSecureExpansionTarget(
            targetPID: targetPID,
            acceptedGeneration: acceptedGeneration,
            focusTarget: focusTarget)
        else {
            pendingSelectionMemoryQuery = nil
            statusText = "Skipped \(shell.displayName): Snippets could not restore the original input field after authentication."
            return
        }

        let revalidation = await confirmedSecureDeletionAfterAuthentication(
            query: query,
            acceptedGeneration: acceptedGeneration,
            targetPID: targetPID,
            focusTarget: focusTarget)
        let deletion: TriggerDeletion
        switch revalidation {
        case .confirmed(let confirmed):
            deletion = confirmed
        case .contextChanged:
            pendingSelectionMemoryQuery = nil
            statusText = "Skipped \(shell.displayName): the target app changed during authentication."
            return
        case .secureInputDidNotSettle:
            pendingSelectionMemoryQuery = nil
            statusText = "Skipped \(shell.displayName): macOS did not release secure keyboard entry."
            return
        case .triggerNotConfirmed:
            pendingSelectionMemoryQuery = nil
            statusText = "Skipped \(shell.displayName): the original trigger was no longer at the cursor."
            return
        }

        // Password/Touch ID input is over, so real user input must invalidate the
        // freshly confirmed trigger again. The activation grace remains until the
        // direct insertion finishes, but applies only while this exact target is still
        // genuinely frontmost.
        if secureSuggestionAuthenticationTargetPID == targetPID {
            secureSuggestionAuthenticationTargetPID = nil
        }

        let refusal = SnippetInjectionGate.refusal(
            secureEventInputEnabled: secureEventInputEnabled,
            isSecureSnippet: store.isSecure(shell.id),
            secureSnippetIsAuthenticated: true,
            isListening: listening,
            ownAppIsFrontmost: frontmostProcessIsThisApp(),
            deleteCount: deletion.characterCount)
        guard deletion.isSelfConsistent,
              store.isSecure(shell.id),
              refusal == nil
        else {
            pendingSelectionMemoryQuery = nil
            statusText = "Skipped \(shell.displayName): secure insertion was no longer available."
            return
        }

        // We already hold the outer `beginInjection()` from accepting the suggestion.
        // Running directly removes the task-queue handoff that let a delayed workspace
        // notification invalidate every other otherwise-valid Touch ID expansion.
        await performExpansion(
            of: shell,
            deletion: deletion,
            bindingQuery: consumePendingSelectionMemoryQuery(),
            generation: acceptedGeneration,
            targetPID: targetPID,
            authorization: .authenticatedSecure,
            securePlaintext: plaintext,
            secureFocusTarget: focusTarget)
    }

    private func restoreSecureExpansionTarget(
        targetPID: pid_t,
        acceptedGeneration: UInt,
        focusTarget: SecureExpansionFocusTarget
    ) async -> Bool {
        guard acceptedGeneration == injectionContextGeneration,
              listening,
              let target = NSRunningApplication(processIdentifier: targetPID),
              !target.isTerminated
        else { return false }

        // Do this even when the target already reports as frontmost. The LocalAuthentication
        // sheet can disappear from NSWorkspace first and keep the real keyboard focus for a
        // little longer; activation plus an explicit AX focus write closes that race.
        _ = target.activate()
        var consecutiveFocusConfirmations = 0
        for delay in [
            Duration.milliseconds(80),
            .milliseconds(100),
            .milliseconds(160),
            .milliseconds(300),
            .milliseconds(500),
            .milliseconds(500)
        ] {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  acceptedGeneration == injectionContextGeneration,
                  listening
            else { return false }

            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                _ = target.activate()
                continue
            }

            _ = target.activate()
            if restoreKeyboardFocus(to: focusTarget, targetPID: targetPID) {
                // The authentication agent and the host can briefly disagree about
                // who owns keyboard focus while the sheet animates away. Require the
                // same system-wide answer twice, separated by a real run-loop turn.
                consecutiveFocusConfirmations += 1
                if consecutiveFocusConfirmations >= 2 { return true }
            } else {
                consecutiveFocusConfirmations = 0
            }
        }
        return false
    }

    private func confirmedSecureDeletionAfterAuthentication(
        query: String,
        acceptedGeneration: UInt,
        targetPID: pid_t,
        focusTarget: SecureExpansionFocusTarget
    ) async -> SecureDeletionRevalidation {
        for delay in secureSuggestionRevalidationDelays {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  acceptedGeneration == injectionContextGeneration,
                  listening,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
            else { return .contextChanged }

            // LocalAuthentication can release its sheet a fraction before Secure Event
            // Input and the focused AX element settle. During this bounded handoff even
            // a readable mismatch can belong to the disappearing system UI. Nothing is
            // authorized until a later read proves the exact original trigger again.
            if secureEventInputEnabled { continue }
            guard restoreKeyboardFocus(to: focusTarget, targetPID: targetPID) else {
                continue
            }
            switch readAcceptContext(matchingQuery: query) {
            case .confirmed(let context):
                return .confirmed(.confirmed(context))
            case .unavailable, .mismatch, .missingTrigger:
                continue
            case .unsafe:
                return .triggerNotConfirmed
            }
        }
        return secureEventInputEnabled ? .secureInputDidNotSettle : .triggerNotConfirmed
    }

    private func dismissSuggestions() {
        typedBuffer = ""
        // Before the guard: another path may have already cleared `suggestionActive`, and the timer
        // would then outlive the session it belongs to.
        stopSuggestionSecureInputWatchdog()

        guard suggestionActive else { return }
        suggestionActive = false
        suggestionQuery = ""
        suggestionDeleteCount = 1
        suggestionLocalFallbackUsable = false
        suggestionHasSyncedAXContext = false
        suggestionSyncGeneration += 1
        suggestionFrecency = .empty
        suggestionPanel.dismiss()
    }

    /// Returns `true` if the event should be suppressed (consumed by us).
    private func handleSuggestionEvent(_ event: NSEvent) -> Bool {
        let ctrl = event.modifierFlags.contains(.control)
        let command = event.modifierFlags.contains(.command)
        let option = event.modifierFlags.contains(.option)

        // Arrow keys / Ctrl+N/P navigate the list - suppress so target app doesn't see them
        if event.keyCode == UInt16(kVK_DownArrow) || (ctrl && event.keyCode == UInt16(kVK_ANSI_N)) {
            guard suggestionPanel.hasSelectableItems else { return false }
            suggestionPanel.moveSelectionDown()
            return true
        }
        if event.keyCode == UInt16(kVK_UpArrow) || (ctrl && event.keyCode == UInt16(kVK_ANSI_P)) {
            guard suggestionPanel.hasSelectableItems else { return false }
            suggestionPanel.moveSelectionUp()
            return true
        }

        // Ctrl+C cancels suggestion mode while still letting the host handle
        // the shortcut (copy/cancel/interruption depending on the app).
        if ctrl && !command && !option && event.keyCode == UInt16(kVK_ANSI_C) {
            typedBuffer = ""
            dismissSuggestions()
            return false
        }

        // Emacs Ctrl+H - treat as backspace
        if ctrl && !command && !option && event.keyCode == UInt16(kVK_ANSI_H) {
            applyLocalSuggestionBackspace()
            scheduleSuggestionContextRefresh(allowAutoExpand: false, dismissOnMissingTrigger: true)
            return false
        }

        // Emacs Ctrl+W - let the host edit, then read the real text before the caret.
        if ctrl && !command && !option && event.keyCode == UInt16(kVK_ANSI_W) {
            suggestionLocalFallbackUsable = false
            scheduleSuggestionContextRefresh(allowAutoExpand: false, dismissOnMissingTrigger: true)
            return false
        }

        // Language/input-source switch (Cmd+Space, Ctrl+Space, Option+Space) - ignore without dismissing
        if event.keyCode == UInt16(kVK_Space) &&
            !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return false
        }

        // Dedicated exclusion: users often screenshot the suggestions panel itself.
        // Keep the session active for Cmd+Shift+3/4/5/6 (+optional Ctrl).
        if isScreenshotShortcut(event) {
            return false
        }

        // Host apps do not agree on word boundaries, so let the app delete and
        // then resync from AX instead of trying to model the shortcut.
        if option && !command && event.keyCode == UInt16(kVK_Delete) {
            suggestionLocalFallbackUsable = false
            scheduleSuggestionContextRefresh(allowAutoExpand: false, dismissOnMissingTrigger: true)
            return false
        }

        // Command/Option combos dismiss (Cmd+Z, Option produces special chars, etc.)
        if command || option {
            typedBuffer = ""
            dismissSuggestions()
            return false
        }

        // Other Ctrl combos and function keys - let the host handle them, then
        // refresh in case the shortcut moved the caret or edited text.
        if ctrl {
            suggestionLocalFallbackUsable = false
            scheduleSuggestionContextRefresh(allowAutoExpand: false, dismissOnMissingTrigger: true)
            return false
        }

        // Escape dismisses - suppress
        if event.keyCode == UInt16(kVK_Escape) {
            dismissSuggestions()
            typedBuffer = ""
            return true
        }

        // Tab or Return selects - suppress so target app doesn't act on the key
        if event.keyCode == UInt16(kVK_Tab) || event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            // Capture the user's explicit selection BEFORE anything can
            // refresh the context and re-rank the list underneath them.
            guard let snippet = suggestionPanel.selectedSnippet() else {
                dismissSuggestions()
                return true
            }
            acceptSelectedSuggestion(snippet)
            return true
        }

        // Backspace - let through to target app (it needs to delete characters too)
        if event.keyCode == UInt16(kVK_Delete) {
            applyLocalSuggestionBackspace()
            scheduleSuggestionContextRefresh(allowAutoExpand: false, dismissOnMissingTrigger: true)
            return false
        }

        // Navigation and function keys report characters in the Unicode
        // function-key range (U+F700–U+F8FF, e.g. NSLeftArrowFunctionKey).
        // Those pass isValidKeywordCharacter but are not query text — they
        // must never be appended to suggestionQuery.
        if isFunctionKeyEvent(event) {
            switch event.keyCode {
            case UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow),
                 UInt16(kVK_Home), UInt16(kVK_End),
                 UInt16(kVK_PageUp), UInt16(kVK_PageDown):
                // The caret moves, so the tracked delete count no longer
                // describes the text before it — end the session and let the
                // host handle the key.
                dismissSuggestions()
                return false
            default:
                // Pure function keys (F1–F19, forward delete, …) don't edit
                // the text before the caret; pass them through untouched.
                return false
            }
        }

        guard let character = typedCharacter(from: event) else {
            // No printable character (e.g. language switch, function key) - ignore
            return false
        }

        // Let the host apply printable text, then resync from the focused AX text.
        if isValidKeywordCharacter(character) {
            appendLocalSuggestionCharacter(character)
            scheduleSuggestionContextRefresh(allowAutoExpand: true, dismissOnMissingTrigger: true)
        } else {
            dismissSuggestions()
        }
        return false
    }

    private func scheduleSuggestionContextRefresh(
        allowAutoExpand: Bool,
        dismissOnMissingTrigger: Bool
    ) {
        suggestionSyncGeneration += 1
        let generation = suggestionSyncGeneration
        let delays = suggestionTextSyncDelays

        Task { @MainActor [weak self] in
            var lastRefreshResult: SuggestionContextRefreshResult = .unavailable
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(for: delay)
                guard let self,
                      self.suggestionActive,
                      self.suggestionSyncGeneration == generation,
                      !self.isInjecting else {
                    return
                }

                let isLastAttempt = index == delays.count - 1
                lastRefreshResult = self.refreshSuggestionContextFromFocusedText(
                    allowAutoExpand: allowAutoExpand && isLastAttempt,
                    dismissOnMissingTrigger: dismissOnMissingTrigger
                )

                if lastRefreshResult == .missingTrigger || !self.suggestionActive {
                    return
                }
            }

            guard let self,
                  self.suggestionActive,
                  self.suggestionSyncGeneration == generation,
                  !self.isInjecting else {
                return
            }
            if lastRefreshResult == .unavailable {
                if self.suggestionLocalFallbackUsable {
                    self.handleUnavailableRefreshWithLocalFallback(allowAutoExpand: allowAutoExpand)
                } else if dismissOnMissingTrigger {
                    self.abandonUnsafeSuggestionContext()
                }
            }
        }
    }

    private func abandonUnsafeSuggestionContext() {
        typedBuffer = ""
        dismissSuggestions()
    }

    private func appendLocalSuggestionCharacter(_ character: Character) {
        guard suggestionActive, suggestionLocalFallbackUsable else { return }
        suggestionQuery.append(character)
        suggestionDeleteCount = 1 + suggestionQuery.count
        updateSuggestionResults()
    }

    private func applyLocalSuggestionBackspace() {
        guard suggestionActive, suggestionLocalFallbackUsable else { return }

        if suggestionQuery.isEmpty {
            dismissSuggestions()
            return
        }

        suggestionQuery.removeLast()
        suggestionDeleteCount = 1 + suggestionQuery.count
        updateSuggestionResults()
    }

    private func handleUnavailableRefreshWithLocalFallback(allowAutoExpand: Bool) {
        guard suggestionActive, suggestionLocalFallbackUsable else { return }

        if allowAutoExpand,
           !suggestionQuery.isEmpty,
           let snippet = unambiguousExactMatch(for: suggestionQuery) {
            selectSuggestion(snippet, deletion: .localTracking(query: suggestionQuery))
            return
        }

        updateSuggestionResults()
    }

    @discardableResult
    private func refreshSuggestionContextFromFocusedText(
        allowAutoExpand: Bool,
        dismissOnMissingTrigger: Bool
    ) -> SuggestionContextRefreshResult {
        guard suggestionActive else { return .missingTrigger }

        switch focusedTriggerContext() {
        case .found(let context):
            suggestionQuery = context.query
            suggestionDeleteCount = context.triggerLength
            suggestionLocalFallbackUsable = true
            suggestionHasSyncedAXContext = true

            if allowAutoExpand,
               !context.query.isEmpty,
               let snippet = unambiguousExactMatch(for: context.query) {
                selectSuggestion(snippet, deletion: .confirmed(context))
                return .synced
            }

            updateSuggestionResults()
            return .synced

        case .missingTrigger:
            if suggestionLocalFallbackUsable && !suggestionHasSyncedAXContext {
                if allowAutoExpand {
                    handleUnavailableRefreshWithLocalFallback(allowAutoExpand: true)
                }
                return .localFallback
            }

            if dismissOnMissingTrigger {
                typedBuffer = ""
                dismissSuggestions()
            }
            return .missingTrigger

        case .unavailable:
            if suggestionLocalFallbackUsable {
                if allowAutoExpand {
                    handleUnavailableRefreshWithLocalFallback(allowAutoExpand: true)
                }
                return .localFallback
            }
            return .unavailable
        }
    }

    /// Returns a snippet only if `query` exactly matches one keyword and no other keyword starts with `query`.
    private func unambiguousExactMatch(for query: String) -> Snippet? {
        // The delete count for auto-expansion is derived from this query;
        // multi-scalar graphemes make that count unreliable in web hosts.
        guard !containsMultiScalarGrapheme(query) else { return nil }

        let snippets = store.enabledSnippetsSorted()
        let normalizedQuery = normalizedForSuggestionMatching(query)

        var exactMatches: [Snippet] = []
        var hasLongerPrefix = false
        for snippet in snippets {
            let keyword = normalizedForSuggestionMatching(snippet.normalizedKeyword)
            guard !keyword.isEmpty else { continue }

            if keyword == normalizedQuery {
                exactMatches.append(snippet)
            } else if keyword.hasPrefix(normalizedQuery) {
                hasLongerPrefix = true
            }
        }

        guard exactMatches.count == 1, !hasLongerPrefix else { return nil }
        return exactMatches[0]
    }

    private func autoExpandFromTypedBufferIfNeeded(typedCharacter: Character) -> Bool {
        guard isValidKeywordCharacter(typedCharacter) else { return false }
        guard let query = trailingKeywordQuery(from: typedBuffer) else { return false }
        guard let snippet = unambiguousExactMatch(for: query) else { return false }

        typedBuffer = ""
        // Current key-down has not been applied by the host app yet, so delete
        // only the already-typed prefix ("\" + query.dropLast()).
        enqueueExpansion(of: snippet, deletion: .pendingLastCharacter(query: query))
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
        let snippets = enabledSnippetsForSuggestionDisplay()
        let displayOrder = Dictionary(
            uniqueKeysWithValues: snippets.enumerated().map { ($0.element.id, $0.offset) }
        )

        let scored: [SuggestionItem]
        if suggestionQuery.isEmpty {
            // Pinned first, then most used, then the library's own order. The
            // cap is applied after ranking; it used to slice the first eight in
            // creation order and present that as the top eight.
            scored = snippets
                .enumerated()
                .sorted { lhs, rhs in
                    SnippetFrecency.emptyQueryRanks(
                        lhsPinned: lhs.element.isPinned,
                        lhsFrecency: suggestionFrecency.value(for: lhs.element.id),
                        lhsOrder: lhs.offset,
                        rhsPinned: rhs.element.isPinned,
                        rhsFrecency: suggestionFrecency.value(for: rhs.element.id),
                        rhsOrder: rhs.offset
                    )
                }
                .prefix(8)
                .map {
                    SuggestionItem(
                        snippet: $0.element,
                        isSecure: store.isSecure($0.element.id),
                        score: 0,
                        frecency: suggestionFrecency.value(for: $0.element.id)
                    )
                }
        } else {
            let foldedQuery = SnippetFrecency.foldedForMatching(suggestionQuery)
            let binding = suggestionFrecency.bindingTable(forQuery: suggestionQuery)

            scored = snippets.compactMap { snippet -> SuggestionItem? in
                let nameResult = FuzzyMatch.score(query: suggestionQuery, target: snippet.displayName)
                let keywordResult = FuzzyMatch.score(query: suggestionQuery, target: snippet.normalizedKeyword)
                let best = max(nameResult.score, keywordResult.score)
                let matched = nameResult.matched || keywordResult.matched
                guard matched else { return nil }
                return SuggestionItem(
                    snippet: snippet,
                    isSecure: store.isSecure(snippet.id),
                    score: best,
                    nameMatchRanges: nameResult.matchedRanges,
                    keywordMatchRanges: keywordResult.matchedRanges,
                    keywordRank: SnippetFrecency.keywordRank(
                        foldedKeyword: SnippetFrecency.foldedForMatching(snippet.normalizedKeyword),
                        foldedQuery: foldedQuery,
                        hasKeywordMatchRanges: !keywordResult.matchedRanges.isEmpty
                    ),
                    bindingWeight: binding[snippet.id] ?? 0,
                    frecency: suggestionFrecency.value(for: snippet.id)
                )
            }
            // Decorate-sort-undecorate: each key is built once per element.
            // Deriving it inside the sort closure would mean O(N log N)
            // constructions, each retaining a String and a UUID.
            .map { (key: rankingKey(for: $0, displayOrder: displayOrder), item: $0) }
            .sorted { SnippetFrecency.ranks($0.key, before: $1.key) }
            .prefix(8)
            .map { $0.item }
        }

        if scored.isEmpty {
            suggestionPanel.hide()
        } else {
            suggestionPanel.show(items: Array(scored))
        }
    }

    private func enabledSnippetsForSuggestionDisplay() -> [Snippet] {
        store.snippetsSortedForDisplay()
            .filter { $0.isEnabled && !$0.normalizedKeyword.isEmpty }
    }

    private func rankingKey(for item: SuggestionItem, displayOrder: [UUID: Int]) -> SnippetRankingKey {
        SnippetRankingKey(
            score: item.score,
            keywordRank: item.keywordRank,
            isPinned: item.snippet.isPinned,
            bindingWeight: item.bindingWeight,
            frecency: item.frecency,
            displayOrder: displayOrder[item.snippet.id] ?? Int.max,
            displayName: item.snippet.displayName,
            id: item.snippet.id
        )
    }

    private func normalizedForSuggestionMatching(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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

    private func isValidKeywordCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isNewline
    }

    /// Trigger deletion is injected as one backspace per Swift Character
    /// (grapheme), but Chromium-family hosts delete multi-scalar graphemes
    /// (ZWJ emoji, flag sequences, combining marks) one scalar per backspace.
    /// A grapheme count is then the wrong unit, so expansion is skipped for
    /// such triggers rather than risking leftover fragments in host text.
    private func containsMultiScalarGrapheme(_ string: String) -> Bool {
        string.contains { $0.unicodeScalars.count > 1 }
    }

    /// True when the event carries a character from the Unicode function-key
    /// range (U+F700–U+F8FF): arrows, Home/End, Page Up/Down, F-keys, forward
    /// delete, … The `.function` modifier alone is not used as the signal
    /// because fn-modified events can still carry ordinary text characters.
    private func isFunctionKeyEvent(_ event: NSEvent) -> Bool {
        guard let scalar = event.characters?.unicodeScalars.first else { return false }
        return (0xF700...0xF8FF).contains(scalar.value)
    }


    // MARK: - Injection

    private func beginInjection() {
        injectionDepth += 1
    }

    private func endInjection() {
        injectionDepth = max(0, injectionDepth - 1)
    }

    /// The one place an expansion is scheduled. Callers stay synchronous — a tap callback has to
    /// return its suppress decision immediately — while delivery runs on the queue afterwards.
    private func enqueueExpansion(
        of snippet: Snippet,
        deletion: TriggerDeletion,
        authorization: ExpansionAuthorization = .ordinary,
        expectedGeneration: UInt? = nil,
        expectedTargetPID: pid_t? = nil,
        securePlaintext: SecurePlaintextLease? = nil
    ) {
        // Consumed on every attempt, recorded only on the ones that commit.
        let bindingQuery = consumePendingSelectionMemoryQuery()
        let isSecureSnippet = store.isSecure(snippet.id)
        let refusal = SnippetInjectionGate.refusal(
            secureEventInputEnabled: secureEventInputEnabled,
            isSecureSnippet: isSecureSnippet,
            secureSnippetIsAuthenticated: authorization.authenticatesSecureSnippet,
            isListening: listening,
            ownAppIsFrontmost: frontmostProcessIsThisApp(),
            deleteCount: deletion.characterCount)
        let payloadMatchesAuthorization = authorization.authenticatesSecureSnippet
            ? (isSecureSnippet && securePlaintext != nil)
            : securePlaintext == nil
        guard deletion.isSelfConsistent, refusal == nil, payloadMatchesAuthorization else {
            securePlaintext?.wipe()
            if authorization.authenticatesSecureSnippet,
               secureExpansionActivationTargetPID == expectedTargetPID {
                secureExpansionActivationTargetPID = nil
            }
            if refusal == .secureSnippetRequiresAuthentication {
                statusText = "Secure snippets never expand automatically. Choose one in suggestions to authenticate."
            }
            return
        }

        let generation = expectedGeneration ?? injectionContextGeneration
        let targetPID = expectedTargetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        // An expansion still waiting its turn was measured against text the one now starting is
        // about to rewrite. Cancelling is a no-op once a unit is past its start check.
        injectionQueue.cancelAutomatic()
        // Raised synchronously, so a key arriving before the unit starts is already ignored.
        beginInjection()
        injectionQueue.enqueue(isAutomatic: true) { [weak self, securePlaintext] in
            // Covers cancellation before `performExpansion` starts as well as every
            // early return inside it. `wipe()` is intentionally idempotent.
            defer { securePlaintext?.wipe() }
            guard let self else { return }
            // Paired with the `beginInjection()` above, and released on every exit — a stranded
            // count would leave user input ignored until the app restarts.
            defer {
                if authorization.authenticatesSecureSnippet,
                   self.secureExpansionActivationTargetPID == targetPID {
                    self.secureExpansionActivationTargetPID = nil
                }
                self.endInjection()
            }
            guard !Task.isCancelled else { return }
            await self.performExpansion(
                of: snippet,
                deletion: deletion,
                bindingQuery: bindingQuery,
                generation: generation,
                targetPID: targetPID,
                authorization: authorization,
                securePlaintext: securePlaintext,
                secureFocusTarget: nil
            )
        }
    }

    private func performExpansion(
        of snippet: Snippet,
        deletion: TriggerDeletion,
        bindingQuery: String?,
        generation: UInt,
        targetPID: pid_t?,
        authorization: ExpansionAuthorization,
        securePlaintext: SecurePlaintextLease?,
        secureFocusTarget: SecureExpansionFocusTarget?
    ) async {
        // Defense in depth for any future caller that bypasses the queue wrapper.
        defer { securePlaintext?.wipe() }
        if let block = injectionBlockDescription(generation: generation, targetPID: targetPID) {
            if authorization.authenticatesSecureSnippet {
                statusText = "Skipped \(snippet.displayName): \(block)."
            }
            return
        }
        if let secureFocusTarget,
           !restoreKeyboardFocus(to: secureFocusTarget, targetPID: targetPID) {
            statusText = "Skipped \(snippet.displayName): the original input field did not regain keyboard focus."
            return
        }
        // `{clipboard}` has to see the user's clipboard, never a snippet we are still holding.
        finishPendingPasteboardOwnership()

        var resolvedText: String
        if let securePlaintext {
            guard let text = resolvedSecureText(consuming: securePlaintext) else {
                statusText = "Could not expand \(snippet.displayName): its secure content is not valid UTF-8."
                return
            }
            resolvedText = text
        } else {
            resolvedText = PlaceholderResolver.resolve(template: snippet.content)
        }
        // Swift strings cannot be securely zeroed. Dropping our last intentional
        // reference at the narrowest scope is the strongest truthful guarantee here;
        // the controlled raw-byte lease above has already been explicitly zeroed.
        defer {
            if authorization.authenticatesSecureSnippet {
                resolvedText.removeAll(keepingCapacity: false)
            }
        }

        // Nothing to insert, so insert nothing — and crucially, do not delete first.
        //
        // Both write paths below start by removing the trigger the user typed. With an
        // empty replacement every verification downstream passes vacuously, so the
        // expansion is recorded as a success while the visible result is that the user's
        // typing silently disappeared. An empty snippet is easy to reach: a draft with no
        // body yet, or a secure record whose content resolved to nothing.
        guard !resolvedText.isEmpty else {
            statusText = "\(snippet.displayName) is empty — nothing to insert. Your text was left as you typed it."
            return
        }

        let replacement = replaceUsingAccessibility(
            deletion: deletion,
            with: resolvedText,
            expectedFocusedElement: secureFocusTarget?.element)
        switch AccessibilityReplacementPolicy.action(for: replacement, provenance: deletion.provenance) {
        case .commit:
            recordExpansion(of: snippet, bindingQuery: bindingQuery)
            return
        case .abort:
            statusText = "Skipped \(snippet.displayName): the text before the cursor changed."
            return
        case .useEvents:
            break
        }

        let deleteCount = adjustedDeleteCountForActiveSelection(baseDeleteCount: deletion.characterCount)
        guard await replaceTypedText(
            characterCount: deleteCount,
            with: resolvedText,
            generation: generation,
            targetPID: targetPID,
            isConcealed: authorization.concealsPasteboard,
            expectedFocusedElement: secureFocusTarget?.element
        ) else {
            if authorization.authenticatesSecureSnippet {
                statusText = "Authentication succeeded, but Snippets could not insert \(snippet.displayName)."
            }
            return
        }
        recordExpansion(of: snippet, bindingQuery: bindingQuery)
    }

    /// Materializes secure bytes only for placeholder resolution, then zeroes the
    /// controlled buffer before any Accessibility or pasteboard call begins.
    private func resolvedSecureText(consuming plaintext: SecurePlaintextLease) -> String? {
        guard var template = plaintext.makeUTF8String() else {
            plaintext.wipe()
            return nil
        }
        plaintext.wipe()
        defer { template.removeAll(keepingCapacity: false) }
        return PlaceholderResolver.resolve(template: template)
    }

    /// The single point that means "the host's text changed" — every earlier stage can still abort
    /// without touching it, and must not be counted as a use.
    private func recordExpansion(of snippet: Snippet, bindingQuery: String?) {
        usage.record(.expansion, snippetID: snippet.id, bindingQuery: bindingQuery)
        lastExpansionName = snippet.displayName
        statusText = "Expanded \(snippet.displayName)."
    }

    private func injectionIsAllowed(generation: UInt, targetPID: pid_t?) -> Bool {
        injectionBlockDescription(generation: generation, targetPID: targetPID) == nil
    }

    private func injectionBlockDescription(generation: UInt, targetPID: pid_t?) -> String? {
        if generation != injectionContextGeneration { return "the input context changed before insertion" }
        if !listening { return "global expansion stopped before insertion" }
        if secureEventInputEnabled { return "macOS still had secure keyboard entry enabled" }
        guard let targetPID else {
            return frontmostProcessIsThisApp() ? "Snippets itself became the target" : nil
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            return "another app became active before insertion"
        }
        return nil
    }

    /// Process-global: true when *any* process has secure keyboard entry on, not only the frontmost
    /// one. Not thread safe per its Carbon header — every call site here is on the main actor.
    private var secureEventInputEnabled: Bool { IsSecureEventInputEnabled() }

    /// Reads and clears in one step, so one accepted query can never be
    /// attributed to two expansions.
    private func consumePendingSelectionMemoryQuery() -> String? {
        defer { pendingSelectionMemoryQuery = nil }
        return pendingSelectionMemoryQuery
    }

    private func adjustedDeleteCountForActiveSelection(baseDeleteCount: Int) -> Int {
        guard baseDeleteCount > 0 else { return 0 }
        return focusedTextInputHasSelectedText() ? (baseDeleteCount + 1) : baseDeleteCount
    }

    // MARK: - Accessibility replacement

    /// The preferred path: one atomic replacement, no synthetic events, no clipboard involvement.
    /// Synchronous on purpose — the read that proves what sits before the caret and the write that
    /// replaces it have to happen in the same turn, or the proof means nothing.
    private func replaceUsingAccessibility(
        deletion: TriggerDeletion,
        with replacement: String,
        expectedFocusedElement: AXUIElement?
    ) -> AccessibilityReplacement {
        guard accessibilityGranted,
              deletion.isSelfConsistent,
              let app = NSWorkspace.shared.frontmostApplication
        else { return .unavailable }

        let strategy = accessibilityWriteStrategy(for: app)
        guard strategy != .none,
              // Only the focused element, never an ancestor: reading from a parent is safe, writing
              // into one is not.
              let element = frontmostFocusedElement(),
              expectedFocusedElement.map({ CFEqual(element, $0) }) ?? true,
              let caret = selectedRange(of: element),
              caret.location >= 0, caret.length >= 0
        else { return .unavailable }

        let caretRange = NSRange(location: caret.location, length: caret.length)
        // Enough text that a trigger made of surrogate pairs cannot be clipped by the read window.
        let readLength = max(maxBufferLength, deletion.expectedText.utf16.count + 8)
        guard let before = textBeforeCaret(
            in: element,
            caretLocation: caret.location,
            maxCharacters: readLength,
            allowFullValueFallback: true
        ) else { return .unavailable }

        let planResult = AccessibilityTextReplacement.plan(
            textBeforeCaret: before,
            caretRange: caretRange,
            expectedTrigger: deletion.expectedText,
            triggerCharacterCount: deletion.characterCount,
            replacementUTF16Length: replacement.utf16.count
        )
        guard case .plan(let plan) = planResult else {
            return planResult == .rejected ? .rejected : .unavailable
        }

        if strategy == .wholeValue {
            // Proven here rather than in the policy: it takes Accessibility reads, and they are
            // wasted on every host that is not Chromium.
            guard elementIsBrowserChrome(element) else { return .unavailable }
            return replaceWholeValueUsingAccessibility(
                element: element,
                plan: plan,
                replacement: replacement
            )
        }

        // Checked after the text comparison, not before: a mismatch has to fail closed even in a
        // field we cannot write, otherwise it would fall through to deleting somebody else's text.
        guard isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element),
              isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
        else { return .unavailable }

        let valueBefore = stringAttribute(of: element, attribute: kAXValueAttribute as CFString)

        guard setSelectedRange(plan.replacementRange, on: element) else { return .unavailable }
        guard setSelectedText(replacement, on: element) else {
            // Leaving the trigger selected would make the event fallback's first backspace eat it
            // and every following one eat a character of the user's text.
            _ = setSelectedRange(caretRange, on: element)
            return .rejected
        }
        // WebKit and Chromium can leave the inserted text selected, so the next keystroke would wipe
        // the snippet out. Collapse explicitly.
        _ = setSelectedRange(NSRange(location: plan.caretLocation, length: 0), on: element)

        guard let valueBefore else { return .delivered }
        guard let valueAfter = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) else {
            // Readable before the write and not after: too little to justify a second attempt.
            return .rejected
        }
        if AccessibilityTextReplacement.writeLanded(
            valueBefore: valueBefore,
            valueAfter: valueAfter,
            plan: plan,
            replacement: replacement
        ) { return .delivered }

        if valueAfter == valueBefore {
            // A write that reported success and did nothing — the Chromium/Electron failure mode.
            _ = setSelectedRange(caretRange, on: element)
            return .unavailable
        }
        return .rejected
    }

    /// Chromium's answer: rewrite the field's whole value, because that is the write its edit model
    /// hears. Only ever reached for a target `elementIsBrowserChrome` has vouched for — a one-line
    /// field in the browser's own UI, where "the whole value" is a URL, not somebody's document.
    private func replaceWholeValueUsingAccessibility(
        element: AXUIElement,
        plan: AccessibilityTextReplacement.Plan,
        replacement: String
    ) -> AccessibilityReplacement {
        guard isAttributeSettable(kAXValueAttribute as CFString, on: element),
              let valueBefore = stringAttribute(of: element, attribute: kAXValueAttribute as CFString)
        else { return .unavailable }

        // The plan was measured against the caret range, so a value that disagrees with it is a
        // model we do not understand — not something to overwrite wholesale.
        let text = valueBefore as NSString
        guard plan.replacementRange.location >= 0,
              NSMaxRange(plan.replacementRange) <= text.length
        else { return .unavailable }

        let newValue = text.replacingCharacters(in: plan.replacementRange, with: replacement)
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newValue as CFString
        ) == .success else { return .unavailable }

        guard let valueAfter = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) else {
            // Readable before the write and not after: too little to justify a second attempt.
            return .rejected
        }

        if AccessibilityTextReplacement.writeLanded(
            valueBefore: valueBefore,
            valueAfter: valueAfter,
            plan: plan,
            replacement: replacement
        ) {
            // Moved only once the value is provably ours. `plan.caretLocation` is an offset into the
            // text we meant to write, so placing the caret before that proof would leave it somewhere
            // arbitrary in the old text — and the event fallback would then backspace from there,
            // eating the user's characters instead of the trigger. This path never touches the
            // selection on any other exit, so there is nothing to restore.
            _ = setSelectedRange(NSRange(location: plan.caretLocation, length: 0), on: element)
            return .delivered
        }

        if valueAfter == valueBefore {
            // A write that reported success and did nothing — the Chromium/Electron failure mode.
            return .unavailable
        }
        // The field holds something we did not write. Saying `.unavailable` here would invite the
        // event path to paste on top of it.
        return .rejected
    }

    /// Guards the whole-value write: true only for a single-line text field belonging to the
    /// application's own interface, never for rendered page content.
    ///
    /// Inside a web area `AXValue` is a flattened rendition of the DOM. Writing it back would strip
    /// a rich editor down to plain text and desynchronize every field whose framework owns its
    /// value — the same class of bug as the omnibox, reintroduced on the web.
    ///
    /// So the walk demands positive evidence — the chain has to arrive at the application element
    /// without passing through a web area. Absence of a web area is not the same claim: a parent
    /// read that fails answers `nil` exactly like the top of the tree does, and a page field one
    /// unreadable link below its `AXWebArea` would pass a test written that way.
    private func elementIsBrowserChrome(_ element: AXUIElement) -> Bool {
        guard stringAttribute(of: element, attribute: kAXRoleAttribute as CFString) == (kAXTextFieldRole as String)
        else { return false }

        if let value = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) {
            guard value.utf16.count <= maxBrowserChromeValueLength,
                  !value.contains(where: \.isNewline)
            else { return false }
        }

        var current = element
        for _ in 0..<maxBrowserChromeAncestorDepth {
            guard let parent = parentElement(of: current),
                  let role = stringAttribute(of: parent, attribute: kAXRoleAttribute as CFString)
            else { return false }

            if role == "AXWebArea" { return false }
            if role == (kAXApplicationRole as String) { return true }
            current = parent
        }
        return false
    }

    /// Reads the user's switches; the decision itself lives in `AccessibilityInsertionPolicy`.
    private func accessibilityWriteStrategy(
        for app: NSRunningApplication
    ) -> AccessibilityInsertionPolicy.Strategy {
        let defaults = UserDefaults.standard
        let key = "SnippetsAccessibilityInsertionEnabled"
        let bundleID = app.bundleIdentifier
        return AccessibilityInsertionPolicy.strategy(
            bundleID: bundleID,
            globallyEnabled: defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key),
            hostIsChromiumFamily: ChromiumBundleIDSettings.isChromiumFamily(bundleIdentifier: bundleID),
            excludedBundleIDs: defaults.stringArray(forKey: "SnippetsAccessibilityInsertionExcludedBundleIDs") ?? []
        )
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    private func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    // MARK: - Event fallback

    /// Returns `true` once the paste has been posted; only then may the caller record a use.
    private func replaceTypedText(
        characterCount: Int,
        with replacement: String,
        generation: UInt,
        targetPID: pid_t?,
        isConcealed: Bool = false,
        expectedFocusedElement: AXUIElement? = nil
    ) async -> Bool {
        guard injectionIsAllowed(generation: generation, targetPID: targetPID),
              expectedFocusedElement.map(currentFocusMatches) ?? true
        else { return false }
        // Borrowed before a single character is deleted: a pasteboard we cannot borrow safely must
        // cost the user nothing, and once the trigger is gone "nothing" is no longer on the table.
        guard beginPasteboardLease(placing: replacement, isConcealed: isConcealed) else {
            return false
        }

        // Delete trigger text one character at a time with a small delay to avoid
        // dropped synthetic key events in some host apps.
        for index in 0..<characterCount {
            guard injectionIsAllowed(generation: generation, targetPID: targetPID),
                  expectedFocusedElement.map(currentFocusMatches) ?? true
            else {
                finishPendingPasteboardOwnership()
                return false
            }
            postKeyStroke(keyCode: UInt16(kVK_Delete))
            if index < characterCount - 1 {
                await settle(for: injectedKeyDelay)
            }
        }
        // Past here the trigger is gone, so bailing out would leave the user with neither their text
        // nor the snippet. These waits are deliberately not cancellable: a cancelled `Task.sleep`
        // returns at once and would rush the paste into a host still applying our deletions.
        if characterCount > 0 { await settle(for: injectedKeyDelay) }
        await settle(for: prePasteDelayAfterDelete)
        await settle(for: pasteboardWriteSettleDelay)

        guard let lease = activePasteboardLease, lease.isOwned else {
            finishPendingPasteboardOwnership()
            return false
        }
        guard expectedFocusedElement.map(currentFocusMatches) ?? true else {
            finishPendingPasteboardOwnership()
            return false
        }
        let baseline = focusedCaretFingerprint()
        postPasteShortcut()
        await waitForPasteConfirmation(
            pastedText: replacement,
            baseline: baseline,
            lease: lease,
            targetPID: targetPID
        )
        finishPendingPasteboardOwnership()
        return true
    }

    /// Holds the borrowed pasteboard until there is evidence the host applied the paste. A fixed
    /// delay cannot be right for both: it is ten times too long for a native field and still too
    /// short for a loaded Electron host, where restoring first makes the user's own clipboard land
    /// in the document instead of the snippet.
    private func waitForPasteConfirmation(
        pastedText: String,
        baseline: PasteCaretFingerprint?,
        lease: TemporaryPasteboardLease,
        targetPID: pid_t?
    ) async {
        var baseline = baseline
        var sawReadableFingerprintAfterPaste = false
        var firstForwardEditAttempt: Int?
        let start = ContinuousClock.now
        var attempt = 0

        while true {
            let abort = pasteConfirmationAbort(lease: lease, targetPID: targetPID)
            let current = abort == nil ? focusedCaretFingerprint() : nil
            if current != nil { sawReadableFingerprintAfterPaste = true }

            let progress = SnippetPasteConfirmationPolicy.progress(
                before: baseline,
                after: current,
                pastedText: pastedText,
                tailLength: pasteConfirmationTuning.fingerprintTailLength
            )
            if progress == .forwardEditObserved, firstForwardEditAttempt == nil {
                firstForwardEditAttempt = attempt
            }

            let verdict = SnippetPasteConfirmationPolicy.verdict(
                SnippetPasteConfirmationPolicy.Input(
                    attempt: attempt,
                    elapsed: start.duration(to: .now),
                    progress: progress,
                    hadFingerprintBeforePaste: baseline != nil,
                    sawReadableFingerprintAfterPaste: sawReadableFingerprintAfterPaste,
                    firstForwardEditAttempt: firstForwardEditAttempt,
                    abort: abort
                ),
                tuning: pasteConfirmationTuning
            )
            switch verdict {
            case .confirmed, .timedOut, .abandoned:
                return
            case .keepWaiting:
                break
            }

            // Our own backspaces can still be landing. Re-baseline, or the caret moving back and
            // then forward again would read as a paste that has not happened yet.
            if progress == .pendingEditObserved, let current { baseline = current }
            await settle(for: pasteConfirmationTuning.pollInterval)
            attempt += 1
        }
    }

    /// Ordered cheapest first; the Accessibility read is the expensive part and comes last.
    private func pasteConfirmationAbort(
        lease: TemporaryPasteboardLease,
        targetPID: pid_t?
    ) -> PasteConfirmationAbort? {
        if !lease.isOwned { return .pasteboardSuperseded }
        if secureEventInputEnabled { return .secureInputEnabled }
        if let targetPID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            // Hand the clipboard back rather than hold it: the user switching away and pressing
            // Cmd+V themselves is likelier than a late paste into an app they already left.
            return .frontmostAppChanged
        }
        return nil
    }

    private func beginPasteboardLease(placing text: String, isConcealed: Bool = false) -> Bool {
        // A previous lease still held would become this one's "original", losing the user's
        // clipboard for good.
        guard finishPendingPasteboardOwnership() else { return false }
        guard let lease = TemporaryPasteboardLease.begin(
            text: text,
            pasteboard: NSPasteboard.general,
            isConcealed: isConcealed
        ) else { return false }
        activePasteboardLease = lease
        return true
    }

    @discardableResult
    private func finishPendingPasteboardOwnership() -> Bool {
        guard let lease = activePasteboardLease else { return true }
        for _ in 0..<3 {
            guard lease.isOwned else { break }
            if case .failed = lease.restoreIfOwned() { continue }
            break
        }
        guard !lease.isOwned else { return false }
        activePasteboardLease = nil
        return true
    }

    private func focusedCaretFingerprint() -> PasteCaretFingerprint? {
        guard let element = frontmostFocusedElement(),
              let range = selectedRange(of: element),
              range.location >= 0
        else { return nil }
        AXUIElementSetMessagingTimeout(element, confirmationAXMessagingTimeoutSeconds)
        // Never the whole value: in a real editor that is the entire document, re-serialized over
        // Accessibility IPC on every poll.
        let tail = textBeforeCaret(
            in: element,
            caretLocation: range.location,
            maxCharacters: pasteConfirmationTuning.fingerprintTailLength,
            allowFullValueFallback: false
        ) ?? ""
        return PasteCaretFingerprint(
            caretLocation: range.location,
            selectionLength: max(0, range.length),
            textBeforeCaret: tail
        )
    }

    private func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let commandKey = UInt16(kVK_Command)

        // One uninterrupted burst: a suspension between Command down and up would leave the host
        // believing Command is held, turning the user's next keystroke into a shortcut.
        postKeyEvent(source: source, keyCode: commandKey, keyDown: true)
        postKeyEvent(source: source, keyCode: UInt16(kVK_ANSI_V), keyDown: true, flags: .maskCommand)
        postKeyEvent(source: source, keyCode: UInt16(kVK_ANSI_V), keyDown: false, flags: .maskCommand)
        postKeyEvent(source: source, keyCode: commandKey, keyDown: false)
    }

    private func postKeyStroke(keyCode: UInt16, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        postKeyEvent(source: source, keyCode: keyCode, keyDown: true, flags: flags)
        postKeyEvent(source: source, keyCode: keyCode, keyDown: false, flags: flags)
    }

    private func postKeyEvent(source: CGEventSource, keyCode: UInt16, keyDown: Bool, flags: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        event.flags = flags
        tag(event)
        event.post(tap: .cghidEventTap)
    }

    /// Everything we post carries this marker. Our events come back through our own session tap, and
    /// the tap keys off the marker to skip them instead of guessing by elapsed time.
    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: SnippetSyntheticEvent.tag)
    }

    /// A pause that survives cancellation, unlike `Task.sleep`, which returns immediately once the
    /// task is cancelled — the worst possible timing in the middle of an injection.
    private func settle(for duration: Duration) async {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
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
        return focusedTextInputSelection().hasSelection
    }

    private func focusedTextInputSelection() -> FocusedSelection {
        guard let focused = frontmostFocusedElement() else { return .none }

        let focusedSelection = selectionState(of: focused)
        if focusedSelection.hasSelection {
            return focusedSelection
        }

        var current = focused
        for _ in 0..<4 {
            guard let parent = parentElement(of: current) else { break }
            let parentSelection = selectionState(of: parent)
            if parentSelection.hasSelection {
                return parentSelection
            }
            current = parent
        }

        return .none
    }

    private func focusedTriggerContext() -> FocusedTriggerContextRead {
        guard let focused = frontmostFocusedElement() else { return .unavailable }

        for element in focusedTextContextCandidates(startingAt: focused) {
            guard let textBeforeCaret = textBeforeCaret(in: element, maxCharacters: maxBufferLength) else {
                continue
            }

            // The first readable candidate is authoritative: injected
            // backspaces land in the actually focused field, so a trigger
            // found in an ancestor's unrelated text must never authorize a
            // deletion here. Keep walking ancestors only while candidates
            // are unreadable.
            if let context = SuggestionTriggerContext.context(inTextBeforeCaret: textBeforeCaret) {
                return .found(context)
            }
            return .missingTrigger
        }

        return .unavailable
    }

    private func focusedTextContextCandidates(startingAt element: AXUIElement) -> [AXUIElement] {
        var elements: [AXUIElement] = [element]
        var current = element

        for _ in 0..<4 {
            guard let parent = parentElement(of: current) else { break }
            elements.append(parent)
            current = parent
        }

        return elements
    }

    private func textBeforeCaret(in element: AXUIElement, maxCharacters: Int) -> String? {
        guard let selectedRange = selectedRange(of: element), selectedRange.location >= 0 else {
            return nil
        }
        return textBeforeCaret(
            in: element,
            caretLocation: selectedRange.location,
            maxCharacters: maxCharacters,
            allowFullValueFallback: true
        )
    }

    /// Split out so a caller can pin the text and the caret offset to one observation, and so the
    /// confirmation poll can opt out of the whole-value fallback.
    private func textBeforeCaret(
        in element: AXUIElement,
        caretLocation: Int,
        maxCharacters: Int,
        allowFullValueFallback: Bool
    ) -> String? {
        guard caretLocation >= 0 else { return nil }
        let start = max(0, caretLocation - maxCharacters)
        let length = caretLocation - start
        let rangeBeforeCaret = CFRange(location: start, length: length)

        if let text = stringForRange(of: element, range: rangeBeforeCaret) {
            return text
        }

        return stringValueBeforeCaret(of: element, caretLocation: caretLocation, maxCharacters: maxCharacters)
    }

    private func stringForRange(of element: AXUIElement, range: CFRange) -> String? {
        guard range.length > 0 else { return "" }

        var requestedRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &requestedRange) else {
            return nil
        }

        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else {
            return nil
        }

        return value as? String
    }

    private func stringValueBeforeCaret(
        of element: AXUIElement,
        caretLocation: Int,
        maxCharacters: Int
    ) -> String? {
        guard let value = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) else {
            return nil
        }

        let nsValue = value as NSString
        let boundedLocation = min(max(0, caretLocation), nsValue.length)
        let start = max(0, boundedLocation - maxCharacters)
        return nsValue.substring(with: NSRange(location: start, length: boundedLocation - start))
    }

    private func selectionState(of element: AXUIElement) -> FocusedSelection {
        if let text = stringAttribute(of: element, attribute: kAXSelectedTextAttribute as CFString),
           !text.isEmpty {
            return .text(text)
        }

        let selectionLength = selectedRangeLength(of: element)
        if selectionLength > 0 {
            return .unreadable(length: selectionLength)
        }

        return .none
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

    private func captureSecureExpansionFocusTarget(targetPID: pid_t?) -> SecureExpansionFocusTarget? {
        guard let targetPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
              let element = frontmostFocusedElement()
        else { return nil }

        return SecureExpansionFocusTarget(
            element: element,
            window: elementAttribute(of: element, attribute: kAXWindowAttribute as CFString)
                ?? ancestorWindow(of: element)
        )
    }

    /// Reasserts both the host window and its original control. Merely observing the
    /// application as frontmost is insufficient while a biometric/password sheet is
    /// handing keyboard ownership back to the host.
    private func restoreKeyboardFocus(
        to focusTarget: SecureExpansionFocusTarget,
        targetPID: pid_t?
    ) -> Bool {
        guard let targetPID,
              !secureEventInputEnabled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        else { return false }

        let appElement = withBoundedMessagingTimeout(AXUIElementCreateApplication(targetPID))
        if let window = focusTarget.window {
            _ = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                window
            )
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        _ = AXUIElementSetAttributeValue(
            focusTarget.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return currentFocusMatches(focusTarget.element)
    }

    private func currentFocusMatches(_ expected: AXUIElement) -> Bool {
        guard let expectedPID = processIdentifier(of: expected),
              systemWideFocusedApplicationPID() == expectedPID
        else { return false }
        guard let current = frontmostFocusedElement() else { return false }
        return CFEqual(current, expected)
    }

    /// NSWorkspace's frontmost process can remain the host throughout a system
    /// authentication sheet. This attribute follows the application that actually
    /// owns keyboard focus, which is the distinction secure insertion needs.
    private func systemWideFocusedApplicationPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedApplication = elementAttribute(
            of: systemWide,
            attribute: kAXFocusedApplicationAttribute as CFString
        ) else { return nil }
        return processIdentifier(of: focusedApplication)
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private func ancestorWindow(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<16 {
            guard let parent = parentElement(of: current) else { return nil }
            if stringAttribute(of: parent, attribute: kAXRoleAttribute as CFString)
                == (kAXWindowRole as String) {
                return parent
            }
            current = parent
        }
        return nil
    }

    private func elementAttribute(of element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return withBoundedMessagingTimeout(value as! AXUIElement)
    }

    /// Applies the engine's bounded messaging timeout to an element we are
    /// about to query, so a stalled host process cannot hang the tap thread.
    private func withBoundedMessagingTimeout(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeoutSeconds)
        return element
    }

    private func copyFocusedElement(from app: NSRunningApplication) -> AXUIElement? {
        let appElement = withBoundedMessagingTimeout(AXUIElementCreateApplication(app.processIdentifier))
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return withBoundedMessagingTimeout(focusedValue as! AXUIElement)
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

            let nested = withBoundedMessagingTimeout(nestedValue as! AXUIElement)
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

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return range
    }

    private func selectedRangeLength(of element: AXUIElement) -> Int {
        guard let range = selectedRange(of: element) else { return 0 }
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

        return withBoundedMessagingTimeout(value as! AXUIElement)
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

        let appElement = withBoundedMessagingTimeout(AXUIElementCreateApplication(pid))

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
