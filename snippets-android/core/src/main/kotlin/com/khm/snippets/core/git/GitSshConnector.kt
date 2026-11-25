package com.khm.snippets.core.git

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One SSH exec channel running a git service.
 *
 * The streams block; [GitSshExchangeRunner] reads and writes them on I/O threads.
 * [close] must be safe to call at any time and from any thread, and must make every
 * blocked read and write on the channel return or throw promptly: it is how an
 * exchange is cancelled or timed out.
 */
interface GitSshChannel {
    /** What the service writes. */
    val stdout: InputStream

    /** Diagnostics from the remote side. Classified into a closed code, then dropped. */
    val stderr: InputStream

    /** What the service reads. Closing it sends EOF on the channel. */
    val stdin: OutputStream

    /**
     * The service's exit status, awaited after [stdout] reached its end. Null when
     * the channel ended without one (the connection went away).
     */
    suspend fun exitStatus(): Int?

    /** Releases the channel, aborting whatever is still running. Idempotent. */
    fun close()
}

/**
 * Opens exec channels for git services over SSH.
 *
 * `command` is exactly what git itself runs (`git-upload-pack '<path>'`), see
 * [GitSshClient.remoteCommand]. An implementation requests one exec channel per call
 * with no pty, no agent or X11 forwarding and **no environment** (`GIT_PROTOCOL` must
 * not be sent: this client speaks protocol v0/v1 only).
 *
 * Failures are [GitRemoteFailure]s (`SshHostKeyUnknown`, `SshHostKeyChanged`,
 * `SshPermissionDenied`, `Unreachable("ssh_connection")`, …). Nothing a server says is
 * ever returned or logged.
 */
interface GitSshConnector {
    suspend fun open(command: String, location: GitSshLocation): GitSshChannel
}

/** Used where SSH has no connector. */
class GitUnavailableSshConnector : GitSshConnector {
    override suspend fun open(command: String, location: GitSshLocation): GitSshChannel =
        throw GitRemoteFailure.UnsupportedServer("ssh")
}

/** What one SSH exec channel produced. */
class GitSshExchange(
    /** The ref advertisement, through its terminating flush packet. */
    val advertisement: ByteArray,
    /** Everything the service wrote after the advertisement. */
    val response: ByteArray,
) {
    override fun equals(other: Any?): Boolean =
        other is GitSshExchange && advertisement.contentEquals(other.advertisement) && response.contentEquals(other.response)

    override fun hashCode(): Int = 31 * advertisement.contentHashCode() + response.contentHashCode()
}

/**
 * Runs one git service over an exec channel.
 *
 * The service speaks first: it writes the ref advertisement, then reads the client's
 * request. The runner reads through the advertisement's flush packet, writes what
 * `request` returns for it (a lone flush packet when it returns null or throws, which
 * ends the service politely), closes the channel's input, and reads the rest until
 * the service exits.
 */
object GitSshExchangeRunner {
    const val DEFAULT_IDLE_TIMEOUT_MILLIS: Long = 120_000
    private const val MAXIMUM_STDERR_BYTES = 65_536
    private const val STDERR_GRACE_MILLIS = 300L

    /**
     * @param maximumBytes the service may write this much plus
     *   [GitWire.MAXIMUM_ADVERTISEMENT_BYTES] in total; the advertisement alone is
     *   limited to the latter.
     * @param idleTimeoutMillis fails the exchange with `Unreachable("ssh_timeout")`
     *   after this long without a byte read or written. A slow but moving transfer
     *   never times out.
     * @param request called once, with the advertisement, on an I/O thread.
     */
    suspend fun exchange(
        connector: GitSshConnector,
        command: String,
        location: GitSshLocation,
        maximumBytes: Long,
        idleTimeoutMillis: Long = DEFAULT_IDLE_TIMEOUT_MILLIS,
        request: (ByteArray) -> GitWireBody?,
    ): GitSshExchange {
        val channel = connector.open(command, location)
        try {
            return Run(channel, maximumBytes, idleTimeoutMillis, request).await()
        } finally {
            channel.close()
        }
    }

    private class Run(
        private val channel: GitSshChannel,
        private val maximumBytes: Long,
        private val idleTimeoutMillis: Long,
        /** Released once used: for a push it holds the pack. */
        private var request: ((ByteArray) -> GitWireBody?)?,
    ) {
        private val failure = AtomicReference<Throwable?>(null)
        private val lastProgress = AtomicLong(System.nanoTime())

        private class Output(val advertisement: ByteArray?, val response: ByteArray)

        private fun progressed() = lastProgress.set(System.nanoTime())

        /** Records the first failure and stops the channel. */
        private fun abort(error: Throwable) {
            failure.compareAndSet(null, error)
            channel.close()
        }

        suspend fun await(): GitSshExchange = coroutineScope {
            val watchdog = launch {
                val interval = (idleTimeoutMillis / 4).coerceIn(10, 5_000)
                while (true) {
                    delay(interval)
                    val idleMillis = (System.nanoTime() - lastProgress.get()) / 1_000_000
                    if (idleMillis > idleTimeoutMillis) {
                        abort(GitRemoteFailure.Unreachable("ssh_timeout"))
                        break
                    }
                }
            }
            val errors = async(Dispatchers.IO) { readErrors() }
            val output = async(Dispatchers.IO) {
                coroutineScope { readOutput { body -> launch(Dispatchers.IO) { write(body) } } }
            }
            try {
                // `readOutput` returns once stdout has ended and the request is written
                // (or its write failed against a service that had already gone).
                val result = output.await()
                // After a timeout or an oversized answer the channel is already closed:
                // there is no status worth waiting for.
                failure.get()?.let { throw it }
                val status = channel.exitStatus()
                // A lingering process on the far side can hold stderr open long after
                // the service is done. What it said within a moment is enough.
                val stderr = withTimeoutOrNull(STDERR_GRACE_MILLIS) { errors.await() }
                    ?: run {
                        channel.close()
                        errors.await()
                    }
                watchdog.cancel()
                finish(result, status, stderr)
            } catch (error: Throwable) {
                // Blocked stream calls do not notice cancellation; closing does, and
                // lets the reader coroutines this scope waits for come to an end.
                channel.close()
                throw error
            }
        }

        private fun finish(output: Output, status: Int?, stderr: ByteArray): GitSshExchange {
            failure.get()?.let { throw it }
            if (output.advertisement != null && (status ?: 0) == 0) {
                return GitSshExchange(output.advertisement, output.response)
            }
            // No exit status and nothing said: the connection went away under us.
            if (status == null && stderr.isEmpty()) throw GitRemoteFailure.Unreachable("ssh_connection")
            throw GitSshDiagnosis.failure(stderr, status ?: 1)
        }

        /** Reads stdout to its end, answering the advertisement through `startWriter` when it completes. */
        private fun readOutput(startWriter: (GitWireBody) -> Unit): Output {
            var head = ByteArray(8 * 1024)
            var headLength = 0
            val scanner = GitPktLine.AdvertisementScanner()
            var advertisement: ByteArray? = null
            var answered = false
            val response = ByteAccumulator()
            var total = 0L
            val chunk = ByteArray(64 * 1024)
            while (true) {
                val count = try {
                    channel.stdout.read(chunk)
                } catch (_: IOException) {
                    failure.compareAndSet(null, GitRemoteFailure.Unreachable("ssh_channel"))
                    -1
                }
                if (count < 0) break
                if (count == 0) continue
                progressed()
                total += count
                if (total > maximumBytes + GitWire.MAXIMUM_ADVERTISEMENT_BYTES) {
                    abort(GitRemoteFailure.ResponseTooLarge())
                    break
                }
                if (answered) {
                    response.append(chunk, 0, count)
                    continue
                }
                if (headLength + count > head.size) head = head.copyOf(maxOf(head.size * 2, headLength + count))
                System.arraycopy(chunk, 0, head, headLength, count)
                headLength += count
                var body: GitWireBody
                try {
                    val end = scanner.end(head, headLength)
                    if (end == null) {
                        if (headLength > GitWire.MAXIMUM_ADVERTISEMENT_BYTES) {
                            abort(GitRemoteFailure.ResponseTooLarge())
                            break
                        }
                        continue
                    }
                    val bytes = head.copyOf(end)
                    advertisement = bytes
                    response.append(head, end, headLength - end)
                    val respond = request
                    request = null
                    body = respond?.invoke(bytes) ?: GitWireBody.of(GitPktLine.flush)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    // A malformed advertisement, or a request that could not be built:
                    // end the service politely and report the failure once it is gone.
                    failure.compareAndSet(null, error)
                    body = GitWireBody.of(GitPktLine.flush)
                }
                answered = true
                head = ByteArray(0)
                // Written off the reader thread: a large pack must not stall reading.
                startWriter(body)
            }
            return Output(advertisement, response.toByteArray())
        }

        private fun write(body: GitWireBody) {
            try {
                body.writeTo(channel.stdin, progress = ::progressed)
                channel.stdin.flush()
            } catch (_: IOException) {
                // The service ended before reading its request; its exit status tells why.
            } finally {
                try {
                    channel.stdin.close()
                } catch (_: IOException) {
                    // Already closed from the far side.
                }
            }
        }

        /** At most 64 KiB is kept; the rest is read and dropped so the remote never blocks on it. */
        private fun readErrors(): ByteArray {
            val kept = ByteArray(MAXIMUM_STDERR_BYTES)
            var length = 0
            val chunk = ByteArray(8 * 1024)
            while (true) {
                val count = try {
                    channel.stderr.read(chunk)
                } catch (_: IOException) {
                    -1
                }
                if (count < 0) break
                progressed()
                val keep = minOf(count, kept.size - length)
                System.arraycopy(chunk, 0, kept, length, keep)
                length += keep
            }
            return kept.copyOf(length)
        }
    }
}
