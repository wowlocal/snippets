import Foundation
import Testing

@testable import SnippetsCore

// The merge is the only thing standing between "two writers" and "one writer's work
// is gone". Every test below names the failure it prevents rather than the code path
// it happens to walk.

// MARK: - Fixtures

/// A fixed epoch. `SyncMerge` feeds `updatedAt` into an `HLC`, so a `Date()` anywhere
/// in this file would make the clock branch depend on when the suite ran.
private let epoch = Date(timeIntervalSince1970: 1_785_312_000)

private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

/// Ids laid out so `uuidString` order is `id(0) < id(1) < …`. The merge falls back to
/// that order for exact ties, and a test about the tiebreak has to be able to say
/// which record it expects to lose.
private func id(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index))!
}

/// This device's id. Deliberately *not* all zeroes: `HLC.foreignDevice` is, and a real
/// device must sort above it so an in-app edit wins an exact millisecond tie.
private let thisDevice = "aabbccdd"

private func rec(
    _ index: Int,
    name: String = "Name",
    keyword: String = "",
    content: String = "body",
    tags: [String] = [],
    isEnabled: Bool = true,
    isPinned: Bool = false,
    createdAt: Double = 0,
    updatedAt: Double = 0
) -> Snippet {
    Snippet(
        id: id(index), name: name, keyword: keyword, content: content, tags: tags,
        isEnabled: isEnabled, isPinned: isPinned,
        createdAt: at(createdAt), updatedAt: at(updatedAt))
}

private func merge(
    base: [Snippet] = [], local: [Snippet] = [], remote: [Snippet] = [],
    device: String = thisDevice
) -> SyncMerge.Outcome {
    SyncMerge.mergeLocal(base: base, local: local, remote: remote)
}

extension Array where Element == Snippet {
    fileprivate func record(_ wanted: UUID) -> Snippet? { first { $0.id == wanted } }
    fileprivate var ids: [UUID] { map(\.id) }
    fileprivate var contents: Set<String> { Set(map(\.content)) }
}

// MARK: - Deterministic randomness
//
// The xorshift from `Tests/SnippetFrecencyTests.swift`, so a property failure
// reproduces exactly from the seed printed in the failure message.

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func int(_ upperBound: Int) -> Int {
        upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
    }
}

/// A random base/local/remote triple over a fixed set of ids.
///
/// Content strings are unique per (record, side) on purpose: the "nothing is silently
/// destroyed" property can only be meaningful if two different records cannot
/// accidentally cover for each other.
private struct Scenario {
    var base: [Snippet]
    var local: [Snippet]
    var remote: [Snippet]
}

private func makeScenario(seed: UInt64, recordCount: Int = 5) -> Scenario {
    var random = SeededRandom(seed: seed)
    // A deliberately small keyword pool, including the empty one and a case variant,
    // so the collision pass and the folding rule are both exercised often.
    let keywords = ["", "sig", "addr", "SIG"]

    var base: [Snippet] = []
    var local: [Snippet] = []
    var remote: [Snippet] = []

    for index in 0..<recordCount {
        let ancestor = rec(
            index,
            name: "n\(index)-base",
            keyword: keywords[random.int(keywords.count)],
            content: "c\(index)-base",
            tags: ["t\(index)-base", "shared"],
            createdAt: 0, updatedAt: 0)

        let hasBase = random.int(4) != 0
        if hasBase { base.append(ancestor) }

        for side in ["local", "remote"] {
            // A missing record is the interesting case, not an edge case: it is either
            // a delete or an addition depending entirely on the ancestor.
            guard random.int(6) != 0 else { continue }

            var snippet = ancestor
            if !hasBase || random.int(5) < 2 { snippet.name = "n\(index)-\(side)" }
            if !hasBase || random.int(5) < 2 { snippet.keyword = keywords[random.int(keywords.count)] }
            if !hasBase || random.int(5) < 2 { snippet.content = "c\(index)-\(side)" }
            if random.int(5) < 2 { snippet.tags = ["t\(index)-\(side)", "shared"] }
            if random.int(6) == 0 { snippet.isEnabled.toggle() }
            if random.int(6) == 0 { snippet.isPinned.toggle() }
            snippet.createdAt = at(Double(random.int(10)))
            snippet.updatedAt = at(Double(random.int(1000)))

            if side == "local" { local.append(snippet) } else { remote.append(snippet) }
        }
    }

    return Scenario(base: base, local: local, remote: remote)
}

// MARK: - Suite

@Suite struct SyncMergeTests {

    // MARK: 1. Absence is never a delete

    /// Without an ancestor, absence means "this side has not seen it yet". Treating it
    /// as a deletion is exactly how a fresh install wipes the library it just joined.
    @Test func aRecordAbsentLocallyWithNoAncestorIsAnAdditionRatherThanADeletion() throws {
        let outcome = merge(base: [], local: [], remote: [rec(0, content: "from the other Mac")])

        #expect(outcome.snippets.ids == [id(0)])
        #expect(outcome.snippets.record(id(0))?.content == "from the other Mac")
    }

    @Test func aRecordAbsentRemotelyWithNoAncestorIsAnAdditionRatherThanADeletion() throws {
        let outcome = merge(base: [], local: [rec(0, content: "typed here")], remote: [])

        #expect(outcome.snippets.ids == [id(0)])
        #expect(outcome.snippets.record(id(0))?.content == "typed here")
    }

    /// The other half of the rule: with an ancestor proving we had it and the other
    /// side leaving it untouched, absence *is* a deletion and must stick. Without this
    /// branch a deleted snippet resurrects on every sync.
    @Test func anAncestorThatProvesTheOtherSideLeftItAloneMakesLocalAbsenceADeletion() throws {
        let ancestor = rec(0, content: "doomed")
        let outcome = merge(base: [ancestor], local: [], remote: [ancestor])

        #expect(outcome.snippets.isEmpty)
    }

    @Test func anAncestorThatProvesWeLeftItAloneMakesRemoteAbsenceADeletion() throws {
        let ancestor = rec(0, content: "doomed")
        let outcome = merge(base: [ancestor], local: [ancestor], remote: [])

        #expect(outcome.snippets.isEmpty)
    }

    /// `payloadEquals` excludes `createdAt`/`updatedAt` so that a re-save which only
    /// bumped a timestamp cannot masquerade as an edit and outrank a real deletion.
    @Test func aReSaveThatOnlyMovedUpdatedAtDoesNotOutrankADeliberateDeletion() throws {
        let ancestor = rec(0, content: "doomed", createdAt: 0, updatedAt: 0)
        var touched = ancestor
        touched.updatedAt = at(9_999)
        touched.createdAt = at(1)

        #expect(SyncMerge.payloadEquals(ancestor, touched))
        #expect(merge(base: [ancestor], local: [], remote: [touched]).snippets.isEmpty)
        #expect(merge(base: [ancestor], local: [touched], remote: []).snippets.isEmpty)
    }

    // MARK: 2. Edit beats delete

    /// A deletion the user meant is trivially repeatable; an edit a delete swallowed is
    /// gone forever. So the edit wins — in both directions.
    @Test func editBeatsDeleteWhenTheOtherSideOnlyRemovedIt() throws {
        let ancestor = rec(0, content: "original")
        var edited = ancestor
        edited.content = "the only copy that ever existed"
        edited.updatedAt = at(100)

        let outcome = merge(base: [ancestor], local: [], remote: [edited])

        #expect(outcome.snippets.ids == [id(0)])
        #expect(outcome.snippets.record(id(0))?.content == "the only copy that ever existed")
    }

    @Test func editBeatsDeleteWhenWeEditedItAndTheOtherSideRemovedIt() throws {
        let ancestor = rec(0, content: "original")
        var edited = ancestor
        edited.content = "the only copy that ever existed"
        edited.updatedAt = at(100)

        let outcome = merge(base: [ancestor], local: [edited], remote: [])

        #expect(outcome.snippets.ids == [id(0)])
        #expect(outcome.snippets.record(id(0))?.content == "the only copy that ever existed")
    }

    /// An edit that is *only* a rename still beats a delete: the surviving-edit rule is
    /// about any payload field, not about content alone.
    @Test func aRenameAloneIsEnoughOfAnEditToSurviveADelete() throws {
        let ancestor = rec(0, name: "Old", content: "same")
        var renamed = ancestor
        renamed.name = "New"

        let outcome = merge(base: [ancestor], local: [], remote: [renamed])

        #expect(outcome.snippets.record(id(0))?.name == "New")
    }

    // MARK: 3. Field-level three-way

    /// The case whole-record last-writer-wins loses: rename on one Mac, body edit on
    /// the other. Under record-level LWW one of the two evaporates; here both survive
    /// and no conflict copy is needed, because the two sides touched different fields.
    @Test func aRenameOnOneSideAndABodyEditOnTheOtherBothSurvive() throws {
        let ancestor = rec(0, name: "Old Name", keyword: "sig", content: "old body")

        var renamed = ancestor
        renamed.name = "New Name"
        renamed.updatedAt = at(10)

        var rewritten = ancestor
        rewritten.content = "new body"
        rewritten.updatedAt = at(20)

        let outcome = merge(base: [ancestor], local: [renamed], remote: [rewritten])
        let survivor = try #require(outcome.snippets.record(id(0)))

        #expect(survivor.name == "New Name", "the rename must not be swallowed by the body edit")
        #expect(survivor.content == "new body", "the body edit must not be swallowed by the rename")
        #expect(outcome.conflictCopies.isEmpty, "different fields are not a conflict")
    }

    /// Every scalar field independently, in one merge, to prove the field-level rule is
    /// not special-cased to name-versus-content.
    @Test func everyScalarFieldMergesIndependentlyOfTheOthers() throws {
        let ancestor = rec(
            0, name: "Old", keyword: "old", content: "old body", tags: ["keep"],
            isEnabled: true, isPinned: false)

        var mine = ancestor
        mine.name = "Renamed"
        mine.isPinned = true
        mine.updatedAt = at(10)

        var theirs = ancestor
        theirs.keyword = "new"
        theirs.isEnabled = false
        theirs.updatedAt = at(20)

        let survivor = try #require(merge(base: [ancestor], local: [mine], remote: [theirs])
            .snippets.record(id(0)))

        #expect(survivor.name == "Renamed")
        #expect(survivor.isPinned == true)
        #expect(survivor.keyword == "new")
        #expect(survivor.isEnabled == false)
        #expect(survivor.content == "old body", "neither side touched the body")
    }

    // MARK: 4. No clock is consulted when only one side moved

    /// The whole reason clock skew barely matters: when only one side moved a field
    /// away from base, that side is simply right. Give the *losing* side a wildly newer
    /// `updatedAt` and the one-sided change must still stand.
    @Test func aOneSidedChangeWinsEvenWhenTheOtherSideHasAMuchNewerUpdatedAt() throws {
        let ancestor = rec(0, name: "Old", content: "body", isPinned: false)

        // Local renamed. Remote only toggled a pin — but a day later.
        var mine = ancestor
        mine.name = "New"
        mine.updatedAt = at(0)

        var theirs = ancestor
        theirs.isPinned = true
        theirs.updatedAt = at(86_400)

        let survivor = try #require(merge(base: [ancestor], local: [mine], remote: [theirs])
            .snippets.record(id(0)))
        #expect(survivor.name == "New", "a much newer clock on the other side is irrelevant")
        #expect(survivor.isPinned == true)

        // The mirror image: remote made the one-sided change and we are the newer one.
        var mineNewer = ancestor
        mineNewer.isPinned = true
        mineNewer.updatedAt = at(86_400)

        var theirsOlder = ancestor
        theirsOlder.name = "New"
        theirsOlder.updatedAt = at(0)

        let mirrored = try #require(merge(base: [ancestor], local: [mineNewer], remote: [theirsOlder])
            .snippets.record(id(0)))
        #expect(mirrored.name == "New", "our much newer clock does not entitle us to revert their rename")
        #expect(mirrored.isPinned == true)
    }

    /// `mergeScalar` in isolation — the two middle branches are the ones that must
    /// never look at `localWins`.
    @Test func mergeScalarIgnoresTheClockWheneverExactlyOneSideMovedAwayFromBase() throws {
        // Only remote moved: remote wins under either clock verdict.
        #expect(SyncMerge.mergeScalar("base", "base", "moved", localWins: true) == "moved")
        #expect(SyncMerge.mergeScalar("base", "base", "moved", localWins: false) == "moved")
        // Only local moved.
        #expect(SyncMerge.mergeScalar("base", "moved", "base", localWins: true) == "moved")
        #expect(SyncMerge.mergeScalar("base", "moved", "base", localWins: false) == "moved")
        // Agreement short-circuits before the ancestor is even read.
        #expect(SyncMerge.mergeScalar(nil as String?, "same", "same", localWins: false) == "same")
        // Both moved, or no ancestor to prove who moved: only then does the clock rule.
        #expect(SyncMerge.mergeScalar("base", "mine", "theirs", localWins: true) == "mine")
        #expect(SyncMerge.mergeScalar("base", "mine", "theirs", localWins: false) == "theirs")
        #expect(SyncMerge.mergeScalar(nil as String?, "mine", "theirs", localWins: true) == "mine")
        #expect(SyncMerge.mergeScalar(nil as String?, "mine", "theirs", localWins: false) == "theirs")
    }

    /// The documented tie rule: a foreign write carries `HLC.foreignDevice`, which sorts
    /// below every real device id, so an in-app edit wins an exact millisecond tie.
    ///
    /// This pins the rule as written. Note that it is *asymmetric* by construction —
    /// every device stamps its own record with a real id and the peer's with the
    /// foreign one — so on an exact tie two devices each conclude "I won". That is
    /// correct for app-versus-`vim`, which is what the rule was written for, and it is
    /// the reason the tie case deserves separate scrutiny for device-versus-device.
    @Test func onAnExactTimestampTieTheInAppEditWinsBecauseForeignWritesSortLowest() throws {
        let ancestor = rec(0, name: "Old")
        var mine = ancestor
        mine.name = "Mine"
        var theirs = ancestor
        theirs.name = "Theirs"
        // Same instant on both sides: only the device tiebreak can decide.

        let survivor = try #require(merge(base: [ancestor], local: [mine], remote: [theirs])
            .snippets.record(id(0)))
        #expect(survivor.name == "Mine")
    }

    // MARK: 5. Content conflict copies

    /// Content is the one field that is never discarded: a lost name is retyped in
    /// seconds, a lost body may be the only copy that ever existed.
    @Test func bothSidesChangingContentPreservesTheLoserAsADisabledConflictCopy() throws {
        let ancestor = rec(0, name: "Signature", keyword: "sig", content: "base body", tags: ["work"])

        var mine = ancestor
        mine.content = "my body"
        mine.updatedAt = at(100)

        var theirs = ancestor
        theirs.content = "their body"
        theirs.updatedAt = at(50)

        let outcome = merge(base: [ancestor], local: [mine], remote: [theirs])

        let survivor = try #require(outcome.snippets.record(id(0)))
        #expect(survivor.content == "my body", "the newer side keeps the record")

        #expect(outcome.conflictCopies.count == 1)
        let copy = try #require(outcome.conflictCopies.first)
        #expect(copy.content == "their body", "the losing body is preserved, never overwritten")
        #expect(copy.id != id(0), "the copy is a separate record, not a mutation of the survivor")
        #expect(copy.isEnabled == false, "a conflict copy must never expand")
        #expect(copy.keyword == "", "two live snippets may never share a keyword")
        #expect(copy.isPinned == false)
        #expect(copy.hasTag(withKey: "conflict"), "the copy has to be findable by tag")
        #expect(copy.tags.contains("work"), "the loser's own tags are kept alongside it")
        #expect(copy.name.hasPrefix("Signature (conflict "))
        #expect(outcome.snippets.record(copy.id) != nil, "the copy is part of the merged library")
        #expect(outcome.needsUserAttention)
    }

    /// Mirror image: when the other side is newer, *our* body becomes the copy. The rule
    /// is symmetric, so neither device can lose a body by being slower to sync.
    @Test func theLocalBodyBecomesTheConflictCopyWhenTheOtherSideIsNewer() throws {
        let ancestor = rec(0, content: "base body")

        var mine = ancestor
        mine.content = "my body"
        mine.updatedAt = at(10)

        var theirs = ancestor
        theirs.content = "their body"
        theirs.updatedAt = at(500)

        let outcome = merge(base: [ancestor], local: [mine], remote: [theirs])

        #expect(outcome.snippets.record(id(0))?.content == "their body")
        #expect(outcome.conflictCopies.first?.content == "my body")
    }

    /// One side changing the body while the other leaves it alone is not a conflict —
    /// minting a copy there would bury the user in copies for ordinary edits.
    @Test func aOneSidedBodyEditProducesNoConflictCopy() throws {
        let ancestor = rec(0, content: "base body")

        var theirs = ancestor
        theirs.content = "their body"
        theirs.updatedAt = at(50)

        var mine = ancestor
        mine.name = "Renamed"

        let outcome = merge(base: [ancestor], local: [mine], remote: [theirs])

        #expect(outcome.snippets.record(id(0))?.content == "their body")
        #expect(outcome.conflictCopies.isEmpty)
        #expect(outcome.needsUserAttention == false)
    }

    /// The copy id is a name-based UUIDv5 over the record and the losing body, so both
    /// devices compute the same id independently. With a random id every sync round
    /// would mint another copy — the classic way this feature goes wrong.
    @Test func aConflictCopyIDIsDerivedFromTheRecordAndTheLosingBodyRatherThanBeingRandom() throws {
        let ancestor = rec(0, content: "base body")
        var mine = ancestor
        mine.content = "my body"
        mine.updatedAt = at(100)
        var theirs = ancestor
        theirs.content = "their body"
        theirs.updatedAt = at(50)

        let first = merge(base: [ancestor], local: [mine], remote: [theirs])
        let second = merge(base: [ancestor], local: [mine], remote: [theirs])

        let copyID = try #require(first.conflictCopies.first?.id)
        #expect(second.conflictCopies.first?.id == copyID, "the same inputs give the same copy id")
        #expect(
            copyID == SyncMerge.deterministicUUID(
                namespace: id(0),
                name: "conflict|their body|\(at(50).millisecondsSince1970)"),
            "the recipe is pinned: changing it would orphan every copy already on disk")
        #expect(copyID.uuidString.dropFirst(14).first == "5", "UUIDv5 version nibble")
    }

    /// Conflict copies must not breed. Re-running the merge against a peer that has not
    /// caught up yet has to converge on the very same library.
    @Test func conflictCopiesDoNotBreedWhenTheSameMergeRunsAgain() throws {
        let ancestor = rec(0, name: "Signature", content: "base body")
        var mine = ancestor
        mine.content = "my body"
        mine.updatedAt = at(100)
        var theirs = ancestor
        theirs.content = "their body"
        theirs.updatedAt = at(50)

        let first = merge(base: [ancestor], local: [mine], remote: [theirs])
        // The peer still has its old bytes; we merge again from the result we just
        // produced. This is the round that a random copy id would double.
        let second = merge(base: [ancestor], local: first.snippets, remote: [theirs])
        let third = merge(base: [ancestor], local: second.snippets, remote: [theirs])

        func copyCount(_ outcome: SyncMerge.Outcome) -> Int {
            outcome.snippets.filter { $0.hasTag(withKey: "conflict") }.count
        }

        #expect(copyCount(first) == 1)
        #expect(copyCount(second) == 1, "a second round must not mint a second copy")
        #expect(copyCount(third) == 1, "nor a third")
        #expect(second.snippets == first.snippets, "the merge has reached a fixed point")
        #expect(third.snippets == first.snippets)
    }

    /// A conflict copy is never itself treated as an ancestor of the record it came
    /// from, and it survives untouched through later merges.
    @Test func aConflictCopySurvivesLaterMergesAsAnOrdinaryDisabledRecord() throws {
        let ancestor = rec(0, content: "base body")
        var mine = ancestor
        mine.content = "my body"
        mine.updatedAt = at(100)
        var theirs = ancestor
        theirs.content = "their body"
        theirs.updatedAt = at(50)

        let first = merge(base: [ancestor], local: [mine], remote: [theirs])
        let copy = try #require(first.conflictCopies.first)

        // The peer now pulls our result; nothing further should happen to the copy.
        let settled = merge(base: first.snippets, local: first.snippets, remote: first.snippets)
        #expect(settled.snippets.record(copy.id) == copy)
        #expect(settled.conflictCopies.isEmpty)
        #expect(settled.needsUserAttention == false)
    }

    // MARK: 6. Tags

    @Test func concurrentTagAdditionsOnBothSidesAreUnioned() throws {
        #expect(
            SyncMerge.mergeTags(["work"], ["work", "urgent"], ["work", "draft"], localWins: true)
                == ["work", "draft", "urgent"],
            "new tags are appended in folded-key order so both devices converge on one array")
    }

    /// The ancestor is the causal context an OR-Set would otherwise have to carry per
    /// element: removing needs the tag in base, adding needs it absent, so a remove and
    /// an add can never contend for the same element.
    @Test func aTagRemovedOnOneSideStaysRemovedWhileTheOtherSidesAdditionIsKept() throws {
        #expect(
            SyncMerge.mergeTags(["alpha", "beta"], ["alpha"], ["alpha", "beta", "gamma"], localWins: true)
                == ["alpha", "gamma"])
        // And symmetrically, with the roles swapped.
        #expect(
            SyncMerge.mergeTags(["alpha", "beta"], ["alpha", "beta", "gamma"], ["alpha"], localWins: false)
                == ["alpha", "gamma"])
    }

    /// Survivors keep the user's hand-ordering from the ancestor; only new tags are
    /// sorted. Re-sorting everything would silently reorder every tag list in the app.
    @Test func survivingTagsKeepTheirOrderFromTheAncestor() throws {
        #expect(
            SyncMerge.mergeTags(
                ["zulu", "alpha", "mike"],
                ["zulu", "alpha", "mike"],
                ["zulu", "alpha", "mike", "new"],
                localWins: true)
                == ["zulu", "alpha", "mike", "new"])
    }

    /// Tag identity is `SnippetTagging.filterKey`, so adding "Work" when the ancestor
    /// already has "work" is not an addition — otherwise every capitalisation
    /// difference between two Macs would double the tag list.
    @Test func aTagDifferingOnlyInCaseOrDiacriticsIsNotANewTag() throws {
        // Identity is the folded key, so this is one tag, not two — but the SPELLING
        // that survives is the winning side's, not the ancestor's. Re-emitting the
        // ancestor's string would silently revert a capitalisation both devices
        // deliberately changed, which is exactly what the per-field rule forbids.
        let cased = SyncMerge.mergeTags(["work"], ["Work", "extra"], ["work"], localWins: true)
        #expect(cased == ["Work", "extra"], "the winning side's casing survives, not the ancestor's")

        let folded = SyncMerge.mergeTags(["café"], ["Cafe"], ["café", "x"], localWins: true)
        #expect(folded == ["Cafe", "x"])

        // …and the loser's spelling is the one that loses.
        let loserCasing = SyncMerge.mergeTags(["work"], ["Work"], ["WORK"], localWins: false)
        #expect(loserCasing == ["WORK"])

        // The same rule end to end, not just in the helper.
        let ancestor = rec(0, tags: ["work"])
        var mine = ancestor
        mine.tags = ["Work", "urgent"]
        mine.updatedAt = at(10)
        var theirs = ancestor
        theirs.tags = ["work", "draft"]
        theirs.updatedAt = at(20)

        let survivor = try #require(merge(base: [ancestor], local: [mine], remote: [theirs])
            .snippets.record(id(0)))
        #expect(survivor.tags == ["work", "draft", "urgent"])
    }

    /// With no ancestor there is nothing to prove a removal, so tags can only union.
    /// Dropping one here would delete a tag a device simply had not seen yet.
    @Test func withNoAncestorTagsCanOnlyBeUnioned() throws {
        #expect(SyncMerge.mergeTags(nil, ["a"], ["b"], localWins: true) == ["a", "b"])
        #expect(SyncMerge.mergeTags(nil, [], ["b"], localWins: false) == ["b"])
    }

    @Test func aTagRemovedOnBothSidesIsGone() throws {
        #expect(SyncMerge.mergeTags(["a", "b"], ["a"], ["a"], localWins: true) == ["a"])
    }

    // MARK: 7. Keyword collisions

    /// A merge can produce two live snippets sharing a keyword even though neither
    /// device ever saw a collision. The merge cannot reject a record, so it disables
    /// the loser — and deliberately does **not** clear the keyword, which would destroy
    /// what the user typed.
    @Test func aMergeThatLeavesTwoLiveSnippetsSharingAKeywordDisablesExactlyOne() throws {
        let mine = rec(0, name: "Mine", keyword: "sig", content: "a", updatedAt: 100)
        let theirs = rec(1, name: "Theirs", keyword: "SIG", content: "b", updatedAt: 50)

        let outcome = merge(base: [], local: [mine], remote: [theirs])

        #expect(outcome.snippets.count == 2, "neither record is dropped")
        #expect(outcome.disabledByKeywordCollision == [id(1)], "the older one loses")
        #expect(outcome.snippets.record(id(0))?.isEnabled == true)
        #expect(outcome.snippets.record(id(1))?.isEnabled == false)
        #expect(
            outcome.snippets.record(id(1))?.keyword == "SIG",
            "the keyword text is never cleared; the editor's warning is what surfaces this")
        #expect(outcome.needsUserAttention)
    }

    /// An exact `updatedAt` tie falls back to id order, so two devices resolving the
    /// same collision independently disable the same record.
    @Test func onAnExactTieTheKeywordCollisionLoserIsTheSameRegardlessOfInputOrder() throws {
        let low = rec(0, keyword: "sig", content: "a", updatedAt: 42)
        let high = rec(1, keyword: "sig", content: "b", updatedAt: 42)

        let oneWay = merge(base: [], local: [high], remote: [low])
        let otherWay = merge(base: [], local: [low], remote: [high])

        #expect(oneWay.disabledByKeywordCollision == [id(1)])
        #expect(otherWay.disabledByKeywordCollision == [id(1)],
                "the tiebreak is a property of the records, not of who merged first")
        #expect(oneWay.snippets.record(id(0))?.isEnabled == true)
        #expect(otherWay.snippets.record(id(0))?.isEnabled == true)
    }

    /// Only *live* snippets contest a keyword. A disabled duplicate is already harmless,
    /// and disabling the enabled one instead would break expansion for no reason.
    @Test func aDisabledSnippetNeverContestsAKeyword() throws {
        let live = rec(0, keyword: "sig", content: "a", updatedAt: 10)
        let dormant = rec(1, keyword: "sig", content: "b", isEnabled: false, updatedAt: 900)

        let outcome = merge(base: [], local: [live], remote: [dormant])

        #expect(outcome.disabledByKeywordCollision.isEmpty)
        #expect(outcome.snippets.record(id(0))?.isEnabled == true)
    }

    /// An empty keyword is not a collision — most snippets have none.
    @Test func snippetsWithoutKeywordsNeverCollide() throws {
        let outcome = merge(
            base: [], local: [rec(0, keyword: "  ", content: "a")], remote: [rec(1, keyword: "", content: "b")])

        #expect(outcome.disabledByKeywordCollision.isEmpty)
        #expect(outcome.snippets.allSatisfy { $0.isEnabled })
    }

    /// Three-way collisions collapse to exactly one survivor, not to zero.
    @Test func threeSnippetsSharingAKeywordLeaveExactlyOneEnabled() throws {
        var snippets = [
            rec(0, keyword: "sig", content: "a", updatedAt: 10),
            rec(1, keyword: "Sig", content: "b", updatedAt: 900),
            rec(2, keyword: "SIG", content: "c", updatedAt: 20),
        ]
        let disabled = SyncMerge.resolveKeywordCollisions(&snippets)

        #expect(snippets.filter(\.isEnabled).ids == [id(1)], "the newest keeps the keyword")
        #expect(Set(disabled) == [id(0), id(2)])
    }

    // MARK: 8. Timestamps

    /// `updatedAt` feeds `enabledSnippetsSorted`, so a merge that lowered it would
    /// silently reshuffle which snippet wins an ambiguous keyword prefix. And a
    /// `createdAt` that moved forward would rewrite the record's history.
    @Test func createdAtNeverMovesForwardAndUpdatedAtNeverMovesBackward() throws {
        // Identical payloads: the timestamps still get reconciled.
        let mine = rec(0, content: "same", createdAt: 50, updatedAt: 50)
        let theirs = rec(0, content: "same", createdAt: 10, updatedAt: 900)
        let agreed = try #require(merge(base: [], local: [mine], remote: [theirs]).snippets.record(id(0)))
        #expect(agreed.createdAt == at(10))
        #expect(agreed.updatedAt == at(900))

        // Differing payloads take the other path and must obey the same rule.
        let ancestor = rec(0, name: "Old", content: "body", createdAt: 0, updatedAt: 0)
        var edited = ancestor
        edited.name = "New"
        edited.createdAt = at(100)
        edited.updatedAt = at(100)
        var otherEdited = ancestor
        otherEdited.isPinned = true
        otherEdited.createdAt = at(20)
        otherEdited.updatedAt = at(300)

        let merged = try #require(merge(base: [ancestor], local: [edited], remote: [otherEdited])
            .snippets.record(id(0)))
        #expect(merged.createdAt == at(20))
        #expect(merged.updatedAt == at(300))
    }

    // MARK: 9. Properties over random triples

    /// Merging the result again must be a no-op. If it is not, two devices exchanging
    /// the same library forever would rewrite `snippets.json` forever — every write
    /// firing the folder monitor on the other device, which writes back.
    @Test func mergingTheResultAgainChangesNothing() throws {
        for seed in UInt64(1)...300 {
            let scenario = makeScenario(seed: seed)
            let first = merge(base: scenario.base, local: scenario.local, remote: scenario.remote)
            let again = merge(base: first.snippets, local: first.snippets, remote: first.snippets)

            #expect(again.snippets == first.snippets, "seed \(seed) is not a fixed point")
            #expect(again.conflictCopies.isEmpty, "seed \(seed) minted a copy on the second pass")
            #expect(again.disabledByKeywordCollision.isEmpty, "seed \(seed) re-resolved a collision")
            #expect(again.needsUserAttention == false, "seed \(seed) reported a change it did not make")
        }
    }

    /// Same inputs, same output — ids, order, and every field. A merge that depended on
    /// `Set` iteration would pass locally and reshuffle the user's list in production.
    @Test func theSameInputsAlwaysProduceTheSameOutput() throws {
        for seed in UInt64(1)...300 {
            let scenario = makeScenario(seed: seed)
            let first = merge(base: scenario.base, local: scenario.local, remote: scenario.remote)
            let second = merge(base: scenario.base, local: scenario.local, remote: scenario.remote)

            #expect(first.snippets == second.snippets, "seed \(seed) is not deterministic")
            #expect(first.snippets.ids == second.snippets.ids, "seed \(seed) reordered itself")
            #expect(first.disabledByKeywordCollision == second.disabledByKeywordCollision)

            // Compared as a *set*, not as an array, and that is a statement about the
            // source rather than about this fixture. `orderedResult` sorts the copies
            // into `snippets`, so the library that reaches disk is stable — asserted
            // above. `Outcome.conflictCopies` is appended inside the `for id in Set(…)`
            // loop instead, so two identical merges in one process can hand that array
            // back in different orders. Anything that ever iterates it (a receipt, a
            // digest, a UI list) inherits that nondeterminism.
            #expect(Set(first.conflictCopies.ids) == Set(second.conflictCopies.ids),
                    "seed \(seed) minted a different copy id")
        }
    }

    /// The one guarantee the whole feature exists for: a body that either side changed
    /// is somewhere in the output — as the survivor or as a conflict copy. A body that
    /// equals the ancestor's is exempt, because dropping it is what "the other side
    /// edited it" or "the other side deleted it" *means*.
    @Test func noBodyThatEitherSideChangedIsEverSilentlyDestroyed() throws {
        for seed in UInt64(1)...300 {
            let scenario = makeScenario(seed: seed)
            let outcome = merge(base: scenario.base, local: scenario.local, remote: scenario.remote)
            let produced = outcome.snippets.contents

            for side in [scenario.local, scenario.remote] {
                for snippet in side {
                    let ancestor = scenario.base.record(snippet.id)
                    guard ancestor == nil || ancestor?.content != snippet.content else { continue }
                    #expect(produced.contains(snippet.content),
                            "seed \(seed) destroyed \(snippet.content)")
                }
            }
        }
    }

    /// Invariants that must hold for every merged library, whatever went into it.
    @Test func everyMergedLibrarySatisfiesTheStructuralInvariants() throws {
        for seed in UInt64(1)...300 {
            let scenario = makeScenario(seed: seed)
            let outcome = merge(base: scenario.base, local: scenario.local, remote: scenario.remote)

            #expect(Set(outcome.snippets.ids).count == outcome.snippets.count,
                    "seed \(seed) produced a duplicate id")

            // The merge must not INTRODUCE a live keyword collision. It deliberately
            // does not resolve one that already existed: the app has always merely
            // warned about duplicate keywords, and a merge silently disabling a
            // snippet the user has been living with for months would be a nasty
            // surprise arriving from an unrelated background write.
            func liveCollisions(_ snippets: [Snippet]) -> Set<String> {
                var seen = Set<String>(), duplicated = Set<String>()
                for snippet in snippets where snippet.isEnabled {
                    let key = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
                    guard !key.isEmpty else { continue }
                    if !seen.insert(key).inserted { duplicated.insert(key) }
                }
                return duplicated
            }
            let preExisting = liveCollisions(scenario.local).union(liveCollisions(scenario.remote))
            #expect(liveCollisions(outcome.snippets).subtracting(preExisting).isEmpty,
                    "seed \(seed) introduced a keyword collision that neither side had")

            for snippet in outcome.snippets {
                let keys = snippet.tags.map { SnippetTagging.filterKey(for: $0) }
                #expect(Set(keys).count == keys.count, "seed \(seed) produced duplicate tags")

                // Timestamps, for the records both sides had.
                if let mine = scenario.local.record(snippet.id),
                   let theirs = scenario.remote.record(snippet.id) {
                    #expect(snippet.createdAt == min(mine.createdAt, theirs.createdAt),
                            "seed \(seed) moved createdAt forward")
                    #expect(snippet.updatedAt == max(mine.updatedAt, theirs.updatedAt),
                            "seed \(seed) moved updatedAt backward")
                }
            }

            // Every conflict copy is inert and tagged.
            for copy in outcome.conflictCopies {
                #expect(copy.isEnabled == false)
                #expect(copy.keyword.isEmpty)
                #expect(copy.hasTag(withKey: "conflict"))
                #expect(outcome.snippets.record(copy.id) != nil)
            }
        }
    }

    /// A merge may only ever drop a record the ancestor proves was deleted. Anything
    /// else vanishing is data loss, however it got there.
    @Test func aRecordOnlyDisappearsWhenTheAncestorProvesItWasDeleted() throws {
        for seed in UInt64(1)...300 {
            let scenario = makeScenario(seed: seed)
            let outcome = merge(base: scenario.base, local: scenario.local, remote: scenario.remote)
            let survived = Set(outcome.snippets.ids)

            for snippet in scenario.local + scenario.remote where !survived.contains(snippet.id) {
                let ancestor = try #require(scenario.base.record(snippet.id),
                                            "seed \(seed) dropped \(snippet.id) with no ancestor")
                #expect(SyncMerge.payloadEquals(ancestor, snippet),
                        "seed \(seed) dropped an edited record")
                let heldByBothSides = scenario.local.record(snippet.id) != nil
                    && scenario.remote.record(snippet.id) != nil
                #expect(!heldByBothSides, "seed \(seed) dropped a record both sides still had")
            }
        }
    }

    // MARK: 10. Output ordering

    /// The stated order: survivors in local order, then records only the other side
    /// had, then conflict copies by id. Without it the merged array would follow `Set`
    /// iteration — randomly seeded per process — and the user's list would reshuffle
    /// itself on every sync.
    @Test func theOutputIsOrderedLocalFirstThenRemoteOnlyThenConflictCopies() throws {
        let ancestor = rec(0, content: "base body")
        var mine = ancestor
        mine.content = "my body"
        mine.updatedAt = at(100)
        var theirs = ancestor
        theirs.content = "their body"
        theirs.updatedAt = at(50)

        let shared = rec(1, content: "shared")
        let localOnly = rec(2, content: "local only")
        let remoteOnly = rec(3, content: "remote only")

        let outcome = merge(
            base: [ancestor, shared],
            local: [mine, shared, localOnly],
            remote: [theirs, shared, remoteOnly])

        let copyID = try #require(outcome.conflictCopies.first?.id)
        #expect(outcome.snippets.ids == [id(0), id(1), id(2), id(3), copyID])
    }

    /// `Set` iteration order is seeded once per process, so a within-process repeat is a
    /// weak check on its own — it is paired with the exact-order assertion above, which
    /// pins the answer rather than merely pinning it to itself.
    @Test func theSameMergeRepeatedInOneProcessAlwaysYieldsTheIdenticalIDOrdering() throws {
        let scenario = makeScenario(seed: 0xC0FFEE, recordCount: 24)
        let reference = merge(base: scenario.base, local: scenario.local, remote: scenario.remote)
            .snippets.ids
        #expect(reference.count > 8, "the fixture has to be big enough for hashing order to matter")

        for _ in 0..<200 {
            let repeated = merge(base: scenario.base, local: scenario.local, remote: scenario.remote)
            #expect(repeated.snippets.ids == reference)
        }
    }

    /// Records only the remote had keep the remote's own order, so a peer's list does
    /// not arrive scrambled.
    @Test func remoteOnlyRecordsArriveInTheRemotesOwnOrder() throws {
        let outcome = merge(
            base: [], local: [],
            remote: [rec(3, content: "c"), rec(1, content: "a"), rec(2, content: "b")])

        #expect(outcome.snippets.ids == [id(3), id(1), id(2)])
    }
}

// MARK: - Cross-device convergence
//
// These tests exist because of a bug that all 88 earlier tests missed. The first
// implementation broke exact `updatedAt` ties by stamping the local record with this
// device's id and the remote one with `HLC.foreignDevice`, then comparing. That is
// asymmetric: run it on device A and A wins; run the mirrored inputs on device B and
// B wins. Both write their own version, each sees the other's, and they rewrite the
// file at each other forever — burning quota and never converging.
//
// The general shape of the trap is that a merge is only correct if BOTH sides compute
// the SAME answer from mirrored inputs. Every test here checks that property rather
// than checking any particular winner, so it stays honest if the tiebreak rule
// changes again.
@Suite("Cross-device convergence")
struct SyncMergeConvergenceTests {

    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"

    private static func snippet(
        _ id: UUID, name: String = "n", keyword: String = "k",
        content: String = "c", tags: [String] = [], updatedAt: Double
    ) -> Snippet {
        Snippet(id: id, name: name, keyword: keyword, content: content, tags: tags,
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: updatedAt))
    }

    /// Mirrored inputs must produce the same library on both machines.
    private static func assertConverges(
        base: [Snippet], onA: [Snippet], onB: [Snippet],
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let a = SyncMerge.mergeLocal(base: base, local: onA, remote: onB)
        let b = SyncMerge.mergeLocal(base: base, local: onB, remote: onA)

        // Stored array order remains local and may legitimately differ; the UI applies
        // `SnippetDisplayOrder`. Identity and field content are what must converge here.
        let byID = { (s: [Snippet]) in Dictionary(uniqueKeysWithValues: s.map { ($0.id, $0) }) }
        #expect(byID(a.snippets) == byID(b.snippets), "\(what): devices disagree",
                sourceLocation: sourceLocation)

        // And the result must be a fixed point: feeding each device the other's
        // now-identical output must change nothing, or the next round writes again.
        let again = SyncMerge.mergeLocal(
            base: a.snippets, local: a.snippets, remote: b.snippets)
        #expect(byID(again.snippets) == byID(a.snippets), "\(what): not a fixed point",
                sourceLocation: sourceLocation)
    }

    /// The exact case the original tiebreak got wrong.
    @Test func twoDevicesAgreeWhenTheSameFieldChangedInTheSameMillisecond() {
        let id = UUID()
        let base = [Self.snippet(id, name: "original", updatedAt: 100)]
        let onA = [Self.snippet(id, name: "renamed on A", updatedAt: 200)]
        let onB = [Self.snippet(id, name: "renamed on B", updatedAt: 200)]
        Self.assertConverges(base: base, onA: onA, onB: onB, "simultaneous rename")
    }

    @Test func twoDevicesAgreeOnASimultaneousContentConflict() {
        let id = UUID()
        let base = [Self.snippet(id, content: "original", updatedAt: 100)]
        let onA = [Self.snippet(id, content: "A's body", updatedAt: 200)]
        let onB = [Self.snippet(id, content: "B's body", updatedAt: 200)]
        Self.assertConverges(base: base, onA: onA, onB: onB, "simultaneous content edit")

        // Both sides must also mint the SAME conflict copy, or the copies breed.
        let a = SyncMerge.mergeLocal(base: base, local: onA, remote: onB)
        let b = SyncMerge.mergeLocal(base: base, local: onB, remote: onA)
        #expect(a.conflictCopies.map(\.id) == b.conflictCopies.map(\.id))
        #expect(a.conflictCopies.count == 1)
        // …and agree on its name, which a locale-local DateFormatter would break.
        #expect(a.conflictCopies.first?.name == b.conflictCopies.first?.name)
    }

    @Test func twoDevicesAgreeOnSimultaneousTagEdits() {
        let id = UUID()
        let base = [Self.snippet(id, tags: ["work"], updatedAt: 100)]
        let onA = [Self.snippet(id, tags: ["work", "urgent"], updatedAt: 200)]
        let onB = [Self.snippet(id, tags: ["work", "draft"], updatedAt: 200)]
        Self.assertConverges(base: base, onA: onA, onB: onB, "simultaneous tag add")
    }

    @Test func twoDevicesAgreeWithNoCommonAncestor() {
        let id = UUID()
        let onA = [Self.snippet(id, name: "A", content: "a", updatedAt: 200)]
        let onB = [Self.snippet(id, name: "B", content: "b", updatedAt: 200)]
        Self.assertConverges(base: [], onA: onA, onB: onB, "no ancestor, same instant")
    }

    @Test func twoDevicesAgreeOnASimultaneousKeywordCollision() {
        // Different records, same keyword, same instant: exactly one must end up
        // disabled, and both devices must disable the same one.
        let a = Self.snippet(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                             keyword: "dup", content: "a", updatedAt: 200)
        let b = Self.snippet(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                             keyword: "dup", content: "b", updatedAt: 200)
        Self.assertConverges(base: [], onA: [a], onB: [b], "simultaneous keyword collision")

        let merged = SyncMerge.mergeLocal(base: [], local: [a], remote: [b])
        #expect(merged.snippets.filter(\.isEnabled).count == 1)
        #expect(merged.disabledByKeywordCollision.count == 1)
    }

    /// The property, over many randomized mirrored pairs rather than hand-picked ones.
    @Test func mirroredMergesConvergeOverRandomHistories() {
        var random = MergeRandom(seed: 0x5EED_C0DE)
        let ids = (0..<6).map { _ in UUID() }

        for iteration in 0..<400 {
            func mutate(_ source: [Snippet], salt: String) -> [Snippet] {
                var out: [Snippet] = []
                for s in source {
                    switch random.int(5) {
                    case 0: continue                                     // deleted here
                    case 1: out.append(Self.snippet(s.id, name: "name-\(salt)",
                                                    keyword: s.keyword, content: s.content,
                                                    updatedAt: 200))
                    case 2: out.append(Self.snippet(s.id, name: s.name, keyword: s.keyword,
                                                    content: "body-\(salt)", updatedAt: 200))
                    case 3: out.append(Self.snippet(s.id, name: s.name, keyword: s.keyword,
                                                    content: s.content, tags: ["t-\(salt)"],
                                                    updatedAt: 200))
                    default: out.append(s)
                    }
                }
                return out
            }

            let base = ids.prefix(random.int(ids.count) + 1).map {
                Self.snippet($0, name: "n-\($0.uuidString.prefix(4))",
                             keyword: "k\($0.uuidString.prefix(4))", updatedAt: 100)
            }
            // Every mutation lands on the same `updatedAt`, so the tiebreak is
            // exercised on essentially every record rather than occasionally.
            Self.assertConverges(base: base,
                                 onA: mutate(base, salt: "A"),
                                 onB: mutate(base, salt: "B"),
                                 "randomized history #\(iteration)")
        }
    }
}

/// Deterministic xorshift, so a failure above reproduces exactly.
private struct MergeRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func int(_ upperBound: Int) -> Int {
        upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
    }
}
