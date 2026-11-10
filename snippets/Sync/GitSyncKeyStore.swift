import CryptoKit
import Foundation

// App target only (macOS and iOS). Core's transport never sees key material.

/// The encryption key of each connected Git library.
///
/// Every Git library has its own 64-byte `K_sync` material, minted when the library is
/// created and never shared with iCloud sync or Snippets Cloud. A record is bound to the
/// repository location, branch and the library's random dataset id, so a different
/// repository that happens to copy a manifest can never borrow the key.
///
/// The store uses the default Keychain tier. On builds entitled to the shared access
/// group that tier is synchronizable, so iCloud Keychain carries the key to the user's
/// other Apple devices and they connect without the recovery code. Unentitled builds
/// and other platforms receive the key from `keys/recovery.json` and the recovery code.
@MainActor
final class GitSyncKeyStore {
    static let service = "com.khm.snippets.git-sync"
    nonisolated static let materialByteCount = 64

    /// The library a key belongs to.
    nonisolated struct Scope: Equatable, Sendable {
        let location: String
        let refName: String
        let datasetID: UUID

        init(location: String, refName: String, datasetID: UUID) {
            self.location = location
            self.refName = refName
            self.datasetID = datasetID
        }

        init(remote: GitRemote, datasetID: UUID) {
            self.init(location: remote.canonicalLocation, refName: remote.refName, datasetID: datasetID)
        }

        /// Opaque, so Keychain listings name no repository.
        var account: String {
            let text = "snippets-git-key-v1\n\(location)\n\(refName)\n\(datasetID.uuidString.lowercased())"
            return "git-library-v1-" + SHA256.hash(data: Data(text.utf8)).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    nonisolated enum Failure: Error, Equatable, CustomStringConvertible {
        case malformedRecord
        case keychainUnavailable

        var description: String {
            switch self {
            case .malformedRecord: "the saved Git library key is invalid"
            case .keychainUnavailable: "the keychain could not provide the Git library key"
            }
        }
    }

    private nonisolated struct Record: Codable {
        let schemaVersion: Int
        let location: String
        let refName: String
        let datasetID: String
        let material: Data
    }

    private nonisolated let keychain: KeychainSecretStore

    init(keychain: KeychainSecretStore? = nil) {
        self.keychain = keychain ?? KeychainSecretStore(
            service: Self.service, itemAccessibility: .afterFirstUnlock)
    }

    var syncsBetweenDevices: Bool { keychain.tier.syncsBetweenDevices }

    func material(for scope: Scope) throws -> Data? {
        let data: Data?
        do { data = try keychain.loadItem(account: scope.account) }
        catch { throw Failure.keychainUnavailable }
        return try Self.decode(data, for: scope)
    }

    /// The same read for iOS lifecycle work, which must not run Security.framework IPC
    /// on MainActor.
    nonisolated func materialInBackground(for scope: Scope) async throws -> Data? {
        try await Task.detached(priority: .utility) { [keychain] in
            let data: Data?
            do { data = try keychain.loadItem(account: scope.account) }
            catch { throw Failure.keychainUnavailable }
            return try Self.decode(data, for: scope)
        }.value
    }

    private nonisolated static func decode(_ data: Data?, for scope: Scope) throws -> Data? {
        guard let data else { return nil }
        guard data.count <= 2_048,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "location", "refName", "datasetID", "material"],
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schemaVersion == 1,
              record.material.count == Self.materialByteCount else {
            throw Failure.malformedRecord
        }
        // A record stored under this account for another scope is a hash collision or
        // tampering; never hand its key to a different library.
        guard record.location == scope.location,
              record.refName == scope.refName,
              record.datasetID == scope.datasetID.uuidString.lowercased() else {
            throw Failure.malformedRecord
        }
        return record.material
    }

    func hasMaterial(for scope: Scope) -> Bool {
        (try? material(for: scope)) != nil
    }

    func install(_ material: Data, for scope: Scope) throws {
        guard material.count == Self.materialByteCount else { throw Failure.malformedRecord }
        let record = Record(
            schemaVersion: 1, location: scope.location, refName: scope.refName,
            datasetID: scope.datasetID.uuidString.lowercased(), material: material)
        do { try keychain.storeItem(try JSONEncoder().encode(record), account: scope.account) }
        catch { throw Failure.keychainUnavailable }
    }

    func forget(_ scope: Scope) throws {
        do { try keychain.deleteItem(account: scope.account) }
        catch { throw Failure.keychainUnavailable }
    }

    static func mintMaterial() -> Data {
        var material = SnippetCrypto.randomBytes(SnippetCrypto.keyByteCount)
        material.append(SnippetCrypto.randomBytes(SnippetCrypto.saltByteCount))
        return material
    }
}
