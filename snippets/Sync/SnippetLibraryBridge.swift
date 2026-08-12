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
        do {
            try store.flushPendingWritesForSync()
        } catch {
            // Journal desired/offered state is allowed to outlive the process. It may not
            // get ahead of the primary ordinary-library file that a restart will project,
            // or an older on-disk value can be restamped as a fresh edit and undo a server-
            // accepted change. Stop before metadata, journal, sealing, or transport.
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "the latest ordinary snippet edits could not be made durable; "
                    + "sync stopped before offering them to iCloud")
        }

        let metadata = loadMetadata(fallingBackTo: agreedBase)
        try refuseToSpeakForAnUnreadableVault(against: agreedBase, metadata: metadata)

        let envelopes = SyncLibraryProjection.currentEnvelopes(
            snippets: store.snippets,
            records: secureStore.document?.records ?? [],
            deviceID: store.deviceID,
            metadata: metadata,
            agreedBase: agreedBase,
            vaultKID: secureStore.document?.kid)
        do {
            for envelope in envelopes.values {
                try SyncMerge.validateContentConflictExtensions(in: envelope)
                if let kid = secureStore.document?.kid,
                   try SyncMerge.secureContentConflictVariants(in: envelope).contains(where: {
                       $0.sourceExtensions[SyncEnvelope.vaultKeyIDExtensionKey]?.text != kid
                   }) {
                    throw SyncLibraryProjection.Failure
                        .incompatibleSecureConflictVault(envelope.id)
                }
            }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "local secure conflict state is malformed or belongs to another vault; "
                    + "sync stopped before offering it")
        }
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
           envelopes.contains(where: {
               ($0.secure && !$0.deleted)
                   || ((try? SyncMerge.secureContentConflictVariants(in: $0))?.isEmpty == false)
           }) {
            secureStore.joinSharedVaultIfAvailable()
        }

        let localKID = secureStore.document?.kid
        var applicable: [SyncEnvelope] = []
        var deferred: [UUID] = []
        var incompatible: [UUID] = []

        for envelope in envelopes {
            let variantKIDs = (try? SyncMerge.secureContentConflictVariants(in: envelope))?
                .compactMap {
                    $0.sourceExtensions[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                } ?? []
            if !variantKIDs.isEmpty {
                guard let localKID else {
                    deferred.append(envelope.id)
                    continue
                }
                if variantKIDs.contains(where: { $0 != localKID }) {
                    incompatible.append(envelope.id)
                    continue
                }
            }
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

    /// Validates and partitions secure conflict snapshots without mutating primary
    /// storage. Materialisation belongs to `applyRemote`'s one transaction so the losing
    /// copy and selected survivor cannot interleave with another writer.
    func prepareRemote(_ envelopes: [SyncEnvelope]) throws -> RemoteClassification {
        var variantsByID: [UUID: [SyncMerge.SecureContentConflictVariant]] = [:]
        var unknownIDs = Set<UUID>()
        var incomingByID: [UUID: SyncEnvelope] = [:]
        do {
            // Validate the complete authoritative batch, not just records which this
            // vault can currently file. A deferred/incompatible record still occupies
            // its id and therefore still participates in deterministic-copy collision
            // checks. This also avoids `Dictionary(uniqueKeysWithValues:)` trapping on
            // malformed direct callers which repeat an id.
            for envelope in envelopes {
                guard incomingByID.updateValue(envelope, forKey: envelope.id) == nil else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                try SyncMerge.validateContentConflictExtensions(in: envelope)
                if SyncMerge.hasUnknownContentConflictVersion(envelope) {
                    unknownIDs.insert(envelope.id)
                    continue
                }
                let variants = try SyncMerge.secureContentConflictVariants(in: envelope)
                if !variants.isEmpty { variantsByID[envelope.id] = variants }
            }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "an incoming secure conflict snapshot was malformed; sync stopped "
                    + "before changing the library")
        }

        // Collision authority is structural and comes before key availability. Waiting
        // for or adopting a vault may defer a valid dependency, but it must never turn
        // an unrelated occupant of the deterministic copy id into an applicable
        // standalone record — or mutate local vault state before rejecting the batch.
        var dependentCopyIDsBySource: [UUID: Set<UUID>] = [:]
        for (sourceID, variants) in variantsByID {
            for variant in variants {
                guard let occupant = incomingByID[variant.copyID] else { continue }
                guard !occupant.deleted,
                      occupant.secure,
                      SyncMerge.matchesConflictCopyProvenance(
                    occupant,
                    sourceID: variant.sourceID,
                    fingerprint: variant.fingerprint),
                      occupant.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                        == variant.sourceExtensions[
                            SyncEnvelope.vaultKeyIDExtensionKey]?.text
                else {
                    throw SyncEngineFailure(
                        reason: .localLibraryQuarantined,
                        detail: "a secure conflict copy collided with an existing snippet; "
                            + "sync stopped without overwriting either record")
                }
                // Provenance identifies which logical copy this is; it does not
                // authenticate the body. AEAD and keyed-hash validation follows inside
                // the transaction once the key is known.
                dependentCopyIDsBySource[sourceID, default: []].insert(variant.copyID)
            }
        }

        let initial = classifyRemote(envelopes)
        var deferred = Set(initial.deferredIDs).union(unknownIDs)
        var applicable = initial.applicable.filter { !unknownIDs.contains($0.id) }
        guard !variantsByID.isEmpty else {
            return RemoteClassification(
                applicable: applicable,
                deferredIDs: deferred.sorted { $0.uuidString < $1.uuidString },
                incompatibleVaultIDs: initial.incompatibleVaultIDs)
        }

        // Only sources that survived ordinary vault-scope classification need a local
        // key. Sources already reported as incompatible stay incompatible; their copy
        // occupants must not be promoted into an independent applicable record.
        let applicableIDs = Set(applicable.map(\.id))
        let activeVariantSourceIDs = Set(variantsByID.keys).intersection(applicableIDs)
        let activeDependencyIDs = activeVariantSourceIDs.reduce(into: Set<UUID>()) {
            result, sourceID in
            result.formUnion(dependentCopyIDsBySource[sourceID] ?? [])
        }
        guard activeVariantSourceIDs.isEmpty || secureStore.document != nil else {
            deferred.formUnion(activeVariantSourceIDs)
            deferred.formUnion(activeDependencyIDs)
            applicable.removeAll {
                activeVariantSourceIDs.contains($0.id) || activeDependencyIDs.contains($0.id)
            }
            return RemoteClassification(
                applicable: applicable,
                deferredIDs: deferred.sorted { $0.uuidString < $1.uuidString },
                incompatibleVaultIDs: initial.incompatibleVaultIDs)
        }
        if !activeVariantSourceIDs.isEmpty {
            do {
                _ = try secureStore.unlockedKeyringForSync()
            } catch VaultSession.Failure.locked {
                deferred.formUnion(activeVariantSourceIDs)
                deferred.formUnion(activeDependencyIDs)
                applicable.removeAll {
                    activeVariantSourceIDs.contains($0.id)
                        || activeDependencyIDs.contains($0.id)
                }
                return RemoteClassification(
                    applicable: applicable,
                    deferredIDs: deferred.sorted { $0.uuidString < $1.uuidString },
                    incompatibleVaultIDs: initial.incompatibleVaultIDs)
            } catch {
                throw SyncEngineFailure(
                    reason: .vaultUnreadable,
                    detail: "the unlocked secure vault could not produce its conflict key; "
                        + "sync stopped before changing the library")
            }
        }
        return RemoteClassification(
            applicable: applicable,
            deferredIDs: deferred.sorted { $0.uuidString < $1.uuidString },
            incompatibleVaultIDs: initial.incompatibleVaultIDs)
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
    /// permanently, retried on every scheduler wake for ever. Ordinary snippets edited on
    /// another Mac simply never arrived, while the pane talked about vault keys.
    ///
    /// A missing-vault record is deferred and retried without backoff. A rival-vault
    /// record is classified as incompatible: everything else in the batch applies, then
    /// the engine halts instead of holding one cursor and re-fetching it forever.
    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome {
        // Defense in depth: the engine normally supplies the result of `prepareRemote`,
        // but this is the mutation boundary and must remain safe for direct callers and
        // for a future engine refactor. Re-run structural validation and preserve its
        // dependency partition in this method's result.
        let guarded = try prepareRemote(envelopes)
        let envelopes = guarded.applicable
        guard !envelopes.isEmpty else {
            return ApplyOutcome(
                deferredIDs: guarded.deferredIDs,
                incompatibleVaultIDs: guarded.incompatibleVaultIDs)
        }

        // Same hazard as promote: the transaction below reads snippets.json from disk,
        // so an unflushed in-memory edit would be invisible to it and then land on top
        // of the merged result a fraction of a second later.
        do {
            try store.flushPendingWritesForSync()
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "the latest ordinary snippet edits could not be made durable; "
                    + "sync stopped before applying iCloud changes")
        }

        let variantsByEnvelope: [UUID: [SyncMerge.SecureContentConflictVariant]]
        do {
            variantsByEnvelope = try envelopes.reduce(into: [:]) { result, envelope in
                let variants = try SyncMerge.secureContentConflictVariants(in: envelope)
                if !variants.isEmpty { result[envelope.id] = variants }
            }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "an incoming secure conflict snapshot was malformed; sync stopped "
                    + "before changing the library")
        }
        let materializationKeyring: SnippetCrypto.Keyring?
        if variantsByEnvelope.isEmpty {
            materializationKeyring = nil
        } else {
            do {
                materializationKeyring = try secureStore.unlockedKeyringForSync()
            } catch VaultSession.Failure.locked {
                // `prepareRemote` may have succeeded moments earlier and the session
                // may expire before this second, transaction-adjacent key read. Nothing
                // in this call has been written yet, so report *every* applicable id as
                // deferred. Reporting only the variant source would let the engine
                // confirm its dependent copy (and unrelated plaintext peers) in base
                // despite never applying them to primary storage.
                return ApplyOutcome(
                    deferredIDs: Set(guarded.deferredIDs)
                        .union(envelopes.map(\.id))
                        .sorted { $0.uuidString < $1.uuidString },
                    incompatibleVaultIDs: guarded.incompatibleVaultIDs)
            } catch {
                throw SyncEngineFailure(
                    reason: .vaultUnreadable,
                    detail: "the secure conflict key became unavailable before apply; "
                        + "sync stopped without changing the library")
            }
        }
        let expectedVault = secureStore.document.map { ($0.kid, $0.vaultSalt) }
        var incomingByID: [UUID: SyncEnvelope] = [:]
        for envelope in envelopes {
            guard incomingByID.updateValue(envelope, forKey: envelope.id) == nil else {
                throw SyncEngineFailure(
                    reason: .localLibraryQuarantined,
                    detail: "an incoming sync batch repeated a snippet identifier; "
                        + "sync stopped before changing the library")
            }
        }

        let outcome: LibraryTransaction.Outcome<ApplyResult>
        do {
            outcome = try LibraryTransaction.perform(lockTimeout: lockTimeout) { contents in
            var changed: [UUID] = []
            var applied: [SyncEnvelope] = []
            var deferred: [UUID] = []
            var incompatible: [UUID] = []

            if let materializationKeyring {
                guard var vault = contents.vault,
                      let expectedVault,
                      vault.kid == expectedVault.0,
                      vault.vaultSalt == expectedVault.1 else {
                    throw SyncSecureConflictMaterializer.Failure.incompatibleVault
                }
                for envelope in envelopes where variantsByEnvelope[envelope.id] != nil {
                    for variant in variantsByEnvelope[envelope.id] ?? [] {
                        guard let occupant = incomingByID[variant.copyID] else { continue }
                        guard SyncMerge.matchesConflictCopyProvenance(
                            occupant,
                            sourceID: variant.sourceID,
                            fingerprint: variant.fingerprint)
                        else {
                            throw SyncSecureConflictMaterializer.Failure.identifierCollision
                        }
                        try SyncSecureConflictMaterializer.validateIncomingSecureCopy(
                            occupant,
                            keyring: materializationKeyring,
                            vaultKID: vault.kid)
                    }
                    let result = try SyncSecureConflictMaterializer.materialize(
                        envelope: envelope,
                        keyring: materializationKeyring,
                        vaultKID: vault.kid,
                        existingSnippets: contents.snippets,
                        existingRecords: vault.records)
                    // Resealing under the deterministic copy id preserves plaintext
                    // size, but the conflict name/tags/provenance add wire metadata.
                    // Refuse before either primary file is written if that completed
                    // copy cannot fit the shipping record budget.
                    for copyID in result.materializedIDs {
                        guard let record = result.records.first(where: { $0.id == copyID }),
                              let projected = SyncLibraryProjection.currentEnvelopes(
                                snippets: [],
                                records: [record],
                                deviceID: store.deviceID,
                                metadata: SyncBase(),
                                agreedBase: SyncBase(),
                                vaultKID: vault.kid)[copyID]
                        else {
                            throw SyncSecureConflictMaterializer.Failure.malformedVariant
                        }
                        try SyncMerge.validateContentConflictExtensions(in: projected)
                    }
                    vault.records = result.records
                }
                contents.vault = vault
            }

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
        } catch let failure as LibraryTransaction.Failure {
            throw failure
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a secure conflict copy failed integrity or collision checks; "
                    + "sync stopped without applying the survivor")
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
            deferredIDs: Set(guarded.deferredIDs)
                .union(outcome.value.deferredIDs)
                .sorted { $0.uuidString < $1.uuidString },
            incompatibleVaultIDs: Set(
                Set(guarded.incompatibleVaultIDs)
                    .union(outcome.value.incompatibleVaultIDs))
                .sorted { $0.uuidString < $1.uuidString })
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
