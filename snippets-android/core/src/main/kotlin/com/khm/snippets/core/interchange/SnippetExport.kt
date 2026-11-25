package com.khm.snippets.core.interchange

import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.model.Snippet

/**
 * The plain JSON export ("Export for Sharing", `SnippetStore.exportSnippets(to:)`).
 *
 * The file is `{"snippets": [...]}` with the nine keys of each ordinary snippet, written
 * as Foundation's `JSONEncoder` writes it with `[.prettyPrinted, .sortedKeys]`. It is
 * plain text: secure snippets are not part of it, not even as shells, and the encrypted
 * backup is the export that carries them.
 *
 * [SnippetImportParser] reads the file back as its second dialect.
 */
object SnippetExport {

    /** The file name the iOS app proposes. */
    const val FILE_NAME: String = "Snippets-Export.json"

    const val MIME_TYPE: String = "application/json"

    /**
     * The export of [ordinarySnippets], the library's ordinary snippets in stored order.
     *
     * @throws SnippetLibraryCodec.NotEncodable when a timestamp is not a finite number.
     */
    @Throws(SnippetLibraryCodec.NotEncodable::class)
    fun encode(ordinarySnippets: List<Snippet>): ByteArray = SnippetLibraryCodec.encodeCollection(ordinarySnippets)
}
