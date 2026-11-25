package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.sync.transport.SyncRecordVersion
import com.khm.snippets.core.wire.WireFixtures.at
import com.khm.snippets.core.wire.WireFixtures.clock
import com.khm.snippets.core.wire.WireFixtures.filled
import com.khm.snippets.core.wire.WireFixtures.id
import com.khm.snippets.core.wire.WireFixtures.snippet
import com.khm.snippets.core.wire.WireFixtures.utf8
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `WireTests.swift`, suite "Sealing a wire record", test for test, followed by
 * `wireVersionIsOpaqueTransportMetadataNotPartOfEncryptedIdentity` from
 * `SyncRecordCASTests.swift` and tamper tests on every field of the record and its blob.
 */
class WireCodecTest {

    private val thisDevice = WireFixtures.THIS_DEVICE

    @Test fun sealingAndOpeningIsLossless() {
        val sealer = TestSealer()
        val envelope = SyncEnvelope.plain(
            snippet(1, content = "Best,\nMike"), hlc = clock(1_234, counter = 7), origin = thisDevice,
        )

        val record = WireCodec.seal(envelope, sealer)
        assertEquals(envelope, WireCodec.open(record, sealer))
        assertNull(record.recordVersion, "only a backend assigns a generation")
    }

    /**
     * The four fields are the entire outside of the record. The crude test proves it: look
     * for the plaintext in the bytes that leave.
     */
    @Test fun nothingButIdRevAndTheDeletionFlagIsReadableFromOutsideTheBlob() {
        val sealer = TestSealer()
        val envelope = SyncEnvelope.secureRecord(
            id = id(9), name = "Router admin", keyword = "rtr",
            plaintext = utf8("hunter2"), tags = listOf("infra"),
            createdAt = at(1.0), updatedAt = at(2.0), hlc = clock(3_000), origin = thisDevice,
        )

        val record = WireCodec.seal(envelope, sealer)
        val onTheWire = record.blob + utf8(record.rev) + utf8(Uuids.uppercase(record.id))
        val text = String(onTheWire, Charsets.UTF_8)

        for (secret in listOf("hunter2", "Router admin", "rtr", "infra", thisDevice)) {
            assertFalse(text.contains(secret), "\"$secret\" is legible on the wire")
        }
        assertFalse(record.deleted, "the deletion flag is the one thing left in the clear")
    }

    /** A backend that moves a blob onto another id must fail, not overwrite the wrong snippet. */
    @Test fun aBlobMovedOntoAnotherRecordIdWillNotOpen() {
        val sealer = TestSealer()
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
        val record = WireCodec.seal(envelope, sealer).copy(id = id(2))

        assertFailsWith<Exception> { WireCodec.open(record, sealer) }
    }

    /** Flipping the clear-text deletion flag must not turn a live record into a tombstone. */
    @Test fun flippingTheClearTextDeletionFlagWillNotOpen() {
        val sealer = TestSealer()
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
        val record = WireCodec.seal(envelope, sealer).copy(deleted = true)

        assertFailsWith<Exception> { WireCodec.open(record, sealer) }
    }

    @Test fun aBlobResealedUnderAnotherKeyWillNotOpen() {
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
        val record = WireCodec.seal(envelope, TestSealer(seed = 1))

        assertFailsWith<Exception> { WireCodec.open(record, TestSealer(seed = 2)) }
    }

    /**
     * A deterministic rev is what makes re-pushing unchanged content a no-op. A random one
     * would make every sync look like a change to every other device.
     */
    @Test fun revIsDeterministicInTheContentAndMovesWhenTheContentDoes() {
        val sealer = TestSealer()
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
        val edited = SyncEnvelope.plain(snippet(1, content = "changed"), hlc = clock(1_000), origin = thisDevice)

        val first = WireCodec.seal(envelope, sealer)
        val second = WireCodec.seal(envelope, sealer)
        val third = WireCodec.seal(edited, sealer)

        assertEquals(first.rev, second.rev)
        assertNotEquals(first.rev, third.rev)
        assertEquals(envelope.envelopeHash().take(32), first.rev)
        assertEquals(32, first.rev.length)
        // The ciphertext still differs: the nonce is fresh every time.
        assertFalse(first.blob.contentEquals(second.blob))
    }

    /** The same contract through the sealer that ships. */
    @Test fun theShippingSealerHonoursTheSameContract() {
        val sealer = productionSealer()
        val envelope = SyncEnvelope.secureRecord(
            id = id(6), name = "Router admin", keyword = "rtr",
            plaintext = utf8("hunter2"), createdAt = at(1.0), updatedAt = at(2.0),
            hlc = clock(3_000), origin = thisDevice,
        )

        val record = WireCodec.seal(envelope, sealer)
        assertEquals(envelope, WireCodec.open(record, sealer))

        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { WireCodec.open(record.copy(id = id(7)), sealer) }
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            WireCodec.open(record.copy(deleted = true), sealer)
        }
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
            WireCodec.open(record, productionSealer(seed = 9))
        }
    }

    /**
     * `SnippetCrypto` pads to 256-byte boundaries. The envelope wraps the body in JSON, and
     * a wire layer that leaked length would undo the padding without anyone noticing.
     */
    @Test fun theWireDoesNotPublishThePreciseLengthOfASecret() {
        val sealer = productionSealer()

        val sizes = listOf(1, 2, 3, 40).map { count ->
            val envelope = SyncEnvelope.secureRecord(
                id = id(6), name = "n", keyword = "k",
                plaintext = filled('x'.code, count),
                createdAt = at(1.0), updatedAt = at(2.0), hlc = clock(3_000), origin = thisDevice,
            )
            WireCodec.seal(envelope, sealer).blobByteCount
        }

        assertEquals(1, sizes.toSet().size, "blob size tracked the secret's length: $sizes")
    }

    @Test fun aTombstoneSealsAndOpensWithNoFields() {
        val sealer = TestSealer()
        val envelope = SyncEnvelope.tombstone(id = id(4), secure = true, hlc = clock(5_000), origin = thisDevice)

        val record = WireCodec.seal(envelope, sealer)
        assertTrue(record.deleted)

        val reopened = WireCodec.open(record, sealer)
        assertNull(reopened.fields)
        assertTrue(reopened.secure, "which store the record left is still needed to remove it")
    }

    // SyncRecordCASTests.swift

    @Test fun wireVersionIsOpaqueTransportMetadataNotPartOfEncryptedIdentity() {
        val sealer = PassthroughSealer()
        val confirmed = SyncEnvelope(
            id = Uuids.parse("abcdef12-1212-4212-8212-abcdef121212")!!,
            hlc = clock(100, device = "aaaaaaa1"),
            origin = "aaaaaaa1",
            secure = false,
            deleted = false,
            fields = SyncEnvelope.Fields(
                name = "confirmed", keyword = "versioned", content = utf8("confirmed"), tags = emptyList(),
                isEnabled = true, isPinned = false, createdAt = -978_307_199.0, updatedAt = -978_307_199.0,
            ),
        )
        val sealed = WireCodec.seal(confirmed, sealer)
        val originalIdentity = WireIdentity(id = sealed.id, rev = sealed.rev, deleted = sealed.deleted)

        val wire = sealed.copy(recordVersion = SyncRecordVersion(utf8("backend-private-state")))

        assertEquals(confirmed, WireCodec.open(wire, sealer))
        assertEquals(originalIdentity, WireIdentity(id = wire.id, rev = wire.rev, deleted = wire.deleted))
        assertNotEquals(sealed, wire, "the generation is still part of the record's value")
    }

    // The post-open checks, each with the failure it reports

    @Test fun eachPostOpenCheckReportsAnIdentityMismatch() {
        // A sealer that authenticates nothing, so only WireCodec's own checks stand.
        val sealer = PassthroughSealer()
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
        val record = WireCodec.seal(envelope, sealer)

        val moved = assertFailsWith<SyncEnvelope.Failure.IdentityMismatch> {
            WireCodec.open(record.copy(id = id(2)), sealer)
        }
        assertEquals(
            "blob is for 00000000-0000-4000-8000-000000000001, record is 00000000-0000-4000-8000-000000000002",
            moved.detail,
        )

        val flipped = assertFailsWith<SyncEnvelope.Failure.IdentityMismatch> {
            WireCodec.open(record.copy(deleted = true), sealer)
        }
        assertEquals("deletion flag disagrees with the blob", flipped.detail)

        for (rev in listOf("0".repeat(32), envelope.envelopeHash(), record.rev.uppercase(), record.rev.dropLast(1), "")) {
            val rolledBack = assertFailsWith<SyncEnvelope.Failure.IdentityMismatch>(rev) {
                WireCodec.open(record.copy(rev = rev), sealer)
            }
            assertEquals("rev does not describe the blob", rolledBack.detail)
        }
    }

    /**
     * Hazard H27: with the shipping sealer `rev` is not in the associated data. A record
     * whose rev was edited still authenticates, and is refused by the comparison after
     * opening, never by the cipher.
     */
    @Test fun theShippingSealerDoesNotAuthenticateRevAndTheCodecChecksItAfterOpening() {
        val sealer = productionSealer()
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
        val record = WireCodec.seal(envelope, sealer)
        val edited = record.copy(rev = "f".repeat(32))

        // The cipher accepts the blob under the edited rev: the plaintext comes back.
        val identity = WireIdentity(id = edited.id, rev = edited.rev, deleted = edited.deleted)
        assertContentEquals(envelope.canonicalBytes(), sealer.open(edited.blob, identity))
        // The codec does not.
        val failure = assertFailsWith<SyncEnvelope.Failure.IdentityMismatch> { WireCodec.open(edited, sealer) }
        assertEquals("rev does not describe the blob", failure.detail)

        // And the associated data is SnippetCrypto's, not `WireIdentity.associatedData()`.
        assertEquals(
            "{\"deleted\":false,\"id\":\"00000000-0000-4000-8000-000000000001\",\"rev\":\"${record.rev}\"}",
            String(WireIdentity(record.id, record.rev, record.deleted).associatedData(), Charsets.UTF_8),
        )
    }

    @Test fun aRevisionTokenIsThePrefixOfTheHashInSwiftCharacters() {
        val sealer = PassthroughSealer()
        assertEquals("a".repeat(32), sealer.revisionToken("a".repeat(64)))
        assertEquals("abc", sealer.revisionToken("abc"))
        assertEquals("", sealer.revisionToken(""))
        // `prefix(32)` counts Characters: 32 flags are 64 scalars and 128 UTF-16 units.
        val flags = "🇫🇷".repeat(40)
        assertEquals("🇫🇷".repeat(32), sealer.revisionToken(flags))
    }

    // Tampering with the blob

    @Test fun everyAlteredByteOfAShippingBlobIsRefused() {
        val sealer = productionSealer()
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
        val record = WireCodec.seal(envelope, sealer)
        val blob = record.blob
        val text = String(blob, Charsets.US_ASCII)
        assertTrue(text.startsWith("v1."))
        // Both base64url fields are whole groups of four here, so no symbol has unused bits
        // and every altered symbol alters the decoded bytes.
        assertEquals(listOf(0, 0), text.split('.').drop(1).map { it.length % 4 })

        // Every position: the version, both separators, the nonce, the body and the tag.
        for (index in blob.indices) {
            val altered = blob.copyOf()
            // Stay inside the base64url alphabet where possible, so the cipher is what refuses.
            altered[index] = if (altered[index] == 'A'.code.toByte()) 'B'.code.toByte() else 'A'.code.toByte()
            if (altered.contentEquals(blob)) continue
            assertFailsWith<Exception>("byte $index") { WireCodec.open(record.copy(blob = altered), sealer) }
        }
    }

    @Test fun aTruncatedExtendedOrReframedBlobIsRefused() {
        val sealer = productionSealer()
        val envelope = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
        val record = WireCodec.seal(envelope, sealer)
        val text = String(record.blob, Charsets.US_ASCII)
        val parts = text.split('.')
        assertEquals(3, parts.size)

        val malformed = listOf(
            "",                                             // nothing
            "v1",                                           // no fields
            "${parts[0]}.${parts[1]}",                      // no body
            "$text.extra",                                  // a fourth field
            "${parts[0]}..${parts[2]}",                     // empty nonce
            "${parts[0]}.${parts[1]}.",                     // empty body
            "${parts[0]}.${parts[1]}=.${parts[2]}",         // padded base64
            "${parts[0]}.${parts[1]}.${parts[2]}==",        // padded base64
            "${parts[0]}.${parts[1]}.${parts[2].replace('-', '+').replace('_', '/')}+",  // the standard alphabet
            "${parts[0]}.${parts[1]}.${parts[2]}\n",        // trailing newline
            "${parts[0]}.${parts[1]}.${parts[2].take(8)}",  // too short for a tag
        )
        for (candidate in malformed) {
            assertFailsWith<SnippetCrypto.Failure.MalformedEnvelope>(candidate.take(24)) {
                WireCodec.open(record.copy(blob = utf8(candidate)), sealer)
            }
        }

        // The version field is compared as it stands: another version, or `v1` with a space.
        for (version in listOf("v2", " v1", "V1", "")) {
            assertFailsWith<SnippetCrypto.Failure.UnsupportedWireVersion>(version) {
                WireCodec.open(record.copy(blob = utf8("$version.${parts[1]}.${parts[2]}")), sealer)
            }
        }
        // A shorter or longer body that is still base64url fails authentication.
        for (body in listOf(parts[2].dropLast(4), parts[2] + "AAAA")) {
            assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> {
                WireCodec.open(record.copy(blob = utf8("${parts[0]}.${parts[1]}.$body")), sealer)
            }
        }
        // Not text at all.
        val failure = assertFailsWith<SnippetCrypto.Failure.MalformedEnvelope> {
            WireCodec.open(record.copy(blob = byteArrayOf(0xFF.toByte(), 0xFE.toByte())), sealer)
        }
        assertEquals("blob is not a SnippetCrypto envelope", failure.detail)
    }

    @Test fun aBlobThatOpensToSomethingElseThanAnEnvelopeIsRefused() {
        val sealer = PassthroughSealer()
        val target = id(1)
        fun record(plaintext: String) = WireRecord(id = target, rev = "0".repeat(32), deleted = false, blob = utf8(plaintext))

        assertFailsWith<CanonicalJson.Failure.UnexpectedEnd> { WireCodec.open(record(""), sealer) }
        assertFailsWith<CanonicalJson.Failure.UnexpectedByte> { WireCodec.open(record("not json"), sealer) }
        assertFailsWith<SyncEnvelope.Failure.Malformed> { WireCodec.open(record("[]"), sealer) }
        assertFailsWith<SyncEnvelope.Failure.Malformed> { WireCodec.open(record("{}"), sealer) }
        assertFailsWith<SyncEnvelope.Failure.TooNew> { WireCodec.open(record("{\"schemaVersion\":2}"), sealer) }
    }

    // WireRecord is a value

    @Test fun aWireRecordIsAnImmutableValueThatComparesItsBlobByContent() {
        val source = utf8("blob bytes")
        val record = WireRecord(id = id(1), rev = "r1", deleted = false, blob = source)

        source[0] = 0   // the caller's array is not the record's
        assertContentEquals(utf8("blob bytes"), record.blob)
        record.blob[0] = 0   // nor is the array it hands out
        assertContentEquals(utf8("blob bytes"), record.blob)
        assertEquals(10, record.blobByteCount)

        val same = WireRecord(id = id(1), rev = "r1", deleted = false, blob = utf8("blob bytes"))
        assertEquals(record, same)
        assertEquals(record.hashCode(), same.hashCode())
        assertNotEquals(record, same.copy(blob = utf8("blob bytez")))
        assertNotEquals(record, same.copy(rev = "r2"))
        assertNotEquals(record, same.copy(deleted = true))
        assertNotEquals(record, same.copy(id = id(2)))
        assertNotEquals(record, same.copy(recordVersion = SyncRecordVersion(byteArrayOf(1))))
        assertEquals(record.copy(recordVersion = SyncRecordVersion(byteArrayOf(1))), same.copy(recordVersion = SyncRecordVersion(byteArrayOf(1))))

        // Nothing of the blob in the description.
        assertFalse(record.toString().contains("blob bytes"))
    }

    @Test fun anEnvelopeWithNoCanonicalFormCannotBeSealed() {
        val sealer = PassthroughSealer()
        val notANumber = SyncEnvelope.plain(snippet(1), hlc = clock(1_000), origin = thisDevice)
            .withExtension("future", JsonValue.of(Double.NaN))
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { WireCodec.seal(notANumber, sealer) }
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { notANumber.envelopeHash() }
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { notANumber.canonicalBytes() }

        val invalidBody = SyncEnvelope.secureRecord(
            id = id(1), name = "n", keyword = "k", plaintext = byteArrayOf(0xC0.toByte(), 0x80.toByte()),
            createdAt = at(1.0), updatedAt = at(2.0), hlc = clock(1_000), origin = thisDevice,
        )
        assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { WireCodec.seal(invalidBody, sealer) }
    }
}
