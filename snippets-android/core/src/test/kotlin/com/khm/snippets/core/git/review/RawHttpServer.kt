package com.khm.snippets.core.git.review

import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * A loopback HTTP/1.1 server that writes exactly the bytes a test gives it, so a test
 * can play a hostile or broken host: malformed framing, lying lengths, connections
 * dropped at a chosen moment. (`GitTestServer` cannot: the JDK's `HttpServer` only
 * emits well-formed responses.)
 */
internal class RawHttpServer(private val answer: (Request) -> Answer) : AutoCloseable {
    class Request(
        /** Which accepted connection this arrived on, from 0. */
        val connection: Int,
        /** Which request on that connection, from 0. */
        val index: Int,
        val head: String,
        val body: ByteArray,
    ) {
        val method: String get() = head.substringBefore(' ')
        val target: String get() = head.substringAfter(' ').substringBefore(' ')
        fun header(name: String): String? =
            head.lines().drop(1).firstOrNull { it.startsWith("$name:", ignoreCase = true) }?.substringAfter(':')?.trim()
    }

    /** `closeAfterMillis == null` keeps the connection open for another request. */
    class Answer(val bytes: ByteArray, val closeAfterMillis: Long? = null) {
        constructor(text: String, closeAfterMillis: Long? = null) : this(text.toByteArray(Charsets.ISO_8859_1), closeAfterMillis)
    }

    private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    private val accepted = AtomicInteger()
    private val log = CopyOnWriteArrayList<Request>()

    val port: Int get() = server.localPort
    val origin: String get() = "http://127.0.0.1:$port"
    val connections: Int get() = accepted.get()
    val requests: List<Request> get() = log.toList()

    init {
        thread(name = "raw-http-accept", isDaemon = true) {
            while (true) {
                val socket = try {
                    server.accept()
                } catch (_: Exception) {
                    break
                }
                val connection = accepted.getAndIncrement()
                thread(name = "raw-http-$connection", isDaemon = true) { serve(socket, connection) }
            }
        }
    }

    private fun serve(socket: Socket, connection: Int) {
        try {
            val input = socket.getInputStream()
            var index = 0
            while (true) {
                val head = ByteArrayOutputStream()
                var matched = 0
                while (matched < 4) {
                    val byte = input.read()
                    if (byte < 0) return
                    head.write(byte)
                    val expected = if (matched % 2 == 0) '\r'.code else '\n'.code
                    matched = if (byte == expected) matched + 1 else if (byte == '\r'.code) 1 else 0
                }
                val text = head.toString(Charsets.ISO_8859_1)
                val length = Regex("(?im)^content-length:\\s*(\\d+)").find(text)?.groupValues?.get(1)?.toInt() ?: 0
                val body = ByteArray(length)
                var read = 0
                while (read < length) {
                    val count = input.read(body, read, length - read)
                    if (count < 0) return
                    read += count
                }
                val request = Request(connection, index++, text, body)
                log.add(request)
                val response = answer(request)
                socket.getOutputStream().write(response.bytes)
                socket.getOutputStream().flush()
                if (response.closeAfterMillis != null) {
                    Thread.sleep(response.closeAfterMillis)
                    return
                }
            }
        } catch (_: Exception) {
            // The client went away.
        } finally {
            runCatching { socket.close() }
        }
    }

    override fun close() {
        server.close()
    }

    companion object {
        fun ok(contentType: String, body: ByteArray, extraHeaders: String = ""): ByteArray =
            ("HTTP/1.1 200 OK\r\nContent-Type: $contentType\r\n${extraHeaders}Content-Length: ${body.size}\r\n\r\n")
                .toByteArray(Charsets.ISO_8859_1) + body
    }
}
