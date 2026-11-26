package com.khm.snippets.core.git

import com.khm.snippets.core.git.testing.GitFixture
import com.khm.snippets.core.git.testing.GitTestObjects
import com.khm.snippets.core.git.testing.GitTestServer
import com.khm.snippets.core.git.testing.MainThreadWatch
import com.khm.snippets.core.git.testing.RawSocketServer
import java.io.File
import java.net.InetAddress
import java.net.Socket
import java.nio.file.Files
import java.security.KeyStore
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume

/**
 * `OkHttpGitHttpEngine` where a well-behaved `git http-backend` cannot take it: hosts
 * that stall or drop the connection, TLS, cancellation, and the threads it works on.
 * (Added for the review of the wire layer; the reviewer's own cases are in
 * `review/HttpEngineHostileServerTest`.)
 */
class GitHttpEngineTest {
    private val advertisementType = "application/x-git-upload-pack-advertisement"

    private fun <T> blocking(block: suspend () -> T): T = runBlocking { withTimeout(60_000) { block() } }

    private fun remote(origin: String) =
        GitRemote.https("$origin/repo.git", "main", "user", "token-value", allowsInsecureLoopback = origin.startsWith("http://"))

    private fun ok(type: String, body: ByteArray) =
        "HTTP/1.1 200 OK\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray() + body

    private val head = GitObjectId.hash(GitObjectType.BLOB, "x".toByteArray())
    private val pushable = GitRefAdvertisement(mapOf("refs/heads/main" to head), mapOf("report-status" to null))

    // MARK: Retries (review findings 4 and 5)

    /** A started upload is never sent a second time, whatever killed the first. */
    @Test fun aPostWhoseConnectionDiesMidUploadIsNotRetried() {
        val posts = CopyOnWriteArrayList<Int>()
        RawSocketServer { socket, index ->
            // The request head and the first part of the pack arrive; then the connection is reset.
            val head = readHeadOf(socket) ?: return@RawSocketServer
            if (head.startsWith("POST")) posts.add(index)
            val input = socket.getInputStream()
            var remaining = 256 * 1024
            val chunk = ByteArray(16 * 1024)
            while (remaining > 0) {
                val count = input.read(chunk, 0, minOf(chunk.size, remaining))
                if (count < 0) break
                remaining -= count
            }
            socket.setSoLinger(true, 0)
            socket.close()
        }.use { server ->
            OkHttpGitHttpEngine(allowsInsecureLoopback = true).use { engine ->
                val client = GitSmartHttpClient(remote(server.origin), engine)
                val pack = ByteArray(24 * 1024 * 1024) { 7 }
                val failure = assertFailsWith<GitRemoteFailure> { blocking { client.push(head, head, pack, pushable) } }
                assertIs<GitRemoteFailure.Unreachable>(failure)
                assertTrue(failure.detail.startsWith("network"), failure.detail)
                // Time for a retry to show up, if the HTTP stack made one.
                Thread.sleep(700)
                assertEquals(1, posts.size, "git-receive-pack requests that reached the host")
                assertEquals(1, server.connections)
            }
        }
    }

    private fun readHeadOf(socket: Socket): String? {
        val out = StringBuilder()
        val input = socket.getInputStream()
        while (!out.endsWith("\r\n\r\n")) {
            val byte = input.read()
            if (byte < 0) return null
            out.append(byte.toChar())
        }
        return out.toString()
    }

    /** The same for a body-less request that OkHttp would follow up by itself. */
    @Test fun aGetAnswered503Or408IsSentOnceAndKeepsItsRetryAfter() {
        for ((status, header, expected) in listOf(
            Triple("503 Busy", "Retry-After: 0\r\n", GitRemoteFailure.RateLimited(1.0)),
            Triple("503 Busy", "Retry-After: 12\r\n", GitRemoteFailure.RateLimited(12.0)),
            Triple("503 Busy", "", GitRemoteFailure.RateLimited(30.0)),
            // A value the server made up for the engine's private header is not believed.
            Triple("503 Busy", "X-Snippets-Retry-After: 99\r\n", GitRemoteFailure.RateLimited(30.0)),
            Triple("408 Timeout", "", GitRemoteFailure.ProtocolViolation("http_408")),
            Triple("408 Timeout", "Retry-After: 0\r\nConnection: close\r\n", GitRemoteFailure.ProtocolViolation("http_408")),
        )) {
            RawSocketServer { socket, _ ->
                while (readHeadOf(socket) != null) {
                    socket.getOutputStream().write("HTTP/1.1 $status\r\n${header}Content-Length: 0\r\n\r\n".toByteArray())
                    socket.getOutputStream().flush()
                }
            }.use { server ->
                val requests = CopyOnWriteArrayList<String>()
                OkHttpGitHttpEngine(allowsInsecureLoopback = true).use { engine ->
                    val counting = object : GitHttpEngine {
                        override suspend fun execute(request: GitHttpRequest, maximumResponseBytes: Long): GitHttpResponse {
                            requests.add(request.method)
                            return engine.execute(request, maximumResponseBytes)
                        }
                    }
                    val failure = assertFailsWith<GitRemoteFailure> { blocking { GitSmartHttpClient(remote(server.origin), counting).discover(GitService.UPLOAD_PACK) } }
                    assertEquals(expected, failure, "$status $header")
                    Thread.sleep(200)
                    assertEquals(1, requests.size)
                    assertEquals(1, server.connections, "$status $header: connections")
                }
            }
        }
    }

    // MARK: Stalls and cancellation

    @Test fun aHostThatStallsAtAnyPointEndsInTheIdleTimeout() {
        val stalls = listOf<(Socket) -> Unit>(
            // Accepts and never reads.
            { Thread.sleep(30_000) },
            // Reads the request and never answers.
            { socket -> readHeadOf(socket); Thread.sleep(30_000) },
            // Answers the status line and stops.
            { socket -> readHeadOf(socket); socket.getOutputStream().apply { write("HTTP/1.1 200 OK\r\n".toByteArray()); flush() }; Thread.sleep(30_000) },
            // Sends the headers and half the body, then nothing.
            { socket ->
                readHeadOf(socket)
                socket.getOutputStream().apply {
                    write("HTTP/1.1 200 OK\r\nContent-Type: $advertisementType\r\nContent-Length: 4096\r\n\r\n".toByteArray() + ByteArray(2048))
                    flush()
                }
                Thread.sleep(30_000)
            },
            // The same without a declared length.
            { socket ->
                readHeadOf(socket)
                socket.getOutputStream().apply {
                    write("HTTP/1.1 200 OK\r\nContent-Type: $advertisementType\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n0000\r\n".toByteArray())
                    flush()
                }
                Thread.sleep(30_000)
            },
        )
        for ((index, stall) in stalls.withIndex()) {
            RawSocketServer { socket, _ -> stall(socket) }.use { server ->
                OkHttpGitHttpEngine(allowsInsecureLoopback = true, idleTimeoutMillis = 400, requestTimeoutMillis = 30_000).use { engine ->
                    val started = System.nanoTime()
                    val failure = assertFailsWith<GitRemoteFailure>("stall $index") {
                        blocking { GitSmartHttpClient(remote(server.origin), engine).discover(GitService.UPLOAD_PACK) }
                    }
                    assertEquals(GitRemoteFailure.Unreachable("network_-1001"), failure, "stall $index")
                    assertTrue(System.nanoTime() - started < 5_000_000_000, "stall $index")
                    // A read that timed out is not a reason to ask again.
                    assertEquals(1, server.connections, "stall $index")
                }
            }
        }
    }

    /** A push to a host that stops reading is stuck in the upload itself; cancelling must still end it. */
    @Test fun cancellationDuringABodyUploadIsReportedAsCancellation() {
        RawSocketServer { socket, _ ->
            readHeadOf(socket)
            Thread.sleep(30_000)
        }.use { server ->
            OkHttpGitHttpEngine(allowsInsecureLoopback = true).use { engine ->
                val client = GitSmartHttpClient(remote(server.origin), engine)
                val pack = ByteArray(48 * 1024 * 1024)
                runBlocking {
                    val task = async(Dispatchers.Default) { client.push(head, head, pack, pushable) }
                    delay(500)
                    assertTrue(task.isActive, "the upload is still blocked on the host")
                    val started = System.nanoTime()
                    task.cancel()
                    assertFailsWith<CancellationException> { task.await() }
                    assertTrue(System.nanoTime() - started < 2_000_000_000)
                }
                assertEquals(1, server.connections)
            }
        }
    }

    @Test fun aClosedEngineFailsClosedAndCancelsWhatIsInFlight() {
        RawSocketServer { socket, _ ->
            readHeadOf(socket)
            Thread.sleep(30_000)
        }.use { server ->
            val engine = OkHttpGitHttpEngine(allowsInsecureLoopback = true)
            val client = GitSmartHttpClient(remote(server.origin), engine)
            runBlocking {
                val inFlight = async(Dispatchers.Default) { runCatching { client.discover(GitService.UPLOAD_PACK) } }
                delay(300)
                engine.close()
                val failure = withTimeout(5_000) { inFlight.await() }.exceptionOrNull()
                assertIs<GitRemoteFailure.Unreachable>(failure)
                assertIs<GitRemoteFailure.Unreachable>(runCatching { client.discover(GitService.UPLOAD_PACK) }.exceptionOrNull())
            }
            engine.close()
        }
    }

    // MARK: TLS

    /** A throwaway key and self-signed certificate made by the JDK's own `keytool`. */
    private class TestCertificate(names: String) {
        val context: SSLContext
        val trustManager: X509TrustManager

        init {
            val keytool = File(System.getProperty("java.home"), "bin/keytool")
            Assume.assumeTrue("keytool is not part of this JDK", keytool.canExecute())
            val directory = Files.createTempDirectory("git-tls-").toFile()
            try {
                val store = File(directory, "keys.p12")
                val process = ProcessBuilder(
                    keytool.path, "-genkeypair", "-alias", "test", "-keyalg", "EC", "-groupname", "secp256r1",
                    "-dname", "CN=git-test", "-ext", "SAN=$names", "-validity", "2",
                    "-keystore", store.path, "-storetype", "PKCS12", "-storepass", PASSWORD, "-keypass", PASSWORD,
                ).redirectErrorStream(true).start()
                val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
                check(process.waitFor(60, TimeUnit.SECONDS) && process.exitValue() == 0) { "keytool: $output" }
                val keys = KeyStore.getInstance("PKCS12")
                store.inputStream().use { keys.load(it, PASSWORD.toCharArray()) }
                val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keys, PASSWORD.toCharArray()) }
                val trusted = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
                    load(null, null)
                    setCertificateEntry("test", keys.getCertificate("test"))
                }
                val trustManagers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trusted) }
                trustManager = trustManagers.trustManagers.filterIsInstance<X509TrustManager>().first()
                context = SSLContext.getInstance("TLS").apply { init(keyManagers.keyManagers, trustManagers.trustManagers, null) }
            } finally {
                directory.deleteRecursively()
            }
        }

        private companion object {
            const val PASSWORD = "changeit"
        }
    }

    /** One HTTPS answer per connection; records what arrived after each handshake. */
    private class TlsServer(certificate: TestCertificate, protocols: Array<String>?) : AutoCloseable {
        private val server = certificate.context.serverSocketFactory.createServerSocket(0, 50, InetAddress.getByName("127.0.0.1")) as SSLServerSocket
        val heads = CopyOnWriteArrayList<String>()
        val negotiated = CopyOnWriteArrayList<String>()
        val port: Int get() = server.localPort

        init {
            if (protocols != null) server.enabledProtocols = protocols
            thread(name = "tls-test-server", isDaemon = true) {
                while (true) {
                    val socket = try {
                        server.accept() as SSLSocket
                    } catch (_: Exception) {
                        break
                    }
                    thread(isDaemon = true) {
                        runCatching {
                            socket.use {
                                it.startHandshake()
                                negotiated.add(it.session.protocol)
                                val head = StringBuilder()
                                val input = it.inputStream
                                while (!head.endsWith("\r\n\r\n")) {
                                    val byte = input.read()
                                    if (byte < 0) return@use
                                    head.append(byte.toChar())
                                }
                                heads.add(head.toString())
                                it.outputStream.write(
                                    "HTTP/1.1 200 OK\r\nContent-Type: application/x-git-upload-pack-advertisement\r\nContent-Length: 4\r\nConnection: close\r\n\r\n0000".toByteArray(),
                                )
                                it.outputStream.flush()
                            }
                        }
                    }
                }
            }
        }

        override fun close() = server.close()
    }

    private fun trusting(certificate: TestCertificate) = OkHttpGitHttpEngine(false, 10_000, 30_000) { builder ->
        builder.sslSocketFactory(certificate.context.socketFactory, certificate.trustManager)
    }

    @Test fun aTrustedHostIsReachedOverTls12And13WithTheCredentialInsideTheTunnel() {
        val certificate = TestCertificate("dns:localhost,ip:127.0.0.1")
        for (protocol in listOf("TLSv1.3", "TLSv1.2")) {
            TlsServer(certificate, arrayOf(protocol)).use { server ->
                trusting(certificate).use { engine ->
                    // A production remote: `https`, no loopback seam involved.
                    val remote = GitRemote.https("https://localhost:${server.port}/repo.git", "main", "user", "token-value")
                    val advertisement = blocking { GitSmartHttpClient(remote, engine).discover(GitService.UPLOAD_PACK) }
                    assertTrue(advertisement.refs.isEmpty())
                    assertEquals(listOf(protocol), server.negotiated.toList())
                    val expected = "Authorization: Basic " + Base64.getEncoder().encodeToString("user:token-value".toByteArray())
                    assertTrue(server.heads.single().contains(expected))
                    assertTrue(server.heads.single().startsWith("GET /repo.git/info/refs?service=git-upload-pack HTTP/1.1\r\n"))
                }
            }
        }
    }

    @Test fun anUntrustedOrMismatchedCertificateIsATlsFailureAndNoRequestIsSent() {
        val certificate = TestCertificate("dns:localhost,ip:127.0.0.1")
        TlsServer(certificate, null).use { server ->
            // The production engine: the system's trust, which does not include a test certificate.
            OkHttpGitHttpEngine().use { engine ->
                val remote = GitRemote.https("https://localhost:${server.port}/repo.git", "main", "user", "token-value")
                val failure = assertFailsWith<GitRemoteFailure> { blocking { GitSmartHttpClient(remote, engine).discover(GitService.UPLOAD_PACK) } }
                assertEquals(GitRemoteFailure.Unreachable("network_-1200"), failure)
            }
            assertTrue(server.heads.isEmpty(), "no request, and so no credential, without a verified handshake")
        }
        // Trusted, but issued for another name than the one in the address.
        val other = TestCertificate("dns:elsewhere.invalid")
        TlsServer(other, null).use { server ->
            trusting(other).use { engine ->
                val remote = GitRemote.https("https://localhost:${server.port}/repo.git", "main", "user", "token-value")
                val failure = assertFailsWith<GitRemoteFailure> { blocking { GitSmartHttpClient(remote, engine).discover(GitService.UPLOAD_PACK) } }
                assertEquals(GitRemoteFailure.Unreachable("network_-1200"), failure)
            }
            assertTrue(server.heads.isEmpty())
        }
    }

    @Test fun aCleartextHostBehindAnHttpsAddressIsATlsFailure() {
        RawSocketServer { socket, _ ->
            socket.getOutputStream().write(ok(advertisementType, "0000".toByteArray()))
            socket.getOutputStream().flush()
            Thread.sleep(500)
        }.use { server ->
            OkHttpGitHttpEngine().use { engine ->
                val remote = GitRemote.https("https://localhost:${server.port}/repo.git", "main", "user", "token-value")
                val failure = assertFailsWith<GitRemoteFailure> { blocking { GitSmartHttpClient(remote, engine).discover(GitService.UPLOAD_PACK) } }
                assertEquals(GitRemoteFailure.Unreachable("network_-1200"), failure)
            }
        }
    }

    // MARK: Main-safety (review finding 10)

    /** A socket factory that notes which thread connects and closes. */
    private class RecordingSocketFactory : SocketFactory() {
        val threads = CopyOnWriteArrayList<String>()

        private inner class RecordingSocket : Socket() {
            override fun connect(endpoint: java.net.SocketAddress?, timeout: Int) {
                threads.add("connect on ${Thread.currentThread().name}")
                super.connect(endpoint, timeout)
            }

            override fun close() {
                threads.add("close on ${Thread.currentThread().name}")
                super.close()
            }
        }

        override fun createSocket(): Socket = RecordingSocket()
        override fun createSocket(host: String?, port: Int): Socket = RecordingSocket().apply { connect(java.net.InetSocketAddress(host, port)) }
        override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket = createSocket(host, port)
        override fun createSocket(host: InetAddress?, port: Int): Socket = RecordingSocket().apply { connect(java.net.InetSocketAddress(host, port)) }
        override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int): Socket = createSocket(address, port)
    }

    @Test fun everyHttpEntryPointIsMainSafe() {
        GitFixture().use { fixture ->
            MainThreadWatch().use { main ->
                val sockets = RecordingSocketFactory()
                val engine = OkHttpGitHttpEngine(true, 60_000, 600_000) { it.socketFactory(sockets) }
                try {
                    val client = GitSmartHttpClient(fixture.remote(), engine)
                    // Enough content that demultiplexing and request building take real time.
                    val files = (0 until 40).associate { "records/%02x/file-$it.bin".format(it) to ByteArray(400_000).also { bytes -> java.util.Random(it.toLong()).nextBytes(bytes) } }
                    val snapshot = GitTestObjects.snapshot(files)
                    val pack = GitPack.build(snapshot.objects)
                    main.onMain {
                        val receive = client.discover(GitService.RECEIVE_PACK)
                        assertEquals(GitPushResult.UPDATED, client.push(GitObjectId.ZERO, snapshot.id, pack, receive))
                        val upload = client.discover(GitService.UPLOAD_PACK)
                        val fetched = client.fetchPack(snapshot.id, emptyList(), upload)
                        assertTrue(fetched.size > 15_000_000)
                        assertTrue(main.isOnMain, "the caller is resumed where it was")
                    }
                    // Cancellation closes a socket: not on the caller's thread either.
                    fixture.server.intercept = { GitTestServer.Response(200, delayMillis = 5_000) }
                    main.onMain {
                        coroutineScope {
                            val task = async { client.discover(GitService.UPLOAD_PACK) }
                            delay(300)
                            task.cancel()
                            assertFailsWith<CancellationException> { task.await() }
                        }
                    }
                    main.onMain { engine.close() }
                    Thread.sleep(300)
                } finally {
                    engine.close()
                }
                assertEquals(emptySet(), main.heavyWork)
                assertTrue(sockets.threads.any { it.startsWith("connect") } && sockets.threads.any { it.startsWith("close") }, sockets.threads.toString())
                assertTrue(sockets.threads.none { it.contains(MainThreadWatch.NAME) }, sockets.threads.toString())
            }
        }
    }

    /** The watch does see heavy work when it is there: the same parsing, done on the main thread. */
    @Test fun theMainThreadWatchNoticesParsingOnTheMainThread() {
        MainThreadWatch().use { main ->
            val payload = ByteArray(48 * 1024 * 1024)
            var stream = GitPktLine.line("NAK")
            val frame = GitPktLine.encode(byteArrayOf(1) + ByteArray(60_000))
            val framed = java.io.ByteArrayOutputStream()
            repeat(payload.size / 60_000) { framed.write(frame) }
            stream += framed.toByteArray() + GitPktLine.flush
            main.onMain { repeat(8) { GitWire.extractPack(stream, false, "side-band-64k") } }
            assertTrue(main.heavyWork.any { it.contains("GitPktLine") || it.contains("GitWire") }, main.heavyWork.toString())
        }
    }
}
