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
            }
        }
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
        if let document { return document }
        guard !isUnreadable else {
            throw Failure.vaultUnreadable("refusing to create a vault over an unreadable one")
        }
        if let adopted = adoptSharedVaultIfAvailable(requireSyncEnabled: false) {
            onChange?()
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

    /// Deletes every secure snippet **and** the key that opens them.
    ///
    /// Both halves, deliberately. Removing the file but leaving the key would strand an
    /// unusable keychain item and a Touch ID prompt the user can no longer explain;
    /// removing the key but leaving the file would leave records that look present and
    /// can never be opened, which is the worst of the three states.
    ///
    /// The key goes last: if that fails, the records are already gone and the leftover
    /// key opens nothing. The other order can leave readable ciphertext with no way to
    /// tell the user their "deletion" only half happened.
    func forgetEverything() throws {
        guard !isUnreadable else {
            throw Failure.vaultUnreadable("the vault could not be read; refusing to discard its key")
        }

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
            throw Failure.transaction("this filesystem cannot lock the vault; refusing to delete its only key")
        }

        let onDisk: VaultDocument?
        switch VaultFile.load(from: vaultURL) {
        case .loaded(let current):
            onDisk = current
        case .missing:
            onDisk = nil
        case .tooNew(let version):
            throw Failure.vaultUnreadable(
                "vault schemaVersion \(version) is newer than this build; refusing to discard its key")
        case .unreadable(let error), .corrupt(let error):
            throw Failure.vaultUnreadable("the vault could not be read; refusing to discard its key: \(error)")
        }

        let rollbackDocument = onDisk ?? document
        let kid = rollbackDocument?.kid
        do {
            // The directory fsync is load-bearing: the missing vault entry must be
            // durable before deleting the only key that could open it.
            try AtomicFileWriter.removeDurablyIfPresent(vaultURL)
        } catch {
            throw Failure.transaction("could not durably delete the vault: \(error)")
        }

        if let kid {
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

        // Last, and only once the file and the key are actually gone. Leaving the
        // identity published would have `reload` immediately re-adopt the vault that was
        // just deleted, as a records-free document whose key no longer exists — the app
        // would report "secure snippets are set up here, but their key is missing" to
        // someone who had asked for exactly the opposite.
        //
        // This clears the slot on the user's other Macs too. That is the honest reading
        // of "delete the key that opens them", and it strands nothing: a Mac that still
        // holds a real vault republishes on its next reload.
        identityStore.forget()

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
        } catch {
            throw Failure.transaction("\(error)")
        }
    }

    private func adopt<T>(_ outcome: LibraryTransaction.Outcome<T>) {
        document = outcome.vault
        onChange?()
    }
}
