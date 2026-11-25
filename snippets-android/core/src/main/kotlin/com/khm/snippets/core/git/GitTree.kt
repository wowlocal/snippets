package com.khm.snippets.core.git

import java.time.Instant

/**
 * One tree entry. `mode` and `name` are the raw bytes, preserved verbatim so an entry
 * this client does not own is rewritten byte for byte; git does not require UTF-8
 * names. Neither array may be modified after the entry is built.
 */
class GitTreeEntry(val mode: ByteArray, val name: ByteArray, val id: GitObjectId) {
    /** Git writes `40000`; a zero-padded `040000` from another writer is still a tree. */
    val isTree: Boolean
        get() {
            var start = 0
            while (start < mode.size && mode[start] == '0'.code.toByte()) start += 1
            return mode.size - start == TREE_MODE.size && mode.startsWithBytes(TREE_MODE, start)
        }

    val isRegularFile: Boolean get() = mode.contentEquals(BLOB_MODE) || mode.contentEquals(EXECUTABLE_MODE)

    /** The name as text, or null when it is not valid UTF-8. */
    val nameString: String? get() = name.decodeUtf8Strict()

    override fun equals(other: Any?): Boolean =
        other is GitTreeEntry && mode.contentEquals(other.mode) && name.contentEquals(other.name) && id == other.id

    override fun hashCode(): Int = 31 * (31 * mode.contentHashCode() + name.contentHashCode()) + id.hashCode()
    override fun toString(): String = "GitTreeEntry(${mode.decodeUtf8Lossy()} $id)"

    companion object {
        private val TREE_MODE = "40000".toByteArray(Charsets.US_ASCII)
        private val BLOB_MODE = "100644".toByteArray(Charsets.US_ASCII)
        private val EXECUTABLE_MODE = "100755".toByteArray(Charsets.US_ASCII)

        val treeMode: ByteArray get() = TREE_MODE.copyOf()
        val blobMode: ByteArray get() = BLOB_MODE.copyOf()

        fun tree(name: String, id: GitObjectId) = GitTreeEntry(treeMode, name.toByteArray(Charsets.UTF_8), id)
        fun blob(name: String, id: GitObjectId) = GitTreeEntry(blobMode, name.toByteArray(Charsets.UTF_8), id)
    }
}

object GitTree {
    const val MAXIMUM_ENTRIES = 1_000_000

    fun parse(content: ByteArray): List<GitTreeEntry> {
        val entries = ArrayList<GitTreeEntry>()
        var index = 0
        while (index < content.size) {
            val space = content.indexOfByte(' '.code.toByte(), index)
            if (space <= index) throw GitFormatException.invalidObject("tree_mode")
            if (space - index > 6 || (index until space).any { content[it] !in '0'.code.toByte()..'7'.code.toByte() }) {
                throw GitFormatException.invalidObject("tree_mode")
            }
            val nul = content.indexOfByte(0, space + 1)
            if (nul <= space + 1) throw GitFormatException.invalidObject("tree_name")
            if (content.indexOfByte('/'.code.toByte(), space + 1, nul) >= 0) {
                throw GitFormatException.invalidObject("tree_name")
            }
            val idStart = nul + 1
            if (content.size - idStart < GitObjectId.BYTE_COUNT) throw GitFormatException.invalidObject("tree_id")
            entries.add(
                GitTreeEntry(
                    mode = content.copyOfRange(index, space),
                    name = content.copyOfRange(space + 1, nul),
                    id = GitObjectId.fromBytes(content, idStart),
                ),
            )
            if (entries.size > MAXIMUM_ENTRIES) throw GitFormatException.limitExceeded("tree_entries")
            index = idStart + GitObjectId.BYTE_COUNT
        }
        return entries
    }

    /**
     * Canonical git order: byte order, with a subtree compared as though its name
     * ended in `/`. A server's fsck rejects trees in any other order.
     */
    fun serialize(entries: List<GitTreeEntry>): ByteArray {
        val ordered = sorted(entries)
        val out = ByteArray(ordered.sumOf { it.mode.size + it.name.size + 2 + GitObjectId.BYTE_COUNT })
        var position = 0
        for (entry in ordered) {
            System.arraycopy(entry.mode, 0, out, position, entry.mode.size)
            position += entry.mode.size
            out[position++] = ' '.code.toByte()
            System.arraycopy(entry.name, 0, out, position, entry.name.size)
            position += entry.name.size
            out[position++] = 0
            entry.id.copyInto(out, position)
            position += GitObjectId.BYTE_COUNT
        }
        return out
    }

    fun sorted(entries: List<GitTreeEntry>): List<GitTreeEntry> =
        entries.map { sortKey(it) to it }
            .sortedWith { left, right -> compareUnsigned(left.first, right.first) }
            .map { it.second }

    private fun sortKey(entry: GitTreeEntry): ByteArray =
        if (entry.isTree) entry.name + '/'.code.toByte() else entry.name
}

data class GitCommit(val tree: GitObjectId, val parents: List<GitObjectId>) {
    companion object {
        private val TREE_PREFIX = "tree ".toByteArray(Charsets.US_ASCII)
        private val PARENT_PREFIX = "parent ".toByteArray(Charsets.US_ASCII)

        /** Reads only the structural headers. Author, committer and message are opaque. */
        fun parse(content: ByteArray): GitCommit {
            var tree: GitObjectId? = null
            val parents = ArrayList<GitObjectId>()
            var index = 0
            while (index < content.size) {
                val newline = content.indexOfByte('\n'.code.toByte(), index)
                if (newline < 0) throw GitFormatException.invalidObject("commit_header")
                if (newline == index) break
                if (content.startsWithBytes(TREE_PREFIX, index, newline)) {
                    val id = GitObjectId.fromHexBytes(content, index + TREE_PREFIX.size, newline)
                    if (tree != null || id == null) throw GitFormatException.invalidObject("commit_tree")
                    tree = id
                } else if (content.startsWithBytes(PARENT_PREFIX, index, newline)) {
                    parents.add(
                        GitObjectId.fromHexBytes(content, index + PARENT_PREFIX.size, newline)
                            ?: throw GitFormatException.invalidObject("commit_parent"),
                    )
                }
                index = newline + 1
            }
            return GitCommit(tree ?: throw GitFormatException.invalidObject("commit_tree"), parents)
        }

        /**
         * A commit with fixed, non-identifying authorship. Hosts display these fields,
         * so they must never carry a device name, account, or anything stable per
         * install. `epochSeconds` is clamped at zero.
         */
        fun serialize(tree: GitObjectId, parents: List<GitObjectId>, epochSeconds: Long, message: String): ByteArray {
            val identity = "Snippets Sync <sync@snippets.invalid> ${maxOf(0L, epochSeconds)} +0000"
            val text = StringBuilder("tree ${tree.hex}\n")
            for (parent in parents) text.append("parent ${parent.hex}\n")
            text.append("author $identity\ncommitter $identity\n\n$message\n")
            return text.toString().toByteArray(Charsets.UTF_8)
        }

        /** `Instant.epochSecond` already rounds toward negative infinity, as Swift does. */
        fun serialize(tree: GitObjectId, parents: List<GitObjectId>, date: Instant, message: String): ByteArray =
            serialize(tree, parents, date.epochSecond, message)
    }
}
