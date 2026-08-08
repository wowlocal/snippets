import Foundation

// Standalone executable, matching Tests/SuggestionTriggerContextTests.swift.
// Build and run:
//
//   swiftc -O snippets/SyntheticEventTag.swift snippets/SnippetInjectionGate.swift \
//          Tests/SnippetInjectionGateTests.swift -o /tmp/injection-gate-tests \
//          && /tmp/injection-gate-tests

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) - expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum SnippetInjectionGateTests {
    static func main() {
        testSyntheticTag()
        testRefusal()
        testApplicationActivationInvalidation()
        testInputDisposition()
        print("SnippetInjectionGate tests passed")
    }

    private static func testSyntheticTag() {
        assertEqual(
            SnippetSyntheticEvent.origin(eventUserData: SnippetSyntheticEvent.tag),
            .selfInjected,
            "our own tag is recognized"
        )
        assertEqual(
            SnippetSyntheticEvent.origin(eventUserData: 0),
            .user,
            "real keystrokes carry zero"
        )
        assertEqual(
            SnippetSyntheticEvent.origin(eventUserData: nil),
            .user,
            "a missing field fails open to user input"
        )
        assertEqual(
            SnippetSyntheticEvent.origin(eventUserData: SnippetSyntheticEvent.tag &+ 1),
            .user,
            "neighbouring values are not ours"
        )
        assertEqual(
            SnippetSyntheticEvent.origin(eventUserData: 1),
            .user,
            "small values another automation tool might use are not ours"
        )
        assertTrue(SnippetSyntheticEvent.tag != 0, "tag must be distinguishable from real input")
        assertTrue(
            SnippetSyntheticEvent.tag > 0xFFFF,
            "tag stays clear of the small values other tools plausibly use"
        )
    }

    private static func testRefusal() {
        assertEqual(
            SnippetInjectionGate.refusal(
                secureEventInputEnabled: true,
                isSecureSnippet: true,
                secureSnippetIsAuthenticated: false,
                isListening: false,
                ownAppIsFrontmost: true,
                deleteCount: 0
            ),
            .secureEventInput,
            "secure input outranks every other refusal"
        )
        assertEqual(
            SnippetInjectionGate.refusal(
                secureEventInputEnabled: true,
                isSecureSnippet: false,
                secureSnippetIsAuthenticated: false,
                isListening: true,
                ownAppIsFrontmost: false,
                deleteCount: 6
            ),
            .secureEventInput,
            "secure input refuses an otherwise valid expansion"
        )
        assertEqual(
            SnippetInjectionGate.refusal(
                secureEventInputEnabled: false,
                isSecureSnippet: true,
                secureSnippetIsAuthenticated: false,
                isListening: true,
                ownAppIsFrontmost: false,
                deleteCount: 6
            ),
            .secureSnippetRequiresAuthentication,
            "a secure display shell is refused before any trigger deletion"
        )
        assertEqual(
            SnippetInjectionGate.refusal(
                secureEventInputEnabled: false,
                isSecureSnippet: true,
                secureSnippetIsAuthenticated: true,
                isListening: true,
                ownAppIsFrontmost: false,
                deleteCount: 6
            ),
            nil,
            "an explicitly authenticated secure expansion is allowed"
        )
        assertEqual(
            SnippetInjectionGate.refusal(
                secureEventInputEnabled: false,
                isSecureSnippet: false,
                secureSnippetIsAuthenticated: false,
                isListening: true,
                ownAppIsFrontmost: false,
                deleteCount: 0
            ),
            .nothingToDelete,
            "an empty deletion is refused"
        )
        assertEqual(
            SnippetInjectionGate.refusal(
                secureEventInputEnabled: false,
                isSecureSnippet: false,
                secureSnippetIsAuthenticated: false,
                isListening: true,
                ownAppIsFrontmost: true,
                deleteCount: 6
            ),
            .ownAppIsFrontmost,
            "we never inject into ourselves"
        )
        assertEqual(
            SnippetInjectionGate.refusal(
                secureEventInputEnabled: false,
                isSecureSnippet: false,
                secureSnippetIsAuthenticated: false,
                isListening: true,
                ownAppIsFrontmost: false,
                deleteCount: 6
            ),
            nil,
            "a healthy expansion is allowed"
        )
    }

    private static func testInputDisposition() {
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .selfInjected,
                secureEventInputEnabled: false,
                isListening: true,
                isInjecting: false,
                ownAppIsFrontmost: false
            ),
            .ignore,
            "our own events are skipped even when nothing else would skip them"
        )
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .selfInjected,
                secureEventInputEnabled: true,
                isListening: true,
                isInjecting: true,
                ownAppIsFrontmost: false
            ),
            .ignore,
            "synthetic outranks secure input: our event must not be read as typing that resets"
        )
        // The regression this guards: never swallow keys while the user types a password.
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .user,
                secureEventInputEnabled: true,
                isListening: true,
                isInjecting: false,
                ownAppIsFrontmost: false
            ),
            .resetAndPassThrough,
            "secure input drops state without suppressing the key"
        )
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .user,
                secureEventInputEnabled: true,
                isListening: true,
                isInjecting: true,
                ownAppIsFrontmost: false,
                isAuthenticatingSecureSuggestion: true
            ),
            .ignore,
            "password fallback passes through without invalidating its saved target"
        )
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .user,
                secureEventInputEnabled: false,
                isListening: true,
                isInjecting: true,
                ownAppIsFrontmost: true,
                isAuthenticatingSecureSuggestion: true
            ),
            .ignore,
            "authentication-sheet typing is never collected as a snippet query"
        )
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .user,
                secureEventInputEnabled: true,
                isListening: true,
                isInjecting: true,
                ownAppIsFrontmost: false
            ),
            .resetAndPassThrough,
            "secure input flipping mid-injection still clears the buffer"
        )
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .user,
                secureEventInputEnabled: false,
                isListening: true,
                isInjecting: true,
                ownAppIsFrontmost: false
            ),
            .ignore,
            "user input during injection is ignored, not treated as typing"
        )
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .user,
                secureEventInputEnabled: false,
                isListening: false,
                isInjecting: false,
                ownAppIsFrontmost: false
            ),
            .ignore,
            "a stopped engine ignores input"
        )
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .user,
                secureEventInputEnabled: false,
                isListening: true,
                isInjecting: false,
                ownAppIsFrontmost: true
            ),
            .resetAndPassThrough,
            "typing in our own window resets the tracked context"
        )
        assertEqual(
            SnippetInjectionGate.inputDisposition(
                origin: .user,
                secureEventInputEnabled: false,
                isListening: true,
                isInjecting: false,
                ownAppIsFrontmost: false
            ),
            .process,
            "ordinary typing is processed"
        )
    }

    private static func testApplicationActivationInvalidation() {
        let own: Int32 = 10
        let target: Int32 = 20

        assertTrue(
            !SnippetInjectionGate.applicationActivationInvalidatesContext(
                activatedPID: own,
                ownPID: own,
                secureAuthenticationTargetPID: target,
                secureEventInputEnabled: true),
            "our Touch ID activation does not invalidate its own pending expansion"
        )
        assertTrue(
            !SnippetInjectionGate.applicationActivationInvalidatesContext(
                activatedPID: target,
                ownPID: own,
                secureAuthenticationTargetPID: target,
                secureEventInputEnabled: false),
            "returning focus to the authenticated target is expected"
        )
        assertTrue(
            !SnippetInjectionGate.applicationActivationInvalidatesContext(
                activatedPID: target,
                ownPID: own,
                secureAuthenticationTargetPID: nil,
                secureExpansionTargetPID: target,
                secureEventInputEnabled: false),
            "a delayed activation receipt cannot cancel the queued secure insertion"
        )
        assertTrue(
            SnippetInjectionGate.applicationActivationInvalidatesContext(
                activatedPID: 30,
                ownPID: own,
                secureAuthenticationTargetPID: nil,
                secureExpansionTargetPID: target,
                secureEventInputEnabled: false),
            "the activation grace applies only to the exact restored target"
        )
        assertTrue(
            !SnippetInjectionGate.applicationActivationInvalidatesContext(
                activatedPID: 30,
                ownPID: own,
                secureAuthenticationTargetPID: target,
                secureEventInputEnabled: false),
            "authentication implementation processes do not invalidate the saved target"
        )
        assertTrue(
            SnippetInjectionGate.applicationActivationInvalidatesContext(
                activatedPID: 30,
                ownPID: own,
                secureAuthenticationTargetPID: nil,
                secureEventInputEnabled: true),
            "unrelated secure input still tears down an ordinary suggestion"
        )
        assertTrue(
            !SnippetInjectionGate.applicationActivationInvalidatesContext(
                activatedPID: own,
                ownPID: own,
                secureAuthenticationTargetPID: nil,
                secureEventInputEnabled: false),
            "our nonactivating suggestion UI does not invalidate its own session"
        )
        assertTrue(
            !SnippetInjectionGate.pointerInteractionInvalidatesContext(
                secureAuthenticationTargetPID: target),
            "clicking Use Password belongs to the pending authentication flow"
        )
        assertTrue(
            SnippetInjectionGate.pointerInteractionInvalidatesContext(
                secureAuthenticationTargetPID: nil),
            "an ordinary global click still invalidates its caret snapshot"
        )
    }
}
