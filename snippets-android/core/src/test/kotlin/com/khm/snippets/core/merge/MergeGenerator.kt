package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.wire.SyncEnvelope
import java.util.UUID

/**
 * Realistic and adversarial merge inputs, reproducible from a seed. Used by the property
 * tests (`MergeAlgebraTest`) and by the Swift differential (`MergeDifferentialTest`), so
 * both look at the same kind of input.
 *
 * Every envelope is returned as another device would read it: built, written as
 * canonical bytes and parsed back. A candidate that canonical JSON cannot spell (two `x`
 * keys that differ only in normalization, say) is dropped and drawn again.
 *
 * What it reaches for: shared prefixes, equal clocks and equal timestamps across sides,
 * `0.0` against `-0.0`, text in NFC and NFD, tags differing by case or diacritics or only
 * in their order, unnormalized tag lists as the wire may carry them, secure/ordinary
 * flips, vault members present, missing, of another type or spelled with U+212A KELVIN
 * SIGN, tombstones with and without `userDeletion.v1`, unknown `x` members, opaque future
 * conflict members, valid secure variants, provenance markers and the odd malformed
 * reserved key. Every body and name is fictional public test data.
 */
internal class MergeGenerator(seed: Long) {

    val random = MergeRandom(seed)

    companion object {
        val IDS: List<UUID> = listOf(
            UUID.fromString("00000000-0000-4000-8000-000000000021"),
            UUID.fromString("a11ce002-0000-4000-8000-000000000001"),
            UUID.fromString("f0000000-0000-4000-8000-00000000000f"),
        )
        val DEVICES = listOf("aaaaaaa1", "bbbbbbb2", "0a0b0c0d")
        val NAMES = listOf(
            "Shared snippet", "Shared snippet A", "Shared snippet B", "Café", "Café", "", "  ",
            "  padded name \n", "👨‍👩‍👧 family", "race", "Ωmega", "ｆｕｌｌ",
        )
        val KEYWORDS = listOf("", "shared", "Shared", "sig", "café", "café", " spaced key ", "\\esc", "SIG")
        val BODIES = listOf(
            "", "body", "body\n", "Body", "﻿body", "café", "café", "\n \r\n  first line after blanks\nsecond",
            "x".repeat(70) + " long line", "👨‍👩‍👧‍👦".repeat(51),
            "shared prefix", "shared prefix plus", "line1 line2", "audit-concurrent-macos", "  \t ",
        )
        val TAGS = listOf(
            "work", "Work", "WORK", "urgent", "draft", "café", "café", "Cafe", "CAFÉ", "  spaced   tag ",
            "a", "b", "x", "y", "z", "Kelvin", "Kelvin", "ﬁle", "file", "Σίσυφος",
            "각", "각", "ǅ", "conflict", "ẹ́", "ẹ́", "",
            // Keys Foundation folds to text that is not in NFC, where Swift's `<` is not an
            // order (see FoundationText.compare): Devanagari nukta letters, Arabic madda,
            // Tibetan vowel signs.
            "क़", "क़", "क", "آ", "آ", "ا", "ཱི", "ཱི",
            "ྲྀ", "ཱྀ",
        )
        val TIMES = listOf(
            0.0, -0.0, 120.0, 59.9994, 59.9995, -60.0, 812_742_226.219845, 812_742_230.7082067, 807_004_800.0,
            1.5, 1e-300, 946_080_000.0, -0.0006,
        )
        val VAULT_HASHES = listOf("hash-a", "hash-b", "same-original-hash")
        val VAULT_KIDS = listOf("11111111-2222-4333-8444-555555555555", "vault-other")
        private const val KELVIN_VAULT_KID = "vaultKID"
        private val HEX = "0123456789abcdef"
    }

    // Primitives

    fun <T> pick(options: List<T>): T = random.pick(options)

    private fun hex64(): String = buildString { repeat(64) { append(HEX[random.int(16)]) } }

    fun hlc(): Hlc = Hlc.of(listOf(100L, 200L, 300L, 300L, 1_000L)[random.int(5)], if (random.oneIn(4)) 1 else 0, pick(DEVICES))

    fun time(): Double = if (random.oneIn(40)) pick(listOf(-2e10, 3e11)) else pick(TIMES)

    fun tags(): List<String> {
        val count = random.int(4)
        val out = ArrayList<String>()
        repeat(count) { out.add(pick(TAGS)) }
        return out
    }

    private fun futureValue(): JsonValue = when (random.int(7)) {
        0 -> JsonValue.Text("Public future value")
        1 -> JsonValue.Integer(7)
        2 -> JsonValue.Real(-0.0)
        3 -> JsonValue.Real(1.5)
        4 -> JsonValue.obj("nested" to JsonValue.array(JsonValue.Null, JsonValue.Bool(true)))
        5 -> JsonValue.Text("café")
        else -> JsonValue.array()
    }

    // Envelopes

    private fun fields(): SyncEnvelope.Fields {
        val fields = SyncEnvelope.Fields(
            name = pick(NAMES), keyword = pick(KEYWORDS), content = MergeFixtures.utf8(pick(BODIES)), tags = tags(),
            isEnabled = !random.oneIn(4), isPinned = random.oneIn(4), createdAt = time(), updatedAt = time(),
        )
        // Tags as the wire may carry them: not normalized.
        return if (random.oneIn(6)) fields.copy(tags = tags()) else fields
    }

    private fun mutate(fields: SyncEnvelope.Fields): SyncEnvelope.Fields {
        var result = fields
        if (random.oneIn(3)) result = result.copy(name = pick(NAMES))
        if (random.oneIn(4)) result = result.copy(keyword = pick(KEYWORDS))
        if (random.oneIn(2)) result = result.copy(content = MergeFixtures.utf8(pick(BODIES)))
        if (random.oneIn(3)) {
            result = when (random.int(3)) {
                0 -> result.copy(tags = tags())
                1 -> result.copy(tags = result.tags.shuffled(java.util.Random(random.next())))
                else -> result.copy(tags = result.tags + pick(TAGS))
            }
        }
        if (random.oneIn(5)) result = result.copy(isEnabled = !result.isEnabled)
        if (random.oneIn(5)) result = result.copy(isPinned = !result.isPinned)
        if (random.oneIn(4)) result = result.copy(createdAt = time())
        if (!random.oneIn(4)) result = result.copy(updatedAt = time())
        return result
    }

    private fun extras(id: UUID, secure: Boolean): LinkedHashMap<String, JsonValue> {
        val x = LinkedHashMap<String, JsonValue>()
        if (secure) {
            if (!random.oneIn(6)) x[SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY] = JsonValue.Text(pick(VAULT_HASHES))
            when (random.int(12)) {
                0 -> {}
                1 -> x[KELVIN_VAULT_KID] = JsonValue.Text(pick(VAULT_KIDS))
                2 -> x[SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY] = JsonValue.Integer(3)
                else -> x[SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY] = JsonValue.Text(pick(VAULT_KIDS))
            }
        } else if (random.oneIn(10)) {
            // Stale routing on an ordinary record, which a merge must not carry forward.
            x[SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY] = JsonValue.Text("obsolete-vault")
        }
        if (random.oneIn(4)) x["futureMetadata"] = futureValue()
        if (random.oneIn(12)) x[if (random.bool()) "café" else "café"] = futureValue()
        if (random.oneIn(14)) {
            x[ConflictCopies.PLAIN_CONFLICT_COPY_EXTENSION_KEY] =
                if (random.oneIn(4)) JsonValue.Integer(1) else ConflictCopies.conflictCopyProvenance(pick(IDS), hex64())
        }
        if (random.oneIn(14)) x["contentConflict.v2.${"ab".repeat(32)}"] = JsonValue.Text("Opaque future fixture")
        if (random.oneIn(9)) variant(id)?.let { (key, value) -> x[key] = value }
        if (random.oneIn(60)) x["contentConflict.invalid"] = JsonValue.Null
        return x
    }

    /** A valid secure variant of some other version of record [id], mostly. */
    private fun variant(id: UUID): Pair<String, JsonValue>? {
        val source = buildEnvelope {
            SyncEnvelope(
                id = id, hlc = hlc(), origin = pick(DEVICES), secure = true, deleted = false, fields = fields(),
                x = mapOf(
                    SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY to JsonValue.Text("variant-${random.int(3)}"),
                    SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY to JsonValue.Text(pick(VAULT_KIDS)),
                ),
            )
        } ?: return null
        val made = ConflictCopies.makeSecureContentConflictVariant(source)
        // Now and then a member that a newer device could not have written.
        if (random.oneIn(10)) {
            val members = LinkedHashMap(made.second.objectOrNull!!)
            members["version"] = JsonValue.Real(1.0)
            return made.first to JsonValue.Object(members)
        }
        return made
    }

    /** Built, encoded and parsed back; `null` when canonical JSON cannot spell it. */
    fun buildEnvelope(build: () -> SyncEnvelope): SyncEnvelope? = try {
        SyncEnvelope.parse(build().canonicalBytes())
    } catch (_: CanonicalJson.Failure) {
        null
    } catch (_: SyncEnvelope.Failure) {
        null
    }

    private fun schemaVersion(): Long = if (random.oneIn(25)) pick(listOf(0L, -3L)) else 1L

    fun live(id: UUID, secure: Boolean = random.oneIn(4)): SyncEnvelope {
        while (true) {
            return buildEnvelope {
                SyncEnvelope(
                    id = id, hlc = hlc(), origin = pick(DEVICES), secure = secure, deleted = false,
                    fields = fields(), x = extras(id, secure), schemaVersion = schemaVersion(),
                )
            } ?: continue
        }
    }

    /** Another version of [from]: some fields moved, a new clock, perhaps a flip of `secure`. */
    fun edit(from: SyncEnvelope): SyncEnvelope {
        val fields = from.fields ?: return live(from.id)
        while (true) {
            val secure = if (random.oneIn(8)) !from.secure else from.secure
            return buildEnvelope {
                val x = if (random.oneIn(3)) extras(from.id, secure) else LinkedHashMap(from.x).also {
                    if (secure != from.secure) it.putAll(extras(from.id, secure))
                    if (secure && random.oneIn(3)) {
                        it[SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY] = JsonValue.Text(pick(VAULT_HASHES))
                    }
                }
                SyncEnvelope(
                    id = from.id, hlc = if (random.oneIn(6)) from.hlc else hlc(),
                    origin = if (random.oneIn(5)) from.origin else pick(DEVICES),
                    secure = secure, deleted = false, fields = mutate(fields), x = x, schemaVersion = schemaVersion(),
                )
            } ?: continue
        }
    }

    fun tombstone(of: SyncEnvelope): SyncEnvelope {
        while (true) {
            return buildEnvelope {
                val deletion = of.tombstoned(hlc(), pick(DEVICES))
                val x = LinkedHashMap(deletion.x)
                if (random.bool()) {
                    val hashes = ArrayList<JsonValue>()
                    if (!of.deleted) hashes.add(JsonValue.Text(of.envelopeHash()))
                    if (hashes.isEmpty() || random.oneIn(3)) hashes.add(JsonValue.Text(hex64()))
                    x[SyncEnvelope.USER_INITIATED_DELETION_EXTENSION_KEY] = JsonValue.Array(hashes)
                }
                deletion.copy(x = x)
            } ?: continue
        }
    }

    /** One (base, local, remote) triple of one record. */
    fun triple(): Triple<SyncEnvelope?, SyncEnvelope?, SyncEnvelope?> {
        val id = pick(IDS)
        val ancestor = live(id)
        val base: SyncEnvelope? = when (random.int(20)) {
            in 0..3 -> null
            4 -> tombstone(ancestor)
            5, 6 -> edit(ancestor)
            else -> ancestor
        }
        fun side(): SyncEnvelope? = when (random.int(20)) {
            0, 1 -> null
            2, 3 -> ancestor
            in 4..6 -> tombstone(ancestor)
            7 -> live(id)
            else -> edit(ancestor)
        }
        val local = side()
        var remote = side()
        when (random.int(12)) {
            0 -> remote = local
            1 -> if (local != null && !local.deleted) remote = edit(local)
            2 -> if (local != null && remote != null && !local.deleted && !remote.deleted) {
                // Same clock on both sides, the case only the canonical rank can decide.
                remote = buildEnvelope { remote!!.copy(hlc = local.hlc, origin = local.origin) } ?: remote
            }
        }
        return Triple(base, local, remote)
    }

    // Tags

    fun tagTriple(): TagCase {
        val base = if (random.oneIn(5)) null else tags()
        fun side(): List<String> = when (random.int(4)) {
            0 -> base ?: tags()
            1 -> (base ?: emptyList()) + tags()
            2 -> (base ?: tags()).shuffled(java.util.Random(random.next()))
            else -> tags()
        }
        return TagCase(base, side(), side(), random.bool())
    }

    data class TagCase(val base: List<String>?, val local: List<String>, val remote: List<String>, val localWins: Boolean)

    // Snippets

    data class LocalCase(val base: List<Snippet>, val local: List<Snippet>, val remote: List<Snippet>)

    private fun snippet(id: UUID): Snippet = Snippet(
        id = id, name = pick(NAMES), keyword = pick(KEYWORDS), content = pick(BODIES), tags = tags(),
        isEnabled = !random.oneIn(5), isPinned = random.oneIn(5), createdAt = time(), updatedAt = time(),
    )

    private fun mutate(snippet: Snippet): Snippet {
        var result = snippet
        if (random.oneIn(3)) result = result.copy(name = pick(NAMES))
        if (random.oneIn(3)) result = result.copy(keyword = pick(KEYWORDS))
        if (random.oneIn(2)) result = result.copy(content = pick(BODIES))
        if (random.oneIn(3)) result = result.copy(tags = if (random.bool()) tags() else result.tags.reversed())
        if (random.oneIn(5)) result = result.copy(isEnabled = !result.isEnabled)
        if (random.oneIn(6)) result = result.copy(isPinned = !result.isPinned)
        if (random.oneIn(3)) result = result.copy(createdAt = time())
        if (!random.oneIn(3)) result = result.copy(updatedAt = time())
        return result
    }

    fun localCase(): LocalCase {
        val ids = (0 until 2 + random.int(5)).map { MergeFixtures.id(random.int(8)) }.distinct()
        val base = ArrayList<Snippet>()
        val local = ArrayList<Snippet>()
        val remote = ArrayList<Snippet>()
        for (id in ids) {
            val ancestor = snippet(id)
            val hasBase = !random.oneIn(4)
            if (hasBase) base.add(ancestor)
            for (side in arrayOf(local, remote)) {
                if (random.oneIn(6)) continue
                side.add(if (random.oneIn(3)) ancestor else mutate(ancestor))
            }
        }
        // An id twice in one list: the first occurrence counts.
        if (random.oneIn(10) && local.isNotEmpty()) local.add(mutate(local[0]))
        if (random.bool()) local.shuffle(java.util.Random(random.next()))
        return LocalCase(base, local, remote)
    }

    // Conflict-name stamps

    fun stamp(): Double = when (random.int(6)) {
        // Around a minute boundary, where the millisecond rounding decides.
        0, 1, 2 -> {
            val minute = (random.int(2_000_000) - 600_000) * 60.0 * (1 + random.int(97))
            minute + pick(listOf(-0.0005, -0.00049999, -0.0004999, -0.0006, 0.0, 0.0004, 0.0005, 59.9995, 59.9994, -1e-9))
        }
        3 -> (random.next() ushr 11).toDouble() / (1L shl 53).toDouble() * 2.6e11 - 1.3e10
        4 -> pick(TIMES)
        else -> (random.int(1_000_000) - 500_000) * 86_400.0 + random.int(86_400_000) / 1000.0
    }
}
