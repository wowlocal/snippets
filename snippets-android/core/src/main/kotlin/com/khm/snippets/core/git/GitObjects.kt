package com.khm.snippets.core.git

// A deliberately small, dependency-free subset of git's object model: exactly what the
// serverless git sync transport needs to read a snapshot from, and write one commit to,
// an ordinary hosted repository. It is not a general-purpose git implementation: no
// index, no working tree, no merges, no tags, no SHA-256 repositories.

/** A SHA-1 git object name. */
class GitObjectId private constructor(private val raw: ByteArray) : Comparable<GitObjectId> {
    private val hash = raw.contentHashCode()

    /** A copy of the 20 raw bytes. */
    val bytes: ByteArray get() = raw.copyOf()

    val hex: String get() = raw.toLowerHex()

    val isZero: Boolean get() = raw.all { it == 0.toByte() }

    internal fun copyInto(destination: ByteArray, offset: Int) {
        System.arraycopy(raw, 0, destination, offset, BYTE_COUNT)
    }

    override fun equals(other: Any?): Boolean = other is GitObjectId && raw.contentEquals(other.raw)
    override fun hashCode(): Int = hash
    override fun compareTo(other: GitObjectId): Int = compareUnsigned(raw, other.raw)
    override fun toString(): String = hex

    companion object {
        const val BYTE_COUNT = 20
        const val HEX_COUNT = 40

        val ZERO = GitObjectId(ByteArray(BYTE_COUNT))

        fun fromBytes(bytes: ByteArray): GitObjectId? =
            if (bytes.size == BYTE_COUNT) GitObjectId(bytes.copyOf()) else null

        internal fun fromBytes(bytes: ByteArray, offset: Int): GitObjectId =
            GitObjectId(bytes.copyOfRange(offset, offset + BYTE_COUNT))

        /** Accepts only canonical lowercase hex, which is what every git server emits. */
        fun fromHex(hex: CharSequence): GitObjectId? {
            if (hex.length != HEX_COUNT) return null
            val result = ByteArray(BYTE_COUNT)
            for (index in 0 until BYTE_COUNT) {
                val high = lowerNibble(hex[2 * index].code)
                val low = lowerNibble(hex[2 * index + 1].code)
                if (high < 0 || low < 0) return null
                result[index] = (high shl 4 or low).toByte()
            }
            return GitObjectId(result)
        }

        internal fun fromHexBytes(bytes: ByteArray, from: Int, until: Int): GitObjectId? {
            if (until - from != HEX_COUNT) return null
            val result = ByteArray(BYTE_COUNT)
            for (index in 0 until BYTE_COUNT) {
                val high = lowerNibble(bytes[from + 2 * index].toInt())
                val low = lowerNibble(bytes[from + 2 * index + 1].toInt())
                if (high < 0 || low < 0) return null
                result[index] = (high shl 4 or low).toByte()
            }
            return GitObjectId(result)
        }

        /** The git object name of `content` stored as `type`. */
        fun hash(type: GitObjectType, content: ByteArray): GitObjectId {
            val digest = sha1()
            digest.update(GitObjectType.header(type, content.size))
            digest.update(content)
            return GitObjectId(digest.digest())
        }

        private fun lowerNibble(character: Int): Int = when (character) {
            in '0'.code..'9'.code -> character - '0'.code
            in 'a'.code..'f'.code -> character - 'a'.code + 10
            else -> -1
        }
    }
}

enum class GitObjectType(val code: Int, val typeName: String) {
    COMMIT(1, "commit"),
    TREE(2, "tree"),
    BLOB(3, "blob"),
    TAG(4, "tag");

    companion object {
        fun fromName(name: String): GitObjectType? = entries.firstOrNull { it.typeName == name }

        fun fromCode(code: Int): GitObjectType? = entries.firstOrNull { it.code == code }

        /** `"<type> <size>\0"`, the prefix hashed (and stored loose) before the content. */
        fun header(type: GitObjectType, size: Int): ByteArray {
            val text = "${type.typeName} $size".toByteArray(Charsets.US_ASCII)
            return text.copyOf(text.size + 1)
        }
    }
}

/**
 * One decoded object. `content` is shared, not copied: nothing may modify it after
 * the object is built, because [id] is computed once.
 */
class GitObject(val type: GitObjectType, val content: ByteArray) {
    val id: GitObjectId by lazy(LazyThreadSafetyMode.PUBLICATION) { GitObjectId.hash(type, content) }

    override fun equals(other: Any?): Boolean =
        other is GitObject && type == other.type && content.contentEquals(other.content)

    override fun hashCode(): Int = 31 * type.hashCode() + content.contentHashCode()
    override fun toString(): String = "GitObject(${type.typeName}, ${content.size} bytes)"
}

/**
 * Every malformed-input path in this layer throws this closed error. It carries no
 * remote-supplied text, so it is safe to surface in a sync status.
 */
class GitFormatException(val kind: Kind, val detail: String? = null) :
    Exception(if (detail == null) kind.code else "${kind.code}:$detail") {

    enum class Kind(val code: String) {
        INVALID_OBJECT("object"),
        INVALID_PACK("pack"),
        INVALID_PKT_LINE("pkt_line"),
        INVALID_DELTA("delta"),
        LIMIT_EXCEEDED("limit"),
        COMPRESSION("zlib"),
    }

    /** The closed code the transport reports. */
    val code: String get() = kind.code

    override fun equals(other: Any?): Boolean =
        other is GitFormatException && kind == other.kind && detail == other.detail

    override fun hashCode(): Int = 31 * kind.hashCode() + (detail?.hashCode() ?: 0)

    companion object {
        fun invalidObject(detail: String) = GitFormatException(Kind.INVALID_OBJECT, detail)
        fun invalidPack(detail: String) = GitFormatException(Kind.INVALID_PACK, detail)
        fun invalidPktLine() = GitFormatException(Kind.INVALID_PKT_LINE)
        fun invalidDelta() = GitFormatException(Kind.INVALID_DELTA)
        fun limitExceeded(detail: String) = GitFormatException(Kind.LIMIT_EXCEEDED, detail)
        fun compression() = GitFormatException(Kind.COMPRESSION)
    }
}
