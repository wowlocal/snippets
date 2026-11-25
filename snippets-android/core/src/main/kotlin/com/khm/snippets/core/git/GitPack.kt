package com.khm.snippets.core.git

import java.io.ByteArrayOutputStream
import java.util.zip.DataFormatException
import java.util.zip.Deflater
import java.util.zip.Inflater

/** zlib, as git uses it: one complete zlib stream per object. */
object GitZlib {
    class Inflated(val content: ByteArray, val consumed: Int)

    fun deflate(input: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(input.size / 2 + 64)
        deflateInto(input, out)
        return out.toByteArray()
    }

    internal fun deflateInto(input: ByteArray, out: ByteArrayOutputStream) {
        val deflater = Deflater(Deflater.DEFAULT_COMPRESSION)
        try {
            deflater.setInput(input)
            deflater.finish()
            val buffer = ByteArray(64 * 1024)
            while (!deflater.finished()) {
                val count = deflater.deflate(buffer)
                // With all input supplied and `finish()` called, zlib always progresses.
                if (count == 0 && !deflater.finished()) throw GitFormatException.compression()
                out.write(buffer, 0, count)
            }
        } finally {
            deflater.end()
        }
    }

    /**
     * Inflates the single zlib stream that begins at `offset` and must expand to
     * exactly `expectedSize` bytes. Returns the bytes and how much input it consumed:
     * a pack does not record compressed lengths, so this is the only way to find the
     * next entry.
     *
     * `Inflater` is fed the rest of the array directly and asked what it left over;
     * an `InflaterInputStream` would read ahead and lose the count.
     */
    fun inflate(input: ByteArray, offset: Int, expectedSize: Int): Inflated {
        if (offset < 0 || offset >= input.size || expectedSize < 0) throw GitFormatException.compression()
        val inflater = Inflater()
        try {
            val available = input.size - offset
            inflater.setInput(input, offset, available)
            val output = ByteArray(expectedSize)
            // One spare byte turns a stream that is longer than declared into a
            // detectable error rather than a silently truncated object. (Swift sizes
            // the output `expectedSize + 1`; a separate byte avoids copying it down.)
            val spare = ByteArray(1)
            var produced = 0
            while (!inflater.finished()) {
                val full = produced == expectedSize
                val count = try {
                    if (full) inflater.inflate(spare, 0, 1) else inflater.inflate(output, produced, expectedSize - produced)
                } catch (_: DataFormatException) {
                    throw GitFormatException.compression()
                }
                if (full && count > 0) throw GitFormatException.compression()
                // Nothing produced and not finished: truncated input or a preset dictionary.
                if (count == 0 && !inflater.finished()) throw GitFormatException.compression()
                produced += count
            }
            if (produced != expectedSize) throw GitFormatException.compression()
            return Inflated(output, available - inflater.remaining)
        } finally {
            inflater.end()
        }
    }
}

/** Git's binary delta format (`gitformat-pack(5)`, "Deltified representation"). */
object GitDelta {
    fun apply(delta: ByteArray, base: ByteArray, maximumSize: Int): ByteArray {
        var index = 0
        fun size(): Long {
            var value = 0L
            var shift = 0
            while (true) {
                if (index >= delta.size || shift >= 63) throw GitFormatException.invalidDelta()
                val byte = delta[index].toInt() and 0xff
                index += 1
                value = value or ((byte and 0x7f).toLong() shl shift)
                shift += 7
                if (byte and 0x80 == 0) return value
            }
        }
        if (size() != base.size.toLong()) throw GitFormatException.invalidDelta()
        val declared = size()
        if (declared < 0 || declared > maximumSize) throw GitFormatException.limitExceeded("delta_target")
        val targetSize = declared.toInt()
        val output = ByteArray(targetSize)
        var written = 0
        while (index < delta.size) {
            val opcode = delta[index].toInt() and 0xff
            index += 1
            if (opcode and 0x80 != 0) {
                var copyOffset = 0L
                var copySize = 0
                for (bit in 0 until 4) {
                    if (opcode and (1 shl bit) == 0) continue
                    if (index >= delta.size) throw GitFormatException.invalidDelta()
                    copyOffset = copyOffset or ((delta[index].toLong() and 0xff) shl (8 * bit))
                    index += 1
                }
                for (bit in 0 until 3) {
                    if (opcode and (0x10 shl bit) == 0) continue
                    if (index >= delta.size) throw GitFormatException.invalidDelta()
                    copySize = copySize or ((delta[index].toInt() and 0xff) shl (8 * bit))
                    index += 1
                }
                if (copySize == 0) copySize = 0x10000
                if (copyOffset + copySize > base.size || copySize > targetSize - written) {
                    throw GitFormatException.invalidDelta()
                }
                System.arraycopy(base, copyOffset.toInt(), output, written, copySize)
                written += copySize
            } else if (opcode != 0) {
                if (opcode > delta.size - index || opcode > targetSize - written) {
                    throw GitFormatException.invalidDelta()
                }
                System.arraycopy(delta, index, output, written, opcode)
                written += opcode
                index += opcode
            } else {
                throw GitFormatException.invalidDelta()
            }
        }
        if (written != targetSize) throw GitFormatException.invalidDelta()
        return output
    }
}

/** Reads and writes version-2 packfiles. */
object GitPack {
    /** The iOS values of the Swift implementation: a phone's memory, not a Mac's. */
    data class Limits(
        val maximumObjects: Int = 2_000_000,
        val maximumObjectBytes: Int = 64 * 1024 * 1024,
        val maximumTotalInflatedBytes: Long = 384L * 1024 * 1024,
        val maximumDeltaDepth: Int = 10_000,
    )

    private sealed interface Entry {
        class Whole(val type: GitObjectType, val content: ByteArray) : Entry
        class OffsetDelta(val baseOffset: Int, val delta: ByteArray) : Entry
        class ReferenceDelta(val base: GitObjectId, val delta: ByteArray) : Entry
    }

    private class Pending(val entry: Int, val obj: GitObject, val depth: Int)

    private val SIGNATURE = "PACK".toByteArray(Charsets.US_ASCII)
    private const val HEADER_BYTES = 12

    /**
     * Decodes every object, resolving both delta forms. `externalBase` supplies
     * objects a thin pack references but omits; this client never asks for thin packs,
     * so production callers pass the local cache only as a defensive fallback.
     *
     * The pack is untrusted: every count, size and offset is checked before it is
     * used to allocate or index.
     */
    fun parse(
        pack: ByteArray,
        limits: Limits = Limits(),
        externalBase: (GitObjectId) -> GitObject? = { null },
    ): Map<GitObjectId, GitObject> {
        if (pack.size < HEADER_BYTES + GitObjectId.BYTE_COUNT || !pack.startsWithBytes(SIGNATURE)) {
            throw GitFormatException.invalidPack("signature")
        }
        val version = bigEndian32(pack, 4)
        if (version != 2L && version != 3L) throw GitFormatException.invalidPack("version")
        val declaredCount = bigEndian32(pack, 8)
        if (declaredCount > limits.maximumObjects) throw GitFormatException.limitExceeded("pack_objects")
        val count = declaredCount.toInt()

        val trailerStart = pack.size - GitObjectId.BYTE_COUNT
        val checksum = sha1().apply { update(pack, 0, trailerStart) }.digest()
        for (index in checksum.indices) {
            if (checksum[index] != pack[trailerStart + index]) throw GitFormatException.invalidPack("checksum")
        }

        // The header's count is untrusted until each entry has actually been read.
        val entries = ArrayList<Entry?>(minOf(count, 65_536))
        // Entries are read front to back, so their offsets are already sorted.
        var offsets = IntArray(minOf(count, 65_536))
        var inflatedTotal = 0L
        var offset = HEADER_BYTES
        repeat(count) {
            val entryOffset = offset
            if (offset >= trailerStart) throw GitFormatException.invalidPack("truncated")
            var byte = pack[offset].toInt() and 0xff
            offset += 1
            val typeCode = (byte shr 4) and 0x07
            var declaredSize = (byte and 0x0f).toLong()
            var shift = 4
            while (byte and 0x80 != 0) {
                if (offset >= trailerStart || shift >= 57) throw GitFormatException.invalidPack("header")
                byte = pack[offset].toInt() and 0xff
                offset += 1
                declaredSize = declaredSize or ((byte and 0x7f).toLong() shl shift)
                shift += 7
            }
            if (declaredSize > limits.maximumObjectBytes) throw GitFormatException.limitExceeded("pack_object")
            val size = declaredSize.toInt()
            val entry: Entry
            when (typeCode) {
                1, 2, 3, 4 -> {
                    val inflated = GitZlib.inflate(pack, offset, size)
                    offset += inflated.consumed
                    entry = Entry.Whole(GitObjectType.fromCode(typeCode)!!, inflated.content)
                }
                6 -> {
                    if (offset >= trailerStart) throw GitFormatException.invalidPack("truncated")
                    byte = pack[offset].toInt() and 0xff
                    offset += 1
                    var distance = (byte and 0x7f).toLong()
                    while (byte and 0x80 != 0) {
                        if (offset >= trailerStart || distance >= Long.MAX_VALUE shr 8) {
                            throw GitFormatException.invalidPack("offset")
                        }
                        byte = pack[offset].toInt() and 0xff
                        offset += 1
                        distance = ((distance + 1) shl 7) or (byte and 0x7f).toLong()
                    }
                    val baseOffset = entryOffset - distance
                    if (distance <= 0 || baseOffset < HEADER_BYTES) throw GitFormatException.invalidPack("offset")
                    val inflated = GitZlib.inflate(pack, offset, size)
                    offset += inflated.consumed
                    entry = Entry.OffsetDelta(baseOffset.toInt(), inflated.content)
                }
                7 -> {
                    if (trailerStart - offset < GitObjectId.BYTE_COUNT) throw GitFormatException.invalidPack("reference")
                    val base = GitObjectId.fromBytes(pack, offset)
                    offset += GitObjectId.BYTE_COUNT
                    val inflated = GitZlib.inflate(pack, offset, size)
                    offset += inflated.consumed
                    entry = Entry.ReferenceDelta(base, inflated.content)
                }
                else -> throw GitFormatException.invalidPack("type")
            }
            if (offset > trailerStart) throw GitFormatException.invalidPack("truncated")
            inflatedTotal += size
            if (inflatedTotal > limits.maximumTotalInflatedBytes) throw GitFormatException.limitExceeded("pack_inflated")
            if (entries.size == offsets.size) offsets = offsets.copyOf(maxOf(16, offsets.size * 2))
            offsets[entries.size] = entryOffset
            entries.add(entry)
        }
        if (offset != trailerStart) throw GitFormatException.invalidPack("trailing_data")

        // Resolve breadth-first from every undeltified object, so each delta is applied
        // exactly once no matter how long its chain is. Offset deltas name a position;
        // reference deltas name an object id that may itself be produced by a delta.
        val objects = HashMap<GitObjectId, GitObject>()
        val childrenByEntry = HashMap<Int, MutableList<Int>>()
        val childrenById = LinkedHashMap<GitObjectId, MutableList<Int>>()
        val queue = ArrayDeque<Pending>()
        var resolvedCount = 0
        for (index in entries.indices) {
            when (val entry = entries[index]!!) {
                is Entry.Whole -> {
                    queue.addLast(Pending(index, GitObject(entry.type, entry.content), 0))
                    entries[index] = null
                }
                is Entry.OffsetDelta -> {
                    val base = java.util.Arrays.binarySearch(offsets, 0, entries.size, entry.baseOffset)
                    if (base < 0) throw GitFormatException.invalidPack("offset_base")
                    childrenByEntry.getOrPut(base) { ArrayList() }.add(index)
                }
                is Entry.ReferenceDelta -> childrenById.getOrPut(entry.base) { ArrayList() }.add(index)
            }
        }

        /** The delta of a child, released once taken: each is applied exactly once. */
        fun takeDelta(index: Int): ByteArray {
            val delta = when (val entry = entries[index]) {
                is Entry.OffsetDelta -> entry.delta
                is Entry.ReferenceDelta -> entry.delta
                else -> ByteArray(0)
            }
            entries[index] = null
            return delta
        }

        fun enqueueChildren(children: List<Int>, base: GitObject, depth: Int) {
            for (child in children) {
                val content = GitDelta.apply(takeDelta(child), base.content, limits.maximumObjectBytes)
                inflatedTotal += content.size
                if (inflatedTotal > limits.maximumTotalInflatedBytes) {
                    throw GitFormatException.limitExceeded("pack_inflated")
                }
                queue.addLast(Pending(child, GitObject(base.type, content), depth))
            }
        }

        while (true) {
            while (queue.isNotEmpty()) {
                val pending = queue.removeFirst()
                resolvedCount += 1
                val id = pending.obj.id
                objects[id] = pending.obj
                val byEntry = childrenByEntry.remove(pending.entry)
                val byId = childrenById.remove(id)
                if (byEntry == null && byId == null) continue
                if (pending.depth >= limits.maximumDeltaDepth) throw GitFormatException.limitExceeded("delta_depth")
                enqueueChildren(byEntry.orEmpty() + byId.orEmpty(), pending.obj, pending.depth + 1)
            }
            // Anything left refers to an object outside this pack.
            val baseId = childrenById.keys.firstOrNull() ?: break
            val base = externalBase(baseId) ?: break
            enqueueChildren(childrenById.remove(baseId).orEmpty(), base, 1)
        }
        if (resolvedCount != count) throw GitFormatException.invalidPack("unresolved_delta")
        return objects
    }

    /**
     * An undeltified pack. Records are already ciphertext, so deltas would not
     * compress them anyway, and an undeltified pack can never depend on a base the
     * server lacks.
     */
    fun build(objects: List<GitObject>): ByteArray {
        // Ciphertext does not compress, so the content size is a good first capacity.
        val capacity = objects.sumOf { it.content.size.toLong() + 16 }.coerceAtMost(64L * 1024 * 1024).toInt() + 64
        val out = ExposedByteArrayOutputStream(capacity)
        out.write(SIGNATURE)
        writeBigEndian32(2, out)
        writeBigEndian32(objects.size, out)
        for (obj in objects) {
            var size = obj.content.size
            var byte = (obj.type.code shl 4) or (size and 0x0f)
            size = size ushr 4
            while (size > 0) {
                out.write(byte or 0x80)
                byte = size and 0x7f
                size = size ushr 7
            }
            out.write(byte)
            GitZlib.deflateInto(obj.content, out)
        }
        val checksum = sha1().apply { update(out.buffer(), 0, out.size()) }.digest()
        out.write(checksum)
        return out.toByteArray()
    }

    private class ExposedByteArrayOutputStream(capacity: Int) : ByteArrayOutputStream(capacity) {
        fun buffer(): ByteArray = buf
    }

    private fun bigEndian32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xff) shl 24) or ((bytes[offset + 1].toLong() and 0xff) shl 16) or
            ((bytes[offset + 2].toLong() and 0xff) shl 8) or (bytes[offset + 3].toLong() and 0xff)

    private fun writeBigEndian32(value: Int, out: ByteArrayOutputStream) {
        out.write(value ushr 24)
        out.write((value ushr 16) and 0xff)
        out.write((value ushr 8) and 0xff)
        out.write(value and 0xff)
    }
}
