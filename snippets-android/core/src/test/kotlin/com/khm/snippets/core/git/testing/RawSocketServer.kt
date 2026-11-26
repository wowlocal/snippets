package com.khm.snippets.core.git.testing

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * A loopback TCP server whose handler owns the socket: for hosts that stall, stop
 * reading, or drop the connection at a chosen byte. (`GitTestServer` always reads
 * the whole request and answers well-formed HTTP.)
 */
class RawSocketServer(private val handler: (Socket, Int) -> Unit) : Closeable {
    private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    private val accepted = AtomicInteger()
    private val sockets = CopyOnWriteArrayList<Socket>()
    private val heads = CopyOnWriteArrayList<String>()

    val port: Int get() = server.localPort
    val origin: String get() = "http://127.0.0.1:$port"

    /** Connections accepted so far. */
    val connections: Int get() = accepted.get()

    /** Every request head a handler read with [readHead]. */
    val requestHeads: List<String> get() = heads.toList()

    init {
        thread(name = "raw-socket-accept", isDaemon = true) {
            while (true) {
                val socket = try {
                    server.accept()
                } catch (_: Exception) {
                    break
                }
                sockets.add(socket)
                val index = accepted.getAndIncrement()
                thread(name = "raw-socket-$index", isDaemon = true) {
                    try {
                        handler(socket, index)
                    } catch (_: Exception) {
                        // The client went away, or the test closed the server.
                    } finally {
                        runCatching { socket.close() }
                    }
                }
            }
        }
    }

    /** Reads through the blank line that ends an HTTP request head, and records it. */
    fun readHead(input: InputStream): String? {
        val head = ByteArrayOutputStream()
        var matched = 0
        while (matched < 4) {
            val byte = input.read()
            if (byte < 0) return null
            head.write(byte)
            val expected = if (matched % 2 == 0) '\r'.code else '\n'.code
            matched = if (byte == expected) matched + 1 else if (byte == '\r'.code) 1 else 0
        }
        return head.toString(Charsets.ISO_8859_1).also { heads.add(it) }
    }

    override fun close() {
        server.close()
        sockets.forEach { runCatching { it.close() } }
    }
}
