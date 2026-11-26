package com.khm.snippets.core.vault

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.model.Snippet
import java.nio.file.Files
import java.util.UUID
import kotlin.coroutines.EmptyCoroutineContext

/** Simulates the process dying at this point: not an `Exception`, so no rollback code catches it. */
internal class SimulatedCrash : Error("the process died here")

/** Keeps the move marker in memory, as `Sync/state.json` does on disk, and records what was written. */
internal class RecordingMarkers : MoveMarkerStore {
    var current: MoveMarker = MoveMarker.None
    val written = ArrayList<MoveMarker>()

    override fun read(): MoveMarker = current

    override fun write(marker: MoveMarker) {
        current = marker
        written.add(marker)
    }
}

/** A sync bookkeeping that records the calls the store makes and can refuse or fail any of them. */
internal class RecordingSync : SecureSyncBookkeeping {
    var secureHistory = false
    var pendingConflicts = false
    var sourceHlc: Hlc = Hlc.of(1, 0, "0badc0de")
    var refuseMove: String? = null
    var refusePersist: String? = null
    var refuseForget: String? = null
    var failPrunedWrite: String? = null
    var rollbackFailures: List<String> = emptyList()

    /** `move:<id>`, `promotion:<id>`, `demotion:<id>`, `forget:<n>`, `pruned`, `rollback`. */
    val events = ArrayList<String>()
    var onEvent: (String) -> Unit = {}
    var lastDestination: VaultRecord? = null
    var lastSnippetsSeen: List<Snippet> = emptyList()

    private fun event(name: String) {
        events.add(name)
        onEvent(name)
    }

    override fun hasSecureSyncHistory(): Boolean = secureHistory

    override fun hasPendingSecureConflicts(): Boolean = pendingConflicts

    override fun prepareMove(snippets: List<Snippet>, records: List<VaultRecord>, vaultKid: String, id: UUID): PreparedSecureMove {
        refuseMove?.let { throw SecureMoveRefused(it) }
        event("move:$id")
        lastSnippetsSeen = snippets
        return object : PreparedSecureMove {
            override val sourceHlc: Hlc = this@RecordingSync.sourceHlc

            override fun persistPromotionDestination(destination: VaultRecord, origin: String): VaultRecord {
                refusePersist?.let { throw SecureMoveRefused(it) }
                event("promotion:${destination.id}")
                lastDestination = destination
                return destination
            }

            override fun persistDemotionSource() {
                refusePersist?.let { throw SecureMoveRefused(it) }
                event("demotion:$id")
            }
        }
    }

    override fun prepareForget(forgottenIds: Set<UUID>, records: List<VaultRecord>, vaultKid: String?): PreparedSecureForget {
        refuseForget?.let { throw SecureForgetRefused(it) }
        event("forget:${forgottenIds.size}")
        return object : PreparedSecureForget {
            override fun writePrunedState() {
                failPrunedWrite?.let { throw SecureForgetRefused(it) }
                event("pruned")
            }

            override fun rollback(): List<String> {
                event("rollback")
                return rollbackFailures
            }
        }
    }
}

internal class MutablePolicy(
    override var libraryOwnsVault: Boolean = false,
    override var syncIsEnabled: Boolean = false,
) : VaultProviderPolicy

/** A whole secure-snippet stack over one scratch root, with every seam observable. */
internal class Components(
    label: String,
    val scratch: Scratch = Scratch(label),
    val keys: FaultyKeyStore = FaultyKeyStore(),
    val policy: MutablePolicy = MutablePolicy(),
    val sync: RecordingSync = RecordingSync(),
    val markers: RecordingMarkers = RecordingMarkers(),
    idleWindowMillis: Long = VaultSession.DEFAULT_IDLE_WINDOW_MILLIS,
) {
    val io = FaultyIo()
    val owner = FakeAuthenticator()
    val time = FakeClock()
    val session = VaultSession(keys, owner, time, idleWindowMillis, null, EmptyCoroutineContext)

    /** Seconds since 2001, read by the store for `updatedAt`. */
    var now: Double = at(1000.0)

    val store = SecureSnippetStore(
        session, keys, scratch.locations, deviceId = THIS_DEVICE,
        policy = policy, sync = sync, markers = markers, io = io, now = { now },
    )

    val reveal = VaultAuthenticationReason.Reveal("a snippet")

    fun writeLibrary(vararg snippets: Snippet) {
        Files.write(scratch.library.toPath(), SnippetLibraryCodec.encode(snippets.toList()))
    }

    fun library(): List<Snippet> =
        if (scratch.library.isFile) SnippetLibraryCodec.decode(Files.readAllBytes(scratch.library.toPath())) else emptyList()

    fun libraryText(): String = String(Files.readAllBytes(scratch.library.toPath()), Charsets.UTF_8)

    fun vaultOnDisk(): VaultDocument? = scratch.vaultFile().load().valueOrNull

    fun vaultText(): String = String(Files.readAllBytes(scratch.vault.toPath()), Charsets.UTF_8)

    /** Sets up a vault the way the UI does, and returns the recovery key text that was shown. */
    fun createVault(): String {
        val pending = store.prepareVaultCreationIfNeeded() ?: error("a vault already exists")
        val text = pending.recoveryKeyText
        store.commitVaultCreation(pending)
        return text
    }

    /** A second stack on the same files and key store: the app after a restart. */
    fun restarted(label: String = "restart"): Components =
        Components(label, scratch = scratch, keys = keys, policy = policy, sync = sync, markers = markers)

    fun destroy() = scratch.destroy()
}

internal fun snippet(index: Int, name: String = "Snippet $index", keyword: String = "kw$index", content: String = "body $index"): Snippet =
    Snippet(id(index), name, keyword, content, listOf("tag"), true, false, at(index.toDouble()), at(index + 0.5))
