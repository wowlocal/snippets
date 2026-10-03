import Foundation
import Testing
@testable import SnippetsCore

/// Server ADR 0006 is normative. These are its published vectors and normalization
/// examples; every Snippets client must agree on them byte for byte.
struct SnippetsCloudAccountKeyTests {
    @Test(arguments: [
        ("00000000000000000000000000", "00000000000000000000000000HF",
         "0000-0000-0000-0000-0000-0000-00HF"),
        ("ZZZZZZZZZZZZZZZZZZZZZZZZZZ", "ZZZZZZZZZZZZZZZZZZZZZZZZZZ8R",
         "ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZ8R"),
        ("7KQF9M2XR4TDH8WBZN3CP6YE1A", "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7",
         "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7"),
        ("0123456789ABCDEFGHJKMNPQRS", "0123456789ABCDEFGHJKMNPQRS45",
         "0123-4567-89AB-CDEF-GHJK-MNPQ-RS45"),
    ])
    func adrVectorsProduceCanonicalAndDisplayForms(body: String, canonical: String, display: String) throws {
        let fromBody = try #require(SnippetsCloudAccountKey(body: body))
        #expect(fromBody.canonical == canonical)
        #expect(fromBody.displayForm == display)
        let parsed = try #require(SnippetsCloudAccountKey(canonical: canonical))
        #expect(parsed == fromBody)
        #expect(SnippetsCloudAccountKey(normalizing: display) == fromBody)
        #expect(SnippetsCloudAccountKey(normalizing: canonical.lowercased()) == fromBody)
    }

    @Test(arguments: [
        " 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-1aq7 ",
        "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-IAQ7",
        "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-LAQ7",
        "7kqf\t9m2x\nr4td\rh8wb\u{0B}zn3c\u{0C}p6ye-1aq7",
    ])
    func adrNormalizationExamplesReachTheSameCanonicalKey(input: String) {
        #expect(SnippetsCloudAccountKey(normalizing: input)?.canonical
            == "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7")
    }

    @Test func letterOIsReadAsZero() {
        #expect(SnippetsCloudAccountKey(normalizing: "OOOO-OOOO-OOOO-OOOO-OOOO-OOOO-OOHF")?.canonical
            == "00000000000000000000000000HF")
    }

    @Test(arguments: [
        "7KQF9M2XR4TDH8WBZN3CP6YE1AQ8",  // failed check
        "7KQF9M2XR4TDH8WBZN3CP6YE1AQU",  // U is never a symbol
        "UKQF9M2XR4TDH8WBZN3CP6YE1AQ7",
        "7KQF9M2XR4TDH8WBZN3CP6YE1AQ",   // too short
        "7KQF9M2XR4TDH8WBZN3CP6YE1AQ70", // too long
        "",
        "7KQF_9M2X_R4TD_H8WB_ZN3C_P6YE_1AQ7",
        "7KQF.9M2X.R4TD.H8WB.ZN3C.P6YE.1AQ7",
        "7KQF—9M2X—R4TD—H8WB—ZN3C—P6YE—1AQ7", // em dashes are not ASCII separators
        "７KQF9M2XR4TDH8WBZN3CP6YE1AQ7",       // full-width digit
        "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7\u{00A0}", // non-ASCII whitespace
    ])
    func invalidInputIsRejectedLocally(input: String) {
        #expect(SnippetsCloudAccountKey(normalizing: input) == nil)
    }

    @Test func inputOverSixtyFourUTF8BytesIsRejectedEvenWhenItWouldNormalize() {
        let valid = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"
        let padded64 = valid + String(repeating: " ", count: 64 - valid.utf8.count)
        #expect(padded64.utf8.count == 64)
        #expect(SnippetsCloudAccountKey(normalizing: padded64)?.canonical == valid)
        #expect(SnippetsCloudAccountKey(normalizing: padded64 + " ") == nil)
        let multibyte = valid + String(repeating: "é", count: 18)
        #expect(multibyte.utf8.count == 64)
        #expect(SnippetsCloudAccountKey(normalizing: multibyte) == nil)
    }

    @Test func canonicalParsingIsStrictAboutTheWireForm() {
        #expect(SnippetsCloudAccountKey(canonical: "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7") != nil)
        #expect(SnippetsCloudAccountKey(canonical: "7kqf9m2xr4tdh8wbzn3cp6ye1aq7") == nil)
        #expect(SnippetsCloudAccountKey(canonical: "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7") == nil)
        #expect(SnippetsCloudAccountKey(canonical: "7KQF9M2XR4TDH8WBZN3CP6YEIAQ7") == nil)
        #expect(SnippetsCloudAccountKey(canonical: "7KQF9M2XR4TDH8WBZN3CP6YE1AQ8") == nil)
        #expect(SnippetsCloudAccountKey(body: "7KQF9M2XR4TDH8WBZN3CP6YE1U") == nil)
        #expect(SnippetsCloudAccountKey(body: "7KQF9M2XR4TDH8WBZN3CP6YE1") == nil)
    }

    @Test func everySingleSymbolSubstitutionInTheVectorIsDetectedOrMapsToAnotherValidKey() throws {
        let key = try #require(SnippetsCloudAccountKey(canonical: "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"))
        let symbols = Array(key.canonical.utf8)
        var accepted = 0
        for index in symbols.indices {
            for replacement in SnippetsCloudAccountKey.alphabet where replacement != symbols[index] {
                var changed = symbols
                changed[index] = replacement
                if SnippetsCloudAccountKey(canonical: String(decoding: changed, as: UTF8.self)) != nil {
                    accepted += 1
                }
            }
        }
        // Ten check bits catch roughly 1023 of 1024 random substitutions.
        #expect(accepted < 10)
    }

    @Test func keyIsRedactedFromDescriptionsAndReflection() throws {
        let key = try #require(SnippetsCloudAccountKey(canonical: "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"))
        var dumped = ""
        dump(key, to: &dumped)
        for text in ["\(key)", String(describing: key), String(reflecting: key), dumped] {
            #expect(!text.contains("7KQF"))
            #expect(!text.contains("1AQ7"))
        }
    }

    @Test func accountIdentifierShowsTheFirstEightUppercaseHexDigits() throws {
        let id = try #require(UUID(uuidString: "e621e1f8-c36c-495a-93fc-0c247a3e6e5f"))
        #expect(SnippetsCloudAccountIdentifier.displayForm(id) == "E621-E1F8")
        let zero = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000000"))
        #expect(SnippetsCloudAccountIdentifier.displayForm(zero) == "0000-0000")
    }
}
