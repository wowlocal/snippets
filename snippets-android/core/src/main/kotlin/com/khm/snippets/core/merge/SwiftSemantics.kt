package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.wire.SyncEnvelope

/**
 * The parts of Swift's standard library that `SyncMerge.swift` leans on without saying
 * so, reproduced where a Kotlin collection or operator would answer differently.
 *
 * - A Swift `Dictionary<String, …>` treats canonically equivalent keys as one key
 *   (`"vaultKID"` and the same word spelled with U+212A KELVIN SIGN), keeps the spelling
 *   that was inserted first, and compares equal to another dictionary regardless of
 *   spelling. A Kotlin `Map` compares UTF-16 units.
 * - `min` and `max` on `Date` return an argument, not a canonical number: which of
 *   `0.0` and `-0.0` comes back depends on the argument order, and the bits are hashed.
 *
 * `String.hasPrefix` is [com.khm.snippets.core.search.SwiftStrings.hasPrefix] and the order
 * of `uuidString` is [com.khm.snippets.core.model.SnippetDisplayOrder.compareUuidStrings];
 * they are not repeated here.
 *
 * All of this is about input no released client writes. It is here because the merge has
 * to make the decision an Apple device makes for every input that parses.
 */
internal object SwiftSemantics {

    /** Whether no key of [map] can be equivalent to a differently spelled key. */
    private fun plainKeys(map: Map<String, *>): Boolean {
        for (key in map.keys) if (!isPlain(key)) return false
        return true
    }

    // Below U+0300 nothing decomposes, composes or reorders, so equivalence is identity.
    private fun isPlain(text: String): Boolean {
        for (unit in text) if (unit.code >= 0x0300) return false
        return true
    }

    // Dictionaries

    /** The key of [map] that Swift would find for [key], or `null`. */
    fun storedKey(map: Map<String, JsonValue>, key: String): String? {
        if (map.containsKey(key)) return key
        // Equivalence is identity only when both sides are plain: `vault` U+212A `ID` is
        // the same key as `vaultKID`.
        if (isPlain(key) && plainKeys(map)) return null
        for (candidate in map.keys) if (FoundationText.canonicalEquals(candidate, key)) return candidate
        return null
    }

    /** `map[key]`. */
    fun get(map: Map<String, JsonValue>, key: String): JsonValue? {
        val stored = storedKey(map, key) ?: return null
        return map[stored]
    }

    /** `map[key] = value`: an existing equivalent key keeps its spelling; `null` removes it. */
    fun set(map: MutableMap<String, JsonValue>, key: String, value: JsonValue?) {
        val stored = storedKey(map, key)
        if (value == null) {
            if (stored != null) map.remove(stored)
        } else {
            map[stored ?: key] = value
        }
    }

    /**
     * `first.merging(second) { mine, theirs in preferFirst ? mine : theirs }`: every key
     * of [first] in its own spelling, then the keys only [second] has.
     */
    fun merging(
        first: Map<String, JsonValue>,
        second: Map<String, JsonValue>,
        preferFirst: Boolean,
    ): LinkedHashMap<String, JsonValue> {
        val merged = LinkedHashMap(first)
        for ((key, value) in second) {
            val stored = storedKey(merged, key)
            if (stored == null) {
                merged[key] = value
            } else if (!preferFirst) {
                merged[stored] = value
            }
        }
        return merged
    }

    /** `first == second` for two `[String: CanonicalJSON.Value]`. */
    fun dictionariesEqual(first: Map<String, JsonValue>, second: Map<String, JsonValue>): Boolean {
        if (first.size != second.size) return false
        if (plainKeys(first) && plainKeys(second)) {
            for ((key, value) in first) {
                val other = second[key] ?: return false
                if (!valuesEqual(value, other)) return false
            }
            return true
        }
        for ((key, value) in first) {
            val other = get(second, key) ?: return false
            if (!valuesEqual(value, other)) return false
        }
        return true
    }

    /**
     * `first == second` for two `CanonicalJSON.Value`: strings by their bytes, numbers by
     * kind and IEEE value, objects as dictionaries.
     */
    fun valuesEqual(first: JsonValue, second: JsonValue): Boolean = when (first) {
        is JsonValue.Object -> second is JsonValue.Object && dictionariesEqual(first.members, second.members)
        is JsonValue.Array ->
            second is JsonValue.Array && first.elements.size == second.elements.size &&
                first.elements.indices.all { valuesEqual(first.elements[it], second.elements[it]) }
        is JsonValue.Real -> second is JsonValue.Real && first.value == second.value
        else -> first == second
    }

    /** `first == second` for two optional values. */
    fun optionalValuesEqual(first: JsonValue?, second: JsonValue?): Boolean =
        if (first == null || second == null) first == null && second == null else valuesEqual(first, second)

    /** `first == second` for two `SyncEnvelope`s (Swift's synthesized `Equatable`). */
    fun envelopesEqual(first: SyncEnvelope, second: SyncEnvelope): Boolean {
        if (first === second) return true
        return first.schemaVersion == second.schemaVersion &&
            first.id == second.id &&
            first.secure == second.secure &&
            first.deleted == second.deleted &&
            first.hlc == second.hlc &&
            FoundationText.canonicalEquals(first.origin, second.origin) &&
            first.fields == second.fields &&
            dictionariesEqual(first.x, second.x)
    }

    // Comparable

    /** Swift's `min(first, second)` on `Double`: `second < first ? second : first`. */
    fun min(first: Double, second: Double): Double = if (second < first) second else first

    /** Swift's `max(first, second)` on `Double`: `second >= first ? second : first`. */
    fun max(first: Double, second: Double): Double = if (second >= first) second else first

    /** Swift's `max(first, second)` on a `Comparable`: the second argument on a tie. */
    fun <T : Comparable<T>> max(first: T, second: T): T = if (second >= first) second else first

}
