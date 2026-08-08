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
/// `LibraryTransaction` — one lock over both, vault written first, with a marker
/// describing what is in flight. See `reconcileInterruptedMove`.
@MainActor
final class SecureSnippetStore {

    enum Failure: Error, CustomStringConvertible {
        case vaultUnreadable(String)
        case noSuchRecord
        case notSecure
        case alreadySecure
        case transaction(String)

        var description: String {
            switch self {
            case .vaultUnreadable(let detail): return detail
            case .noSuchRecord: return "no such snippet"
            case .notSecure: return "that snippet is not secure"
            case .alreadySecure: return "that snippet is already secure"
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
    private let vaultURL: URL
    private let libraryURL: URL
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
        lockTimeout: TimeInterval = 2.0
    ) {
        self.session = session
        self.keychain = keychain ?? KeychainSecretStore()
        self.vaultURL = vaultURL
        self.libraryURL = libraryURL
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
        case .missing:
            document = nil
            isUnreadable = false
            session.adopt(keyID: nil)
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

    func isSecure(_ id: UUID) -> Bool { document?.record(id) != nil }

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

    /// Creates a vault and its library key, storing the key in the keychain.
    ///
    /// Idempotent: an existing vault is returned untouched, so this is safe to call
    /// from a "make this snippet secure" flow without a separate setup step.
    @discardableResult
    func createVaultIfNeeded(requireBiometry: Bool = true) throws -> VaultDocument {
        if let document { return document }
        guard !isUnreadable else {
            throw Failure.vaultUnreadable("refusing to create a vault over an unreadable one")
        }

        let keyring = SnippetCrypto.Keyring.generate()
        let kid = "k-\(UUID().uuidString.lowercased().prefix(12))"

        // The key goes in the keychain BEFORE the document exists on disk. The other
        // order can leave a vault whose key was never stored — a file full of records
        // nothing can ever open.
        try keychain.store(
            keyring.libraryKey.withUnsafeBytes { Data($0) },
            keyID: kid, requireBiometry: requireBiometry)

        let created = VaultDocument(
            kid: kid,
            vaultSalt: SnippetCrypto.base64URL(keyring.salt),
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))))

        try VaultFile.write(created, to: vaultURL)
        document = created
        session.adopt(keyID: kid)
        onChange?()
        return created
    }

    // MARK: - Content, requires an unlocked vault

    func content(for id: UUID) throws -> String {
        let document = try requireDocument()
        guard let record = document.record(id) else { throw Failure.noSuchRecord }
        let plaintext = try SnippetCrypto.open(
            record.sealed, for: context(for: id, in: document), keyring: try keyring(document))
        // Converted to `String` only here, at the last possible moment. Everything
        // upstream is `Data`, because a `String` is copied by value and cannot be
        // scrubbed.
        return String(decoding: plaintext, as: UTF8.self)
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
                name: snippet.name,
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
        let document = try requireDocument()
        let ring = try keyring(document)
        let plaintext = try SnippetCrypto.open(
            try requireRecord(recordID, in: document).sealed,
            for: context(for: recordID, in: document), keyring: ring)

        let outcome = try runTransaction { contents in
            guard var vault = contents.vault,
                  let index = vault.records.firstIndex(where: { $0.id == recordID })
            else { throw Failure.notSecure }

            let record = vault.records[index]
            vault.records.remove(at: index)
            contents.vault = vault
            contents.snippets.insert(
                Snippet(
                    id: record.id, name: record.name, keyword: record.keyword,
                    content: String(decoding: plaintext, as: UTF8.self),
                    tags: record.tags, isEnabled: record.isEnabled, isPinned: record.isPinned,
                    createdAt: record.createdAt, updatedAt: self.now()),
                at: 0)
            contents.marker = .demoting(recordID)
        }
        adopt(outcome)
    }

    // MARK: - Crash recovery

    /// Finishes a move that a crash interrupted.
    ///
    /// The transaction writes the vault first, so an interrupted move always leaves the
    /// record in **both** files — never in neither. Which copy is right depends on which
    /// direction was in flight, and that is the only thing the marker is for:
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

    private func requireRecord(_ id: UUID, in document: VaultDocument) throws -> VaultRecord {
        guard let record = document.record(id) else { throw Failure.noSuchRecord }
        return record
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
                at: vaultURL, lockTimeout: lockTimeout
            ) { current in
                guard var vault = current else { throw Failure.noSuchRecord }
                try change(&vault)
                return vault
            }
            document = updated
            onChange?()
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
                libraryURL: libraryURL, vaultURL: vaultURL, lockTimeout: lockTimeout, body: body)
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
