package com.khm.snippets.core.library

import com.khm.snippets.core.state.SyncState
import com.khm.snippets.core.state.TEST_DEVICE
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The pure generation rule (`bumpGeneration`). */
class LibraryGenerationTest {

    private val a = "a".repeat(64)
    private val b = "b".repeat(64)
    private val c = "c".repeat(64)

    @Test
    fun aCooperatingWriteAdvancesByOneAndRecordsItsDigest() {
        val next = LibraryGeneration.advanced(SyncState(TEST_DEVICE, generation = 7, librarySha256 = a), written = b, observedOnDisk = a)
        assertEquals(SyncState(TEST_DEVICE, generation = 8, librarySha256 = b), next)
    }

    @Test
    fun bytesTheWriterDidNotRecordLeaveAGapOfTwo() {
        val state = SyncState(TEST_DEVICE, generation = 7, librarySha256 = a)
        assertTrue(LibraryGeneration.changedOutsideWriter(state, c))
        assertEquals(9L, LibraryGeneration.advanced(state, written = b, observedOnDisk = c).generation)
    }

    @Test
    fun aMissingFileOrANewStateIsNeverAForeignWrite() {
        val recorded = SyncState(TEST_DEVICE, generation = 3, librarySha256 = a)
        assertTrue(!LibraryGeneration.changedOutsideWriter(recorded, ""))
        assertEquals(4L, LibraryGeneration.advanced(recorded, b, "").generation)
        val unrecorded = SyncState(TEST_DEVICE, generation = 0)
        assertTrue(!LibraryGeneration.changedOutsideWriter(unrecorded, c))
        assertEquals(1L, LibraryGeneration.advanced(unrecorded, b, c).generation)
    }

    @Test
    fun theCounterWrapsLikeAnUnsignedCounterInsteadOfOverflowing() {
        val top = SyncState(TEST_DEVICE, generation = Long.MAX_VALUE, librarySha256 = a)
        assertEquals(0L, LibraryGeneration.advanced(top, b, a).generation)
        assertEquals(1L, LibraryGeneration.advanced(top, b, c).generation)
    }

    @Test
    fun everythingElseInTheStateIsKept() {
        val state = SyncState(TEST_DEVICE, generation = 1, librarySha256 = a, promoting = java.util.UUID.randomUUID())
        val next = LibraryGeneration.advanced(state, b, a)
        assertEquals(state.copy(generation = 2, librarySha256 = b), next)
    }
}
