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
    private(set) var statusText = SnippetExpansionEngine.accessibilityRequiredStatus { didSet { onStateChange?() } }

    /// One sentence for one blocked state. It used to be described by two
    /// different sentences depending on whether the engine had run its first
    /// check yet, with a third label ("Permissions Required") stacked on top of
    /// whichever won. This names the app, the permission and the consequence,
    /// and says "expand keywords" — the user's word for the feature — rather
    /// than "watch typing and insert snippets", which is the implementation's.
    static let accessibilityRequiredStatus = "Snippets needs Accessibility access to expand keywords."

    var onStateChange: (() -> Void)?
    var beforeTemporaryPasteboardWrite: (() -> Void)?
    var afterTemporaryPasteboardRestore: ((Int) -> Void)?
    private var clipboardHistoryPickerActive = false
    private var clipboardHistoryInsertionActive = false
    /// The app layer owns the user's opt-in. Keeping this as a closure avoids
    /// coupling the typing engine to UserDefaults or the diagnostics backend.
    var expansionVerboseDiagnosticsEnabled: () -> Bool = { false }
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
    private var injectionInvalidationReason: DiagnosticPasteReason = .contextChanged
    private var injectionInvalidationOrigin: DiagnosticPasteInterruptionOrigin?
    private var acceptanceKeys = SnippetSuggestionAcceptanceKeys()
    private var activePasteboardLease: TemporaryPasteboardLease?
    /// The lease currently being consumed by a posted paste. It must not be restored merely
    /// because Quit, sleep, or another command arrived while the host was still accepting Cmd+V.
    private var pasteboardInjectionLease: TemporaryPasteboardLease?
    private var pasteboardRestoreRetryWorkItem: DispatchWorkItem?
    private var pasteboardRestoreRetryRoundsRemaining = 0
    private var pasteboardRestoreScheduleGeneration: UInt = 0
    private var pasteboardRecoveryCompletion: ((Bool) -> Void)?
    /// Raised before queued work is canceled and kept raised until AppKit terminates or explicitly
    /// cancels Quit. It closes every route that could acquire a new lease after termination was
    /// approved.
    private var isPreparingForTermination = false
    private var suggestionSecureInputWatchdog: Timer?

    // Suggestion overlay state
    private var suggestionActive = false
    private var suggestionQuery = ""
    private var suggestionDeleteCount = 1
    private var suggestionContextState: SuggestionContextState = .localDisplayOnly
    /// The process that owned the focused field when this suggestion session started.
    /// Modifier+Space is user-configurable, so we compare this with actual keyboard
    /// focus after key-up instead of assigning meaning to Command/Control/Option.
    private var suggestionTargetPID: pid_t?
    /// The exact focused object and its role are retained only for the live session.
    /// A text surface with no usable insertion-caret AX range may use local tracking
    /// only while keyboard focus remains on this same object.
    private var suggestionTargetElement: AXUIElement?
    private var suggestionTargetRole: String?
    private var suggestionHasReadableAXContext = false
    private var suggestionCaretUnavailable = false
    private var pendingSpaceShortcutFocusValidation = false
    private var pendingSpaceShortcutInputSourceID: String?
    private var suggestionSyncGeneration = 0
    private var suggestionSessionGeneration: UInt = 0
    private var suggestionAXObserver: AXObserver?
    private var suggestionAXObserverSource: CFRunLoopSource?
    private var suggestionObserverRegistration: SuggestionObserverRegistration?
    private var suggestionObserverAllowsAutoExpand = false
    /// Non-nil only while LocalAuthentication is servicing an explicit secure
    /// suggestion. Its own activation/secure-input transitions must not invalidate
    /// the target we are about to restore and re-check.
    private var secureSuggestionAuthenticationTargetPID: pid_t?
    /// Survives the prompt itself until the authenticated insertion finishes. NSWorkspace
    /// sometimes delivers the restored target's activation notification late; only
    /// that exact PID gets this grace, while activating any other app still cancels.
    private var secureExpansionActivationTargetPID: pid_t?
    /// Frozen for the lifetime of one suggestion session so AX notifications
    /// cannot reshuffle rows under the user's fingers by changing frecency.
    private var suggestionFrecency: FrecencySnapshot = .empty
    private let suggestionResultsUpdater = SuggestionResultsUpdater()
    private let suggestionSearchIndex = SuggestionSearchIndex()
    /// The query the user had typed when they accepted from the panel, held
    /// only until `expand()` consumes it. Never set on an auto-expand path.
    private var pendingSelectionMemoryQuery: String?
    private lazy var suggestionPanel = SuggestionPanelController()
    /// Secure Paste borrows the suggestion panel's input-enabled mode. While its
    /// search field owns focus, the global event tap must pass those keys through
    /// instead of interpreting them as typing in the captured host field.
    private var securePastePickerActive = false
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
    // AX calls into a beachballing host block for ~6s by default. Every exact object gets this
    // per-message bound; suggestion activation additionally shares one `AXMessagingBudget` across
    // its whole engine-to-panel chain so several bounded messages cannot accumulate into seconds.
    private let axMessagingTimeoutSeconds = AXMessagingBudget.interactiveTimeoutSeconds
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

    /// Posting the paste and returning the clipboard are separate observable outcomes. Once the
    /// host has accepted Cmd+V, a failed handback must not turn a real insertion into a failure —
    /// but it must not be flattened into ordinary success either.
    private enum EventReplacementOutcome {
        case failed
        case inserted
        case insertedWithPasteboardRecoveryPending
        case unconfirmed(pasteboardRecoveryPending: Bool)
    }

    private struct ExpansionTarget {
        let element: AXUIElement
        let selection: NSRange?
    }

    private struct PreparedTriggerSelection {
        let element: AXUIElement
        let verification: VerifiedTriggerSelection
    }

    private enum TriggerSelectionPreparation {
        case unavailable
        case prepared(PreparedTriggerSelection)
        case rejected(DiagnosticPasteReason)
    }

    private enum FocusedTriggerContextRead {
        case found(SuggestionTriggerContext)
        case missingTrigger
        case unavailable(AXContextUnavailable)
    }

    private struct AXContextUnavailable {
        let stage: DiagnosticExpansionAXStage
        let failure: DiagnosticExpansionAXFailure
        let errorCode: Int?
        var allowsLocalTracking = false
    }

    private enum AXTextRead {
        case value(String)
        case unavailable(AXContextUnavailable, mayReadAncestor: Bool)
    }

    private enum AXElementRead {
        case value(AXUIElement)
        case unavailable(AXContextUnavailable)
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

    private struct SecurePasteWebPreparation {
        let fieldUTF16Count: Int
        let selection: CFRange
        let lineEndings: SecurePasteWebReplacementPolicy.LineEndings
    }

    private enum SecurePasteDeliveryPreparation {
        case replaceSecureValue
        case replaceWebRange(SecurePasteWebPreparation)
        case typeUnicode
        case typeSecureUnicode

        var usesDirectInput: Bool {
            switch self {
            case .typeUnicode, .typeSecureUnicode: true
            default: false
            }
        }
    }

    /// Opaque handle to the exact control that was focused when Secure Paste began.
    /// The picker may keep metadata, but only the engine can inspect or write this target.
    struct SecurePasteTarget {
        fileprivate let targetPID: pid_t
        fileprivate let focusedElement: AXUIElement
        fileprivate let textElement: AXUIElement
        fileprivate let window: AXUIElement?
        fileprivate let isSecureTextField: Bool
        fileprivate let secureInputWasEnabledAtCapture: Bool
        fileprivate var containerBinding: SecurePasteContainerBinding? = nil
        let applicationName: String
    }

    struct SecurePasteFieldSelection {
        let targetPID: pid_t
        fileprivate let root: AXUIElement
        fileprivate let window: AXUIElement
        fileprivate let applicationName: String
        let frame: NSRect
    }

    fileprivate struct SecurePasteContainerBinding {
        let context: SecurePasteFieldSelection
        /// nil means the descendant positively reported keyboard focus.
        let explicitPoint: CGPoint?
    }

    enum SecurePasteTargetCapture {
        case target(SecurePasteTarget)
        case chooseField(SecurePasteFieldSelection)
        /// No safe text destination was focused; Copy is the non-destructive fallback.
        case noTextField
        case accessibilityRequired
        case unavailable
    }

    enum ClipboardCopyResult {
        case copied
        case secureSnippetBlocked
        case failed
    }

    var securePastePickerIsVisible: Bool {
        securePastePickerActive && suggestionPanel.isSecurePasteVisible
    }

    init(store: SnippetStore, usage: SnippetUsageStore) {
        self.store = store
        self.usage = usage
        refreshAccessibilityStatus(prompt: false)
    }

    func startIfNeeded() {
        if eventTap == nil {
            // Pay initial metadata preparation before installing the keyboard tap,
            // so the first backslash doesn't build the whole search index.
            _ = suggestionSearchSnapshot()
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
                self.resetTypingContext(reason: .pointerInteraction)
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
                        self.resetTypingContext(reason: .applicationActivation)
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
    private func resetTypingContext(reason: DiagnosticPasteReason = .contextChanged) {
        typedBuffer = ""
        // Anything already queued was measured against a caret that has since moved.
        injectionContextGeneration &+= 1
        injectionInvalidationReason = reason
        injectionInvalidationOrigin = nil
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
            eventsOfInterest: CGEventMask(
                (1 << CGEventType.keyDown.rawValue)
                    | (1 << CGEventType.keyUp.rawValue)
            ),
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
                if type == .keyUp {
                    return engine.handleEventTapKeyUp(event) ? nil : Unmanaged.passUnretained(event)
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
            // Input may have passed while the tap was disabled, including the release of
            // an accepted Tab. Neither held-key ownership nor insertion authority survives.
            acceptanceKeys.reset()
            injectionContextGeneration &+= 1
            injectionInvalidationReason = .monitorsRestarted
            injectionInvalidationOrigin = nil
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
            if acceptanceKeys.consume(keyCode: UInt16(truncatingIfNeeded: cgEvent.getIntegerValueField(.keyboardEventKeycode)),
                                      phase: .keyDown, origin: .user,
                                      isAutorepeat: cgEvent.getIntegerValueField(.keyboardEventAutorepeat) != 0) { return true }
            guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return false }
            return handle(event: nsEvent, eventUserData: eventUserData)
        }
    }

    /// A head-insert tap sees key-up before the rest of the event pipeline. Queue the
    /// focus read onto the main run loop so the key can be delivered first, without
    /// adding a timer or making the shortcut feel delayed.
    nonisolated private func handleEventTapKeyUp(_ cgEvent: CGEvent) -> Bool {
        let eventUserData = cgEvent.getIntegerValueField(.eventSourceUserData)
        guard SnippetSyntheticEvent.origin(eventUserData: eventUserData) == .user else { return false }
        let keyCode = UInt16(truncatingIfNeeded: cgEvent.getIntegerValueField(.keyboardEventKeycode))
        if MainActor.assumeIsolated({ acceptanceKeys.consume(
            keyCode: keyCode, phase: .keyUp, origin: .user,
            keyIsDownInHIDState: CGEventSource.keyState(.hidSystemState, key: keyCode)) }) {
            return true
        }
        guard keyCode == UInt16(kVK_Space) else { return false }
        let shouldValidate = MainActor.assumeIsolated {
            pendingSpaceShortcutFocusValidation
        }
        guard shouldValidate else { return false }

        DispatchQueue.main.async { [weak self] in
            self?.validatePendingSpaceShortcutFocus()
        }
        return false
    }

    func requestAccessibilityPermission() {
        refreshAccessibilityStatus(prompt: true)
    }

    private func restartEventMonitors() {
        // Permission changes are irrelevant once Quit has begun. More importantly, restarting here
        // must neither invalidate an in-flight paste nor resolve a recovery lease without answering
        // AppKit's outstanding `.terminateLater` request.
        if isPreparingForTermination {
            if finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) {
                continueTerminationPreparationIfNeeded()
            }
            return
        }
        injectionContextGeneration &+= 1
        injectionInvalidationReason = .monitorsRestarted
        injectionInvalidationOrigin = nil
        acceptanceKeys.reset()
        injectionQueue.cancelAll()
        stopSuggestionSecureInputWatchdog()
        finishPendingPasteboardOwnership(schedulingRetryOnFailure: true)
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
            statusText = SnippetExpansionEngine.accessibilityRequiredStatus
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


    @discardableResult
    func copySnippetToClipboard(_ snippet: Snippet) -> ClipboardCopyResult {
        guard !isPreparingForTermination else { return .failed }
        // Check the vault projection before resolving placeholders or touching the
        // pasteboard. A secure shell carries no body, but fail closed here as well so
        // no future caller can accidentally turn an empty shell into a clipboard write.
        guard !store.isSecure(snippet.id) else {
            statusText = ClipboardCopyFeedback.secureSnippetBlocked
            return .secureSnippetBlocked
        }
        // An explicit copy is the user taking the clipboard back; hand it over before reading
        // `{clipboard}`, or the snippet would resolve against a snippet we are still holding.
        guard finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) else {
            statusText = "Still restoring your previous clipboard. Try Copy again in a moment."
            return .failed
        }
        let rendered = PlaceholderResolver.resolve(template: snippet.content)
        beforeTemporaryPasteboardWrite?()
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(rendered, forType: .string) else {
            statusText = ClipboardCopyFeedback.failed
            return .failed
        }

        usage.record(.copyFromApp, snippetID: snippet.id)
        lastExpansionName = snippet.displayName
        statusText = "Copied \(snippet.displayName) to the clipboard."
        return .copied
    }

    func pasteSnippetIntoFrontmostApp(_ snippet: Snippet) {
        guard !isPreparingForTermination else { return }
        guard finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) else {
            statusText = "Still restoring your previous clipboard. Try Paste again in a moment."
            return
        }
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
            let outcome = await self.replaceTypedText(
                characterCount: 0,
                with: rendered,
                generation: self.injectionContextGeneration,
                targetPID: nil
            )
            switch outcome {
            case .failed:
                self.statusText = "Could not paste \(snippet.displayName)."
            case .inserted:
                self.usage.record(.pasteFromApp, snippetID: snippet.id)
                self.lastExpansionName = snippet.displayName
                self.statusText = "Pasted \(snippet.displayName)."
            case .insertedWithPasteboardRecoveryPending:
                self.usage.record(.pasteFromApp, snippetID: snippet.id)
                self.lastExpansionName = snippet.displayName
                self.statusText = "Pasted \(snippet.displayName); restoring your previous clipboard is still pending."
            case .unconfirmed(let pending):
                self.reportUnconfirmedPaste(recoveryPending: pending)
            }
        }
    }

    /// History is literal text. It never resolves snippet placeholders or records a snippet use.
    func captureClipboardHistoryTarget() -> SecurePasteTarget? {
        let previousStatus = statusText
        defer { statusText = previousStatus }
        guard case .target(let target) = captureSecurePasteTargetImpl(),
              !target.isSecureTextField, !target.secureInputWasEnabledAtCapture else { return nil }
        return target
    }

    func setClipboardHistoryPickerActive(_ active: Bool) {
        if active { resetTypingContext() }
        clipboardHistoryPickerActive = active
    }

    func returnFocusAfterCancellingClipboardHistory(_ target: SecurePasteTarget) async {
        let generation = injectionContextGeneration
        _ = await restoreSecurePasteTarget(target, mode: .withoutAuthentication,
            logsHandoff: false, contextIsValid: { [self] in
            generation == injectionContextGeneration
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.targetPID
        })
    }

    @discardableResult
    func copyClipboardHistoryText(_ text: String) -> Bool {
        guard prepareClipboardHistoryWrite(),
              let writtenChangeCount = ClipboardHistoryPasteTransaction.write(text, to: NSPasteboard.general)
        else { return false }
        return NSPasteboard.general.changeCount == writtenChangeCount
    }

    private func prepareClipboardHistoryWrite() -> Bool {
        guard !isPreparingForTermination,
              finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) else { return false }
        beforeTemporaryPasteboardWrite?()
        return true
    }

    func pasteClipboardHistoryText(
        _ text: String, to target: SecurePasteTarget,
        completion: @escaping (String?) -> Void
    ) {
        guard !text.isEmpty, !isPreparingForTermination, accessibilityGranted,
              !target.isSecureTextField else {
            completion("Could not paste into the original field.")
            return
        }
        let generation = injectionContextGeneration
        beginInjection()
        injectionQueue.enqueue(isAutomatic: false) { [weak self] in
            guard let self else { return }
            defer {
                self.clipboardHistoryInsertionActive = false
                if self.secureExpansionActivationTargetPID == target.targetPID {
                    self.secureExpansionActivationTargetPID = nil
                }
                self.endInjection()
            }
            guard !Task.isCancelled, !self.isPreparingForTermination,
                  generation == self.injectionContextGeneration,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.targetPID else {
                completion("Paste canceled because the original input changed.")
                return
            }
            self.clipboardHistoryInsertionActive = true
            self.secureExpansionActivationTargetPID = target.targetPID
            guard await self.restoreSecurePasteTarget(target, mode: .withoutAuthentication,
                source: .clipboardHistory, contextIsValid: {
                generation == self.injectionContextGeneration
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.targetPID
            }) else {
                completion("Could not restore the original field. Copy the entry and paste it manually.")
                return
            }
            let result = ClipboardHistoryPasteTransaction.paste(text, to: NSPasteboard.general,
                validateTarget: {
                    guard !Task.isCancelled else { return .contextChanged }
                    if let reason = self.injectionBlockReason(generation: generation, targetPID: target.targetPID) {
                        return reason
                    }
                    return self.securePasteTargetStillMatches(target, budget: AXMessagingBudget())
                        ? nil : .focusedElementChanged
                }, prepareClipboard: { self.prepareClipboardHistoryWrite() },
                prepareShortcut: {
                    guard let events = self.makePasteShortcutEvents() else { return nil }
                    return { for event in events { event.postToPid(target.targetPID) } }
                })
            completion(result.message)
        }
    }

    /// Captures a text destination before the picker search field takes focus, or
    /// explicitly reports that Copy should be used because no safe field was found.
    /// No field value is read; password fields commonly refuse that read by design.
    func captureSecurePasteTarget() -> SecurePasteTargetCapture {
        let startedAt = ContinuousClock.now
        let result = captureSecurePasteTargetImpl()
        let outcome: DiagnosticSecurePasteOutcome
        let reason: DiagnosticSecurePasteReason
        var target: SecurePasteTarget?
        switch result {
        case .target(let captured): outcome = .succeeded; reason = .none; target = captured
        case .chooseField: outcome = .selectionRequired; reason = .ambiguousFocus
        case .noTextField: outcome = .clipboard; reason = .noTextField
        case .accessibilityRequired: outcome = .failed; reason = .permissionRequired
        case .unavailable: outcome = .failed; reason = .unavailable
        }
        recordSecurePaste(stage: .capture, outcome: outcome, target: target,
                          reason: reason, startedAt: startedAt)
        return result
    }

    private func captureSecurePasteTargetImpl() -> SecurePasteTargetCapture {
        guard !isPreparingForTermination else { return .unavailable }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            resetTypingContext()
            statusText = "No text field is focused. Choose an ordinary snippet to copy it."
            return .noTextField
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            resetTypingContext()
            if ownApplicationHasFocusedTextInput {
                statusText = "Secure Paste targets text fields in other apps."
                return .unavailable
            }
            statusText = "No text field is focused. Choose an ordinary snippet to copy it."
            return .noTextField
        }
        // The shortcut may be the first interaction after the user grants access in
        // System Settings, so do not rely on the last UI refresh's cached answer.
        refreshAccessibilityStatus(prompt: false)
        guard accessibilityGranted else {
            statusText = "Secure Paste needs Accessibility access."
            return .accessibilityRequired
        }

        let budget = AXMessagingBudget()
        guard let focusedElement = frontmostFocusedElement(axBudget: budget) else {
            resetTypingContext()
            statusText = "No text field is focused. Choose an ordinary snippet to copy it."
            return .noTextField
        }
        guard processIdentifier(of: focusedElement) == app.processIdentifier else {
            statusText = "Secure Paste could not safely capture the focused application."
            return .unavailable
        }
        let textElement = securePasteTextElement(
            startingAt: focusedElement,
            axBudget: budget
        )
        let role = stringAttribute(of: focusedElement, attribute: kAXRoleAttribute as CFString,
                                   axBudget: budget)
        // A web area may advertise selected-text ranges for the whole page. That
        // does not identify an input. Preserve native/custom input detection.
        if role == "AXWebArea" || (textElement == nil && role == "AXGroup") {
            return captureSecurePasteContainer(focusedElement, app: app, budget: budget)
        }
        guard let textElement else {
            resetTypingContext()
            statusText = "No text field is focused. Choose an ordinary snippet to copy it."
            return .noTextField
        }
        guard processIdentifier(of: textElement) == app.processIdentifier else {
            statusText = "Secure Paste could not safely capture the focused text field."
            return .unavailable
        }

        let isSecureTextField = stringAttribute(
            of: textElement,
            attribute: kAXSubroleAttribute as CFString,
            axBudget: budget
        ) == (kAXSecureTextFieldSubrole as String)
        let secureInputWasEnabledAtCapture = secureEventInputEnabled

        resetTypingContext()
        return .target(
            SecurePasteTarget(
                targetPID: app.processIdentifier,
                focusedElement: focusedElement,
                textElement: textElement,
                window: elementAttribute(
                    of: focusedElement,
                    attribute: kAXWindowAttribute as CFString,
                    axBudget: budget
                ),
                isSecureTextField: isSecureTextField,
                secureInputWasEnabledAtCapture: secureInputWasEnabledAtCapture,
                applicationName: app.localizedName ?? "the target app"
            )
        )
    }

    private func captureSecurePasteContainer(
        _ root: AXUIElement, app: NSRunningApplication, budget: AXMessagingBudget
    ) -> SecurePasteTargetCapture {
        guard let window = elementAttribute(of: root, attribute: kAXWindowAttribute as CFString,
                                            axBudget: budget),
              let frame = securePasteWindowFrame(window, budget: budget)
        else { return .unavailable }
        let context = SecurePasteFieldSelection(targetPID: app.processIdentifier, root: root,
            window: window, applicationName: app.localizedName ?? "the target app", frame: frame)
        let resolution = SecurePasteTargetResolver.focusedDescendant(
            of: root, canContinue: { budget.canContinue },
            metadata: { [self] element in
                guard processIdentifier(of: element) == app.processIdentifier,
                      let role = stringAttribute(of: element, attribute: kAXRoleAttribute as CFString,
                                                 axBudget: budget) else { return nil }
                return .init(isTextControl: SecurePasteDeliveryPolicy.isEligibleWebTextRole(role),
                    isFocused: boolAttribute(of: element, attribute: kAXFocusedAttribute as CFString,
                                              axBudget: budget) == true,
                    isEnabled: boolAttribute(of: element, attribute: kAXEnabledAttribute as CFString,
                                              axBudget: budget) == true)
            }, children: { [self] element in
                var value: CFTypeRef?
                let result = copyAttributeValue(of: element, attribute: kAXChildrenAttribute as CFString,
                                                into: &value, axBudget: budget)
                if result == .attributeUnsupported || result == .noValue { return [] }
                guard result == .success else { return nil }
                return value as? [AXUIElement]
            })
        resetTypingContext()
        if case .noTextField = resolution { return .noTextField }
        var reason = DiagnosticSecurePasteReason.unsupportedTarget
        if case .focused(let field) = resolution,
           let target = makeContainerSecurePasteTarget(field, context: context,
                                                       explicitPoint: nil, budget: budget, reason: &reason) {
            return .target(target)
        }
        // An explicit choice does not depend on a complete descendant search.
        return .chooseField(context)
    }

    /// Called only after the user clicks our destination-selection overlay.
    func captureExplicitSecurePasteTarget(
        in context: SecurePasteFieldSelection, at point: CGPoint
    ) -> SecurePasteTarget? {
        let startedAt = ContinuousClock.now
        var reason = DiagnosticSecurePasteReason.unavailable
        let target = captureExplicitSecurePasteTargetImpl(in: context, at: point, reason: &reason)
        recordSecurePaste(stage: .selection, outcome: target == nil ? .failed : .succeeded,
                          target: target, reason: target == nil ? reason : .none, startedAt: startedAt)
        return target
    }

    private func captureExplicitSecurePasteTargetImpl(
        in context: SecurePasteFieldSelection, at point: CGPoint,
        reason: inout DiagnosticSecurePasteReason
    ) -> SecurePasteTarget? {
        guard !isPreparingForTermination, accessibilityGranted else { return nil }
        let budget = AXMessagingBudget()
        guard currentFocusMatches(context.root, axBudget: budget) else {
            reason = budget.canContinue ? .focusChanged : .budgetExhausted
            return nil
        }
        guard let hit = securePasteHitTest(point, context: context, budget: budget),
              let field = securePasteTextElement(startingAt: hit, axBudget: budget),
              let role = stringAttribute(of: field, attribute: kAXRoleAttribute as CFString,
                                        axBudget: budget),
              SecurePasteDeliveryPolicy.isEligibleWebTextRole(role)
        else { reason = budget.canContinue ? .unsupportedTarget : .budgetExhausted; return nil }
        return makeContainerSecurePasteTarget(field, context: context,
                                              explicitPoint: point, budget: budget, reason: &reason)
    }

    private func makeContainerSecurePasteTarget(
        _ field: AXUIElement, context: SecurePasteFieldSelection,
        explicitPoint: CGPoint?, budget: AXMessagingBudget, reason: inout DiagnosticSecurePasteReason
    ) -> SecurePasteTarget? {
        let secure = stringAttribute(of: field, attribute: kAXSubroleAttribute as CFString,
                                     axBudget: budget) == (kAXSecureTextFieldSubrole as String)
        let target = SecurePasteTarget(targetPID: context.targetPID, focusedElement: field,
            textElement: field, window: context.window, isSecureTextField: secure,
            secureInputWasEnabledAtCapture: secureEventInputEnabled,
            containerBinding: .init(context: context, explicitPoint: explicitPoint),
            applicationName: context.applicationName)
        let validation = securePasteTargetValidation(target, budget: budget)
        guard validation == .valid else { reason = diagnosticReason(validation); return nil }
        reason = .unsupportedTarget
        // A container alone may authorize only an addressed AX operation. Secure
        // web input may be captured here, but preparation and delivery must later
        // prove that the concrete field (not just this container) owns the keyboard.
        if secure && !elementIsInsideWebArea(field, axBudget: budget) {
            guard attributeIsSettable(kAXValueAttribute as CFString, on: field, axBudget: budget)
            else { return nil }
        } else if !secure {
            guard elementIsInsideWebArea(field, axBudget: budget),
                  let attributes = parameterizedAttributes(on: field, axBudget: budget),
                  SecurePasteDeliveryPolicy.supportsWebRangeReplacement(
                    advertisedParameterizedAttributes: attributes) else { return nil }
        }
        return budget.canContinue ? target : nil
    }

    private func securePasteHitTest(
        _ point: CGPoint, context: SecurePasteFieldSelection, budget: AXMessagingBudget
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(context.targetPID)
        guard budget.bind(application) else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
                == .success, budget.canContinue else { return nil }
        return hit
    }

    private func securePasteWindowFrame(_ window: AXUIElement, budget: AXMessagingBudget) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard copyAttributeValue(of: window, attribute: kAXPositionAttribute as CFString,
                                 into: &positionValue, axBudget: budget) == .success,
              copyAttributeValue(of: window, attribute: kAXSizeAttribute as CFString,
                                 into: &sizeValue, axBudget: budget) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              let screen = NSScreen.screens.first else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return NSRect(x: point.x, y: screen.frame.maxY - point.y - size.height,
                      width: size.width, height: size.height)
    }

    /// Existing targets retain exact-focus identity checks. Container targets also
    /// require a live enabled field in the original window/subtree. An explicit
    /// choice is re-hit-tested; automatic discovery must still report field focus.
    private func securePasteTargetStillMatches(
        _ target: SecurePasteTarget, budget: AXMessagingBudget
    ) -> Bool {
        securePasteTargetValidation(target, budget: budget) == .valid
    }

    private func securePasteTargetValidation(
        _ target: SecurePasteTarget, budget: AXMessagingBudget
    ) -> SecurePasteTargetResolver.Validation {
        guard let binding = target.containerBinding else {
            if currentFocusMatches(target.focusedElement, axBudget: budget) { return .valid }
            return budget.canContinue ? .focusUnavailable : .budgetExhausted
        }
        let context = binding.context
        guard processIdentifier(of: target.textElement) == target.targetPID else { return .fieldUnavailable }
        // Check structural identity independently of keyboard ownership: a lost
        // control must never be retried as if authentication were merely settling.
        let validation = SecurePasteTargetResolver.validation(
            field: target.textElement, root: context.root, window: context.window,
            wasSecure: target.isSecureTextField, explicit: binding.explicitPoint != nil,
            canContinue: { budget.canContinue },
            metadata: { [self] element in
                guard let role = stringAttribute(of: element, attribute: kAXRoleAttribute as CFString,
                                                 axBudget: budget) else { return nil }
                return .init(isTextControl: SecurePasteDeliveryPolicy.isEligibleWebTextRole(role),
                    isFocused: boolAttribute(of: element, attribute: kAXFocusedAttribute as CFString,
                                              axBudget: budget) == true,
                    isEnabled: boolAttribute(of: element, attribute: kAXEnabledAttribute as CFString,
                                              axBudget: budget) == true,
                    isSecure: stringAttribute(of: element, attribute: kAXSubroleAttribute as CFString,
                                               axBudget: budget) == (kAXSecureTextFieldSubrole as String))
            },
            currentFocus: {
                guard let app = NSRunningApplication(processIdentifier: target.targetPID),
                      let focused = self.copyFocusedElement(from: app, axBudget: budget) else { return nil }
                return self.deepestFocusedElement(startingAt: focused, maxDepth: 4, axBudget: budget)
            },
            currentWindow: { self.elementAttribute(of: $0, attribute: kAXWindowAttribute as CFString,
                                                   axBudget: budget) },
            windowIsUnchanged: { self.securePasteWindowFrame(context.window, budget: budget) == context.frame },
            parent: { self.parentElement(of: $0, axBudget: budget) },
            hitTest: {
                guard let point = binding.explicitPoint else { return nil }
                return self.securePasteHitTest(point, context: context, budget: budget)
            })
        guard validation == .valid || validation == .fieldFocusPending else { return validation }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.targetPID
        else { return .applicationNotFrontmost }
        guard systemWideFocusedApplicationPID(axBudget: budget) == target.targetPID
        else { return budget.canContinue ? .keyboardOwnerPending : .budgetExhausted }
        return validation
    }

    private func diagnosticTarget(_ target: SecurePasteTarget?) -> DiagnosticSecurePasteTarget {
        guard let target else { return .unresolved }
        guard let binding = target.containerBinding else { return .focused }
        return binding.explicitPoint == nil ? .descendant : .explicit
    }

    private func diagnosticReason(_ validation: SecurePasteTargetResolver.Validation) -> DiagnosticSecurePasteReason {
        if validation == .valid { return .none }
        // Both sides are closed enums; tests cover their vocabulary mapping.
        return DiagnosticSecurePasteReason(rawValue: validation.rawValue) ?? .unavailable
    }

    private func recordSecurePaste(
        stage: DiagnosticSecurePasteStage, outcome: DiagnosticSecurePasteOutcome,
        target: SecurePasteTarget?, transport: DiagnosticSecurePasteTransport = .none,
        reason: DiagnosticSecurePasteReason = .none, startedAt: ContinuousClock.Instant,
        attempts: Int = 1, axErrorCode: Int? = nil, failure: DiagnosticFailure? = nil,
        handoff: DiagnosticPasteHandoffProgress? = nil
    ) {
        let elapsed = startedAt.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        Diagnostics.record(.securePaste(stage: stage, outcome: outcome,
            target: diagnosticTarget(target), transport: transport, reason: reason,
            attempts: attempts, durationMilliseconds: milliseconds, axErrorCode: axErrorCode,
            failure: failure, handoff: handoff))
    }

    /// Reuses the ordinary suggestion panel for an explicit, searchable action.
    /// With a captured target it performs Secure Paste. Without one it keeps every
    /// row visible but allows only ordinary snippets to be copied; selecting a secure
    /// shell is deliberately routed to the app-level refusal feedback.
    @discardableResult
    func showSecurePastePicker(
        for target: SecurePasteTarget?,
        onSelect: @escaping (Snippet) -> Void,
        onCancel: @escaping (Bool) -> Void
    ) -> Bool {
        let startedAt = ContinuousClock.now
        let snippets = store.snippetsSortedForDisplay()
        guard !snippets.isEmpty else {
            statusText = "There are no snippets yet."
            recordSecurePaste(stage: .picker, outcome: .failed, target: target,
                              reason: .unavailable, startedAt: startedAt)
            return false
        }

        let frecency = usage.makeRankingSnapshot()
        let makeItems: (String) -> [SuggestionItem] = { [weak self] query in
            guard let self else { return [] }
            return self.securePasteSuggestionItems(
                query: query,
                snapshot: self.suggestionSearchSnapshot(),
                frecency: frecency)
        }

        securePastePickerActive = true
        suggestionPanel.showSecurePaste(
            items: makeItems(""),
            anchorFocusedElement: target?.focusedElement,
            copiesToClipboard: target == nil,
            onSearch: makeItems,
            onSelect: { [weak self] snippet in
                self?.securePastePickerActive = false
                self?.recordSecurePaste(stage: .picker, outcome: .succeeded, target: target, startedAt: startedAt)
                onSelect(snippet)
            },
            onCancel: { [weak self] shouldReturnFocus in
                self?.securePastePickerActive = false
                self?.recordSecurePaste(stage: .picker, outcome: .cancelled, target: target,
                                        reason: .cancelled, startedAt: startedAt)
                onCancel(shouldReturnFocus)
            }
        )
        return true
    }

    func cancelSecurePastePicker(returnFocus: Bool) {
        guard securePastePickerActive else { return }
        suggestionPanel.cancelSecurePaste(returnFocus: returnFocus)
    }

    func dismissSecurePastePicker() {
        guard securePastePickerActive else { return }
        securePastePickerActive = false
        suggestionPanel.dismissSecurePasteWithoutCallback()
    }

    /// Escape from the palette behaves like Quick Access: return keyboard focus without
    /// decrypting anything. A click into a different app deliberately does not call this.
    func returnFocusAfterCancellingSecurePaste(_ target: SecurePasteTarget) async {
        secureExpansionActivationTargetPID = target.targetPID
        defer {
            if secureExpansionActivationTargetPID == target.targetPID {
                secureExpansionActivationTargetPID = nil
            }
        }
        _ = await restoreSecurePasteTarget(target, mode: .withoutAuthentication, logsHandoff: false)
    }

    /// Delivers either kind of snippet through one transport chosen before its body is
    /// materialized. Secure records authenticate and decrypt one body; ordinary records
    /// resolve their existing content directly. Browser delivery reads only bounded text
    /// state needed to prove that its one request landed. Neither path borrows the
    /// pasteboard.
    @discardableResult
    func pasteSnippetUsingSecurePaste(
        _ snippet: Snippet,
        to target: SecurePasteTarget
    ) async -> SecurePasteResult {
        let startedAt = ContinuousClock.now
        let result: SecurePasteResult
        if store.isSecure(snippet.id) {
            result = await pasteSecureSnippet(snippet, to: target)
        } else {
            result = await pasteOrdinarySnippetUsingSecurePaste(snippet, to: target)
        }
        recordSecurePaste(stage: .completion, outcome: Task.isCancelled ? .cancelled : diagnosticOutcome(result),
            target: target, reason: Task.isCancelled ? .cancelled : diagnosticResultReason(result), startedAt: startedAt)
        return result
    }

    private func diagnosticOutcome(_ result: SecurePasteResult) -> DiagnosticSecurePasteOutcome {
        switch result {
        case .inserted: .succeeded
        case .attemptedAmbiguous, .dispatchedUnconfirmed: .ambiguous
        case .failedBeforeAttempt, .blockedUnsafeControlCharacters: .failed
        }
    }

    private func diagnosticResultReason(_ result: SecurePasteResult) -> DiagnosticSecurePasteReason {
        switch result {
        case .inserted: .none
        case .dispatchedUnconfirmed: .directInputUnconfirmed
        case .attemptedAmbiguous: .readbackUnconfirmed
        case .failedBeforeAttempt: .unavailable
        case .blockedUnsafeControlCharacters: .unsafeContent
        }
    }

    private func pasteOrdinarySnippetUsingSecurePaste(
        _ snippet: Snippet,
        to target: SecurePasteTarget
    ) async -> SecurePasteResult {
        guard !isPreparingForTermination else { return .failedBeforeAttempt }
        guard let targetApplication = NSRunningApplication(processIdentifier: target.targetPID),
              !targetApplication.isTerminated,
              target.targetPID != ProcessInfo.processInfo.processIdentifier,
              processIdentifier(of: target.focusedElement) == target.targetPID,
              processIdentifier(of: target.textElement) == target.targetPID
        else {
            statusText = "Secure Paste stopped because the original app is no longer available."
            return .failedBeforeAttempt
        }
        // `{clipboard}` must resolve against the user's clipboard. This only
        // completes restoration of an older lease; Secure Paste never creates one.
        guard finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) else {
            statusText = "Secure Paste is waiting for your previous clipboard to be restored."
            return .failedBeforeAttempt
        }

        secureExpansionActivationTargetPID = target.targetPID
        beginInjection()
        defer {
            if secureExpansionActivationTargetPID == target.targetPID {
                secureExpansionActivationTargetPID = nil
            }
            endInjection()
        }

        guard await restoreSecurePasteTarget(target, mode: .withoutAuthentication) else {
            statusText = "Skipped \(snippet.displayName): Snippets could not restore the original field."
            return .failedBeforeAttempt
        }

        let resolvedText = PlaceholderResolver.resolve(template: snippet.content)
        guard !resolvedText.isEmpty else {
            statusText = "\(snippet.displayName) is empty — nothing to paste."
            return .failedBeforeAttempt
        }
        guard let preparation = prepareSecurePasteDeliveryTarget(target) else {
            statusText = "The target field did not accept Secure Paste."
            return .failedBeforeAttempt
        }
        if preparation.usesDirectInput,
           let validationFailure = directInputValidationFailure(
            for: resolvedText,
            displayName: snippet.displayName
           ) {
            statusText = validationFailure.message
            return validationFailure.result
        }

        let result = deliverSecurePasteText(resolvedText, to: target, using: preparation)
        switch result {
        case .inserted:
            usage.record(.pasteFromApp, snippetID: snippet.id)
            lastExpansionName = snippet.displayName
            statusText = "Pasted \(snippet.displayName)."
        case .dispatchedUnconfirmed:
            statusText = "Secure Paste keyboard input sent."
        case .failedBeforeAttempt:
            statusText = "The target field did not accept Secure Paste."
        case .blockedUnsafeControlCharacters:
            break
        case .attemptedAmbiguous:
            statusText = "Secure Paste may have inserted \(snippet.displayName). Check the field before trying again."
        }
        return result
    }

    /// Authenticates one secure shell and writes it directly to the captured control.
    private func pasteSecureSnippet(
        _ shell: Snippet,
        to target: SecurePasteTarget
    ) async -> SecurePasteResult {
        guard !isPreparingForTermination else { return .failedBeforeAttempt }
        guard store.isSecure(shell.id), let resolver = secureSnippetContentResolver else {
            statusText = "Secure Paste is not configured for this snippet."
            return .failedBeforeAttempt
        }
        guard let targetApplication = NSRunningApplication(processIdentifier: target.targetPID),
              !targetApplication.isTerminated,
              target.targetPID != ProcessInfo.processInfo.processIdentifier,
              processIdentifier(of: target.focusedElement) == target.targetPID,
              processIdentifier(of: target.textElement) == target.targetPID
        else {
            statusText = "Secure Paste stopped because the original app is no longer available."
            return .failedBeforeAttempt
        }
        guard finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) else {
            statusText = "Secure Paste is waiting for your previous clipboard to be restored."
            return .failedBeforeAttempt
        }

        let reason = "Paste \u{201C}\(shell.displayName)\u{201D} into \(target.applicationName)"
        statusText = "Waiting for authentication to paste \(shell.displayName)\u{2026}"
        secureSuggestionAuthenticationTargetPID = target.targetPID
        secureExpansionActivationTargetPID = target.targetPID
        beginInjection()
        defer {
            if secureSuggestionAuthenticationTargetPID == target.targetPID {
                secureSuggestionAuthenticationTargetPID = nil
            }
            if secureExpansionActivationTargetPID == target.targetPID {
                secureExpansionActivationTargetPID = nil
            }
            endInjection()
        }

        let plaintext: SecurePlaintextLease
        let authenticationStartedAt = ContinuousClock.now
        do {
            plaintext = try await resolver(shell, reason)
        } catch {
            recordSecurePaste(stage: .authentication, outcome: Task.isCancelled ? .cancelled : .failed,
                target: target, reason: .authenticationFailed, startedAt: authenticationStartedAt,
                failure: DiagnosticFailure(error))
            statusText = "Could not paste \(shell.displayName): \(error)"
            return .failedBeforeAttempt
        }
        recordSecurePaste(stage: .authentication, outcome: .succeeded, target: target,
                          startedAt: authenticationStartedAt)
        defer { plaintext.wipe() }

        guard !Task.isCancelled else { return .failedBeforeAttempt }
        // The resolver has completed both authentication and the Keychain read.
        // Either can show system UI, even when the destination permits Secure Input.
        guard await restoreSecurePasteTarget(target, mode: .afterAuthentication) else {
            statusText = "Skipped \(shell.displayName): Snippets could not restore the original field after authentication."
            return .failedBeforeAttempt
        }

        // Authentication is over. Delivery below is synchronous, so there is no queued
        // delete count or later paste event for a real keystroke to race with.
        if secureSuggestionAuthenticationTargetPID == target.targetPID {
            secureSuggestionAuthenticationTargetPID = nil
        }

        // Establish the exact transport and capture only non-secret range metadata
        // before materializing the authenticated bytes as a Swift String.
        guard let preparation = prepareSecurePasteDeliveryTarget(target) else {
            statusText = "Authentication succeeded, but the target field did not accept Secure Paste."
            return .failedBeforeAttempt
        }

        guard var resolvedText = resolvedSecureText(consuming: plaintext) else {
            statusText = "Could not paste \(shell.displayName): its secure content is not valid UTF-8."
            return .failedBeforeAttempt
        }
        defer { resolvedText.removeAll(keepingCapacity: false) }
        guard !resolvedText.isEmpty else {
            statusText = "\(shell.displayName) is empty — nothing to paste."
            return .failedBeforeAttempt
        }
        if preparation.usesDirectInput,
           let validationFailure = directInputValidationFailure(
            for: resolvedText,
            displayName: shell.displayName
           ) {
            statusText = validationFailure.message
            return validationFailure.result
        }

        let result = deliverSecurePasteText(
            resolvedText,
            to: target,
            using: preparation
        )
        switch result {
        case .inserted:
            usage.record(.pasteFromApp, snippetID: shell.id)
            lastExpansionName = shell.displayName
            statusText = "Pasted \(shell.displayName) securely."
        case .dispatchedUnconfirmed:
            statusText = "Secure Paste keyboard input sent."
        case .failedBeforeAttempt:
            statusText = "Authentication succeeded, but the target field did not accept Secure Paste."
        case .blockedUnsafeControlCharacters:
            break
        case .attemptedAmbiguous:
            statusText = "Secure Paste may have inserted \(shell.displayName). Check the field before trying again."
        }
        return result
    }

    /// Starts termination cleanup. `true` means the clipboard is already safe and termination can
    /// proceed. `false` means the caller must return `.terminateLater`; `onRecoveryComplete` then
    /// answers whether termination may continue after bounded delayed retries.
    @discardableResult
    func prepareForTermination(onRecoveryComplete: ((Bool) -> Void)? = nil) -> Bool {
        if isPreparingForTermination {
            return activePasteboardLease == nil
                && pasteboardInjectionLease == nil
                && pasteboardRecoveryCompletion == nil
        }
        isPreparingForTermination = true
        // A pasteboard injection that already borrowed the clipboard is a bounded critical
        // section: changing its generation here could stop it after only part of the trigger was
        // deleted. Queued/not-yet-started work is still invalidated below.
        if pasteboardInjectionLease == nil {
            injectionContextGeneration &+= 1
            injectionInvalidationReason = .quitting
            injectionInvalidationOrigin = nil
        }
        injectionQueue.cancelAll()
        pasteboardRestoreRetryWorkItem?.cancel()
        pasteboardRestoreRetryWorkItem = nil
        pasteboardRestoreScheduleGeneration &+= 1
        pasteboardRestoreRetryRoundsRemaining = max(pasteboardRestoreRetryRoundsRemaining, 3)

        // Cancellation deliberately does not interrupt the timing waits after trigger deletion.
        // Restoring this lease now could make the already-posted Cmd+V consume the user's old
        // clipboard instead of the snippet. The injection's defer advances termination once the
        // host has had its bounded confirmation window.
        guard pasteboardInjectionLease == nil else {
            pasteboardRecoveryCompletion = onRecoveryComplete
            return false
        }
        guard !finishPendingPasteboardOwnership() else { return true }
        pasteboardRecoveryCompletion = onRecoveryComplete
        if schedulePasteboardRestoreRetryIfNeeded() { return false }

        // The pasteboard is process-global and can change between the failed restore and the retry
        // scheduling check. A newer user copy is safe, not an exhausted recovery attempt.
        if finishPendingPasteboardOwnership() {
            pasteboardRecoveryCompletion = nil
            return true
        }
        completePasteboardRecovery(success: false)
        return false
    }

    /// AppKit calls this only after a `.terminateLater` decision is answered with `false`.
    /// Reopen the engine then; until that explicit cancellation, no event or command may create a
    /// fresh clipboard lease behind the termination reply.
    func cancelTerminationPreparation() {
        guard isPreparingForTermination else { return }
        isPreparingForTermination = false
        pasteboardRecoveryCompletion = nil
        pasteboardRestoreRetryRoundsRemaining = max(pasteboardRestoreRetryRoundsRemaining, 3)
        _ = schedulePasteboardRestoreRetryIfNeeded()
    }

    func releaseBorrowedPasteboard() {
        if finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) {
            continueTerminationPreparationIfNeeded()
        }
    }

    /// Returns `true` if the event was consumed and should be suppressed.
    @discardableResult
    private func handle(event: NSEvent, eventUserData: Int64?) -> Bool {
        // The event tap still sees keys addressed to our non-activating search
        // panel because the destination app remains frontmost. Let AppKit deliver
        // them to NSSearchField; none belongs in the host typing buffer.
        if securePastePickerActive || clipboardHistoryPickerActive { return false }

        // Keep observing real input while an already-started paste drains: it still needs normal
        // generation invalidation if the user changes the host text. With no such critical
        // section, Quit gates the event path completely.
        guard !isPreparingForTermination || pasteboardInjectionLease != nil else { return false }
        let origin = SnippetSyntheticEvent.origin(eventUserData: eventUserData)
        let isAuthenticatingSecureSuggestion = secureSuggestionAuthenticationTargetPID != nil
        let secureInputEnabled = secureEventInputEnabled
        switch SnippetInjectionGate.inputDisposition(
            origin: origin,
            secureEventInputEnabled: secureInputEnabled,
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
                injectionInvalidationReason = .unmarkedKeyDown
                let sourcePID = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0
                injectionInvalidationOrigin = sourcePID <= 0 ? .unspecified
                    : (sourcePID == Int64(ProcessInfo.processInfo.processIdentifier) ? .ownProcess : .otherProcess)
            }
            return false
        case .resetAndPassThrough:
            resetTypingContext(reason: secureInputEnabled ? .secureInputEnabled : .ownAppFrontmost)
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

        // Activate suggestion mode on backslash, only if a text field is focused. The same
        // aggregate budget and exact focused object continue into panel anchoring: reacquiring
        // either here would turn a 0.4s safety bound into a chain of individually bounded calls.
        if character == "\\" {
            let axBudget = AXMessagingBudget()
            if let focusedElement = focusedTextInputElement(using: axBudget) {
                activateSuggestions(anchorFocusedElement: focusedElement, axBudget: axBudget)
                return false
            }
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

    private func activateSuggestions(
        anchorFocusedElement: AXUIElement,
        axBudget: AXMessagingBudget
    ) {
        suggestionActive = true
        suggestionSessionGeneration &+= 1
        suggestionQuery = ""
        suggestionDeleteCount = 1
        suggestionContextState = .localDisplayOnly
        suggestionTargetPID = processIdentifier(of: anchorFocusedElement)
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        suggestionTargetElement = anchorFocusedElement
        suggestionTargetRole = stringAttribute(
            of: anchorFocusedElement,
            attribute: kAXRoleAttribute as CFString,
            axBudget: axBudget)
        suggestionHasReadableAXContext = false
        suggestionCaretUnavailable = false
        pendingSpaceShortcutFocusValidation = false
        pendingSpaceShortcutInputSourceID = nil
        suggestionObserverAllowsAutoExpand = false
        suggestionFrecency = usage.makeRankingSnapshot()
        suggestionResultsUpdater.reset()
        pendingSelectionMemoryQuery = nil

        suggestionPanel.onSelect = { [weak self] snippet in
            self?.selectSuggestion(snippet)
        }
        suggestionPanel.onDismiss = { [weak self] in
            self?.dismissSuggestions()
        }

        updateSuggestionResults(
            anchorFocusedElement: anchorFocusedElement,
            axBudget: axBudget
        )
        startSuggestionAccessibilityObserver(anchorFocusedElement: anchorFocusedElement)
        scheduleSuggestionContextRefresh(
            operation: .activation,
            expectedQuery: "",
            allowAutoExpand: false)
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
                self.resetTypingContext(reason: .secureInputEnabled)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        suggestionSecureInputWatchdog = timer
    }

    private func stopSuggestionSecureInputWatchdog() {
        suggestionSecureInputWatchdog?.invalidate()
        suggestionSecureInputWatchdog = nil
    }

    private func startSuggestionAccessibilityObserver(anchorFocusedElement: AXUIElement) {
        let sessionGeneration = suggestionSessionGeneration
        Task { @MainActor [weak self] in
            // Leave the trigger's tap callback before bounded ancestor discovery.
            // Notification registration itself must use the worker below: yielding
            // a MainActor task alone would still stall subsequent key callbacks.
            await Task.yield()
            guard let self,
                  self.suggestionActive,
                  self.suggestionSessionGeneration == sessionGeneration else { return }
            self.installSuggestionAccessibilityObserver(
                anchorFocusedElement: anchorFocusedElement)
        }
    }

    private func installSuggestionAccessibilityObserver(anchorFocusedElement: AXUIElement) {
        stopSuggestionAccessibilityObserver()

        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(anchorFocusedElement, &pid)
        guard pidResult == .success else {
            recordExpansionAccessibility(
                operation: .observerRegistration,
                outcome: .unavailable,
                stateBefore: suggestionContextState,
                stateAfter: suggestionContextState,
                unavailable: axUnavailable(stage: .observerCreation, error: pidResult))
            return
        }

        var observer: AXObserver?
        let creationResult = AXObserverCreate(
            pid,
            { _, _, notification, refcon in
                guard let refcon else { return }
                let engine = Unmanaged<SnippetExpansionEngine>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                engine.receiveSuggestionAccessibilityNotification(notification)
            },
            &observer)
        guard creationResult == .success, let observer else {
            recordExpansionAccessibility(
                operation: .observerRegistration,
                outcome: .unavailable,
                stateBefore: suggestionContextState,
                stateAfter: suggestionContextState,
                unavailable: axUnavailable(stage: .observerCreation, error: creationResult))
            return
        }

        let elements = focusedTextContextCandidates(
            startingAt: anchorFocusedElement,
            axBudget: AXMessagingBudget(totalTimeoutSeconds: 0.1))
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handles = SuggestionObserverHandles(observer: observer, elements: elements, refcon: refcon)
        let registration = SuggestionObserverRegistration(
            count: elements.count * 2,
            register: { handles.register($0) },
            unregister: { handles.unregister($0) })
        let sessionGeneration = suggestionSessionGeneration
        suggestionObserverRegistration = registration
        registration.start { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self,
                      self.suggestionActive,
                      self.suggestionSessionGeneration == sessionGeneration,
                      self.suggestionObserverRegistration === registration else {
                    registration.cancel()
                    return
                }
                let failure = outcome.lastFailure.map {
                    self.axUnavailable(
                        stage: $0.index.isMultiple(of: 2) ? .valueNotification : .selectionNotification,
                        error: $0.error)
                }
                if let failure {
                    self.recordExpansionAccessibility(
                        operation: .observerRegistration, outcome: .unavailable,
                        stateBefore: self.suggestionContextState,
                        stateAfter: self.suggestionContextState, unavailable: failure)
                }
                guard outcome.registeredAny else {
                    self.stopSuggestionAccessibilityObserver()
                    return
                }
                let source = AXObserverGetRunLoopSource(handles.observer)
                self.suggestionAXObserver = handles.observer
                self.suggestionAXObserverSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                self.recordExpansionAccessibility(
                    operation: .observerRegistration, outcome: .observing,
                    stateBefore: self.suggestionContextState,
                    stateAfter: self.suggestionContextState, stage: .observerCreation)
            }
        }
    }

    private func stopSuggestionAccessibilityObserver() {
        if let source = suggestionAXObserverSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        suggestionObserverRegistration?.cancel()
        suggestionObserverRegistration = nil
        suggestionAXObserverSource = nil
        suggestionAXObserver = nil
    }

    /// AXObserver's source is installed on the main run loop, matching the
    /// event tap. Keep the C callback itself nonisolated and make that invariant
    /// explicit at the actor boundary.
    nonisolated private func receiveSuggestionAccessibilityNotification(_ notification: CFString) {
        MainActor.assumeIsolated {
            handleSuggestionAccessibilityNotification(notification)
        }
    }

    private func handleSuggestionAccessibilityNotification(_ notification: CFString) {
        guard suggestionActive, !isInjecting else { return }
        let stage: DiagnosticExpansionAXStage =
            notification == (kAXSelectedTextChangedNotification as CFString)
                ? .selectionNotification
                : .valueNotification
        refreshSuggestionContextFromFocusedText(
            operation: .observerNotification,
            expectedQuery: nil,
            readIsAuthoritative: true,
            allowAutoExpand: suggestionObserverAllowsAutoExpand,
            dismissOnMissingTrigger: true,
            notificationStage: stage)
    }

    private func validatePendingSpaceShortcutFocus() {
        guard pendingSpaceShortcutFocusValidation else { return }
        pendingSpaceShortcutFocusValidation = false
        guard suggestionActive else { return }

        let inputSourceIDBeforeShortcut = pendingSpaceShortcutInputSourceID
        pendingSpaceShortcutInputSourceID = nil
        let inputSourceIDAfterShortcut = currentKeyboardInputSourceIdentifier()
        let inputSourceChanged = inputSourceIDBeforeShortcut != nil
            && inputSourceIDAfterShortcut != nil
            && inputSourceIDBeforeShortcut != inputSourceIDAfterShortcut

        let axBudget = AXMessagingBudget(
            totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
            perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
        let focusedApplicationPID = systemWideFocusedApplicationPID(axBudget: axBudget)
        let frontmostApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if SnippetInjectionGate.spaceShortcutFocusInvalidatesContext(
            inputSourceChanged: inputSourceChanged,
            expectedTargetPID: suggestionTargetPID,
            focusedApplicationPID: focusedApplicationPID,
            frontmostApplicationPID: frontmostApplicationPID
        ) {
            resetTypingContext()
        }
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
        case unavailable(AXContextUnavailable)
        /// The host text before the caret contains multi-scalar graphemes;
        /// no backspace count is reliable there.
        case unsafe

    }

    private func readAcceptContext(
        matchingQuery query: String,
        axBudget: AXMessagingBudget
    ) -> AcceptContextRead {
        switch focusedTriggerContext(axBudget: axBudget) {
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
        case .unavailable(let unavailable):
            return .unavailable(unavailable)
        }
    }

    /// Accepts an explicit user selection (Tab/Return or a click in the
    /// panel). The snippet must be captured by the caller BEFORE any context
    /// refresh so that re-ranking can never change what the user picked.
    ///
    /// The delete count is normally taken from one fresh exact AX read. There
    /// is no retry delay. A never-confirmed AXTextArea may instead use the
    /// separately guarded local session while its exact target still matches.
    private func acceptSelectedSuggestion(_ snippet: Snippet) {
        let localQuery = suggestionQuery
        let stateBefore = suggestionContextState

        // Multi-scalar graphemes (ZWJ emoji, flags, combining marks) in the
        // query make the backspace count unreliable in web hosts — skip the
        // accept instead of corrupting host text.
        guard !containsMultiScalarGrapheme(localQuery) else {
            recordExpansionAccessibility(
                operation: .acceptance,
                outcome: .unsafe,
                stateBefore: stateBefore,
                stateAfter: stateBefore)
            pendingSelectionMemoryQuery = nil
            dismissSuggestions()
            return
        }

        let deletion: TriggerDeletion
        switch readAcceptContext(
            matchingQuery: localQuery,
            axBudget: AXMessagingBudget(
                totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
        ) {
        case .confirmed(let confirmed):
            deletion = .confirmed(confirmed)
            suggestionContextState = .axConfirmed
            suggestionHasReadableAXContext = true
            recordExpansionAccessibility(
                operation: .acceptance,
                outcome: .confirmed,
                stateBefore: stateBefore,
                stateAfter: .axConfirmed)
        case .mismatch:
            recordExpansionAccessibility(
                operation: .acceptance,
                outcome: .stale,
                stateBefore: stateBefore,
                stateAfter: stateBefore)
            pendingSelectionMemoryQuery = nil
            dismissSuggestions()
            return
        case .missingTrigger:
            recordExpansionAccessibility(
                operation: .acceptance,
                outcome: .missingTrigger,
                stateBefore: stateBefore,
                stateAfter: stateBefore)
            pendingSelectionMemoryQuery = nil
            dismissSuggestions()
            return
        case .unavailable(let unavailable):
            if unavailable.allowsLocalTracking,
               canUseUnconfirmedTextAreaLocalTracking(state: stateBefore) {
                deletion = .localTracking(query: localQuery)
                recordExpansionAccessibility(
                    operation: .acceptance,
                    outcome: .localTracking,
                    stateBefore: stateBefore,
                    stateAfter: stateBefore,
                    unavailable: unavailable)
            } else {
                recordExpansionAccessibility(
                    operation: .acceptance,
                    outcome: .unavailable,
                    stateBefore: stateBefore,
                    stateAfter: stateBefore,
                    unavailable: unavailable)
                pendingSelectionMemoryQuery = nil
                dismissSuggestions()
                return
            }
        case .unsafe:
            recordExpansionAccessibility(
                operation: .acceptance,
                outcome: .unsafe,
                stateBefore: stateBefore,
                stateAfter: stateBefore)
            pendingSelectionMemoryQuery = nil
            dismissSuggestions()
            return
        }

        let acceptedGeneration = injectionContextGeneration
        let acceptedTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let acceptedFocusTarget = store.isSecure(snippet.id)
            ? captureSecureExpansionFocusTarget(targetPID: acceptedTargetPID)
            : nil
        let ordinaryTarget = store.isSecure(snippet.id) ? nil : captureExpansionTarget()
        if !store.isSecure(snippet.id) {
            guard let ordinaryTarget,
                  suggestionTargetElement.map({ CFEqual($0, ordinaryTarget.element) }) ?? false else {
                Diagnostics.record(.pasteDelivery(outcome: .interrupted, restoration: .notBorrowed,
                    durationMilliseconds: 0, hadFingerprint: false,
                    progress: .init(reason: .focusedElementChanged, plannedDeletes: deletion.characterCount)))
                pendingSelectionMemoryQuery = nil
                dismissSuggestions()
                statusText = "Expansion stopped because the original input field changed."
                return
            }
        }
        // Captured before `dismissSuggestions()` clears the query. Only an
        // explicit accept teaches selection memory; auto-expansions never do.
        pendingSelectionMemoryQuery = localQuery
        dismissSuggestions()

        guard deletion.characterCount > 0 else {
            pendingSelectionMemoryQuery = nil
            return
        }

        if store.isSecure(snippet.id) {
            // Secure authentication is asynchronous and owns this outer gate
            // until its separately revalidated insertion completes.
            beginInjection()
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.endInjection() }
                await self.authenticateAndPerformSecureExpansion(
                    shell: snippet,
                    query: localQuery,
                    acceptedDeletion: deletion,
                    acceptedGeneration: acceptedGeneration,
                    acceptedTargetPID: acceptedTargetPID,
                    acceptedFocusTarget: acceptedFocusTarget)
            }
        } else {
            enqueueExpansion(of: snippet, deletion: deletion,
                expectedGeneration: acceptedGeneration, expectedTargetPID: acceptedTargetPID,
                expectedTarget: ordinaryTarget)
        }
    }

    /// Turns a content-free secure shell into a one-use expansion only after the user
    /// authenticates. The prompt can remain open for seconds, so the original app,
    /// focused control, and generation are checked again before plaintext is converted
    /// to a String or inserted. Controls with a readable caret must also prove the exact
    /// trigger again; never-readable text areas retain only their uninterrupted local proof.
    private func authenticateAndPerformSecureExpansion(
        shell: Snippet,
        query: String,
        acceptedDeletion: TriggerDeletion,
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
        // Keep ownership if the acceptance key is still held through Touch ID. A fresh
        // nonrepeat key-down reconciles any release hidden by Secure Event Input.
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
            locallyTrackedDeletion: acceptedDeletion.provenance == .localTracking
                ? acceptedDeletion
                : nil,
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
        let startedAt = ContinuousClock.now
        var succeeded = false
        var reason = DiagnosticSecurePasteReason.applicationUnavailable
        var attempts = 0
        var confirmations = 0
        var firstWaitReason = DiagnosticSecurePasteReason.none
        defer {
            let elapsed = startedAt.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            Diagnostics.record(.securePaste(stage: .handoff,
                outcome: Task.isCancelled || reason == .cancelled ? .cancelled : (succeeded ? .succeeded : .failed),
                target: .focused, transport: .none, reason: Task.isCancelled ? .cancelled : reason,
                attempts: attempts, durationMilliseconds: milliseconds, axErrorCode: nil, failure: nil,
                handoff: .init(source: .secureExpansion, afterAuthentication: true,
                    confirmations: confirmations,
                    requiredConfirmations: SecurePasteAuthenticationHandoffPolicy.requiredConsecutiveFocusConfirmations,
                    firstWaitReason: firstWaitReason)))
        }
        guard !Task.isCancelled, acceptedGeneration == injectionContextGeneration, listening
        else { reason = .cancelled; return false }
        guard let target = NSRunningApplication(processIdentifier: targetPID),
              !target.isTerminated
        else { return false }

        // Run after both LocalAuthentication and the Keychain read have completed:
        // either system dialog can outlive its NSWorkspace activation state.
        _ = target.activate()
        let report = await SecurePasteFocusHandoff.run(
            mode: .afterAuthentication,
            sleep: { delay in try? await Task.sleep(for: delay) }
        ) { [self] in
            guard acceptedGeneration == injectionContextGeneration, listening,
                  !target.isTerminated else { return .cancelled }
            guard !secureEventInputEnabled else { return .secureInputPending }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                _ = target.activate()
                return .applicationNotFrontmost
            }
            _ = target.activate()
            return restoreKeyboardFocus(to: focusTarget, targetPID: targetPID)
                ? .valid : .focusUnavailable
        }
        attempts = report.attempts
        confirmations = report.consecutiveConfirmations
        firstWaitReason = diagnosticReason(report.firstTransient ?? .valid)
        succeeded = report.validation == .valid
        reason = diagnosticReason(succeeded ? (report.firstTransient ?? .valid) : report.validation)
        return succeeded
    }

    private func confirmedSecureDeletionAfterAuthentication(
        query: String,
        locallyTrackedDeletion: TriggerDeletion?,
        acceptedGeneration: UInt,
        targetPID: pid_t,
        focusTarget: SecureExpansionFocusTarget
    ) async -> SecureDeletionRevalidation {
        var consecutiveUnconfirmedReads = 0
        var localFallbackRemainsEligible = locallyTrackedDeletion != nil

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
            if secureEventInputEnabled {
                consecutiveUnconfirmedReads = 0
                continue
            }
            guard restoreKeyboardFocus(to: focusTarget, targetPID: targetPID) else {
                consecutiveUnconfirmedReads = 0
                continue
            }
            switch readAcceptContext(
                matchingQuery: query,
                axBudget: AXMessagingBudget()
            ) {
            case .confirmed(let context):
                recordExpansionAccessibility(
                    operation: .secureRevalidation,
                    outcome: .confirmed,
                    stateBefore: .axConfirmed,
                    stateAfter: .axConfirmed)
                return .confirmed(.confirmed(context))
            case .unavailable(let unavailable):
                if unavailable.allowsLocalTracking {
                    consecutiveUnconfirmedReads += 1
                } else {
                    consecutiveUnconfirmedReads = 0
                    if unavailable.failure == .invalidRange {
                        localFallbackRemainsEligible = false
                    }
                }
                recordExpansionAccessibility(
                    operation: .secureRevalidation,
                    outcome: .unavailable,
                    stateBefore: locallyTrackedDeletion == nil ? .axConfirmed : .localDisplayOnly,
                    stateAfter: locallyTrackedDeletion == nil ? .uncertainAfterHostEdit : .localDisplayOnly,
                    unavailable: unavailable)
            case .mismatch:
                // Once the exact control exposes readable text that disagrees with
                // the accepted query, an unreadable read may not revive local trust.
                localFallbackRemainsEligible = false
                consecutiveUnconfirmedReads = 0
                recordExpansionAccessibility(
                    operation: .secureRevalidation,
                    outcome: .stale,
                    stateBefore: .axConfirmed,
                    stateAfter: .uncertainAfterHostEdit)
                continue
            case .missingTrigger:
                localFallbackRemainsEligible = false
                consecutiveUnconfirmedReads = 0
                recordExpansionAccessibility(
                    operation: .secureRevalidation,
                    outcome: .missingTrigger,
                    stateBefore: locallyTrackedDeletion == nil ? .axConfirmed : .localDisplayOnly,
                    stateAfter: locallyTrackedDeletion == nil ? .uncertainAfterHostEdit : .localDisplayOnly)
            case .unsafe:
                recordExpansionAccessibility(
                    operation: .secureRevalidation,
                    outcome: .unsafe,
                    stateBefore: .axConfirmed,
                    stateAfter: .uncertainAfterHostEdit)
                return .triggerNotConfirmed
            }

            let targetStillMatches =
                acceptedGeneration == injectionContextGeneration
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
                && currentFocusMatches(focusTarget.element)
            if localFallbackRemainsEligible,
               SecureLocalTriggerRevalidationPolicy.canAuthorize(
                   deletion: locallyTrackedDeletion,
                   query: query,
                   consecutiveUnconfirmedReads: consecutiveUnconfirmedReads,
                   secureEventInputEnabled: secureEventInputEnabled,
                   targetStillMatches: targetStillMatches),
               let locallyTrackedDeletion {
                recordExpansionAccessibility(
                    operation: .secureRevalidation,
                    outcome: .localTracking,
                    stateBefore: .localDisplayOnly,
                    stateAfter: .localDisplayOnly)
                return .confirmed(locallyTrackedDeletion)
            }
        }
        return secureEventInputEnabled ? .secureInputDidNotSettle : .triggerNotConfirmed
    }

    private func dismissSuggestions() {
        typedBuffer = ""
        suggestionResultsUpdater.reset()
        // Before the guard: another path may have already cleared `suggestionActive`, and the timer
        // would then outlive the session it belongs to.
        stopSuggestionSecureInputWatchdog()
        stopSuggestionAccessibilityObserver()
        suggestionTargetPID = nil
        suggestionTargetElement = nil
        suggestionTargetRole = nil
        suggestionHasReadableAXContext = false
        suggestionCaretUnavailable = false
        pendingSpaceShortcutFocusValidation = false
        pendingSpaceShortcutInputSourceID = nil

        guard suggestionActive else { return }
        suggestionActive = false
        suggestionSessionGeneration &+= 1
        suggestionQuery = ""
        suggestionDeleteCount = 1
        suggestionContextState = .localDisplayOnly
        suggestionObserverAllowsAutoExpand = false
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
            return false
        }

        // Emacs Ctrl+W - let the host edit, then read the real text before the caret.
        if ctrl && !command && !option && event.keyCode == UInt16(kVK_ANSI_W) {
            markSuggestionUncertainAfterHostEdit()
            return false
        }

        // Modifier+Space is user-configurable: it may change the input source or
        // open a launcher. Pass it through, then classify the result by actual
        // keyboard focus after key-up rather than hardcoding its modifiers.
        if event.keyCode == UInt16(kVK_Space),
           !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            pendingSpaceShortcutFocusValidation = true
            pendingSpaceShortcutInputSourceID = currentKeyboardInputSourceIdentifier()
            return false
        }

        // Dedicated exclusion: users often screenshot the suggestions panel itself.
        // Keep the session active for Cmd+Shift+3/4/5/6 (+optional Ctrl).
        if isScreenshotShortcut(event) {
            return false
        }

        // Host apps do not agree on word boundaries, so let the app delete and
        // wait for its AX notification instead of trying to model the shortcut.
        if option && !command && event.keyCode == UInt16(kVK_Delete) {
            markSuggestionUncertainAfterHostEdit()
            return false
        }

        // Command/Option combos dismiss (Cmd+Z, Option produces special chars, etc.)
        if command || option {
            typedBuffer = ""
            dismissSuggestions()
            return false
        }

        // Other Ctrl combos and function keys are host-owned. Mark the local
        // display uncertain; an AX notification may reconcile it immediately.
        if ctrl {
            markSuggestionUncertainAfterHostEdit()
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
            // Own the entire accepted key press, even if insertion finishes before key-up.
            acceptanceKeys.recordAcceptedKeyDown(keyCode: event.keyCode)
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

            // A text area with no usable insertion caret may use the same
            // suppressed-final-key strategy as the panel-less typed-buffer fallback,
            // but only for ordinary snippets. Secure snippets always require an
            // explicit Tab/Return choice and Local Authentication.
            if let snippet = unambiguousExactMatch(for: suggestionQuery),
               !store.isSecure(snippet.id),
               canUseUnconfirmedTextAreaLocalTracking(state: suggestionContextState) {
                recordExpansionAccessibility(
                    operation: .printableEdit,
                    outcome: .localTracking,
                    stateBefore: suggestionContextState,
                    stateAfter: suggestionContextState)
                selectSuggestion(
                    snippet,
                    deletion: .pendingLastCharacter(query: suggestionQuery))
                return true
            }

            scheduleSuggestionContextRefresh(
                operation: .printableEdit,
                expectedQuery: suggestionQuery,
                allowAutoExpand: true)
        } else {
            dismissSuggestions()
        }
        return false
    }

    private func scheduleSuggestionContextRefresh(
        operation: DiagnosticExpansionAXOperation,
        expectedQuery: String,
        allowAutoExpand: Bool
    ) {
        suggestionSyncGeneration += 1
        let generation = suggestionSyncGeneration

        Task { @MainActor [weak self] in
            // Yield only to get out of the event-tap callback and let the host
            // receive the key. This is scheduling, not a wall-clock debounce.
            await Task.yield()
            guard let self,
                  self.suggestionActive,
                  self.suggestionSyncGeneration == generation,
                  !self.isInjecting else {
                return
            }
            self.refreshSuggestionContextFromFocusedText(
                operation: operation,
                expectedQuery: expectedQuery,
                readIsAuthoritative: false,
                allowAutoExpand: allowAutoExpand,
                dismissOnMissingTrigger: false)
        }
    }

    private func appendLocalSuggestionCharacter(_ character: Character) {
        guard suggestionActive else { return }
        let stateBefore = suggestionContextState
        suggestionContextState = suggestionContextState.afterLocalPrintableEdit
        suggestionObserverAllowsAutoExpand = true
        suggestionQuery.append(character)
        suggestionDeleteCount = 1 + suggestionQuery.count
        recordExpansionAccessibility(
            operation: .printableEdit,
            outcome: .observing,
            stateBefore: stateBefore,
            stateAfter: suggestionContextState)
        updateSuggestionResults()
    }

    private func applyLocalSuggestionBackspace() {
        guard suggestionActive else { return }
        let stateBefore = suggestionContextState
        suggestionContextState = suggestionContextState.afterAmbiguousHostEdit
        suggestionObserverAllowsAutoExpand = false

        if suggestionQuery.isEmpty {
            recordExpansionAccessibility(
                operation: .hostEdit,
                outcome: .observing,
                stateBefore: stateBefore,
                stateAfter: suggestionContextState)
            dismissSuggestions()
            return
        }

        suggestionQuery.removeLast()
        suggestionDeleteCount = 1 + suggestionQuery.count
        recordExpansionAccessibility(
            operation: .hostEdit,
            outcome: .observing,
            stateBefore: stateBefore,
            stateAfter: suggestionContextState)
        updateSuggestionResults()
    }

    private func markSuggestionUncertainAfterHostEdit() {
        guard suggestionActive else { return }
        let stateBefore = suggestionContextState
        suggestionContextState = suggestionContextState.afterAmbiguousHostEdit
        suggestionObserverAllowsAutoExpand = false
        recordExpansionAccessibility(
            operation: .hostEdit,
            outcome: .observing,
            stateBefore: stateBefore,
            stateAfter: suggestionContextState)
    }

    private func refreshSuggestionContextFromFocusedText(
        operation: DiagnosticExpansionAXOperation,
        expectedQuery: String?,
        readIsAuthoritative: Bool,
        allowAutoExpand: Bool,
        dismissOnMissingTrigger: Bool,
        notificationStage: DiagnosticExpansionAXStage? = nil
    ) {
        guard suggestionActive else { return }
        let stateBefore = suggestionContextState

        switch focusedTriggerContext(axBudget: AXMessagingBudget()) {
        case .found(let context):
            if !readIsAuthoritative,
               let expectedQuery,
               normalizedForSuggestionMatching(context.query)
                   != normalizedForSuggestionMatching(expectedQuery) {
                // The host has not applied our just-observed key yet. Never
                // roll the optimistic panel backwards based on this stale read.
                recordExpansionAccessibility(
                    operation: operation,
                    outcome: .stale,
                    stateBefore: stateBefore,
                    stateAfter: stateBefore,
                    stage: notificationStage)
                return
            }

            suggestionQuery = context.query
            suggestionDeleteCount = context.triggerLength
            suggestionContextState = .axConfirmed
            suggestionHasReadableAXContext = true
            // One printable key grants at most one opportunity to auto-expand.
            // Duplicate or later programmatic AX notifications may still
            // reconcile the panel, but cannot spend the same authorization.
            suggestionObserverAllowsAutoExpand = false
            recordExpansionAccessibility(
                operation: operation,
                outcome: .confirmed,
                stateBefore: stateBefore,
                stateAfter: .axConfirmed,
                stage: notificationStage)

            if allowAutoExpand,
               !context.query.isEmpty,
               let snippet = unambiguousExactMatch(for: context.query) {
                selectSuggestion(snippet, deletion: .confirmed(context))
                return
            }

            updateSuggestionResults()

        case .missingTrigger:
            recordExpansionAccessibility(
                operation: operation,
                outcome: .missingTrigger,
                stateBefore: stateBefore,
                stateAfter: stateBefore,
                stage: notificationStage)
            if dismissOnMissingTrigger {
                typedBuffer = ""
                dismissSuggestions()
            }

        case .unavailable(let unavailable):
            recordExpansionAccessibility(
                operation: operation,
                outcome: .unavailable,
                stateBefore: stateBefore,
                stateAfter: stateBefore,
                unavailable: unavailable)
        }
    }

    /// Returns a snippet only if `query` exactly matches one keyword and no other keyword starts with `query`.
    private func unambiguousExactMatch(for query: String) -> Snippet? {
        suggestionSearchSnapshot().unambiguousOrdinaryMatch(for: query)
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

    /// Capability-based fallback for an AXTextArea that never supplied a usable
    /// insertion caret: no ambiguous edit, no earlier readable AX context, same process,
    /// and the exact same focused AX object. No application identity is consulted.
    private func canUseUnconfirmedTextAreaLocalTracking(
        state: SuggestionContextState
    ) -> Bool {
        let targetStillMatches: Bool
        if let targetPID = suggestionTargetPID,
           let targetElement = suggestionTargetElement,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
            targetStillMatches = currentFocusMatches(targetElement)
        } else {
            targetStillMatches = false
        }

        return UnconfirmedTextAreaSuggestionPolicy.canAuthorizeLocalTracking(
            focusedRole: suggestionTargetRole,
            contextState: state,
            hasReadableAXContext: suggestionHasReadableAXContext,
            caretUnavailable: suggestionCaretUnavailable,
            targetStillMatches: targetStillMatches)
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

    private func securePasteSuggestionItems(
        query rawQuery: String,
        snapshot: SuggestionSearchIndex.Snapshot,
        frecency: FrecencySnapshot
    ) -> [SuggestionItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippets = snapshot.entries.map(\.snippet)
        let displayOrder = snapshot.displayOrder

        if query.isEmpty {
            return snippets
                .enumerated()
                .map { offset, snippet in
                    (
                        item: SuggestionItem(
                            snippet: snippet,
                            isSecure: store.isSecure(snippet.id),
                            score: 0,
                            frecency: frecency.value(for: snippet.id)
                        ),
                        order: offset
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.item.isSecure != rhs.item.isSecure {
                        return lhs.item.isSecure
                    }
                    return SnippetFrecency.emptyQueryRanks(
                        lhsPinned: lhs.item.snippet.isPinned,
                        lhsFrecency: lhs.item.frecency,
                        lhsOrder: lhs.order,
                        rhsPinned: rhs.item.snippet.isPinned,
                        rhsFrecency: rhs.item.frecency,
                        rhsOrder: rhs.order
                    )
                }
                .map(\.item)
        }

        let foldedQuery = SnippetFrecency.foldedForMatching(query)
        let binding = frecency.bindingTable(forQuery: query)
        let preparedQuery = FuzzyMatch.PreparedQuery(query, locale: snapshot.locale)
        var workspace = FuzzyMatch.Workspace()
        return snapshot.entries.compactMap { entry -> SuggestionItem? in
            let snippet = entry.snippet
            let nameResult = FuzzyMatch.score(query: preparedQuery, target: entry.preparedName,
                                             includingRanges: false, workspace: &workspace)
            let keywordResult = FuzzyMatch.score(query: preparedQuery, target: entry.preparedKeyword,
                                                includingRanges: false, workspace: &workspace)
            var tagMatched = false
            var tagScore = Int.min
            for tag in entry.preparedTags {
                let result = FuzzyMatch.score(query: preparedQuery, target: tag, includingRanges: false, workspace: &workspace)
                if result.matched {
                    tagMatched = true
                    tagScore = max(tagScore, result.score)
                }
            }

            guard nameResult.matched || keywordResult.matched || tagMatched else { return nil }
            return SuggestionItem(
                snippet: snippet,
                isSecure: entry.isSecure,
                score: max(max(nameResult.score, keywordResult.score), tagScore),
                keywordRank: SnippetFrecency.keywordRank(
                    foldedKeyword: entry.foldedKeyword,
                    foldedQuery: foldedQuery,
                    hasKeywordMatchRanges: keywordResult.matched && !preparedQuery.isEmpty
                ),
                bindingWeight: binding[snippet.id] ?? 0,
                frecency: frecency.value(for: snippet.id),
                highlightSource: SuggestionHighlightSource(
                    query: preparedQuery, name: entry.preparedName, keyword: entry.preparedKeyword)
            )
        }
        .map { (key: rankingKey(for: $0, displayOrder: displayOrder), item: $0) }
        .sorted { lhs, rhs in
            switch SecurePasteSuggestionRankingPolicy.decision(
                lhsScore: lhs.key.score,
                lhsKeywordRank: lhs.key.keywordRank,
                lhsIsSecure: lhs.item.isSecure,
                rhsScore: rhs.key.score,
                rhsKeywordRank: rhs.key.keywordRank,
                rhsIsSecure: rhs.item.isSecure
            ) {
            case .lhsFirst:
                return true
            case .rhsFirst:
                return false
            case .tied:
                return SnippetFrecency.ranks(lhs.key, before: rhs.key)
            }
        }
        .map(\.item)
    }

    private func updateSuggestionResults(
        anchorFocusedElement: AXUIElement? = nil,
        axBudget: AXMessagingBudget? = nil
    ) {
        suggestionResultsUpdater.updateIfNeeded(
            query: suggestionQuery,
            ordinary: store.snippets,
            secure: store.secureProvider?.secureShellsForDisplay() ?? []
        ) {
            renderSuggestionResults(
                anchorFocusedElement: anchorFocusedElement,
                axBudget: axBudget)
        }
    }

    private func renderSuggestionResults(
        anchorFocusedElement: AXUIElement?,
        axBudget: AXMessagingBudget?
    ) {
        let scored = SuggestionSearchIndex.suggestions(
            query: suggestionQuery, snapshot: suggestionSearchSnapshot(), frecency: suggestionFrecency)

        if scored.isEmpty {
            suggestionPanel.hide()
        } else {
            suggestionPanel.show(
                items: Array(scored),
                anchorFocusedElement: anchorFocusedElement,
                axBudget: axBudget
            )
        }
    }

    private func suggestionSearchSnapshot() -> SuggestionSearchIndex.Snapshot {
        suggestionSearchIndex.snapshot(
            ordinary: store.snippets,
            secure: store.secureProvider?.secureShellsForDisplay() ?? [])
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

    private func captureExpansionTarget() -> ExpansionTarget? {
        let budget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                       perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
        guard let element = frontmostFocusedElement(axBudget: budget) else { return nil }
        let range = selectedRange(of: element, axBudget: budget)
        let selection = range.flatMap { range -> NSRange? in
            guard range.location >= 0, range.length >= 0,
                  range.location <= Int.max - range.length else { return nil }
            return NSRange(location: range.location, length: range.length)
        }
        return ExpansionTarget(element: element, selection: selection)
    }

    private func expansionTargetMatches(_ target: ExpansionTarget, checkSelection: Bool) -> Bool {
        let budget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                       perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
        guard currentFocusMatches(target.element, axBudget: budget) else { return false }
        guard checkSelection, let expected = target.selection else { return true }
        guard let actual = selectedRange(of: target.element, axBudget: budget) else { return false }
        return actual.location == expected.location && actual.length == expected.length
    }

    /// The one place an expansion is scheduled. Callers stay synchronous — a tap callback has to
    /// return its suppress decision immediately — while delivery runs on the queue afterwards.
    private func enqueueExpansion(
        of snippet: Snippet,
        deletion: TriggerDeletion,
        authorization: ExpansionAuthorization = .ordinary,
        expectedGeneration: UInt? = nil,
        expectedTargetPID: pid_t? = nil,
        securePlaintext: SecurePlaintextLease? = nil,
        expectedTarget: ExpansionTarget? = nil
    ) {
        guard !isPreparingForTermination else {
            securePlaintext?.wipe()
            return
        }
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
        let target = expectedTarget ?? captureExpansionTarget()
        if deletion.provenance == .accessibilityConfirmed, target == nil {
            securePlaintext?.wipe()
            Diagnostics.record(.pasteDelivery(outcome: .interrupted, restoration: .notBorrowed,
                durationMilliseconds: 0, hadFingerprint: false,
                progress: .init(reason: .targetUnavailable, plannedDeletes: deletion.characterCount)))
            statusText = "Expansion stopped because the original input field is unavailable."
            return
        }
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
                secureFocusTarget: nil,
                ordinaryTarget: target
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
        secureFocusTarget: SecureExpansionFocusTarget?,
        ordinaryTarget: ExpansionTarget? = nil
    ) async {
        // Defense in depth for any future caller that bypasses the queue wrapper.
        defer { securePlaintext?.wipe() }
        if let reason = injectionBlockReason(generation: generation, targetPID: targetPID) {
            var progress = DiagnosticPasteProgress(reason: reason, plannedDeletes: deletion.characterCount)
            if reason == .unmarkedKeyDown { progress.interruptionOrigin = injectionInvalidationOrigin }
            Diagnostics.record(.pasteDelivery(outcome: .interrupted, restoration: .notBorrowed,
                durationMilliseconds: 0, hadFingerprint: false, progress: progress))
            let block = injectionBlockDescription(generation: generation, targetPID: targetPID)
                ?? "the input context changed before insertion"
            statusText = "Skipped \(snippet.displayName): \(block)."
            return
        }
        if let secureFocusTarget,
           !restoreKeyboardFocus(to: secureFocusTarget, targetPID: targetPID) {
            Diagnostics.record(.pasteDelivery(outcome: .interrupted, restoration: .notBorrowed,
                durationMilliseconds: 0, hadFingerprint: false,
                progress: .init(reason: .focusedElementChanged, plannedDeletes: deletion.characterCount)))
            statusText = "Skipped \(snippet.displayName): the original input field did not regain keyboard focus."
            return
        }
        let expectedElement = secureFocusTarget?.element ?? ordinaryTarget?.element
        if let ordinaryTarget,
           !expansionTargetMatches(ordinaryTarget, checkSelection: deletion.provenance == .accessibilityConfirmed) {
            Diagnostics.record(.pasteDelivery(outcome: .interrupted, restoration: .notBorrowed,
                durationMilliseconds: 0, hadFingerprint: false,
                progress: .init(reason: .selectionChanged, plannedDeletes: deletion.characterCount)))
            statusText = "Expansion stopped because the original field or selection changed."
            return
        }
        // `{clipboard}` has to see the user's clipboard, never a snippet we are still holding.
        guard finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) else {
            statusText = "Skipped \(snippet.displayName): your previous clipboard is still being restored."
            return
        }

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

        let accessibilityStart = ContinuousClock.now
        var accessibilityProgress = DiagnosticAccessibilityReplacementProgress()
        let replacement = replaceUsingAccessibility(
            deletion: deletion,
            with: resolvedText,
            expectedFocusedElement: expectedElement,
            generation: generation, targetPID: targetPID,
            progress: &accessibilityProgress)
        let accessibilityElapsed = accessibilityStart.duration(to: .now).components
        let accessibilityDuration = accessibilityElapsed.seconds * 1_000
            + accessibilityElapsed.attoseconds / 1_000_000_000_000_000
        switch AccessibilityReplacementPolicy.action(for: replacement, provenance: deletion.provenance) {
        case .commit:
            Diagnostics.record(.accessibilityReplacement(outcome: .delivered,
                durationMilliseconds: accessibilityDuration, progress: accessibilityProgress))
            recordExpansion(of: snippet, bindingQuery: bindingQuery)
            return
        case .abort:
            Diagnostics.record(.accessibilityReplacement(
                outcome: replacement == .attemptedUnconfirmed ? .ambiguous : .rejected,
                durationMilliseconds: accessibilityDuration, progress: accessibilityProgress))
            if replacement == .attemptedUnconfirmed {
                statusText = "Insertion could not be confirmed. Check the field before trying again."
            } else if replacement == .cancelledBeforeText {
                statusText = "Expansion stopped before writing text. Check the field before trying again."
            } else {
                statusText = "Skipped \(snippet.displayName): the text before the cursor changed."
            }
            return
        case .useEvents:
            break
        }

        if let ordinaryTarget,
           !expansionTargetMatches(ordinaryTarget, checkSelection: deletion.provenance == .accessibilityConfirmed) {
            var progress = DiagnosticPasteProgress(reason: .selectionChanged, plannedDeletes: deletion.characterCount)
            progress.accessibilityOutcome = replacement == .unavailable ? .unavailable : .rejected
            Diagnostics.record(.pasteDelivery(outcome: .interrupted, restoration: .notBorrowed,
                durationMilliseconds: 0, hadFingerprint: false, progress: progress))
            statusText = "Expansion stopped because the original field or selection changed."
            return
        }

        let deleteCount = adjustedDeleteCountForActiveSelection(baseDeleteCount: deletion.characterCount)
        let eventOutcome = await replaceTypedText(
            characterCount: deleteCount,
            with: resolvedText,
            generation: generation,
            targetPID: targetPID,
            isConcealed: authorization.concealsPasteboard,
            expectedFocusedElement: expectedElement,
            deletion: deletion,
            accessibilityOutcome: replacement == .unavailable ? .unavailable : .rejected
        )
        switch eventOutcome {
        case .failed:
            if authorization.authenticatesSecureSnippet {
                statusText = "Authentication succeeded, but Snippets could not insert \(snippet.displayName)."
            } else {
                statusText = "Expansion stopped before paste. Check the field before trying again."
            }
        case .inserted:
            recordExpansion(of: snippet, bindingQuery: bindingQuery)
        case .insertedWithPasteboardRecoveryPending:
            recordExpansion(of: snippet, bindingQuery: bindingQuery)
            statusText = "Expanded \(snippet.displayName); restoring your previous clipboard is still pending."
        case .unconfirmed(let pending):
            reportUnconfirmedPaste(recoveryPending: pending)
        }
    }

    private func reportUnconfirmedPaste(recoveryPending: Bool) {
        statusText = "Paste was sent, but insertion could not be confirmed. Check the field before trying again."
        if recoveryPending {
            statusText += " Restoring your previous clipboard is still pending."
        }
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

    private func injectionIsAllowed(
        generation: UInt,
        targetPID: pid_t?,
        allowingTerminationDrain: Bool = false
    ) -> Bool {
        injectionBlockDescription(
            generation: generation,
            targetPID: targetPID,
            allowingTerminationDrain: allowingTerminationDrain
        ) == nil
    }

    private func injectionBlockDescription(
        generation: UInt,
        targetPID: pid_t?,
        allowingTerminationDrain: Bool = false
    ) -> String? {
        switch injectionBlockReason(generation: generation, targetPID: targetPID,
                                    allowingTerminationDrain: allowingTerminationDrain) {
        case nil: return nil
        case .quitting: return "the app is quitting"
        case .listeningStopped: return "global expansion stopped before insertion"
        case .secureInputEnabled: return "macOS still had secure keyboard entry enabled"
        case .ownAppFrontmost: return "Snippets itself became the target"
        case .frontmostAppChanged: return "another app became active before insertion"
        default: return "the input context changed before insertion"
        }
    }

    private func injectionBlockReason(
        generation: UInt,
        targetPID: pid_t?,
        allowingTerminationDrain: Bool = false
    ) -> DiagnosticPasteReason? {
        if isPreparingForTermination, !allowingTerminationDrain { return .quitting }
        if generation != injectionContextGeneration { return injectionInvalidationReason }
        if !listening && !clipboardHistoryInsertionActive { return .listeningStopped }
        if secureEventInputEnabled { return .secureInputEnabled }
        guard let targetPID else {
            return frontmostProcessIsThisApp() ? .ownAppFrontmost : nil
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            return .frontmostAppChanged
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

    /// Direct replacement without synthetic events or clipboard involvement. It is synchronous
    /// to avoid scheduling gaps, but cross-process AX reads and writes are not atomic.
    private func replaceUsingAccessibility(
        deletion: TriggerDeletion,
        with replacement: String,
        expectedFocusedElement: AXUIElement?,
        generation: UInt,
        targetPID: pid_t?,
        progress: inout DiagnosticAccessibilityReplacementProgress
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
              let caret = selectedRange(of: element),
              caret.location >= 0, caret.length >= 0
        else { return .unavailable }
        guard expectedFocusedElement.map({ CFEqual(element, $0) }) ?? true else { return .cancelledBeforeText }

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
                replacement: replacement,
                originalSelection: caretRange, expectedTrigger: deletion.expectedText,
                generation: generation, targetPID: targetPID,
                progress: &progress
            )
        }

        // Checked after the text comparison, not before: a mismatch has to fail closed even in a
        // field we cannot write, otherwise it would fall through to deleting somebody else's text.
        guard isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element),
              isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
        else { return .unavailable }

        // If this transport cannot verify its write, choose native paste before changing
        // anything. Discovering that limitation after the setter would be too late to retry.
        guard let valueBefore = stringAttribute(of: element, attribute: kAXValueAttribute as CFString)
        else { return .unavailable }
        let selectedBefore = caret.length == 0 ? "" : (
            stringForRange(of: element, range: caret)
                ?? stringAttribute(of: element, attribute: kAXSelectedTextAttribute as CFString))
        guard let selectedBefore else { return .unavailable }
        let proof: VerifiedTriggerSelection
        switch VerifiedTriggerSelection.prepare(deletion: deletion, textBeforeCaret: before,
            originalSelection: caretRange, readSelectedText: { selectedBefore }) {
        case .verified(let selection): proof = selection
        case .unavailable: return .unavailable
        case .rejected: return .cancelledBeforeText
        }
        guard let currentSelection = selectedRange(of: element),
              currentSelection.location == caret.location, currentSelection.length == caret.length,
              currentFocusMatches(element) else { return .cancelledBeforeText }

        let prepared = PreparedTriggerSelection(element: element, verification: proof)
        var confirmedValue: String?
        func contextIsValid() -> Bool {
            let budget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                           perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
            return injectionIsAllowed(generation: generation, targetPID: targetPID)
                && currentFocusMatches(element, axBudget: budget)
        }
        let result = AccessibilitySelectedTextTransaction.run(
            targetIsInsideWebArea: securePasteWebAncestry(element, axBudget: AXMessagingBudget()),
            contextIsValid: contextIsValid,
            originalSelectionMatches: {
                guard let selected = selectedRange(of: element),
                      selected.location == caret.location, selected.length == caret.length,
                      let value = stringAttribute(of: element, attribute: kAXValueAttribute as CFString)
                else { return false }
                return value.utf16.elementsEqual(valueBefore.utf16)
            },
            selectTrigger: { setSelectedRange(plan.replacementRange, on: element) },
            selectedTriggerMatches: {
                triggerSelectionMatches(prepared, budget: AXMessagingBudget(), allowSelectedTextFallback: true)
            },
            writeText: {
                // Set before crossing the host boundary, even if it replies with an error.
                progress.textWriteAttempted = true
                return setSelectedText(replacement, on: element)
            },
            confirmText: {
                guard let value = stringAttribute(of: element, attribute: kAXValueAttribute as CFString),
                      AccessibilityTextReplacement.writeLanded(valueBefore: valueBefore,
                          valueAfter: value, plan: plan, replacement: replacement) else { return false }
                confirmedValue = value
                return true
            },
            finishCaret: {
                if let confirmedValue,
                   let location = AccessibilityTextReplacement.confirmedCaretLocation(
                       valueBefore: valueBefore, valueAfter: confirmedValue, plan: plan, replacement: replacement),
                   contextIsValid() {
                    _ = setSelectedRange(NSRange(location: location, length: 0), on: element)
                }
            },
            restoreSelection: {
                progress.selectionRestoration = restoreTriggerSelection(prepared,
                    generation: generation, targetPID: targetPID, allowSelectedTextFallback: true)
            })
        switch result {
        case .unavailable: return .unavailable
        case .delivered: return .delivered
        case .selectionUnconfirmed: return .cancelledBeforeText
        case .textUnconfirmed: return .attemptedUnconfirmed
        }
    }

    /// Chromium's answer: rewrite the field's whole value, because that is the write its edit model
    /// hears. Only ever reached for a target `elementIsBrowserChrome` has vouched for — a one-line
    /// field in the browser's own UI, where "the whole value" is a URL, not somebody's document.
    private func replaceWholeValueUsingAccessibility(
        element: AXUIElement,
        plan: AccessibilityTextReplacement.Plan,
        replacement: String,
        originalSelection: NSRange,
        expectedTrigger: String,
        generation: UInt,
        targetPID: pid_t?,
        progress: inout DiagnosticAccessibilityReplacementProgress
    ) -> AccessibilityReplacement {
        guard isAttributeSettable(kAXValueAttribute as CFString, on: element),
              let valueBefore = stringAttribute(of: element, attribute: kAXValueAttribute as CFString)
        else { return .unavailable }

        // The plan was measured against the caret range, so a value that disagrees with it is a
        // model we do not understand — not something to overwrite wholesale.
        let text = valueBefore as NSString
        guard plan.replacementRange.location >= 0,
              NSMaxRange(plan.replacementRange) <= text.length,
              originalSelection.location >= plan.replacementRange.location,
              originalSelection.location <= text.length
        else { return .unavailable }

        let prefixRange = NSRange(location: plan.replacementRange.location,
                                  length: originalSelection.location - plan.replacementRange.location)
        guard text.substring(with: prefixRange).utf16.elementsEqual(expectedTrigger.utf16),
              let selected = selectedRange(of: element),
              selected.location == originalSelection.location, selected.length == originalSelection.length
        else { return .cancelledBeforeText }
        guard let newValue = AccessibilityTextReplacement.expectedValue(
            valueBefore: valueBefore, plan: plan, replacement: replacement) else { return .unavailable }
        guard injectionIsAllowed(generation: generation, targetPID: targetPID),
              currentFocusMatches(element) else { return .cancelledBeforeText }
        progress.textWriteAttempted = true
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newValue as CFString
        ) == .success else { return .attemptedUnconfirmed }

        guard let valueAfter = stringAttribute(of: element, attribute: kAXValueAttribute as CFString) else {
            // Readable before the write and not after: too little to justify a second attempt.
            return .attemptedUnconfirmed
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
            if let location = AccessibilityTextReplacement.confirmedCaretLocation(
                valueBefore: valueBefore, valueAfter: valueAfter, plan: plan, replacement: replacement),
               injectionIsAllowed(generation: generation, targetPID: targetPID),
               currentFocusMatches(element) {
                _ = setSelectedRange(NSRange(location: location, length: 0), on: element)
            }
            return .delivered
        }

        if valueAfter == valueBefore {
            return .attemptedUnconfirmed
        }
        // The field holds something we did not write. Saying `.unavailable` here would invite the
        // event path to paste on top of it.
        return .attemptedUnconfirmed
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

    private func setSelectedRange(_ range: NSRange, on element: AXUIElement, axBudget: AXMessagingBudget? = nil) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        if let axBudget {
            return axBudget.setAttributeValue(of: element,
                attribute: kAXSelectedTextRangeAttribute as CFString, value: value) == .success
        }
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

    /// Prepare without changing either the field or clipboard. A host that can select a
    /// range but cannot write AXSelectedText can still perform its own native paste.
    private func prepareTriggerSelection(
        deletion: TriggerDeletion?, element: AXUIElement?
    ) -> TriggerSelectionPreparation {
        guard let deletion, deletion.provenance == .accessibilityConfirmed,
              let app = NSWorkspace.shared.frontmostApplication,
              accessibilityWriteStrategy(for: app) != .none,
              let element else { return .unavailable }
        let budget = AXMessagingBudget()
        guard currentFocusMatches(element, axBudget: budget) else { return .rejected(.focusedElementChanged) }
        guard attributeIsSettable(kAXSelectedTextRangeAttribute as CFString, on: element, axBudget: budget),
              let original = selectedRange(of: element, axBudget: budget) else { return .unavailable }
        guard original.location >= 0, original.length >= 0,
              original.location <= Int.max - original.length else { return .rejected(.selectionChanged) }
        let readLength = max(maxBufferLength, deletion.expectedText.utf16.count)
        guard readLength <= VerifiedTriggerSelection.maximumReadUTF16Length,
              original.length <= VerifiedTriggerSelection.maximumReadUTF16Length - readLength else { return .unavailable }
        guard let before = textBeforeCaret(in: element, caretLocation: original.location,
                  maxCharacters: readLength, allowFullValueFallback: false, axBudget: budget)
        else { return .unavailable }
        // The prefix is authoritative even if a later selected-suffix read fails.
        let verification: VerifiedTriggerSelection
        switch VerifiedTriggerSelection.prepare(deletion: deletion, textBeforeCaret: before,
            originalSelection: NSRange(location: original.location, length: original.length),
            readSelectedText: { stringForRange(of: element, range: original, axBudget: budget) }) {
        case .verified(let selection): verification = selection
        case .unavailable: return .unavailable
        case .rejected: return .rejected(.triggerChanged)
        }
        let prepared = PreparedTriggerSelection(element: element, verification: verification)
        guard triggerSelectionMatches(prepared, originalSelection: true, budget: budget) else {
            return .rejected(.selectionChanged)
        }
        return .prepared(prepared)
    }

    private func triggerSelectionMatches(
        _ prepared: PreparedTriggerSelection, originalSelection: Bool = false,
        budget: AXMessagingBudget, allowSelectedTextFallback: Bool = false
    ) -> Bool {
        let proof = prepared.verification
        let expected = originalSelection ? proof.originalSelection : proof.replacementRange
        guard let actual = selectedRange(of: prepared.element, axBudget: budget),
              actual.location == expected.location, actual.length == expected.length else { return false }
        var text = stringForRange(of: prepared.element,
            range: CFRange(location: proof.replacementRange.location, length: proof.replacementRange.length),
            axBudget: budget)
        if text == nil, allowSelectedTextFallback {
            if !originalSelection {
                text = stringAttribute(of: prepared.element, attribute: kAXSelectedTextAttribute as CFString,
                                       axBudget: budget)
            }
            // Direct AX replacement already requires a whole-value snapshot. Only that
            // path may use the same capability when parameterized range reads are absent.
            if text == nil,
               let value = stringAttribute(of: prepared.element, attribute: kAXValueAttribute as CFString,
                                           axBudget: budget) {
                let source = value as NSString
                let range = proof.replacementRange
                if range.location <= source.length, range.length <= source.length - range.location {
                    text = source.substring(with: range)
                }
            }
        }
        guard let text else { return false }
        return proof.matches(range: proof.replacementRange, text: text)
    }

    private func observeTriggerSelection(_ prepared: PreparedTriggerSelection) -> TriggerSelectionObservation {
        let budget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                       perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
        let actual = selectedRange(of: prepared.element, axBudget: budget)
            .map { NSRange(location: $0.location, length: $0.length) }
        let proof = prepared.verification
        // Avoid fetching any text at a range that already proves a conflict.
        guard actual == proof.originalSelection || actual == proof.replacementRange else {
            return actual == nil ? .unavailable : .rangeChanged
        }
        let text = stringForRange(of: prepared.element,
            range: CFRange(location: proof.replacementRange.location, length: proof.replacementRange.length),
            axBudget: budget)
        return proof.observation(range: actual, text: text)
    }

    private func restorePendingTriggerSelection(
        _ prepared: PreparedTriggerSelection, generation: UInt, targetPID: pid_t?
    ) async -> DiagnosticPasteSelectionRestoration {
        await SelectionPasteTransaction.restore(
            contextIsValid: {
                let budget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                               perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
                return injectionIsAllowed(generation: generation, targetPID: targetPID,
                                          allowingTerminationDrain: true)
                    && currentFocusMatches(prepared.element, axBudget: budget)
            },
            observeSelection: { observeTriggerSelection(prepared) },
            restoreOriginal: {
                let budget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                               perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
                return setSelectedRange(prepared.verification.originalSelection,
                                        on: prepared.element, axBudget: budget)
            },
            wait: { await settle(for: $0) })
    }

    /// No Undo or text rewrite: only give back an unchanged selection we can still prove ours.
    private func restoreTriggerSelection(
        _ prepared: PreparedTriggerSelection, generation: UInt, targetPID: pid_t?,
        allowSelectedTextFallback: Bool = false
    ) -> DiagnosticPasteSelectionRestoration {
        let budget = AXMessagingBudget()
        guard injectionIsAllowed(generation: generation, targetPID: targetPID, allowingTerminationDrain: true),
              currentFocusMatches(prepared.element, axBudget: budget) else { return .skippedContextChanged }
        if triggerSelectionMatches(prepared, originalSelection: true, budget: budget,
                                   allowSelectedTextFallback: allowSelectedTextFallback) { return .notNeeded }
        guard triggerSelectionMatches(prepared, budget: budget, allowSelectedTextFallback: allowSelectedTextFallback),
              injectionIsAllowed(generation: generation, targetPID: targetPID, allowingTerminationDrain: true),
              currentFocusMatches(prepared.element, axBudget: budget) else { return .skippedContextChanged }
        guard setSelectedRange(prepared.verification.originalSelection, on: prepared.element, axBudget: budget),
              triggerSelectionMatches(prepared, originalSelection: true, budget: budget,
                                      allowSelectedTextFallback: allowSelectedTextFallback) else { return .failed }
        return .restored
    }

    /// Distinguishes insertion from clipboard handback. Only an inserted outcome may be recorded,
    /// and a pending handback remains visible while delayed recovery continues.
    private func replaceTypedText(
        characterCount: Int,
        with replacement: String,
        generation: UInt,
        targetPID: pid_t?,
        isConcealed: Bool = false,
        expectedFocusedElement: AXUIElement? = nil,
        deletion: TriggerDeletion? = nil,
        accessibilityOutcome: DiagnosticPasteAccessibilityOutcome? = nil
    ) async -> EventReplacementOutcome {
        let start = ContinuousClock.now
        let targetPID = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        var diagnosticOutcome: DiagnosticPasteOutcome = .interrupted
        var diagnosticLease: TemporaryPasteboardLease?
        var hadFingerprint = false
        var progress = DiagnosticPasteProgress(plannedDeletes: characterCount)
        progress.transport = characterCount == 0 ? .insertionOnly : .backspacePaste
        progress.accessibilityOutcome = accessibilityOutcome
        let expectedFocusedElement = expectedFocusedElement ?? captureExpansionTarget()?.element
        // Capture the reason at the guard that actually stops insertion, before cleanup.
        func insertionIsAllowed(allowingTerminationDrain: Bool = false) -> Bool {
            if let reason = injectionBlockReason(generation: generation, targetPID: targetPID,
                                                 allowingTerminationDrain: allowingTerminationDrain) {
                progress.reason = reason
                if reason == .unmarkedKeyDown { progress.interruptionOrigin = injectionInvalidationOrigin }
                return false
            }
            let focusBudget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                               perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
            if let expectedFocusedElement, !currentFocusMatches(expectedFocusedElement, axBudget: focusBudget) {
                progress.reason = .focusedElementChanged
                return false
            }
            return true
        }
        defer {
            let elapsed = start.duration(to: .now).components
            Diagnostics.record(.pasteDelivery(
                outcome: diagnosticOutcome,
                restoration: pasteboardRestoration(for: diagnosticLease),
                durationMilliseconds: elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000,
                hadFingerprint: hadFingerprint, progress: progress))
        }
        guard insertionIsAllowed() else { return .failed }
        guard let targetPID else {
            progress.reason = .targetUnavailable
            return .failed
        }
        progress.stage = .selectionPreparation
        let preparedSelection: PreparedTriggerSelection?
        switch prepareTriggerSelection(deletion: deletion, element: expectedFocusedElement) {
        case .unavailable:
            preparedSelection = nil
        case .rejected(let reason):
            progress.reason = reason
            progress.selection = .rejected
            return .failed
        case .prepared(let prepared):
            preparedSelection = prepared
            progress.transport = .selectionPaste
        }
        // Build the complete shortcut before borrowing the clipboard or deleting the trigger.
        progress.stage = .eventPreparation
        guard let pasteEvents = makePasteShortcutEvents(),
              let deleteEvents = makeDeleteEvents(count: preparedSelection == nil ? characterCount : 0) else {
            diagnosticOutcome = .eventCreationFailed
            progress.reason = .eventCreationFailed
            return .failed
        }
        // Borrowed before a single character is deleted: a pasteboard we cannot borrow safely must
        // cost the user nothing, and once the trigger is gone "nothing" is no longer on the table.
        progress.stage = .clipboardAcquisition
        guard beginPasteboardLease(placing: replacement, isConcealed: isConcealed) else {
            diagnosticOutcome = .clipboardUnavailable
            progress.reason = .clipboardUnavailable
            diagnosticLease = activePasteboardLease
            return .failed
        }
        diagnosticLease = activePasteboardLease
        guard let lease = activePasteboardLease, lease.isOwned else {
            diagnosticOutcome = .pasteboardSuperseded
            progress.reason = .pasteboardSuperseded
            finishPendingPasteboardOwnership()
            return .failed
        }
        pasteboardInjectionLease = lease
        diagnosticLease = lease
        defer {
            if !progress.pastePosted {
                finishPendingPasteboardOwnership(schedulingRetryOnFailure: true, finishingInFlightLease: lease)
            }
            if pasteboardInjectionLease === lease {
                pasteboardInjectionLease = nil
            }
            continueTerminationPreparationIfNeeded()
        }
        func clipboardIsOwned() -> Bool {
            guard activePasteboardLease === lease, lease.isOwned else {
                diagnosticOutcome = .pasteboardSuperseded
                progress.reason = .pasteboardSuperseded
                return false
            }
            return true
        }
        var confirmationElement: AXUIElement?
        var baseline: PasteCaretFingerprint?
        func captureConfirmationBaseline() {
            let budget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                           perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
            confirmationElement = expectedFocusedElement ?? frontmostFocusedElement(axBudget: budget)
            baseline = confirmationElement.flatMap { focusedCaretFingerprint(in: $0, axBudget: budget) }
            hadFingerprint = baseline != nil
        }
        func postPaste() {
            // One uninterrupted burst, with every event already allocated and tagged.
            progress.stage = .prePaste
            for event in pasteEvents { event.postToPid(targetPID) }
            progress.pastePosted = true
        }

        if let preparedSelection {
            await settle(for: pasteboardWriteSettleDelay)
            progress.stage = .selectionValidation
            let report = await SelectionPasteTransaction.run(
                contextIsValid: {
                    // No destructive edit has happened: cancellation need not finish a paste.
                    guard !Task.isCancelled else {
                        progress.reason = isPreparingForTermination ? .quitting : .contextChanged
                        return false
                    }
                    return insertionIsAllowed(allowingTerminationDrain: true) && clipboardIsOwned()
                },
                observeSelection: { observeTriggerSelection(preparedSelection) },
                selectTrigger: {
                    let budget = AXMessagingBudget(totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                                                   perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
                    return setSelectedRange(preparedSelection.verification.replacementRange,
                                            on: preparedSelection.element, axBudget: budget)
                },
                captureBaseline: captureConfirmationBaseline,
                postPaste: postPaste,
                wait: { await settle(for: $0) })
            progress.selectionConfirmation = report.progress
            if report.result != .posted {
                // Return the borrowed text before waiting on selection-only cleanup. The queue
                // and injection guard stay held until cleanup ends; no detached task can later
                // restore an obsolete range into a newer expansion.
                finishPendingPasteboardOwnership(schedulingRetryOnFailure: true, finishingInFlightLease: lease)
                if report.progress.writeAttempted {
                    progress.selectionRestoration = await restorePendingTriggerSelection(
                        preparedSelection, generation: generation, targetPID: targetPID)
                }
            }
            switch report.result {
            case .posted:
                progress.selection = .verified
                break
            case .contextChanged:
                return .failed // The failing guard already captured the precise reason.
            case .originalSelectionChanged, .selectionChanged:
                progress.reason = .selectionChanged
                progress.selection = .rejected
                return .failed
            case .selectionWriteFailed:
                progress.reason = .selectionWriteFailed
                progress.selection = .rejected
                return .failed
            case .selectionTimedOut:
                progress.reason = .selectionConfirmationTimedOut
                progress.selection = .rejected
                return .failed
            }
        } else {
            // Compatibility path for hosts without verifiable AX selection. Check the loan
            // before EVERY destructive key, not only after the trigger has disappeared.
            progress.stage = .triggerDeletion
            for index in 0..<characterCount {
                guard insertionIsAllowed(allowingTerminationDrain: true), clipboardIsOwned() else { return .failed }
                deleteEvents[index * 2].postToPid(targetPID)
                deleteEvents[index * 2 + 1].postToPid(targetPID)
                progress.deleteAttempts += 1
                if index < characterCount - 1 { await settle(for: injectedKeyDelay) }
            }
            // Keep timing non-cancellable once destructive events have been sent.
            progress.stage = .prePaste
            if characterCount > 0 {
                await settle(for: injectedKeyDelay)
                await settle(for: prePasteDelayAfterDelete)
            }
            await settle(for: pasteboardWriteSettleDelay)
            captureConfirmationBaseline()
            // Revalidate after the blocking fingerprint read, immediately before dispatch.
            guard insertionIsAllowed(allowingTerminationDrain: true), clipboardIsOwned() else { return .failed }
            postPaste()
        }
        progress.stage = .confirmation
        let verdict = await waitForPasteConfirmation(
            pastedText: replacement,
            baseline: baseline,
            lease: lease,
            targetPID: targetPID,
            expectedFocusedElement: confirmationElement,
            allowsDeletionRebaseline: preparedSelection == nil
        )
        diagnosticOutcome = verdict.diagnosticOutcome
        switch verdict {
        case .confirmed, .keepWaiting: progress.reason = .none
        case .timedOut: progress.reason = .confirmationTimedOut
        case .abandoned(.pasteboardSuperseded): progress.reason = .pasteboardSuperseded
        case .abandoned(.secureInputEnabled): progress.reason = .secureInputEnabled
        case .abandoned(.frontmostAppChanged): progress.reason = .frontmostAppChanged
        case .abandoned(.focusedElementChanged): progress.reason = .focusedElementChanged
        case .abandoned(.newExpansionStarted): progress.reason = .newExpansionStarted
        case .abandoned(.applicationTerminating): progress.reason = .quitting
        }
        let restored = finishPendingPasteboardOwnership(
            schedulingRetryOnFailure: true,
            finishingInFlightLease: lease
        )
        guard verdict == .confirmed else {
            return .unconfirmed(pasteboardRecoveryPending: !restored)
        }
        return restored ? .inserted : .insertedWithPasteboardRecoveryPending
    }

    /// Holds the borrowed pasteboard until there is evidence the host applied the paste. A fixed
    /// delay cannot be right for both: it is ten times too long for a native field and still too
    /// short for a loaded Electron host, where restoring first makes the user's own clipboard land
    /// in the document instead of the snippet.
    private func waitForPasteConfirmation(
        pastedText: String,
        baseline: PasteCaretFingerprint?,
        lease: TemporaryPasteboardLease,
        targetPID: pid_t?,
        expectedFocusedElement: AXUIElement?,
        allowsDeletionRebaseline: Bool = true
    ) async -> PasteConfirmationVerdict {
        var baseline = baseline
        var focusChanged = false
        let start = ContinuousClock.now
        var attempt = 0

        while true {
            let abort = pasteConfirmationAbort(lease: lease, targetPID: targetPID)
            let axBudget = AXMessagingBudget(
                totalTimeoutSeconds: confirmationAXMessagingTimeoutSeconds,
                perMessageTimeoutSeconds: confirmationAXMessagingTimeoutSeconds)
            let focused = abort == nil ? frontmostFocusedElement(axBudget: axBudget) : nil
            if let expectedFocusedElement, let focused,
               !CFEqual(focused, expectedFocusedElement) {
                focusChanged = true
            }
            // A different field cannot acknowledge this paste. Keep the bounded lease alive:
            // renderer node replacement or focus movement may precede consumption of Cmd+V.
            let current = abort == nil && !focusChanged && expectedFocusedElement != nil
                ? focused.flatMap { focusedCaretFingerprint(in: $0, axBudget: axBudget) } : nil

            let progress = SnippetPasteConfirmationPolicy.progress(
                before: baseline,
                after: current,
                pastedText: pastedText,
                tailLength: pasteConfirmationTuning.fingerprintTailLength
            )
            let verdict = SnippetPasteConfirmationPolicy.verdict(
                SnippetPasteConfirmationPolicy.Input(
                    attempt: attempt,
                    elapsed: start.duration(to: .now),
                    progress: progress,
                    abort: abort
                ),
                tuning: pasteConfirmationTuning
            )
            switch verdict {
            case .timedOut:
                return focusChanged ? .abandoned(.focusedElementChanged) : verdict
            case .confirmed, .abandoned:
                return verdict
            case .keepWaiting:
                break
            }

            // Our own backspaces can still be landing. Re-baseline, or the caret moving back and
            // then forward again would read as a paste that has not happened yet.
            if allowsDeletionRebaseline, progress == .pendingEditObserved, let current { baseline = current }
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
        guard !isPreparingForTermination, pasteboardInjectionLease == nil else { return false }
        // A previous lease still held would become this one's "original", losing the user's
        // clipboard for good.
        guard finishPendingPasteboardOwnership(schedulingRetryOnFailure: true) else { return false }
        beforeTemporaryPasteboardWrite?()
        let acquisition = TemporaryPasteboardLease.begin(
            text: text,
            pasteboard: NSPasteboard.general,
            isConcealed: isConcealed,
            onRestore: afterTemporaryPasteboardRestore
        )
        let lease: TemporaryPasteboardLease
        switch acquisition {
        case .acquired(let acquired):
            lease = acquired
        case .refused:
            return false
        case .recoveryPending(let pending):
            installPasteboardLease(pending)
            schedulePasteboardRestoreRetryIfNeeded()
            statusText = "Could not borrow the clipboard; restoring its previous contents is pending."
            return false
        }
        installPasteboardLease(lease)
        return true
    }

    private func installPasteboardLease(_ lease: TemporaryPasteboardLease) {
        pasteboardRestoreRetryWorkItem?.cancel()
        pasteboardRestoreRetryWorkItem = nil
        pasteboardRestoreScheduleGeneration &+= 1
        pasteboardRestoreRetryRoundsRemaining = 3
        activePasteboardLease = lease
    }

    @discardableResult
    private func finishPendingPasteboardOwnership(
        schedulingRetryOnFailure: Bool = false,
        finishingInFlightLease: TemporaryPasteboardLease? = nil
    ) -> Bool {
        guard let lease = activePasteboardLease else { return true }
        // Only the injection that owns this exact lease may hand it back before its paste
        // confirmation finishes. External cleanup must wait, or a slow host can paste the restored
        // user clipboard instead of the snippet whose Cmd+V was already posted.
        if pasteboardInjectionLease === lease, finishingInFlightLease !== lease {
            return false
        }
        let wasRecoveryPending = lease.lastRestoreResult == .failed
        let restoredOrSuperseded = lease.restoreWithRetries()
        if wasRecoveryPending {
            // One aggregate outcome for a recovery batch, never for each immediate write retry.
            Diagnostics.record(.pasteboardRecovery(outcome: pasteboardRestoration(for: lease)))
        }
        // A lease that is still owned here could not hand the clipboard back — as opposed to
        // having lost it to a newer copy, which finishes it. Reporting success would mean
        // telling `beginPasteboardLease` it may take a clipboard we are still holding, and
        // taking a second lease over our own snippet text loses the user's data for good.
        guard restoredOrSuperseded else {
            if schedulingRetryOnFailure {
                schedulePasteboardRestoreRetryIfNeeded()
            }
            return false
        }
        activePasteboardLease = nil
        pasteboardRestoreRetryWorkItem?.cancel()
        pasteboardRestoreRetryWorkItem = nil
        pasteboardRestoreScheduleGeneration &+= 1
        pasteboardRestoreRetryRoundsRemaining = 0
        if statusReportsPendingPasteboardRecovery(statusText) {
            // This covers both a successful restore and a newer copy superseding our lease.
            statusText = "Your clipboard is ready."
        }
        return true
    }

    /// A short delayed retry covers transient pasteboard-server failures without blocking the main
    /// thread or silently starting a second lease. The rounds are bounded; after they are exhausted,
    /// later user actions still retry synchronously and remain blocked until the debt is resolved or
    /// a newer user copy supersedes it.
    @discardableResult
    private func schedulePasteboardRestoreRetryIfNeeded() -> Bool {
        guard let scheduledLease = activePasteboardLease,
              scheduledLease.isOwned,
              pasteboardRestoreRetryWorkItem == nil,
              pasteboardRestoreRetryRoundsRemaining > 0
        else { return false }

        pasteboardRestoreRetryRoundsRemaining -= 1
        let scheduledGeneration = pasteboardRestoreScheduleGeneration
        let workItem = DispatchWorkItem { [weak self, weak scheduledLease] in
            MainActor.assumeIsolated {
                // `DispatchWorkItem.cancel()` is cooperative: a canceled block may still reach the
                // queue. Never let an old retry clear or restore a newer lease created meanwhile.
                guard let self, let scheduledLease,
                      self.activePasteboardLease === scheduledLease,
                      self.pasteboardRestoreScheduleGeneration == scheduledGeneration
                else { return }
                self.pasteboardRestoreRetryWorkItem = nil
                if self.finishPendingPasteboardOwnership() {
                    self.continueTerminationPreparationIfNeeded()
                    return
                }
                if self.schedulePasteboardRestoreRetryIfNeeded() { return }

                // A user copy can supersede the lease after the failed write above but before the
                // scheduling guard reads `isOwned`. Check once more before calling it failure.
                if self.finishPendingPasteboardOwnership() {
                    self.continueTerminationPreparationIfNeeded()
                    return
                }
                if self.pasteboardRecoveryCompletion != nil {
                    self.statusText = "Could not restore your previous clipboard, so Quit was canceled."
                }
                self.completePasteboardRecovery(success: false)
            }
        }
        pasteboardRestoreRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        return true
    }

    private func statusReportsPendingPasteboardRecovery(_ status: String) -> Bool {
        status.localizedCaseInsensitiveContains("restoring your previous clipboard")
            || status.localizedCaseInsensitiveContains("previous clipboard is still being restored")
            || status.localizedCaseInsensitiveContains("restoring its previous contents")
    }

    /// Called after the paste-confirmation critical section or a delayed handback finishes. A quit
    /// decision is never delivered while the lease is still consumable by an in-flight Cmd+V.
    private func continueTerminationPreparationIfNeeded() {
        guard isPreparingForTermination,
              pasteboardInjectionLease == nil,
              pasteboardRecoveryCompletion != nil
        else { return }
        // The in-flight injection may already have scheduled the first delayed handback after its
        // own bounded immediate attempts. Do not duplicate those writes synchronously here.
        if pasteboardRestoreRetryWorkItem != nil { return }

        if finishPendingPasteboardOwnership() {
            completePasteboardRecovery(success: true)
            return
        }
        if schedulePasteboardRestoreRetryIfNeeded() { return }

        // As in `prepareForTermination`, distinguish a last-moment superseding user copy from
        // actual retry exhaustion.
        if finishPendingPasteboardOwnership() {
            completePasteboardRecovery(success: true)
        } else {
            statusText = "Could not restore your previous clipboard, so Quit was canceled."
            completePasteboardRecovery(success: false)
        }
    }

    private func completePasteboardRecovery(success: Bool) {
        guard let completion = pasteboardRecoveryCompletion else { return }
        pasteboardRecoveryCompletion = nil
        // `applicationShouldTerminate` must return `.terminateLater` before AppKit receives its
        // answer. Always crossing one main-queue turn makes that ordering structural, including
        // last-moment pasteboard supersession.
        DispatchQueue.main.async {
            completion(success)
        }
    }

    private func pasteboardRestoration(for lease: TemporaryPasteboardLease?) -> DiagnosticPasteboardRestoration {
        guard let lease else { return .notBorrowed }
        switch lease.lastRestoreResult {
        case .restored: return .restored
        case .superseded: return .superseded
        case .failed, nil: return lease.isOwned ? .pending : .superseded
        }
    }

    private func focusedCaretFingerprint(
        in element: AXUIElement, axBudget: AXMessagingBudget
    ) -> PasteCaretFingerprint? {
        guard let range = selectedRange(of: element, axBudget: axBudget),
              range.location >= 0, range.length >= 0
        else { return nil }
        // Never the whole value: in a real editor that is the entire document, re-serialized over
        // Accessibility IPC on every poll.
        guard let tail = textBeforeCaret(
            in: element,
            caretLocation: range.location,
            maxCharacters: pasteConfirmationTuning.fingerprintTailLength,
            allowFullValueFallback: false,
            axBudget: axBudget
        ) else { return nil }
        return PasteCaretFingerprint(
            caretLocation: range.location,
            selectionLength: max(0, range.length),
            textBeforeCaret: tail
        )
    }

    private func makePasteShortcutEvents() -> [CGEvent]? {
        let commandKey = UInt16(kVK_Command)
        let strokes: [(UInt16, Bool, CGEventFlags)] = [
            (commandKey, true, []),
            (UInt16(kVK_ANSI_V), true, .maskCommand),
            (UInt16(kVK_ANSI_V), false, .maskCommand),
            (commandKey, false, []),
        ]
        return makeKeyEvents(strokes)
    }

    private func makeDeleteEvents(count: Int) -> [CGEvent]? {
        guard count >= 0, count <= VerifiedTriggerSelection.maximumReadUTF16Length else { return nil }
        let strokes: [(UInt16, Bool, CGEventFlags)] = (0..<count).flatMap { _ in
            [(UInt16(kVK_Delete), true, CGEventFlags()), (UInt16(kVK_Delete), false, CGEventFlags())]
        }
        return makeKeyEvents(strokes)
    }

    private func makeKeyEvents(_ strokes: [(UInt16, Bool, CGEventFlags)]) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        var events: [CGEvent] = []
        for (key, down, flags) in strokes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            else { return nil }
            event.flags = flags
            tag(event)
            events.append(event)
        }
        return events
    }

    /// Everything we post carries this marker. Any copy that reaches our session tap is ignored
    /// by origin rather than guessed from elapsed time; PID routing is not an isolation guarantee.
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

    /// Carbon also delivers Command-Backslash while one of our own editors is active.
    /// Preserve the existing refusal there: the clipboard fallback is specifically
    /// for a context with no text input, not an alternate way to handle our editor.
    private var ownApplicationHasFocusedTextInput: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func focusedTextInputElement(using axBudget: AXMessagingBudget) -> AXUIElement? {
        guard let focused = frontmostFocusedElement(axBudget: axBudget) else { return nil }

        if elementAcceptsTextInput(focused, axBudget: axBudget) {
            return focused
        }

        var current = focused
        for _ in 0..<4 {
            guard let parent = parentElement(of: current, axBudget: axBudget) else { break }
            if elementAcceptsTextInput(parent, axBudget: axBudget) {
                return focused
            }
            current = parent
        }

        return nil
    }

    /// Finds the actual writable text element while preserving the separately captured
    /// deepest focused element for identity checks. Prefer a secure ancestor over a generic
    /// editable child: web accessibility trees sometimes split those two responsibilities.
    private func securePasteTextElement(
        startingAt focused: AXUIElement,
        axBudget: AXMessagingBudget
    ) -> AXUIElement? {
        var firstTextInput: AXUIElement?
        var current = focused

        for depth in 0...4 {
            let subrole = stringAttribute(
                of: current,
                attribute: kAXSubroleAttribute as CFString,
                axBudget: axBudget
            )
            if subrole == (kAXSecureTextFieldSubrole as String) {
                return current
            }
            if firstTextInput == nil,
               elementAcceptsTextInput(current, axBudget: axBudget) {
                firstTextInput = current
            }

            guard depth < 4,
                  let parent = parentElement(of: current, axBudget: axBudget)
            else { break }
            current = parent
        }

        return firstTextInput
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

    private func focusedTriggerContext(
        axBudget: AXMessagingBudget
    ) -> FocusedTriggerContextRead {
        let focused: AXUIElement
        switch focusedElementForTriggerContext(axBudget: axBudget) {
        case .value(let element):
            focused = element
        case .unavailable(let unavailable):
            return .unavailable(unavailable)
        }

        var lastUnavailable: AXContextUnavailable?
        var element = focused
        for depth in 0...4 {
            switch detailedTextBeforeCaret(
                in: element,
                maxCharacters: maxBufferLength,
                axBudget: axBudget
            ) {
            case .value(let textBeforeCaret):
                // Even a readable value without a trigger proves this control
                // can supply insertion context. It must never fall back to blind
                // deletion later in this session, including after a transient read.
                if suggestionActive {
                    suggestionHasReadableAXContext = true
                    suggestionCaretUnavailable = false
                }
                // The first readable candidate is authoritative: injected
                // backspaces land in the actually focused field, so a trigger
                // found in an ancestor's unrelated text must never authorize a
                // deletion here. Only unreadable wrappers may lead to ancestors;
                // a text control without a caret still owns its insertion context.
                if let context = SuggestionTriggerContext.context(
                    inTextBeforeCaret: textBeforeCaret
                ) {
                    return .found(context)
                }
                return .missingTrigger
            case .unavailable(let unavailable, let mayReadAncestor):
                if suggestionActive {
                    suggestionCaretUnavailable = unavailable.allowsLocalTracking
                    if unavailable.failure == .invalidRange {
                        suggestionContextState = .uncertainAfterHostEdit
                    }
                }
                guard mayReadAncestor else { return .unavailable(unavailable) }
                lastUnavailable = unavailable
            }

            guard depth < 4,
                  let parent = parentElement(of: element, axBudget: axBudget) else { break }
            element = parent
        }

        return .unavailable(lastUnavailable ?? AXContextUnavailable(
            stage: .value,
            failure: .noValue,
            errorCode: nil))
    }

    private func focusedElementForTriggerContext(
        axBudget: AXMessagingBudget
    ) -> AXElementRead {
        guard accessibilityGranted else {
            return .unavailable(AXContextUnavailable(
                stage: .application,
                failure: .notTrusted,
                errorCode: nil))
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .unavailable(AXContextUnavailable(
                stage: .application,
                failure: .noApplication,
                errorCode: nil))
        }

        primeAccessibilityIfNeeded(for: app, axBudget: axBudget)
        guard let appElement = withBoundedMessagingTimeout(
            AXUIElementCreateApplication(app.processIdentifier),
            axBudget: axBudget
        ) else {
            return .unavailable(axUnavailable(
                stage: .application,
                error: .cannotComplete))
        }
        var focusedValue: CFTypeRef?
        var result = copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedUIElementAttribute as CFString,
            into: &focusedValue,
            axBudget: axBudget)

        if result != .success {
            // Preserve the existing Chromium/Electron priming retry, but keep
            // the final AXError instead of flattening it to nil.
            primeAccessibilityIfNeeded(for: app, force: true, axBudget: axBudget)
            focusedValue = nil
            result = copyAttributeValue(
                of: appElement,
                attribute: kAXFocusedUIElementAttribute as CFString,
                into: &focusedValue,
                axBudget: axBudget)
        }

        guard result == .success else {
            return .unavailable(axUnavailable(stage: .focusedElement, error: result))
        }
        guard let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unavailable(AXContextUnavailable(
                stage: .focusedElement,
                failure: .invalidType,
                errorCode: nil))
        }

        guard let focused = withBoundedMessagingTimeout(
            focusedValue as! AXUIElement,
            axBudget: axBudget
        ) else {
            return .unavailable(axUnavailable(
                stage: .focusedElement,
                error: .cannotComplete))
        }
        return .value(deepestFocusedElement(
            startingAt: focused,
            maxDepth: 4,
            axBudget: axBudget) ?? focused)
    }

    private func focusedTextContextCandidates(
        startingAt element: AXUIElement,
        axBudget: AXMessagingBudget? = nil
    ) -> [AXUIElement] {
        var elements: [AXUIElement] = [element]
        var current = element

        for _ in 0..<4 {
            guard let parent = parentElement(of: current, axBudget: axBudget) else { break }
            elements.append(parent)
            current = parent
        }

        return elements
    }

    private func detailedTextBeforeCaret(
        in element: AXUIElement,
        maxCharacters: Int,
        axBudget: AXMessagingBudget
    ) -> AXTextRead {
        switch SuggestionAXTextReader(element: element, budget: axBudget).read(
            maxCharacters: maxCharacters
        ) {
        case .text(let text):
            return .value(text)
        case .unavailable(let failure):
            let stage: DiagnosticExpansionAXStage
            switch failure.stage {
            case .selectedRange: stage = .selectedRange
            case .rangeText: stage = .rangeText
            case .value: stage = .value
            }
            var unavailable = axUnavailable(stage: stage, error: failure.error)
            unavailable.allowsLocalTracking = failure.allowsLocalTracking
            return .unavailable(unavailable, mayReadAncestor: failure.mayReadAncestor)
        }
    }

    private func axUnavailable(
        stage: DiagnosticExpansionAXStage,
        error: AXError
    ) -> AXContextUnavailable {
        AXContextUnavailable(
            stage: stage,
            failure: diagnosticFailure(for: error),
            errorCode: Int(error.rawValue))
    }

    private func diagnosticFailure(for error: AXError) -> DiagnosticExpansionAXFailure {
        switch error {
        case .attributeUnsupported, .parameterizedAttributeUnsupported:
            .attributeUnsupported
        case .noValue:
            .noValue
        case .cannotComplete:
            .cannotComplete
        case .notImplemented:
            .notImplemented
        case .invalidUIElement, .invalidUIElementObserver:
            .invalidElement
        case .illegalArgument:
            .invalidRange
        case .notificationUnsupported:
            .notificationUnsupported
        case .notificationAlreadyRegistered:
            .alreadyRegistered
        case .apiDisabled:
            .apiDisabled
        default:
            .other
        }
    }

    private func recordExpansionAccessibility(
        operation: DiagnosticExpansionAXOperation,
        outcome: DiagnosticExpansionAXOutcome,
        stateBefore: SuggestionContextState,
        stateAfter: SuggestionContextState,
        unavailable: AXContextUnavailable? = nil,
        stage: DiagnosticExpansionAXStage? = nil
    ) {
        guard expansionVerboseDiagnosticsEnabled() else { return }
        Diagnostics.record(.expansionAccessibility(
            operation: operation,
            outcome: outcome,
            stateBefore: diagnosticState(stateBefore),
            stateAfter: diagnosticState(stateAfter),
            stage: unavailable?.stage ?? stage,
            failure: unavailable?.failure,
            axErrorCode: unavailable?.errorCode,
            queryLength: suggestionQuery.count))
    }

    private func diagnosticState(
        _ state: SuggestionContextState
    ) -> DiagnosticExpansionContextState {
        switch state {
        case .axConfirmed: .axConfirmed
        case .localDisplayOnly: .localDisplayOnly
        case .uncertainAfterHostEdit: .uncertainAfterHostEdit
        }
    }

    /// Split out so a caller can pin the text and the caret offset to one observation, and so the
    /// confirmation poll can opt out of the whole-value fallback.
    private func textBeforeCaret(
        in element: AXUIElement,
        caretLocation: Int,
        maxCharacters: Int,
        allowFullValueFallback: Bool,
        axBudget: AXMessagingBudget? = nil
    ) -> String? {
        guard caretLocation >= 0 else { return nil }
        let start = max(0, caretLocation - maxCharacters)
        let length = caretLocation - start
        let rangeBeforeCaret = CFRange(location: start, length: length)

        if let text = stringForRange(of: element, range: rangeBeforeCaret, axBudget: axBudget) {
            return text
        }
        guard allowFullValueFallback else { return nil }
        return stringValueBeforeCaret(of: element, caretLocation: caretLocation, maxCharacters: maxCharacters)
    }

    private func stringForRange(
        of element: AXUIElement,
        range: CFRange,
        axBudget: AXMessagingBudget? = nil
    ) -> String? {
        guard range.length > 0 else { return "" }

        var requestedRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &requestedRange) else {
            return nil
        }

        var value: CFTypeRef?
        let result: AXError
        if let axBudget {
            result = axBudget.copyParameterizedAttributeValue(
                of: element,
                attribute: kAXStringForRangeParameterizedAttribute as CFString,
                parameter: rangeValue,
                into: &value
            )
        } else {
            result = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &value
            )
        }
        guard result == .success else {
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

    private func frontmostFocusedElement(axBudget: AXMessagingBudget? = nil) -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        primeAccessibilityIfNeeded(for: app, axBudget: axBudget)
        if let axBudget, !axBudget.canContinue { return nil }

        if let focused = copyFocusedElement(from: app, axBudget: axBudget) {
            return deepestFocusedElement(startingAt: focused, maxDepth: 4, axBudget: axBudget)
        }
        if let axBudget, !axBudget.canContinue { return nil }

        // Retry once after forcing manual accessibility attributes for Chromium/Electron.
        primeAccessibilityIfNeeded(for: app, force: true, axBudget: axBudget)
        if let axBudget, !axBudget.canContinue { return nil }
        guard let focused = copyFocusedElement(from: app, axBudget: axBudget) else {
            return nil
        }
        return deepestFocusedElement(startingAt: focused, maxDepth: 4, axBudget: axBudget)
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
              !secureEventInputEnabled
        else { return false }

        return reassertKeyboardFocus(
            element: focusTarget.element,
            window: focusTarget.window,
            targetPID: targetPID
        )
    }

    /// Secure Paste may restore a password field while Secure Event Input is enabled.
    /// Other fields wait for authentication's temporary secure-input ownership to clear
    /// before delivery, while preserving destinations that already had secure
    /// input enabled when they were captured.
    private func restoreSecurePasteTarget(
        _ focusTarget: SecurePasteTarget,
        mode: SecurePasteFocusHandoff.Mode,
        source: DiagnosticPasteHandoffSource = .snippetPicker,
        logsHandoff: Bool = true,
        contextIsValid: (() -> Bool)? = nil
    ) async -> Bool {
        let startedAt = ContinuousClock.now
        var succeeded = false
        var reason: DiagnosticSecurePasteReason = .applicationUnavailable
        var attempts = 0
        var confirmations = 0
        var firstWaitReason = DiagnosticSecurePasteReason.none
        defer {
            if logsHandoff {
                recordSecurePaste(stage: .handoff,
                    outcome: Task.isCancelled || reason == .cancelled ? .cancelled : (succeeded ? .succeeded : .failed),
                    target: focusTarget, reason: Task.isCancelled ? .cancelled : reason,
                    startedAt: startedAt, attempts: attempts,
                    handoff: .init(source: source, afterAuthentication: mode == .afterAuthentication,
                        confirmations: confirmations,
                        requiredConfirmations: mode == .afterAuthentication
                            ? SecurePasteAuthenticationHandoffPolicy.requiredConsecutiveFocusConfirmations : 1,
                        firstWaitReason: firstWaitReason))
            }
        }
        guard !Task.isCancelled, contextIsValid?() != false else { reason = .cancelled; return false }
        guard let target = NSRunningApplication(processIdentifier: focusTarget.targetPID),
              !target.isTerminated
        else { return false }

        let waitForAuthenticationSecureInputToClear = mode == .afterAuthentication
            && SecurePasteAuthenticationHandoffPolicy.shouldWaitForSecureInputToClear(
                targetIsSecureTextField: focusTarget.isSecureTextField,
                secureInputWasEnabledAtCapture: focusTarget.secureInputWasEnabledAtCapture)
        if mode == .afterAuthentication
            || NSWorkspace.shared.frontmostApplication?.processIdentifier != focusTarget.targetPID {
            _ = target.activate()
        }
        if focusTarget.containerBinding != nil {
            let report = await SecurePasteFocusHandoff.runForContainer(
                mode: mode,
                sleep: { delay in try? await Task.sleep(for: delay) },
                observe: { [self] in
                    guard contextIsValid?() != false else { return .cancelled }
                    guard !target.isTerminated else { return .fieldUnavailable }
                    let budget = AXMessagingBudget()
                    let validation = securePasteTargetValidation(focusTarget, budget: budget)
                    if validation == .applicationNotFrontmost { _ = target.activate() }
                    guard validation == .valid || validation == .fieldFocusPending else { return validation }
                    if SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
                        waitForAuthenticationSecureInputToClear: waitForAuthenticationSecureInputToClear,
                        secureEventInputEnabled: secureEventInputEnabled) { return .secureInputPending }
                    return validation
                }, restoreFocus: {
                    guard contextIsValid?() != false else { return }
                    let budget = AXMessagingBudget()
                    _ = budget.setAttributeValue(of: focusTarget.textElement,
                        attribute: kAXFocusedAttribute as CFString, value: kCFBooleanTrue)
                })
            attempts = report.attempts
            confirmations = report.consecutiveConfirmations
            firstWaitReason = diagnosticReason(report.firstTransient ?? .valid)
            succeeded = report.validation == .valid
            reason = diagnosticReason(succeeded ? (report.firstTransient ?? .valid) : report.validation)
            return succeeded
        }
        reason = .focusUnavailable
        let report = await SecurePasteFocusHandoff.run(
            mode: mode,
            sleep: { delay in try? await Task.sleep(for: delay) }
        ) { [self] in
            guard !target.isTerminated else { return .fieldUnavailable }
            guard contextIsValid?() != false else { return .cancelled }
            if SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
                waitForAuthenticationSecureInputToClear:
                    waitForAuthenticationSecureInputToClear,
                secureEventInputEnabled: secureEventInputEnabled
            ) {
                return .secureInputPending
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focusTarget.targetPID else {
                _ = target.activate()
                return .applicationNotFrontmost
            }
            if mode == .withoutAuthentication,
               currentFocusMatches(focusTarget.focusedElement, axBudget: AXMessagingBudget()) {
                return .valid
            }

            // LocalAuthentication or a Keychain unlock dialog can disappear from
            // NSWorkspace before keyboard ownership has fully returned. Reassert the
            // captured control and require consecutive observations after authentication.
            _ = target.activate()
            return reassertKeyboardFocus(
                element: focusTarget.focusedElement,
                window: focusTarget.window,
                targetPID: focusTarget.targetPID
            ) ? .valid : .focusUnavailable
        }
        attempts = report.attempts
        confirmations = report.consecutiveConfirmations
        firstWaitReason = diagnosticReason(report.firstTransient ?? .valid)
        succeeded = report.validation == .valid
        reason = diagnosticReason(succeeded ? (report.firstTransient ?? .valid) : report.validation)
        return succeeded
    }

    private func reassertKeyboardFocus(
        element: AXUIElement,
        window: AXUIElement?,
        targetPID: pid_t
    ) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            return false
        }

        let appElement = withBoundedMessagingTimeout(AXUIElementCreateApplication(targetPID))
        if let window {
            _ = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                window
            )
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return currentFocusMatches(element)
    }

    /// Chooses one transport while the original field is freshly focused. No secure
    /// snippet body has been materialized as a `String` when the secure call site enters
    /// this method, password values are never read, and the selected transport is final:
    /// delivery never falls through to a second plaintext-bearing strategy.
    private func prepareSecurePasteDeliveryTarget(
        _ target: SecurePasteTarget
    ) -> SecurePasteDeliveryPreparation? {
        let startedAt = ContinuousClock.now
        var reason = DiagnosticSecurePasteReason.unsupportedTarget
        let preparation = prepareSecurePasteDeliveryTargetImpl(target, reason: &reason)
        recordSecurePaste(stage: .preparation, outcome: preparation == nil ? .failed : .succeeded,
            target: target, transport: diagnosticTransport(preparation),
            reason: preparation == nil ? reason : .none, startedAt: startedAt)
        return preparation
    }

    private func diagnosticTransport(_ preparation: SecurePasteDeliveryPreparation?) -> DiagnosticSecurePasteTransport {
        switch preparation {
        case .replaceSecureValue: .secureValue
        case .replaceWebRange: .webRange
        case .typeUnicode: .unicode
        case .typeSecureUnicode: .secureUnicode
        case nil: .none
        }
    }

    private func prepareSecurePasteDeliveryTargetImpl(
        _ target: SecurePasteTarget, reason: inout DiagnosticSecurePasteReason
    ) -> SecurePasteDeliveryPreparation? {
        guard accessibilityGranted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.targetPID,
              processIdentifier(of: target.textElement) == target.targetPID,
              let targetApplication = NSRunningApplication(processIdentifier: target.targetPID),
              !targetApplication.isTerminated
        else { reason = .applicationUnavailable; return nil }

        let budget = AXMessagingBudget()
        let validation = securePasteTargetValidation(target, budget: budget)
        guard validation == .valid else {
            reason = diagnosticReason(validation)
            return nil
        }

        let targetIsSecureTextField = stringAttribute(
            of: target.textElement,
            attribute: kAXSubroleAttribute as CFString,
            axBudget: budget
        ) == (kAXSecureTextFieldSubrole as String)
        guard targetIsSecureTextField == target.isSecureTextField else {
            reason = .fieldTypeChanged
            return nil
        }
        let role = stringAttribute(
            of: target.textElement,
            attribute: kAXRoleAttribute as CFString,
            axBudget: budget
        )
        let ancestry = securePasteWebAncestry(target.textElement, axBudget: budget)
        if targetIsSecureTextField && ancestry == nil {
            reason = budget.canContinue ? .unsupportedTarget : .budgetExhausted
            return nil
        }
        let targetIsInsideWebArea = ancestry == true
        let valueIsSettable = targetIsSecureTextField && !targetIsInsideWebArea && attributeIsSettable(
            kAXValueAttribute as CFString, on: target.textElement, axBudget: budget)
        let targetHasEligibleWebTextRole = targetIsInsideWebArea
            && SecurePasteDeliveryPolicy.isEligibleWebTextRole(role)
        let advertisedParameterizedAttributes = targetHasEligibleWebTextRole && !targetIsSecureTextField
            ? parameterizedAttributes(on: target.textElement, axBudget: budget)
            : nil
        let webRangeReplacementIsAvailable = advertisedParameterizedAttributes.map {
            SecurePasteDeliveryPolicy.supportsWebRangeReplacement(
                advertisedParameterizedAttributes: $0
            )
        } ?? false
        guard budget.canContinue else { reason = .budgetExhausted; return nil }
        switch SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: targetIsSecureTextField,
            valueIsSettable: valueIsSettable,
            targetIsInsideWebArea: targetIsInsideWebArea,
            targetHasEligibleWebTextRole: targetHasEligibleWebTextRole,
            webRangeReplacementIsAvailable: webRangeReplacementIsAvailable
        ) {
        case .replaceSecureValue:
            return .replaceSecureValue
        case .typeSecureUnicode:
            guard CGPreflightPostEventAccess() else { reason = .permissionRequired; return nil }
            guard SecurePasteDeliveryPolicy.permitsDirectInput(
                isSecureWebField: true, hasContainerBinding: target.containerBinding != nil,
                exactFieldHasKeyboardFocus: currentFocusMatches(target.textElement, axBudget: budget)
            ) else { reason = .fieldFocusPending; return nil }
            return .typeSecureUnicode
        case .replaceWebRange:
            guard let fieldUTF16Count = integerAttribute(
                of: target.textElement,
                attribute: kAXNumberOfCharactersAttribute as CFString,
                axBudget: budget
            ),
                  let selection = selectedRange(
                    of: target.textElement,
                    axBudget: budget
                  ),
                  fieldUTF16Count >= 0,
                  fieldUTF16Count <= SecurePasteWebReplacementPolicy.maximumFieldUTF16Count,
                  selection.location >= 0,
                  selection.length >= 0,
                  selection.location <= fieldUTF16Count,
                  selection.length <= fieldUTF16Count - selection.location,
                  selection.length <= SecurePasteWebReplacementPolicy.maximumReplacementUTF16Count
            else { return nil }

            return .replaceWebRange(SecurePasteWebPreparation(
                fieldUTF16Count: fieldUTF16Count,
                selection: selection,
                lineEndings: SecurePasteWebReplacementPolicy.lineEndings(
                    bundleIdentifier: targetApplication.bundleIdentifier, role: role)
            ))
        case .typeUnicode:
            guard target.containerBinding == nil else { return nil }
            return .typeUnicode
        case .unavailable:
            return nil
        }
    }

    /// Sends exactly the transport selected before plaintext materialization. An ordinary
    /// browser request is confirmed only after bounded range/count readback. Password
    /// setters remain unconfirmed even when AX accepts them. Direct input is one
    /// PID-bound Unicode key event; normal dispatch remains unverified without presenting
    /// the lack of host acknowledgement as a user-facing failure. No outcome falls through
    /// to another AX operation, key event, or the pasteboard.
    private func deliverSecurePasteText(
        _ text: String,
        to target: SecurePasteTarget,
        using preparation: SecurePasteDeliveryPreparation
    ) -> SecurePasteResult {
        let startedAt = ContinuousClock.now
        var outcome = DiagnosticSecurePasteOutcome.failed
        var reason = DiagnosticSecurePasteReason.applicationUnavailable
        var axErrorCode: Int?
        defer {
            recordSecurePaste(stage: .delivery, outcome: outcome, target: target,
                transport: diagnosticTransport(preparation), reason: reason, startedAt: startedAt,
                axErrorCode: axErrorCode)
        }
        guard accessibilityGranted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.targetPID,
              processIdentifier(of: target.textElement) == target.targetPID
        else { return .failedBeforeAttempt }

        let budget = AXMessagingBudget()
        let validation = securePasteTargetValidation(target, budget: budget)
        guard validation == .valid else {
            reason = diagnosticReason(validation)
            return .failedBeforeAttempt
        }

        switch preparation {
        case .replaceSecureValue:
            if target.containerBinding != nil,
               !attributeIsSettable(kAXValueAttribute as CFString,
                                     on: target.textElement, axBudget: budget) {
                reason = budget.canContinue ? .unsupportedTarget : .budgetExhausted
                return .failedBeforeAttempt
            }
            let result = budget.setAttributeValue(
                of: target.textElement,
                attribute: kAXValueAttribute as CFString,
                value: text as CFString
            )
            axErrorCode = Int(result.rawValue)
            outcome = .ambiguous
            reason = result == .success ? .axWriteUnconfirmed : .axWriteRejected
            return SecurePasteDeliveryPolicy.secureValueWriteResult(result)

        case .typeUnicode, .typeSecureUnicode:
            let isSecureWebField: Bool
            if case .typeSecureUnicode = preparation { isSecureWebField = true }
            else { isSecureWebField = false }
            let result = deliverDirectUnicodePasteText(text, to: target,
                isSecureWebField: isSecureWebField, reason: &reason)
            outcome = diagnosticOutcome(result)
            return result

        case .replaceWebRange(let preparation):
            let result = deliverWebSecurePasteText(
                text,
                to: target,
                preparation: preparation,
                axBudget: budget,
                axErrorCode: &axErrorCode,
                reason: &reason
            )
            outcome = diagnosticOutcome(result)
            return result
        }
    }

    /// Direct input serves web passwords and selected text on native/custom surfaces
    /// whose AX write cannot prove that the host's actual input model changed. Both
    /// events are created before the final focus check and then posted as one uninterrupted
    /// PID-bound burst. `postToPid` has no delivery acknowledgement, so success here means
    /// only that the one allowed attempt was posted.
    private func deliverDirectUnicodePasteText(
        _ text: String,
        to target: SecurePasteTarget,
        isSecureWebField: Bool,
        reason: inout DiagnosticSecurePasteReason
    ) -> SecurePasteResult {
        reason = .permissionRequired
        guard CGPreflightPostEventAccess() else { return .failedBeforeAttempt }
        reason = .applicationUnavailable
        guard let targetApplication = NSRunningApplication(
                processIdentifier: target.targetPID
              ),
              !targetApplication.isTerminated else { return .failedBeforeAttempt }
        reason = .invalidContent
        guard let events = SecurePasteDirectInputPolicy.makeEvents(
                text: text,
                eventTag: SnippetSyntheticEvent.tag
              )
        else { return .failedBeforeAttempt }

        let budget = AXMessagingBudget()
        reason = .focusChanged
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.targetPID,
              processIdentifier(of: target.focusedElement) == target.targetPID,
              processIdentifier(of: target.textElement) == target.targetPID,
              currentFocusMatches(target.focusedElement, axBudget: budget)
        else { return .failedBeforeAttempt }

        let exactFieldHasKeyboardFocus = isSecureWebField
            && currentFocusMatches(target.textElement, axBudget: budget)
        guard SecurePasteDeliveryPolicy.permitsDirectInput(
            isSecureWebField: isSecureWebField, hasContainerBinding: target.containerBinding != nil,
            exactFieldHasKeyboardFocus: exactFieldHasKeyboardFocus
        ) else { return .failedBeforeAttempt }
        if isSecureWebField {
            // Do not type a password into a field whose kind changed while resolving
            // the body. This reads metadata only, never password text or its length.
            reason = .fieldTypeChanged
            guard stringAttribute(of: target.textElement, attribute: kAXSubroleAttribute as CFString,
                                  axBudget: budget) == (kAXSecureTextFieldSubrole as String),
                  boolAttribute(of: target.textElement, attribute: kAXEnabledAttribute as CFString,
                                axBudget: budget) == true else { return .failedBeforeAttempt }
            reason = .focusChanged
            guard currentFocusMatches(target.textElement, axBudget: budget) else { return .failedBeforeAttempt }
        }

        events.keyDown.postToPid(target.targetPID)
        events.keyUp.postToPid(target.targetPID)
        reason = .directInputUnconfirmed
        return .dispatchedUnconfirmed
    }

    private func directInputValidationFailure(
        for text: String,
        displayName: String
    ) -> (message: String, result: SecurePasteResult)? {
        switch SecurePasteDirectInputPolicy.validation(of: text) {
        case .allowed:
            return nil
        case .empty:
            return (
                "\(displayName) is empty — nothing to paste.",
                .failedBeforeAttempt
            )
        case .tooLong:
            return (
                "Secure Paste direct input is limited to \(SecurePasteDirectInputPolicy.maximumUTF16Count) UTF-16 units.",
                .failedBeforeAttempt
            )
        case .containsControlCharacter:
            return (
                "Secure Paste direct input refused control characters, including Return, newline, and Tab.",
                .blockedUnsafeControlCharacters
            )
        }
    }

    private func deliverWebSecurePasteText(
        _ text: String,
        to target: SecurePasteTarget,
        preparation: SecurePasteWebPreparation,
        axBudget: AXMessagingBudget,
        axErrorCode: inout Int?,
        reason: inout DiagnosticSecurePasteReason
    ) -> SecurePasteResult {
        reason = .unsupportedTarget
        // Re-read all mutable, non-secret state after body materialization and immediately
        // before the request. This closes the authentication/picker focus race without
        // ever reading the field's whole value.
        guard integerAttribute(
            of: target.textElement,
            attribute: kAXNumberOfCharactersAttribute as CFString,
            axBudget: axBudget
        ) == preparation.fieldUTF16Count,
              let currentSelection = selectedRange(
                of: target.textElement,
                axBudget: axBudget
              ),
              currentSelection.location == preparation.selection.location,
              currentSelection.length == preparation.selection.length,
              let selectedText = stringForRange(
                of: target.textElement,
                range: currentSelection,
                axBudget: axBudget
              ),
              let snapshot = SecurePasteWebReplacementPolicy.snapshot(
                fieldUTF16Count: preparation.fieldUTF16Count,
                selectionLocation: currentSelection.location,
                selectionLength: currentSelection.length,
                selectedText: selectedText
              ),
              let plan = SecurePasteWebReplacementPolicy.plan(
                replacing: snapshot,
                with: text,
                lineEndings: preparation.lineEndings
              )
        else { return .failedBeforeAttempt }

        var replacementRange = CFRange(
            location: plan.replacementLocation,
            length: plan.replacementLength
        )
        guard let replacementRangeValue = AXValueCreate(.cfRange, &replacementRange) else {
            return .failedBeforeAttempt
        }
        let parameters: NSDictionary = [
            "AXReplacementRange": replacementRangeValue,
            "AXReplacementText": text,
        ]

        let validation = securePasteTargetValidation(target, budget: axBudget)
        guard validation == .valid else {
            reason = diagnosticReason(validation)
            return .failedBeforeAttempt
        }

        var operationResult: CFTypeRef?
        let result = axBudget.copyParameterizedAttributeValue(
            of: target.textElement,
            attribute: "AXReplaceRangeWithText" as CFString,
            parameter: parameters,
            into: &operationResult
        )
        axErrorCode = Int(result.rawValue)
        guard result == .success else { reason = .axWriteRejected; return .attemptedAmbiguous }

        let insertedRange = CFRange(
            location: plan.replacementLocation,
            length: plan.replacementUTF16Count
        )
        guard let confirmedFieldCount = integerAttribute(
            of: target.textElement,
            attribute: kAXNumberOfCharactersAttribute as CFString,
            axBudget: axBudget
        ), confirmedFieldCount == plan.expectedFieldUTF16Count,
              let insertedText = stringForRange(
                of: target.textElement,
                range: insertedRange,
                axBudget: axBudget
              ),
              SecurePasteWebReplacementPolicy.confirms(plan,
                fieldUTF16Count: confirmedFieldCount, insertedText: insertedText)
        else { reason = .readbackUnconfirmed; return .attemptedAmbiguous }

        // Chromium currently leaves the replacement selected. This non-plaintext write
        // happens only after delivery is proven; failure cannot authorize a retry.
        var caretRange = CFRange(location: plan.caretLocation, length: 0)
        if let caretRangeValue = AXValueCreate(.cfRange, &caretRange) {
            _ = axBudget.setAttributeValue(
                of: target.textElement,
                attribute: kAXSelectedTextRangeAttribute as CFString,
                value: caretRangeValue
            )
        }
        reason = .none
        return .inserted
    }

    private func attributeIsSettable(
        _ attribute: CFString,
        on element: AXUIElement,
        axBudget: AXMessagingBudget
    ) -> Bool {
        guard axBudget.bind(element) else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private func currentFocusMatches(
        _ expected: AXUIElement,
        axBudget: AXMessagingBudget? = nil
    ) -> Bool {
        guard let expectedPID = processIdentifier(of: expected),
              systemWideFocusedApplicationPID(axBudget: axBudget) == expectedPID
        else { return false }
        guard let current = frontmostFocusedElement(axBudget: axBudget) else { return false }
        return CFEqual(current, expected)
    }

    /// NSWorkspace's frontmost process can remain the host throughout a system
    /// authentication sheet. This attribute follows the application that actually
    /// owns keyboard focus, which is the distinction secure insertion needs.
    private func systemWideFocusedApplicationPID(
        axBudget: AXMessagingBudget? = nil
    ) -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard copyAttributeValue(
            of: systemWide,
            attribute: kAXFocusedApplicationAttribute as CFString,
            into: &value,
            axBudget: axBudget
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return processIdentifier(of: value as! AXUIElement)
    }

    private func currentKeyboardInputSourceIdentifier() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let identifierPointer = TISGetInputSourceProperty(
                  inputSource,
                  kTISPropertyInputSourceID
              )
        else { return nil }
        return Unmanaged<CFString>
            .fromOpaque(identifierPointer)
            .takeUnretainedValue() as String
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

    private func elementAttribute(
        of element: AXUIElement,
        attribute: CFString,
        axBudget: AXMessagingBudget? = nil
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard copyAttributeValue(
            of: element,
            attribute: attribute,
            into: &value,
            axBudget: axBudget
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return withBoundedMessagingTimeout(value as! AXUIElement, axBudget: axBudget)
    }

    /// Applies the engine's bounded messaging timeout to an element we are
    /// about to query, so a stalled host process cannot hang the tap thread.
    private func withBoundedMessagingTimeout(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeoutSeconds)
        return element
    }

    private func withBoundedMessagingTimeout(
        _ element: AXUIElement,
        axBudget: AXMessagingBudget?
    ) -> AXUIElement? {
        guard let axBudget else { return withBoundedMessagingTimeout(element) }
        return axBudget.bind(element) ? element : nil
    }

    private func copyAttributeValue(
        of element: AXUIElement,
        attribute: CFString,
        into value: inout CFTypeRef?,
        axBudget: AXMessagingBudget?
    ) -> AXError {
        if let axBudget {
            return axBudget.copyAttributeValue(of: element, attribute: attribute, into: &value)
        }
        return AXUIElementCopyAttributeValue(element, attribute, &value)
    }

    private func copyFocusedElement(
        from app: NSRunningApplication,
        axBudget: AXMessagingBudget? = nil
    ) -> AXUIElement? {
        guard let appElement = withBoundedMessagingTimeout(
            AXUIElementCreateApplication(app.processIdentifier),
            axBudget: axBudget
        ) else { return nil }
        var focusedValue: CFTypeRef?
        guard copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedUIElementAttribute as CFString,
            into: &focusedValue,
            axBudget: axBudget
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return withBoundedMessagingTimeout(focusedValue as! AXUIElement, axBudget: axBudget)
    }

    private func deepestFocusedElement(
        startingAt root: AXUIElement,
        maxDepth: Int,
        axBudget: AXMessagingBudget? = nil
    ) -> AXUIElement? {
        var current = root

        for _ in 0..<maxDepth {
            var nestedValue: CFTypeRef?
            guard copyAttributeValue(
                of: current,
                attribute: kAXFocusedUIElementAttribute as CFString,
                into: &nestedValue,
                axBudget: axBudget
            ) == .success,
                  let nestedValue,
                  CFGetTypeID(nestedValue) == AXUIElementGetTypeID() else {
                break
            }

            guard let nested = withBoundedMessagingTimeout(
                nestedValue as! AXUIElement,
                axBudget: axBudget
            ) else { return nil }
            if CFEqual(current, nested) {
                break
            }

            current = nested
        }

        if let axBudget, !axBudget.canContinue { return nil }
        return current
    }

    private func elementAcceptsTextInput(
        _ element: AXUIElement,
        axBudget: AXMessagingBudget? = nil
    ) -> Bool {
        let role = stringAttribute(
            of: element,
            attribute: kAXRoleAttribute as CFString,
            axBudget: axBudget
        ) ?? ""
        let subrole = stringAttribute(
            of: element,
            attribute: kAXSubroleAttribute as CFString,
            axBudget: axBudget
        ) ?? ""

        if role == (kAXTextFieldRole as String) ||
            role == (kAXTextAreaRole as String) ||
            role == (kAXComboBoxRole as String) ||
            subrole == (kAXSearchFieldSubrole as String) {
            return true
        }

        if boolAttribute(
            of: element,
            attribute: "AXEditable" as CFString,
            axBudget: axBudget
        ) == true {
            return true
        }

        // Chromium/Electron text controls often expose text-range attributes
        // even when the role isn't one of the standard text roles.
        if hasAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            on: element,
            axBudget: axBudget
        ) {
            return true
        }

        return false
    }

    private func stringAttribute(
        of element: AXUIElement,
        attribute: CFString,
        axBudget: AXMessagingBudget? = nil
    ) -> String? {
        var value: CFTypeRef?
        guard copyAttributeValue(
            of: element,
            attribute: attribute,
            into: &value,
            axBudget: axBudget
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(
        of element: AXUIElement,
        attribute: CFString,
        axBudget: AXMessagingBudget? = nil
    ) -> Bool? {
        var value: CFTypeRef?
        guard copyAttributeValue(
            of: element,
            attribute: attribute,
            into: &value,
            axBudget: axBudget
        ) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func integerAttribute(
        of element: AXUIElement,
        attribute: CFString,
        axBudget: AXMessagingBudget? = nil
    ) -> Int? {
        var value: CFTypeRef?
        guard copyAttributeValue(
            of: element,
            attribute: attribute,
            into: &value,
            axBudget: axBudget
        ) == .success,
              let number = value as? NSNumber
        else { return nil }

        let integer = number.int64Value
        guard integer >= 0,
              number.doubleValue == Double(integer),
              integer <= Int64(Int.max)
        else { return nil }
        return Int(integer)
    }

    private func selectedRange(
        of element: AXUIElement,
        axBudget: AXMessagingBudget? = nil
    ) -> CFRange? {
        var value: CFTypeRef?
        guard copyAttributeValue(
            of: element,
            attribute: kAXSelectedTextRangeAttribute as CFString,
            into: &value,
            axBudget: axBudget
        ) == .success,
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

    private func hasAttribute(
        _ attribute: CFString,
        on element: AXUIElement,
        axBudget: AXMessagingBudget? = nil
    ) -> Bool {
        var attributesValue: CFArray?
        let result: AXError
        if let axBudget {
            result = axBudget.copyAttributeNames(of: element, into: &attributesValue)
        } else {
            result = AXUIElementCopyAttributeNames(element, &attributesValue)
        }
        guard result == .success,
              let attributesValue,
              let attributes = attributesValue as? [String] else {
            return false
        }

        return attributes.contains(attribute as String)
    }

    private func parameterizedAttributes(
        on element: AXUIElement,
        axBudget: AXMessagingBudget
    ) -> Set<String>? {
        var attributesValue: CFArray?
        guard axBudget.copyParameterizedAttributeNames(
            of: element,
            into: &attributesValue
        ) == .success,
              let attributes = attributesValue as? [String]
        else { return nil }

        return Set(attributes)
    }

    /// Positive browser evidence only. A missing role, failed parent read, cycle, or
    /// excessive depth is not treated as web content.
    private func elementIsInsideWebArea(
        _ element: AXUIElement,
        axBudget: AXMessagingBudget
    ) -> Bool {
        securePasteWebAncestry(element, axBudget: axBudget) == true
    }

    /// Unknown ancestry must not select the native password setter: it can be an
    /// incomplete browser tree. Reaching a window/application establishes native.
    private func securePasteWebAncestry(
        _ element: AXUIElement, axBudget: AXMessagingBudget
    ) -> Bool? {
        SecurePasteDeliveryPolicy.webAncestry(of: element, canContinue: { axBudget.canContinue },
            role: { self.stringAttribute(of: $0, attribute: kAXRoleAttribute as CFString, axBudget: axBudget) },
            parent: { self.parentElement(of: $0, axBudget: axBudget) })
    }

    private func parentElement(
        of element: AXUIElement,
        axBudget: AXMessagingBudget? = nil
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard copyAttributeValue(
            of: element,
            attribute: kAXParentAttribute as CFString,
            into: &value,
            axBudget: axBudget
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return withBoundedMessagingTimeout(value as! AXUIElement, axBudget: axBudget)
    }

    private func primeAccessibilityIfNeeded(
        for app: NSRunningApplication,
        force: Bool = false,
        axBudget: AXMessagingBudget? = nil
    ) {
        guard accessibilityGranted else { return }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        let shouldSetEnhancedUI = isChromiumFamily(bundleIdentifier: app.bundleIdentifier)
        let hasManualPriming = accessibilityPrimedPIDs.contains(pid)
        let hasEnhancedPriming = enhancedAccessibilityPrimedPIDs.contains(pid)

        if !force && hasManualPriming && (!shouldSetEnhancedUI || hasEnhancedPriming) {
            return
        }

        guard let appElement = withBoundedMessagingTimeout(
            AXUIElementCreateApplication(pid),
            axBudget: axBudget
        ) else { return }

        // Electron documents this explicit opt-in switch for third-party ATs.
        if force || !hasManualPriming {
            let result = setAttributeValue(
                of: appElement,
                attribute: "AXManualAccessibility" as CFString,
                value: kCFBooleanTrue,
                axBudget: axBudget
            )
            if AXMessagingBudget.primingResultIsCacheable(result) {
                accessibilityPrimedPIDs.insert(pid)
            }
        }

        // Chromium apps may require this to expose complete accessibility data
        // for non-VoiceOver assistive tools.
        if shouldSetEnhancedUI && (force || !hasEnhancedPriming) {
            let result = setAttributeValue(
                of: appElement,
                attribute: "AXEnhancedUserInterface" as CFString,
                value: kCFBooleanTrue,
                axBudget: axBudget
            )
            if AXMessagingBudget.primingResultIsCacheable(result) {
                enhancedAccessibilityPrimedPIDs.insert(pid)
            }
        }
    }

    private func setAttributeValue(
        of element: AXUIElement,
        attribute: CFString,
        value: CFTypeRef,
        axBudget: AXMessagingBudget?
    ) -> AXError {
        if let axBudget {
            return axBudget.setAttributeValue(of: element, attribute: attribute, value: value)
        }
        return AXUIElementSetAttributeValue(element, attribute, value)
    }

    private func isChromiumFamily(bundleIdentifier: String?) -> Bool {
        ChromiumBundleIDSettings.isChromiumFamily(bundleIdentifier: bundleIdentifier)
    }
}
