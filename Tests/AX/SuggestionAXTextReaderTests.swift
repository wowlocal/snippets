import AppKit
import Testing
@testable import SnippetsAX

@Suite("Suggestion insertion context")
@MainActor
struct SuggestionAXTextReaderTests {
    private struct Host {
        var range = CFRange(location: 0, length: 0)
        var rangeError = AXError.success
        var role = kAXTextAreaRole
        var selectionSettable = false
        var settableError = AXError.success
        var boundsError = AXError.parameterizedAttributeUnsupported
        var caretBounds = CGRect(x: 0, y: 0, width: 0, height: 16)
        var rangeText: String?
        var textError = AXError.parameterizedAttributeUnsupported
        var value = ""

        var reader: SuggestionAXTextReader {
            SuggestionAXTextReader(
                copyAttribute: { attribute, output in
                    switch attribute as String {
                    case kAXSelectedTextRangeAttribute:
                        var range = range
                        output = AXValueCreate(.cfRange, &range)
                        return rangeError
                    case kAXRoleAttribute:
                        output = role as CFString
                    case kAXValueAttribute:
                        output = value as CFString
                    default:
                        Issue.record("unexpected attribute")
                        return .attributeUnsupported
                    }
                    return .success
                },
                copyParameterizedAttribute: { attribute, _, output in
                    switch attribute as String {
                    case kAXBoundsForRangeParameterizedAttribute:
                        var bounds = caretBounds
                        output = AXValueCreate(.cgRect, &bounds)
                        return boundsError
                    case kAXStringForRangeParameterizedAttribute:
                        output = rangeText as CFString?
                        return textError
                    default:
                        Issue.record("unexpected parameterized attribute")
                        return .parameterizedAttributeUnsupported
                    }
                },
                isSelectionSettable: { (settableError, selectionSettable) })
        }
    }

    @Test func ghosttyValueNotificationsDoNotManufactureMissingTrigger() {
        // Observed live: AXTextArea, {0, 0}, selection not settable,
        // AXBoundsForRange unsupported. Screen contents change on each key.
        for value in ["prompt", "prompt \\", "prompt \\abc"] {
            let host = Host(value: value)
            guard case .unavailable(let failure) = host.reader.read(maxCharacters: 500) else {
                Issue.record("terminal placeholder must not become authoritative empty text")
                return
            }
            #expect(failure.allowsLocalTracking)
            #expect(!failure.mayReadAncestor)
        }
    }

    @Test func realEditorAtDocumentStartStillReportsEmptyText() {
        let host = Host(selectionSettable: true, value: "body")
        guard case .text(let text) = host.reader.read(maxCharacters: 500) else {
            Issue.record("a writable selection at zero is a real empty prefix")
            return
        }
        #expect(text.isEmpty)
    }

    @Test func readOnlyCaretGeometryAlsoConfirmsDocumentStart() {
        let host = Host(boundsError: .success)
        guard case .text(let text) = host.reader.read(maxCharacters: 500) else {
            Issue.record("a zero-width caret with positive height is valid")
            return
        }
        #expect(text.isEmpty)
    }

    @Test func readableTextWithoutTriggerRemainsAuthoritative() {
        let host = Host(range: CFRange(location: 5, length: 0), value: "plain")
        guard case .text(let text) = host.reader.read(maxCharacters: 500) else {
            Issue.record("valid AXValue fallback must remain readable")
            return
        }
        #expect(text == "plain")
    }

    @Test func utf16RangeTextIsReadWithoutChangingItsMeaning() {
        let host = Host(range: CFRange(location: 5, length: 0), rangeText: "😀\\ab", textError: .success)
        guard case .text(let text) = host.reader.read(maxCharacters: 500) else {
            Issue.record("AX ranges use UTF-16, not grapheme count")
            return
        }
        #expect(text == "😀\\ab")
    }

    @Test func inconsistentReadsAndSelectionsCannotAuthorizeLocalDeletion() {
        let hosts = [
            Host(range: CFRange(location: 80, length: 0), value: "\\abc"),
            Host(range: CFRange(location: 4, length: 1), value: "\\abcX"),
            Host(range: CFRange(location: 4, length: 0), rangeText: "ab", textError: .success),
            Host(range: CFRange(location: NSNotFound, length: 0)),
            Host(boundsError: .success, caretBounds: .zero),
            Host(boundsError: .cannotComplete),
            Host(settableError: .cannotComplete),
            Host(rangeError: .cannotComplete),
            Host(role: kAXTextFieldRole),
        ]
        for host in hosts {
            guard case .unavailable(let failure) = host.reader.read(maxCharacters: 500) else {
                Issue.record("inconsistent context must be rejected")
                continue
            }
            #expect(!failure.allowsLocalTracking)
            #expect(!failure.mayReadAncestor)
        }
    }

    @Test func onlyUnreadableWrappersMayFallBackToAncestors() {
        for role in [kAXTextAreaRole, kAXTextFieldRole, kAXGroupRole] {
            let host = Host(rangeError: .attributeUnsupported, role: role)
            guard case .unavailable(let failure) = host.reader.read(maxCharacters: 500) else {
                Issue.record("missing range should be unavailable")
                continue
            }
            #expect(failure.mayReadAncestor == (role == kAXGroupRole))
            #expect(failure.allowsLocalTracking == (role == kAXTextAreaRole))
        }
    }
}
