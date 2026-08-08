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
    private let baseURL: URL
    private let metadataURL: URL
    private let temporaryDirectory: URL
    private var metadataCache: SyncBase?

    private struct ApplyResult {
        var changedIDs: [UUID]
        var appliedEnvelopes: [SyncEnvelope]
    }

    init(
        store: SnippetStore,
        secureStore: SecureSnippetStore,
        lockTimeout: TimeInterval = 2.0,
        baseURL: URL = SnippetStorageLocations.syncBaseFileURL,
        metadataURL: URL = SnippetStorageLocations.syncLibraryMetadataFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) {
        self.store = store
        self.secureStore = secureStore
        self.lockTimeout = lockTimeout
        self.baseURL = baseURL
        self.metadataURL = metadataURL
        self.temporaryDirectory = temporaryDirectory
    }

    // MARK: - Reading

    func currentEnvelopes() throws -> [UUID: SyncEnvelope] {
        let agreedBase: SyncBase
        if case .loaded(let loaded) = SyncBaseFile.load(from: baseURL) {
            agreedBase = loaded
        } else {
            // The base is derived state. Losing it costs one full reconcile; it must
            // never make the user's library unreadable or stop local edits syncing.
            agreedBase = SyncBase()
        }
        let envelopes = SyncLibraryProjection.currentEnvelopes(
            snippets: store.snippets,
            records: secureStore.document?.records ?? [],
            deviceID: store.deviceID,
            metadata: loadMetadata(fallingBackTo: agreedBase),
            agreedBase: agreedBase)
        persistMetadata(envelopes)
        return envelopes
    }

    func liveIDs() -> Set<UUID> {
        Set(store.snippets.map(\.id)).union(secureStore.shells.map(\.id))
    }

    // MARK: - Applying

    /// Writes merged remote state into whichever store owns each record.
    ///
    /// Everything goes through one `LibraryTransaction`, so a remote change that moves a
    /// record between plaintext and secure cannot be observed half-applied — and so a
    /// concurrent CLI write cannot interleave with it.
    @discardableResult
    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> [UUID] {
        guard !envelopes.isEmpty else { return [] }

        // Same hazard as promote: the transaction below reads snippets.json from disk,
        // so an unflushed in-memory edit would be invisible to it and then land on top
        // of the merged result a fraction of a second later.
        store.flushPendingWrites()

        let outcome = try LibraryTransaction.perform(lockTimeout: lockTimeout) { contents in
            var changed: [UUID] = []
            var applied: [SyncEnvelope] = []

            for envelope in envelopes {
                let wasPlain = contents.snippets.contains { $0.id == envelope.id }
                let wasSecure = contents.vault?.record(envelope.id) != nil

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
                    // whose records no other device can open. Skipping is correct and
                    // recoverable: aborting this round leaves the fetch cursor before
                    // the record, so it reappears once the vault has been set up.
                    // Silently skipping would still advance the cursor and then make
                    // the live base record look locally deleted on the next round.
                    guard var vault = contents.vault else {
                        throw SyncLibraryProjection.Failure.secureVaultMissing(envelope.id)
                    }

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
            return ApplyResult(changedIDs: changed, appliedEnvelopes: applied)
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
        store.reloadAfterExternalWrite()
        secureStore.reload()
        return outcome.value.changedIDs
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
            NSLog("Snippets: could not write sync library metadata: \(error)")
        }
    }
}
