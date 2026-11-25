package com.khm.snippets.core.crypto

/**
 * The length-prefixed field list behind every `snip.*` AAD
 * (`SnippetCrypto.domainSeparated` in Swift):
 *
 * ```
 * u32be(len(domain)) ‖ domain_utf8 ‖ u32be(len(f1)) ‖ f1 ‖ … ‖ u32be(len(fn)) ‖ fn
 * ```
 *
 * Injective by construction: no two different field lists produce the same bytes.
 */
object DomainSeparated {

    fun encode(domain: String, fields: List<ByteArray>): ByteArray {
        val tag = Utf8.encode(domain)
        var total = 4 + tag.size
        for (field in fields) total += 4 + field.size
        val out = ByteArray(total)
        var position = append(out, 0, tag)
        for (field in fields) position = append(out, position, field)
        return out
    }

    fun encode(domain: String, vararg fields: ByteArray): ByteArray = encode(domain, fields.asList())

    private fun append(out: ByteArray, position: Int, field: ByteArray): Int {
        Bytes.u32be(field.size).copyInto(out, position)
        field.copyInto(out, position + 4)
        return position + 4 + field.size
    }
}
