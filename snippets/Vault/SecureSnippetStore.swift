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
        case setupChanged
        case invalidSetupTicket
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
            case .setupChanged:
                return "the vault changed while its recovery key was being shown; try again"
            case .invalidSetupTicket: return "that secure-snippet setup has already finished"
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
        case libraryRecoveryRequired
        case conflicts([String])

        var errorDescription: String? {
            switch self {
            case .incompatibleVault:
                return "This backup belongs to a different secure-snippet vault. "
                    + "Import it into a fresh Snippets library or a device already using the same vault."
            case .vaultKeyMismatch:
                return "The backup and this device have different keys for the same secure-snippet vault. Nothing was imported."
            case .libraryRecoveryRequired:
                return "A new all-library backup cannot be created while the ordinary "
                    + "snippet library is unreadable. You can still restore an existing "
                    + "encrypted backup, or use a complete Snippets JSON export."
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

    struct PreparedEncryptedBackupImport {
        fileprivate var opened: EncryptedSnippetBackup.Opened
        var ordinaryCount: Int { opened.ordinaryCount }
        var secureCount: Int { opened.secureCount }
        var totalCount: Int { opened.totalCount }
    }

    struct EncryptedBackupImportResult {
        var ordinaryCount: Int
        var secureCount: Int
        var totalCount: Int { ordinaryCount + secureCount }
    }

    /// Immutable point-in-time input for the expensive backup KDF. The constituent
    /// models are value types and this instance is never touched again on MainActor
    /// after being transferred to the detached worker.
    nonisolated private struct EncryptedBackupSnapshot: @unchecked Sendable {
        let snippets: [Snippet]
        let vault: VaultDocument?
        let vaultKey: SymmetricKey?
    }

    /// A first-vault recovery key that has been generated and shown, but has not yet
    /// changed either the Keychain or the filesystem. The UI commits this ticket only
    /// from an explicit acknowledgement action; dismissing it leaves no half-created
    /// vault behind.
    final class PendingVaultCreation {
        private(set) var recoveryKeyText: String
        fileprivate var recoveryKey: Data?

        fileprivate init(recoveryKey: Data, recoveryKeyText: String) {
            self.recoveryKey = recoveryKey
            self.recoveryKeyText = recoveryKeyText
        }

        func cancel() {
            if var bytes = recoveryKey {
                // Drop the stored reference first so `bytes` owns the Data buffer and
                // wiping it does not trigger copy-on-write on a disposable copy.
                recoveryKey = nil
                SecureMemory.wipe(&bytes)
            }
            recoveryKey = nil
            recoveryKeyText = ""
        }

        fileprivate func markCommitted() {
            // The caller owns and wipes the consumed bytes in a `defer`.
            recoveryKey = nil
            recoveryKeyText = ""
        }

        deinit {
            if var bytes = recoveryKey {
                recoveryKey = nil
                SecureMemory.wipe(&bytes)
            }
        }
    }

    /// An authenticated recovery wrap waiting for the user to confirm that the
    /// printable key was saved. It contains ciphertext, not `K_lib`; the one-use vault
    /// authentication that created it may therefore close before the alert is shown.
    final class PendingRecoveryKeyAddition {
        private(set) var recoveryKeyText: String
        fileprivate let kid: String
        fileprivate let vaultSalt: String
        fileprivate let envelope: String
        fileprivate var isActive = true

        fileprivate init(
            recoveryKeyText: String,
            kid: String,
            vaultSalt: String,
            envelope: String
        ) {
            self.recoveryKeyText = recoveryKeyText
            self.kid = kid
            self.vaultSalt = vaultSalt
            self.envelope = envelope
        }

        func cancel() {
            isActive = false
            recoveryKeyText = ""
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
    private var syncBaseURL: URL
    private var syncJournalURL: URL
    private let syncMetadataURL: URL
    private let lockTimeout: TimeInterval
    /// Injected durability operations let transaction tests fail after a rename/unlink
    /// became visible. Production defaults are the real atomic writers.
    private let syncBaseWriter: (SyncBase, URL, URL) throws -> Void
    private let syncJournalWriter: (SyncJournal, URL, URL) throws -> Void
    private let syncMetadataWriter: (SyncBase, URL, URL) throws -> Void
    private let durableFileRemover: (URL) throws -> Void
    private let vaultKeyRemover: (String) throws -> Void

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
        syncJournalURL: URL = SnippetStorageLocations.syncJournalFileURL,
        syncMetadataURL: URL = SnippetStorageLocations.syncLibraryMetadataFileURL,
        lockTimeout: TimeInterval = 2.0,
        syncBaseWriter: @escaping (SyncBase, URL, URL) throws -> Void = {
            try SyncBaseFile.write($0, to: $1, temporaryDirectory: $2)
        },
        syncJournalWriter: @escaping (SyncJournal, URL, URL) throws -> Void = {
            try SyncJournalFile.write($0, to: $1, temporaryDirectory: $2)
        },
        syncMetadataWriter: @escaping (SyncBase, URL, URL) throws -> Void = {
            try SyncBaseFile.write($0, to: $1, temporaryDirectory: $2)
        },
        durableFileRemover: @escaping (URL) throws -> Void = {
            try AtomicFileWriter.removeDurablyIfPresent($0)
        },
        vaultKeyRemover: ((String) throws -> Void)? = nil
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
        self.syncJournalURL = syncJournalURL
        self.syncMetadataURL = syncMetadataURL
        self.lockTimeout = lockTimeout
        self.syncBaseWriter = syncBaseWriter
        self.syncJournalWriter = syncJournalWriter
        self.syncMetadataWriter = syncMetadataWriter
        self.durableFileRemover = durableFileRemover
        self.vaultKeyRemover = vaultKeyRemover ?? {
            try resolvedKeychain.deleteKey(keyID: $0)
        }
        self.clock = HLCGenerator(device: deviceID)
        reload()
    }

    /// Secure promote/demote and local vault removal participate in the active
    /// provider's durable journal. The projection metadata remains provider-neutral.
    func activateProtocolLocations(_ locations: SyncProtocolLocations) {
        syncBaseURL = locations.baseURL
        syncJournalURL = locations.journalURL
    }

    // MARK: - Loading

    func reload(notifyChange: Bool = true) {
        switch VaultFile.load(from: vaultURL) {
        case .loaded(let loaded):
            document = loaded
            isUnreadable = false
            session.adopt(keyID: loaded.kid)
            // Opportunistic, and cheap after the first call. It upgrades a vault created
            // before identity sharing existed, and heals a slot another Mac cleared,
            // without either needing a migration step of its own.
            identityStore.publish(loaded)
            healLegacyPlainSyncMetadata(for: loaded)
            Diagnostics.record(.vaultAction(.loaded, count: loaded.records.count))
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
            Diagnostics.record(.storageState(
                area: .vault,
                state: .versionTooNew,
                value: version))
            Diagnostics.record(.vaultAction(.readOnly, count: nil))
        case .unreadable(let error), .corrupt(let error):
            document = nil
            isUnreadable = true
            session.adopt(keyID: nil)
            Diagnostics.record(.storageFailure(
                area: .vault,
                operation: .read,
                failure: DiagnosticFailure(error),
                attempt: nil))
        }
        if notifyChange { onChange?() }
    }

    /// Old promotion builds could leave a plaintext projection envelope beside a now-
    /// secure primary record. This repair runs at vault startup even while sync is off,
    /// preserves safe opaque extensions, and never rewrites unknown/newer sidecar bytes.
    private func healLegacyPlainSyncMetadata(for vault: VaultDocument) {
        guard !vault.records.isEmpty else { return }
        switch SyncBaseFile.load(from: syncMetadataURL) {
        case .loaded(var metadata):
            let affected = vault.records.filter { record in
                guard let envelope = metadata.envelope(record.id) else { return false }
                return !envelope.secure && !envelope.deleted
            }
            guard !affected.isEmpty else { return }
            // Do not let the projection inspect protocol-owned `x` from a plaintext
            // shadow. Some legacy opaque-carrier spellings are intentionally decoded
            // into current conflict keys by the projection, so filtering only after it
            // returns would be too late.
            var sanitizedInput = metadata
            for record in affected {
                guard var stale = sanitizedInput.envelope(record.id) else { continue }
                stale.x = stale.x.filter { key, _ in
                    !SyncMerge.isContentConflictExtension(key)
                        && !key.hasPrefix(SyncMerge.contentConflictOpaqueCarrierPrefix)
                        && key != SyncMerge.plainConflictCopyExtensionKey
                        && key != SyncEnvelope.vaultKeyIDExtensionKey
                        && key != SyncEnvelope.vaultContentHashExtensionKey
                }
                sanitizedInput.record(stale)
            }
            let projected = SyncLibraryProjection.currentEnvelopes(
                snippets: [],
                records: affected,
                deviceID: clock.device,
                metadata: sanitizedInput,
                agreedBase: SyncBase(),
                vaultKID: vault.kid)
            for record in affected {
                guard var secure = projected[record.id],
                      let stale = metadata.envelope(record.id) else { continue }
                // The stale value described a plaintext representation. Preserve only
                // genuinely opaque application metadata from it: protocol-owned secure
                // fields and conflict carriers must come exclusively from vault.json.
                // Otherwise a long-resolved/forged plaintext sidecar can become causal
                // evidence for a secure record merely because this repair copied `x`.
                for (key, value) in stale.x where
                    secure.x[key] == nil
                        && !SyncMerge.isContentConflictExtension(key)
                        && !key.hasPrefix(SyncMerge.contentConflictOpaqueCarrierPrefix)
                        && key != SyncMerge.plainConflictCopyExtensionKey
                        && key != SyncEnvelope.vaultKeyIDExtensionKey
                        && key != SyncEnvelope.vaultContentHashExtensionKey {
                    secure.x[key] = value
                }
                metadata.record(secure)
            }
            do {
                try syncMetadataWriter(metadata, syncMetadataURL, temporaryDirectory)
            } catch {
                Diagnostics.record(.storageFailure(
                    area: .syncMetadata,
                    operation: .write,
                    failure: DiagnosticFailure(error),
                    attempt: nil))
                // This is derived state and the known-schema input contains plaintext
                // for records whose primary representation is secure. If an atomic
                // sanitized rewrite cannot commit, removing the derived file is the
                // only fail-safe outcome; the next projection rebuilds it from vault,
                // base, and journal knowledge without retaining the plaintext leak.
                do {
                    try durableFileRemover(syncMetadataURL)
                } catch {
                    Diagnostics.record(.storageFailure(
                        area: .syncMetadata,
                        operation: .remove,
                        failure: DiagnosticFailure(error),
                        attempt: nil))
                }
            }
        case .missing, .tooNew, .unreadable:
            // Missing has no leak. Unknown bytes are intentionally fail-closed and
            // byte-identical; a newer build remains their only authorized writer.
            return
        }
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
            Diagnostics.record(.storageFailure(
                area: .vault,
                operation: .adopt,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return nil
        }

        document = adopted
        session.adopt(keyID: adopted.kid)
        Diagnostics.record(.vaultAction(.adoptedSharedIdentity, count: nil))
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
        guard let pending = try prepareVaultCreationIfNeeded() else {
            return try requireDocument()
        }
        guard confirmRecoveryKey(pending.recoveryKeyText) else {
            pending.cancel()
            throw Failure.setupCancelled
        }
        return try commitVaultCreation(pending)
    }

    /// Starts first-vault setup without storing a key, wrap, or vault document.
    /// `nil` means an existing/adopted vault is already ready for promotion.
    func prepareVaultCreationIfNeeded() throws -> PendingVaultCreation? {
        if let existing = try existingVaultForCreation() {
            try requireUsableKey(for: existing)
            return nil
        }

        let recoveryKey = RecoveryKey.generate()
        return PendingVaultCreation(
            recoveryKey: recoveryKey,
            recoveryKeyText: try RecoveryKey.formatted(recoveryKey))
    }

    /// Completes a prepared setup after the UI explicitly acknowledges the displayed
    /// recovery key. If a shared identity appeared meanwhile, that vault wins.
    @discardableResult
    func commitVaultCreation(_ pending: PendingVaultCreation) throws -> VaultDocument {
        guard var recoveryKey = pending.recoveryKey else { throw Failure.invalidSetupTicket }
        defer { SecureMemory.wipe(&recoveryKey) }
        if let existing = try existingVaultForCreation() {
            try requireUsableKey(for: existing)
            pending.cancel()
            // The displayed recovery key was generated for a different, not-yet-created
            // vault. Silently adopting `existing` would tell the user that unrelated key
            // can recover it. Abort and let a retry use the real existing vault instead.
            throw Failure.setupChanged
        }

        let created = try createVault(recoveryKey: recoveryKey)
        pending.markCommitted()
        return created
    }

    private func existingVaultForCreation() throws -> VaultDocument? {
        if let document { return document }
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
        return nil
    }

    private func createVault(recoveryKey: Data) throws -> VaultDocument {
        let keyring = SnippetCrypto.Keyring.generate()
        let kid = "k-\(UUID().uuidString.lowercased().prefix(12))"
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
        guard let pending = try prepareRecoveryKeyAddition() else { return false }
        guard confirmRecoveryKey(pending.recoveryKeyText) else {
            pending.cancel()
            throw Failure.setupCancelled
        }
        return try commitRecoveryKeyAddition(pending)
    }

    /// Builds an authenticated recovery wrap while the vault is freshly authorised,
    /// but does not persist it. This may run inside `withOneUseAuthentication`; only
    /// ciphertext and the printable recovery key remain while the alert is visible.
    func prepareRecoveryKeyAddition() throws -> PendingRecoveryKeyAddition? {
        guard let document else { throw Failure.noSuchRecord }
        guard document.wrapRecovery == nil else { return nil }
        guard let salt = document.vaultSaltBytes else {
            throw Failure.vaultUnreadable("the vault's salt could not be decoded")
        }
        let libraryKey = try session.currentKey()

        var recoveryKey = RecoveryKey.generate()
        defer { SecureMemory.wipe(&recoveryKey) }
        let recoveryText = try RecoveryKey.formatted(recoveryKey)
        let envelope = try KeyWrap.wrap(
            libraryKey, under: recoveryKey, purpose: .recovery,
            kid: document.kid, salt: salt)

        return PendingRecoveryKeyAddition(
            recoveryKeyText: recoveryText,
            kid: document.kid,
            vaultSalt: document.vaultSalt,
            envelope: envelope)
    }

    /// Persists an already-authenticated recovery wrap only after the key has been
    /// displayed and explicitly acknowledged.
    @discardableResult
    func commitRecoveryKeyAddition(_ pending: PendingRecoveryKeyAddition) throws -> Bool {
        guard pending.isActive else { throw Failure.invalidSetupTicket }
        guard let document else { throw Failure.noSuchRecord }
        guard document.kid == pending.kid, document.vaultSalt == pending.vaultSalt else {
            throw Failure.invalidSetupTicket
        }
        if document.wrapRecovery != nil {
            pending.cancel()
            return false
        }

        try mutateVault { vault in
            guard vault.kid == pending.kid, vault.vaultSalt == pending.vaultSalt else {
                throw Failure.invalidSetupTicket
            }
            if vault.wrapRecovery == nil { vault.wrapRecovery = pending.envelope }
        }
        // The recovery wrap is part of the identity, and it is the escape hatch a second
        // Mac needs when iCloud Keychain did not carry the key. Republish so that Mac can
        // use it without this one being present. `self.document`, not the local capture
        // above — that one predates the wrap this just added.
        if let updated = self.document { identityStore.publish(updated) }
        pending.cancel()
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
        passphrase: String,
        iterations: Int = PassphraseKDF.iterations
    ) async throws -> EncryptedBackupExport {
        guard !store.isLibraryQuarantined else {
            throw EncryptedBackupFailure.libraryRecoveryRequired
        }
        store.flushPendingWrites()
        reload(notifyChange: false)

        let snapshot: EncryptedBackupSnapshot
        if document?.records.isEmpty == false {
            snapshot = try await session.withOneUseAuthentication(
                reason: "Export an encrypted backup including secure snippets"
            ) {
                try self.prepareEncryptedBackupSnapshot()
            }
        } else {
            snapshot = try prepareEncryptedBackupSnapshot()
        }

        // PBKDF2 is intentionally expensive (600k iterations in production). Keep it
        // off MainActor after taking an immutable, transaction-locked snapshot.
        let data = try await Task.detached(priority: .userInitiated) {
            try EncryptedSnippetBackup.seal(
                snippets: snapshot.snippets,
                vault: snapshot.vault,
                vaultKey: snapshot.vaultKey,
                passphrase: passphrase,
                iterations: iterations)
        }.value
        return EncryptedBackupExport(
            data: data,
            ordinaryCount: snapshot.snippets.count,
            secureCount: snapshot.vault?.records.count ?? 0)
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
        let prepared = try await prepareEncryptedBackupImport(
            data, passphrase: passphrase)
        return try await importPreparedEncryptedBackup(prepared, into: store)
    }

    /// Authenticates and validates a backup without changing either primary file. The
    /// UI uses the returned exact counts for an action-specific quarantine confirmation.
    func prepareEncryptedBackupImport(
        _ data: Data,
        passphrase: String
    ) async throws -> PreparedEncryptedBackupImport {
        let opened = try await Task.detached(priority: .userInitiated) {
            try EncryptedSnippetBackup.open(data, passphrase: passphrase)
        }.value
        return PreparedEncryptedBackupImport(opened: opened)
    }

    /// Applies a previously authenticated backup. During ordinary-library quarantine,
    /// only the explicit authoritative path is legal: its ordinary half is a complete
    /// replacement, its vault half follows the existing key/vault compatibility rules,
    /// and the independent quarantine marker remains until Sync → Check Again commits
    /// the non-destructive cloud merge fence.
    func importPreparedEncryptedBackup(
        _ prepared: PreparedEncryptedBackupImport,
        into store: SnippetStore,
        authoritativeRecovery: Bool = false
    ) async throws -> EncryptedBackupImportResult {
        guard !store.isLibraryQuarantined || authoritativeRecovery else {
            throw EncryptedBackupFailure.libraryRecoveryRequired
        }
        guard store.isLibraryQuarantined || !authoritativeRecovery else {
            throw EncryptedBackupFailure.libraryRecoveryRequired
        }
        let opened = prepared.opened
        store.flushPendingWrites()
        reload()

        guard let incomingVault = opened.vault else {
            return try mergeEncryptedBackup(
                opened, into: store,
                authoritativeOrdinaryRecovery: authoritativeRecovery)
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
                    return try self.mergeEncryptedBackup(
                        opened, into: store,
                        authoritativeOrdinaryRecovery: authoritativeRecovery)
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
            return try mergeEncryptedBackup(
                opened, into: store,
                authoritativeOrdinaryRecovery: authoritativeRecovery)
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
    func promote(snippetID: UUID, notifyChange: Bool = true) throws {
        let document = try requireDocument()

        let outcome = try runTransaction { contents in
            guard let index = contents.snippets.firstIndex(where: { $0.id == snippetID }) else {
                throw Failure.noSuchRecord
            }
            var vault = contents.vault ?? document
            guard vault.kid == document.kid,
                  vault.vaultSalt == document.vaultSalt else {
                // `VaultSession` owns the key adopted for `document`. Sealing into a
                // concurrently replaced vault with that old key but the new kid would
                // create ciphertext that no device can open.
                throw Failure.setupChanged
            }
            guard vault.record(snippetID) == nil else { throw Failure.alreadySecure }
            let ring = try self.keyring(vault)

            let snippet = contents.snippets[index]
            let plaintext = Data(snippet.content.utf8)
            let timestamp = self.now()
            let sealed = try SnippetCrypto.seal(
                plaintext,
                for: SnippetCrypto.RecordContext(scopeID: vault.kid, recordID: snippet.id),
                keyring: ring)
            let contentHash = SnippetCrypto.contentHash(of: plaintext, keyring: ring)
            let source = try self.transitionEnvelope(
                snippets: contents.snippets,
                records: vault.records,
                vaultKID: vault.kid,
                id: snippet.id)
            let hlc = self.clock.stamp(
                updatedAt: timestamp,
                baseHLC: source.hlc)
            var extensions = source.x
            extensions[SyncEnvelope.vaultContentHashExtensionKey] = .string(contentHash)
            extensions[SyncEnvelope.vaultKeyIDExtensionKey] = .string(vault.kid)
            let target = SyncEnvelope(
                id: snippet.id,
                hlc: hlc,
                origin: self.clock.device,
                secure: true,
                deleted: false,
                fields: SyncEnvelope.Fields(
                    // Preserve only the explicit name. `Snippet.displayName` may derive
                    // its fallback from the first plaintext content line, while vault
                    // metadata is deliberately readable with the vault locked. Freezing
                    // that fallback here would therefore disclose secure content.
                    name: snippet.name,
                    keyword: snippet.normalizedKeyword,
                    content: Data(sealed.utf8),
                    tags: snippet.tags,
                    isEnabled: snippet.isEnabled,
                    isPinned: snippet.isPinned,
                    createdAt: snippet.createdAt,
                    updatedAt: timestamp),
                x: extensions)
            guard let record = try SyncLibraryProjection.vaultRecord(from: target) else {
                throw Failure.transaction("could not preserve sync metadata during promotion")
            }
            // Prewrite the destination, whose body is ciphertext. If the primary move
            // fails, the still-plain Snippet remains authoritative and projection treats
            // this non-exact sidecar as metadata only (stripping secure-only hash/scope).
            // If it succeeds, no plaintext copy of the old source can remain indefinitely
            // in library-metadata.json while sync is disabled.
            try self.persistTransitionMetadata(target)

            vault.records.append(record)
            contents.vault = vault
            contents.snippets.remove(at: index)
            // The marker only matters if we crash between the two writes; see
            // `LibraryTransaction.CrashMarker`.
            contents.marker = .promoting(snippetID)
        }
        adopt(outcome, notifyChange: notifyChange)
    }

    /// Turns a secure snippet back into a plaintext one.
    func demote(recordID: UUID, notifyChange: Bool = true) throws {
        _ = try requireDocument()

        let outcome = try runTransaction { contents in
            guard var vault = contents.vault,
                  let index = vault.records.firstIndex(where: { $0.id == recordID })
            else { throw Failure.notSecure }

            let record = vault.records[index]
            guard Self.supportsDemotion(record.x) else {
                throw Failure.transaction(
                    "this secure snippet contains metadata from a newer build; update "
                        + "Snippets before making it non-secure")
            }
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

            let snippet = Snippet(
                id: record.id, name: record.name, keyword: record.keyword,
                content: content,
                tags: record.tags, isEnabled: record.isEnabled, isPinned: record.isPinned,
                createdAt: record.createdAt, updatedAt: self.now())
            let source = try self.transitionEnvelope(
                snippets: contents.snippets,
                records: vault.records,
                vaultKID: vault.kid,
                id: record.id)
            // Never prewrite the decrypted destination. A crash or transaction failure
            // after that write would leave secure primary storage intact while leaking
            // its plaintext body into the sync sidecar. The encrypted source is a safe,
            // conservative handoff; authoritative plain primary heals it on projection.
            try self.persistTransitionMetadata(source)

            vault.records.remove(at: index)
            contents.vault = vault
            contents.snippets.insert(snippet, at: 0)
            contents.marker = .demoting(recordID)
        }
        adopt(outcome, notifyChange: notifyChange)
    }

    /// Representation changes move safety metadata between two frozen primary models.
    /// The transition sidecar lands before source ownership changes, but the prewrite is
    /// always ciphertext-bearing: promotion writes its secure destination and demotion
    /// writes its secure source. A crash can leave stale metadata, never plaintext secret
    /// material outside the authoritative ordinary library.
    private func persistTransitionMetadata(_ envelope: SyncEnvelope) throws {
        var metadata = try transitionMetadata()
        metadata.record(envelope)
        do {
            try syncMetadataWriter(metadata, syncMetadataURL, temporaryDirectory)
        } catch {
            throw Failure.transaction("could not preserve sync metadata before moving snippet")
        }
    }

    private func transitionEnvelope(
        snippets: [Snippet],
        records: [VaultRecord],
        vaultKID: String,
        id: UUID
    ) throws -> SyncEnvelope {
        let metadata = try transitionMetadata()
        let journal: SyncJournal
        let journalWasMissing: Bool
        switch SyncJournalFile.load(from: syncJournalURL) {
        case .missing(let empty):
            journal = empty
            journalWasMissing = true
        case .loaded(let loaded):
            journal = loaded
            journalWasMissing = false
        case .tooNew(let version):
            throw Failure.transaction(
                "sync journal schemaVersion \(version) is newer than this build")
        case .unreadable:
            throw Failure.transaction("pending sync metadata could not be read")
        }
        let base: SyncBase
        let baseWasMissing: Bool
        switch SyncBaseFile.load(from: syncBaseURL) {
        case .loaded(let loaded):
            base = loaded
            baseWasMissing = false
        case .missing:
            base = SyncBase()
            baseWasMissing = true
        case .tooNew(let version):
            throw Failure.transaction(
                "sync base schemaVersion \(version) is newer than this build")
        case .unreadable:
            throw Failure.transaction("confirmed sync metadata could not be read")
        }
        guard !baseWasMissing || journalWasMissing else {
            throw Failure.transaction(
                "confirmed sync state is missing while pending changes still exist")
        }
        guard !journalWasMissing || !base.journalEstablished else {
            throw Failure.transaction(
                "pending sync state is missing after its durability marker was established")
        }
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: snippets,
            records: records,
            deviceID: clock.device,
            metadata: metadata,
            agreedBase: journal.projectionKnowledge(over: base),
            vaultKID: vaultKID)
        guard let envelope = projected[id] else {
            throw Failure.transaction("snippet changed while preparing its secure move")
        }
        do {
            try SyncMerge.validateContentConflictExtensions(in: envelope)
            if envelope.x[SyncMerge.plainConflictCopyExtensionKey] != nil,
               !SyncMerge.hasValidConflictCopyIdentity(envelope) {
                throw SyncMerge.EnvelopeFailure.malformedContentConflict
            }
        } catch {
            throw Failure.transaction(
                "conflict metadata is malformed; refusing to move the snippet")
        }
        return envelope
    }

    private func transitionMetadata() throws -> SyncBase {
        switch SyncBaseFile.load(from: syncMetadataURL) {
        case .loaded(let loaded): return loaded
        case .missing: return SyncBase()
        case .tooNew(let version):
            throw Failure.transaction(
                "sync metadata schemaVersion \(version) is newer than this build")
        case .unreadable:
            throw Failure.transaction("sync metadata could not be read")
        }
    }

    private static func supportsDemotion(_ values: [String: JSONValue]) -> Bool {
        values.keys.allSatisfy { key in
            key == SyncMerge.plainConflictCopyExtensionKey
                || key.hasPrefix(SyncMerge.contentConflictOpaqueCarrierPrefix)
                || SyncMerge.isContentConflictExtension(key)
        }
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
        let forgottenIDs = Set(rollbackDocument?.records.map(\.id) ?? [])

        // Prepare the post-forget protocol state before destroying the vault. Ordinary
        // pending intent must survive, while secure confirmations/offers must not turn
        // the deliberately absent local vault into outbound tombstones later.
        var retainedBase: SyncBase
        let baseWasMissing: Bool
        switch SyncBaseFile.load(from: syncBaseURL) {
        case .loaded(let loaded):
            retainedBase = loaded
            baseWasMissing = false
        case .missing:
            retainedBase = SyncBase()
            baseWasMissing = true
        case .tooNew(let version):
            throw Failure.transaction(
                "sync base schemaVersion \(version) is newer than this build; refusing "
                    + "to forget the vault until sync bookkeeping can be preserved")
        case .unreadable:
            throw Failure.transaction(
                "sync bookkeeping could not be read; refusing to forget the vault "
                    + "without preserving ordinary pending changes")
        }
        var retainedJournal: SyncJournal
        let journalWasMissing: Bool
        switch SyncJournalFile.load(from: syncJournalURL) {
        case .missing(let empty):
            retainedJournal = empty
            journalWasMissing = true
        case .loaded(let loaded):
            retainedJournal = loaded
            journalWasMissing = false
        case .tooNew(let version):
            throw Failure.transaction(
                "sync journal schemaVersion \(version) is newer than this build; refusing "
                    + "to forget the vault until pending changes can be preserved")
        case .unreadable:
            throw Failure.transaction(
                "pending sync changes could not be read; refusing to forget the vault "
                    + "without preserving ordinary edits")
        }

        guard !baseWasMissing || journalWasMissing else {
            throw Failure.transaction(
                "confirmed sync state is missing while pending changes still exist; "
                    + "refusing to hide the loss while forgetting the vault")
        }
        guard !journalWasMissing || !retainedBase.journalEstablished else {
            throw Failure.transaction(
                "pending sync state is missing even though the confirmed base records "
                    + "that its journal was established; restore it or reset both files "
                    + "before forgetting the vault")
        }

        let originalBase: SyncBase? = baseWasMissing ? nil : retainedBase
        let originalJournal: SyncJournal? = journalWasMissing ? nil : retainedJournal
        let originalMetadata: SyncBase?
        switch SyncBaseFile.load(from: syncMetadataURL) {
        case .loaded(let loaded): originalMetadata = loaded
        case .missing: originalMetadata = nil
        case .tooNew(let version):
            throw Failure.transaction(
                "sync metadata schemaVersion \(version) is newer than this build; refusing "
                    + "to forget the vault until its conflict carriers can be preserved")
        case .unreadable:
            throw Failure.transaction(
                "sync metadata could not be read; refusing to forget the vault until "
                    + "its conflict carriers can be preserved")
        }

        if retainedJournal.requiresDependencyMigration {
            // Vault forget is also a journal maintenance writer and may run while sync
            // is disabled. Reconstruct schema-1 plain conflict edges from frozen files,
            // journal intent and the agreed base before publishing schema 2; the encoder
            // deliberately refuses to let this evidence be skipped.
            let snippets: [Snippet]
            do {
                snippets = try LibraryWriter.read(from: libraryURL).snippets
            } catch {
                throw Failure.transaction(
                    "the snippet library could not be read; refusing to forget the vault "
                        + "before sync intent is preserved")
            }
            let metadata = originalMetadata ?? retainedBase
            let current = SyncLibraryProjection.currentEnvelopes(
                snippets: snippets,
                records: rollbackDocument?.records ?? [],
                deviceID: clock.device,
                metadata: retainedJournal.projectionKnowledge(over: metadata),
                agreedBase: retainedBase,
                vaultKID: rollbackDocument?.kid)
            do {
                try retainedJournal.reconcileDependencies(
                    current: current, confirmed: retainedBase)
            } catch {
                throw Failure.transaction(
                    "legacy sync conflict intent could not be reconstructed; refusing "
                        + "to forget the vault without preserving ordinary copies")
            }
        }

        retainedBase.envelopes = retainedBase.envelopes.compactMapValues { envelope in
            guard !envelope.secure, !forgottenIDs.contains(envelope.id) else { return nil }
            return Self.scrubbingUnderstoodSecureConflictCarriers(envelope)
        }
        // A later opt-in deliberately performs a full fetch, allowing the remote vault
        // to return without forgetting ordinary confirmed ancestors.
        retainedBase.adoptCursor(nil, kind: nil)
        retainedBase.requiresTransportFullResync = !baseWasMissing
        retainedJournal.forgetSecureIntent(forgottenIDs: forgottenIDs)
        var retainedMetadata = originalMetadata
        if var metadata = retainedMetadata {
            metadata.envelopes = metadata.envelopes.compactMapValues { envelope in
                guard !envelope.secure,
                      !forgottenIDs.contains(envelope.id) else { return nil }
                return Self.scrubbingUnderstoodSecureConflictCarriers(envelope)
            }
            metadata.adoptCursor(nil, kind: nil)
            retainedMetadata = metadata
        }
        // System fields are credentials to replace the corresponding remote record.
        // Keep them for every ordinary confirmation or surviving ordinary desired
        // change (including a secure-to-plain demotion), and discard credentials owned
        // only by the forgotten vault. Leaving a secure generation behind without its
        // envelope/journal would let a later unrelated recreation inherit that identity.
        let retainedVersionKeys = Set(retainedBase.envelopes.keys)
            .union(retainedJournal.entries.keys)
        retainedBase.recordVersions = retainedBase.recordVersions.filter { key, _ in
            retainedVersionKeys.contains(key)
        }

        // Establish the post-forget projection/protocol state before destroying either
        // ciphertext or its device-only key. The metadata sidecar comes first: a crash
        // after that scrub still has the vault and complete protocol evidence, whereas
        // deleting the vault with an old sidecar could make this process speak for
        // forgotten ciphertext on a later opt-in. Base/journal remain structurally off
        // when both were absent, but an independently surviving metadata file must still
        // be scrubbed durably. Any failure leaves the vault intact and rolls every file
        // back to its exact pre-transaction state.
        do {
            if let retainedMetadata {
                try syncMetadataWriter(
                    retainedMetadata, syncMetadataURL, temporaryDirectory)
            }
            if !baseWasMissing || !journalWasMissing {
                try syncBaseWriter(retainedBase, syncBaseURL, temporaryDirectory)
                try syncJournalWriter(retainedJournal, syncJournalURL, temporaryDirectory)
            }
        } catch {
            let rollback = rollbackForgetState(
                vault: nil, base: originalBase, journal: originalJournal,
                metadata: originalMetadata)
            throw Failure.transaction(
                "could not durably preserve ordinary sync state before forgetting "
                    + "the vault: \(error)\(rollback)")
        }

        do {
            // The directory fsync is load-bearing: the removal must survive a crash
            // before any device-only key is deleted.
            try durableFileRemover(vaultURL)
        } catch {
            let rollback = rollbackForgetState(
                vault: rollbackDocument, base: originalBase, journal: originalJournal,
                metadata: originalMetadata)
            throw Failure.transaction(
                "could not durably delete the vault: \(error)\(rollback)")
        }

        if let kid, !preserveSharedKey {
            do {
                try vaultKeyRemover(kid)
            } catch let keychainError {
                // Treat a Keychain refusal as a failed transaction. Restore both the
                // locked vault and the exact protocol snapshots; restoring only the
                // ciphertext would leave a reported failure with its offered/desired
                // history silently discarded.
                let rollback = rollbackForgetState(
                    vault: rollbackDocument, base: originalBase, journal: originalJournal,
                    metadata: originalMetadata)
                let recovery = rollbackDocument == nil ? "no vault file needed restoring" : "the vault was restored"
                throw Failure.transaction(
                    "the keychain kept the vault key; \(recovery): \(keychainError)\(rollback)")
            }
        }

        // The local-tier identity is as stale as its deleted key. The synchronizable
        // identity must remain: deleting it would propagate, and it is what lets this Mac
        // rejoin the same vault later instead of minting a rival one.
        if !preserveSharedKey { identityStore.forget() }

        document = nil
        isUnreadable = false
        session.adopt(keyID: nil)
        Diagnostics.record(.vaultAction(.forgotLocalVault, count: nil))
        onChange?()
    }

    /// Best-effort rollback for every failure after protocol pruning begins.
    ///
    /// The vault is restored first so a crash cannot expose secure journal intent while
    /// its local ciphertext is still absent. All requested restorations are attempted
    /// even after one fails; the returned suffix makes an incomplete rollback explicit
    /// while sync remains structurally off.
    private func rollbackForgetState(
        vault: VaultDocument?,
        base: SyncBase?,
        journal: SyncJournal?,
        metadata: SyncBase? = nil
    ) -> String {
        var failures: [String] = []

        if let vault {
            do {
                try VaultFile.write(
                    vault, to: vaultURL, temporaryDirectory: temporaryDirectory)
                document = vault
            } catch {
                failures.append("vault restore failed: \(error)")
            }
        }

        if let base {
            // Restore the journal first. Both paths already exist at this point, and
            // the conservative crash state is "pruned base + original intent": that can
            // conflict/refetch. The inverse would look fully valid while silently
            // retaining the pruned journal and losing the only ambiguous offer.
            if let journal {
                do {
                    try syncJournalWriter(journal, syncJournalURL, temporaryDirectory)
                } catch {
                    failures.append("sync journal restore failed: \(error)")
                }
            } else {
                do {
                    try durableFileRemover(syncJournalURL)
                } catch {
                    failures.append("new sync journal removal failed: \(error)")
                }
            }
            do {
                try syncBaseWriter(base, syncBaseURL, temporaryDirectory)
            } catch {
                failures.append("sync base restore failed: \(error)")
            }
        } else {
            // The validated original shape cannot contain a journal without a base.
            // Remove in the reverse establishment order to preserve that invariant.
            do {
                try durableFileRemover(syncJournalURL)
            } catch {
                failures.append("new sync journal removal failed: \(error)")
            }
            do {
                try durableFileRemover(syncBaseURL)
            } catch {
                failures.append("new sync base removal failed: \(error)")
            }
        }

        if let metadata {
            do {
                try syncMetadataWriter(metadata, syncMetadataURL, temporaryDirectory)
            } catch {
                failures.append("sync metadata restore failed: \(error)")
            }
        } else {
            do {
                try durableFileRemover(syncMetadataURL)
            } catch {
                failures.append("new sync metadata removal failed: \(error)")
            }
        }

        guard !failures.isEmpty else { return "; original state was restored" }
        return "; rollback incomplete (" + failures.joined(separator: "; ") + ")"
    }

    private static func scrubbingUnderstoodSecureConflictCarriers(
        _ envelope: SyncEnvelope
    ) -> SyncEnvelope {
        var retained = envelope
        for key in retained.x.keys where key.hasPrefix(
            SyncMerge.contentConflictV1ExtensionPrefix) {
            retained.x[key] = nil
        }
        return retained
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
            Diagnostics.record(.vaultAction(
                .reconciledInterruptedMove,
                count: outcome.value))
            adopt(outcome)
        }
        return outcome?.value ?? 0
    }

    private func prepareEncryptedBackupSnapshot() throws -> EncryptedBackupSnapshot {
        let snapshot = try runTransaction { contents in
            (snippets: contents.snippets, vault: contents.vault)
        }.value
        // A zero-record vault contains no snippet data worth exporting. Omitting it also
        // avoids asking for a key solely to preserve an unused security setup.
        var exportedVault = snapshot.vault?.records.isEmpty == false ? snapshot.vault : nil
        // Receipts describe this device's primary-file history, not user data and not
        // portable recovery state. Importing one could suppress a required C0 install.
        exportedVault?.removeLocalConflictInstallReceipts()
        let libraryKey: SymmetricKey?
        if let exportedVault {
            guard document?.kid == exportedVault.kid else {
                throw Failure.transaction("the vault changed while the backup was being prepared; try again")
            }
            libraryKey = try session.currentKey()
        } else {
            libraryKey = nil
        }

        return EncryptedBackupSnapshot(
            snippets: snapshot.snippets,
            vault: exportedVault,
            vaultKey: libraryKey)
    }

    private func mergeEncryptedBackup(
        _ opened: EncryptedSnippetBackup.Opened,
        into store: SnippetStore,
        authoritativeOrdinaryRecovery: Bool = false
    ) throws -> EncryptedBackupImportResult {
        let incomingPlain = opened.snippets.map(Self.normalizedBackupSnippet)
        var incomingVault = opened.vault
        incomingVault?.removeLocalConflictInstallReceipts()
        let importDate = now()
        let importWallMs = UInt64(max(0, importDate.timeIntervalSince1970 * 1_000))
        let importedClocks: [UUID: HLC] = Dictionary(uniqueKeysWithValues:
            (incomingVault?.records ?? []).map { record in
                (record.id, clock.send(atLeast: max(record.hlc.wallMs, importWallMs)))
            })

        let outcome = try runTransaction { contents in
            var conflicts: [String] = []
            let existingPlain = authoritativeOrdinaryRecovery ? [] : contents.snippets
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

            var mergedPlain = authoritativeOrdinaryRecovery ? [] : contents.snippets
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

    /// Sync may opportunistically materialise an encrypted conflict only while the
    /// user has already unlocked this vault. This never prompts and, unlike an explicit
    /// reveal/edit, does not slide the idle deadline: background traffic must not keep
    /// an unattended vault open.
    func unlockedKeyringForSync() throws -> SnippetCrypto.Keyring {
        let document = try requireDocument()
        guard let salt = document.vaultSaltBytes else {
            throw Failure.vaultUnreadable("the vault's salt could not be decoded")
        }
        return try session.keyringWithoutExtendingSession(vaultSalt: salt)
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

    private func adopt<T>(
        _ outcome: LibraryTransaction.Outcome<T>,
        notifyChange: Bool = true
    ) {
        document = outcome.vault
        if notifyChange { onChange?() }
    }

    /// Publishes a move whose transaction notification was deliberately deferred until
    /// both the ordinary and secure in-memory projections had been reloaded. This is an
    /// iOS cache-coordination hook; direct macOS moves keep the default immediate
    /// notification on `promote` and `demote`.
    func coordinatedMoveDidFinish() {
        onChange?()
    }
}
