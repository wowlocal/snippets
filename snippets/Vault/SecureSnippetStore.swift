import CryptoKit
import Foundation

/// Owns `Vault/vault.json`: the secure snippets, and the moves in and out of it.
///
/// ## Metadata works while locked, content does not
///
/// A secure record's name, keyword, tags, enabled and pinned flags are plaintext in the
/// vault file, so renaming one, retagging it, or deleting it needs no key and no Touch
/// ID. Only reading or changing the *content* does.
///
/// That split is not a convenience — it is forced. The keyword matcher runs inside a
/// `CGEventTap` while the app is in the background and the vault is locked, so it must
/// be able to see that a secret named "AWS root password" with keyword `awsroot` exists
/// without being able to read it. The cost is stated plainly in the threat model: an
/// attacker with the file learns that the secret exists and when it changed.
///
/// ## Moving between the two files
///
/// Promotion and demotion span `snippets.json` and `vault.json`, so they go through
/// `LibraryTransaction` — one lock over both, each destination written before its
/// source is removed, with a marker describing what is in flight. See
/// `reconcileInterruptedMove`.
@MainActor
final class SecureSnippetStore: SecureSnippetProviding {

    enum Failure: Error, CustomStringConvertible {
        case vaultUnreadable(String)
        case noSuchRecord
        case notSecure
        case alreadySecure
        case setupCancelled
        case recoveryUnavailable
        case invalidUTF8
        case transaction(String)
        case sharedVaultKeyMissing
        case forgetRequiresSyncOff
        case forgetWaitForSync

        var description: String {
            switch self {
            case .vaultUnreadable(let detail): return detail
            case .noSuchRecord: return "no such snippet"
            case .notSecure: return "that snippet is not secure"
            case .alreadySecure: return "that snippet is already secure"
            case .setupCancelled: return "secure-snippet setup was cancelled"
            case .recoveryUnavailable: return "this vault has no recovery key"
            case .invalidUTF8: return "the secure snippet is not valid UTF-8"
            case .transaction(let detail): return detail
            case .sharedVaultKeyMissing:
                return "your other device's secure-snippets key has not reached this one yet. "
                    + "Check that iCloud Keychain is on in Settings, or restore the "
                    + "key with your recovery key under Secure Snippets."
            case .forgetRequiresSyncOff:
                return "Turn off iCloud Sync first. Then Snippets can remove this device's "
                    + "vault without deleting the shared key or affecting your other devices."
            case .forgetWaitForSync:
                return "iCloud Sync is still finishing a round. Wait a moment and try again."
            }
        }
    }

    enum EncryptedBackupFailure: Error, LocalizedError {
        case incompatibleVault
        case vaultKeyMismatch
        case conflicts([String])

        var errorDescription: String? {
            switch self {
            case .incompatibleVault:
                return "This backup belongs to a different secure-snippet vault. "
                    + "Import it into a fresh Snippets library or a device already using the same vault."
            case .vaultKeyMismatch:
                return "The backup and this device have different keys for the same secure-snippet vault. Nothing was imported."
            case .conflicts(let conflicts):
                if conflicts.count == 1 { return "Import conflict: \(conflicts[0])" }
                return "Import conflicts:\n" + conflicts.map { "- \($0)" }.joined(separator: "\n")
            }
        }
    }

    struct EncryptedBackupExport {
        var data: Data
        var ordinaryCount: Int
        var secureCount: Int
        var totalCount: Int { ordinaryCount + secureCount }
    }

    struct EncryptedBackupImportResult {
        var ordinaryCount: Int
        var secureCount: Int
        var totalCount: Int { ordinaryCount + secureCount }
    }

    private(set) var document: VaultDocument?

    /// Set when the vault on disk could not be read. **Everything that writes refuses
    /// while this is true.** An unreadable vault is not an absent one, and writing a
    /// fresh document over it would destroy secrets a quarantined copy might recover.
    private(set) var isUnreadable = false

    var onChange: (() -> Void)?

    private let session: VaultSession
    private let keychain: KeychainSecretStore
    /// Publishes and adopts the vault's identity through iCloud Keychain, which is what
    /// makes a second Mac join this vault instead of minting a rival one.
    private let identityStore: VaultIdentityStore
    private let vaultURL: URL
    private let libraryURL: URL
    private let lockURL: URL
    private let temporaryDirectory: URL
    private let syncBaseURL: URL
    private let syncMetadataURL: URL
    private let lockTimeout: TimeInterval

    /// Injected so tests can drive timestamps and clocks deterministically.
    var now: () -> Date = { Date() }
    var clock: HLCGenerator

    init(
        session: VaultSession,
        keychain: KeychainSecretStore? = nil,
        deviceID: String,
        vaultURL: URL = SnippetStorageLocations.vaultFileURL,
        libraryURL: URL = SnippetStorageLocations.snippetsFileURL,
        lockURL: URL = SnippetStorageLocations.libraryLockFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL,
        syncBaseURL: URL = SnippetStorageLocations.syncBaseFileURL,
        syncMetadataURL: URL = SnippetStorageLocations.syncLibraryMetadataFileURL,
        lockTimeout: TimeInterval = 2.0
    ) {
        let resolvedKeychain = keychain ?? KeychainSecretStore()
        self.session = session
        self.keychain = resolvedKeychain
        self.identityStore = VaultIdentityStore(keychain: resolvedKeychain)
        self.vaultURL = vaultURL
        self.libraryURL = libraryURL
        self.lockURL = lockURL
        self.temporaryDirectory = temporaryDirectory
        self.syncBaseURL = syncBaseURL
        self.syncMetadataURL = syncMetadataURL
        self.lockTimeout = lockTimeout
        self.clock = HLCGenerator(device: deviceID)
        reload()
    }

    // MARK: - Loading

    func reload() {
        switch VaultFile.load(from: vaultURL) {
        case .loaded(let loaded):
            document = loaded
            isUnreadable = false
            session.adopt(keyID: loaded.kid)
            // Opportunistic, and cheap after the first call. It upgrades a vault created
            // before identity sharing existed, and heals a slot another Mac cleared,
            // without either needing a migration step of its own.
            identityStore.publish(loaded)
        case .missing:
            document = nil
            isUnreadable = false
            session.adopt(keyID: nil)
            adoptSharedVaultIfAvailable()
        case .tooNew(let version):
            // A newer build owns this file. Show what we can; never write.
            document = nil
            isUnreadable = true
            session.adopt(keyID: nil)
            NSLog("Snippets: vault is schemaVersion \(version); running read-only.")
        case .unreadable(let error), .corrupt(let error):
            document = nil
            isUnreadable = true
            session.adopt(keyID: nil)
            NSLog("Snippets: vault could not be read (\(error)); refusing to write to it.")
        }
        onChange?()
    }

    // MARK: - Metadata, available while locked

    /// Content-free `Snippet` values for display and for keyword-uniqueness checks.
    var shells: [Snippet] { document?.shells ?? [] }

    var isEmpty: Bool { document?.records.isEmpty ?? true }

    /// An existing zero-record vault still owns a key, salt, and recovery wrap and
    /// must not be mistaken for first-run state.
    var hasVault: Bool { document != nil }

    var count: Int { document?.records.count ?? 0 }

    var hasRecoveryKey: Bool { document?.wrapRecovery != nil }

    /// Whether deleting this vault's Keychain item would reach the user's other Macs.
    ///
    /// This follows the Keychain tier rather than the published identity. Publication can
    /// fail or its slot can be temporarily missing while `K_lib` is still a
    /// synchronizable item whose deletion propagates account-wide. Destructive behavior
    /// must over-report sharing, never infer "local" from a failed identity lookup.
    var usesSynchronizableVaultKey: Bool { keychain.tier.syncsBetweenDevices }

    func isSecure(_ id: UUID) -> Bool { document?.record(id) != nil }

    /// `SecureSnippetProviding`. Shells only — never content, never a key.
    func secureShellsForDisplay() -> [Snippet] { shells }

    func record(_ id: UUID) -> VaultRecord? { document?.record(id) }

    /// Enabled secure shells, for the picker.
    ///
    /// Deliberately separate from `SnippetStore.enabledSnippetsSorted()`, which feeds
    /// **auto-expansion from the keystroke buffer**. Secure records must never reach
    /// that path: a secret that types itself because five characters matched is the
    /// failure this whole feature exists to prevent. Keeping the two lists apart makes
    /// that structural rather than a rule a later refactor can forget.
    func enabledShellsSortedForDisplay() -> [Snippet] {
        shells.filter(\.isEnabled)
    }

    // MARK: - Creating the vault

    /// Joins the vault the user's other Macs already share, when there is one.
    ///
    /// Writes a records-free `vault.json` carrying the shared `kid`, salt and wraps, and
    /// points the session at it. The library key itself is already on its way over the
    /// same channel — `KeychainSecretStore` stores `K_lib` as a synchronizable item — so
    /// in the ordinary case this Mac can open the vault the moment records arrive. When
    /// the key has *not* arrived (iCloud Keychain off, most likely), the vault reports
    /// `.noKey` and Settings offers the recovery key, which is a state the app already
    /// knows how to be in. What it must never do instead is mint a rival vault: a second
    /// `kid` is a second crypto scope, and the two Macs then cannot read a single one of
    /// each other's records.
    ///
    /// Adoption writes a file, so `reload` only does it when sync is on — a Mac that
    /// merely shares an iCloud account should not spontaneously grow a vault. An
    /// explicit "make this secure" is a different matter: the user is asking for a
    /// vault, and the right one to give them is the one they already have.
    @discardableResult
    private func adoptSharedVaultIfAvailable(requireSyncEnabled: Bool = true) -> VaultDocument? {
        guard document == nil, !isUnreadable else { return nil }
        guard !requireSyncEnabled || SyncCoordinator.isEnabled else { return nil }
        guard let identity = identityStore.published() else { return nil }

        let adopted: VaultDocument
        do {
            adopted = try VaultFile.update(
                at: vaultURL,
                lockURL: lockURL,
                temporaryDirectory: temporaryDirectory,
                lockTimeout: lockTimeout
            ) { existing in
                // Read under the lock: another process may have created a vault since
                // the load that reported `.missing`. Theirs wins — it may already hold
                // records, and this document holds none.
                if let existing { return existing }
                var fresh = identity
                fresh.records = []
                return fresh
            }
        } catch {
            NSLog("Snippets: the shared vault could not be adopted (\(error)).")
            return nil
        }

        document = adopted
        session.adopt(keyID: adopted.kid)
        return adopted
    }

    /// Refuses an operation that needs to *write* a secret when the key is not here.
    ///
    /// Only reachable on an adopted vault: a vault this Mac minted stored its key in the
    /// same breath. `hasKey` rather than an unlock, because this is a question about the
    /// keychain, not about the user — raising a Touch ID prompt to discover that there is
    /// nothing to authenticate against would be a prompt that cannot succeed.
    private func requireUsableKey(for document: VaultDocument) throws {
        guard !keychain.hasKey(keyID: document.kid) else { return }
        throw Failure.sharedVaultKeyMissing
    }

    /// Joins the shared vault if there is one, announcing it if it worked.
    ///
    /// For callers outside the load path — chiefly `SnippetLibraryBridge`, when a secure
    /// record arrives and there is nowhere to put it. That moment is the best trigger
    /// there is: this Mac has just been told, by the backend, that a vault exists
    /// somewhere. Without it, adoption would wait for the next launch or the next local
    /// vault change, neither of which a Mac with no secure snippets ever has.
    @discardableResult
    func joinSharedVaultIfAvailable() -> Bool {
        guard adoptSharedVaultIfAvailable() != nil else { return false }
        onChange?()
        return true
    }

    /// Creates a vault and its library key, storing the key in the keychain.
    ///
    /// Idempotent: an existing vault is returned untouched, so this is safe to call
    /// from a "make this snippet secure" flow without a separate setup step. A vault the
    /// user's other Macs already share counts as existing — see
    /// `adoptSharedVaultIfAvailable`.
    @discardableResult
    func createVaultIfNeeded(
        confirmRecoveryKey: (String) -> Bool
    ) throws -> VaultDocument {
        if let document {
            try requireUsableKey(for: document)
            return document
        }
        guard !isUnreadable else {
            throw Failure.vaultUnreadable("refusing to create a vault over an unreadable one")
        }
        if let adopted = adoptSharedVaultIfAvailable(requireSyncEnabled: false) {
            onChange?()
            // Adopted, written, and pointed at — and then refused, because a vault whose
            // key has not arrived cannot take a new secret. Saying so here is the whole
            // point: without it the caller went on to `promote`, failed deep inside
            // `VaultSession` with a bare "no vault key is available on this Mac", and left
            // the user with a vault they could neither use nor replace, since `document`
            // is now non-nil and the minting path above can never run again.
            //
            // Adopting anyway, rather than refusing before the write, is deliberate: the
            // alternative is minting a rival `kid`, which splits the vault permanently.
            // A vault that is merely waiting for its key is recoverable — by iCloud
            // Keychain delivering it, or by the recovery key Settings now offers, because
            // the adopted document carries the wrap.
            try requireUsableKey(for: adopted)
            return adopted
        }

        let keyring = SnippetCrypto.Keyring.generate()
        let kid = "k-\(UUID().uuidString.lowercased().prefix(12))"
        let recoveryKey = RecoveryKey.generate()
        let recoveryText = try RecoveryKey.formatted(recoveryKey)
        guard confirmRecoveryKey(recoveryText) else { throw Failure.setupCancelled }

        let recoveryWrap = try KeyWrap.wrap(
            keyring.libraryKey,
            under: recoveryKey,
            purpose: .recovery,
            kid: kid,
            salt: keyring.salt)

        // The key goes in the keychain BEFORE the document exists on disk. The other
        // order can leave a vault whose key was never stored — a file full of records
        // nothing can ever open.
        try keychain.store(
            keyring.libraryKey.withUnsafeBytes { Data($0) },
            keyID: kid)

        let created = VaultDocument(
            kid: kid,
            vaultSalt: SnippetCrypto.base64URL(keyring.salt),
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))),
            wrapRecovery: recoveryWrap)

        do {
            try VaultFile.write(created, to: vaultURL, temporaryDirectory: temporaryDirectory)
        } catch {
            try? keychain.deleteKey(keyID: kid)
            throw error
        }
        document = created
        session.adopt(keyID: kid)
        // Publish only after the vault exists on disk. The other order would advertise a
        // vault this Mac might then have failed to write, and a second Mac would adopt a
        // `kid` whose records live nowhere.
        identityStore.publish(created)
        onChange?()
        return created
    }

    /// Adds the escape hatch to a vault created by a build that did not yet wire it.
    /// The vault must already be unlocked; cancellation writes nothing.
    @discardableResult
    func addRecoveryKeyIfNeeded(confirmRecoveryKey: (String) -> Bool) throws -> Bool {
        guard let document else { throw Failure.noSuchRecord }
        guard document.wrapRecovery == nil else { return false }
        guard let salt = document.vaultSaltBytes else {
            throw Failure.vaultUnreadable("the vault's salt could not be decoded")
        }

        // Capture the authenticated key before showing a modal panel. The panel spins
        // the run loop, so the session timer may fire while the user saves the text.
        // An already-authorised recovery setup is allowed to finish; otherwise the
        // user could save a key that is never actually committed.
        let libraryKey = try session.currentKey()

        let recoveryKey = RecoveryKey.generate()
        let recoveryText = try RecoveryKey.formatted(recoveryKey)
        guard confirmRecoveryKey(recoveryText) else { throw Failure.setupCancelled }
        let envelope = try KeyWrap.wrap(
            libraryKey, under: recoveryKey, purpose: .recovery,
            kid: document.kid, salt: salt)

        try mutateVault { vault in
            if vault.wrapRecovery == nil { vault.wrapRecovery = envelope }
        }
        // The recovery wrap is part of the identity, and it is the escape hatch a second
        // Mac needs when iCloud Keychain did not carry the key. Republish so that Mac can
        // use it without this one being present. `self.document`, not the local capture
        // above — that one predates the wrap this just added.
        if let updated = self.document { identityStore.publish(updated) }
        return true
    }

    /// Restores a missing Keychain item from the printable recovery key. `KeyWrap`
    /// authenticates the recovered bytes against this vault's `kid` before anything is
    /// stored, so a typo cannot replace a good local key with garbage.
    func restoreKey(fromRecoveryKey text: String) throws {
        let document = try requireDocument()
        guard let envelope = document.wrapRecovery else { throw Failure.recoveryUnavailable }
        guard let salt = document.vaultSaltBytes else {
            throw Failure.vaultUnreadable("the vault's salt could not be decoded")
        }
        let recoveryKey = try RecoveryKey.decode(text)
        let libraryKey = try KeyWrap.unwrap(
            envelope, under: recoveryKey, purpose: .recovery,
            kid: document.kid, salt: salt)
        try keychain.store(
            libraryKey.withUnsafeBytes { Data($0) },
            keyID: document.kid)
        session.adopt(keyID: document.kid)
        onChange?()
    }

    // MARK: - Content, requires an unlocked vault

    func contentData(for id: UUID) throws -> Data {
        let document = try requireDocument()
        guard let record = document.record(id) else { throw Failure.noSuchRecord }
        return try SnippetCrypto.open(
            record.sealed, for: context(for: id, in: document), keyring: try keyring(document))
    }

    func content(for id: UUID) throws -> String {
        var plaintext = try contentData(for: id)
        defer { SecureMemory.wipe(&plaintext) }
        // Converted to `String` only here, at the last possible moment. Everything
        // upstream is `Data`, because a `String` is copied by value and cannot be
        // scrubbed.
        guard let text = SnippetCrypto.plaintextString(plaintext) else { throw Failure.invalidUTF8 }
        return text
    }

    func setContent(_ content: String, for id: UUID) throws {
        let document = try requireDocument()
        guard document.record(id) != nil else { throw Failure.noSuchRecord }
        let ring = try keyring(document)
        let plaintext = Data(content.utf8)
        let sealed = try SnippetCrypto.seal(plaintext, for: context(for: id, in: document), keyring: ring)
        let hash = SnippetCrypto.contentHash(of: plaintext, keyring: ring)

        try mutateVault { vault in
            guard let index = vault.records.firstIndex(where: { $0.id == id }) else { return }
            vault.records[index].sealed = sealed
            vault.records[index].contentHash = hash
            vault.records[index].updatedAt = self.now()
            vault.records[index].hlc = self.clock.send()
        }
    }

    /// Renames, retags, enables, pins. **No key required** — see the type's docs.
    func updateMetadata(
        id: UUID,
        name: String? = nil, keyword: String? = nil, tags: [String]? = nil,
        isEnabled: Bool? = nil, isPinned: Bool? = nil
    ) throws {
        try mutateVault { vault in
            guard let index = vault.records.firstIndex(where: { $0.id == id }) else { return }
            if let name { vault.records[index].name = name }
            if let keyword { vault.records[index].keyword = Snippet.sanitizedKeyword(keyword) }
            if let tags { vault.records[index].tags = SnippetTagging.normalizedTags(tags) }
            if let isEnabled { vault.records[index].isEnabled = isEnabled }
            if let isPinned { vault.records[index].isPinned = isPinned }
            vault.records[index].updatedAt = self.now()
            vault.records[index].hlc = self.clock.send()
        }
    }

    /// Deletes a secure snippet. No key required: destroying ciphertext does not need
    /// the ability to read it, and requiring Touch ID to delete something would be a
    /// strange place to put friction.
    func delete(id: UUID) throws {
        try mutateVault { vault in
            vault.records.removeAll { $0.id == id }
        }
    }

    // MARK: - Encrypted backup

    /// Creates the portable all-library backup. The ordinary share export remains on
    /// `SnippetStore`; keeping the entry points separate makes including secrets an
    /// explicit user choice rather than a checkbox whose state could be remembered.
    ///
    /// A fresh user-presence check is required whenever the snapshot actually contains
    /// secure records. The record bodies remain sealed throughout: only `K_lib` is read
    /// from the authenticated session, then wrapped by `EncryptedSnippetBackup`.
    func makeEncryptedBackup(
        store: SnippetStore,
        passphrase: String
    ) async throws -> EncryptedBackupExport {
        store.flushPendingWrites()
        reload()

        if document?.records.isEmpty == false {
            return try await session.withOneUseAuthentication(
                reason: "Export an encrypted backup including secure snippets"
            ) {
                try self.buildEncryptedBackup(passphrase: passphrase)
            }
        }
        return try buildEncryptedBackup(passphrase: passphrase)
    }

    /// Opens and merges a backup without ever writing its decrypted payload to disk.
    /// The two live library files are changed by one `LibraryTransaction`, so every
    /// preflight error leaves both untouched. A backup may join a fresh device to its
    /// vault or merge into the same vault; a rival vault is refused rather than silently
    /// decrypting and re-encrypting an entire security domain.
    func importEncryptedBackup(
        _ data: Data,
        passphrase: String,
        into store: SnippetStore
    ) async throws -> EncryptedBackupImportResult {
        let opened = try EncryptedSnippetBackup.open(data, passphrase: passphrase)
        store.flushPendingWrites()
        reload()

        guard let incomingVault = opened.vault else {
            return try mergeEncryptedBackup(opened, into: store)
        }
        guard let incomingKey = opened.vaultKey else {
            throw EncryptedSnippetBackup.Failure.damagedBackup
        }
        if let current = document, current.kid != incomingVault.kid {
            throw EncryptedBackupFailure.incompatibleVault
        }

        let previousKeyID = document?.kid
        var incomingKeyBytes = incomingKey.withUnsafeBytes { Data($0) }
        defer { SecureMemory.wipe(&incomingKeyBytes) }
        session.adopt(keyID: incomingVault.kid)

        if keychain.hasKey(keyID: incomingVault.kid) {
            do {
                return try await session.withOneUseAuthentication(
                    reason: "Import secure snippets from an encrypted backup"
                ) {
                    var currentKeyBytes = try self.session.currentKey().withUnsafeBytes { Data($0) }
                    defer { SecureMemory.wipe(&currentKeyBytes) }
                    guard currentKeyBytes == incomingKeyBytes else {
                        throw EncryptedBackupFailure.vaultKeyMismatch
                    }
                    return try self.mergeEncryptedBackup(opened, into: store)
                }
            } catch {
                // No vault was installed, so do not leave the session addressing a key
                // which has no corresponding local document.
                if self.document == nil { self.session.adopt(keyID: previousKeyID) }
                throw error
            }
        }

        // Restoring a missing key is safe before the files move: an orphaned Keychain
        // item is harmless and recoverable, while deleting it on a failed transaction
        // could propagate through iCloud Keychain if another device published the same
        // `kid` between the check above and this write.
        try keychain.store(incomingKeyBytes, keyID: incomingVault.kid)
        do {
            return try mergeEncryptedBackup(opened, into: store)
        } catch {
            if self.document == nil { self.session.adopt(keyID: previousKeyID) }
            throw error
        }
    }

    // MARK: - Moving between the two files

    /// Makes a plaintext snippet secure: seal it into the vault, remove it from
    /// `snippets.json`.
    ///
    /// Requires an unlocked vault, because sealing needs the key.
    func promote(snippetID: UUID) throws {
        let document = try requireDocument()
        let ring = try keyring(document)

        let outcome = try runTransaction { contents in
            guard let index = contents.snippets.firstIndex(where: { $0.id == snippetID }) else {
                throw Failure.noSuchRecord
            }
            var vault = contents.vault ?? document
            guard vault.record(snippetID) == nil else { throw Failure.alreadySecure }

            let snippet = contents.snippets[index]
            let plaintext = Data(snippet.content.utf8)
            let record = VaultRecord(
                id: snippet.id,
                // Fix the name now, not later. `Snippet.displayName` falls back to the
                // first line of the content, and a secure shell has no content — so an
                // unnamed snippet that was recognisable in the list becomes one of
                // several identical "Untitled Snippet" rows the moment it is encrypted.
                // This is the last instant the text is still available to name it from.
                name: snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? snippet.displayName
                    : snippet.name,
                keyword: snippet.normalizedKeyword,
                tags: snippet.tags,
                isEnabled: snippet.isEnabled,
                isPinned: snippet.isPinned,
                createdAt: snippet.createdAt,
                updatedAt: self.now(),
                hlc: self.clock.send(),
                contentHash: SnippetCrypto.contentHash(of: plaintext, keyring: ring),
                sealed: try SnippetCrypto.seal(
                    plaintext,
                    for: SnippetCrypto.RecordContext(scopeID: vault.kid, recordID: snippet.id),
                    keyring: ring))

            vault.records.append(record)
            contents.vault = vault
            contents.snippets.remove(at: index)
            // The marker only matters if we crash between the two writes; see
            // `LibraryTransaction.CrashMarker`.
            contents.marker = .promoting(snippetID)
        }
        adopt(outcome)
    }

    /// Turns a secure snippet back into a plaintext one.
    func demote(recordID: UUID) throws {
        _ = try requireDocument()

        let outcome = try runTransaction { contents in
            guard var vault = contents.vault,
                  let index = vault.records.firstIndex(where: { $0.id == recordID })
            else { throw Failure.notSecure }

            let record = vault.records[index]
            // Decrypt the same locked snapshot that will be removed. Decrypting the
            // in-memory copy before acquiring this transaction can overwrite a
            // concurrent secure-content edit with stale plaintext.
            let plaintext = try SnippetCrypto.open(
                record.sealed,
                for: self.context(for: recordID, in: vault),
                keyring: try self.keyring(vault))
            guard let content = SnippetCrypto.plaintextString(plaintext) else {
                throw Failure.invalidUTF8
            }

            vault.records.remove(at: index)
            contents.vault = vault
            contents.snippets.insert(
                Snippet(
                    id: record.id, name: record.name, keyword: record.keyword,
                    content: content,
                    tags: record.tags, isEnabled: record.isEnabled, isPinned: record.isPinned,
                    createdAt: record.createdAt, updatedAt: self.now()),
                at: 0)
            contents.marker = .demoting(recordID)
        }
        adopt(outcome)
    }

    /// Removes every secure snippet from this Mac.
    ///
    /// A device-only vault also loses its device-only key and identity. A synchronizable
    /// vault deliberately keeps both: deleting either Keychain item would propagate to
    /// every Mac, turning a local removal into fleet-wide key destruction. This operation
    /// cannot prove another ciphertext copy exists; the confirmation must say so rather
    /// than treating a synchronizable key as evidence that the records finished uploading.
    ///
    /// For a device-only vault the key goes last. If that fails, the exact locked
    /// document is restored so the operation remains retryable.
    func forgetEverything(syncIsQuiescent: Bool) throws {
        guard !isUnreadable else {
            throw Failure.vaultUnreadable("the vault could not be read; refusing to remove it")
        }

        // With sync running, removing the local file would be undone by the next fetch:
        // the bridge would immediately re-adopt the published identity and restore the
        // records. Require the user to stop that loop before making a local-only change.
        guard !SyncCoordinator.isEnabled else {
            throw Failure.forgetRequiresSyncOff
        }
        guard syncIsQuiescent else { throw Failure.forgetWaitForSync }

        // A synchronizable item has no honest "delete only here" operation. Preserve the
        // shared key and identity, regardless of whether the identity lookup currently
        // succeeds; the Keychain tier is the authority on deletion propagation.
        let preserveSharedKey = keychain.tier.syncsBetweenDevices

        let held: FileGuard.Held
        do {
            held = try FileGuard.acquire(at: lockURL, timeout: lockTimeout)
        } catch {
            throw Failure.transaction("another process is writing the vault; try again")
        }
        defer { held.release() }
        guard !held.isUnlocked else {
            // Compare-and-swap retries can protect an ordinary file write without a
            // lock; they cannot make a file deletion and a Keychain deletion atomic
            // with respect to another writer.
            throw Failure.transaction("this filesystem cannot lock the vault; refusing a non-atomic removal")
        }

        let onDisk: VaultDocument?
        switch VaultFile.load(from: vaultURL) {
        case .loaded(let current):
            onDisk = current
        case .missing:
            onDisk = nil
        case .tooNew(let version):
            throw Failure.vaultUnreadable(
                "vault schemaVersion \(version) is newer than this build; refusing to remove it")
        case .unreadable(let error), .corrupt(let error):
            throw Failure.vaultUnreadable("the vault could not be read; refusing to remove it: \(error)")
        }

        let rollbackDocument = onDisk ?? document
        let kid = rollbackDocument?.kid
        do {
            // The directory fsync is load-bearing: the removal must survive a crash
            // before any device-only key is deleted.
            try AtomicFileWriter.removeDurablyIfPresent(vaultURL)
        } catch {
            throw Failure.transaction("could not durably delete the vault: \(error)")
        }

        if let kid, !preserveSharedKey {
            do {
                try keychain.deleteKey(keyID: kid)
            } catch let keychainError {
                // Treat a Keychain refusal as a failed transaction. Restore the exact
                // locked snapshot so the user can retry and the key is not orphaned.
                if let rollbackDocument {
                    do {
                        try VaultFile.write(
                            rollbackDocument, to: vaultURL,
                            temporaryDirectory: temporaryDirectory)
                        document = rollbackDocument
                    } catch let restoreError {
                        throw Failure.transaction(
                            "the keychain kept the vault key (\(keychainError)), but the vault could not be restored: \(restoreError)")
                    }
                }
                let recovery = rollbackDocument == nil ? "no vault file needed restoring" : "the vault was restored"
                throw Failure.transaction(
                    "the keychain kept the vault key; \(recovery): \(keychainError)")
            }
        }

        // The local-tier identity is as stale as its deleted key. The synchronizable
        // identity must remain: deleting it would propagate, and it is what lets this Mac
        // rejoin the same vault later instead of minting a rival one.
        if !preserveSharedKey { identityStore.forget() }

        // The agreed base still lists every secure record this Mac ever synced. Clear it
        // so a later opt-in reconciles from the backend rather than manufacturing local
        // tombstones for the removed vault.
        do {
            try AtomicFileWriter.removeDurablyIfPresent(syncBaseURL)
        } catch {
            // Safe failure: the bridge receives this exact ancestor from the engine and
            // refuses to project a missing vault as deletions.
            NSLog("Snippets: could not clear \(syncBaseURL.lastPathComponent) after forgetting the vault (\(error)).")
        }

        // The projection sidecar is key-independent and carries unknown extension fields
        // for ordinary snippets. Deleting the whole file would strip forward-compatible
        // metadata on the next upload, so remove only entries owned by the deleted vault.
        if case .loaded(var metadata) = SyncBaseFile.load(from: syncMetadataURL) {
            metadata.envelopes = metadata.envelopes.filter { !$0.value.secure }
            metadata.cursor = nil
            do {
                try SyncBaseFile.write(
                    metadata, to: syncMetadataURL, temporaryDirectory: temporaryDirectory)
            } catch {
                // Leaving secure entries is fail-closed: the next bridge projection sees
                // them and halts rather than emitting tombstones.
                NSLog("Snippets: could not prune secure projection metadata after forgetting the vault (\(error)).")
            }
        }

        document = nil
        isUnreadable = false
        session.adopt(keyID: nil)
        onChange?()
    }

    // MARK: - Crash recovery

    /// Finishes a move that a crash interrupted.
    ///
    /// The transaction writes the move's destination before removing its source, so an
    /// interrupted move always leaves the record in **both** files — never in neither.
    /// Which copy is right depends on which direction was in flight, and that is the
    /// only thing the marker is for:
    ///
    /// - A promote was interrupted → the vault copy is the new truth; drop the stale
    ///   plaintext one.
    /// - A demote was interrupted → the *plaintext* copy is the new truth; drop the
    ///   vault one. Without the marker the rule below would silently re-secure it and
    ///   undo what the user asked for.
    ///
    /// With no marker at all — an older build, or a lost state file — the fallback is
    /// "the vault wins", because leaving a secret's plaintext lying in `snippets.json`
    /// is the worse of the two mistakes.
    @discardableResult
    func reconcileInterruptedMove() -> Int {
        guard !isUnreadable else { return 0 }
        let marker = LibraryTransaction.pendingMarker()

        let outcome = try? runTransaction { contents -> Int in
            guard let vault = contents.vault else { return 0 }
            let secureIDs = Set(vault.records.map(\.id))
            let duplicated = contents.snippets.filter { secureIDs.contains($0.id) }
            guard !duplicated.isEmpty else { return 0 }

            var resolved = 0
            for snippet in duplicated {
                if case .demoting(let id) = marker, id == snippet.id {
                    // The plaintext copy is the intended outcome.
                    var updated = vault
                    updated.records.removeAll { $0.id == id }
                    contents.vault = updated
                } else {
                    contents.snippets.removeAll { $0.id == snippet.id }
                }
                resolved += 1
            }
            contents.marker = .none
            return resolved
        }

        if let outcome, outcome.value > 0 {
            NSLog("Snippets: completed \(outcome.value) interrupted secure-snippet move(s) after a crash.")
            adopt(outcome)
        }
        return outcome?.value ?? 0
    }

    private func buildEncryptedBackup(passphrase: String) throws -> EncryptedBackupExport {
        let snapshot = try runTransaction { contents in
            (snippets: contents.snippets, vault: contents.vault)
        }.value
        // A zero-record vault contains no snippet data worth exporting. Omitting it also
        // avoids asking for a key solely to preserve an unused security setup.
        let exportedVault = snapshot.vault?.records.isEmpty == false ? snapshot.vault : nil
        let libraryKey: SymmetricKey?
        if let exportedVault {
            guard document?.kid == exportedVault.kid else {
                throw Failure.transaction("the vault changed while the backup was being prepared; try again")
            }
            libraryKey = try session.currentKey()
        } else {
            libraryKey = nil
        }

        let data = try EncryptedSnippetBackup.seal(
            snippets: snapshot.snippets,
            vault: exportedVault,
            vaultKey: libraryKey,
            passphrase: passphrase)
        return EncryptedBackupExport(
            data: data,
            ordinaryCount: snapshot.snippets.count,
            secureCount: exportedVault?.records.count ?? 0)
    }

    private func mergeEncryptedBackup(
        _ opened: EncryptedSnippetBackup.Opened,
        into store: SnippetStore
    ) throws -> EncryptedBackupImportResult {
        let incomingPlain = opened.snippets.map(Self.normalizedBackupSnippet)
        let incomingVault = opened.vault
        let importDate = now()
        let importWallMs = UInt64(max(0, importDate.timeIntervalSince1970 * 1_000))
        let importedClocks: [UUID: HLC] = Dictionary(uniqueKeysWithValues:
            (incomingVault?.records ?? []).map { record in
                (record.id, clock.send(atLeast: max(record.hlc.wallMs, importWallMs)))
            })

        let outcome = try runTransaction { contents in
            var conflicts: [String] = []
            let existingPlain = contents.snippets
            let existingSecure = contents.vault?.records ?? []

            if let incomingVault, let existingVault = contents.vault {
                guard existingVault.schemaVersion == incomingVault.schemaVersion,
                      existingVault.kid == incomingVault.kid,
                      existingVault.vaultSalt == incomingVault.vaultSalt else {
                    throw EncryptedBackupFailure.incompatibleVault
                }
            }

            for incoming in incomingPlain {
                if let secure = existingSecure.first(where: { $0.id == incoming.id }) {
                    conflicts.append(
                        "\(incoming.displayName) has the same ID as secure snippet \(Self.displayName(secure)).")
                    continue
                }
                let keywordKey = Self.keywordKey(incoming.keyword)
                if !keywordKey.isEmpty,
                   let secure = existingSecure.first(where: { Self.keywordKey($0.keyword) == keywordKey }) {
                    conflicts.append(
                        "Keyword \\\(incoming.normalizedKeyword) belongs to secure snippet \(Self.displayName(secure)).")
                    continue
                }

                if let idMatch = existingPlain.first(where: { $0.id == incoming.id }),
                   !keywordKey.isEmpty,
                   let keywordMatch = existingPlain.first(where: {
                       $0.id != incoming.id && Self.keywordKey($0.keyword) == keywordKey
                   }) {
                    conflicts.append(
                        "\(incoming.displayName) matches existing ID \(idMatch.displayName), but keyword "
                        + "\\\(incoming.normalizedKeyword) belongs to \(keywordMatch.displayName).")
                }
            }

            for incoming in incomingVault?.records ?? [] {
                if let ordinary = existingPlain.first(where: { $0.id == incoming.id }) {
                    conflicts.append(
                        "\(Self.displayName(incoming)) has the same ID as ordinary snippet \(ordinary.displayName).")
                    continue
                }
                let keywordKey = Self.keywordKey(incoming.keyword)
                if !keywordKey.isEmpty,
                   let ordinary = existingPlain.first(where: { Self.keywordKey($0.keyword) == keywordKey }) {
                    conflicts.append(
                        "Keyword \\\(Snippet.sanitizedKeyword(incoming.keyword)) belongs to ordinary snippet \(ordinary.displayName).")
                    continue
                }

                if !keywordKey.isEmpty,
                   let keywordMatch = existingSecure.first(where: {
                       $0.id != incoming.id && Self.keywordKey($0.keyword) == keywordKey
                   }) {
                    conflicts.append(
                        "Secure snippet \(Self.displayName(incoming)) uses keyword "
                        + "\\\(Snippet.sanitizedKeyword(incoming.keyword)), which belongs to "
                        + "\(Self.displayName(keywordMatch)).")
                }
            }

            guard conflicts.isEmpty else {
                throw EncryptedBackupFailure.conflicts(Array(conflicts.prefix(8)))
            }

            var mergedPlain = contents.snippets
            for snippet in incomingPlain {
                Self.upsertBackupSnippet(snippet, into: &mergedPlain)
            }
            contents.snippets = mergedPlain

            if let incomingVault {
                if contents.vault == nil {
                    contents.vault = incomingVault
                } else if var mergedVault = contents.vault {
                    // Keep this device's local doors. The recovery wrap is portable and
                    // safe to fill when absent; CLI/passphrase wraps belong to the device
                    // that created them and must not hitch a ride through a backup import.
                    if mergedVault.wrapRecovery == nil {
                        mergedVault.wrapRecovery = incomingVault.wrapRecovery
                    }
                    for (key, value) in incomingVault.x where mergedVault.x[key] == nil {
                        mergedVault.x[key] = value
                    }

                    for incoming in incomingVault.records {
                        if let index = mergedVault.records.firstIndex(where: { $0.id == incoming.id }) {
                            guard !Self.sameBackupRecord(mergedVault.records[index], incoming) else { continue }
                            var replacement = incoming
                            replacement.updatedAt = max(importDate, incoming.updatedAt)
                            replacement.hlc = importedClocks[incoming.id] ?? incoming.hlc
                            mergedVault.records[index] = replacement
                        } else {
                            var inserted = incoming
                            inserted.updatedAt = max(importDate, incoming.updatedAt)
                            inserted.hlc = importedClocks[incoming.id] ?? incoming.hlc
                            mergedVault.records.append(inserted)
                        }
                    }
                    contents.vault = mergedVault
                }
            }

            return EncryptedBackupImportResult(
                ordinaryCount: incomingPlain.count,
                secureCount: incomingVault?.records.count ?? 0)
        }

        // The transaction wrote underneath both in-memory stores. Adopt the exact disk
        // result immediately; waiting for folder notifications risks a stale editor write
        // landing on top of the import.
        store.reloadAfterExternalWrite()
        reload()
        return outcome.value
    }

    private static func normalizedBackupSnippet(_ item: Snippet) -> Snippet {
        var snippet = item
        snippet.keyword = snippet.normalizedKeyword
        snippet.tags = SnippetTagging.normalizedTags(snippet.tags)
        if snippet.updatedAt < snippet.createdAt { snippet.updatedAt = snippet.createdAt }
        return snippet
    }

    private static func upsertBackupSnippet(_ incoming: Snippet, into merged: inout [Snippet]) {
        if let index = merged.firstIndex(where: { $0.id == incoming.id }) {
            merged[index] = incoming
            return
        }
        let keyword = keywordKey(incoming.keyword)
        if !keyword.isEmpty,
           let index = merged.firstIndex(where: { keywordKey($0.keyword) == keyword }) {
            var replacement = incoming
            replacement.id = merged[index].id
            replacement.createdAt = merged[index].createdAt
            merged[index] = replacement
            return
        }
        merged.insert(incoming, at: 0)
    }

    private static func keywordKey(_ keyword: String) -> String {
        SnippetTagging.filterKey(for: Snippet.sanitizedKeyword(keyword))
    }

    private static func displayName(_ record: VaultRecord) -> String {
        let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Snippet" : name
    }

    /// Ignore only merge clocks: the first import stamps those locally. Exact backup
    /// ciphertext must match too, so importing a known-good backup can repair a live
    /// record whose `sealed` field was damaged even when its stored hash survived.
    private static func sameBackupRecord(_ lhs: VaultRecord, _ rhs: VaultRecord) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.keyword == rhs.keyword
            && lhs.tags == rhs.tags
            && lhs.isEnabled == rhs.isEnabled
            && lhs.isPinned == rhs.isPinned
            && lhs.createdAt == rhs.createdAt
            && lhs.contentHash == rhs.contentHash
            && lhs.sealed == rhs.sealed
            && lhs.x == rhs.x
    }

    // MARK: - Plumbing

    private func requireDocument() throws -> VaultDocument {
        guard !isUnreadable else { throw Failure.vaultUnreadable("the vault could not be read") }
        guard let document else { throw Failure.noSuchRecord }
        return document
    }

    private func keyring(_ document: VaultDocument) throws -> SnippetCrypto.Keyring {
        guard let salt = document.vaultSaltBytes else {
            throw Failure.vaultUnreadable("the vault's salt could not be decoded")
        }
        return try session.keyring(vaultSalt: salt)
    }

    /// The crypto scope is the vault's own `kid` — **never** `SyncState.scopeID`, which
    /// is regenerated whenever that file cannot be read and would make every record
    /// permanently unopenable. See `SnippetCrypto.RecordContext.scopeID`.
    private func context(for id: UUID, in document: VaultDocument) -> SnippetCrypto.RecordContext {
        SnippetCrypto.RecordContext(scopeID: document.kid, recordID: id)
    }

    /// A vault-only change. Still takes the shared lock, because a concurrent promote
    /// touches this file too.
    private func mutateVault(_ change: (inout VaultDocument) throws -> Void) throws {
        guard !isUnreadable else { throw Failure.vaultUnreadable("the vault could not be read") }
        do {
            let updated = try VaultFile.update(
                at: vaultURL, lockURL: lockURL,
                temporaryDirectory: temporaryDirectory, lockTimeout: lockTimeout
            ) { current in
                guard var vault = current else { throw Failure.noSuchRecord }
                try change(&vault)
                return vault
            }
            // Only announce a real change. `VaultFile.update` already skips the write
            // when the encoded document is byte-identical, but firing onChange anyway
            // published a `.external` library change — which reloads the editor and
            // sends the caret to the end of the line. On the content path that happens
            // on every single keystroke.
            let changed = updated != document
            document = updated
            if changed { onChange?() }
        } catch let failure as Failure {
            throw failure
        } catch let failure as EncryptedBackupFailure {
            throw failure
        } catch {
            throw Failure.transaction("\(error)")
        }
    }

    private func runTransaction<T>(
        _ body: @escaping (inout LibraryTransaction.Contents) throws -> T
    ) throws -> LibraryTransaction.Outcome<T> {
        do {
            return try LibraryTransaction.perform(
                libraryURL: libraryURL, vaultURL: vaultURL, lockURL: lockURL,
                temporaryDirectory: temporaryDirectory,
                lockTimeout: lockTimeout, body: body)
        } catch let failure as Failure {
            throw failure
        } catch let failure as EncryptedBackupFailure {
            throw failure
        } catch {
            throw Failure.transaction("\(error)")
        }
    }

    private func adopt<T>(_ outcome: LibraryTransaction.Outcome<T>) {
        document = outcome.vault
        onChange?()
    }
}
