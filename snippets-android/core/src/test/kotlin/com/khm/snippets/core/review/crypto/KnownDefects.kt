package com.khm.snippets.core.review.crypto

/**
 * Recorded lines on which the port is known to differ from Swift. `SwiftDifferentialTest`
 * skips them so the rest of each fixture keeps guarding; the test named beside each entry
 * asserts the difference itself.
 */
internal object KnownDefects {

    /** `"` followed by U+FEFF, raw or as a `﻿` escape of either case: a key or string that starts with a BOM. */
    private val quotedBom = Regex("22(efbbbf|5c75(46|66)(45|65)(46|66)(46|66))")

    /**
     * D1, `LeadingByteOrderMarkTest`: Swift's `String(data:encoding: .utf8)` drops one leading
     * U+FEFF. Fixed; still used to select the lines that test asserts.
     */
    fun isLeadingBom(fields: List<String>): Boolean = when (fields[0]) {
        "canon" -> quotedBom.containsMatchIn(fields[1])
        "utf8str", "plaintext" -> fields[1].startsWith("efbbbf")
        else -> false
    }

    /**
     * Documented in `Uuids.parse`, and stricter than Swift: Foundation reads the text as a C
     * string and accepts a valid id followed by an embedded NUL. `UuidStrictnessTest` pins it.
     */
    fun isUuidWithEmbeddedNul(fields: List<String>, expected: String): Boolean =
        fields[0] == "uuid" && expected != "nil" && fields[1].length > 72 && fields[1].startsWith("00", 72)

    @Suppress("UNUSED_PARAMETER")
    fun covers(fields: List<String>, expected: String, actual: String): Boolean =
        // Decision D1: the BOM lines agree with Swift now, so they are no longer skipped.
        isUuidWithEmbeddedNul(fields, expected)
}
