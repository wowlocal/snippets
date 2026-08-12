import CryptoKit
import Foundation
import Security

// App target only. CKSyncEngine's opaque serialization can contain CloudKit account
// coordinates, so this file intentionally stays out of CorePackage and snippets-cli.

/// Encrypts the complete CKSyncEngine checkpoint envelope before it reaches disk.
///
/// The serialization is opaque Apple state, not application JSON. In particular it may
/// contain a stable CloudKit user record identifier, which the diagnostics/privacy
/// contract forbids us to persist in plaintext. Keeping the seam this small also lets
/// durability tests use a deterministic authenticated key without touching Keychain.
nonisolated protocol CloudKitSyncCheckpointCrypting: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}

/// The CKSyncEngine watermark and every fetched record covered by that watermark.
///
/// A generation is retained until `SyncBase.cursor` comes back in a *later* round. The
/// engine serialization can therefore advance immediately without losing records when
/// the process dies before the domain merge and base fsync complete.
nonisolated struct CloudKitSyncCheckpoint: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    nonisolated struct Generation: Codable, Equatable, Sendable {
        var sequence: UInt64
        var serialization: Data
        var records: [WireRecord]
        var physicalDeletionCount: Int

        init(
            sequence: UInt64,
            serialization: Data,
            records: [WireRecord],
            physicalDeletionCount: Int
        ) {
            self.sequence = sequence
            self.serialization = serialization
            self.records = records
            self.physicalDeletionCount = physicalDeletionCount
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case sequence, serialization, records, physicalDeletionCount
        }

        init(from decoder: Decoder) throws {
            try CloudKitSyncCheckpoint.rejectUnknownFields(
                decoder, expected: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sequence = try container.decode(UInt64.self, forKey: .sequence)
            serialization = try container.decode(Data.self, forKey: .serialization)
            records = try container.decode([WireRecord].self, forKey: .records)
            physicalDeletionCount = try container.decode(Int.self, forKey: .physicalDeletionCount)
            guard sequence > 0,
                  !serialization.isEmpty,
                  physicalDeletionCount >= 0 else {
                throw CloudKitSyncCheckpointCodingFailure.invalid
            }
        }

        func encode(to encoder: Encoder) throws {
            guard sequence > 0,
                  !serialization.isEmpty,
                  physicalDeletionCount >= 0 else {
                throw CloudKitSyncCheckpointCodingFailure.invalid
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sequence, forKey: .sequence)
            try container.encode(serialization, forKey: .serialization)
            try container.encode(records, forKey: .records)
            try container.encode(physicalDeletionCount, forKey: .physicalDeletionCount)
        }
    }

    var schemaVersion: Int
    var accountIdentity: SyncAccountIdentity
    var epoch: UUID
    var serialization: Data?
    var nextSequence: UInt64
    var generations: [Generation]
    /// True only until this account scope's custom zone has been saved once.
    ///
    /// A nil scheduler serialization is also used for reviewed checkpoint repair and
    /// local transport-key rekey. It therefore cannot, by itself, mean that recreating
    /// the remote zone is safe: doing so after a purge/reset would upload local cache
    /// back into a scope CloudKit deliberately removed.
    var allowsZoneBootstrap: Bool

    init(
        accountIdentity: SyncAccountIdentity,
        epoch: UUID = UUID(),
        serialization: Data? = nil,
        nextSequence: UInt64 = 1,
        generations: [Generation] = [],
        allowsZoneBootstrap: Bool = true
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.accountIdentity = accountIdentity
        self.epoch = epoch
        self.serialization = serialization
        self.nextSequence = nextSequence
        self.generations = generations
        self.allowsZoneBootstrap = allowsZoneBootstrap
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, accountIdentity, epoch, serialization, nextSequence, generations
        case allowsZoneBootstrap
    }

    init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(decoder, expected: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CloudKitSyncCheckpointCodingFailure.unsupportedSchema
        }
        accountIdentity = try container.decode(SyncAccountIdentity.self, forKey: .accountIdentity)
        epoch = try container.decode(UUID.self, forKey: .epoch)
        serialization = try container.decodeIfPresent(Data.self, forKey: .serialization)
        nextSequence = try container.decode(UInt64.self, forKey: .nextSequence)
        generations = try container.decode([Generation].self, forKey: .generations)
        allowsZoneBootstrap = try container.decode(Bool.self, forKey: .allowsZoneBootstrap)
        try validate(decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try validate(encoder.codingPath)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(accountIdentity, forKey: .accountIdentity)
        try container.encode(epoch, forKey: .epoch)
        try container.encodeIfPresent(serialization, forKey: .serialization)
        try container.encode(nextSequence, forKey: .nextSequence)
        try container.encode(generations, forKey: .generations)
        try container.encode(allowsZoneBootstrap, forKey: .allowsZoneBootstrap)
    }

    private func validate(_ codingPath: [any CodingKey]) throws {
        _ = codingPath
        guard schemaVersion == Self.currentSchemaVersion,
              nextSequence > 0,
              serialization?.isEmpty != true else {
            throw CloudKitSyncCheckpointCodingFailure.invalid
        }
        var previous: UInt64 = 0
        for generation in generations {
            guard generation.sequence > previous,
                  generation.sequence < nextSequence else {
                throw CloudKitSyncCheckpointCodingFailure.invalid
            }
            previous = generation.sequence
        }
    }

    fileprivate static func rejectUnknownFields(
        _ decoder: Decoder,
        expected: [String]
    ) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: Set(expected)) else {
            throw CloudKitSyncCheckpointCodingFailure.invalid
        }
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

private nonisolated enum CloudKitSyncCheckpointCodingFailure: Error {
    case invalid
    case unsupportedSchema
}

/// Cursor returned to Core only after the corresponding encrypted inbox exists.
nonisolated struct CloudKitSyncCursor: Codable, Equatable, Sendable {
    private static let prefix = "cksync-inbox-v1:"

    var epoch: UUID
    var throughSequence: UInt64

    var syncCursor: SyncCursor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try? encoder.encode(self)
        return SyncCursor(Self.prefix + (encoded?.base64EncodedString() ?? ""))
    }

    static func decode(_ cursor: SyncCursor) -> CloudKitSyncCursor? {
        guard cursor.rawValue.hasPrefix(prefix) else { return nil }
        let payload = String(cursor.rawValue.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: payload),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.throughSequence > 0 else { return nil }
        return decoded
    }
}

/// Atomic encrypted storage for the CKSyncEngine watermark plus durable inbound inbox.
nonisolated final class CloudKitSyncCheckpointStore: @unchecked Sendable {
    nonisolated enum LoadOutcome: Equatable, Sendable {
        case missing
        case loaded(CloudKitSyncCheckpoint)
        case unreadable
        case scopeMismatch
    }

    nonisolated enum Failure: Error, Equatable {
        case unreadable
        case scopeMismatch
        case wrongEpoch
        case invalidAcknowledgement
    }

    private let url: URL
    private let temporaryDirectory: URL
    private let cryptor: any CloudKitSyncCheckpointCrypting
    private let applyFileProtection: @Sendable (URL) throws -> Void
    private let lock = NSLock()

    init(
        url: URL = SnippetStorageLocations.cloudKitSyncCheckpointFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL,
        cryptor: any CloudKitSyncCheckpointCrypting = LocalCloudKitSyncCheckpointCryptor(),
        applyFileProtection: @escaping @Sendable (URL) throws -> Void = { url in
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
            #else
            _ = url
            #endif
        }
    ) {
        self.url = url
        self.temporaryDirectory = temporaryDirectory
        self.cryptor = cryptor
        self.applyFileProtection = applyFileProtection
    }

    func load(for accountIdentity: SyncAccountIdentity) -> LoadOutcome {
        lock.withLock { loadUnlocked(for: accountIdentity) }
    }

    func saveStateSerialization(
        _ serialization: Data,
        for accountIdentity: SyncAccountIdentity
    ) throws {
        try lock.withLock {
            guard !serialization.isEmpty else { throw Failure.unreadable }
            var checkpoint = try checkpointForMutation(accountIdentity)
            checkpoint.serialization = serialization
            try write(checkpoint)
        }
    }

    @discardableResult
    func appendFetched(
        records: [WireRecord],
        physicalDeletionCount: Int,
        stateSerialization: Data,
        for accountIdentity: SyncAccountIdentity
    ) throws -> CloudKitSyncCheckpoint.Generation {
        try lock.withLock {
            guard physicalDeletionCount >= 0,
                  !stateSerialization.isEmpty else { throw Failure.unreadable }
            var checkpoint = try checkpointForMutation(accountIdentity)
            let generation = CloudKitSyncCheckpoint.Generation(
                sequence: checkpoint.nextSequence,
                serialization: stateSerialization,
                records: records,
                physicalDeletionCount: physicalDeletionCount)
            checkpoint.nextSequence &+= 1
            guard checkpoint.nextSequence != 0 else { throw Failure.unreadable }
            checkpoint.serialization = stateSerialization
            checkpoint.generations.append(generation)
            try write(checkpoint)
            return generation
        }
    }

    func acknowledge(
        through sequence: UInt64,
        epoch: UUID,
        for accountIdentity: SyncAccountIdentity
    ) throws {
        try lock.withLock {
            var checkpoint = try checkpointForMutation(accountIdentity)
            guard checkpoint.epoch == epoch else { throw Failure.wrongEpoch }
            guard sequence > 0, sequence < checkpoint.nextSequence else {
                throw Failure.invalidAcknowledgement
            }
            if let first = checkpoint.generations.first,
               sequence >= first.sequence,
               !checkpoint.generations.contains(where: { $0.sequence == sequence }) {
                // Only a cursor we actually returned may compact the inbox. A manually
                // edited/corrupt base must not be able to skip an unseen generation.
                throw Failure.invalidAcknowledgement
            }
            let retained = checkpoint.generations.filter { $0.sequence > sequence }
            guard retained != checkpoint.generations else { return }
            checkpoint.generations = retained
            try write(checkpoint)
        }
    }

    /// Destructive only after the domain engine consumed its one-shot review grant.
    /// Sealing happens before the atomic rename, so an unavailable replacement key
    /// leaves the exact old ciphertext in place.
    func resetAfterAccountReview(for accountIdentity: SyncAccountIdentity) throws {
        try reset(
            for: accountIdentity,
            allowsZoneBootstrap: true)
    }

    /// Replaces scheduler ancestry while retaining whether zone creation is authorized.
    /// Account migration is the only reviewed reset that may pass `true`; same-account
    /// repair and local crypto maintenance must always pass `false`.
    func reset(
        for accountIdentity: SyncAccountIdentity,
        allowsZoneBootstrap: Bool
    ) throws {
        try lock.withLock {
            try write(CloudKitSyncCheckpoint(
                accountIdentity: accountIdentity,
                allowsZoneBootstrap: allowsZoneBootstrap))
        }
    }

    /// Persists the point after which nil scheduler state must never recreate the zone.
    /// This write happens immediately after the awaited direct zone save and before the
    /// first snippet send/fetch is allowed to proceed.
    func markZoneEstablished(for accountIdentity: SyncAccountIdentity) throws {
        try lock.withLock {
            var checkpoint = try checkpointForMutation(accountIdentity)
            guard checkpoint.allowsZoneBootstrap else { return }
            checkpoint.allowsZoneBootstrap = false
            try write(checkpoint)
        }
    }

    private func checkpointForMutation(
        _ accountIdentity: SyncAccountIdentity
    ) throws -> CloudKitSyncCheckpoint {
        switch loadUnlocked(for: accountIdentity) {
        case .missing:
            return CloudKitSyncCheckpoint(accountIdentity: accountIdentity)
        case .loaded(let checkpoint):
            return checkpoint
        case .unreadable:
            throw Failure.unreadable
        case .scopeMismatch:
            throw Failure.scopeMismatch
        }
    }

    private func loadUnlocked(for accountIdentity: SyncAccountIdentity) -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let ciphertext = try Data(contentsOf: url, options: [.mappedIfSafe])
            let plaintext = try cryptor.open(ciphertext)
            let checkpoint = try JSONDecoder().decode(
                CloudKitSyncCheckpoint.self, from: plaintext)
            guard checkpoint.accountIdentity == accountIdentity else {
                return .scopeMismatch
            }
            return .loaded(checkpoint)
        } catch {
            return .unreadable
        }
    }

    private func write(_ checkpoint: CloudKitSyncCheckpoint) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)

        for directory in [parent, temporaryDirectory] {
            try applyFileProtection(directory)
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(directoryValues)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(checkpoint)
        let ciphertext = try cryptor.seal(plaintext)
        try AtomicFileWriter.write(
            ciphertext,
            to: url,
            temporaryDirectory: temporaryDirectory,
            permissions: 0o600)

        try applyFileProtection(url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

/// Device-local, background-readable checkpoint key. It must never use the shared
/// KeychainSecretStore because that class intentionally upgrades to synchronizable
/// iCloud Keychain when the entitlement is available.
nonisolated final class LocalCloudKitSyncCheckpointKeyStore: @unchecked Sendable {
    nonisolated enum Failure: Error {
        case unavailable(OSStatus)
        case missingKey
        case malformedKey
    }

    private static let keyByteCount = 32
    private static let service = "com.khm.snippets.cksync-checkpoint"
    private static let account = "local-v1"
    private let lock = NSLock()
    private let keychainOperations: KeychainItemOperations

    init(keychainOperations: KeychainItemOperations = .live) {
        self.keychainOperations = keychainOperations
    }

    /// Reads existing material without creating a replacement. Ciphertext paired with
    /// a missing local key is evidence of an unreadable checkpoint and must flow to the
    /// reviewed recovery path instead of silently minting a key that cannot decrypt it.
    func material() throws -> Data? {
        try lock.withLock { try load() }
    }

    func materialMintingIfNeeded() throws -> Data {
        try lock.withLock {
            if let existing = try load() { return existing }

            var bytes = Data(count: Self.keyByteCount)
            let randomStatus = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, Self.keyByteCount, buffer.baseAddress!)
            }
            guard randomStatus == errSecSuccess else { throw Failure.unavailable(randomStatus) }

            var attributes = query
            attributes[kSecValueData as String] = bytes
            attributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = keychainOperations.add(attributes as CFDictionary, nil)
            switch status {
            case errSecSuccess:
                return bytes
            case errSecDuplicateItem:
                guard let winner = try load() else { throw Failure.unavailable(status) }
                return winner
            default:
                throw Failure.unavailable(status)
            }
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychainOperations.copyMatching(lookup as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data, data.count == Self.keyByteCount else {
                throw Failure.malformedKey
            }
            return data
        default:
            throw Failure.unavailable(status)
        }
    }
}

nonisolated struct LocalCloudKitSyncCheckpointCryptor: CloudKitSyncCheckpointCrypting {
    private let keys: LocalCloudKitSyncCheckpointKeyStore

    init(keys: LocalCloudKitSyncCheckpointKeyStore = LocalCloudKitSyncCheckpointKeyStore()) {
        self.keys = keys
    }

    func seal(_ plaintext: Data) throws -> Data {
        let key = SymmetricKey(data: try keys.materialMintingIfNeeded())
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw LocalCloudKitSyncCheckpointKeyStore.Failure.malformedKey
        }
        return combined
    }

    func open(_ sealed: Data) throws -> Data {
        guard let material = try keys.material() else {
            throw LocalCloudKitSyncCheckpointKeyStore.Failure.missingKey
        }
        let key = SymmetricKey(data: material)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }
}
