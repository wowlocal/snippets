package com.khm.snippets.core.git

import com.khm.snippets.core.git.testing.GitBinary
import com.khm.snippets.core.git.testing.GitFixture
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.Random
import java.util.zip.Deflater
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Property-style round trips, size boundaries, hand-built delta packs and corruption:
 * a hostile pack must end in a closed `GitFormatException`, never in another
 * exception, a hang or an allocation sized by an untrusted length.
 */
class GitPackPropertyTest {
    // MARK: Building packs by hand

    private sealed interface Entry {
        class Whole(val type: Int, val content: ByteArray, val declaredSize: Long = content.size.toLong()) : Entry
        class OffsetDelta(val baseIndex: Int, val delta: ByteArray, val distanceOverride: Long? = null) : Entry
        class ReferenceDelta(val base: GitObjectId, val delta: ByteArray) : Entry
    }

    private fun deflate(bytes: ByteArray, level: Int = Deflater.DEFAULT_COMPRESSION): ByteArray {
        val deflater = Deflater(level)
        deflater.setInput(bytes)
        deflater.finish()
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (!deflater.finished()) out.write(buffer, 0, deflater.deflate(buffer))
        deflater.end()
        return out.toByteArray()
    }

    private fun entryHeader(type: Int, size: Long): ByteArray {
        val out = ByteArrayOutputStream()
        var remaining = size ushr 4
        var byte = (type shl 4) or (size and 0x0f).toInt()
        while (remaining > 0) {
            out.write(byte or 0x80)
            byte = (remaining and 0x7f).toInt()
            remaining = remaining ushr 7
        }
        out.write(byte)
        return out.toByteArray()
    }

    /** Git's offset encoding: big-endian groups of seven bits, each but the last biased by one. */
    private fun offsetVarint(distance: Long): ByteArray {
        var value = distance
        val bytes = ArrayList<Byte>()
        bytes.add((value and 0x7f).toByte())
        value = value ushr 7
        while (value > 0) {
            value -= 1
            bytes.add(((value and 0x7f) or 0x80).toByte())
            value = value ushr 7
        }
        return bytes.reversed().toByteArray()
    }

    private fun seal(body: ByteArray): ByteArray = body + MessageDigest.getInstance("SHA-1").digest(body)

    private fun packHeader(count: Long, version: Int = 2): ByteArray = "PACK".toByteArray() + byteArrayOf(
        0, 0, 0, version.toByte(),
        (count ushr 24).toByte(), (count ushr 16).toByte(), (count ushr 8).toByte(), count.toByte(),
    )

    private fun pack(entries: List<Entry>, version: Int = 2, count: Long = entries.size.toLong(), trailing: ByteArray = ByteArray(0)): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(packHeader(count, version))
        val offsets = ArrayList<Int>()
        for (entry in entries) {
            offsets.add(out.size())
            when (entry) {
                is Entry.Whole -> {
                    out.write(entryHeader(entry.type, entry.declaredSize))
                    out.write(deflate(entry.content))
                }
                is Entry.OffsetDelta -> {
                    out.write(entryHeader(6, entry.delta.size.toLong()))
                    out.write(offsetVarint(entry.distanceOverride ?: (offsets.last() - offsets[entry.baseIndex]).toLong()))
                    out.write(deflate(entry.delta))
                }
                is Entry.ReferenceDelta -> {
                    out.write(entryHeader(7, entry.delta.size.toLong()))
                    out.write(entry.base.bytes)
                    out.write(deflate(entry.delta))
                }
            }
        }
        out.write(trailing)
        return seal(out.toByteArray())
    }

    private fun varint(value: Long): ByteArray {
        val out = ByteArrayOutputStream()
        var remaining = value
        while (true) {
            val byte = (remaining and 0x7f).toInt()
            remaining = remaining ushr 7
            if (remaining == 0L) {
                out.write(byte)
                return out.toByteArray()
            }
            out.write(byte or 0x80)
        }
    }

    /** A delta that copies the shared prefix and suffix and inserts what lies between. */
    private fun delta(base: ByteArray, target: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(varint(base.size.toLong()))
        out.write(varint(target.size.toLong()))
        var prefix = 0
        while (prefix < base.size && prefix < target.size && base[prefix] == target[prefix]) prefix += 1
        var suffix = 0
        while (suffix < base.size - prefix && suffix < target.size - prefix &&
            base[base.size - 1 - suffix] == target[target.size - 1 - suffix]
        ) suffix += 1
        fun copy(offset: Int, length: Int) {
            var from = offset
            var remaining = length
            while (remaining > 0) {
                val count = minOf(remaining, 0x10000)
                val operands = ByteArrayOutputStream()
                var opcode = 0x80
                for (bit in 0 until 4) {
                    val byte = (from ushr (8 * bit)) and 0xff
                    if (byte != 0) {
                        opcode = opcode or (1 shl bit)
                        operands.write(byte)
                    }
                }
                // A size of 0x10000 is written as "no size bytes".
                if (count != 0x10000) {
                    for (bit in 0 until 3) {
                        val byte = (count ushr (8 * bit)) and 0xff
                        if (byte != 0) {
                            opcode = opcode or (0x10 shl bit)
                            operands.write(byte)
                        }
                    }
                }
                out.write(opcode)
                out.write(operands.toByteArray())
                from += count
                remaining -= count
            }
        }
        fun insert(offset: Int, length: Int) {
            var from = offset
            var remaining = length
            while (remaining > 0) {
                val count = minOf(remaining, 127)
                out.write(count)
                out.write(target, from, count)
                from += count
                remaining -= count
            }
        }
        copy(0, prefix)
        insert(prefix, target.size - prefix - suffix)
        copy(base.size - suffix, suffix)
        return out.toByteArray()
    }

    private fun random(seed: Long, size: Int) = ByteArray(size).also { Random(seed).nextBytes(it) }

    private fun blob(content: ByteArray) = GitObject(GitObjectType.BLOB, content)

    // MARK: Round trips

    @Test fun randomObjectsSurviveBuildAndParse() {
        val random = Random(20261125)
        val types = GitObjectType.entries
        repeat(60) { round ->
            val objects = List(random.nextInt(12)) {
                val size = when (random.nextInt(6)) {
                    0 -> 0
                    1 -> random.nextInt(32)
                    2 -> random.nextInt(4_096)
                    3 -> 65_530 + random.nextInt(12)
                    else -> random.nextInt(200_000)
                }
                val content = ByteArray(size)
                // Half incompressible (like ciphertext), half repetitive.
                if (random.nextBoolean()) random.nextBytes(content) else content.fill(random.nextInt(256).toByte())
                GitObject(types[random.nextInt(types.size)], content)
            }
            val pack = GitPack.build(objects)
            val parsed = GitPack.parse(pack)
            assertEquals(objects.map { it.id }.toSet(), parsed.keys, "round $round")
            for (obj in objects) {
                assertEquals(obj, parsed[obj.id], "round $round")
                assertEquals(obj.id, GitObjectId.hash(obj.type, parsed.getValue(obj.id).content))
            }
        }
    }

    /** Sizes where the entry header grows a byte, where zlib changes block, and git's 64 KiB copy unit. */
    @Test fun objectsAroundEncodingBoundariesRoundTrip() {
        val sizes = listOf(
            0, 1, 14, 15, 16, 17, 126, 127, 128, 2_046, 2_047, 2_048, 2_049, 32_767, 32_768, 32_769,
            65_534, 65_535, 65_536, 65_537, 262_143, 262_144, 262_145, 1 shl 20, (1 shl 20) + 1,
        )
        val objects = sizes.flatMap { size ->
            listOf(blob(random(size.toLong(), size)), blob(ByteArray(size) { (size % 251).toByte() }))
        }.distinctBy { it.id }
        val parsed = GitPack.parse(GitPack.build(objects))
        assertEquals(objects.size, parsed.size)
        for (obj in objects) assertEquals(obj, parsed[obj.id], "size ${obj.content.size}")
        for (size in sizes) {
            val content = random(size + 1L, size)
            val stream = GitZlib.deflate(content)
            val inflated = GitZlib.inflate(byteArrayOf(9, 9, 9) + stream + byteArrayOf(7, 7), offset = 3, expectedSize = size)
            assertContentEquals(content, inflated.content, "size $size")
            assertEquals(stream.size, inflated.consumed, "size $size")
        }
    }

    @Test fun aBuiltPackIsReadByGitItself() {
        GitFixture().use { fixture ->
            val objects = listOf(
                blob(ByteArray(0)), blob(random(1, 70_000)), blob("text\n".toByteArray()),
                GitObject(GitObjectType.TREE, GitTree.serialize(listOf(GitTreeEntry.blob("x", blob(ByteArray(0)).id)))),
            )
            val pack = GitPack.build(objects)
            val file = File(fixture.root, "built.pack").apply { writeBytes(pack) }
            // `index-pack` verifies the checksum, every zlib stream and every object id.
            fixture.git("index-pack", "--strict", file.path)
            val listed = fixture.git("verify-pack", "-v", file.path.removeSuffix(".pack") + ".idx").lines()
                .filter { it.length > 40 && it[40] == ' ' }.map { it.take(40) }.toSet()
            assertEquals(objects.map { it.id.hex }.toSet(), listed)
        }
    }

    @Test fun zlibInflateAcceptsEveryStreamShapeAndReportsItsLength() {
        val content = random(5, 50_000)
        for (level in listOf(Deflater.NO_COMPRESSION, Deflater.BEST_SPEED, Deflater.BEST_COMPRESSION)) {
            val stream = deflate(content, level)
            val inflated = GitZlib.inflate(stream + random(6, 100), 0, content.size)
            assertContentEquals(content, inflated.content)
            assertEquals(stream.size, inflated.consumed, "level $level")
        }
        val stream = GitZlib.deflate(content)
        val compression = GitFormatException.compression()
        // Longer or shorter than declared, truncated, empty, not zlib at all, out of range.
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(stream, 0, content.size + 1) })
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(stream, 0, content.size - 1) })
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(stream, 0, 0) })
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(stream.copyOf(stream.size - 1), 0, content.size) })
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(stream.copyOf(stream.size / 2), 0, content.size) })
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(ByteArray(0), 0, 0) })
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(stream, stream.size, 0) })
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(stream, -1, 0) })
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(random(8, 64), 0, 10) })
        // A stream that needs a preset dictionary (FDICT) is not something git writes.
        assertEquals(compression, assertFailsWith<GitFormatException> { GitZlib.inflate(byteArrayOf(0x78, 0xbb.toByte(), 0, 0, 0, 1, 3, 0), 0, 0) })
        assertEquals(0, GitZlib.inflate(GitZlib.deflate(ByteArray(0)), 0, 0).content.size)
    }

    // MARK: Deltas

    @Test fun randomEditsRoundTripThroughDeltas() {
        val random = Random(42)
        repeat(300) { round ->
            val base = random(round.toLong(), random.nextInt(3) * 70_000 + random.nextInt(5_000))
            val target = base.copyOf()
                .let { if (it.isNotEmpty() && random.nextBoolean()) it.copyOfRange(0, random.nextInt(it.size)) + it else it }
                .let { bytes ->
                    if (bytes.isEmpty()) return@let random(round + 1_000L, random.nextInt(300))
                    val cut = random.nextInt(bytes.size)
                    bytes.copyOfRange(0, cut) + random(round + 2_000L, random.nextInt(400)) +
                        bytes.copyOfRange(minOf(bytes.size, cut + random.nextInt(50)), bytes.size)
                }
            val applied = GitDelta.apply(delta(base, target), base, maximumSize = 64 * 1024 * 1024)
            assertContentEquals(target, applied, "round $round")
        }
    }

    @Test fun copySizeZeroMeansSixtyFourKibibytes() {
        val base = random(9, 0x10000 + 10)
        // source size, target size 0x10000, then a copy with offset 5 and no size bytes.
        val delta = varint(base.size.toLong()) + varint(0x10000) + byteArrayOf(0x81.toByte(), 5)
        assertContentEquals(base.copyOfRange(5, 5 + 0x10000), GitDelta.apply(delta, base, 1 shl 20))
        // Every offset and size byte position is honoured.
        val large = random(10, 0x1_02_03 + 0x02_01 + 7)
        val wide = varint(large.size.toLong()) + varint(0x0201) + byteArrayOf(0xb7.toByte(), 0x03, 0x02, 0x01, 0x01, 0x02)
        assertContentEquals(large.copyOfRange(0x010203, 0x010203 + 0x0201), GitDelta.apply(wide, large, 1 shl 20))
    }

    @Test fun hostileDeltasFailClosed() {
        val base = "hello world".toByteArray()
        val invalid = GitFormatException.invalidDelta()
        fun delta(vararg bytes: Int) = ByteArray(bytes.size) { bytes[it].toByte() }
        for (hostile in listOf(
            delta(), // no sizes
            delta(11), // no target size
            delta(11, 5), // nothing produced
            delta(11, 5, 0x91, 6), // copy operands cut short
            delta(11, 5, 0x90), // size byte announced, missing
            delta(11, 5, 5, 'a'.code), // insert past the delta
            delta(11, 2, 3, 1, 2, 3), // insert longer than the target
            delta(11, 3, 0x91, 0, 5), // copy longer than the target
            delta(11, 5, 0x80), // 64 KiB copy from an 11-byte base
            delta(11, 5, 0x9f, 0xff, 0xff, 0xff, 0xff, 5), // offset near 2^32
            delta(11, 5, 0x91, 6, 5, 0x91, 0, 1), // more than the target
            delta(0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 1), // size varint overflow
        )) {
            assertEquals(invalid, assertFailsWith<GitFormatException>(hostile.toList().toString()) { GitDelta.apply(hostile, base, 100) })
        }
        // A huge declared target is refused before anything is allocated.
        val huge = delta(11) + varint(1L shl 60)
        assertEquals(GitFormatException.limitExceeded("delta_target"), assertFailsWith<GitFormatException> { GitDelta.apply(huge, base, Int.MAX_VALUE) })
        assertEquals(
            GitFormatException.limitExceeded("delta_target"),
            assertFailsWith<GitFormatException> { GitDelta.apply(delta(11) + varint(Long.MAX_VALUE) + delta(0x80), base, 100) },
        )
    }

    @Test fun handBuiltDeltaChainsResolveInAnyOrder() {
        val random = Random(77)
        val versions = ArrayList<ByteArray>()
        versions.add(random(1, 150_000))
        repeat(9) {
            val previous = versions.last()
            val cut = random.nextInt(previous.size)
            versions.add(previous.copyOfRange(0, cut) + random(it + 100L, 200) + previous.copyOfRange(cut, previous.size))
        }
        val ids = versions.map { GitObjectId.hash(GitObjectType.BLOB, it) }
        // Offset deltas, each on the entry before it.
        val chained = listOf<Entry>(Entry.Whole(3, versions[0])) +
            (1 until versions.size).map { Entry.OffsetDelta(it - 1, delta(versions[it - 1], versions[it])) }
        var parsed = GitPack.parse(pack(chained))
        assertEquals(ids.toSet(), parsed.keys)
        for (index in versions.indices) assertContentEquals(versions[index], parsed.getValue(ids[index]).content)

        // Reference deltas listed before the objects they build on, the whole object last.
        val reversed = (versions.size - 1 downTo 1).map<Int, Entry> { Entry.ReferenceDelta(ids[it - 1], delta(versions[it - 1], versions[it])) } +
            Entry.Whole(3, versions[0])
        parsed = GitPack.parse(pack(reversed))
        assertEquals(ids.toSet(), parsed.keys)
        for (index in versions.indices) assertContentEquals(versions[index], parsed.getValue(ids[index]).content)

        // A thin pack: the base comes from outside, and is not itself part of the result.
        val thin = listOf<Entry>(
            Entry.ReferenceDelta(ids[0], delta(versions[0], versions[1])),
            Entry.OffsetDelta(0, delta(versions[1], versions[2])),
        )
        assertEquals(
            GitFormatException.invalidPack("unresolved_delta"),
            assertFailsWith<GitFormatException> { GitPack.parse(pack(thin)) },
        )
        parsed = GitPack.parse(pack(thin)) { id -> if (id == ids[0]) blob(versions[0]) else null }
        assertEquals(setOf(ids[1], ids[2]), parsed.keys)
        assertContentEquals(versions[2], parsed.getValue(ids[2]).content)
        // A delta keeps the type of its base.
        val tree = GitTree.serialize(listOf(GitTreeEntry.blob("a", ids[0])))
        val grown = GitTree.serialize(listOf(GitTreeEntry.blob("a", ids[0]), GitTreeEntry.blob("b", ids[1])))
        parsed = GitPack.parse(pack(listOf(Entry.Whole(2, tree), Entry.OffsetDelta(0, delta(tree, grown)))))
        assertEquals(GitObjectType.TREE, parsed.getValue(GitObjectId.hash(GitObjectType.TREE, grown)).type)
    }

    // MARK: Limits and hostile headers

    @Test fun hostileHeadersAndLimitsFailClosedWithoutAllocating() {
        fun code(pack: ByteArray, limits: GitPack.Limits = GitPack.Limits()): String =
            assertFailsWith<GitFormatException> { GitPack.parse(pack, limits) }.message!!

        val one = blob("abc".toByteArray())
        assertEquals("pack:signature", code(ByteArray(0)))
        assertEquals("pack:signature", code(ByteArray(31)))
        assertEquals("pack:signature", code(seal("JUNK".toByteArray() + ByteArray(8))))
        assertEquals("pack:version", code(pack(listOf(Entry.Whole(3, one.content)), version = 4)))
        assertEquals("pack:version", code(pack(listOf(Entry.Whole(3, one.content)), version = 1)))
        assertEquals(1, GitPack.parse(pack(listOf(Entry.Whole(3, one.content)), version = 3)).size)
        // An object count the pack cannot possibly hold: refused or found truncated, never allocated.
        assertEquals("limit:pack_objects", code(seal(packHeader(0xffff_ffffL))))
        assertEquals("limit:pack_objects", code(seal(packHeader(2_000_001))))
        assertEquals("pack:truncated", code(seal(packHeader(2_000_000))))
        assertEquals("pack:truncated", code(pack(listOf(Entry.Whole(3, one.content)), count = 2)))
        assertEquals("pack:trailing_data", code(pack(listOf(Entry.Whole(3, one.content)), count = 0)))
        assertEquals("pack:trailing_data", code(pack(listOf(Entry.Whole(3, one.content)), trailing = byteArrayOf(0))))
        assertEquals(0, GitPack.parse(seal(packHeader(0))).size)
        assertEquals("pack:checksum", code(packHeader(0) + ByteArray(20)))
        // Declared sizes: over the object limit, absurd, and a size varint that never ends.
        assertEquals("limit:pack_object", code(seal(packHeader(1) + entryHeader(3, 64L * 1024 * 1024 + 1) + deflate(one.content))))
        assertEquals("limit:pack_object", code(seal(packHeader(1) + entryHeader(3, 1L shl 50) + deflate(one.content))))
        assertEquals("pack:header", code(seal(packHeader(1) + ByteArray(12) { 0xff.toByte() } + deflate(one.content))))
        assertEquals("pack:header", code(seal(packHeader(1) + byteArrayOf(0xb0.toByte()))))
        // A large declared size over a tiny stream is a zlib error, not a 64 MiB object.
        assertEquals("zlib", code(seal(packHeader(1) + entryHeader(3, 64L * 1024 * 1024) + deflate(one.content))))
        assertEquals("zlib", code(pack(listOf(Entry.Whole(3, one.content, declaredSize = 2)))))
        assertEquals("zlib", code(pack(listOf(Entry.Whole(3, one.content, declaredSize = 4)))))
        assertEquals("zlib", code(seal(packHeader(1) + entryHeader(3, 3))))
        // Types 0 and 5 do not exist.
        assertEquals("pack:type", code(pack(listOf(Entry.Whole(0, one.content)))))
        assertEquals("pack:type", code(pack(listOf(Entry.Whole(5, one.content)))))
        assertEquals(GitObjectType.TAG, GitPack.parse(pack(listOf(Entry.Whole(4, one.content)))).values.single().type)

        // Totals.
        val three = listOf(Entry.Whole(3, ByteArray(40) { 1 }), Entry.Whole(3, ByteArray(40) { 2 }), Entry.Whole(3, ByteArray(40) { 3 }))
        assertEquals("limit:pack_inflated", code(pack(three), GitPack.Limits(maximumTotalInflatedBytes = 100)))
        assertEquals(3, GitPack.parse(pack(three), GitPack.Limits(maximumTotalInflatedBytes = 120)).size)
        assertEquals("limit:pack_object", code(pack(three), GitPack.Limits(maximumObjectBytes = 39)))
        assertEquals("limit:pack_objects", code(pack(three), GitPack.Limits(maximumObjects = 2)))
        // What deltas produce counts toward the total as well.
        val base = ByteArray(40) { 1 }
        val target = ByteArray(60) { 1 }
        val deltified = listOf<Entry>(Entry.Whole(3, base), Entry.OffsetDelta(0, delta(base, target)))
        val deltaBytes = delta(base, target).size
        assertEquals("limit:pack_inflated", code(pack(deltified), GitPack.Limits(maximumTotalInflatedBytes = 40L + deltaBytes + 59)))
        assertEquals(2, GitPack.parse(pack(deltified), GitPack.Limits(maximumTotalInflatedBytes = 40L + deltaBytes + 60)).size)
        assertEquals("limit:delta_target", code(pack(deltified), GitPack.Limits(maximumObjectBytes = 59)))
    }

    @Test fun deltaBasesMustBeRealAndChainsBounded() {
        fun code(pack: ByteArray, limits: GitPack.Limits = GitPack.Limits()): String =
            assertFailsWith<GitFormatException> { GitPack.parse(pack, limits) }.message!!

        val base = random(3, 500)
        val target = base + byteArrayOf(1)
        val change = delta(base, target)
        // An offset that points before the first entry, at itself, or into the middle of one.
        assertEquals("pack:offset", code(pack(listOf(Entry.Whole(3, base), Entry.OffsetDelta(0, change, distanceOverride = 100_000)))))
        assertEquals("pack:offset", code(pack(listOf(Entry.Whole(3, base), Entry.OffsetDelta(0, change, distanceOverride = 0)))))
        assertEquals("pack:offset", code(seal(packHeader(1) + entryHeader(6, 4) + ByteArray(12) { 0xff.toByte() })))
        assertEquals("pack:truncated", code(seal(packHeader(1) + entryHeader(6, 4))))
        val whole = pack(listOf(Entry.Whole(3, base)))
        val wholeLength = whole.size - 20 - 12
        assertEquals("pack:offset_base", code(pack(listOf(Entry.Whole(3, base), Entry.OffsetDelta(0, change, distanceOverride = wholeLength - 1L)))))
        assertEquals(2, GitPack.parse(pack(listOf(Entry.Whole(3, base), Entry.OffsetDelta(0, change, distanceOverride = wholeLength.toLong())))).size)
        // A reference delta cut short, or naming an object nobody has.
        assertEquals("pack:reference", code(seal(packHeader(1) + entryHeader(7, 4) + ByteArray(19))))
        assertEquals("pack:unresolved_delta", code(pack(listOf(Entry.ReferenceDelta(GitObjectId.ZERO, change)))))
        // Two deltas that name each other never resolve, and never loop.
        val a = GitObjectId.hash(GitObjectType.BLOB, base)
        val b = GitObjectId.hash(GitObjectType.BLOB, target)
        assertEquals("pack:unresolved_delta", code(pack(listOf(Entry.ReferenceDelta(a, change), Entry.ReferenceDelta(b, change)))))
        // A delta that does not fit its base.
        assertEquals("delta", code(pack(listOf(Entry.Whole(3, target), Entry.OffsetDelta(0, change)))))

        // A long chain is resolved iteratively; the depth limit is exact.
        val depth = 3_000
        val chain = ArrayList<Entry>()
        var content = ByteArray(8)
        chain.add(Entry.Whole(3, content))
        repeat(depth) {
            val next = content + byteArrayOf((it % 251).toByte())
            chain.add(Entry.OffsetDelta(chain.size - 1, delta(content, next)))
            content = next
        }
        val deep = pack(chain)
        assertEquals(depth + 1, GitPack.parse(deep).size)
        assertEquals(depth + 1, GitPack.parse(deep, GitPack.Limits(maximumDeltaDepth = depth)).size)
        assertEquals("limit:delta_depth", code(deep, GitPack.Limits(maximumDeltaDepth = depth - 1)))
    }

    // MARK: Corruption

    /** With the trailer intact every flipped byte is caught by the checksum. */
    @Test fun everyFlippedByteIsCaughtByTheChecksum() {
        val pack = GitPack.build(listOf(blob("abc".toByteArray()), blob(random(4, 300))))
        for (index in pack.indices) {
            val corrupt = pack.copyOf()
            corrupt[index] = (corrupt[index].toInt() xor 0x01).toByte()
            val failure = assertFailsWith<GitFormatException>("byte $index") { GitPack.parse(corrupt) }
            val expected = when {
                index < 4 -> setOf("pack:signature")
                // The last version byte turns 2 into 3, which is a version this parser reads.
                index < 7 -> setOf("pack:version")
                // A larger object count is refused before the checksum is even computed.
                index in 8..11 -> setOf("pack:checksum", "limit:pack_objects")
                else -> setOf("pack:checksum")
            }
            assertTrue(failure.message in expected, "byte $index: ${failure.message}")
        }
        for (length in 0 until pack.size) {
            assertFailsWith<GitFormatException>("length $length") { GitPack.parse(pack.copyOf(length)) }
        }
    }

    /**
     * A hostile server computes a valid checksum over whatever it sends. Mutations
     * with the trailer re-sealed reach every parser path: the only acceptable outcomes
     * are a closed `GitFormatException` or objects whose ids match their content.
     */
    @Test fun mutatedPacksWithAValidChecksumNeverEscapeTheClosedError() {
        val versions = (0 until 6).map { random(it.toLong(), 400 + it * 37) }
        val ids = versions.map { GitObjectId.hash(GitObjectType.BLOB, it) }
        val seeds = listOf(
            GitPack.build(versions.map(::blob) + GitObject(GitObjectType.TREE, GitTree.serialize(listOf(GitTreeEntry.blob("a", ids[0]))))),
            pack(listOf<Entry>(Entry.Whole(3, versions[0])) + (1 until versions.size).map { Entry.OffsetDelta(it - 1, delta(versions[it - 1], versions[it])) }),
            pack((versions.size - 1 downTo 1).map<Int, Entry> { Entry.ReferenceDelta(ids[it - 1], delta(versions[it - 1], versions[it])) } + Entry.Whole(3, versions[0])),
        )
        mutateAndParse(seeds, rounds = 4_000, seed = 1)
    }

    @Test fun mutatedGitMadeDeltaPacksNeverEscapeTheClosedError() {
        GitFixture().use { fixture ->
            val work = File(fixture.root, "work")
            fixture.git("init", "--quiet", work.path)
            var text = (0 until 300).joinToString("") { "line $it of a repetitive file\n" }
            for (revision in 0 until 6) {
                text = text.replace("line ${revision * 10} ", "edited $revision ")
                File(work, "file.txt").writeText(text)
                fixture.git("-C", work.path, "add", "-A")
                fixture.git("-C", work.path, "commit", "--quiet", "-m", "r$revision")
            }
            val ids = fixture.git("-C", work.path, "rev-list", "--objects", "--all").lines().joinToString("\n") { it.take(40) } + "\n"
            val seeds = listOf(true, false).map { useOffsets ->
                val command = listOf(GitBinary.path!!, "-C", work.path, "pack-objects", "--stdout", "--window=50", "--depth=50", "--no-reuse-delta") +
                    (if (useOffsets) listOf("--delta-base-offset") else emptyList())
                val builder = ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.DISCARD)
                builder.environment().clear()
                builder.environment().putAll(GitBinary.isolatedEnvironment(fixture.root))
                val process = builder.start()
                val writer = thread { process.outputStream.use { it.write(ids.toByteArray()) } }
                val pack = process.inputStream.readBytes()
                writer.join()
                assertEquals(0, process.waitFor())
                assertEquals(18, GitPack.parse(pack).size)
                pack
            }
            mutateAndParse(seeds, rounds = 3_000, seed = 2)
        }
    }

    private fun mutateAndParse(seeds: List<ByteArray>, rounds: Int, seed: Long) {
        val random = Random(seed)
        // Small limits keep a mutated length from costing time; the paths are the same.
        val limits = GitPack.Limits(maximumObjects = 10_000, maximumObjectBytes = 1 shl 20, maximumTotalInflatedBytes = 8L shl 20, maximumDeltaDepth = 64)
        var parsedCount = 0
        val codes = HashSet<String>()
        repeat(rounds) { round ->
            val original = seeds[round % seeds.size]
            var body = original.copyOf(original.size - 20)
            repeat(1 + random.nextInt(3)) {
                val position = if (body.isEmpty()) 0 else random.nextInt(body.size)
                body = when (random.nextInt(8)) {
                    0, 1, 2 -> body.also { if (it.isNotEmpty()) it[position] = (it[position].toInt() xor (1 shl random.nextInt(8))).toByte() }
                    3 -> body.also { if (it.isNotEmpty()) it[position] = random.nextInt(256).toByte() }
                    4 -> body.copyOf(position)
                    5 -> body.copyOfRange(0, position) + random.nextInt(256).toByte() + body.copyOfRange(position, body.size)
                    6 -> body + ByteArray(1 + random.nextInt(4)).also(random::nextBytes)
                    else -> body.copyOfRange(0, position) + body.copyOfRange(minOf(body.size, position + 1 + random.nextInt(4)), body.size)
                }
            }
            val mutated = seal(body)
            try {
                val objects = GitPack.parse(mutated, limits)
                parsedCount += 1
                for ((id, obj) in objects) assertEquals(id, GitObjectId.hash(obj.type, obj.content), "round $round")
            } catch (failure: GitFormatException) {
                codes.add(failure.message!!)
            }
            // Anything else (an index error, an arithmetic error, an out-of-memory error) fails the test by propagating.
        }
        // The mutations really did reach the parser's own checks, not just one of them.
        assertTrue(codes.size >= 6, "codes seen: $codes")
        assertTrue("zlib" in codes && "pack:trailing_data" in codes && "pack:truncated" in codes, "codes seen: $codes")
        assertTrue(parsedCount < rounds)
    }

    /**
     * Mutations of the delta instructions themselves, deflated and sealed correctly, so
     * nothing but the delta interpreter stands between them and memory.
     */
    @Test fun mutatedDeltaInstructionsNeverEscapeTheClosedError() {
        val random = Random(3)
        val base = random(11, 70_000)
        val target = base.copyOfRange(0, 30_000) + random(12, 500) + base.copyOfRange(29_000, 70_000)
        val good = delta(base, target)
        assertContentEquals(target, GitDelta.apply(good, base, 1 shl 20))
        val codes = HashSet<String>()
        var applied = 0
        repeat(4_000) { round ->
            var mutated = good.copyOf()
            repeat(1 + random.nextInt(2)) {
                val position = if (mutated.isEmpty()) 0 else random.nextInt(mutated.size)
                mutated = when (if (mutated.isEmpty()) 3 else random.nextInt(4)) {
                    0 -> mutated.also { it[position] = (it[position].toInt() xor (1 shl random.nextInt(8))).toByte() }
                    1 -> mutated.also { it[position] = random.nextInt(256).toByte() }
                    2 -> mutated.copyOf(position)
                    else -> mutated.copyOfRange(0, position) + random.nextInt(256).toByte() + mutated.copyOfRange(position, mutated.size)
                }
            }
            val direct = runCatching { GitDelta.apply(mutated, base, 1 shl 20) }
            val failure = direct.exceptionOrNull()
            if (failure != null) {
                assertTrue(failure is GitFormatException, "round $round: $failure")
                codes.add(failure.message!!)
            } else {
                applied += 1
            }
            // The same instructions arriving in a pack end the same way.
            val packed = runCatching { GitPack.parse(pack(listOf(Entry.Whole(3, base), Entry.OffsetDelta(0, mutated))), GitPack.Limits(maximumObjectBytes = 1 shl 20)) }
            val packFailure = packed.exceptionOrNull()
            if (failure != null) {
                assertEquals(failure, packFailure, "round $round")
            } else {
                assertTrue(packFailure == null, "round $round: $packFailure")
                val result = direct.getOrThrow()
                assertContentEquals(result, packed.getOrThrow().getValue(GitObjectId.hash(GitObjectType.BLOB, result)).content)
            }
        }
        assertEquals(setOf("delta", "limit:delta_target"), codes)
        assertTrue(applied in 1 until 4_000, "applied $applied")
    }

    // MARK: Trees and commits

    @Test fun treesKeepRawNamesAndModesAndRefuseMalformedEntries() {
        val id = GitObjectId.hash(GitObjectType.BLOB, ByteArray(0))
        val raw = listOf(
            GitTreeEntry("120000".toByteArray(), byteArrayOf(0xff.toByte(), 0xfe.toByte()), id), // a symlink with a non-UTF-8 name
            GitTreeEntry("160000".toByteArray(), "module".toByteArray(), id), // a gitlink
            GitTreeEntry("040000".toByteArray(), "padded".toByteArray(), id), // a zero-padded tree mode
            GitTreeEntry("100755".toByteArray(), "run.sh".toByteArray(), id),
            GitTreeEntry("100644".toByteArray(), "é".toByteArray(), id),
        )
        val parsed = GitTree.parse(GitTree.serialize(raw))
        assertEquals(raw.toSet(), parsed.toSet())
        assertEquals(null, parsed.first { it.mode.contentEquals("120000".toByteArray()) }.nameString)
        assertTrue(parsed.first { it.nameString == "padded" }.isTree)
        assertTrue(parsed.first { it.nameString == "run.sh" }.isRegularFile)
        assertTrue(parsed.none { it.nameString == "module" && (it.isTree || it.isRegularFile) })
        // Bytes above 0x7f sort after ASCII: unsigned comparison.
        assertEquals(listOf("module", "padded", "run.sh", "é", null), parsed.map { it.nameString })
        assertContentEquals(GitTree.serialize(raw), GitTree.serialize(parsed.shuffled(Random(1))))

        fun entry(mode: String, name: String, idBytes: Int = 20) = mode.toByteArray() + ' '.code.toByte() + name.toByteArray() + 0.toByte() + ByteArray(idBytes)
        fun code(content: ByteArray) = assertFailsWith<GitFormatException> { GitTree.parse(content) }.message
        assertEquals("object:tree_mode", code(" name".toByteArray()))
        assertEquals("object:tree_mode", code(entry("1006440", "a")))
        assertEquals("object:tree_mode", code(entry("10064x", "a")))
        assertEquals("object:tree_mode", code(entry("100648", "a")))
        assertEquals("object:tree_mode", code("100644".toByteArray()))
        assertEquals("object:tree_name", code(entry("100644", "")))
        assertEquals("object:tree_name", code(entry("100644", "a/b")))
        assertEquals("object:tree_name", code("100644 name".toByteArray()))
        assertEquals("object:tree_id", code(entry("100644", "a", idBytes = 19)))
        assertEquals("object:tree_id", code(entry("100644", "a") + entry("100644", "b", idBytes = 0)))
        assertTrue(GitTree.parse(ByteArray(0)).isEmpty())
    }

    @Test fun treeOrderMatchesGitForAwkwardNames() {
        GitFixture().use { fixture ->
            val blob = GitObjectId.hash(GitObjectType.BLOB, "x".toByteArray())
            val empty = GitObjectId.hash(GitObjectType.TREE, ByteArray(0))
            val random = Random(5)
            val names = listOf("a", "a.", "a-", "a0", "a_", "A", "ab", "a b", "é", "zz", "z", "a~", "a!", "0", "_", "~", "ÿ", "日本")
            val entries = names.map { if (random.nextBoolean()) GitTreeEntry.tree(it, empty) else GitTreeEntry.blob(it, blob) }.shuffled(random)
            val listing = entries.joinToString("") { entry ->
                val kind = if (entry.isTree) "040000 tree" else "100644 blob"
                "$kind ${entry.id.hex}\t${entry.nameString}\u0000"
            }
            val gitId = fixture.bareGit("mktree", "--missing", "-z", input = listing.toByteArray())
            assertEquals(gitId, GitObjectId.hash(GitObjectType.TREE, GitTree.serialize(entries)).hex)
        }
    }

    @Test fun commitsAreExactBytesAndParseStrictly() {
        val tree = GitObjectId.hash(GitObjectType.TREE, ByteArray(0))
        val parent = GitObjectId.hash(GitObjectType.BLOB, "p".toByteArray())
        val identity = "Snippets Sync <sync@snippets.invalid>"
        assertEquals(
            "tree ${tree.hex}\nauthor $identity 1700000000 +0000\ncommitter $identity 1700000000 +0000\n\nCreate Snippets library\n",
            GitCommit.serialize(tree, emptyList(), 1_700_000_000, "Create Snippets library").toString(Charsets.UTF_8),
        )
        assertEquals(
            "tree ${tree.hex}\nparent ${parent.hex}\nauthor $identity 0 +0000\ncommitter $identity 0 +0000\n\nSync 2 records\n",
            GitCommit.serialize(tree, listOf(parent), -5, "Sync 2 records").toString(Charsets.UTF_8),
        )
        // A fractional time rounds down, as Swift's `rounded(.down)` does.
        assertContentEquals(
            GitCommit.serialize(tree, emptyList(), 1_700_000_000, "m"),
            GitCommit.serialize(tree, emptyList(), java.time.Instant.ofEpochSecond(1_700_000_000, 999_999_999), "m"),
        )
        fun code(text: String) = assertFailsWith<GitFormatException> { GitCommit.parse(text.toByteArray()) }.message
        assertEquals("object:commit_tree", code(""))
        assertEquals("object:commit_tree", code("\ntree ${tree.hex}\n"))
        assertEquals("object:commit_tree", code("tree ${tree.hex}\ntree ${tree.hex}\n\n"))
        assertEquals("object:commit_tree", code("tree ${tree.hex.uppercase()}\n\n"))
        assertEquals("object:commit_tree", code("tree ${tree.hex} \n\n"))
        assertEquals("object:commit_parent", code("tree ${tree.hex}\nparent nope\n\n"))
        assertEquals("object:commit_header", code("tree ${tree.hex}"))
        val merge = GitCommit.parse("tree ${tree.hex}\nparent ${parent.hex}\nparent ${tree.hex}\nauthor x\n\ntree is not a header here\n".toByteArray())
        assertEquals(GitCommit(tree, listOf(parent, tree)), merge)
    }

    @Test fun commitsMadeHereAreTheCommitsGitMakes() {
        GitFixture().use { fixture ->
            val tree = fixture.bareGit("mktree", input = ByteArray(0))
            val environment = arrayOf(
                "GIT_AUTHOR_NAME=Snippets Sync", "GIT_AUTHOR_EMAIL=sync@snippets.invalid", "GIT_AUTHOR_DATE=1700000000 +0000",
                "GIT_COMMITTER_NAME=Snippets Sync", "GIT_COMMITTER_EMAIL=sync@snippets.invalid", "GIT_COMMITTER_DATE=1700000000 +0000",
            )
            val builder = ProcessBuilder(GitBinary.path!!, "--git-dir", fixture.bare.path, "commit-tree", tree, "-m", "Sync 1 record")
            builder.environment().clear()
            builder.environment().putAll(GitBinary.isolatedEnvironment(fixture.root))
            for (pair in environment) builder.environment()[pair.substringBefore('=')] = pair.substringAfter('=')
            val process = builder.redirectError(ProcessBuilder.Redirect.DISCARD).start()
            process.outputStream.close()
            val gitCommit = process.inputStream.readBytes().toString(Charsets.UTF_8).trim()
            assertEquals(0, process.waitFor())
            val ours = GitCommit.serialize(GitObjectId.fromHex(tree)!!, emptyList(), 1_700_000_000, "Sync 1 record")
            assertEquals(gitCommit, GitObjectId.hash(GitObjectType.COMMIT, ours).hex)
        }
    }
}
