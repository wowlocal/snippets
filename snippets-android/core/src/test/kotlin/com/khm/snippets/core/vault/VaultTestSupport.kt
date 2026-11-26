package com.khm.snippets.core.vault

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.json.SwiftVectors
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

// Shared by the vault and backup test packages. All data here is fictional public test data.

/** A storage root of its own for one test, with the folders the app creates. Call [destroy] in a `finally`. */
internal class Scratch(label: String) {
    val root: File = Files.createTempDirectory("snippets-vault-$label-").toFile()
    val locations = StorageLocations(root).also { it.createAllDirectories() }

    val vault: File get() = locations.vaultFile
    val library: File get() = locations.snippetsFile
    val quarantineFolder: File get() = File(locations.vaultFolder, "Quarantine")

    fun put(bytes: ByteArray) {
        Files.write(vault.toPath(), bytes)
    }

    fun put(json: String) = put(json.toByteArray(Charsets.UTF_8))

    fun bytes(): ByteArray? = if (vault.isFile) Files.readAllBytes(vault.toPath()) else null

    fun vaultFile(io: VaultFileIo = VaultFileIo.Default) = VaultFile(locations, io)

    fun destroy() {
        root.deleteRecursively()
    }
}

internal fun entries(folder: File): List<String> = folder.list()?.sorted() ?: emptyList()

/**
 * A file system that can be told to fail. Each hook sees the file an operation is about;
 * throwing from it (an [IOException]) fails that operation before it touches the disk.
 * `after…` hooks run once the real operation has happened, which is how a test models a
 * crash or a failure that arrives after a rename became visible.
 */
internal class FaultyIo : VaultFileIo {
    var beforeRead: (File) -> Unit = {}
    var beforeWrite: (File, ByteArray) -> Unit = { _, _ -> }
    var afterWrite: (File) -> Unit = {}
    var beforeRemove: (File) -> Unit = {}

    /** Every successful write and removal, in order, as `write:<name>` or `remove:<name>`. */
    val log = ArrayList<String>()

    override fun read(file: File): FileRead = try {
        beforeRead(file)
        VaultFileIo.Default.read(file)
    } catch (failure: IOException) {
        FileRead.Unreadable(failure)
    }

    override fun writeAtomically(data: ByteArray, destination: File, temporaryDirectory: File) {
        beforeWrite(destination, data)
        VaultFileIo.Default.writeAtomically(data, destination, temporaryDirectory)
        synchronized(log) { log.add("write:${destination.name}") }
        afterWrite(destination)
    }

    override fun removeDurably(file: File) {
        beforeRemove(file)
        VaultFileIo.Default.removeDurably(file)
        synchronized(log) { log.add("remove:${file.name}") }
    }
}

/** A key store that records what happened to it and can refuse any one kind of operation. */
internal class FaultyKeyStore(val inner: InMemoryVaultKeyStore = InMemoryVaultKeyStore()) : VaultKeyStore {
    var failStore: VaultKeyStoreException? = null
    var failLoad: VaultKeyStoreException? = null
    var failDelete: VaultKeyStoreException? = null
    var presenceOverride: KeyPresence? = null
    var onStore: (String) -> Unit = {}

    /** `store:<kid>`, `load:<kid>`, `delete:<kid>` for every call that succeeded. */
    val log = ArrayList<String>()

    override fun store(key: ByteArray, keyId: String) {
        failStore?.let { throw it }
        inner.store(key, keyId)
        synchronized(log) { log.add("store:$keyId") }
        onStore(keyId)
    }

    override fun load(keyId: String): ByteArray {
        failLoad?.let { throw it }
        return inner.load(keyId).also { synchronized(log) { log.add("load:$keyId") } }
    }

    override fun presence(keyId: String): KeyPresence = presenceOverride ?: inner.presence(keyId)

    override fun delete(keyId: String) {
        failDelete?.let { throw it }
        inner.delete(keyId)
        synchronized(log) { log.add("delete:$keyId") }
    }

    override fun addIfAbsent(key: ByteArray, keyId: String): ByteArray {
        failStore?.let { throw it }
        return inner.addIfAbsent(key, keyId)
    }

    override fun availability(): KeyStorageAvailability = inner.availability()
}

/** The device owner, scripted. Counts prompts and can hold one open until the test decides. */
internal class FakeAuthenticator(var result: VaultAuthenticationResult = VaultAuthenticationResult.SUCCESS) : VaultAuthenticator {
    val count = AtomicInteger()
    val reasons = ArrayList<VaultAuthenticationReason>()

    /** When set, the next prompt waits for it. */
    var gate: CompletableDeferred<VaultAuthenticationResult>? = null
    var started: CompletableDeferred<Unit>? = null
    var throwing: Exception? = null

    override suspend fun authenticate(reason: VaultAuthenticationReason): VaultAuthenticationResult {
        count.incrementAndGet()
        synchronized(reasons) { reasons.add(reason) }
        started?.complete(Unit)
        throwing?.let { throw it }
        return gate?.await() ?: result
    }
}

internal class FakeClock(var now: Long = 1_000_000) : MonotonicClock {
    override fun nowMillis(): Long = now

    fun advance(millis: Long) {
        now += millis
    }
}

// Fixtures in the shape of `VaultDocumentTests.swift`

/** 2026-07-29T08:00:00Z, on a millisecond boundary that is exact in binary. Seconds since 2001. */
internal const val EPOCH: Double = 1_785_312_000.0 - 978_307_200.0

internal fun at(seconds: Double): Double = EPOCH + seconds

internal fun id(index: Int): UUID = UUID.fromString("00000000-0000-4000-8000-%012x".format(index))

internal const val THIS_DEVICE = "aabbccdd"

internal fun clock(wallMs: Long, counter: Int = 0): Hlc = Hlc.of(wallMs, counter, THIS_DEVICE)

internal fun record(
    index: Int,
    name: String = "AWS root password",
    keyword: String = "awsroot",
    tags: List<String> = listOf("work", "prod"),
    isEnabled: Boolean = true,
    isPinned: Boolean = false,
    createdAt: Double = 0.0,
    updatedAt: Double = 0.5,
    contentHash: String = "9d2b7c41f0a3",
    sealed: String = "v1.k-7f3a91c0.bm9uY2U.Y2lwaGVy",
    x: Map<String, JsonValue> = emptyMap(),
): VaultRecord = VaultRecord(
    id(index), name, keyword, tags, isEnabled, isPinned, at(createdAt), at(updatedAt),
    clock(1_785_312_000_500, index), contentHash, sealed, x,
)

internal fun document(
    schemaVersion: Long = VaultDocument.CURRENT_SCHEMA_VERSION,
    wrapCLI: String? = null,
    x: Map<String, JsonValue> = emptyMap(),
    kdfX: Map<String, JsonValue> = emptyMap(),
    records: List<VaultRecord> = listOf(record(0), record(1, name = "Recovery codes", keyword = "codes")),
): VaultDocument = VaultDocument(
    schemaVersion = schemaVersion,
    kid = "k-7f3a91c0",
    vaultSalt = "3Qk5Yy1xQfC0Zr8mHn2pQw",
    kdf = VaultKdfParameters(PassphraseKdf.ALGORITHM, PassphraseKdf.ITERATIONS, "Yh8pQm4kL1sTz0Wc7Vb9Ng", kdfX),
    wrapPass = "v1.k-7f3a91c0.pass.bm9uY2U.d3JhcA",
    wrapRecovery = "v1.k-7f3a91c0.recovery.bm9uY2U.d3JhcA",
    wrapCLI = wrapCLI,
    x = x,
    records = records,
)

/** A real vault: a key, a document with [bodies] sealed under it, and the salt as bytes. */
internal class RealVault(kid: String = "k-test-vault", vararg bodies: Pair<UUID, String>) {
    val keyring: SnippetCrypto.Keyring = SnippetCrypto.Keyring.generate()
    val key: ByteArray get() = keyring.libraryKey()
    val document: VaultDocument = VaultDocument(
        kid = kid,
        vaultSalt = Base64Url.encode(keyring.salt()),
        kdf = VaultKdfParameters(PassphraseKdf.ALGORITHM, PassphraseKdf.ITERATIONS, Base64Url.encode(PassphraseKdf.makeSalt())),
        records = bodies.mapIndexed { index, (id, body) -> secureRecord(kid, keyring, id, body, index) },
    )
}

internal fun secureRecord(
    kid: String,
    keyring: SnippetCrypto.Keyring,
    id: UUID,
    body: String,
    index: Int = 0,
    name: String = "Secret $index",
    keyword: String = "secret-$index",
): VaultRecord {
    val plaintext = body.toByteArray(Charsets.UTF_8)
    return VaultRecord(
        id = id, name = name, keyword = keyword, tags = listOf("Private"), isEnabled = true, isPinned = false,
        createdAt = at(index.toDouble()), updatedAt = at(index + 0.5),
        hlc = clock(1_785_312_000_000 + index),
        contentHash = SnippetCrypto.contentHash(plaintext, keyring),
        sealed = SnippetCrypto.seal(plaintext, SnippetCrypto.RecordContext(kid, id), keyring),
    )
}

// Values as the Swift interop tool writes them (`J` in `tools/swift-interop`)

/** `{"t": "integer", "v": "7"}` and friends. */
internal fun vectorJsonValue(element: JsonElement): JsonValue {
    val tagged = element.jsonObject
    return when (val type = tagged.getValue("t").jsonPrimitive.content) {
        "null" -> JsonValue.Null
        "bool" -> JsonValue.Bool(tagged.getValue("v").jsonPrimitive.boolean)
        "integer" -> JsonValue.Integer(tagged.getValue("v").jsonPrimitive.content.toLong())
        "double" -> JsonValue.Real(SwiftVectors.Case.double(tagged))
        "string" -> JsonValue.Text(tagged.getValue("v").jsonPrimitive.content)
        "array" -> JsonValue.Array(tagged.getValue("v").jsonArray.map(::vectorJsonValue))
        "object" -> JsonValue.Object(vectorBag(tagged.getValue("v")))
        else -> error("unknown vector value type $type")
    }
}

/** `[{"k": …, "v": …}]`. */
internal fun vectorBag(element: JsonElement): Map<String, JsonValue> =
    element.jsonArray.associate { it.jsonObject.getValue("k").jsonPrimitive.content to vectorJsonValue(it.jsonObject.getValue("v")) }

private fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.content

private fun JsonObject.optionalText(key: String): String? = getValue(key).takeUnless { it is JsonNull }?.jsonPrimitive?.content

/** A vault document as the vectors describe one: field values, dates as bit patterns, bags as lists. */
internal fun vectorDocument(element: JsonElement): VaultDocument {
    val root = element.jsonObject
    val kdf = root.getValue("kdf").jsonObject
    return VaultDocument(
        schemaVersion = root.getValue("schemaVersion").jsonPrimitive.long,
        kid = root.text("kid"),
        vaultSalt = root.text("vaultSalt"),
        kdf = VaultKdfParameters(kdf.text("alg"), kdf.getValue("iterations").jsonPrimitive.long, kdf.text("saltP"), vectorBag(kdf.getValue("x"))),
        wrapPass = root.optionalText("wrapPass"),
        wrapRecovery = root.optionalText("wrapRecovery"),
        wrapCLI = root.optionalText("wrapCLI"),
        x = vectorBag(root.getValue("x")),
        records = root.getValue("records").jsonArray.map { item ->
            val record = item.jsonObject
            VaultRecord(
                id = Uuids.parse(record.text("id"))!!,
                name = record.text("name"),
                keyword = record.text("keyword"),
                tags = record.getValue("tags").jsonArray.map { it.jsonPrimitive.content },
                isEnabled = record.getValue("isEnabled").jsonPrimitive.boolean,
                isPinned = record.getValue("isPinned").jsonPrimitive.boolean,
                createdAt = SwiftVectors.Case.double(record.getValue("createdAt")),
                updatedAt = SwiftVectors.Case.double(record.getValue("updatedAt")),
                hlc = Hlc.parse(record.text("hlc"))!!,
                contentHash = record.text("contentHash"),
                sealed = record.text("sealed"),
                x = vectorBag(record.getValue("x")),
            )
        },
    )
}

/** Bit-exact comparison of every timestamp, which `==` on doubles would not give for `-0.0` and NaN. */
internal fun timestampBits(document: VaultDocument): List<String> = document.records.flatMap {
    listOf(java.lang.Long.toHexString(it.createdAt.toRawBits()), java.lang.Long.toHexString(it.updatedAt.toRawBits()))
}
