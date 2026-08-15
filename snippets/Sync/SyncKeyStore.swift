import CryptoKit
import Foundation

// App target only — see the note at the top of `CloudKitRecordMapping.swift`.

/// Owns `K_sync`, the key every record is sealed under before it leaves this Mac.
///
/// ## Why this is not the vault key
///
/// It used to be. `SyncCoordinator` built its sealer from `VaultSession.keyring(...)`,
/// which meant sync could not start without a vault and could not run without an
/// *unlocked* one — so syncing an ordinary snippet required setting up Secure Snippets,
/// saving a recovery key, and proving user presence again every half hour or background
/// rounds silently stopped.
///
/// That gate bought nothing. Work out what the wire key actually protects:
///
/// - Ordinary snippet bodies — already plaintext in `snippets.json`, on this disk.
/// - Secure snippets' names, keywords and tags — already plaintext in `vault.json`.
/// - Secure snippets' *content* — **not protected by this key at all.** `SyncEnvelope`
///   carries the vault's `sealed` bytes verbatim (see `SnippetLibraryBridge`), so they
///   are already ciphertext under `K_rec` before this layer sees them.
///
/// So `K_sync` defends against Apple and against whoever ends up with the bucket. It
/// does not, and cannot, defend against someone sitting at the unlocked Mac — they can
/// read both files directly. Requiring Touch ID for it was protecting a copy of data
/// that is in the clear two directories away, at the cost of the feature working at all.
///
/// Splitting it out keeps `K_lib` honest: the library key is still never read without a
/// user-presence check, because nothing unattended needs it any more.
///
/// ## One key per iCloud account, and how two Macs agree on it
///
/// `account` is fixed and doubles as the crypto scope. There is exactly one wire key per
/// iCloud account, so a per-device name would only guarantee that no two devices ever
/// agreed. `KeychainSecretStore` stores it with `kSecAttrSynchronizable` where the
/// entitlement allows, so the second Mac reads the first Mac's key rather than minting
/// its own.
///
/// `addItemIfAbsent` settles the race on one device. The race it cannot settle is two
/// Macs that both mint before iCloud Keychain has propagated either — which needs a
/// user enabling sync on two Macs within about a minute, ever, and only the very first
/// time. iCloud Keychain converges on one of them, `SyncCoordinator` notices the stored
/// key no longer matches the one its engine was built with and rebuilds, and both Macs
/// end up on the winner. The rebuild clears the agreed base, so every local record is
/// offered again under the winning key; stale losing-key records in the backend can be
/// overwritten or removed with the rest of the old zone.
@MainActor
final class SyncKeyStore {

    /// Fixed. Also the `scopeID` bound into every envelope's AAD — see
    /// `SnippetCryptoSealer.scopeID` for why a scope must come from somewhere that
    /// cannot regenerate itself, which a constant trivially satisfies.
    static let account = "sync-v1"

    /// 32 bytes of key followed by 32 bytes of HKDF salt, exactly what
    /// `SnippetCrypto.Keyring.generate()` produces.
    private nonisolated static let materialByteCount =
        SnippetCrypto.keyByteCount + SnippetCrypto.saltByteCount

    enum Failure: Error, Equatable, CustomStringConvertible {
        case malformedMaterial(Int)
        case keychainUnavailable
        case cloudBootstrapRequired

        var description: String {
            switch self {
            case .malformedMaterial(let count):
                return "the stored sync key must be \(SyncKeyStore.materialByteCount) bytes; found \(count)"
            case .keychainUnavailable:
                return "the keychain could not provide the sync key"
            case .cloudBootstrapRequired:
                return "approve this device or restore the Snippets Cloud recovery kit first"
            }
        }
    }

    var scopeID: String { Self.account }

    private let keychain: KeychainSecretStore
    private let cloudKeys: SnippetsCloudKeyStore?
    private let usesSnippetsCloud: () -> Bool

    init(
        keychain: KeychainSecretStore,
        cloudKeys: SnippetsCloudKeyStore? = nil,
        usesSnippetsCloud: @escaping () -> Bool = { false }
    ) {
        self.keychain = keychain
        self.cloudKeys = cloudKeys
        self.usesSnippetsCloud = usesSnippetsCloud
    }

    /// The stored key material, or `nil` when this Mac has none yet.
    ///
    /// Returned as bytes rather than as a `Keyring` so `SyncCoordinator` can compare it
    /// against what its engine was built with. A `SymmetricKey` is not `Equatable` in a
    /// way that helps, and the comparison is the whole point.
    func material() throws -> Data? {
        if usesSnippetsCloud() {
            guard let cloudKeys else { throw Failure.cloudBootstrapRequired }
            return try cloudKeys.materialForConfiguredAccount()
        }
        do {
            guard let stored = try keychain.loadItem(
                account: Self.account, expectedByteCount: Self.materialByteCount)
            else { return nil }
            guard stored.count == Self.materialByteCount else {
                throw Failure.malformedMaterial(stored.count)
            }
            return stored
        } catch KeychainSecretStore.Failure.invalidItemLength(_, let actual) {
            throw Failure.malformedMaterial(actual)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.keychainUnavailable
        }
    }

    /// The wire key, minting and storing one on first use.
    ///
    /// No user presence, deliberately — see the type's documentation. Background rounds
    /// may be started silently by CKSyncEngine and must not raise a Touch ID sheet over
    /// whatever the user is actually doing.
    func materialMintingIfNeeded() throws -> Data {
        if let existing = try material() { return existing }
        if usesSnippetsCloud() { throw Failure.cloudBootstrapRequired }

        var minted = Data(capacity: Self.materialByteCount)
        minted.append(SnippetCrypto.randomBytes(SnippetCrypto.keyByteCount))
        minted.append(SnippetCrypto.randomBytes(SnippetCrypto.saltByteCount))

        do {
            let stored = try keychain.addItemIfAbsent(minted, account: Self.account)
            guard stored.count == Self.materialByteCount else {
                throw Failure.malformedMaterial(stored.count)
            }
            return stored
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.keychainUnavailable
        }
    }

    /// Splits stored material into the keyring the sealer wants.
    nonisolated static func keyring(from material: Data) throws -> SnippetCrypto.Keyring {
        guard material.count == materialByteCount else {
            throw Failure.malformedMaterial(material.count)
        }
        let split = material.index(material.startIndex, offsetBy: SnippetCrypto.keyByteCount)
        return SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: material[material.startIndex..<split]),
            salt: Data(material[split...]))
    }

    /// Drops the wire key. Everything already in the backend becomes unreadable, which
    /// is why nothing calls this except an explicit reset.
    func forget() {
        do {
            try keychain.deleteItem(account: Self.account)
        } catch {
            Diagnostics.record(.storageFailure(
                area: .syncKey,
                operation: .remove,
                failure: DiagnosticFailure(error),
                attempt: nil))
        }
    }
}

/// Device-local copy of the Snippets Cloud library root.
///
/// It is deliberately a single authenticated Keychain record containing both the
/// 64-byte wire material and its exact server/space binding. Unlike the iCloud key,
/// it is never synchronizable: another device must receive it through an approved
/// pairing or decrypt it with the user's offline recovery kit.
@MainActor
final class SnippetsCloudKeyStore {
    static let service = "com.khm.snippets.cloud-library-key"
    static let account = "sync-v1"

    enum Failure: Error, CustomStringConvertible {
        case malformedRecord
        case wrongAccount
        case keychainUnavailable

        var description: String {
            switch self {
            case .malformedRecord: "the saved Snippets Cloud key is invalid"
            case .wrongAccount: "the saved key belongs to a different Snippets Cloud library"
            case .keychainUnavailable: "the keychain could not provide the Snippets Cloud key"
            }
        }
    }

    private struct Record: Codable {
        let schemaVersion: Int
        let serverURL: String
        let spaceID: String
        let material: Data
    }

    private let keychain: KeychainSecretStore
    private let coordinates: @MainActor () -> SyncBackendSelectionStore.CloudCoordinates?

    init(
        keychain: KeychainSecretStore? = nil,
        coordinates: @escaping @MainActor () -> SyncBackendSelectionStore.CloudCoordinates? = {
            SyncBackendSelectionStore().cloudCoordinates
        }
    ) {
        self.keychain = keychain ?? KeychainSecretStore(
            tier: .deviceOnly,
            service: Self.service,
            itemAccessibility: .afterFirstUnlock)
        self.coordinates = coordinates
    }

    func materialForConfiguredAccount() throws -> Data? {
        guard let coordinates = coordinates() else { return nil }
        return try material(serverURL: coordinates.serverURL, spaceID: coordinates.spaceID)
    }

    func material(serverURL: URL, spaceID: UUID) throws -> Data? {
        guard let data = try loadRecordData() else { return nil }
        let record = try decode(data)
        guard record.serverURL == serverURL.absoluteString,
              record.spaceID == spaceID.uuidString.lowercased() else {
            return nil
        }
        return record.material
    }

    func install(_ material: Data, serverURL: URL, spaceID: UUID) throws {
        guard material.count == 64,
              serverURL.scheme?.lowercased() == "https",
              serverURL.host != nil,
              serverURL.user == nil,
              serverURL.password == nil,
              serverURL.query == nil,
              serverURL.fragment == nil,
              !serverURL.absoluteString.hasSuffix("/") else {
            throw Failure.malformedRecord
        }
        let record = Record(
            schemaVersion: 1,
            serverURL: serverURL.absoluteString,
            spaceID: spaceID.uuidString.lowercased(),
            material: material)
        do {
            try keychain.storeItem(try JSONEncoder().encode(record), account: Self.account)
        } catch {
            throw Failure.keychainUnavailable
        }
    }

    func forget() throws {
        do { try keychain.deleteItem(account: Self.account) }
        catch { throw Failure.keychainUnavailable }
    }

    private func loadRecordData() throws -> Data? {
        do { return try keychain.loadItem(account: Self.account) }
        catch { throw Failure.keychainUnavailable }
    }

    private func decode(_ data: Data) throws -> Record {
        guard data.count <= 2_048,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "serverURL", "spaceID", "material"],
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schemaVersion == 1,
              record.material.count == 64,
              let server = URL(string: record.serverURL),
              server.scheme?.lowercased() == "https",
              server.host != nil,
              server.user == nil,
              server.password == nil,
              server.query == nil,
              server.fragment == nil,
              !record.serverURL.hasSuffix("/"),
              let space = UUID(uuidString: record.spaceID),
              space.uuidString.lowercased() == record.spaceID else {
            throw Failure.malformedRecord
        }
        return record
    }
}
