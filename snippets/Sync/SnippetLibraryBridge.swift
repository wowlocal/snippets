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

    let supportsSecureConflictMaterialization = true

    private let store: SnippetStore
    private let secureStore: SecureSnippetStore
    private let lockTimeout: TimeInterval
    private let metadataURL: URL
    private let temporaryDirectory: URL
    private var metadataCache: SyncBase?

    private struct ApplyResult {
        var changedIDs: [UUID]
        var appliedEnvelopes: [SyncEnvelope]
        var conflictCopyEvidence: [SyncEnvelope] = []
        var deferredIDs: [UUID] = []
        var incompatibleVaultIDs: [UUID] = []
        var retryIDs: [UUID] = []
    }

    private struct MaterializePrerequisitesResult {
        var materializedIDs: [UUID]
        var primaryCASMiss: Bool
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

    func activateProtocolLocations(_ locations: SyncProtocolLocations) {
        secureStore.activateProtocolLocations(locations)
    }

    // MARK: - Reading

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        try currentSnapshot(agreedBase: agreedBase).envelopes
    }

    func currentSnapshot(agreedBase: SyncBase) throws -> SyncLibrarySnapshot {
        try projectedSnapshot(agreedBase: agreedBase, allowingReviewedQuarantine: false)
    }

    /// The recovery action needs one narrow read path while ordinary mutation and sync
    /// remain quarantined. `adoptRecoveredLibraryIfPresent` has already decoded the
    /// exact primary bytes; this flag authorizes projection only, never writes or apply.
    private func projectedSnapshot(
        agreedBase: SyncBase,
        allowingReviewedQuarantine: Bool
    ) throws -> SyncLibrarySnapshot {
        guard allowingReviewedQuarantine || !store.isLibraryQuarantined else {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "the primary snippet library is quarantined; restore a valid "
                    + "library before syncing so missing records are not treated as deletions",
                recoveryContext: .localLibraryQuarantine)
        }
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

        let metadata = try loadMetadata(fallingBackTo: agreedBase)
        // Decode both files under their shared read lock. Besides closing the external
        // writer tear, this canonicalizes Date precision exactly as a later transaction
        // sees it; in-memory VaultFile.update results can retain sub-millisecond values
        // that the durable JSON representation intentionally rounds.
        let primary: LibraryTransaction.Outcome<(snippets: [Snippet], vault: VaultDocument?)>
        do {
            primary = try LibraryTransaction.perform(lockTimeout: lockTimeout) { contents in
                (contents.snippets, contents.vault)
            }
        } catch {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "the primary snippet library could not be read consistently; "
                    + "sync stopped before offering or applying changes")
        }
        let snippets = primary.value.snippets
        let vault = primary.value.vault
        try refuseToSpeakForAnUnreadableVault(
            actualVault: vault,
            against: agreedBase,
            metadata: metadata)
        let records = vault?.records ?? []
        let envelopes = SyncLibraryProjection.currentEnvelopes(
            snippets: snippets,
            records: records,
            deviceID: store.deviceID,
            metadata: metadata,
            agreedBase: agreedBase,
            vaultKID: vault?.kid)
        do {
            for envelope in envelopes.values {
                try SyncMerge.validateContentConflictExtensions(in: envelope)
                if let kid = vault?.kid,
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
        var primaryStates: [UUID: SyncPrimaryState] = [:]
        for snippet in snippets {
            primaryStates[snippet.id] = .plain(snippet)
        }
        if let vault {
            for record in records {
                if case .plain(let snippet)? = primaryStates[record.id] {
                    primaryStates[record.id] = .duplicate(
                        snippet: snippet,
                        record: record,
                        vaultKID: vault.kid,
                        vaultSalt: vault.vaultSalt)
                } else {
                    primaryStates[record.id] = .secure(
                        record: record,
                        vaultKID: vault.kid,
                        vaultSalt: vault.vaultSalt)
                }
            }
        }
        return SyncLibrarySnapshot(
            envelopes: envelopes,
            primaryStates: primaryStates,
            installedConflictPrerequisiteHashes: try validatedConflictInstallReceipts(
                in: vault))
    }

    func reviewRecoveredLibrary(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        if store.isLibraryQuarantined {
            guard store.adoptRecoveredLibraryIfPresent() else {
                throw SyncEngineFailure(
                    reason: .localLibraryQuarantined,
                    detail: "the restored snippet library still cannot be read")
            }
        }
        return try projectedSnapshot(
            agreedBase: agreedBase,
            allowingReviewedQuarantine: true).envelopes
    }

    func finalizeRecoveredLibraryReview() throws {
        guard store.finalizeRecoveredLibraryReview() else {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "the library recovery marker is still active")
        }
    }

    private func validatedConflictInstallReceipts(
        in vault: VaultDocument?
    ) throws -> [UUID: String] {
        guard let vault else { return [:] }
        guard let receipts = vault.localConflictInstallReceipts else {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "local conflict-install receipts are malformed; sync stopped "
                    + "instead of guessing whether an absent copy was deleted")
        }
        return receipts
    }

    func retainConflictPrerequisiteInstallReceipts(for ids: Set<UUID>) throws {
        let outcome: LibraryTransaction.Outcome<Bool>
        do {
            outcome = try LibraryTransaction.perform(lockTimeout: lockTimeout) { contents in
                guard var vault = contents.vault else { return false }
                let before = vault.x
                try vault.retainLocalConflictInstallReceipts(for: ids)
                guard vault.x != before else { return false }
                contents.vault = vault
                return true
            }
        } catch let failure as LibraryTransaction.Failure {
            throw failure
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "local conflict-install receipts could not be pruned safely")
        }
        if outcome.value {
            secureStore.reload(notifyChange: false)
        }
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
    /// Both halts are sticky and re-checked on every round, so "Check Again" on a vault
    /// that is still unreadable stops again instead of pushing.
    private func refuseToSpeakForAnUnreadableVault(
        actualVault: VaultDocument? = nil,
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
        if actualVault != nil { return }
        guard secureStore.document == nil else {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "the in-memory vault exists but its primary file is missing; "
                    + "sync stopped instead of projecting secure deletions")
        }
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
        let livePrimaryIDs = Set(store.snippets.map(\.id))
            .union(secureStore.shells.map(\.id))
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
            let arrivingKID = envelope.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
            if envelope.deleted, livePrimaryIDs.contains(envelope.id) {
                // A secure deletion may touch an occupied UUID only when both sides
                // name the same local vault. Missing local identity cannot authorize a
                // remote scope to erase a plaintext occupant; an absent id remains an
                // idempotent no-op below.
                if arrivingKID == nil {
                    incompatible.append(envelope.id)
                } else if localKID == nil {
                    deferred.append(envelope.id)
                } else if arrivingKID != localKID {
                    incompatible.append(envelope.id)
                } else {
                    applicable.append(envelope)
                }
            } else if let arrivingKID,
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
        var liveSecureCopyIDs = Set<UUID>()
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
                if envelope.x[SyncMerge.plainConflictCopyExtensionKey] != nil {
                    guard SyncMerge.hasValidConflictCopyIdentity(envelope) else {
                        throw SyncMerge.EnvelopeFailure.malformedContentConflict
                    }
                    if envelope.secure, !envelope.deleted {
                        liveSecureCopyIDs.insert(envelope.id)
                    }
                }
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
        var incomingDependencyIDsBySource: [UUID: Set<UUID>] = [:]
        for (sourceID, variants) in variantsByID {
            for variant in variants {
                guard let occupant = incomingByID[variant.copyID] else { continue }
                incomingDependencyIDsBySource[sourceID, default: []]
                    .insert(variant.copyID)
                // A tombstone intentionally has neither body nor provenance. It is a
                // later operation on the reserved copy id, not an identity collision;
                // the dependency still materializes/offers immutable C0 before release.
                guard !occupant.deleted else { continue }
                guard SyncMerge.matchesConflictCopyProvenance(
                    occupant,
                    sourceID: variant.sourceID,
                    fingerprint: variant.fingerprint),
                      (!occupant.secure
                        || occupant.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                            == variant.sourceExtensions[
                                SyncEnvelope.vaultKeyIDExtensionKey]?.text)
                else {
                    throw SyncEngineFailure(
                        reason: .localLibraryQuarantined,
                        detail: "a secure conflict copy collided with an existing snippet; "
                            + "sync stopped without overwriting either record")
                }
                // Provenance identifies which logical copy this is; it does not
                // authenticate the body. AEAD and keyed-hash validation follows inside
                // the transaction once the key is known.
            }
        }

        let initial = classifyRemote(envelopes)
        var deferred = Set(initial.deferredIDs).union(unknownIDs)
        var applicable = initial.applicable.filter { !unknownIDs.contains($0.id) }
        let unstampedLiveSecureIDs = Set(applicable.compactMap { envelope in
            envelope.secure && !envelope.deleted
                && envelope.x[SyncEnvelope.vaultKeyIDExtensionKey] == nil
                ? envelope.id : nil
        })
        guard !variantsByID.isEmpty || !liveSecureCopyIDs.isEmpty
                || !unstampedLiveSecureIDs.isEmpty else {
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
        let allDependencyIDs = incomingDependencyIDsBySource.values.reduce(
            into: Set<UUID>()) { $0.formUnion($1) }
        let activeDependencyIDs = activeVariantSourceIDs.reduce(into: Set<UUID>()) {
            result, sourceID in
            result.formUnion(incomingDependencyIDsBySource[sourceID] ?? [])
        }
        // A dependent C1/tombstone travels atomically with its carrier source. If that
        // source is waiting for a key or belongs to another vault, a plain demotion must
        // not escape the partition merely because it no longer has a vault stamp of its
        // own. Keep it on the same held cursor as the source.
        let inactiveDependencyIDs = allDependencyIDs.subtracting(activeDependencyIDs)
        if !inactiveDependencyIDs.isEmpty {
            deferred.formUnion(inactiveDependencyIDs)
            applicable.removeAll { inactiveDependencyIDs.contains($0.id) }
        }
        let applicableSecureCopyIDs = liveSecureCopyIDs.intersection(applicableIDs)
        let exactSecureEchoIDs = Set(applicable.filter { envelope in
            guard applicableSecureCopyIDs.contains(envelope.id),
                  let vault = secureStore.document,
                  let record = vault.record(envelope.id)
            else { return false }
            return SyncLibraryProjection.matchesExactSecurePrimary(
                envelope,
                record: record,
                vaultKID: vault.kid)
        }.map(\.id))
        let exactLegacyEchoIDs = Set(applicable.compactMap { envelope -> UUID? in
            guard unstampedLiveSecureIDs.contains(envelope.id),
                  let vault = secureStore.document,
                  let record = vault.record(envelope.id),
                  SyncLibraryProjection.matchesExactLegacyUnstampedSecurePrimary(
                    envelope, record: record, vaultKID: vault.kid)
            else { return nil }
            return envelope.id
        })
        let keyRequiredIDs = activeVariantSourceIDs
            .union(activeDependencyIDs)
            .union(applicableSecureCopyIDs.subtracting(exactSecureEchoIDs))
            .union(unstampedLiveSecureIDs.subtracting(exactLegacyEchoIDs))
        guard keyRequiredIDs.isEmpty || secureStore.document != nil else {
            deferred.formUnion(keyRequiredIDs)
            applicable.removeAll {
                keyRequiredIDs.contains($0.id)
            }
            return RemoteClassification(
                applicable: applicable,
                deferredIDs: deferred.sorted { $0.uuidString < $1.uuidString },
                incompatibleVaultIDs: initial.incompatibleVaultIDs)
        }
        if !keyRequiredIDs.isEmpty {
            do {
                _ = try secureStore.unlockedKeyringForSync()
            } catch VaultSession.Failure.locked {
                deferred.formUnion(keyRequiredIDs)
                applicable.removeAll {
                    keyRequiredIDs.contains($0.id)
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
        try applyRemote(
            envelopes,
            expectedPrimary: [:],
            heldConflictCopyIntents: [:],
            authorizesDependencyEvolution: false)
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        try applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: [:],
            authorizesDependencyEvolution: false)
    }

    private func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        authorizesDependencyEvolution: Bool
    ) throws -> ApplyOutcome {
        let evidence = try prepareConflictCopyEvidence(from: envelopes)
        return try applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: heldConflictCopyIntents,
            preparedConflictCopyEvidence: evidence,
            authorizesDependencyEvolution: authorizesDependencyEvolution)
    }

    func prepareConflictCopyEvidence(
        from envelopes: [SyncEnvelope]
    ) throws -> [SyncEnvelope] {
        let sources: [SyncEnvelope]
        do {
            sources = try envelopes.filter {
                !(try SyncMerge.secureContentConflictVariants(in: $0)).isEmpty
            }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "an incoming secure conflict snapshot was malformed")
        }
        guard !sources.isEmpty else { return [] }
        let keyring: SnippetCrypto.Keyring
        let vault: VaultDocument
        do {
            guard let currentVault = secureStore.document else {
                throw VaultSession.Failure.locked
            }
            vault = currentVault
            keyring = try secureStore.unlockedKeyringForSync()
        } catch VaultSession.Failure.locked {
            return []
        } catch {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "the secure conflict key is unavailable during evidence preparation")
        }
        do {
            let records = try SyncSecureConflictMaterializer.prepareEvidenceRecords(
                envelopes: sources, keyring: keyring, vaultKID: vault.kid)
            let variants = try sources.flatMap {
                try SyncMerge.secureContentConflictVariants(in: $0)
            }
            var metadata = SyncBase()
            for variant in variants {
                guard let record = records.first(where: { $0.id == variant.copyID }) else {
                    throw SyncSecureConflictMaterializer.Failure.malformedVariant
                }
                let fields = SyncEnvelope.Fields(
                    name: record.name,
                    keyword: record.keyword,
                    content: Data(record.sealed.utf8),
                    tags: record.tags,
                    isEnabled: record.isEnabled,
                    isPinned: record.isPinned,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt)
                metadata.record(SyncEnvelope(
                    id: record.id,
                    hlc: variant.sourceHLC,
                    origin: variant.sourceOrigin,
                    secure: true,
                    deleted: false,
                    fields: fields,
                    x: [
                        SyncEnvelope.vaultContentHashExtensionKey: .string(record.contentHash),
                        SyncEnvelope.vaultKeyIDExtensionKey: .string(vault.kid),
                        SyncMerge.plainConflictCopyExtensionKey: .object([
                            "version": .int(1),
                            "sourceID": .string(variant.sourceID.uuidString.lowercased()),
                            "fingerprint": .string(variant.fingerprint),
                        ]),
                    ]))
            }
            let projected = SyncLibraryProjection.currentEnvelopes(
                snippets: [], records: records, deviceID: store.deviceID,
                metadata: metadata, agreedBase: SyncBase(), vaultKID: vault.kid)
            guard projected.count == records.count else {
                throw SyncSecureConflictMaterializer.Failure.malformedVariant
            }
            return projected.values.sorted { $0.id.uuidString < $1.id.uuidString }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a secure conflict prerequisite failed authentication")
        }
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope]
    ) throws -> ApplyOutcome {
        try applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: heldConflictCopyIntents,
            preparedConflictCopyEvidence: preparedConflictCopyEvidence,
            authorizesDependencyEvolution: true)
    }

    private func applyRemote(
        _ originalEnvelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope],
        authorizesDependencyEvolution: Bool
    ) throws -> ApplyOutcome {
        // Defense in depth: the engine normally supplies the result of `prepareRemote`,
        // but this is the mutation boundary and must remain safe for direct callers and
        // for a future engine refactor. Re-run structural validation and preserve its
        // dependency partition in this method's result.
        let originalCarrierSourceIDs: Set<UUID>
        do {
            originalCarrierSourceIDs = Set(try originalEnvelopes.compactMap { envelope in
                try SyncMerge.secureContentConflictVariants(in: envelope).isEmpty
                    ? nil : envelope.id
            })
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "an incoming secure conflict snapshot was malformed; sync stopped "
                    + "before changing the library")
        }
        let guarded = try prepareRemote(originalEnvelopes)
        let guardedDeferredIDs = Set(guarded.deferredIDs)
        if !originalCarrierSourceIDs.isDisjoint(with: guardedDeferredIDs) {
            // The vault can expire after C0 evidence is prepared but before this
            // transaction-adjacent defensive preflight. No member of that preservation
            // unit (including unrelated peers in the same not-yet-started apply) may be
            // applied or confirmed independently. Keep exact evidence validation strict
            // for every other shape; this path is only a temporal key deferral.
            let incompatible = Set(guarded.incompatibleVaultIDs)
            return ApplyOutcome(
                deferredIDs: Set(originalEnvelopes.map(\.id))
                    .subtracting(incompatible)
                    .sorted { $0.uuidString < $1.uuidString },
                incompatibleVaultIDs: guarded.incompatibleVaultIDs)
        }
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
        let implicitVariants: [UUID: SyncMerge.SecureContentConflictVariant]
        let liveSecureConflictCopies: [SyncEnvelope]
        let unstampedLiveSecure: [SyncEnvelope]
        do {
            variantsByEnvelope = try envelopes.reduce(into: [:]) { result, envelope in
                let variants = try SyncMerge.secureContentConflictVariants(in: envelope)
                if !variants.isEmpty { result[envelope.id] = variants }
            }
            var uniqueVariants: [UUID: SyncMerge.SecureContentConflictVariant] = [:]
            for variant in variantsByEnvelope.values.flatMap({ $0 }) {
                if uniqueVariants[variant.copyID] != nil {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                uniqueVariants[variant.copyID] = variant
            }
            implicitVariants = uniqueVariants
            guard heldConflictCopyIntents.allSatisfy({ id, intent in
                guard id == intent.id, let variant = implicitVariants[id] else {
                    return false
                }
                if intent.secure,
                   intent.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                    != variant.sourceExtensions[
                        SyncEnvelope.vaultKeyIDExtensionKey]?.text {
                    return false
                }
                return intent.deleted || SyncMerge.matchesConflictCopyProvenance(
                    intent,
                    sourceID: variant.sourceID,
                    fingerprint: variant.fingerprint)
            }) else {
                throw SyncMerge.EnvelopeFailure.malformedContentConflict
            }
            for (sourceID, variants) in variantsByEnvelope {
                for variant in variants {
                    guard let occupant = envelopes.first(where: {
                        $0.id == variant.copyID
                    }), occupant.deleted || !occupant.secure else { continue }
                    // Plain C1 and T are legitimate only after the engine has fsynced
                    // this carrier's exact C0 evidence and supplied the complete CAS
                    // read set. Provenance alone is public metadata and cannot grant a
                    // direct bridge caller authority over a deterministic copy id.
                    guard authorizesDependencyEvolution,
                          expectedPrimary[sourceID] != nil,
                          expectedPrimary[variant.copyID] != nil,
                          preparedConflictCopyEvidence.contains(where: { evidence in
                              evidence.id == variant.copyID
                                && SyncMerge.matchesConflictCopyProvenance(
                                    evidence,
                                    sourceID: variant.sourceID,
                                    fingerprint: variant.fingerprint)
                          })
                    else { throw SyncMerge.EnvelopeFailure.malformedContentConflict }
                }
            }
            liveSecureConflictCopies = try envelopes.filter { envelope in
                guard envelope.x[SyncMerge.plainConflictCopyExtensionKey] != nil else {
                    return false
                }
                guard SyncMerge.hasValidConflictCopyIdentity(envelope) else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                return envelope.secure && !envelope.deleted
            }
            unstampedLiveSecure = envelopes.filter {
                $0.secure && !$0.deleted
                    && $0.x[SyncEnvelope.vaultKeyIDExtensionKey] == nil
            }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "an incoming secure conflict snapshot was malformed; sync stopped "
                    + "before changing the library")
        }
        let materializationKeyring: SnippetCrypto.Keyring?
        let exactSecureEchoIDs: Set<UUID> = Set(liveSecureConflictCopies.compactMap {
            envelope -> UUID? in
            guard let vault = secureStore.document,
                  let record = vault.record(envelope.id),
                  SyncLibraryProjection.matchesExactSecurePrimary(
                    envelope,
                    record: record,
                    vaultKID: vault.kid)
            else { return nil }
            return envelope.id
        })
        let secureCopiesRequiringValidation = liveSecureConflictCopies.filter {
            !exactSecureEchoIDs.contains($0.id)
        }
        let exactLegacyEchoIDs = Set(unstampedLiveSecure.compactMap { envelope -> UUID? in
            guard let vault = secureStore.document,
                  let record = vault.record(envelope.id),
                  SyncLibraryProjection.matchesExactLegacyUnstampedSecurePrimary(
                    envelope, record: record, vaultKID: vault.kid)
            else { return nil }
            return envelope.id
        })
        let unstampedRequiringValidation = unstampedLiveSecure.filter {
            !exactLegacyEchoIDs.contains($0.id)
        }
        if variantsByEnvelope.isEmpty && secureCopiesRequiringValidation.isEmpty
                && unstampedRequiringValidation.isEmpty {
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
        var preparedEvidenceByID: [UUID: SyncEnvelope] = [:]
        do {
            for evidence in preparedConflictCopyEvidence {
                guard SyncMerge.hasValidConflictCopyIdentity(evidence),
                      evidence.secure, !evidence.deleted,
                      preparedEvidenceByID.updateValue(evidence, forKey: evidence.id) == nil,
                      let variant = implicitVariants[evidence.id],
                      SyncMerge.matchesConflictCopyProvenance(
                        evidence,
                        sourceID: variant.sourceID,
                        fingerprint: variant.fingerprint),
                      evidence.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                        == variant.sourceExtensions[
                            SyncEnvelope.vaultKeyIDExtensionKey]?.text
                else { throw SyncMerge.EnvelopeFailure.malformedContentConflict }
            }
            guard Set(preparedEvidenceByID.keys) == Set(implicitVariants.keys) else {
                throw SyncMerge.EnvelopeFailure.malformedContentConflict
            }
            if let materializationKeyring, let vaultKID = expectedVault?.0 {
                for (id, evidence) in preparedEvidenceByID {
                    guard let variant = implicitVariants[id] else {
                        throw SyncMerge.EnvelopeFailure.malformedContentConflict
                    }
                    try SyncSecureConflictMaterializer.validatePreparedEvidence(
                        evidence,
                        for: variant,
                        keyring: materializationKeyring,
                        vaultKID: vaultKID)
                }
            }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "prepared conflict-copy evidence was malformed or unauthenticated")
        }
        if let materializationKeyring,
           let vaultKID = expectedVault?.0 {
            do {
                for intent in heldConflictCopyIntents.values where
                    intent.secure && !intent.deleted {
                    try SyncSecureConflictMaterializer.validateIncomingSecureCopy(
                        intent,
                        keyring: materializationKeyring,
                        vaultKID: vaultKID)
                }
            } catch {
                throw SyncEngineFailure(
                    reason: .localLibraryQuarantined,
                    detail: "a dependency-held secure copy failed authentication; sync "
                        + "stopped before changing primary storage")
            }
        }
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
            var conflictCopyEvidence: [SyncEnvelope] = []
            var deferred: [UUID] = []
            var incompatible: [UUID] = []

            // Compare every affected id under the same library lock which protects the
            // writes below. Abort the whole batch on one mismatch: a generated copy and
            // its source are one preservation unit and must not be partially released.
            if !expectedPrimary.isEmpty,
               expectedPrimary.contains(where: { id, expected in
                   Self.primaryState(for: id, in: contents) != expected
               }) {
                return ApplyResult(
                    changedIDs: [],
                    appliedEnvelopes: [],
                    deferredIDs: [],
                    incompatibleVaultIDs: [],
                    retryIDs: envelopes.map(\.id))
            }

            if materializationKeyring == nil && !exactSecureEchoIDs.isEmpty {
                guard let vault = contents.vault,
                      let expectedVault,
                      vault.kid == expectedVault.0,
                      vault.vaultSalt == expectedVault.1,
                      liveSecureConflictCopies.allSatisfy({ envelope in
                          guard let record = vault.record(envelope.id) else { return false }
                          return SyncLibraryProjection.matchesExactSecurePrimary(
                              envelope,
                              record: record,
                              vaultKID: vault.kid)
                      })
                else {
                    return ApplyResult(
                        changedIDs: [],
                        appliedEnvelopes: [],
                        deferredIDs: envelopes.map(\.id),
                        incompatibleVaultIDs: [])
                }
            }

            if materializationKeyring == nil && !exactLegacyEchoIDs.isEmpty {
                guard let vault = contents.vault,
                      let expectedVault,
                      vault.kid == expectedVault.0,
                      vault.vaultSalt == expectedVault.1,
                      unstampedLiveSecure.allSatisfy({ envelope in
                          guard let record = vault.record(envelope.id) else { return false }
                          return SyncLibraryProjection
                            .matchesExactLegacyUnstampedSecurePrimary(
                                envelope, record: record, vaultKID: vault.kid)
                      })
                else {
                    return ApplyResult(
                        changedIDs: [], appliedEnvelopes: [],
                        deferredIDs: envelopes.map(\.id),
                        incompatibleVaultIDs: [])
                }
            }

            if let materializationKeyring {
                guard var vault = contents.vault,
                      let expectedVault,
                      vault.kid == expectedVault.0,
                      vault.vaultSalt == expectedVault.1 else {
                    throw SyncSecureConflictMaterializer.Failure.incompatibleVault
                }
                // A conflict copy can arrive in a later CloudKit page or round than its
                // carrier source. Its provenance proves identity, not ciphertext
                // integrity, so authenticate every standalone copy before it can replace
                // a known-good deterministic vault record.
                for copy in secureCopiesRequiringValidation {
                    try SyncSecureConflictMaterializer.validateIncomingSecureCopy(
                        copy,
                        keyring: materializationKeyring,
                        vaultKID: vault.kid)
                }
                for envelope in unstampedRequiringValidation {
                    try SyncSecureConflictMaterializer.validateIncomingSecureCopy(
                        envelope,
                        keyring: materializationKeyring,
                        vaultKID: vault.kid,
                        requireVaultStamp: false)
                }
                for envelope in envelopes where variantsByEnvelope[envelope.id] != nil {
                    for variant in variantsByEnvelope[envelope.id] ?? [] {
                        guard let occupant = incomingByID[variant.copyID],
                              !occupant.deleted else { continue }
                        guard SyncMerge.matchesConflictCopyProvenance(
                            occupant,
                            sourceID: variant.sourceID,
                            fingerprint: variant.fingerprint)
                        else {
                            throw SyncSecureConflictMaterializer.Failure.identifierCollision
                        }
                        // A demotion is an ordinary plaintext C1. Provenance and the
                        // deterministic id bind its lineage; unlike a secure C1 it has
                        // no ciphertext to authenticate under the vault key.
                        if occupant.secure {
                            try SyncSecureConflictMaterializer.validateIncomingSecureCopy(
                                occupant,
                                keyring: materializationKeyring,
                                vaultKID: vault.kid)
                        }
                    }
                    let heldPlainIDs: Set<UUID> = Set(heldConflictCopyIntents.compactMap {
                        id, intent in
                        guard !intent.deleted, !intent.secure,
                              let snippet = intent.plainSnippet,
                              expectedPrimary[id] == .plain(snippet)
                        else { return nil }
                        return id
                    })
                    let incomingPlainIDs: Set<UUID> = Set((
                        variantsByEnvelope[envelope.id] ?? [])
                        .compactMap { variant in
                            guard let occupant = incomingByID[variant.copyID],
                                  !occupant.deleted, !occupant.secure,
                                  let snippet = occupant.plainSnippet,
                                  expectedPrimary[variant.copyID] == .plain(snippet)
                            else { return nil }
                            return variant.copyID
                        })
                    let authorizedPlainIDs = heldPlainIDs.union(incomingPlainIDs)
                    let result = try SyncSecureConflictMaterializer.materialize(
                        envelope: envelope,
                        keyring: materializationKeyring,
                        vaultKID: vault.kid,
                        // Only exact-provenance plain C1 values validated above may
                        // temporarily occupy a deterministic copy id. Every unrelated
                        // plaintext occupant still reaches the materializer and fails.
                        existingSnippets: contents.snippets.filter {
                            !authorizedPlainIDs.contains($0.id)
                        },
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
                    for variant in variantsByEnvelope[envelope.id] ?? [] {
                        guard let evidence = preparedEvidenceByID[variant.copyID],
                              let record = try SyncLibraryProjection.vaultRecord(
                                from: evidence,
                                preserving: vault.record(variant.copyID))
                        else {
                            throw SyncSecureConflictMaterializer.Failure.malformedVariant
                        }
                        if let index = vault.records.firstIndex(where: {
                            $0.id == variant.copyID
                        }) {
                            // Preserve a later same-provenance C1 occupant. C0 is already
                            // durable in the journal and will be offered from there.
                            guard vault.records[index].x[
                                SyncMerge.plainConflictCopyExtensionKey]
                                == record.x[SyncMerge.plainConflictCopyExtensionKey]
                            else {
                                throw SyncSecureConflictMaterializer.Failure.identifierCollision
                            }
                        } else {
                            vault.records.append(record)
                        }
                        conflictCopyEvidence.append(evidence)
                    }
                    // `result` authenticates the carrier and collision shape. Exact C0
                    // installation above deliberately uses the pre-fsynced ciphertext.
                }
                try vault.recordLocalConflictInstallReceipts(
                    for: preparedConflictCopyEvidence)
                contents.vault = vault
            }

            // These are local generations which happened after immutable copy C0 was
            // frozen for copy-before-source ordering. Apply them in the same transaction
            // as implicit materialization so C0 can never escape into primary storage as
            // a fake resurrection. Explicit fetched C values run afterwards and may
            // legitimately win the three-way merge selected by Core.
            for intent in heldConflictCopyIntents.values.sorted(by: {
                $0.id.uuidString < $1.id.uuidString
            }) {
                let wasPlain = contents.snippets.contains { $0.id == intent.id }
                let wasSecure = contents.vault?.record(intent.id) != nil

                if intent.deleted {
                    if wasPlain { contents.snippets.removeAll { $0.id == intent.id } }
                    if wasSecure, var vault = contents.vault {
                        vault.records.removeAll { $0.id == intent.id }
                        contents.vault = vault
                    }
                    if wasPlain || wasSecure { changed.append(intent.id) }
                    applied.append(intent)
                    continue
                }

                if intent.secure {
                    guard var vault = contents.vault,
                          let record = try SyncLibraryProjection.vaultRecord(
                            from: intent, preserving: vault.record(intent.id))
                    else {
                        deferred.append(intent.id)
                        continue
                    }
                    if let index = vault.records.firstIndex(where: { $0.id == intent.id }) {
                        vault.records[index] = record
                    } else {
                        vault.records.append(record)
                    }
                    contents.vault = vault
                    if wasPlain { contents.snippets.removeAll { $0.id == intent.id } }
                } else {
                    guard let snippet = intent.plainSnippet else { continue }
                    if let index = contents.snippets.firstIndex(where: { $0.id == intent.id }) {
                        contents.snippets[index] = snippet
                    } else {
                        contents.snippets.insert(snippet, at: 0)
                    }
                    if wasSecure, var vault = contents.vault {
                        vault.records.removeAll { $0.id == intent.id }
                        contents.vault = vault
                    }
                }
                changed.append(intent.id)
                applied.append(intent)
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
                if envelope.secure, envelope.deleted, wasPlain || wasSecure {
                    guard arrivingKID != nil else {
                        incompatible.append(envelope.id)
                        continue
                    }
                    guard let localKID = contents.vault?.kid else {
                        deferred.append(envelope.id)
                        continue
                    }
                    guard let arrivingKID, arrivingKID == localKID else {
                        incompatible.append(envelope.id)
                        continue
                    }
                } else if envelope.secure, !envelope.deleted,
                          let arrivingKID,
                          let localKID = contents.vault?.kid,
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
                    var normalized = envelope
                    if arrivingKID == nil {
                        normalized.x[SyncEnvelope.vaultKeyIDExtensionKey] =
                            .string(vault.kid)
                    }
                    if exactLegacyEchoIDs.contains(envelope.id) {
                        // Exact primary bytes were authenticated when first installed.
                        // Persist only normalized sidecar scope; primary remains exact.
                        applied.append(normalized)
                        continue
                    }
                    guard let record = try SyncLibraryProjection.vaultRecord(
                        from: normalized, preserving: existing)
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
                if envelope.secure,
                   envelope.x[SyncEnvelope.vaultKeyIDExtensionKey] == nil,
                   let vaultKID = contents.vault?.kid {
                    var normalized = envelope
                    normalized.x[SyncEnvelope.vaultKeyIDExtensionKey] = .string(vaultKID)
                    applied.append(normalized)
                } else {
                    applied.append(envelope)
                }
            }
            // C0 can be only an intermediate while the final copy is plaintext C1.
            // If neither file contained this id beforehand, ordinary move detection
            // cannot infer a demotion. Force snippets.json before the receipt-bearing
            // vault so a crash cannot leave receipt+absence and manufacture a deletion.
            if let plainCopyID = preparedConflictCopyEvidence.lazy.map(\.id).first(where: {
                id in
                contents.snippets.contains { $0.id == id }
                    && contents.vault?.record(id) == nil
            }) {
                contents.marker = .demoting(plainCopyID)
            }
            return ApplyResult(
                changedIDs: changed, appliedEnvelopes: applied,
                conflictCopyEvidence: conflictCopyEvidence,
                deferredIDs: deferred,
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

        if !outcome.value.retryIDs.isEmpty {
            // The transaction proved that primary storage moved after the merge input
            // and deliberately wrote nothing. Reloading here would be more than churn:
            // SecureSnippetStore.reload() re-adopts/locks the vault session and can make
            // the bounded fresh merge spuriously wait for a key it had moments ago.
            return ApplyOutcome(
                deferredIDs: guarded.deferredIDs,
                incompatibleVaultIDs: guarded.incompatibleVaultIDs,
                retryIDs: outcome.value.retryIDs
                    .sorted { $0.uuidString < $1.uuidString })
        }

        var metadata = try loadMetadata(fallingBackTo: SyncBase())
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
        // Keep exact affected IDs process-local so UI can preserve a revealed editor
        // when this batch only changed other snippets.
        store.coordinatedReloadDidFinish(
            .remoteSync,
            changedIDs: Set(outcome.value.changedIDs))
        return ApplyOutcome(
            changedIDs: outcome.value.changedIDs,
            deferredIDs: Set(guarded.deferredIDs)
                .union(outcome.value.deferredIDs)
                .sorted { $0.uuidString < $1.uuidString },
            incompatibleVaultIDs: Set(
                Set(guarded.incompatibleVaultIDs)
                    .union(outcome.value.incompatibleVaultIDs))
                .sorted { $0.uuidString < $1.uuidString },
            retryIDs: outcome.value.retryIDs
                .sorted { $0.uuidString < $1.uuidString },
            conflictCopyEvidence: outcome.value.conflictCopyEvidence.sorted {
                $0.id.uuidString < $1.id.uuidString
            })
    }

    private static func primaryState(
        for id: UUID,
        in contents: LibraryTransaction.Contents
    ) -> SyncPrimaryState {
        let snippet = contents.snippets.first { $0.id == id }
        let record = contents.vault?.record(id)
        switch (snippet, record, contents.vault) {
        case (.some(let snippet), .some(let record), .some(let vault)):
            return .duplicate(
                snippet: snippet,
                record: record,
                vaultKID: vault.kid,
                vaultSalt: vault.vaultSalt)
        case (.some(let snippet), _, _):
            return .plain(snippet)
        case (_, .some(let record), .some(let vault)):
            return .secure(
                record: record,
                vaultKID: vault.kid,
                vaultSalt: vault.vaultSalt)
        default:
            return .absent
        }
    }

    /// Conditionally removes already-preserved carrier members from the latest primary
    /// record. The comparison and mutation share `LibraryTransaction`'s locked snapshot:
    /// the resolution envelope supplied by Core is only a comparison token and must
    /// never overwrite a user edit made after the copy was materialized.
    func resolveConflictCarriers(
        _ resolutions: [SyncJournal.ConflictCarrierResolution]
    ) throws -> ApplyOutcome {
        guard !resolutions.isEmpty else { return ApplyOutcome() }

        do {
            try store.flushPendingWritesForSync()
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "the latest ordinary snippet edits could not be made durable; "
                    + "sync stopped before resolving conflict metadata")
        }

        // Metadata is only an ancestor/extension source. Every persisted user field and
        // every vault carrier is read again inside the transaction below, so an external
        // writer either lands before this locked snapshot and is preserved, or retries
        // after it. A plain source has no primary extension bag; for that representation
        // cleanup is deliberately a sidecar-only operation and never rewrites Snippet.
        let metadata = try loadMetadata(fallingBackTo: SyncBase())
        let outcome: LibraryTransaction.Outcome<[SyncEnvelope]>
        do {
            outcome = try LibraryTransaction.perform(lockTimeout: lockTimeout) { contents in
                let current = SyncLibraryProjection.currentEnvelopes(
                    snippets: contents.snippets,
                    records: contents.vault?.records ?? [],
                    deviceID: store.deviceID,
                    metadata: metadata,
                    agreedBase: metadata,
                    vaultKID: contents.vault?.kid)
                var applied: [SyncEnvelope] = []

                for resolution in resolutions {
                    guard let latest = current[resolution.sourceID],
                          let resolved = SyncMerge.resolvingContentConflicts(
                            in: latest, expected: resolution.expected)
                    else { continue }

                    if latest.secure {
                        guard var vault = contents.vault,
                              let index = vault.records.firstIndex(where: {
                                  $0.id == resolution.sourceID
                              }),
                              let record = try SyncLibraryProjection.vaultRecord(
                                from: resolved, preserving: vault.records[index])
                        else { continue }
                        vault.records[index] = record
                        contents.vault = vault
                    }
                    applied.append(resolved)
                }
                return applied
            }
        } catch let failure as LibraryTransaction.Failure {
            throw failure
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "conflict metadata changed or became malformed while it was "
                    + "being resolved; sync stopped without overwriting the snippet")
        }

        guard !outcome.value.isEmpty else { return ApplyOutcome() }
        var nextMetadata = metadata
        for envelope in outcome.value { nextMetadata.record(envelope) }
        do {
            try persistMetadataStrict(nextMetadata)
        } catch {
            // For a plain survivor this sidecar is primary storage for the opaque
            // carrier. Reporting success before its carrier-free version is durable can
            // let the dependency be ACKed/pruned and resurrect the old carrier after a
            // restart. Secure primary mutation is harmless to retry, so fail the whole
            // resolution uniformly and leave the durable edge in place.
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "resolved conflict metadata could not be saved; sync stopped "
                    + "before releasing its source record")
        }

        if outcome.wroteLibrary || outcome.wroteVault {
            store.reloadAfterExternalWrite(notifyChange: false)
            secureStore.reload(notifyChange: false)
            store.coordinatedReloadDidFinish(
                .remoteSync,
                changedIDs: Set(outcome.value.map(\.id)))
        }
        return ApplyOutcome(changedIDs: outcome.value.map(\.id))
    }

    /// Materialises carrier-owned copies without installing the source survivor. This
    /// is the recovery half of an account/checkpoint reset: the durable journal already
    /// holds authenticated carrier bytes, while the old CloudKit inbox may be gone.
    func materializeConflictPrerequisites(
        from sources: [SyncEnvelope]
    ) throws -> ApplyOutcome {
        let evidence = try prepareConflictCopyEvidence(from: sources)
        return try materializeConflictPrerequisites(
            from: sources,
            preparedConflictCopyEvidence: evidence,
            heldConflictCopyIntents: [:],
            expectedPrimary: [:])
    }

    func materializeConflictPrerequisites(
        from sources: [SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        guard !sources.isEmpty else { return ApplyOutcome() }
        do {
            try store.flushPendingWritesForSync()
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "local edits could not be made durable before recovering "
                    + "conflict copies")
        }

        let keyring: SnippetCrypto.Keyring
        do {
            keyring = try secureStore.unlockedKeyringForSync()
        } catch VaultSession.Failure.locked {
            return ApplyOutcome(deferredIDs: sources.map(\.id))
        } catch {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "the secure conflict key is unavailable; account reset stopped "
                    + "before discarding recoverable conflict data")
        }
        guard let expectedVault = secureStore.document.map({ ($0.kid, $0.vaultSalt) }) else {
            return ApplyOutcome(deferredIDs: sources.map(\.id))
        }

        let variants: [UUID: SyncMerge.SecureContentConflictVariant]
        var evidenceByID: [UUID: SyncEnvelope] = [:]
        do {
            var parsed: [UUID: SyncMerge.SecureContentConflictVariant] = [:]
            for source in sources {
                for variant in try SyncMerge.secureContentConflictVariants(in: source) {
                    guard parsed.updateValue(variant, forKey: variant.copyID) == nil else {
                        throw SyncMerge.EnvelopeFailure.malformedContentConflict
                    }
                }
            }
            variants = parsed
            for evidence in preparedConflictCopyEvidence {
                guard evidenceByID.updateValue(evidence, forKey: evidence.id) == nil,
                      let variant = variants[evidence.id],
                      evidence.secure, !evidence.deleted,
                      SyncMerge.hasValidConflictCopyIdentity(evidence),
                      SyncMerge.matchesConflictCopyProvenance(
                        evidence,
                        sourceID: variant.sourceID,
                        fingerprint: variant.fingerprint),
                      evidence.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                        == expectedVault.0
                else { throw SyncMerge.EnvelopeFailure.malformedContentConflict }
                try SyncSecureConflictMaterializer.validatePreparedEvidence(
                    evidence,
                    for: variant,
                    keyring: keyring,
                    vaultKID: expectedVault.0)
            }
            guard Set(evidenceByID.keys) == Set(variants.keys),
                  heldConflictCopyIntents.allSatisfy({ id, intent in
                    guard id == intent.id, let variant = variants[id] else { return false }
                    if intent.secure && !intent.deleted {
                        guard intent.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                            == expectedVault.0,
                              SyncMerge.matchesConflictCopyProvenance(
                                intent,
                                sourceID: variant.sourceID,
                                fingerprint: variant.fingerprint)
                        else { return false }
                    }
                    return intent.deleted || SyncMerge.matchesConflictCopyProvenance(
                        intent,
                        sourceID: variant.sourceID,
                        fingerprint: variant.fingerprint)
                  })
            else { throw SyncMerge.EnvelopeFailure.malformedContentConflict }
            for intent in heldConflictCopyIntents.values where
                intent.secure && !intent.deleted {
                try SyncSecureConflictMaterializer.validateIncomingSecureCopy(
                    intent, keyring: keyring, vaultKID: expectedVault.0)
            }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "frozen conflict-copy recovery evidence was malformed or unauthenticated")
        }

        let outcome: LibraryTransaction.Outcome<MaterializePrerequisitesResult>
        do {
            outcome = try LibraryTransaction.perform(lockTimeout: lockTimeout) { contents in
                if !expectedPrimary.isEmpty,
                   expectedPrimary.contains(where: { id, expected in
                       Self.primaryState(for: id, in: contents) != expected
                   }) {
                    return MaterializePrerequisitesResult(
                        materializedIDs: [],
                        primaryCASMiss: true)
                }
                guard var vault = contents.vault,
                      vault.kid == expectedVault.0,
                      vault.vaultSalt == expectedVault.1 else {
                    throw SyncSecureConflictMaterializer.Failure.incompatibleVault
                }
                var materialized = Set<UUID>()
                for source in sources {
                    // Authenticate the retained carrier and every deterministic collision
                    // under the current transaction snapshot. The returned fresh nonce
                    // is deliberately ignored: exact bytes come from the fsynced journal.
                    let result = try SyncSecureConflictMaterializer.materialize(
                        envelope: source,
                        keyring: keyring,
                        vaultKID: vault.kid,
                        existingSnippets: contents.snippets.filter { snippet in
                            guard let intent = heldConflictCopyIntents[snippet.id],
                                  !intent.deleted, !intent.secure,
                                  let expectedSnippet = intent.plainSnippet,
                                  expectedPrimary[snippet.id] == .plain(expectedSnippet)
                            else { return true }
                            return false
                        },
                        existingRecords: vault.records)
                    _ = result
                    for variant in try SyncMerge.secureContentConflictVariants(in: source) {
                        guard let evidence = evidenceByID[variant.copyID],
                              let record = try SyncLibraryProjection.vaultRecord(
                                from: evidence,
                                preserving: vault.record(variant.copyID))
                        else { throw SyncSecureConflictMaterializer.Failure.malformedVariant }
                        if let index = vault.records.firstIndex(where: {
                            $0.id == variant.copyID
                        }) {
                            // A same-provenance C1 is a later user generation. Keep it;
                            // the journal owns C0 transport ordering independently.
                            guard vault.records[index].x[
                                SyncMerge.plainConflictCopyExtensionKey]
                                == record.x[SyncMerge.plainConflictCopyExtensionKey]
                            else {
                                throw SyncSecureConflictMaterializer.Failure.identifierCollision
                            }
                        } else {
                            vault.records.append(record)
                            materialized.insert(variant.copyID)
                        }
                    }
                }

                // Reapply post-C0 local intent before releasing the library lock. This
                // prevents recovery from surfacing C0 as a resurrection even briefly.
                for intent in heldConflictCopyIntents.values.sorted(by: {
                    $0.id.uuidString < $1.id.uuidString
                }) {
                    let wasPlain = contents.snippets.contains { $0.id == intent.id }
                    let wasSecure = vault.record(intent.id) != nil
                    if intent.deleted {
                        if wasPlain { contents.snippets.removeAll { $0.id == intent.id } }
                        if wasSecure { vault.records.removeAll { $0.id == intent.id } }
                        continue
                    }
                    if intent.secure {
                        guard let record = try SyncLibraryProjection.vaultRecord(
                            from: intent, preserving: vault.record(intent.id))
                        else { throw SyncSecureConflictMaterializer.Failure.malformedVariant }
                        if let index = vault.records.firstIndex(where: { $0.id == intent.id }) {
                            vault.records[index] = record
                        } else {
                            vault.records.append(record)
                        }
                        if wasPlain { contents.snippets.removeAll { $0.id == intent.id } }
                    } else {
                        guard let snippet = intent.plainSnippet else {
                            throw SyncSecureConflictMaterializer.Failure.malformedVariant
                        }
                        if let index = contents.snippets.firstIndex(where: {
                            $0.id == intent.id
                        }) {
                            contents.snippets[index] = snippet
                        } else {
                            contents.snippets.insert(snippet, at: 0)
                        }
                        if wasSecure { vault.records.removeAll { $0.id == intent.id } }
                    }
                }
                try vault.recordLocalConflictInstallReceipts(
                    for: preparedConflictCopyEvidence)
                contents.vault = vault
                if let plainCopyID = preparedConflictCopyEvidence.lazy.map(\.id).first(where: {
                    id in
                    contents.snippets.contains { $0.id == id }
                        && contents.vault?.record(id) == nil
                }) {
                    contents.marker = .demoting(plainCopyID)
                }
                return MaterializePrerequisitesResult(
                    materializedIDs: materialized.sorted {
                        $0.uuidString < $1.uuidString
                    },
                    primaryCASMiss: false)
            }
        } catch let failure as LibraryTransaction.Failure {
            throw failure
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a secure conflict prerequisite could not be authenticated or "
                    + "materialised; account reset stopped without overwriting data")
        }

        if outcome.value.primaryCASMiss {
            return ApplyOutcome(
                retryIDs: sources.map(\.id).sorted { $0.uuidString < $1.uuidString })
        }
        if outcome.wroteLibrary || outcome.wroteVault {
            secureStore.reload(notifyChange: false)
            store.reloadAfterExternalWrite(notifyChange: false)
            store.coordinatedReloadDidFinish(
                .remoteSync,
                changedIDs: Set(outcome.value.materializedIDs))
        }
        return ApplyOutcome(
            changedIDs: outcome.value.materializedIDs,
            conflictCopyEvidence: preparedConflictCopyEvidence.sorted {
                $0.id.uuidString < $1.id.uuidString
            })
    }

    // MARK: - Frozen-file metadata

    /// The file intentionally reuses `SyncBase`'s canonical-envelope map encoding. Its
    /// cursor is always nil; semantically this is the local projection, not the agreed
    /// backend ancestor.
    private func loadMetadata(fallingBackTo fallback: SyncBase) throws -> SyncBase {
        // Other app boundaries (notably promote/demote) make safety-critical sidecar
        // writes without owning this bridge instance. Re-read the tiny file on every
        // projection so an in-process cache cannot overwrite their newer handoff.
        switch SyncBaseFile.load(from: metadataURL) {
        case .loaded(let loaded):
            metadataCache = loaded
            return loaded
        case .missing:
            if metadataCache == nil { metadataCache = fallback }
            return metadataCache ?? fallback
        case .tooNew(let version):
            throw SyncEngineFailure(
                reason: .schemaTooNew,
                detail: "Sync/library-metadata.json is version \(version); this build "
                    + "will not replace newer projection metadata")
        case .unreadable:
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "sync projection metadata could not be read; sync stopped "
                    + "instead of replacing unknown causal fields")
        }
    }

    private func persistMetadata(_ envelopes: [UUID: SyncEnvelope]) {
        var next = SyncBase()
        for envelope in envelopes.values { next.record(envelope) }
        guard metadataCache != next else { return }
        do {
            try persistMetadataStrict(next)
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

    /// Safety-critical counterpart to the ordinary best-effort projection cache. Cache
    /// publication follows the atomic file write so a failed cleanup cannot look durable
    /// to the running engine while a restart would still read carrier-bearing bytes.
    private func persistMetadataStrict(_ next: SyncBase) throws {
        guard metadataCache != next else { return }
        try SyncBaseFile.write(
            next, to: metadataURL, temporaryDirectory: temporaryDirectory)
        metadataCache = next
    }

    /// Drops only the vault-owned portion of the in-process projection sidecar after a
    /// deliberate local vault removal. `SecureSnippetStore` prunes the file durably, but
    /// this bridge may have cached its old contents; without the matching memory update,
    /// re-enabling sync in the same process would still fail closed on those stale secure
    /// entries. Plaintext and unknown extension metadata remains intact.
    func forgetSecureProjectionMetadata() {
        // `SecureSnippetStore.forgetEverything` already made the scrubbed sidecar
        // durable before deleting vault ciphertext/key material. Publishing that file
        // into this process must not perform a second best-effort rewrite: if it failed,
        // the disk would be safe but this cache could still resurrect forgotten IDs on
        // a same-process opt-in. Reload the authoritative post-transaction bytes.
        switch SyncBaseFile.load(from: metadataURL) {
        case .loaded(let retained):
            metadataCache = retained
        case .missing:
            metadataCache = SyncBase()
        case .tooNew, .unreadable:
            // The forget transaction would have rejected either state before deleting
            // the vault. A race after it returned must fail closed on the next projection
            // rather than publishing the stale pre-forget cache.
            metadataCache = nil
        }
    }
}
