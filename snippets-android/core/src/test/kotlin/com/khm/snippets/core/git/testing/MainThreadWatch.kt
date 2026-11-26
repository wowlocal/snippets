package com.khm.snippets.core.git.testing

import java.io.Closeable
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import kotlin.concurrent.thread
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * A single-threaded dispatcher standing in for Android's main thread, and a sampler
 * that looks at that thread's stack several thousand times a second. A suspend
 * function is main-safe when no sample ever finds the thread inside blocking I/O,
 * inflating, or one of this layer's parsers.
 */
class MainThreadWatch : Closeable {
    private val executor = Executors.newSingleThreadExecutor { task -> Thread(task, NAME).apply { isDaemon = true } }
    val dispatcher: ExecutorCoroutineDispatcher = executor.asCoroutineDispatcher()
    val thread: Thread = executor.submit<Thread> { Thread.currentThread() }.get()
    private val offences = ConcurrentLinkedQueue<String>()

    @Volatile private var running = true
    private val sampler = thread(name = "main-thread-sampler", isDaemon = true) {
        while (running) {
            val stack = thread.stackTrace
            val index = stack.indexOfFirst { isHeavy(it.className) }
            // The JVM reading a class file the first time a class is used is not the code under test.
            val incidental = stack.any { it.className.startsWith("java.lang.ClassLoader") || it.className.startsWith("jdk.internal.loader.") }
            if (index >= 0 && !incidental) {
                offences.add(stack.drop(index).take(6).joinToString(" < ") { "${it.className}.${it.methodName}" })
            }
            Thread.sleep(0, 200_000)
        }
    }

    /** What the sampler found the main thread doing that it must not do. */
    val heavyWork: Set<String> get() = offences.toSet()

    /** Runs `block` on the "main" thread, as a coroutine launched from the UI would. */
    fun <T> onMain(timeoutMillis: Long = 60_000, block: suspend () -> T): T =
        runBlocking(dispatcher) { withTimeout(timeoutMillis) { block() } }

    override fun close() {
        running = false
        sampler.join(1_000)
        dispatcher.close()
    }

    /** Whether the calling code runs on the "main" thread. (Its name may carry a coroutine suffix.) */
    val isOnMain: Boolean get() = Thread.currentThread() === thread

    companion object {
        const val NAME = "test-main"

        // What OkHttp and okio do on the calling thread (building a request, checking a
        // header name, handing a call to the dispatcher) works in memory. Their real
        // socket and file operations show up as `java.net`, `sun.nio` or `java.io`
        // frames, which is what is looked for.
        private val heavyPackages = listOf(
            "java.net.", "sun.nio.", "sun.security.ssl.", "java.util.zip.",
            "java.io.FileInputStream", "java.io.FileOutputStream", "java.io.RandomAccessFile", "java.lang.Process",
            "com.khm.snippets.core.git.GitWire", "com.khm.snippets.core.git.GitPktLine", "com.khm.snippets.core.git.GitPack",
            "com.khm.snippets.core.git.GitZlib", "com.khm.snippets.core.git.GitDelta",
            "com.khm.snippets.core.git.testing.BlockingPipe",
        )

        // Checked first: holding a request or response value is not work.
        private val light = listOf(
            "com.khm.snippets.core.git.GitWireClient", "com.khm.snippets.core.git.GitWireBody", "java.net.URI",
        )

        private fun isHeavy(className: String): Boolean =
            light.none { className.startsWith(it) } && heavyPackages.any { className.startsWith(it) }
    }
}
