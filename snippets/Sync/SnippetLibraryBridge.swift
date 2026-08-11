import Foundation

/// Presents `SnippetStore` and `SecureSnippetStore` to the sync engine as one library.
///
/// The engine deals only in envelopes and knows nothing about two files, a vault, or a
/// lock. This is where that translation lives — and it is the piece whose absence meant
/// nothing could construct a `SyncEngine`.
///
/// ## A secure record syncs while the vault is locked
///
/// Its envelope carries the **sealed** bytes verbatim, exactly as they sit in
/// `vault.json`, never a re-encryption. Three things follow, and all of them matter:
///
/// - Syncing needs no key, so a locked Mac still participates.
/// - The bytes are stable, so an unchanged record does not look changed every time it
///   is sent, which is what would otherwise make two devices trade writes forever.
/// - The keyed vault content hash travels inside the envelope's encrypted extension
///   bag, so importing ciphertext never replaces the vault HMAC with a SHA of the
///   sealed bytes.
@MainActor
final class SnippetLibraryBridge: SyncLibraryAccess {

    private let store: SnippetStore
    private let secureStore: SecureSnippetStore
    private let lockTimeout: TimeInterval
    private let metadataURL: URL
    private let temporaryDirectory: URL
    private var metadataCache: SyncBase?

    private struct ApplyResult {
        var changedIDs: [UUID]
        var appliedEnvelopes: [SyncEnvelope]
        var deferredIDs: [UUID] = []
        var incompatibleVaultIDs: [UUID] = []
    }

    init(
        store: SnippetStore,
        secureStore: SecureSnippetStore,
        lockTimeout: TimeInterval = 2.0,
        metadataURL: URL = SnippetStorageLocations.syncLibraryMetadataFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) {
        self.store = store
        self.secureStore = secureStore
        self.lockTimeout = lockTimeout
        self.metadataURL = metadataURL
        self.temporaryDirectory = temporaryDirectory
    }

    // MARK: - Reading

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        let metadata = loadMetadata(fallingBackTo: agreedBase)
        try refuseToSpeakForAnUnreadableVault(against: agreedBase, metadata: metadata)

        let envelopes = SyncLibraryProjection.currentEnvelopes(
            snippets: store.snippets,
            records: secureStore.document?.records ?? [],
            deviceID: store.deviceID,
            metadata: metadata,
            agreedBase: agreedBase,
            vaultKID: secureStore.document?.kid)
        persistMetadata(envelopes)
        return envelopes
    }

    /// Halts rather than letting a vault this Mac cannot read be projected as an empty one.
    ///
    /// The projection takes `secureStore.document?.records ?? []`, and
    /// `SyncBase.pendingChanges` turns "in the base, absent from the projection" into an
    /// explicit tombstone. Those two are only correct together while the absence is
    /// *real*. A vault that failed to **load** — written by a newer build, corrupt,
    /// unreadable, or a file that went missing — projects as zero records too, and the
    /// result is a tombstone for every secure snippet this device ever synced, pushed to
    /// every other Mac, waved through by `DeletionGuard` because five records is not a
    /// mass deletion. A read failure on one machine would delete the user's secrets on all
    /// of them.
    ///
    /// `SyncCoordinator` used to hold this line by accident: `makeSealer()` threw when the
    /// vault document was nil, so no engine existed to push anything. Splitting the wire
    /// key off the vault key removed that coupling, and this replaces it deliberately —
    /// at the projection, which is where the damage is actually done, rather than as a
    /// precondition in a type that no longer has any other reason to know what a vault is.
    ///
    /// Both halts are sticky, and re-checked on every round, so "Resume After Review" on a
    /// vault that is still unreadable stops again instead of pushing.
    private func refuseToSpeakForAnUnreadableVault(
        against base: SyncBase, metadata: SyncBase
    ) throws {
        if secureStore.isUnreadable {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "the secure vault on this device could not be read, so its snippets "
                    + "cannot be synced without appearing to have been deleted")
        }

        // No vault at all is ordinary: a Mac that never made one, or one whose vault the
        // user deliberately forgot — `forgetEverything` clears these entries itself, so
        // reaching here means the file went away underneath us instead.
        guard secureStore.document == nil else { return }
        let baseIDs = base.envelopes.values
            .filter { $0.secure && !$0.deleted }.map(\.id)
        let metadataIDs = metadata.envelopes.values
            .filter { $0.secure && !$0.deleted }.map(\.id)
        let orphaned = Set(baseIDs).union(metadataIDs).count
        guard orphaned == 0 else {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "\(orphaned) secure snippet(s) have been synced from this device but "
                    + "its vault file is missing, so syncing now would delete them everywhere")
        }
    }

    func liveIDs() -> Set<UUID> {
        Set(store.snippets.map(\.id)).union(secureStore.shells.map(\.id))
    }

    /// Partitions remote state before the engine evaluates its deletion guard.
    ///
    /// A missing vault is expected to heal when its synchronizable identity arrives, so
    /// live secure records wait. A different `kid` cannot heal by waiting: the ciphertext
    /// is permanently bound to another AAD scope, so those ids are reported separately
    /// and the engine applies the rest of the batch before entering a sticky halt.
    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
        if secureStore.document == nil,
           envelopes.contains(where: { $0.secure && !$0.deleted }) {
            secureStore.joinSharedVaultIfAvailable()
        }

        let localKID = secureStore.document?.kid
        var applicable: [SyncEnvelope] = []
        var deferred: [UUID] = []
        var incompatible: [UUID] = []

        for envelope in envelopes {
            guard envelope.secure else {
                applicable.append(envelope)
                continue
            }
            if let arrivingKID = envelope.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text,
               let localKID, arrivingKID != localKID {
                incompatible.append(envelope.id)
            } else if !envelope.deleted, localKID == nil {
                deferred.append(envelope.id)
            } else {
                applicable.append(envelope)
            }
        }
        return RemoteClassification(
            applicable: applicable, deferredIDs: deferred,
            incompatibleVaultIDs: incompatible)
    }

    // MARK: - Applying

    /// Writes merged remote state into whichever store owns each record.
    ///
    /// Everything goes through one `LibraryTransaction`, so a remote change that moves a
    /// record between plaintext and secure cannot be observed half-applied — and so a
    /// concurrent CLI write cannot interleave with it.
    ///
    /// ## A record this Mac cannot file waits; it does not take the round down with it
    ///
    /// Two secure records cannot be filed here: one that arrives with no local vault, and
    /// one sealed under a *different* vault's `kid`. Both used to throw — the first
    /// explicitly, the second not at all, because nothing checked. Throwing from inside
    /// the transaction rolls back every plaintext envelope merged alongside it and leaves
    /// the cursor where it was, so one un-fileable secret stopped **all** inbound sync,
    /// permanently, retried every two minutes for ever. Ordinary snippets edited on
    /// another Mac simply never arrived, while the pane talked about vault keys.
    ///
    /// A missing-vault record is deferred and retried without backoff. A rival-vault
    /// record is classified as incompatible: everything else in the batch applies, then
    /// the engine halts instead of holding one cursor and re-fetching it forever.
    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome {
        guard !envelopes.isEmpty else { return ApplyOutcome() }

        // Same hazard as promote: the transaction below reads snippets.json from disk,
        // so an unflushed in-memory edit would be invisible to it and then land on top
        // of the merged result a fraction of a second later.
        store.flushPendingWrites()

        // A secure record is arriving and this Mac has no vault. Before the transaction
        // refuses it, look for the vault the user's other Macs already share — this is
        // the moment we learn one exists, and a Mac with no secure snippets of its own
        // never has a local change that would trigger the check anywhere else.
        //
        // Outside the transaction on purpose: adopting takes the same library lock, and
        // taking it twice would deadlock rather than merely fail.
        if secureStore.document == nil,
           envelopes.contains(where: { $0.secure && !$0.deleted }) {
            secureStore.joinSharedVaultIfAvailable()
        }

        let outcome = try LibraryTransaction.perform(lockTimeout: lockTimeout) { contents in
            var changed: [UUID] = []
            var applied: [SyncEnvelope] = []
            var deferred: [UUID] = []
            var incompatible: [UUID] = []

            for envelope in envelopes {
                let wasPlain = contents.snippets.contains { $0.id == envelope.id }
                let wasSecure = contents.vault?.record(envelope.id) != nil

                // Scope-check tombstones too, before they can remove anything. A rival
                // vault's live record was already deferred below, but its tombstone took
                // the earlier deletion branch and could erase a local record with the
                // same UUID despite being authenticated for a different vault. Legitimate
                // secure tombstones retain the `vaultKID` extension from their live
                // envelope. A legitimate demotion and its later tombstone carry this
                // vault's `kid`; a rival scope may not delete even a plaintext copy that
                // happens to share the UUID.
                let arrivingKID = envelope.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                if envelope.secure, let arrivingKID, let localKID = contents.vault?.kid,
                   arrivingKID != localKID {
                    incompatible.append(envelope.id)
                    continue
                }

                if envelope.deleted {
                    if wasPlain { contents.snippets.removeAll { $0.id == envelope.id } }
                    if wasSecure, var vault = contents.vault {
                        vault.records.removeAll { $0.id == envelope.id }
                        contents.vault = vault
                    }
                    if wasPlain || wasSecure { changed.append(envelope.id) }
                    // Even an already-absent record must leave the projection cache:
                    // absence plus an old live envelope would manufacture a local
                    // resurrection on the next read.
                    applied.append(envelope)
                    continue
                }

                guard envelope.fields != nil else { continue }

                if envelope.secure {
                    // Arriving secure. A vault must already exist here — its `kid` is the
                    // crypto scope, and inventing one locally would produce a document
                    // whose records no other device can open.
                    guard var vault = contents.vault else {
                        deferred.append(envelope.id)
                        continue
                    }

                    // And it has to be the *same* vault. The body is the originating
                    // vault's sealed bytes verbatim, AEAD-bound to that vault's `kid`,
                    // which lives in the AAD and so is invisible from the envelope text —
                    // the scope stamp in `x` is the only way to see it. Without this
                    // check a Mac that lost the first-publisher race filed the record
                    // happily, showed its name and keyword in the list, and failed every
                    // reveal for ever with nothing explaining why. Deferring instead
                    // keeps the record on the backend, where it stays readable by the
                    // Mac that owns it, and leaves this one repairable by the recovery key.
                    let existing = vault.record(envelope.id)
                    guard let record = try SyncLibraryProjection.vaultRecord(
                        from: envelope, preserving: existing)
                    else { continue }

                    if let index = vault.records.firstIndex(where: { $0.id == envelope.id }) {
                        vault.records[index] = record
                    } else {
                        vault.records.append(record)
                    }
                    contents.vault = vault
                    // A record that became secure elsewhere must stop existing in
                    // plaintext here, or the same snippet would be in both files — and
                    // the plaintext copy would still be exportable.
                    if wasPlain { contents.snippets.removeAll { $0.id == envelope.id } }
                } else {
                    guard let snippet = envelope.plainSnippet else { continue }
                    if let index = contents.snippets.firstIndex(where: { $0.id == envelope.id }) {
                        contents.snippets[index] = snippet
                    } else {
                        contents.snippets.insert(snippet, at: 0)
                    }
                    if wasSecure, var vault = contents.vault {
                        vault.records.removeAll { $0.id == envelope.id }
                        contents.vault = vault
                    }
                }
                changed.append(envelope.id)
                applied.append(envelope)
            }
            return ApplyResult(
                changedIDs: changed, appliedEnvelopes: applied, deferredIDs: deferred,
                incompatibleVaultIDs: incompatible)
        }

        var metadata = loadMetadata(fallingBackTo: SyncBase())
        for envelope in outcome.value.appliedEnvelopes {
            if envelope.deleted {
                metadata.envelopes[SyncBase.key(envelope.id)] = nil
            } else {
                metadata.record(envelope)
            }
        }
        persistMetadata(metadata.envelopes.values.reduce(into: [:]) { result, envelope in
            result[envelope.id] = envelope
        })

        // Both stores re-read from disk, because the transaction wrote underneath them.
        // Suppress their independent callbacks and publish one explicitly remote change:
        // UI still refreshes, but the outbound debounce must not replay a round merely
        // because this round applied what it just fetched.
        store.reloadAfterExternalWrite(notifyChange: false)
        secureStore.reload(notifyChange: false)
        store.coordinatedReloadDidFinish(.remoteSync)
        return ApplyOutcome(
            changedIDs: outcome.value.changedIDs,
            deferredIDs: outcome.value.deferredIDs,
            incompatibleVaultIDs: outcome.value.incompatibleVaultIDs)
    }

    // MARK: - Frozen-file metadata

    /// The file intentionally reuses `SyncBase`'s canonical-envelope map encoding. Its
    /// cursor is always nil; semantically this is the local projection, not the agreed
    /// backend ancestor.
    private func loadMetadata(fallingBackTo fallback: SyncBase) -> SyncBase {
        if let metadataCache { return metadataCache }
        if case .loaded(let loaded) = SyncBaseFile.load(from: metadataURL) {
            metadataCache = loaded
        } else {
            metadataCache = fallback
        }
        return metadataCache ?? fallback
    }

    private func persistMetadata(_ envelopes: [UUID: SyncEnvelope]) {
        var next = SyncBase()
        for envelope in envelopes.values { next.record(envelope) }
        guard metadataCache != next else { return }
        metadataCache = next
        do {
            try SyncBaseFile.write(
                next, to: metadataURL, temporaryDirectory: temporaryDirectory)
        } catch {
            // Derived state only. The agreed base is the fallback, so losing this can
            // cause one conservative re-push after restart but cannot lose a snippet.
            Diagnostics.record(.storageFailure(
                area: .syncMetadata,
                operation: .write,
                failure: DiagnosticFailure(error),
                attempt: nil))
        }
    }

    /// Drops only the vault-owned portion of the in-process projection sidecar after a
    /// deliberate local vault removal. `SecureSnippetStore` prunes the file durably, but
    /// this bridge may have cached its old contents; without the matching memory update,
    /// re-enabling sync in the same process would still fail closed on those stale secure
    /// entries. Plaintext and unknown extension metadata remains intact.
    func forgetSecureProjectionMetadata() {
        let current = loadMetadata(fallingBackTo: SyncBase())
        let retained = current.envelopes.values.filter { !$0.secure }
        persistMetadata(retained.reduce(into: [:]) { result, envelope in
            result[envelope.id] = envelope
        })
    }
}
