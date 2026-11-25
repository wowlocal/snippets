package com.khm.snippets.core.git

/** Git's length-prefixed framing (`gitprotocol-common(5)`). */
object GitPktLine {
    /** Four length digits plus 65516 bytes of payload. */
    const val MAXIMUM_PAYLOAD = 65_516

    /** A fresh `0000` each time, so no caller can alter a shared array. */
    val flush: ByteArray get() = "0000".toByteArray(Charsets.US_ASCII)

    sealed interface Packet {
        class Data(val payload: ByteArray) : Packet {
            override fun equals(other: Any?): Boolean = other is Data && payload.contentEquals(other.payload)
            override fun hashCode(): Int = payload.contentHashCode()
            override fun toString(): String = "Data(${payload.size} bytes)"
        }

        data object Flush : Packet
        data object Delimiter : Packet
        data object ResponseEnd : Packet
    }

    fun encode(payload: ByteArray): ByteArray {
        if (payload.size > MAXIMUM_PAYLOAD) throw GitFormatException.invalidPktLine()
        val out = ByteArray(payload.size + 4)
        writeLength(payload.size + 4, out)
        System.arraycopy(payload, 0, out, 4, payload.size)
        return out
    }

    fun line(text: String): ByteArray = encode((text + "\n").toByteArray(Charsets.UTF_8))

    private fun writeLength(length: Int, out: ByteArray) {
        val digits = "0123456789abcdef"
        for (index in 0 until 4) {
            out[index] = digits[(length ushr (12 - 4 * index)) and 0x0f].code.toByte()
        }
    }

    /**
     * Exactly four hex digits of either case. `String.toInt(16)` would also accept a
     * sign, so a hostile `-005` must be refused here.
     */
    private fun readLength(bytes: ByteArray, offset: Int): Int {
        var length = 0
        for (index in offset until offset + 4) {
            val digit = hexValue(bytes[index].toInt())
            if (digit < 0) throw GitFormatException.invalidPktLine()
            length = length shl 4 or digit
        }
        return length
    }

    private enum class Frame { DATA, FLUSH, DELIMITER, RESPONSE_END }

    class Reader(private val bytes: ByteArray, offset: Int = 0) {
        var offset: Int = offset
            private set

        private var payloadStart = 0
        private var payloadLength = 0

        val isAtEnd: Boolean get() = offset >= bytes.size

        /** A copy of everything not yet read. */
        fun remainder(): ByteArray = bytes.copyOfRange(minOf(offset, bytes.size), bytes.size)

        /** An independent reader at the same position, for looking ahead. */
        fun copy(): Reader = Reader(bytes, offset)

        fun next(): Packet? = when (advance()) {
            null -> null
            Frame.FLUSH -> Packet.Flush
            Frame.DELIMITER -> Packet.Delimiter
            Frame.RESPONSE_END -> Packet.ResponseEnd
            Frame.DATA -> Packet.Data(bytes.copyOfRange(payloadStart, payloadStart + payloadLength))
        }

        private fun advance(): Frame? {
            if (offset >= bytes.size) return null
            if (offset + 4 > bytes.size) throw GitFormatException.invalidPktLine()
            when (val length = readLength(bytes, offset)) {
                0 -> {
                    offset += 4
                    return Frame.FLUSH
                }
                1 -> {
                    offset += 4
                    return Frame.DELIMITER
                }
                2 -> {
                    offset += 4
                    return Frame.RESPONSE_END
                }
                3 -> throw GitFormatException.invalidPktLine()
                else -> {
                    if (length > MAXIMUM_PAYLOAD + 4 || length > bytes.size - offset) {
                        throw GitFormatException.invalidPktLine()
                    }
                    payloadStart = offset + 4
                    payloadLength = length - 4
                    offset += length
                    return Frame.DATA
                }
            }
        }

        /**
         * Band 1 is payload, band 2 progress, band 3 a fatal error from the server.
         * Reads through the next flush packet (or the end of the data).
         *
         * Two passes over the frames, so a pack of a hundred megabytes is copied once
         * into an array of its exact size rather than through a growing buffer.
         */
        internal fun demultiplex(): ByteArray {
            val start = offset
            var total = 0L
            scan@ while (true) {
                when (advance()) {
                    null, Frame.FLUSH -> break@scan
                    Frame.DELIMITER, Frame.RESPONSE_END -> throw GitRemoteFailure.ProtocolViolation("side_band")
                    Frame.DATA -> {
                        if (payloadLength == 0) throw GitRemoteFailure.ProtocolViolation("side_band")
                        when (bytes[payloadStart].toInt() and 0xff) {
                            1 -> total += payloadLength - 1
                            2 -> Unit
                            3 -> throw GitRemoteFailure.ProtocolViolation("remote_error")
                            else -> throw GitRemoteFailure.ProtocolViolation("side_band")
                        }
                    }
                }
            }
            val end = offset
            // The band-1 bytes are a subset of one array, so the total fits an array.
            val output = ByteArray(total.toInt())
            var position = 0
            offset = start
            while (offset < end) {
                if (advance() == Frame.DATA && bytes[payloadStart].toInt() == 1) {
                    System.arraycopy(bytes, payloadStart + 1, output, position, payloadLength - 1)
                    position += payloadLength - 1
                }
            }
            return output
        }
    }

    /** Payload text with one trailing newline removed, as git tolerates either form. */
    fun text(payload: ByteArray): String {
        val end = if (payload.isNotEmpty() && payload.last() == '\n'.code.toByte()) payload.size - 1 else payload.size
        return payload.decodeUtf8Lossy(0, end)
    }

    /**
     * The index just past the first top-level flush packet, null while incomplete.
     * Only the first `length` bytes are examined.
     */
    fun advertisementEnd(bytes: ByteArray, length: Int = bytes.size): Int? =
        AdvertisementScanner().end(bytes, length)

    /**
     * [advertisementEnd] for a buffer that grows: it remembers the frames already
     * walked, so scanning a large advertisement as it arrives stays linear.
     */
    internal class AdvertisementScanner {
        private var offset = 0L

        fun end(bytes: ByteArray, length: Int): Int? {
            while (offset + 4 <= length) {
                val frame = readLength(bytes, offset.toInt())
                if (frame == 0) return offset.toInt() + 4
                if (frame < 4) throw GitFormatException.invalidPktLine()
                offset += frame
            }
            return null
        }
    }
}
