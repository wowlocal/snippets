package com.khm.snippets.core.merge

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import org.junit.Test
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `Tests/Core/SyncMergeTests.swift`, all 45 cases under their Swift names (the 40 of
 * `SyncMergeTests` and the 5 of `SyncMergeConvergenceTests`), and the local-merge cases
 * of `ReviewRegressionTests.swift`. Fixtures follow the Swift file: a fixed epoch, ids
 * laid out in `uuidString` order, the same xorshift scenarios.
 */
class LocalMergeTest {

    private fun id(index: Int): UUID = MergeFixtures.id(index)

    private fun at(seconds: Double): Double = MergeFixtures.at(seconds)

    private fun rec(
        index: Int,
        name: String = "Name",
        keyword: String = "",
        content: String = "body",
        tags: List<String> = emptyList(),
        isEnabled: Boolean = true,
        isPinned: Boolean = false,
        createdAt: Double = 0.0,
        updatedAt: Double = 0.0,
    ): Snippet = Snippet(
        id = id(index), name = name, keyword = keyword, content = content, tags = tags,
        isEnabled = isEnabled, isPinned = isPinned, createdAt = at(createdAt), updatedAt = at(updatedAt),
    )

    private fun merge(
        base: List<Snippet> = emptyList(),
        local: List<Snippet> = emptyList(),
        remote: List<Snippet> = emptyList(),
    ): LocalMerge.Outcome = LocalMerge.mergeLocal(base, local, remote)

    private fun List<Snippet>.record(wanted: UUID): Snippet? = firstOrNull { it.id == wanted }
    private val List<Snippet>.ids: List<UUID> get() = map { it.id }
    private val List<Snippet>.contents: Set<String> get() = map { it.content }.toSet()

    // `SeededRandom` and `makeScenario` of the Swift file, draw for draw.

    private class Scenario(val base: List<Snippet>, val local: List<Snippet>, val remote: List<Snippet>)

    private fun makeScenario(seed: Long, recordCount: Int = 5): Scenario {
        val random = MergeRandom(seed)
        val keywords = listOf("", "sig", "addr", "SIG")
        val base = ArrayList<Snippet>()
        val local = ArrayList<Snippet>()
        val remote = ArrayList<Snippet>()
        for (index in 0 until recordCount) {
            val ancestor = rec(
                index, name = "n$index-base", keyword = keywords[random.int(keywords.size)],
                content = "c$index-base", tags = listOf("t$index-base", "shared"), createdAt = 0.0, updatedAt = 0.0,
            )
            val hasBase = random.int(4) != 0
            if (hasBase) base.add(ancestor)
            for (side in listOf("local", "remote")) {
                if (random.int(6) == 0) continue
                var snippet = ancestor
                if (!hasBase || random.int(5) < 2) snippet = snippet.copy(name = "n$index-$side")
                if (!hasBase || random.int(5) < 2) snippet = snippet.copy(keyword = keywords[random.int(keywords.size)])
                if (!hasBase || random.int(5) < 2) snippet = snippet.copy(content = "c$index-$side")
                if (random.int(5) < 2) snippet = snippet.copy(tags = listOf("t$index-$side", "shared"))
                if (random.int(6) == 0) snippet = snippet.copy(isEnabled = !snippet.isEnabled)
                if (random.int(6) == 0) snippet = snippet.copy(isPinned = !snippet.isPinned)
                snippet = snippet.copy(createdAt = at(random.int(10).toDouble()), updatedAt = at(random.int(1000).toDouble()))
                if (side == "local") local.add(snippet) else remote.add(snippet)
            }
        }
        return Scenario(base, local, remote)
    }

    // 1. Absence is never a delete

    @Test fun aRecordAbsentLocallyWithNoAncestorIsAnAdditionRatherThanADeletion() {
        val outcome = merge(remote = listOf(rec(0, content = "from the other Mac")))
        assertEquals(listOf(id(0)), outcome.snippets.ids)
        assertEquals("from the other Mac", outcome.snippets.record(id(0))?.content)
    }

    @Test fun aRecordAbsentRemotelyWithNoAncestorIsAnAdditionRatherThanADeletion() {
        val outcome = merge(local = listOf(rec(0, content = "typed here")))
        assertEquals(listOf(id(0)), outcome.snippets.ids)
        assertEquals("typed here", outcome.snippets.record(id(0))?.content)
    }

    @Test fun anAncestorThatProvesTheOtherSideLeftItAloneMakesLocalAbsenceADeletion() {
        val ancestor = rec(0, content = "doomed")
        assertTrue(merge(base = listOf(ancestor), remote = listOf(ancestor)).snippets.isEmpty())
    }

    @Test fun anAncestorThatProvesWeLeftItAloneMakesRemoteAbsenceADeletion() {
        val ancestor = rec(0, content = "doomed")
        assertTrue(merge(base = listOf(ancestor), local = listOf(ancestor)).snippets.isEmpty())
    }

    @Test fun aReSaveThatOnlyMovedUpdatedAtDoesNotOutrankADeliberateDeletion() {
        val ancestor = rec(0, content = "doomed", createdAt = 0.0, updatedAt = 0.0)
        val touched = ancestor.copy(updatedAt = at(9_999.0), createdAt = at(1.0))
        assertTrue(LocalMerge.payloadEquals(ancestor, touched))
        assertTrue(merge(base = listOf(ancestor), remote = listOf(touched)).snippets.isEmpty())
        assertTrue(merge(base = listOf(ancestor), local = listOf(touched)).snippets.isEmpty())
    }

    // 2. Edit beats delete

    @Test fun editBeatsDeleteWhenTheOtherSideOnlyRemovedIt() {
        val ancestor = rec(0, content = "original")
        val edited = ancestor.copy(content = "the only copy that ever existed", updatedAt = at(100.0))
        val outcome = merge(base = listOf(ancestor), remote = listOf(edited))
        assertEquals(listOf(id(0)), outcome.snippets.ids)
        assertEquals("the only copy that ever existed", outcome.snippets.record(id(0))?.content)
    }

    @Test fun editBeatsDeleteWhenWeEditedItAndTheOtherSideRemovedIt() {
        val ancestor = rec(0, content = "original")
        val edited = ancestor.copy(content = "the only copy that ever existed", updatedAt = at(100.0))
        val outcome = merge(base = listOf(ancestor), local = listOf(edited))
        assertEquals(listOf(id(0)), outcome.snippets.ids)
        assertEquals("the only copy that ever existed", outcome.snippets.record(id(0))?.content)
    }

    @Test fun aRenameAloneIsEnoughOfAnEditToSurviveADelete() {
        val ancestor = rec(0, name = "Old", content = "same")
        val outcome = merge(base = listOf(ancestor), remote = listOf(ancestor.copy(name = "New")))
        assertEquals("New", outcome.snippets.record(id(0))?.name)
    }

    // 3. Field-level three-way

    @Test fun aRenameOnOneSideAndABodyEditOnTheOtherBothSurvive() {
        val ancestor = rec(0, name = "Old Name", keyword = "sig", content = "old body")
        val renamed = ancestor.copy(name = "New Name", updatedAt = at(10.0))
        val rewritten = ancestor.copy(content = "new body", updatedAt = at(20.0))
        val outcome = merge(base = listOf(ancestor), local = listOf(renamed), remote = listOf(rewritten))
        val survivor = assertNotNull(outcome.snippets.record(id(0)))
        assertEquals("New Name", survivor.name, "the rename must not be swallowed by the body edit")
        assertEquals("new body", survivor.content, "the body edit must not be swallowed by the rename")
        assertTrue(outcome.conflictCopies.isEmpty(), "different fields are not a conflict")
    }

    @Test fun everyScalarFieldMergesIndependentlyOfTheOthers() {
        val ancestor = rec(0, name = "Old", keyword = "old", content = "old body", tags = listOf("keep"))
        val mine = ancestor.copy(name = "Renamed", isPinned = true, updatedAt = at(10.0))
        val theirs = ancestor.copy(keyword = "new", isEnabled = false, updatedAt = at(20.0))
        val survivor = assertNotNull(merge(listOf(ancestor), listOf(mine), listOf(theirs)).snippets.record(id(0)))
        assertEquals("Renamed", survivor.name)
        assertTrue(survivor.isPinned)
        assertEquals("new", survivor.keyword)
        assertFalse(survivor.isEnabled)
        assertEquals("old body", survivor.content, "neither side touched the body")
    }

    // 4. No clock is consulted when only one side moved

    @Test fun aOneSidedChangeWinsEvenWhenTheOtherSideHasAMuchNewerUpdatedAt() {
        val ancestor = rec(0, name = "Old", content = "body", isPinned = false)
        val mine = ancestor.copy(name = "New", updatedAt = at(0.0))
        val theirs = ancestor.copy(isPinned = true, updatedAt = at(86_400.0))
        val survivor = assertNotNull(merge(listOf(ancestor), listOf(mine), listOf(theirs)).snippets.record(id(0)))
        assertEquals("New", survivor.name, "a much newer clock on the other side is irrelevant")
        assertTrue(survivor.isPinned)

        val mineNewer = ancestor.copy(isPinned = true, updatedAt = at(86_400.0))
        val theirsOlder = ancestor.copy(name = "New", updatedAt = at(0.0))
        val mirrored = assertNotNull(merge(listOf(ancestor), listOf(mineNewer), listOf(theirsOlder)).snippets.record(id(0)))
        assertEquals("New", mirrored.name, "our much newer clock does not entitle us to revert their rename")
        assertTrue(mirrored.isPinned)
    }

    @Test fun mergeScalarIgnoresTheClockWheneverExactlyOneSideMovedAwayFromBase() {
        assertEquals("moved", FieldMerge.mergeScalar("base", "base", "moved", localWins = true))
        assertEquals("moved", FieldMerge.mergeScalar("base", "base", "moved", localWins = false))
        assertEquals("moved", FieldMerge.mergeScalar("base", "moved", "base", localWins = true))
        assertEquals("moved", FieldMerge.mergeScalar("base", "moved", "base", localWins = false))
        assertEquals("same", FieldMerge.mergeScalar(null, "same", "same", localWins = false))
        assertEquals("mine", FieldMerge.mergeScalar("base", "mine", "theirs", localWins = true))
        assertEquals("theirs", FieldMerge.mergeScalar("base", "mine", "theirs", localWins = false))
        assertEquals("mine", FieldMerge.mergeScalar(null, "mine", "theirs", localWins = true))
        assertEquals("theirs", FieldMerge.mergeScalar(null, "mine", "theirs", localWins = false))
    }

    /** The Swift name is historical; the tie is now broken by the payload digest, which happens to favour "Mine". */
    @Test fun onAnExactTimestampTieTheInAppEditWinsBecauseForeignWritesSortLowest() {
        val ancestor = rec(0, name = "Old")
        val survivor = assertNotNull(
            merge(listOf(ancestor), listOf(ancestor.copy(name = "Mine")), listOf(ancestor.copy(name = "Theirs")))
                .snippets.record(id(0)),
        )
        assertEquals("Mine", survivor.name)
    }

    // 5. Content conflict copies

    @Test fun bothSidesChangingContentPreservesTheLoserAsADisabledConflictCopy() {
        val ancestor = rec(0, name = "Signature", keyword = "sig", content = "base body", tags = listOf("work"))
        val mine = ancestor.copy(content = "my body", updatedAt = at(100.0))
        val theirs = ancestor.copy(content = "their body", updatedAt = at(50.0))
        val outcome = merge(listOf(ancestor), listOf(mine), listOf(theirs))

        val survivor = assertNotNull(outcome.snippets.record(id(0)))
        assertEquals("my body", survivor.content, "the newer side keeps the record")
        assertEquals(1, outcome.conflictCopies.size)
        val copy = outcome.conflictCopies.first()
        assertEquals("their body", copy.content, "the losing body is preserved, never overwritten")
        assertNotEquals(id(0), copy.id)
        assertFalse(copy.isEnabled, "a conflict copy must never expand")
        assertEquals("", copy.keyword, "two live snippets may never share a keyword")
        assertFalse(copy.isPinned)
        assertTrue(copy.hasTag(SnippetTagging.filterKey("conflict")), "the copy has to be findable by tag")
        assertTrue("work" in copy.tags, "the loser's own tags are kept alongside it")
        assertTrue(copy.name.startsWith("Signature (conflict "))
        assertNotNull(outcome.snippets.record(copy.id), "the copy is part of the merged library")
        assertTrue(outcome.needsUserAttention)
    }

    @Test fun theLocalBodyBecomesTheConflictCopyWhenTheOtherSideIsNewer() {
        val ancestor = rec(0, content = "base body")
        val outcome = merge(
            listOf(ancestor),
            listOf(ancestor.copy(content = "my body", updatedAt = at(10.0))),
            listOf(ancestor.copy(content = "their body", updatedAt = at(500.0))),
        )
        assertEquals("their body", outcome.snippets.record(id(0))?.content)
        assertEquals("my body", outcome.conflictCopies.firstOrNull()?.content)
    }

    @Test fun aOneSidedBodyEditProducesNoConflictCopy() {
        val ancestor = rec(0, content = "base body")
        val outcome = merge(
            listOf(ancestor),
            listOf(ancestor.copy(name = "Renamed")),
            listOf(ancestor.copy(content = "their body", updatedAt = at(50.0))),
        )
        assertEquals("their body", outcome.snippets.record(id(0))?.content)
        assertTrue(outcome.conflictCopies.isEmpty())
        assertFalse(outcome.needsUserAttention)
    }

    @Test fun aConflictCopyIDIsDerivedFromTheRecordAndTheLosingBodyRatherThanBeingRandom() {
        val ancestor = rec(0, content = "base body")
        val mine = ancestor.copy(content = "my body", updatedAt = at(100.0))
        val theirs = ancestor.copy(content = "their body", updatedAt = at(50.0))
        val first = merge(listOf(ancestor), listOf(mine), listOf(theirs))
        val second = merge(listOf(ancestor), listOf(mine), listOf(theirs))
        val copyId = assertNotNull(first.conflictCopies.firstOrNull()?.id)
        assertEquals(copyId, second.conflictCopies.firstOrNull()?.id, "the same inputs give the same copy id")
        assertEquals(
            ConflictCopies.deterministicUuid(id(0), "conflict|their body|${AppleTime.hlcMillis(at(50.0))}"), copyId,
            "the recipe is pinned: changing it would orphan every copy already on disk",
        )
        assertEquals(copyId, LocalMerge.conflictCopyId(id(0), theirs))
        assertEquals('5', copyId.toString()[14], "UUIDv5 version nibble")
    }

    @Test fun conflictCopiesDoNotBreedWhenTheSameMergeRunsAgain() {
        val ancestor = rec(0, name = "Signature", content = "base body")
        val mine = ancestor.copy(content = "my body", updatedAt = at(100.0))
        val theirs = ancestor.copy(content = "their body", updatedAt = at(50.0))
        val first = merge(listOf(ancestor), listOf(mine), listOf(theirs))
        val second = merge(listOf(ancestor), first.snippets, listOf(theirs))
        val third = merge(listOf(ancestor), second.snippets, listOf(theirs))
        fun copyCount(outcome: LocalMerge.Outcome) = outcome.snippets.count { it.hasTag(SnippetTagging.filterKey("conflict")) }
        assertEquals(1, copyCount(first))
        assertEquals(1, copyCount(second), "a second round must not mint a second copy")
        assertEquals(1, copyCount(third), "nor a third")
        assertEquals(first.snippets, second.snippets, "the merge has reached a fixed point")
        assertEquals(first.snippets, third.snippets)
    }

    @Test fun aConflictCopySurvivesLaterMergesAsAnOrdinaryDisabledRecord() {
        val ancestor = rec(0, content = "base body")
        val first = merge(
            listOf(ancestor),
            listOf(ancestor.copy(content = "my body", updatedAt = at(100.0))),
            listOf(ancestor.copy(content = "their body", updatedAt = at(50.0))),
        )
        val copy = first.conflictCopies.first()
        val settled = merge(first.snippets, first.snippets, first.snippets)
        assertEquals(copy, settled.snippets.record(copy.id))
        assertTrue(settled.conflictCopies.isEmpty())
        assertFalse(settled.needsUserAttention)
    }

    // 6. Tags

    @Test fun concurrentTagAdditionsOnBothSidesAreUnioned() {
        assertEquals(
            listOf("work", "draft", "urgent"),
            FieldMerge.mergeTags(listOf("work"), listOf("work", "urgent"), listOf("work", "draft"), localWins = true),
            "new tags are appended in folded-key order so both devices converge on one array",
        )
    }

    @Test fun aTagRemovedOnOneSideStaysRemovedWhileTheOtherSidesAdditionIsKept() {
        assertEquals(
            listOf("alpha", "gamma"),
            FieldMerge.mergeTags(listOf("alpha", "beta"), listOf("alpha"), listOf("alpha", "beta", "gamma"), localWins = true),
        )
        assertEquals(
            listOf("alpha", "gamma"),
            FieldMerge.mergeTags(listOf("alpha", "beta"), listOf("alpha", "beta", "gamma"), listOf("alpha"), localWins = false),
        )
    }

    @Test fun survivingTagsKeepTheirOrderFromTheAncestor() {
        assertEquals(
            listOf("zulu", "alpha", "mike", "new"),
            FieldMerge.mergeTags(
                listOf("zulu", "alpha", "mike"), listOf("zulu", "alpha", "mike"), listOf("zulu", "alpha", "mike", "new"),
                localWins = true,
            ),
        )
    }

    @Test fun aTagDifferingOnlyInCaseOrDiacriticsIsNotANewTag() {
        assertEquals(
            listOf("Work", "extra"),
            FieldMerge.mergeTags(listOf("work"), listOf("Work", "extra"), listOf("work"), localWins = true),
            "the winning side's casing survives, not the ancestor's",
        )
        assertEquals(listOf("Cafe", "x"), FieldMerge.mergeTags(listOf("café"), listOf("Cafe"), listOf("café", "x"), localWins = true))
        assertEquals(listOf("WORK"), FieldMerge.mergeTags(listOf("work"), listOf("Work"), listOf("WORK"), localWins = false))

        val ancestor = rec(0, tags = listOf("work"))
        val mine = ancestor.copy(tags = listOf("Work", "urgent"), updatedAt = at(10.0))
        val theirs = ancestor.copy(tags = listOf("work", "draft"), updatedAt = at(20.0))
        val survivor = assertNotNull(merge(listOf(ancestor), listOf(mine), listOf(theirs)).snippets.record(id(0)))
        assertEquals(listOf("work", "draft", "urgent"), survivor.tags)
    }

    @Test fun withNoAncestorTagsCanOnlyBeUnioned() {
        assertEquals(listOf("a", "b"), FieldMerge.mergeTags(null, listOf("a"), listOf("b"), localWins = true))
        assertEquals(listOf("b"), FieldMerge.mergeTags(null, emptyList(), listOf("b"), localWins = false))
    }

    @Test fun aTagRemovedOnBothSidesIsGone() {
        assertEquals(listOf("a"), FieldMerge.mergeTags(listOf("a", "b"), listOf("a"), listOf("a"), localWins = true))
    }

    // 7. Keyword collisions

    @Test fun aMergeThatLeavesTwoLiveSnippetsSharingAKeywordDisablesExactlyOne() {
        val mine = rec(0, name = "Mine", keyword = "sig", content = "a", updatedAt = 100.0)
        val theirs = rec(1, name = "Theirs", keyword = "SIG", content = "b", updatedAt = 50.0)
        val outcome = merge(local = listOf(mine), remote = listOf(theirs))
        assertEquals(2, outcome.snippets.size, "neither record is dropped")
        assertEquals(listOf(id(1)), outcome.disabledByKeywordCollision, "the older one loses")
        assertEquals(true, outcome.snippets.record(id(0))?.isEnabled)
        assertEquals(false, outcome.snippets.record(id(1))?.isEnabled)
        assertEquals("SIG", outcome.snippets.record(id(1))?.keyword, "the keyword text is never cleared")
        assertTrue(outcome.needsUserAttention)
    }

    @Test fun onAnExactTieTheKeywordCollisionLoserIsTheSameRegardlessOfInputOrder() {
        val low = rec(0, keyword = "sig", content = "a", updatedAt = 42.0)
        val high = rec(1, keyword = "sig", content = "b", updatedAt = 42.0)
        val oneWay = merge(local = listOf(high), remote = listOf(low))
        val otherWay = merge(local = listOf(low), remote = listOf(high))
        assertEquals(listOf(id(1)), oneWay.disabledByKeywordCollision)
        assertEquals(listOf(id(1)), otherWay.disabledByKeywordCollision, "the tiebreak is a property of the records")
        assertEquals(true, oneWay.snippets.record(id(0))?.isEnabled)
        assertEquals(true, otherWay.snippets.record(id(0))?.isEnabled)
    }

    @Test fun aDisabledSnippetNeverContestsAKeyword() {
        val live = rec(0, keyword = "sig", content = "a", updatedAt = 10.0)
        val dormant = rec(1, keyword = "sig", content = "b", isEnabled = false, updatedAt = 900.0)
        val outcome = merge(local = listOf(live), remote = listOf(dormant))
        assertTrue(outcome.disabledByKeywordCollision.isEmpty())
        assertEquals(true, outcome.snippets.record(id(0))?.isEnabled)
    }

    @Test fun snippetsWithoutKeywordsNeverCollide() {
        val outcome = merge(local = listOf(rec(0, keyword = "  ", content = "a")), remote = listOf(rec(1, keyword = "", content = "b")))
        assertTrue(outcome.disabledByKeywordCollision.isEmpty())
        assertTrue(outcome.snippets.all { it.isEnabled })
    }

    @Test fun threeSnippetsSharingAKeywordLeaveExactlyOneEnabled() {
        val snippets = listOf(
            rec(0, keyword = "sig", content = "a", updatedAt = 10.0),
            rec(1, keyword = "Sig", content = "b", updatedAt = 900.0),
            rec(2, keyword = "SIG", content = "c", updatedAt = 20.0),
        )
        val (resolved, disabled) = LocalMerge.resolveKeywordCollisions(snippets)
        assertEquals(listOf(id(1)), resolved.filter { it.isEnabled }.ids, "the newest keeps the keyword")
        assertEquals(setOf(id(0), id(2)), disabled.toSet())
    }

    // 8. Timestamps

    @Test fun createdAtNeverMovesForwardAndUpdatedAtNeverMovesBackward() {
        val mine = rec(0, content = "same", createdAt = 50.0, updatedAt = 50.0)
        val theirs = rec(0, content = "same", createdAt = 10.0, updatedAt = 900.0)
        val agreed = assertNotNull(merge(local = listOf(mine), remote = listOf(theirs)).snippets.record(id(0)))
        assertEquals(at(10.0), agreed.createdAt)
        assertEquals(at(900.0), agreed.updatedAt)

        val ancestor = rec(0, name = "Old", content = "body", createdAt = 0.0, updatedAt = 0.0)
        val edited = ancestor.copy(name = "New", createdAt = at(100.0), updatedAt = at(100.0))
        val otherEdited = ancestor.copy(isPinned = true, createdAt = at(20.0), updatedAt = at(300.0))
        val merged = assertNotNull(merge(listOf(ancestor), listOf(edited), listOf(otherEdited)).snippets.record(id(0)))
        assertEquals(at(20.0), merged.createdAt)
        assertEquals(at(300.0), merged.updatedAt)
    }

    // 9. Properties over random triples

    @Test fun mergingTheResultAgainChangesNothing() {
        for (seed in 1L..300L) {
            val scenario = makeScenario(seed)
            val first = merge(scenario.base, scenario.local, scenario.remote)
            val again = merge(first.snippets, first.snippets, first.snippets)
            assertEquals(first.snippets, again.snippets, "seed $seed is not a fixed point")
            assertTrue(again.conflictCopies.isEmpty(), "seed $seed minted a copy on the second pass")
            assertTrue(again.disabledByKeywordCollision.isEmpty(), "seed $seed re-resolved a collision")
            assertFalse(again.needsUserAttention, "seed $seed reported a change it did not make")
        }
    }

    @Test fun theSameInputsAlwaysProduceTheSameOutput() {
        for (seed in 1L..300L) {
            val scenario = makeScenario(seed)
            val first = merge(scenario.base, scenario.local, scenario.remote)
            val second = merge(scenario.base, scenario.local, scenario.remote)
            assertEquals(first.snippets, second.snippets, "seed $seed is not deterministic")
            assertEquals(first.snippets.ids, second.snippets.ids, "seed $seed reordered itself")
            assertEquals(first.disabledByKeywordCollision, second.disabledByKeywordCollision)
            // Swift compares the copies as a set; here they come back sorted by id, so as a list.
            assertEquals(first.conflictCopies.ids, second.conflictCopies.ids, "seed $seed minted a different copy id")
        }
    }

    @Test fun noBodyThatEitherSideChangedIsEverSilentlyDestroyed() {
        for (seed in 1L..300L) {
            val scenario = makeScenario(seed)
            val produced = merge(scenario.base, scenario.local, scenario.remote).snippets.contents
            for (side in listOf(scenario.local, scenario.remote)) {
                for (snippet in side) {
                    val ancestor = scenario.base.record(snippet.id)
                    if (ancestor != null && ancestor.content == snippet.content) continue
                    assertTrue(snippet.content in produced, "seed $seed destroyed ${snippet.content}")
                }
            }
        }
    }

    @Test fun everyMergedLibrarySatisfiesTheStructuralInvariants() {
        fun liveCollisions(snippets: List<Snippet>): Set<String> {
            val seen = HashSet<String>()
            val duplicated = HashSet<String>()
            for (snippet in snippets) {
                if (!snippet.isEnabled) continue
                val key = SnippetTagging.filterKey(snippet.normalizedKeyword)
                if (key.isEmpty()) continue
                if (!seen.add(key)) duplicated.add(key)
            }
            return duplicated
        }
        for (seed in 1L..300L) {
            val scenario = makeScenario(seed)
            val outcome = merge(scenario.base, scenario.local, scenario.remote)
            assertEquals(outcome.snippets.size, outcome.snippets.ids.toSet().size, "seed $seed produced a duplicate id")
            val preExisting = liveCollisions(scenario.local) + liveCollisions(scenario.remote)
            assertTrue((liveCollisions(outcome.snippets) - preExisting).isEmpty(), "seed $seed introduced a keyword collision")
            for (snippet in outcome.snippets) {
                val keys = snippet.tags.map(SnippetTagging::filterKey)
                assertEquals(keys.size, keys.toSet().size, "seed $seed produced duplicate tags")
                val mine = scenario.local.record(snippet.id)
                val theirs = scenario.remote.record(snippet.id)
                if (mine != null && theirs != null) {
                    assertEquals(minOf(mine.createdAt, theirs.createdAt), snippet.createdAt, "seed $seed moved createdAt forward")
                    assertEquals(maxOf(mine.updatedAt, theirs.updatedAt), snippet.updatedAt, "seed $seed moved updatedAt backward")
                }
            }
            for (copy in outcome.conflictCopies) {
                assertFalse(copy.isEnabled)
                assertTrue(copy.keyword.isEmpty())
                assertTrue(copy.hasTag(SnippetTagging.filterKey("conflict")))
                assertNotNull(outcome.snippets.record(copy.id))
            }
        }
    }

    @Test fun aRecordOnlyDisappearsWhenTheAncestorProvesItWasDeleted() {
        for (seed in 1L..300L) {
            val scenario = makeScenario(seed)
            val survived = merge(scenario.base, scenario.local, scenario.remote).snippets.ids.toSet()
            for (snippet in scenario.local + scenario.remote) {
                if (snippet.id in survived) continue
                val ancestor = assertNotNull(scenario.base.record(snippet.id), "seed $seed dropped ${snippet.id} with no ancestor")
                assertTrue(LocalMerge.payloadEquals(ancestor, snippet), "seed $seed dropped an edited record")
                val heldByBoth = scenario.local.record(snippet.id) != null && scenario.remote.record(snippet.id) != null
                assertFalse(heldByBoth, "seed $seed dropped a record both sides still had")
            }
        }
    }

    // 10. Output ordering

    @Test fun theOutputIsOrderedLocalFirstThenRemoteOnlyThenConflictCopies() {
        val ancestor = rec(0, content = "base body")
        val mine = ancestor.copy(content = "my body", updatedAt = at(100.0))
        val theirs = ancestor.copy(content = "their body", updatedAt = at(50.0))
        val shared = rec(1, content = "shared")
        val localOnly = rec(2, content = "local only")
        val remoteOnly = rec(3, content = "remote only")
        val outcome = merge(listOf(ancestor, shared), listOf(mine, shared, localOnly), listOf(theirs, shared, remoteOnly))
        val copyId = assertNotNull(outcome.conflictCopies.firstOrNull()?.id)
        assertEquals(listOf(id(0), id(1), id(2), id(3), copyId), outcome.snippets.ids)
    }

    @Test fun theSameMergeRepeatedInOneProcessAlwaysYieldsTheIdenticalIDOrdering() {
        val scenario = makeScenario(0xC0FFEE, recordCount = 24)
        val reference = merge(scenario.base, scenario.local, scenario.remote).snippets.ids
        assertTrue(reference.size > 8, "the fixture has to be big enough for hashing order to matter")
        repeat(200) { assertEquals(reference, merge(scenario.base, scenario.local, scenario.remote).snippets.ids) }
    }

    @Test fun remoteOnlyRecordsArriveInTheRemotesOwnOrder() {
        val outcome = merge(remote = listOf(rec(3, content = "c"), rec(1, content = "a"), rec(2, content = "b")))
        assertEquals(listOf(id(3), id(1), id(2)), outcome.snippets.ids)
    }

    // Cross-device convergence (`SyncMergeConvergenceTests`)

    private fun convergenceSnippet(
        id: UUID,
        name: String = "n",
        keyword: String = "k",
        content: String = "c",
        tags: List<String> = emptyList(),
        updatedAt: Double,
    ) = Snippet(
        id = id, name = name, keyword = keyword, content = content, tags = tags,
        createdAt = MergeFixtures.unix(1_000.0), updatedAt = MergeFixtures.unix(updatedAt),
    )

    private fun assertConverges(base: List<Snippet>, onA: List<Snippet>, onB: List<Snippet>, what: String) {
        val a = LocalMerge.mergeLocal(base, onA, onB)
        val b = LocalMerge.mergeLocal(base, onB, onA)
        val byId = { snippets: List<Snippet> -> snippets.associateBy { it.id } }
        assertEquals(byId(a.snippets), byId(b.snippets), "$what: devices disagree")
        val again = LocalMerge.mergeLocal(a.snippets, a.snippets, b.snippets)
        assertEquals(byId(a.snippets), byId(again.snippets), "$what: not a fixed point")
    }

    @Test fun twoDevicesAgreeWhenTheSameFieldChangedInTheSameMillisecond() {
        val id = UUID.randomUUID()
        assertConverges(
            listOf(convergenceSnippet(id, name = "original", updatedAt = 100.0)),
            listOf(convergenceSnippet(id, name = "renamed on A", updatedAt = 200.0)),
            listOf(convergenceSnippet(id, name = "renamed on B", updatedAt = 200.0)),
            "simultaneous rename",
        )
    }

    @Test fun twoDevicesAgreeOnASimultaneousContentConflict() {
        val id = UUID.randomUUID()
        val base = listOf(convergenceSnippet(id, content = "original", updatedAt = 100.0))
        val onA = listOf(convergenceSnippet(id, content = "A's body", updatedAt = 200.0))
        val onB = listOf(convergenceSnippet(id, content = "B's body", updatedAt = 200.0))
        assertConverges(base, onA, onB, "simultaneous content edit")
        val a = LocalMerge.mergeLocal(base, onA, onB)
        val b = LocalMerge.mergeLocal(base, onB, onA)
        assertEquals(a.conflictCopies.ids, b.conflictCopies.ids)
        assertEquals(1, a.conflictCopies.size)
        assertEquals(a.conflictCopies.first().name, b.conflictCopies.first().name)
    }

    @Test fun twoDevicesAgreeOnSimultaneousTagEdits() {
        val id = UUID.randomUUID()
        assertConverges(
            listOf(convergenceSnippet(id, tags = listOf("work"), updatedAt = 100.0)),
            listOf(convergenceSnippet(id, tags = listOf("work", "urgent"), updatedAt = 200.0)),
            listOf(convergenceSnippet(id, tags = listOf("work", "draft"), updatedAt = 200.0)),
            "simultaneous tag add",
        )
    }

    @Test fun twoDevicesAgreeWithNoCommonAncestor() {
        val id = UUID.randomUUID()
        assertConverges(
            emptyList(),
            listOf(convergenceSnippet(id, name = "A", content = "a", updatedAt = 200.0)),
            listOf(convergenceSnippet(id, name = "B", content = "b", updatedAt = 200.0)),
            "no ancestor, same instant",
        )
    }

    @Test fun twoDevicesAgreeOnASimultaneousKeywordCollision() {
        val a = convergenceSnippet(UUID.fromString("11111111-1111-4111-8111-111111111111"), keyword = "dup", content = "a", updatedAt = 200.0)
        val b = convergenceSnippet(UUID.fromString("22222222-2222-4222-8222-222222222222"), keyword = "dup", content = "b", updatedAt = 200.0)
        assertConverges(emptyList(), listOf(a), listOf(b), "simultaneous keyword collision")
        val merged = LocalMerge.mergeLocal(emptyList(), listOf(a), listOf(b))
        assertEquals(1, merged.snippets.count { it.isEnabled })
        assertEquals(1, merged.disabledByKeywordCollision.size)
    }

    @Test fun mirroredMergesConvergeOverRandomHistories() {
        val random = MergeRandom(0x5EED_C0DE)
        val ids = (0 until 6).map { UUID.randomUUID() }
        for (iteration in 0 until 400) {
            fun mutate(source: List<Snippet>, salt: String): List<Snippet> {
                val out = ArrayList<Snippet>()
                for (s in source) {
                    when (random.int(5)) {
                        0 -> continue
                        1 -> out.add(convergenceSnippet(s.id, name = "name-$salt", keyword = s.keyword, content = s.content, updatedAt = 200.0))
                        2 -> out.add(convergenceSnippet(s.id, name = s.name, keyword = s.keyword, content = "body-$salt", updatedAt = 200.0))
                        3 -> out.add(
                            convergenceSnippet(s.id, name = s.name, keyword = s.keyword, content = s.content, tags = listOf("t-$salt"), updatedAt = 200.0),
                        )
                        else -> out.add(s)
                    }
                }
                return out
            }
            val base = ids.take(random.int(ids.size) + 1).map {
                convergenceSnippet(it, name = "n-${it.toString().uppercase().take(4)}", keyword = "k${it.toString().uppercase().take(4)}", updatedAt = 100.0)
            }
            assertConverges(base, mutate(base, "A"), mutate(base, "B"), "randomized history #$iteration")
        }
    }

    // `ReviewRegressionTests.swift`, the merge cases

    private fun named(name: String, keyword: String, content: String = "body"): Snippet =
        Snippet(name = name, keyword = keyword, content = content, createdAt = MergeFixtures.unix(1.0), updatedAt = MergeFixtures.unix(1.0))

    @Test fun mergingAgainstAGenuinelyEmptiedRemoteDeletesEverything() {
        val records = (0 until 20).map { named("n$it", "k$it") }
        val edited = records.toMutableList().also { it[0] = it[0].copy(content = "edited locally") }
        val outcome = LocalMerge.mergeLocal(records, edited, emptyList())
        assertEquals(1, outcome.snippets.size)
        assertEquals("edited locally", outcome.snippets.first().content)
    }

    @Test fun rebasingAnUndoSnapshotNeverMintsAConflictCopy() {
        val original = named("note", "n", "v1")
        val v2 = original.copy(content = "v2")
        val v3 = original.copy(content = "v3 from the CLI")
        val rebased = LocalMerge.rebaseSnapshot(listOf(original), capturedAgainst = listOf(v2), merged = listOf(v3))
        assertEquals(1, rebased.size, "a rebase must not add records")
        assertEquals("v1", rebased[0].content, "undo restores the value the user asked for")
        assertTrue(rebased.none { "conflict" in it.tags })
        assertTrue(rebased.all { it.isEnabled })
    }

    @Test fun rebasingAnUndoSnapshotKeepsRecordsTheUndoNeverTouched() {
        val mine = named("mine", "m", "v1")
        val mineEdited = mine.copy(content = "v2")
        val theirs = named("theirs", "t")
        val rebased = LocalMerge.rebaseSnapshot(listOf(mine), listOf(mineEdited), listOf(mineEdited, theirs))
        assertEquals(2, rebased.size)
        assertEquals("v1", rebased.first { it.id == mine.id }.content)
        assertTrue(rebased.any { it.id == theirs.id }, "the other writer's record must survive undo")
    }

    @Test fun rebasingAnUndoSnapshotThatDeletedARecordStillDeletesIt() {
        val a = named("a", "a")
        val b = named("b", "b")
        assertEquals(listOf(a.id), LocalMerge.rebaseSnapshot(listOf(a), listOf(a, b), listOf(a, b)).ids)
    }

    @Test fun aPreExistingKeywordCollisionIsLeftAloneByAnUnrelatedMerge() {
        val dupA = named("first", "dup", "a")
        val dupB = named("second", "dup", "b")
        val other = named("other", "other")
        val editedOther = other.copy(content = "changed remotely")
        val outcome = LocalMerge.mergeLocal(listOf(dupA, dupB, other), listOf(dupA, dupB, other), listOf(dupA, dupB, editedOther))
        assertTrue(outcome.disabledByKeywordCollision.isEmpty())
        assertTrue(outcome.snippets.filter { it.normalizedKeyword == "dup" }.all { it.isEnabled })
    }

    @Test fun aCollisionTheMergeItselfCreatesIsStillResolved() {
        val mine = named("mine", "taken", "a")
        val theirs = named("theirs", "taken", "b")
        val outcome = LocalMerge.mergeLocal(emptyList(), listOf(mine), listOf(theirs))
        assertEquals(1, outcome.snippets.count { it.isEnabled && it.normalizedKeyword == "taken" })
        assertEquals(1, outcome.disabledByKeywordCollision.size)
        assertTrue(outcome.snippets.all { it.normalizedKeyword == "taken" })
    }

    @Test fun tagFoldingDoesNotDependOnTheProcessLocale() {
        val saved = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.forLanguageTag("tr-TR"))
            assertEquals(SnippetTagging.filterKey("work"), SnippetTagging.filterKey("WORK"))
            assertEquals(SnippetTagging.filterKey("istanbul"), SnippetTagging.filterKey("İstanbul"))
            assertEquals(SnippetTagging.filterKey("cafe"), SnippetTagging.filterKey("CAFÉ"))
            val once = SnippetTagging.filterKey("Iı-İi")
            repeat(50) { assertEquals(once, SnippetTagging.filterKey("Iı-İi")) }
        } finally {
            java.util.Locale.setDefault(saved)
        }
    }

    @Test fun repeatedIdenticalMergesProduceIdenticalOutputIncludingConflictOrder() {
        val base = ArrayList<Snippet>()
        val local = ArrayList<Snippet>()
        val remote = ArrayList<Snippet>()
        for (index in 0 until 12) {
            val record = named("n$index", "k$index", "base")
            base.add(record)
            local.add(record.copy(content = "mine-$index", updatedAt = MergeFixtures.unix(2_000.0)))
            remote.add(record.copy(content = "theirs-$index", updatedAt = MergeFixtures.unix(2_000.0)))
        }
        val first = LocalMerge.mergeLocal(base, local, remote)
        repeat(20) {
            val again = LocalMerge.mergeLocal(base, local, remote)
            assertEquals(first.snippets.ids, again.snippets.ids)
            assertEquals(first.conflictCopies.ids, again.conflictCopies.ids)
        }
    }

    @Test fun aRecordRemovedByTheMergeStaysRemovedWhenTheUndoNeverTouchedIt() {
        val secret = named("awsroot", "awsroot", "hunter2")
        val other = named("sig", "sig", "Best, Mike")
        val rebased = LocalMerge.rebaseSnapshot(listOf(secret, other), listOf(secret, other), listOf(other))
        assertEquals(listOf(other.id), rebased.ids)
        assertTrue(rebased.none { it.content == "hunter2" }, "the plaintext must not survive in an undo level")
    }

    @Test fun anUndoThatReAddsARecordStillRestoresIt() {
        val restored = named("note", "note", "v1")
        val other = named("sig", "sig", "Best, Mike")
        val rebased = LocalMerge.rebaseSnapshot(listOf(restored, other), listOf(other), listOf(other))
        assertEquals(setOf(restored.id, other.id), rebased.ids.toSet())
        assertEquals("v1", rebased.first { it.id == restored.id }.content)
    }

    // Beyond the Swift suites: the corners Kotlin's own types would get wrong.

    @Test fun textComparesByCanonicalEquivalenceAndKeepsTheLocalSpelling() {
        val nfc = "Café"
        val nfd = "Café"
        assertEquals(nfc, FieldMerge.mergeScalar("Old", nfc, nfd, localWins = false), "equal values: local's spelling")
        val ancestor = rec(0, name = nfc, content = "same")
        val outcome = merge(listOf(ancestor), listOf(ancestor.copy(name = nfd)), listOf(ancestor))
        assertEquals(nfd, outcome.snippets.single().name, "both sides hold one payload as Swift compares it; local's bytes stay")
        assertTrue(LocalMerge.payloadEquals(ancestor, ancestor.copy(name = nfd)))
        assertTrue(FoundationText.canonicalEquals(nfc, nfd))
    }

    @Test fun minAndMaxReturnSwiftsArgumentForZeroAndNegativeZero() {
        val local = rec(0, content = "same").copy(createdAt = 0.0, updatedAt = 0.0)
        val remote = local.copy(createdAt = -0.0, updatedAt = -0.0)
        val merged = merge(local = listOf(local), remote = listOf(remote)).snippets.single()
        // `min(x, y)` keeps x on a tie, `max(x, y)` takes y.
        assertEquals(0.0.toRawBits(), merged.createdAt.toRawBits())
        assertEquals((-0.0).toRawBits(), merged.updatedAt.toRawBits())
    }

    @Test fun duplicateIdsCountAsTheirFirstOccurrence() {
        val first = rec(0, content = "first")
        val second = rec(0, content = "second")
        val outcome = merge(local = listOf(first, second))
        assertEquals(listOf("first"), outcome.snippets.map { it.content })
        assertNull(merge(base = listOf(first, second), local = listOf(first)).snippets.firstOrNull { it.content == "second" })
    }

    @Test fun keywordTiesBreakOnTheUppercaseIdTextNotOnSignedLongs() {
        // `f…` sorts after `0…` as text, but its most significant long is negative.
        val high = Snippet(
            id = UUID.fromString("f0000000-0000-4000-8000-000000000000"), name = "high", keyword = "sig", content = "a",
            createdAt = at(0.0), updatedAt = at(5.0),
        )
        val low = Snippet(
            id = UUID.fromString("00000000-0000-4000-8000-000000000001"), name = "low", keyword = "sig", content = "b",
            createdAt = at(0.0), updatedAt = at(5.0),
        )
        assertEquals(listOf(high.id), merge(local = listOf(high), remote = listOf(low)).disabledByKeywordCollision)
    }
}
