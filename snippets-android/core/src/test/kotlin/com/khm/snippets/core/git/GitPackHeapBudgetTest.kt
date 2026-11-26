package com.khm.snippets.core.git

import com.khm.snippets.core.git.review.HeapProbe
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.zip.Deflater
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Review finding 3: the limits follow the heap, and a pack is parsed or refused with
 * the closed `limit` failure, never with `OutOfMemoryError`.
 *
 * The parsing runs in a child JVM with the heap of a typical Android app
 * (`-Xmx256m`), through the reviewer's `HeapProbe`.
 */
class GitPackHeapBudgetTest {
    private val mebibyte = 1024L * 1024

    @Test fun limitsAreAFractionOfTheHeapCappedAtTheIosNumbers() {
        val phone = GitPack.Limits.forHeap(256 * mebibyte)
        assertEquals(32 * mebibyte, phone.maximumPackBytes)
        assertEquals(32 * mebibyte, phone.maximumObjectBytes.toLong())
        assertEquals(96 * mebibyte, phone.maximumTotalInflatedBytes)
        assertEquals(131_072, phone.maximumObjects)
        assertEquals(10_000, phone.maximumDeltaDepth)
        // Everything a parse can hold at once fits the heap with room to spare: the
        // pack, its objects, their bookkeeping and one more object being built.
        val worstCase = phone.maximumPackBytes + phone.maximumTotalInflatedBytes + phone.maximumObjects * 256L + phone.maximumObjectBytes
        assertTrue(worstCase <= 256 * mebibyte * 3 / 4, "worst case $worstCase")

        val small = GitPack.Limits.forHeap(128 * mebibyte)
        assertEquals(listOf(16 * mebibyte, 16 * mebibyte, 48 * mebibyte, 65_536L),
            listOf(small.maximumPackBytes, small.maximumObjectBytes.toLong(), small.maximumTotalInflatedBytes, small.maximumObjects.toLong()))
        val large = GitPack.Limits.forHeap(512 * mebibyte)
        assertEquals(listOf(64 * mebibyte, 64 * mebibyte, 192 * mebibyte, 262_144L),
            listOf(large.maximumPackBytes, large.maximumObjectBytes.toLong(), large.maximumTotalInflatedBytes, large.maximumObjects.toLong()))
        // Never more than the Swift implementation allows on iOS, however large the heap.
        for (heap in listOf(4096 * mebibyte, 64 * 1024 * mebibyte, Long.MAX_VALUE)) {
            assertEquals(GitPack.Limits(), GitPack.Limits.forHeap(heap), "heap $heap")
        }
        assertEquals(128 * mebibyte, GitPack.Limits().maximumPackBytes)
        assertEquals(64 * mebibyte, GitPack.Limits().maximumObjectBytes.toLong())
        assertEquals(384 * mebibyte, GitPack.Limits().maximumTotalInflatedBytes)
        assertEquals(2_000_000, GitPack.Limits().maximumObjects)
        // A heap too small to matter still gets limits that work.
        for (heap in listOf(0L, -1L, 1024L, 4 * mebibyte)) {
            val tiny = GitPack.Limits.forHeap(heap)
            assertEquals(mebibyte, tiny.maximumPackBytes, "heap $heap")
            assertEquals(3 * mebibyte, tiny.maximumTotalInflatedBytes, "heap $heap")
            assertEquals(4_096, tiny.maximumObjects, "heap $heap")
        }
        // Monotonic: more heap never means less room.
        var previous = GitPack.Limits.forHeap(0)
        for (heap in 1..600) {
            val next = GitPack.Limits.forHeap(heap * mebibyte)
            assertTrue(next.maximumPackBytes >= previous.maximumPackBytes && next.maximumTotalInflatedBytes >= previous.maximumTotalInflatedBytes)
            assertTrue(next.maximumObjectBytes >= previous.maximumObjectBytes && next.maximumObjects >= previous.maximumObjects)
            previous = next
        }
        // What this process parses with by default.
        assertEquals(GitPack.Limits.forHeap(Runtime.getRuntime().maxMemory()), GitPack.Limits.current())
    }

    // MARK: Packs built for the probe

    private fun deflate(bytes: ByteArray): ByteArray {
        val deflater = Deflater(Deflater.BEST_SPEED)
        deflater.setInput(bytes)
        deflater.finish()
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
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

    /** A delta that copies all of a `baseSize`-byte base and appends one byte. */
    private fun growingDelta(baseSize: Int, appended: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(varint(baseSize.toLong()))
        out.write(varint(baseSize + 1L))
        var offset = 0
        while (offset < baseSize) {
            val count = minOf(0x10000, baseSize - offset)
            val operands = ByteArrayOutputStream()
            var opcode = 0x80
            for (bit in 0 until 4) {
                val byte = (offset ushr (8 * bit)) and 0xff
                if (byte != 0) {
                    opcode = opcode or (1 shl bit)
                    operands.write(byte)
                }
            }
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
            offset += count
        }
        out.write(1)
        out.write(appended)
        return out.toByteArray()
    }

    private class PackWriter {
        private val body = ByteArrayOutputStream()
        private var count = 0
        var lastOffset = 0
            private set

        fun add(header: ByteArray, vararg rest: ByteArray): Int {
            lastOffset = 12 + body.size()
            body.write(header)
            for (part in rest) body.write(part)
            count += 1
            return lastOffset
        }

        /** Where the next entry will start. */
        val nextOffset: Int get() = 12 + body.size()

        fun finish(): ByteArray {
            val head = "PACK".toByteArray() + byteArrayOf(0, 0, 0, 2, (count ushr 24).toByte(), (count ushr 16).toByte(), (count ushr 8).toByte(), count.toByte())
            val whole = head + body.toByteArray()
            return whole + MessageDigest.getInstance("SHA-1").digest(whole)
        }
    }

    private fun blobs(count: Int, size: Int): ByteArray {
        val writer = PackWriter()
        repeat(count) { writer.add(entryHeader(3, size.toLong()), deflate(ByteArray(size) { _ -> (it + 1).toByte() })) }
        return writer.finish()
    }

    private fun deltaChain(baseSize: Int, deltas: Int): ByteArray {
        val writer = PackWriter()
        var previous = writer.add(entryHeader(3, baseSize.toLong()), deflate(ByteArray(baseSize) { 9 }))
        repeat(deltas) { index ->
            val delta = growingDelta(baseSize + index, index)
            previous = writer.add(entryHeader(6, delta.size.toLong()), offsetVarint((writer.nextOffset - previous).toLong()), deflate(delta))
        }
        return writer.finish()
    }

    /** Parses `pack` in a JVM with a 256 MiB heap and returns `OK …`, `CLOSED <code>` or what went wrong. */
    private fun probe(pack: ByteArray): String {
        val file = Files.createTempFile("heap-budget-", ".pack").toFile()
        try {
            file.writeBytes(pack)
            val classpath = listOf(HeapProbe::class.java, GitPack::class.java, Unit::class.java)
                .map { File(it.protectionDomain.codeSource.location.toURI()).path }
                .distinct().joinToString(File.pathSeparator)
            val java = File(System.getProperty("java.home"), "bin/java").path
            val process = ProcessBuilder(java, "-Xmx256m", "-cp", classpath, HeapProbe::class.java.name, file.path)
                .redirectErrorStream(true)
                .start()
            var output = ""
            val reader = thread { output = process.inputStream.readBytes().toString(Charsets.UTF_8) }
            if (!process.waitFor(180, TimeUnit.SECONDS)) {
                process.destroyForcibly()
                return "TIMEOUT"
            }
            reader.join(5_000)
            return output.lines().lastOrNull { it.startsWith("RESULT ") }?.removePrefix("RESULT ")
                ?: "NO RESULT (exit ${process.exitValue()}): ${output.takeLast(400)}"
        } finally {
            file.delete()
        }
    }

    @Test fun packsUpToTheHeapsLimitsParseAndLargerOnesAreRefusedWithA256MiBHeap() {
        val size = 28 * 1024 * 1024
        // Three large objects fill most of the 96 MiB the heap allows; a fourth is over.
        assertEquals("OK 3 objects", probe(blobs(3, size)))
        assertEquals("CLOSED limit:pack_inflated", probe(blobs(4, size)))
        // One object over the 32 MiB a single object may take.
        assertEquals("CLOSED limit:pack_object", probe(blobs(1, 40 * 1024 * 1024)))
    }

    @Test fun whatDeltasProduceCountsBeforeItIsAllocated() {
        val size = 28 * 1024 * 1024
        assertEquals("OK 3 objects", probe(deltaChain(size, 2)))
        // The third result would be the fourth 28 MiB array: refused before it exists.
        assertEquals("CLOSED limit:pack_inflated", probe(deltaChain(size, 3)))
    }

    @Test fun aPackOfVeryManySmallObjectsIsBoundedByItsBookkeeping() {
        fun tiny(count: Int): ByteArray {
            val writer = PackWriter()
            repeat(count) { index ->
                val content = byteArrayOf((index ushr 16).toByte(), (index ushr 8).toByte(), index.toByte())
                writer.add(entryHeader(3, 3), deflate(content))
            }
            return writer.finish()
        }
        assertEquals("OK 100000 objects", probe(tiny(100_000)))
        assertEquals("CLOSED limit:pack_objects", probe(tiny(150_000)))
    }
}
