import Foundation
import Testing
@testable import SnippetsCore

@Suite("Snippet import parser")
struct SnippetImportParserTests {
    @Test func nativeExportRoundTripsWithoutRaycastPrompt() throws {
        let expected = Snippet(
            name: "Résumé",
            keyword: "hello",
            content: "Body",
            tags: ["Work"]
        )
        let data = try JSONEncoder().encode([expected])

        let prepared = try SnippetImportParser.parse(data)

        #expect(prepared.snippets == [expected])
        #expect(prepared.snippetsPreservingExclamationPrefix == [expected])
        #expect(!prepared.hasRaycastExclamationKeywords)
    }

    @Test func raycastPayloadIsDecodedOnceWithBothKeywordChoices() throws {
        let data = Data(#"[{"name":"Signature","keyword":"!sig","text":"Hello {clipboard}"}]"#.utf8)

        let prepared = try SnippetImportParser.parse(data)

        #expect(prepared.hasRaycastExclamationKeywords)
        #expect(prepared.snippets.first?.keyword == "sig")
        #expect(prepared.snippetsPreservingExclamationPrefix.first?.keyword == "!sig")
        #expect(prepared.snippets.first?.content == "Hello {clipboard}")
    }

    @Test func malformedDocumentIsRejectedAndEmptyNativeArrayRemainsAValidParse() throws {
        #expect(throws: SnippetImportParser.Failure.invalidFormat) {
            try SnippetImportParser.parse(Data("not json".utf8))
        }
        #expect(try SnippetImportParser.parse(Data("[]".utf8)).snippets.isEmpty)
    }
}
