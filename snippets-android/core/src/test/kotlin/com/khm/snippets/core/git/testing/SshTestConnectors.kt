package com.khm.snippets.core.git.testing

import com.khm.snippets.core.git.GitSshChannel
import com.khm.snippets.core.git.GitSshConnector
import com.khm.snippets.core.git.GitSshLocation
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Runs the remote command locally with `/bin/sh -c` in `root`, so
 * `git@host:repo.git` reaches `root/repo.git` and the exchange carries exactly the
 * bytes an SSH exec channel would. The stand-in for the Swift tests' fake `ssh`: it
 * logs every command and can fail with a scripted status and stderr text.
 */
class ProcessGitSshConnector(private val root: File) : GitSshConnector {
    private val log = CopyOnWriteArrayList<String>()

    /** Every command asked for, in order. */
    val commands: List<String> get() = log.toList()

    /** When set, every exchange prints this stderr text and exits with this status instead. */
    @Volatile var failure: Pair<Int, String>? = null

    /** When set, run this shell text instead of the command. */
    @Volatile var script: String? = null

    /** Overrides `PATH` (to hide git from the "remote" shell). */
    @Volatile var searchPath: String? = null

    override suspend fun open(command: String, location: GitSshLocation): GitSshChannel {
        log.add(command)
        val failure = failure
        val shell = when {
            failure != null -> "cat <<'SNIPPETS_EOF' >&2\n${failure.second}\nSNIPPETS_EOF\nexit ${failure.first}"
            else -> script ?: command
        }
        val builder = ProcessBuilder("/bin/sh", "-c", shell).directory(root)
        builder.environment().clear()
        builder.environment().putAll(GitBinary.isolatedEnvironment(root))
        searchPath?.let { builder.environment()["PATH"] = it }
        val process = withContext(Dispatchers.IO) { builder.start() }
        return object : GitSshChannel {
            override val stdout: InputStream = process.inputStream
            override val stderr: InputStream = process.errorStream
            override val stdin: OutputStream = process.outputStream
            override suspend fun exitStatus(): Int? = withContext(Dispatchers.IO) {
                if (process.waitFor(60, TimeUnit.SECONDS)) process.exitValue() else null
            }

            override fun close() {
                process.destroyForcibly()
            }
        }
    }
}

/** An in-memory byte pipe whose blocked reads and writes end as soon as either side closes. */
class BlockingPipe(private val capacity: Int = Int.MAX_VALUE) {
    private val lock = Object()
    private val buffer = ArrayDeque<ByteArray>()
    private var buffered = 0
    private var head = 0
    private var writerClosed = false
    private var readerClosed = false

    val input: InputStream = object : InputStream() {
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(target: ByteArray, offset: Int, length: Int): Int = synchronized(lock) {
            while (buffered == 0 && !writerClosed && !readerClosed) lock.wait()
            if (readerClosed) throw IOException("closed")
            if (buffered == 0) return -1
            val first = buffer.first()
            val count = minOf(length, first.size - head)
            System.arraycopy(first, head, target, offset, count)
            head += count
            buffered -= count
            if (head == first.size) {
                buffer.removeFirst()
                head = 0
            }
            lock.notifyAll()
            count
        }

        override fun close() = synchronized(lock) {
            readerClosed = true
            lock.notifyAll()
        }
    }

    val output: OutputStream = object : OutputStream() {
        override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)

        override fun write(source: ByteArray, offset: Int, length: Int) = synchronized(lock) {
            var from = offset
            var remaining = length
            while (remaining > 0) {
                while (buffered >= capacity && !readerClosed && !writerClosed) lock.wait()
                if (readerClosed || writerClosed) throw IOException("closed")
                val count = minOf(remaining, capacity - buffered)
                buffer.addLast(source.copyOfRange(from, from + count))
                buffered += count
                from += count
                remaining -= count
                lock.notifyAll()
            }
        }

        override fun close() = synchronized(lock) {
            writerClosed = true
            lock.notifyAll()
        }
    }
}

/**
 * A scripted git service: `serve` runs on its own thread for each exchange, talks
 * through [Server] and returns the exit status (null: the connection just went away).
 * Pipes hold `pipeCapacity` bytes, so a test can stage real back-pressure.
 */
class FakeSshConnector(
    private val pipeCapacity: Int = Int.MAX_VALUE,
    private val serve: (Server) -> Int?,
) : GitSshConnector {
    class Server(
        /** What the client wrote; ends when the client closes its input side. */
        val fromClient: InputStream,
        val toClient: OutputStream,
        val errors: OutputStream,
        /** Leaves stderr open after the service has "exited", like a lingering child process. */
        @Volatile var holdsErrorsOpen: Boolean = false,
    ) {
        fun send(bytes: ByteArray) {
            toClient.write(bytes)
            toClient.flush()
        }

        fun send(text: String) = send(text.toByteArray())

        /** Everything the client sends until it closes its input. */
        fun readRequest(): ByteArray {
            val out = ByteArrayOutputStream()
            val chunk = ByteArray(64 * 1024)
            while (true) {
                val count = fromClient.read(chunk)
                if (count < 0) break
                out.write(chunk, 0, count)
            }
            return out.toByteArray()
        }
    }

    private val log = CopyOnWriteArrayList<String>()
    private val opened = AtomicInteger()
    private val closed = AtomicInteger()

    val commands: List<String> get() = log.toList()
    val channelsOpened: Int get() = opened.get()
    val channelsClosed: Int get() = closed.get()

    override suspend fun open(command: String, location: GitSshLocation): GitSshChannel {
        log.add(command)
        opened.incrementAndGet()
        val toService = BlockingPipe(pipeCapacity)
        val fromService = BlockingPipe(pipeCapacity)
        val errors = BlockingPipe()
        val status = CompletableDeferred<Int?>()
        val server = Server(toService.input, fromService.output, errors.output)
        thread(name = "fake-git-service", isDaemon = true) {
            val result = runCatching { serve(server) }
            // A service that exits drops its ends of all three streams.
            toService.input.close()
            fromService.output.close()
            if (!server.holdsErrorsOpen) errors.output.close()
            status.complete(result.getOrNull())
        }
        return object : GitSshChannel {
            private var isClosed = false
            override val stdout: InputStream = fromService.input
            override val stderr: InputStream = errors.input
            override val stdin: OutputStream = toService.output
            override suspend fun exitStatus(): Int? = status.await()

            @Synchronized
            override fun close() {
                if (isClosed) return
                isClosed = true
                closed.incrementAndGet()
                fromService.input.close()
                errors.input.close()
                toService.output.close()
                toService.input.close()
                fromService.output.close()
                status.complete(null)
            }
        }
    }
}
