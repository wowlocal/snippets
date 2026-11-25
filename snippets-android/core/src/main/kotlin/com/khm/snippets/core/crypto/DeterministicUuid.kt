package com.khm.snippets.core.crypto

import java.security.MessageDigest
import java.util.UUID

/**
 * The name-based identifier of a conflict copy (`SyncMerge.deterministicUUID` in Swift):
 * SHA-1 over the namespace's 16 bytes and the name's UTF-8, first 16 bytes, version
 * nibble 5, RFC 4122 variant. Stable across devices, so both sides of a conflict mint the
 * same copy.
 *
 * SHA-1 is not used for security here. `UUID.nameUUIDFromBytes` is not a substitute: it is
 * MD5 (version 3) and takes no namespace.
 */
object DeterministicUuid {

    fun make(namespace: UUID, name: String): UUID {
        val digest = MessageDigest.getInstance("SHA-1")
        digest.update(Uuids.toBytes(namespace))
        digest.update(Utf8.encode(name))
        val bytes = digest.digest().copyOf(Uuids.BYTE_COUNT)
        bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x50).toByte()   // version 5
        bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte()   // RFC 4122 variant
        return Uuids.fromBytes(bytes)
    }
}
