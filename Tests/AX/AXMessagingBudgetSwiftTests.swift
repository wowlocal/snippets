import AppKit
import Testing
@testable import SnippetsAX
@testable import SnippetsCore

@Suite("Secure Paste container targets")
@MainActor
struct SecurePasteContainerTargetTests {
    @MainActor
    private struct Fixture {
        var metadata: [Int: SecurePasteTargetResolver.Metadata] = [
            1: .init(isTextControl: false, isFocused: true, isEnabled: true),
            2: .init(isTextControl: true, isFocused: false, isEnabled: true, isSecure: true),
            3: .init(isTextControl: true, isFocused: false, isEnabled: true),
        ]
        var children = [1: [2, 3]]
        var parents = [2: 1, 3: 1]
        var focus: Int? = 1
        var window: Int? = 10
        var hit: Int? = 2
        var windowUnchanged = true
        var withinBudget = true

        func resolve(nodes: Int = 128, depth: Int = 16) -> SecurePasteTargetResolver.Resolution<Int> {
            SecurePasteTargetResolver.focusedDescendant(of: 1, maximumNodes: nodes,
                maximumDepth: depth, canContinue: { withinBudget },
                metadata: { metadata[$0] }, children: { children[$0] ?? [] })
        }

        func validates(explicit: Bool = true) -> Bool {
            SecurePasteTargetResolver.validation(field: 2, root: 1, window: 10,
                wasSecure: true, explicit: explicit, canContinue: { withinBudget },
                metadata: { metadata[$0] }, currentFocus: { focus },
                currentWindow: { _ in window }, windowIsUnchanged: { windowUnchanged },
                parent: { parents[$0] }, hitTest: { hit }) == .valid
        }
    }

    @Test("page focus and one password field do not authorize automatic insertion")
    func ambiguousPage() {
        var fixture = Fixture()
        fixture.children = [1: [2]]
        guard case .ambiguous = fixture.resolve() else { Issue.record("Guessed a field"); return }
        #expect(!fixture.validates(explicit: false))
        #expect(fixture.validates())
    }

    @Test("only a uniquely focused enabled descendant is resolved automatically")
    func focusedDescendants() {
        var fixture = Fixture()
        fixture.metadata[2] = .init(isTextControl: true, isFocused: true, isEnabled: true, isSecure: true)
        guard case .focused(2) = fixture.resolve() else { Issue.record("Missing focused field"); return }
        #expect(fixture.validates(explicit: false))
        fixture.metadata[3] = .init(isTextControl: true, isFocused: true, isEnabled: true)
        guard case .ambiguous = fixture.resolve() else { Issue.record("Accepted two focused fields"); return }
    }

    @Test("empty containers preserve the ordinary clipboard action")
    func emptyContainer() {
        var fixture = Fixture()
        fixture.children = [:]
        guard case .noTextField = fixture.resolve() else { Issue.record("Not empty"); return }
    }

    @Test("failed reads, cycles, depth and node limits never prove uniqueness", arguments: 0..<5)
    func incompleteTraversal(reason: Int) {
        var fixture = Fixture()
        var nodes = 128
        var depth = 16
        switch reason {
        case 0: fixture.metadata.removeValue(forKey: 3)
        case 1: fixture.children[1] = [1]
        case 2: nodes = 2
        case 3: depth = 0
        default: fixture.withinBudget = false
        }
        guard case .unavailable = fixture.resolve(nodes: nodes, depth: depth)
        else { Issue.record("Incomplete traversal accepted"); return }
    }

    @Test("authentication handoff refuses changed or unprovable destinations", arguments: 0..<10)
    func revalidation(reason: Int) {
        var fixture = Fixture()
        #expect(fixture.validates())
        switch reason {
        case 0: fixture.focus = 3
        case 1: fixture.window = 11
        case 2: fixture.hit = 3 // New field at the same screen position.
        case 3: fixture.parents.removeValue(forKey: 2) // Navigation detached the captured object.
        case 4: fixture.metadata.removeValue(forKey: 2) // Stale AX element.
        case 5: fixture.metadata[2] = .init(isTextControl: true, isFocused: false, isEnabled: false, isSecure: true)
        case 6: fixture.metadata[2] = .init(isTextControl: true, isFocused: false, isEnabled: true)
        case 7: fixture.windowUnchanged = false
        case 8: fixture.withinBudget = false
        default: fixture.parents[2] = 2
        }
        #expect(!fixture.validates())
    }

    @Test("a hit on field decoration must still belong to the exact chosen field")
    func hitAncestry() {
        var fixture = Fixture()
        fixture.hit = 4
        fixture.parents[4] = 2
        #expect(fixture.validates())
        fixture.parents[4] = 3
        #expect(!fixture.validates())
    }

    @Test("deadline expiry after metadata reads refuses the write")
    func expiredDuringValidation() {
        let fixture = Fixture()
        var checks = 0
        #expect(SecurePasteTargetResolver.validation(field: 2, root: 1, window: 10,
            wasSecure: true, explicit: true,
            canContinue: { checks += 1; return checks == 1 },
            metadata: { fixture.metadata[$0] }, currentFocus: { 1 },
            currentWindow: { _ in 10 }, windowIsUnchanged: { true },
            parent: { fixture.parents[$0] }, hitTest: { 2 }) == .budgetExhausted)
    }

    @Test("authentication keyboard ownership settles before focus restoration")
    func handoffWaitsForKeyboardOwner() async {
        var observations: [SecurePasteTargetResolver.Validation] = [
            .keyboardOwnerPending, .focusUnavailable, .valid, .valid, .valid, .valid, .valid, .valid,
        ]
        var restorations = 0
        let report = await SecurePasteFocusHandoff.runForContainer(mode: .afterAuthentication, sleep: { _ in },
            observe: { observations.removeFirst() }, restoreFocus: { restorations += 1 })
        #expect(report.validation == .valid)
        #expect(report.attempts == 5)
        #expect(report.firstTransient == .keyboardOwnerPending)
        #expect(restorations == 3)
    }

    @Test("an intact automatic descendant can regain focus after authentication")
    func handoffRestoresFieldFocus() async {
        var focused = false
        let report = await SecurePasteFocusHandoff.runForContainer(mode: .afterAuthentication, sleep: { _ in },
            observe: { focused ? .valid : .fieldFocusPending }, restoreFocus: { focused = true })
        #expect(report.validation == .valid)
        #expect(report.firstTransient == .fieldFocusPending)
        #expect(report.attempts == 3)
    }

    @Test("structural changes abort immediately, even after a valid sample",
          arguments: SecurePasteTargetResolver.Validation.allCases.filter { !$0.canRetryHandoff })
    func handoffRejectsChangedDestination(failure: SecurePasteTargetResolver.Validation) async {
        var samples = [SecurePasteTargetResolver.Validation.valid, .valid, failure]
        var restorations = 0
        let report = await SecurePasteFocusHandoff.runForContainer(mode: .afterAuthentication, sleep: { _ in },
            observe: { samples.removeFirst() }, restoreFocus: { restorations += 1 })
        #expect(report.validation == failure)
        #expect(report.attempts == 2)
        #expect(restorations == 1)
    }

    @Test("focus interruption resets consecutive confirmations and retries stay bounded")
    func handoffIsBoundedAndConsecutive() async {
        var samples: [SecurePasteTargetResolver.Validation] = [
            .valid, .valid, .keyboardOwnerPending, .valid, .valid, .focusUnavailable,
            .valid, .valid, .keyboardOwnerPending,
        ]
        var elapsed = Duration.zero
        let report = await SecurePasteFocusHandoff.runForContainer(mode: .afterAuthentication,
            sleep: { elapsed += $0 },
            observe: { samples.isEmpty ? .keyboardOwnerPending : samples.removeFirst() }, restoreFocus: {})
        #expect(report.validation == .keyboardOwnerPending)
        #expect(report.attempts < 20)
        #expect(elapsed <= .milliseconds(1_640))
    }

    @Test("task cancellation while waiting prevents focus restoration")
    func cancelledHandoff() async {
        var restorations = 0
        let task = Task { @MainActor in
            await SecurePasteFocusHandoff.runForContainer(mode: .afterAuthentication,
                sleep: { _ in await Task.yield() },
                observe: { .valid }, restoreFocus: { restorations += 1 })
        }
        task.cancel()
        let report = await task.value
        #expect(report.validation == .cancelled)
        #expect(restorations == 0)
    }

    @Test("every failed validation has a closed diagnostic reason")
    func diagnosticVocabulary() {
        for validation in SecurePasteTargetResolver.Validation.allCases where validation != .valid {
            #expect(DiagnosticSecurePasteReason(rawValue: validation.rawValue) != nil)
        }
    }

    @Test("cancelling field selection discards the request without selecting or delivering")
    func cancelSelection() {
        _ = NSApplication.shared
        let controller = SecurePasteFieldSelectionController()
        var selections = 0
        var dismissals = 0
        controller.show(frame: NSRect(x: -10_000, y: -10_000, width: 300, height: 200),
            targetPID: ProcessInfo.processInfo.processIdentifier,
            onDismiss: { dismissals += 1 }, onSelection: { _ in selections += 1 })
        #expect(controller.isVisible)
        controller.cancel()
        controller.cancel()
        #expect(!controller.isVisible)
        #expect(selections == 0)
        #expect(dismissals == 1)
    }
}

@Suite("Accessibility messaging budget")
@MainActor
struct AXMessagingBudgetSwiftTests {
    @Test("per-object timeouts shrink to one aggregate deadline")
    func shrinkingTimeoutNeverExceedsAggregateDeadline() {
        var now = ContinuousClock().now
        var configuredTimeouts: [Float] = []
        let element = AXUIElementCreateSystemWide()
        let budget = AXMessagingBudget(
            totalTimeoutSeconds: 0.4,
            perMessageTimeoutSeconds: 0.4,
            now: { now },
            setMessagingTimeout: { _, timeout in
                configuredTimeouts.append(timeout)
                return .success
            }
        )

        #expect(budget.bind(element))
        #expect(abs(configuredTimeouts[0] - 0.4) <= 0.001)

        now = now.advanced(by: .milliseconds(125))
        #expect(budget.bind(element))
        #expect(abs(configuredTimeouts[1] - 0.275) <= 0.001)

        now = now.advanced(by: .milliseconds(276))
        #expect(!budget.bind(element))
        #expect(configuredTimeouts.count == 2)
        #expect(budget.stopReason == .deadlineExceeded)
        #expect(abs(budget.elapsedMilliseconds - 401) <= 0.001)
    }

    @Test("a timeout-configuration failure prevents the AX message")
    func timeoutConfigurationFailureStopsInteraction() {
        let budget = AXMessagingBudget(
            setMessagingTimeout: { _, _ in .invalidUIElement }
        )

        #expect(!budget.bind(AXUIElementCreateSystemWide()))
        #expect(budget.stopReason == .timeoutConfigurationFailed(.invalidUIElement))
    }

    @Test("only permanent priming answers are cached")
    func onlyPermanentPrimingAnswersAreCached() {
        #expect(AXMessagingBudget.primingResultIsCacheable(.success))
        #expect(AXMessagingBudget.primingResultIsCacheable(.attributeUnsupported))
        #expect(AXMessagingBudget.primingResultIsCacheable(.notImplemented))
        #expect(!AXMessagingBudget.primingResultIsCacheable(.cannotComplete))
        #expect(!AXMessagingBudget.primingResultIsCacheable(.apiDisabled))
        #expect(!AXMessagingBudget.primingResultIsCacheable(.invalidUIElement))
        #expect(!AXMessagingBudget.primingResultIsCacheable(.illegalArgument))
    }

    @Test("Secure Paste retains native password whole-value replacement")
    func securePastePrefersWholeSecureValue() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: true,
            valueIsSettable: true,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true
        ) == .replaceSecureValue)
    }

    @Test("Secure Paste fails closed for a password field without a writable value")
    func securePasteRequiresWritableSecureValue() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: true,
            valueIsSettable: false,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true
        ) == .unavailable)
    }

    @Test("web passwords use input events even when AXValue advertises success",
          arguments: [true, false], [true, false])
    func secureWebPasteDoesNotDependOnAXWrites(valueSettable: Bool, rangeAvailable: Bool) {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: true, valueIsSettable: valueSettable,
            targetIsInsideWebArea: true, targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: rangeAvailable) == .typeSecureUnicode)
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: true, valueIsSettable: valueSettable,
            targetIsInsideWebArea: true, targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: rangeAvailable) == .unavailable)
    }

    @Test("container evidence never substitutes for keyboard focus in a web password",
          arguments: [true, false], [true, false])
    func directInputRequiresConcreteSecureField(container: Bool, focused: Bool) {
        #expect(SecurePasteDeliveryPolicy.permitsDirectInput(isSecureWebField: true,
            hasContainerBinding: container, exactFieldHasKeyboardFocus: focused) == focused)
        #expect(SecurePasteDeliveryPolicy.permitsDirectInput(isSecureWebField: false,
            hasContainerBinding: container, exactFieldHasKeyboardFocus: focused) == !container)
    }

    @Test("an accepted/no-op or rejected password setter is never confirmed delivery",
          arguments: [AXError.success, .cannotComplete, .attributeUnsupported, .invalidUIElement])
    func acceptedPasswordSetterIsUnconfirmed(error: AXError) {
        #expect(SecurePasteDeliveryPolicy.secureValueWriteResult(error) == .attemptedAmbiguous)
        #expect(SecurePasteCompletionPolicy.reaction(after: .attemptedAmbiguous) == .warnWithoutRestoringFocus)
    }

    @Test("native and web password ancestry require positive metadata")
    func secureWebAncestryClassification() {
        for rootRole in ["AXWebArea", "AXWindow", "AXApplication"] {
            #expect(SecurePasteDeliveryPolicy.webAncestry(of: 1, canContinue: { true },
                role: { $0 == 1 ? "AXTextField" : rootRole },
                parent: { $0 == 1 ? 2 : nil }) == (rootRole == "AXWebArea"))
        }
        #expect(SecurePasteDeliveryPolicy.webAncestry(of: 1, canContinue: { true },
            role: { _ in "AXTextField" }, parent: { _ in nil }) == nil)
        #expect(SecurePasteDeliveryPolicy.webAncestry(of: 1, canContinue: { true },
            role: { _ in nil }, parent: { _ in 2 }) == nil)
        #expect(SecurePasteDeliveryPolicy.webAncestry(of: 1, canContinue: { false },
            role: { _ in "AXWebArea" }, parent: { _ in 2 }) == nil)
        #expect(SecurePasteDeliveryPolicy.webAncestry(of: 1, canContinue: { true },
            role: { _ in "AXGroup" }, parent: { $0 == 1 ? 2 : 1 }) == nil)
        var visited = 0
        #expect(SecurePasteDeliveryPolicy.webAncestry(of: 1, canContinue: { true },
            role: { _ in visited += 1; return "AXGroup" }, parent: { $0 + 1 }) == nil)
        #expect(visited == 16)
        var budget = true
        #expect(SecurePasteDeliveryPolicy.webAncestry(of: 1, canContinue: { budget },
            role: { _ in budget = false; return "AXWindow" }, parent: { _ in nil }) == nil)
    }

    @Test("Secure Paste prefers the advertised browser range operation in web text fields")
    func securePasteUsesWebRangeReplacement() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: true
        ) == .replaceWebRange)
    }

    @Test("ordinary picker content uses the same direct input as secure content")
    func ordinaryPickerContentUsesDirectInput() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: false
        ) == .typeUnicode)
    }

    @Test("Secure Paste fails closed when a web operation is not advertised")
    func securePasteRequiresAdvertisedWebCapability() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: true,
            webRangeReplacementIsAvailable: false
        ) == .unavailable)
    }

    @Test("Secure Paste refuses the native route for generic web controls")
    func securePasteRefusesNoneligibleWebControls() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: true,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: true
        ) == .unavailable)
    }

    @Test("web eligibility includes standard single-line and multiline text roles")
    func securePasteRecognizesStandardWebTextRoles() {
        #expect(SecurePasteDeliveryPolicy.isEligibleWebTextRole("AXTextField"))
        #expect(SecurePasteDeliveryPolicy.isEligibleWebTextRole("AXComboBox"))
        #expect(SecurePasteDeliveryPolicy.isEligibleWebTextRole("AXTextArea"))
        #expect(!SecurePasteDeliveryPolicy.isEligibleWebTextRole("AXGroup"))
        #expect(!SecurePasteDeliveryPolicy.isEligibleWebTextRole(nil))
    }

    @Test("web range delivery requires both replacement and readback capabilities")
    func securePasteRequiresCompleteWebRangeCapabilities() {
        #expect(SecurePasteDeliveryPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: [
                "AXReplaceRangeWithText",
                "AXStringForRange",
                "AXBoundsForRange",
            ]
        ))
        #expect(!SecurePasteDeliveryPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: ["AXReplaceRangeWithText"]
        ))
        #expect(!SecurePasteDeliveryPolicy.supportsWebRangeReplacement(
            advertisedParameterizedAttributes: ["AXStringForRange"]
        ))
    }

    @Test("native delivery does not depend on writable AX selected text")
    func nativeDeliveryDoesNotDependOnAXSelectedText() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: true,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: false
        ) == .typeUnicode)
    }

    @Test("native direct input selection requires no host identity")
    func securePasteUsesDirectUnicodeForNativeAndCustomTextSurfaces() {
        #expect(SecurePasteDeliveryPolicy.strategy(
            targetIsSecureTextField: false,
            valueIsSettable: false,
            targetIsInsideWebArea: false,
            targetHasEligibleWebTextRole: false,
            webRangeReplacementIsAvailable: false
        ) == .typeUnicode)
    }

    @Test("direct input accepts printable Unicode and reconstructs one tagged key event")
    func securePasteDirectInputBuildsUnicodeEvent() throws {
        let text = "токен-😀"
        let tag: Int64 = 0x5A17
        let events = try #require(SecurePasteDirectInputPolicy.makeEvents(
            text: text,
            eventTag: tag
        ))

        var actualLength = 0
        var utf16 = [UniChar](repeating: 0, count: text.utf16.count)
        events.keyDown.keyboardGetUnicodeString(
            maxStringLength: utf16.count,
            actualStringLength: &actualLength,
            unicodeString: &utf16
        )

        #expect(String(decoding: utf16.prefix(actualLength), as: UTF16.self) == text)
        #expect(events.keyDown.getIntegerValueField(.keyboardEventKeycode)
            == Int64(SecurePasteDirectInputPolicy.unicodeOnlyVirtualKey))
        #expect(events.keyDown.getIntegerValueField(.eventSourceUserData) == tag)
        #expect(events.keyUp.getIntegerValueField(.eventSourceUserData) == tag)
    }

    @Test("direct input rejects controls, empty content, and oversized content")
    func securePasteDirectInputValidationFailsClosed() {
        #expect(SecurePasteDirectInputPolicy.validation(of: "token-😀") == .allowed)
        #expect(SecurePasteDirectInputPolicy.validation(of: "") == .empty)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\nb") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\rb") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\tb") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\0b") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(of: "a\u{0085}b") == .containsControlCharacter)
        #expect(SecurePasteDirectInputPolicy.validation(
            of: String(repeating: "x", count: SecurePasteDirectInputPolicy.maximumUTF16Count + 1)
        ) == .tooLong)
    }

    @Test("routine keyboard dispatch has no warning, beep or focus restoration")
    func securePasteDispatchedInputIsQuietButNotConfirmed() {
        #expect(SecurePasteCompletionPolicy.reaction(after: .dispatchedUnconfirmed) == .none)
        // Do not turn an unacknowledged keyboard operation into verified insertion
        // just to silence the HUD. The engine records usage only for .inserted.
        #expect(SecurePasteResult.dispatchedUnconfirmed != .inserted)
    }

    @Test("an ambiguous Secure Paste attempt still warns without restoring focus")
    func securePasteAmbiguityDoesNotRestoreFocus() {
        #expect(SecurePasteCompletionPolicy.reaction(after: .inserted) == .none)
        #expect(SecurePasteCompletionPolicy.reaction(
            after: .failedBeforeAttempt
        ) == .restoreOriginalFocus)
        #expect(SecurePasteCompletionPolicy.reaction(
            after: .blockedUnsafeControlCharacters
        ) == .warnAfterRestoringFocus)
        #expect(SecurePasteCompletionPolicy.reaction(
            after: .attemptedAmbiguous
        ) == .warnWithoutRestoringFocus)
    }

    @Test("Secure Paste waits for authentication secure input before restoring an ordinary field")
    func securePasteWaitsForAuthenticationSecureInput() {
        #expect(SecurePasteAuthenticationHandoffPolicy.shouldWaitForSecureInputToClear(
            targetIsSecureTextField: false,
            secureInputWasEnabledAtCapture: false
        ))
        #expect(SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
            waitForAuthenticationSecureInputToClear: true,
            secureEventInputEnabled: true
        ))
        #expect(!SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
            waitForAuthenticationSecureInputToClear: true,
            secureEventInputEnabled: false
        ))
    }

    @Test("Secure Paste preserves password fields and pre-existing secure terminal input")
    func securePastePreservesLegitimateSecureInput() {
        #expect(!SecurePasteAuthenticationHandoffPolicy.shouldWaitForSecureInputToClear(
            targetIsSecureTextField: true,
            secureInputWasEnabledAtCapture: false
        ))
        #expect(!SecurePasteAuthenticationHandoffPolicy.shouldWaitForSecureInputToClear(
            targetIsSecureTextField: false,
            secureInputWasEnabledAtCapture: true
        ))
        #expect(!SecurePasteAuthenticationHandoffPolicy.secureInputBlocksRestore(
            waitForAuthenticationSecureInputToClear: false,
            secureEventInputEnabled: true
        ))
    }

    @Test("Secure Paste focus confirmations must be consecutive")
    func securePasteFocusConfirmationsResetAfterInterruption() {
        var confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: 0,
                targetIsFrontmost: true,
                focusWasReasserted: true
            )
        #expect(confirmations == 1)
        #expect(!SecurePasteAuthenticationHandoffPolicy.focusIsStable(
            consecutiveConfirmations: confirmations
        ))

        confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: confirmations,
                targetIsFrontmost: true,
                focusWasReasserted: true
            )
        #expect(confirmations == 2)
        #expect(!SecurePasteAuthenticationHandoffPolicy.focusIsStable(
            consecutiveConfirmations: confirmations
        ))

        confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: confirmations,
                targetIsFrontmost: false,
                focusWasReasserted: false
            )
        #expect(confirmations == 0)

        confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: confirmations,
                targetIsFrontmost: true,
                focusWasReasserted: true
            )
        #expect(confirmations == 1)
        confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: confirmations,
                targetIsFrontmost: true,
                focusWasReasserted: true
            )
        #expect(confirmations == 2)
        #expect(!SecurePasteAuthenticationHandoffPolicy.focusIsStable(
            consecutiveConfirmations: confirmations
        ))
        confirmations = SecurePasteAuthenticationHandoffPolicy
            .updatedConsecutiveFocusConfirmations(
                current: confirmations,
                targetIsFrontmost: true,
                focusWasReasserted: true
            )
        #expect(confirmations == 3)
        #expect(SecurePasteAuthenticationHandoffPolicy.focusIsStable(
            consecutiveConfirmations: confirmations
        ))
    }

    @Test("web replacement planning uses UTF-16 offsets")
    func webReplacementUsesUTF16Offsets() throws {
        let snapshot = try #require(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 10,
            selectionLocation: 3,
            selectionLength: 4,
            selectedText: "3456"
        ))
        let plan = try #require(SecurePasteWebReplacementPolicy.plan(
            replacing: snapshot,
            with: "a😀b"
        ))

        #expect(plan.replacementLocation == 3)
        #expect(plan.replacementLength == 4)
        #expect(plan.replacementUTF16Count == 4)
        #expect(plan.expectedFieldUTF16Count == 10)
        #expect(plan.caretLocation == 7)
    }

    @Test("web replacement rejects an invalid or unreadable selection")
    func webReplacementRejectsInvalidSelection() {
        #expect(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 5,
            selectionLocation: 4,
            selectionLength: 2,
            selectedText: "45"
        ) == nil)
        #expect(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 5,
            selectionLocation: 1,
            selectionLength: 2,
            selectedText: "😀"
        ) != nil)
        #expect(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 5,
            selectionLocation: 1,
            selectionLength: 1,
            selectedText: "😀"
        ) == nil)
    }

    @Test("web replacement accepts multiline and bounded large payloads")
    func webReplacementPreservesExistingSnippetShapes() throws {
        let snapshot = try #require(SecurePasteWebReplacementPolicy.snapshot(
            fieldUTF16Count: 3,
            selectionLocation: 0,
            selectionLength: 3,
            selectedText: "old"
        ))

        #expect(SecurePasteWebReplacementPolicy.plan(replacing: snapshot, with: "old") == nil)
        #expect(SecurePasteWebReplacementPolicy.plan(replacing: snapshot, with: "a\nb") != nil)
        #expect(SecurePasteWebReplacementPolicy.plan(
            replacing: snapshot,
            with: String(repeating: "x", count: 999_999)
        ) != nil)
        #expect(SecurePasteWebReplacementPolicy.plan(
            replacing: snapshot,
            with: String(repeating: "x", count: 1_000_001)
        ) == nil)
    }

    @Test("web replacement confirmation is exact instead of canonically equivalent")
    func webReplacementConfirmationUsesExactUTF16() {
        let first = "a\u{0301}\u{0327}"
        let reordered = "a\u{0327}\u{0301}"

        #expect(first == reordered)
        #expect(!SecurePasteWebReplacementPolicy.utf16ContentsMatch(first, reordered))
        #expect(SecurePasteWebReplacementPolicy.utf16ContentsMatch(first, first))
    }

    @Test("Secure Paste keeps relevance ahead of security preference")
    func securePasteRelevanceComesFirst() {
        #expect(SecurePasteSuggestionRankingPolicy.decision(
            lhsScore: 20,
            lhsKeywordRank: 1,
            lhsIsSecure: false,
            rhsScore: 10,
            rhsKeywordRank: 3,
            rhsIsSecure: true
        ) == .lhsFirst)
    }

    @Test("Secure Paste ranks secure snippets first when relevance ties")
    func securePasteSecurityBreaksRelevanceTie() {
        #expect(SecurePasteSuggestionRankingPolicy.decision(
            lhsScore: 20,
            lhsKeywordRank: 2,
            lhsIsSecure: false,
            rhsScore: 20,
            rhsKeywordRank: 2,
            rhsIsSecure: true
        ) == .rhsFirst)
    }

    @Test("Secure Paste leaves equal security rows to normal ranking")
    func securePasteRankingFallsThrough() {
        #expect(SecurePasteSuggestionRankingPolicy.decision(
            lhsScore: 20,
            lhsKeywordRank: 2,
            lhsIsSecure: true,
            rhsScore: 20,
            rhsKeywordRank: 2,
            rhsIsSecure: true
        ) == .tied)
    }
}
