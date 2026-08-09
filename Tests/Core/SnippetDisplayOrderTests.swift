import Foundation
import Testing

@testable import SnippetsCore

private func displayOrderID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func displayOrderSnippet(
    _ id: Int,
    name: String,
    createdAt: Double,
    updatedAt: Double? = nil,
    isPinned: Bool = false
) -> Snippet {
    Snippet(
        id: displayOrderID(id),
        name: name,
        keyword: "k\(id)",
        content: "body",
        isPinned: isPinned,
        createdAt: Date(timeIntervalSince1970: createdAt),
        updatedAt: Date(timeIntervalSince1970: updatedAt ?? createdAt)
    )
}

@Suite("Canonical snippet display order")
struct SnippetDisplayOrderTests {
    @Test func pinnedThenNewestThenID() {
        let oldPinned = displayOrderSnippet(
            4, name: "A old pin", createdAt: 100, isPinned: true)
        let tiedPinnedHigherID = displayOrderSnippet(
            2, name: "A ignored", createdAt: 200, isPinned: true)
        let tiedPinnedLowerID = displayOrderSnippet(
            1, name: "Z ignored", createdAt: 200, isPinned: true)
        let newest = displayOrderSnippet(6, name: "Newest", createdAt: 400)
        let older = displayOrderSnippet(5, name: "Older", createdAt: 300)

        let result = SnippetDisplayOrder.sorted([
            older, tiedPinnedHigherID, newest, oldPinned, tiedPinnedLowerID,
        ])

        #expect(result.map(\.id) == [
            tiedPinnedLowerID.id,
            tiedPinnedHigherID.id,
            oldPinned.id,
            newest.id,
            older.id,
        ])
    }

    @Test func inputAndTransportOrderCannotAffectPresentation() {
        let records = [
            displayOrderSnippet(1, name: "one", createdAt: 100),
            displayOrderSnippet(2, name: "two", createdAt: 300),
            displayOrderSnippet(3, name: "three", createdAt: 200, isPinned: true),
            displayOrderSnippet(4, name: "four", createdAt: 400, isPinned: true),
        ]
        let expected = SnippetDisplayOrder.sorted(records).map(\.id)
        let permutations = [
            records,
            Array(records.reversed()),
            [records[2], records[0], records[3], records[1]],
            [records[1], records[3], records[0], records[2]],
        ]

        for input in permutations {
            #expect(SnippetDisplayOrder.sorted(input).map(\.id) == expected)
        }
    }

    @Test func editsDoNotMoveRowsWithinASection() {
        let createdLater = displayOrderSnippet(
            1, name: "Created later", createdAt: 200, updatedAt: 201)
        let editedMuchLater = displayOrderSnippet(
            2, name: "Edited much later", createdAt: 100, updatedAt: 10_000)

        #expect(
            SnippetDisplayOrder.sorted([editedMuchLater, createdLater]).map(\.id)
                == [createdLater.id, editedMuchLater.id]
        )
    }

    @Test func comparatorIsIrreflexive() {
        let snippet = displayOrderSnippet(1, name: "same", createdAt: 100)
        #expect(!SnippetDisplayOrder.ranks(snippet, before: snippet))
    }
}
