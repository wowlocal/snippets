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
/// - The keyed `contentHash` travels alongside, so a device that cannot decrypt can
///   still tell whether the content changed and merge correctly.
@MainActor
final class SnippetLibraryBridge: SyncLibraryAccess {

    private let store: SnippetStore
    private let secureStore: SecureSnippetStore
    private let lockTimeout: TimeInterval

    init(store: SnippetStore, secureStore: SecureSnippetStore, lockTimeout: TimeInterval = 2.0) {
        self.store = store
        self.secureStore = secureStore
        self.lockTimeout = lockTimeout
    }

    // MARK: - Reading

    func currentEnvelopes() throws -> [UUID: SyncEnvelope] {
        var out: [UUID: SyncEnvelope] = [:]

        for snippet in store.snippets {
            out[snippet.id] = SyncEnvelope(
                id: snippet.id,
                hlc: HLC.foreign(updatedAt: snippet.updatedAt),
                origin: store.deviceID,
                secure: false,
                deleted: false,
                fields: SyncEnvelope.Fields(
                    name: snippet.name, keyword: snippet.normalizedKeyword,
                    content: Data(snippet.content.utf8), tags: snippet.tags,
                    isEnabled: snippet.isEnabled, isPinned: snippet.isPinned,
                    createdAt: snippet.createdAt, updatedAt: snippet.updatedAt))
        }

        for record in secureStore.document?.records ?? [] {
            out[record.id] = SyncEnvelope(
                id: record.id,
                hlc: record.hlc,
                origin: store.deviceID,
                secure: true,
                deleted: false,
                // The sealed string, not the plaintext. This is why sync works locked.
                fields: SyncEnvelope.Fields(
                    name: record.name, keyword: record.keyword,
                    content: Data(record.sealed.utf8), tags: record.tags,
                    isEnabled: record.isEnabled, isPinned: record.isPinned,
                    createdAt: record.createdAt, updatedAt: record.updatedAt))
        }
        return out
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

        let outcome = try LibraryTransaction.perform(lockTimeout: lockTimeout) { contents in
            var changed: [UUID] = []

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
                    continue
                }

                guard let fields = envelope.fields else { continue }

                if envelope.secure {
                    // Arriving secure. A vault must already exist here — its `kid` is the
                    // crypto scope, and inventing one locally would produce a document
                    // whose records no other device can open. Skipping is correct and
                    // recoverable: the record is left in the base as unseen, so it
                    // reappears on the next round once the vault has been set up.
                    guard var vault = contents.vault else { continue }

                    let sealed = String(decoding: fields.content, as: UTF8.self)
                    let record = VaultRecord(
                        id: envelope.id, name: fields.name, keyword: fields.keyword,
                        tags: fields.tags, isEnabled: fields.isEnabled, isPinned: fields.isPinned,
                        createdAt: fields.createdAt, updatedAt: fields.updatedAt,
                        hlc: envelope.hlc,
                        contentHash: envelope.contentHash ?? "",
                        sealed: sealed)

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
            }
            return changed
        }

        // Both stores re-read from disk, because the transaction wrote underneath them.
        store.reloadAfterExternalWrite()
        secureStore.reload()
        return outcome.value
    }
}
