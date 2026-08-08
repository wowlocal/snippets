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
/// end up on the winner. What is left over is records pushed under the losing key, which
/// stay unreadable until they are edited or the base is cleared. Stated rather than
/// engineered around: distributed consensus over a keychain item is not worth building
/// for a window that size.
@MainActor
final class SyncKeyStore {

    /// Fixed. Also the `scopeID` bound into every envelope's AAD — see
    /// `SnippetCryptoSealer.scopeID` for why a scope must come from somewhere that
    /// cannot regenerate itself, which a constant trivially satisfies.
    static let account = "sync-v1"

    /// 32 bytes of key followed by 32 bytes of HKDF salt, exactly what
    /// `SnippetCrypto.Keyring.generate()` produces.
    private static let materialByteCount =
        SnippetCrypto.keyByteCount + SnippetCrypto.saltByteCount

    enum Failure: Error, CustomStringConvertible {
        case malformedMaterial(Int)
        case keychain(String)

        var description: String {
            switch self {
            case .malformedMaterial(let count):
                return "the stored sync key must be \(SyncKeyStore.materialByteCount) bytes; found \(count)"
            case .keychain(let detail):
                return "the keychain refused the sync key: \(detail)"
            }
        }
    }

    var scopeID: String { Self.account }

    private let keychain: KeychainSecretStore

    init(keychain: KeychainSecretStore) {
        self.keychain = keychain
    }

    /// The stored key material, or `nil` when this Mac has none yet.
    ///
    /// Returned as bytes rather than as a `Keyring` so `SyncCoordinator` can compare it
    /// against what its engine was built with. A `SymmetricKey` is not `Equatable` in a
    /// way that helps, and the comparison is the whole point.
    func material() throws -> Data? {
        do {
            guard let stored = try keychain.loadItem(account: Self.account) else { return nil }
            guard stored.count == Self.materialByteCount else {
                throw Failure.malformedMaterial(stored.count)
            }
            return stored
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.keychain("\(error)")
        }
    }

    /// The wire key, minting and storing one on first use.
    ///
    /// No user presence, deliberately — see the type's documentation. Background rounds
    /// run every two minutes and must not raise a Touch ID sheet over whatever the user
    /// is actually doing.
    func materialMintingIfNeeded() throws -> Data {
        if let existing = try material() { return existing }

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
            throw Failure.keychain("\(error)")
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
            NSLog("Snippets: the sync key could not be removed (\(error)).")
        }
    }
}
