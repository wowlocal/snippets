package com.khm.snippets.core.state

import com.khm.snippets.core.canonical.JsonValue
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The `state.json` decoder is closed. A lenient reader would be worse than none: an
 * ignored key is erased on the next write, a `null` read as "absent" can clear a halt,
 * and a default turns a truncated file into an authoritative fresh one.
 */
class SyncStateStrictnessTest {

    private val full = SyncState(
        deviceId = TEST_DEVICE,
        generation = 7,
        librarySha256 = "cd".repeat(32),
        halt = Halt(
            reason = HaltReason.MASS_DELETION,
            detail = HaltDetail.of("remote_mass_deletion", mapOf("live" to "93")),
            at = 790_692_600.25,
            recoveryContext = RecoveryContext.MassDeletion(93, 91, "e".repeat(64)),
            recoveryClaim = RecoveryClaim(testId(1), testId(2), testId(3)),
        ),
        promoting = testId(4),
        demoting = testId(5),
    )

    private val document: JsonValue = parseJson(SyncStateCodec.encode(full))

    private val required = mapOf(
        "" to setOf("schemaVersion", "deviceID", "generation"),
        "halt" to setOf("reason", "detail", "at"),
        "halt.detail" to setOf("code", "arguments"),
        "halt.recoveryContext" to setOf("massDeletion"),
        "halt.recoveryContext.massDeletion" to setOf("liveCount", "requestedDeletions", "batchFingerprint"),
        "halt.recoveryClaim" to setOf("id", "ownerID", "launchID"),
    )

    // Free-form maps: their keys are data, not format.
    private val openObjects = setOf("halt.detail.arguments")

    private fun undecodable(bytes: ByteArray, label: String): StrictDecodeFailure {
        val result = SyncStateCodec.read(bytes)
        if (result !is SyncStateCodec.ReadResult.Undecodable) fail("$label decoded as $result")
        return result.failure
    }

    @Test
    fun theFullDocumentRoundTrips() {
        assertEquals(full, SyncStateCodec.decode(document.bytes()))
        assertEquals(full, SyncStateCodec.decode(SyncStateCodec.encode(full)))
    }

    @Test
    fun anUnknownKeyAtAnyLevelIsRefused() {
        for (path in objectPaths(document)) {
            if (dotted(path) in openObjects) continue
            val edited = document.edited(path) { it["futureField"] = JsonValue.of(true) }
            val failure = undecodable(edited.bytes(), "an unknown key in '${dotted(path)}'")
            assertEquals(StrictDecodeFailure.Kind.UNKNOWN_KEY, failure.kind, dotted(path))
            assertEquals(dotted(path), failure.path)
        }
        // Also inside the empty case object of the other recovery context.
        val quarantine = parseJson(
            SyncStateCodec.encode(
                full.copy(halt = full.halt!!.copy(recoveryContext = RecoveryContext.LocalLibraryQuarantine)),
            ),
        )
        val edited = quarantine.edited(listOf("halt", "recoveryContext", "localLibraryQuarantine")) { it["x"] = JsonValue.of(1) }
        assertEquals(StrictDecodeFailure.Kind.UNKNOWN_KEY, undecodable(edited.bytes(), "context payload").kind)
    }

    @Test
    fun anExplicitNullIsNeverReadAsAbsent() {
        for (path in objectPaths(document)) {
            for (key in document.objectAt(path).keys) {
                val edited = document.edited(path) { it[key] = JsonValue.Null }
                val label = dotted(path + key)
                val failure = undecodable(edited.bytes(), "null at '$label'")
                if (key == "schemaVersion" && path.isEmpty()) {
                    assertEquals(StrictDecodeFailure.Kind.EXPLICIT_NULL, failure.kind, label)
                    continue
                }
                assertEquals(StrictDecodeFailure.Kind.EXPLICIT_NULL, failure.kind, label)
                val expectedPath = if (dotted(path) in openObjects) dotted(path) else label
                assertEquals(expectedPath, failure.path, label)
            }
        }
    }

    @Test
    fun aMissingRequiredKeyIsRefusedAndAMissingOptionalOneIsAbsent() {
        for (path in objectPaths(document)) {
            val dottedPath = dotted(path)
            if (dottedPath in openObjects) continue
            for (key in document.objectAt(path).keys) {
                val edited = document.edited(path) { it.remove(key) }
                val label = dotted(path + key)
                val mandatory = required[dottedPath]?.contains(key) == true
                val result = SyncStateCodec.read(edited.bytes())
                if (mandatory) {
                    assertIs<SyncStateCodec.ReadResult.Undecodable>(result, "removing '$label'")
                    // A context object must name exactly one case.
                    val expected = if (dottedPath == "halt.recoveryContext") StrictDecodeFailure.Kind.INVALID_VALUE else StrictDecodeFailure.Kind.MISSING_KEY
                    assertEquals(expected, result.failure.kind, label)
                } else {
                    assertIs<SyncStateCodec.ReadResult.Decoded>(result, "removing optional '$label'")
                }
            }
        }
    }

    @Test
    fun aWrongTypeAnywhereIsRefused() {
        for (path in objectPaths(document)) {
            for (key in document.objectAt(path).keys) {
                val value = document.objectAt(path).getValue(key)
                val edited = document.edited(path) { it[key] = anotherType(value) }
                val label = dotted(path + key)
                if (label == "schemaVersion") {
                    // The probe reads only a number; "7" is not one, so the strict decoder refuses it.
                    assertEquals(StrictDecodeFailure.Kind.WRONG_TYPE, undecodable(edited.bytes(), label).kind)
                    continue
                }
                val failure = undecodable(edited.bytes(), "a wrong type at '$label'")
                assertTrue(
                    failure.kind in setOf(
                        StrictDecodeFailure.Kind.WRONG_TYPE, StrictDecodeFailure.Kind.NOT_AN_OBJECT, StrictDecodeFailure.Kind.INVALID_VALUE,
                    ),
                    "$label: ${failure.kind}",
                )
            }
        }
    }

    @Test
    fun valuesOutsideTheFormatAreRefused() {
        val cases = listOf(
            listOf<String>() to ("deviceID" to JsonValue.of("A1B2C3D4")),
            listOf<String>() to ("deviceID" to JsonValue.of("a1b2c3")),
            listOf<String>() to ("generation" to JsonValue.of(-1)),
            listOf<String>() to ("generation" to JsonValue.of(7.0)),
            listOf<String>() to ("librarySHA256" to JsonValue.of("CD".repeat(32))),
            listOf<String>() to ("promoting" to JsonValue.of(LETTERED_ID.toString().uppercase())),
            listOf<String>() to ("demoting" to JsonValue.of("1-1-1-1-1")),
            listOf("halt") to ("reason" to JsonValue.of("somethingNew")),
            listOf("halt") to ("at" to JsonValue.of("2026-02-02T02:30:00Z")),
            listOf("halt", "detail") to ("code" to JsonValue.of("has a space")),
            listOf("halt", "detail") to ("code" to JsonValue.of("")),
            listOf("halt", "detail", "arguments") to ("bad key" to JsonValue.of("v")),
            listOf("halt", "detail", "arguments") to ("n" to JsonValue.of(3)),
            listOf("halt", "recoveryContext", "massDeletion") to ("batchFingerprint" to JsonValue.of("not-a-digest")),
            listOf("halt", "recoveryContext", "massDeletion") to ("liveCount" to JsonValue.of(1.5)),
            listOf("halt", "recoveryContext", "massDeletion") to ("liveCount" to JsonValue.of(Long.MAX_VALUE)),
            listOf("halt", "recoveryClaim") to ("launchID" to JsonValue.of("not-a-uuid")),
        )
        for ((path, change) in cases) {
            val edited = document.edited(path) { it[change.first] = change.second }
            undecodable(edited.bytes(), "${dotted(path + change.first)} = ${change.second}")
        }
        val twoContexts = document.edited(listOf("halt", "recoveryContext")) {
            it["localLibraryQuarantine"] = JsonValue.Object(emptyMap())
        }
        assertEquals(StrictDecodeFailure.Kind.INVALID_VALUE, undecodable(twoContexts.bytes(), "two contexts").kind)
        val noContext = document.edited(listOf("halt")) { it["recoveryContext"] = JsonValue.Object(emptyMap()) }
        assertEquals(StrictDecodeFailure.Kind.INVALID_VALUE, undecodable(noContext.bytes(), "no context case").kind)
    }

    @Test
    fun everyOtherSchemaIsUnsupportedNeverDecoded() {
        for (version in listOf(-1L, 0L, 1L, 4L, 6L, 99L, 9_007_199_254_740_992L)) {
            val edited = document.edited(emptyList()) { it["schemaVersion"] = JsonValue.of(version) }
            assertEquals(SyncStateCodec.ReadResult.Unsupported(version), SyncStateCodec.read(edited.bytes()))
        }
        // Beyond 2^53 the probe's number is approximate, and still not this schema.
        val huge = document.edited(emptyList()) { it["schemaVersion"] = JsonValue.of(Long.MAX_VALUE / 2) }
        assertIs<SyncStateCodec.ReadResult.Unsupported>(SyncStateCodec.read(huge.bytes()))
        // A real-valued version is probed as its number, as Foundation's decoder reads it.
        val real = document.edited(emptyList()) { it["schemaVersion"] = JsonValue.of(6.0) }
        assertEquals(SyncStateCodec.ReadResult.Unsupported(6), SyncStateCodec.read(real.bytes()))
        val realCurrent = document.edited(emptyList()) { it["schemaVersion"] = JsonValue.of(5.0) }
        assertEquals(StrictDecodeFailure.Kind.WRONG_TYPE, undecodable(realCurrent.bytes(), "5.0").kind)
    }

    @Test
    fun everyTruncationAndTheEmptyFileAreNotJson() {
        val bytes = SyncStateCodec.encode(full)
        for (length in 0 until bytes.size) {
            val failure = undecodable(bytes.copyOf(length), "a truncation to $length bytes")
            assertEquals(StrictDecodeFailure.Kind.NOT_JSON, failure.kind, "length $length")
        }
        assertEquals(StrictDecodeFailure.Kind.NOT_JSON, undecodable(ByteArray(0), "empty").kind)
        assertEquals(StrictDecodeFailure.Kind.NOT_JSON, undecodable(utf8("{\"schemaVersion\":5,\"deviceID\":\"a1b2c3d4\",\"generation\":1,\"generation\":2}"), "duplicate key").kind)
        assertEquals(StrictDecodeFailure.Kind.NOT_JSON, undecodable(utf8("{\"schemaVersion\":5} trailing"), "trailing bytes").kind)
    }

    @Test
    fun aFailureNamesTheFormatNeverAValue() {
        val edited = document.edited(listOf("halt")) { it["reason"] = JsonValue.of("secret-looking-value") }
        val failure = undecodable(edited.bytes(), "unknown reason")
        assertTrue("secret-looking-value" !in (failure.message ?: ""))
        assertEquals("halt.reason", failure.path)
    }

    @Test
    fun encodingIsDeterministicAndIndependentOfArgumentOrder() {
        val forward = full.copy(halt = full.halt!!.copy(detail = HaltDetail.of("c", linkedMapOf("a" to "1", "b" to "2"))))
        val backward = full.copy(halt = full.halt!!.copy(detail = HaltDetail.of("c", linkedMapOf("b" to "2", "a" to "1"))))
        kotlin.test.assertContentEquals(SyncStateCodec.encode(forward), SyncStateCodec.encode(backward))
        assertEquals(forward, backward)
        assertEquals(UUID.fromString(testId(4).toString()), SyncStateCodec.decode(SyncStateCodec.encode(full)).promoting)
    }
}
