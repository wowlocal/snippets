package com.khm.snippets.core.git.review

import com.khm.snippets.core.git.GitFormatException
import com.khm.snippets.core.git.GitPack
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.zip.Deflater
import kotlin.concurrent.thread
import kotlin.system.exitProcess
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Review: the limits of this layer against the memory an Android app has.
 *
 * The port keeps the iOS numbers (`GitWire.MAXIMUM_PACK_BYTES` = 128 MiB,
 * `GitPack.Limits.maximumTotalInflatedBytes` = 384 MiB, 64 MiB per object). An
 * Android app's Java heap is capped by `dalvik.vm.heapgrowthlimit`: 256 MiB on current
 * phones, 128 to 192 MiB on smaller ones (the app does not ask for `largeHeap`, and
 * even that gives only 512 MiB, less than a 128 MiB pack plus 384 MiB of objects).
 * Input that stays inside every limit therefore ends in `OutOfMemoryError`, which is
 * not one of the closed failures: it ends the process, and the next sync round
 * fetches the same pack again.
 *
 * The code under review runs in a child JVM started with `-Xmx256m`, which prints
 * `OK`, `CLOSED <code>` or `OOM`.
 */
class AndroidHeapBudgetTest {
    private fun deflate(bytes: ByteArray): ByteArray {
        val deflater = Deflater(Deflater.BEST_COMPRESSION)
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

    /** Runs [HeapProbe] with a 256 MiB heap and returns what it reported. */
    private fun probe(packFile: File): String {
        val classpath = listOf(HeapProbe::class.java, GitPack::class.java, Unit::class.java)
            .map { File(it.protectionDomain.codeSource.location.toURI()).path }
            .distinct().joinToString(File.pathSeparator)
        val java = File(System.getProperty("java.home"), "bin/java").path
        val process = ProcessBuilder(java, "-Xmx256m", "-cp", classpath, HeapProbe::class.java.name, packFile.path)
            .redirectErrorStream(true)
            .start()
        var output = ""
        val reader = thread { output = process.inputStream.readBytes().toString(Charsets.UTF_8) }
        if (!process.waitFor(120, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            return "TIMEOUT after 120 s"
        }
        reader.join(5_000)
        return output.lines().lastOrNull { it.startsWith("RESULT ") }?.removePrefix("RESULT ")
            ?: "NO RESULT (exit ${process.exitValue()}): ${output.takeLast(400)}"
    }

    /**
     * Failed before the fix.
     *
     * A 320 KiB pack of five blobs, each 64 MiB of zeros: 320 MiB inflated, inside
     * every limit of `GitPack.Limits()`. `GitPack.parse` inflates every entry before
     * it resolves any (GitPack.kt:193-252) and returns them all in one map, so 320 MiB
     * are live at once. A host (or whoever controls it) needs to send no more than
     * this to end the app at every sync.
     */
    @Test fun aPackInsideEveryLimitIsParsedOrRefusedWithA256MiBHeap() {
        val size = 64 * 1024 * 1024
        val stream = deflate(ByteArray(size))
        val body = ByteArrayOutputStream()
        body.write("PACK".toByteArray())
        body.write(byteArrayOf(0, 0, 0, 2, 0, 0, 0, 5))
        repeat(5) {
            body.write(entryHeader(3, size.toLong()))
            body.write(stream)
        }
        val pack = body.toByteArray() + MessageDigest.getInstance("SHA-1").digest(body.toByteArray())
        assertTrue(pack.size < 512 * 1024, "the pack on the wire is ${pack.size} bytes")
        val file = Files.createTempFile("review-pack-", ".pack").toFile()
        try {
            file.writeBytes(pack)
            val result = probe(file)
            assertTrue(
                result.startsWith("OK") || result.startsWith("CLOSED"),
                "a ${pack.size}-byte pack inside every limit, parsed with a 256 MiB heap: $result",
            )
        } finally {
            file.delete()
        }
    }
}

/** The child process of [AndroidHeapBudgetTest]. */
object HeapProbe {
    @JvmStatic fun main(arguments: Array<String>) {
        val result = try {
            "OK ${GitPack.parse(File(arguments[0]).readBytes()).size} objects"
        } catch (failure: GitFormatException) {
            "CLOSED ${failure.message}"
        } catch (_: OutOfMemoryError) {
            "OutOfMemoryError"
        }
        println("RESULT $result")
        System.out.flush()
        exitProcess(0)
    }
}
