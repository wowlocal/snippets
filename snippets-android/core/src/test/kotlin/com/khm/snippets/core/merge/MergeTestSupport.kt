package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.wire.SyncEnvelope
import java.util.UUID

// Shared by the merge tests. Every body, id and key here is fictional public test data.

internal object MergeFixtures {

    /** `Date(timeIntervalSince1970: 1_785_312_000)` as seconds since 2001: the epoch of `SyncMergeTests.swift`. */
    const val EPOCH: Double = 807_004_800.0

    fun at(seconds: Double): Double = EPOCH + seconds

    /** Seconds since 1970 as seconds since 2001 (`Date(timeIntervalSince1970:)`). */
    fun unix(seconds: Double): Double = seconds - 978_307_200.0

    /** Ids laid out so their text order is `id(0) < id(1) < …`. */
    fun id(index: Int): UUID = UUID.fromString("00000000-0000-4000-8000-%012x".format(index))

    fun utf8(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

    fun hex(bytes: ByteArray): String = Bytes.toHex(bytes)

    fun unhex(text: String): ByteArray = Bytes.fromHex(text) ?: error("not hex")

    fun text(value: String): JsonValue = JsonValue.Text(value)

    fun parse(canonical: String): SyncEnvelope = SyncEnvelope.parse(utf8(canonical))

    fun canonical(envelope: SyncEnvelope): String = String(envelope.canonicalBytes(), Charsets.UTF_8)

    fun canonical(value: JsonValue): String = CanonicalJson.encodeToString(value)

    /** The envelope as another process would read it: parsed back from its canonical bytes. */
    fun reparsed(envelope: SyncEnvelope): SyncEnvelope = SyncEnvelope.parse(envelope.canonicalBytes())

    fun hlc(wallMs: Long, counter: Int = 0, device: String = "aaaaaaa1"): Hlc = Hlc.of(wallMs, counter, device)

    /** A live ordinary envelope whose clock and `updatedAt` follow [revision], as the Swift conflict suites build theirs. */
    fun plainEnvelope(
        id: UUID,
        revision: Long,
        device: String,
        content: String,
        name: String = "Shared snippet",
        keyword: String = "shared",
        tags: List<String> = emptyList(),
        isEnabled: Boolean = true,
        isPinned: Boolean = false,
        createdAt: Double = unix(1.0),
        updatedAt: Double = unix(revision / 1000.0),
        clockDevice: String = device,
        x: Map<String, JsonValue> = emptyMap(),
    ): SyncEnvelope = SyncEnvelope(
        id = id, hlc = Hlc.of(revision, 0, clockDevice), origin = device, secure = false, deleted = false,
        fields = SyncEnvelope.Fields(
            name = name, keyword = keyword, content = utf8(content), tags = tags,
            isEnabled = isEnabled, isPinned = isPinned, createdAt = createdAt, updatedAt = updatedAt,
        ),
        x = x,
    )

    /**
     * A live secure envelope. [sealed] stands for the vault's sealed text; the merge
     * never opens it, so any text will do.
     */
    fun secureEnvelope(
        id: UUID,
        revision: Long,
        device: String,
        sealed: String,
        contentHash: String?,
        vaultKid: String? = "11111111-2222-4333-8444-555555555555",
        name: String = "Secure snippet",
        keyword: String = "secure",
        tags: List<String> = emptyList(),
        isEnabled: Boolean = true,
        isPinned: Boolean = false,
        createdAt: Double = unix(1.0),
        updatedAt: Double = unix(revision / 1000.0),
        x: Map<String, JsonValue> = emptyMap(),
    ): SyncEnvelope {
        val extensions = LinkedHashMap(x)
        if (contentHash != null) extensions[SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY] = JsonValue.Text(contentHash)
        if (vaultKid != null) extensions[SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY] = JsonValue.Text(vaultKid)
        return SyncEnvelope(
            id = id, hlc = Hlc.of(revision, 0, device), origin = device, secure = true, deleted = false,
            fields = SyncEnvelope.Fields(
                name = name, keyword = keyword, content = utf8(sealed), tags = tags,
                isEnabled = isEnabled, isPinned = isPinned, createdAt = createdAt, updatedAt = updatedAt,
            ),
            x = extensions,
        )
    }

    fun snippet(
        id: UUID,
        name: String = "Name",
        keyword: String = "",
        content: String = "body",
        tags: List<String> = emptyList(),
        isEnabled: Boolean = true,
        isPinned: Boolean = false,
        createdAt: Double = at(0.0),
        updatedAt: Double = at(0.0),
    ): Snippet = Snippet(
        id = id, name = name, keyword = keyword, content = content, tags = tags,
        isEnabled = isEnabled, isPinned = isPinned, createdAt = createdAt, updatedAt = updatedAt,
    )

    /** The bodies of an outcome: the survivor's and every copy's. */
    fun bodies(outcome: EnvelopeMerge.Outcome): Set<String> {
        val all = ArrayList<SyncEnvelope>()
        outcome.survivor?.let(all::add)
        all.addAll(outcome.conflictCopies)
        return all.mapNotNull { envelope -> envelope.fields?.let { String(it.content, Charsets.UTF_8) } }.toSet()
    }

    /** Swift's `==` on two outcomes: envelopes by canonical equivalence of their text. */
    fun sameOutcome(first: EnvelopeMerge.Outcome, second: EnvelopeMerge.Outcome): Boolean {
        val a = first.survivor
        val b = second.survivor
        if ((a == null) != (b == null)) return false
        if (a != null && b != null && !SwiftSemantics.envelopesEqual(a, b)) return false
        if (first.conflictCopies.size != second.conflictCopies.size) return false
        return first.conflictCopies.indices.all {
            SwiftSemantics.envelopesEqual(first.conflictCopies[it], second.conflictCopies[it])
        }
    }

    /** Whether two outcomes are the same bytes. */
    fun sameBytes(first: EnvelopeMerge.Outcome, second: EnvelopeMerge.Outcome): Boolean =
        outcomeBytes(first) == outcomeBytes(second)

    fun outcomeBytes(outcome: EnvelopeMerge.Outcome): List<String?> =
        listOf(outcome.survivor?.let(::canonical)) + outcome.conflictCopies.map(::canonical)
}

/** The xorshift64 of the Swift suites (`SeededRandom`, `MergeRandom`), so a failure reproduces from its seed. */
internal class MergeRandom(seed: Long) {
    private var state: Long = if (seed == 0L) -0x61C8864680B583EBL else seed

    fun next(): Long {
        state = state xor (state shl 13)
        state = state xor (state ushr 7)
        state = state xor (state shl 17)
        return state
    }

    fun int(upperBound: Int): Int =
        if (upperBound <= 0) 0 else java.lang.Long.remainderUnsigned(next(), upperBound.toLong()).toInt()

    fun bool(): Boolean = int(2) == 0

    /** `true` once in [n]. */
    fun oneIn(n: Int): Boolean = int(n) == 0

    fun <T> pick(options: List<T>): T = options[int(options.size)]
}
