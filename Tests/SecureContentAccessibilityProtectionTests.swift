import AppKit

private func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor
@main
private enum SecureContentAccessibilityProtectionTests {
    static func main() {
        testRegistrationFailureFailsClosedAndIsSticky()
        testProtectedPresentationPreservesTheSystemAccessibilityValue()
        print("SecureContentAccessibilityProtectionTests passed")
    }

    private static func testRegistrationFailureFailsClosedAndIsSticky() {
        var registrationCalls = 0
        let protection = SecureContentAccessibilityProtection { requested in
            registrationCalls += 1
            assertTrue(requested, "registration must opt into protected content")
            return false
        }
        let textView = SnippetContentTextView()

        assertTrue(!protection.canPresentSecurePlaintext, "unregistered protection fails closed")
        assertTrue(
            !protection.beginProtecting([textView]),
            "an unregistered process cannot begin a secure presentation"
        )
        assertTrue(!textView.isAccessibilityProtectedContent(), "failed begin leaves the view ordinary")

        assertTrue(!protection.registerApplication(), "a failed AppKit registration is reported")
        assertTrue(protection.availability == .unavailable, "registration failure is remembered")
        assertTrue(!protection.registerApplication(), "registration failure remains fail closed")
        assertTrue(registrationCalls == 1, "a sticky failure does not retry behind the caller's back")
    }

    private static func testProtectedPresentationPreservesTheSystemAccessibilityValue() {
        var registrationCalls = 0
        let protection = SecureContentAccessibilityProtection { requested in
            registrationCalls += 1
            return requested
        }
        let textView = SnippetContentTextView()
        let preview = NSTextField(wrappingLabelWithString: "")

        assertTrue(protection.registerApplication(), "successful registration permits presentation")
        assertTrue(protection.registerApplication(), "successful registration is idempotent")
        assertTrue(registrationCalls == 1, "successful registration occurs once")

        // Production follows this exact order: protect every destination, then
        // materialize plaintext. Direct in-process AX getters deliberately keep
        // returning the value; AppKit applies the protected-content policy at
        // the client boundary, including its VoiceOver exception.
        assertTrue(protection.beginProtecting([textView, preview]), "registered presentation begins")
        textView.prepareForSecurePlaintextAccessibility()
        assertTrue(textView.mayContainSecurePlaintext, "the editor records the protected interval")
        assertTrue(textView.isAccessibilityProtectedContent(), "the editor declares protected content")
        assertTrue(preview.isAccessibilityProtectedContent(), "the preview declares protected content")

        textView.string = "test secure body"
        preview.stringValue = "test secure preview"
        assertTrue(
            textView.accessibilityValue() == "test secure body",
            "the app does not redact AXValue and break system assistive technologies"
        )

        // Clear every plaintext destination before ending the protected interval.
        textView.string = ""
        preview.stringValue = ""
        textView.securePlaintextWasClearedFromAccessibility()
        protection.endProtecting([textView, preview])

        assertTrue(!textView.mayContainSecurePlaintext, "the editor exits the protected interval")
        assertTrue(!textView.isAccessibilityProtectedContent(), "a cleared editor becomes ordinary")
        assertTrue(!preview.isAccessibilityProtectedContent(), "a cleared preview becomes ordinary")

        textView.string = "ordinary body"
        assertTrue(
            textView.accessibilityValue() == "ordinary body",
            "ordinary snippets retain normal accessibility"
        )
    }
}
