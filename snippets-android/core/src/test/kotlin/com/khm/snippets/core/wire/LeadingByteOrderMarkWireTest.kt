package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.model.Snippet
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * Review finding D1 on the wire. Swift reads text back with `String(data:encoding: .utf8)`,
 * which drops one leading U+FEFF, so the port must neither write a name, keyword or tag that
 * starts with one, nor read one differently from Swift.
 */
class LeadingByteOrderMarkWireTest {

    private val hlc = Hlc.parse("019face339f4-0003-a1b2c3d4")!!
    private val id = UUID.fromString("00000000-0000-4000-8000-000000000005")

    private fun fields(name: String, keyword: String, tags: List<String>, body: ByteArray = "body".toByteArray()) =
        SyncEnvelope.Fields(
            name = name, keyword = keyword, content = body, tags = tags,
            isEnabled = true, isPinned = false, createdAt = 1.0, updatedAt = 2.0,
        )

    @Test fun newFieldsDropEveryLeadingBomFromTheTextMembersAndNoneFromTheBody() {
        val body = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte(), 'x'.code.toByte())
        val made = fields("\uFEFF\uFEFFRouter", "\uFEFFrtr", listOf("\uFEFFhome", "net\uFEFF"), body)
        assertEquals("Router", made.name)
        assertEquals("rtr", made.keyword)
        assertEquals(listOf("home", "net\uFEFF"), made.tags)
        assertContentEquals(body, made.content)
    }

    @Test fun whatThePortWritesItReadsBackAsWrittenThroughEveryConstructor() {
        val snippet = Snippet(
            id = id, name = "\uFEFFRouter", keyword = "\uFEFFrtr", content = "\uFEFFbody",
            tags = listOf("\uFEFFhome"), isEnabled = true, isPinned = false, createdAt = 1.0, updatedAt = 2.0,
        )
        for (envelope in listOf(
            SyncEnvelope.plain(snippet, hlc, "a1b2c3d4"),
            SyncEnvelope.secureRecord(
                id = id, name = "\uFEFFRouter", keyword = "\uFEFFrtr", plaintext = "sealed".toByteArray(),
                tags = listOf("\uFEFFhome"), createdAt = 1.0, updatedAt = 2.0, hlc = hlc, origin = "a1b2c3d4",
            ),
        )) {
            val parsed = SyncEnvelope.parse(envelope.canonicalBytes())
            assertEquals("Router", parsed.fields!!.name)
            assertEquals("rtr", parsed.fields!!.keyword)
            assertEquals(listOf("home"), parsed.fields!!.tags)
            assertEquals(envelope.envelopeHash(), parsed.envelopeHash())
        }
    }

    @Test fun anEnvelopeThatHashedABomIsRefusedAsSwiftRefusesIt() {
        // Built with `copy`, which keeps members as given: the bytes another writer could produce.
        val written = SyncEnvelope(
            id = id, hlc = hlc, origin = "a1b2c3d4", secure = false, deleted = false,
            fields = fields("Router", "rtr", emptyList()).copy(name = "\uFEFFRouter"),
        )
        assertFailsWith<SyncEnvelope.Failure.HashMismatch> { SyncEnvelope.parse(written.canonicalBytes()) }
    }

    @Test fun thePlainSnippetViewDropsOneLeadingBomOfTheBodyAsSwiftDoes() {
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        val envelope = SyncEnvelope(
            id = id, hlc = hlc, origin = "a1b2c3d4", secure = false, deleted = false,
            fields = fields("n", "k", emptyList(), bom + bom + "x".toByteArray()),
        )
        assertEquals("\uFEFFx", envelope.plainSnippet!!.content)
    }

    @Test fun anObjectKeyWithABomIsTheKeyWithoutIt() {
        val parsed = CanonicalJson.parse("{\"\uFEFFa\":1}".toByteArray())
        assertEquals(setOf("a"), parsed.objectOrNull!!.keys)
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { CanonicalJson.parse("{\"\\ufeffa\":1,\"a\":2}".toByteArray()) }
        // Two marks: one is dropped, one stays.
        assertEquals(setOf("\uFEFFa"), CanonicalJson.parse("{\"\uFEFF\uFEFFa\":1}".toByteArray()).objectOrNull!!.keys)
        assertEquals("x", JsonValue.Utf8("\uFEFFx".toByteArray()).textOrNull)
    }

    // The bundle reader ports `JSONSerialization` (drops a key's BOM) then `JSONDecoder` (keeps it).

    private val key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    private val salt = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="

    private fun bundle(schemaKey: String = "schemaVersion", scope: String = "sync-v1", extra: String = "") =
        "{\"$schemaKey\":1,\"scopeID\":\"$scope\",\"key\":\"$key\",\"salt\":\"$salt\"$extra}".toByteArray()

    @Test fun aBundleKeyWithABomIsMissingAsJsonDecoderSeesIt() {
        PortableKeyBundle.fromJson(bundle()).close()
        // JSONSerialization's key set is right, JSONDecoder finds no `schemaVersion`: keyNotFound.
        assertFailsWith<PortableKeyBundle.Failure.Undecodable> { PortableKeyBundle.fromJson(bundle(schemaKey = "\uFEFFschemaVersion")) }
        // Both spellings: JSONSerialization sees four keys, JSONDecoder reads the plain one.
        PortableKeyBundle.fromJson(bundle(extra = ",\"\uFEFFkey\":\"x\"")).close()
        // A key with two marks keeps one for JSONSerialization too: wrong key set.
        assertFailsWith<PortableKeyBundle.Failure.InvalidFormat> {
            PortableKeyBundle.fromJson(bundle(schemaKey = "\uFEFF\uFEFFschemaVersion"))
        }
        // JSONDecoder keeps the mark in a value: not the sync scope.
        assertFailsWith<PortableKeyBundle.Failure.InvalidFormat> { PortableKeyBundle.fromJson(bundle(scope = "\uFEFFsync-v1")) }
    }
}
