import Foundation

/// Carries the vault's *identity* — `vault.json` with its records removed — to the
/// user's other Macs, so a second Mac adopts the existing vault instead of minting a
/// rival one.
///
/// ## The problem this exists to remove
///
/// `K_lib` already travels: `KeychainSecretStore` stores it with
/// `kSecAttrSynchronizable` whenever the entitlement is present, and iCloud Keychain
/// delivers it. What did not travel was the *name of the lock it opens*. A second Mac
/// with no `vault.json` called `createVaultIfNeeded`, which minted a fresh `kid` and a
/// fresh key — and since `kid` is the crypto scope bound into every AAD, the two Macs
/// could not read each other's records at all. Settings told the user to copy
/// `Vault/vault.json` across by hand.
///
/// That instruction was carrying about six hundred bytes of **non-secret** metadata — a
/// salt, KDF parameters, and wraps that are useless without the key — over a channel
/// already open for the actual secret. This closes it.
///
/// ## Why the Keychain and not CloudKit
///
/// The identity has to be readable *before* the first sync round, because it is what
/// decides whether this Mac has a vault at all. Putting it in CloudKit means a fetch
/// that needs a sealer that needs a vault: a bootstrap loop. The Keychain has none of
/// that, needs no schema, adds no entitlement, and is end-to-end encrypted between the
/// user's devices rather than merely encrypted to Apple.
///
/// ## First publisher wins
///
/// A published identity is never overwritten with a *different* `kid`. Two Macs that
/// each minted a vault before this shipped therefore keep whichever one published
/// first, and the other Mac's local vault is left completely alone — its records are
/// the only copy of secrets that exist nowhere else, and silently re-pointing it at a
/// key it was not encrypted under would destroy them. That state is reported rather
/// than repaired; the recovery key is the way out.
@MainActor
final class VaultIdentityStore {

    /// Fixed, because there is exactly one vault identity per iCloud account. A varying
    /// name would mean two Macs could never find each other's.
    static let account = "vault-identity"

    private let keychain: KeychainSecretStore

    init(keychain: KeychainSecretStore) {
        self.keychain = keychain
    }

    /// The shared identity, or `nil` when there is none, it cannot be read, or it was
    /// written by a build whose format this one does not understand.
    ///
    /// Deliberately non-throwing. Every caller's fallback is "behave as it did before
    /// this type existed", and a keychain hiccup must not be able to stop a vault being
    /// created or a snippet being saved.
    func published() -> VaultDocument? {
        let data: Data?
        do {
            data = try keychain.loadItem(account: Self.account)
        } catch {
            Diagnostics.record(.storageFailure(
                area: .vaultIdentity,
                operation: .read,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return nil
        }
        guard let data else { return nil }

        // Same rule as `VaultFile.load`: probe the version before decoding, so a newer
        // format lands in "this build is too old" rather than in "the bytes are broken".
        if let version = VaultFile.probeSchemaVersion(data),
           version > VaultDocument.currentSchemaVersion {
            Diagnostics.record(.storageState(
                area: .vaultIdentity,
                state: .versionTooNew,
                value: version))
            return nil
        }
        do {
            return try VaultFile.decode(data)
        } catch {
            Diagnostics.record(.storageFailure(
                area: .vaultIdentity,
                operation: .read,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return nil
        }
    }

    /// Publishes this vault's identity, unless a different vault already holds the slot.
    ///
    /// Best-effort by design: the return value says what happened, and no caller treats
    /// a `false` as a reason to fail the operation it was part of. Re-publishing an
    /// identity that is already current is a no-op, so this is cheap enough to call from
    /// `reload()` and thereby self-heal a slot some other Mac deleted.
    @discardableResult
    func publish(_ document: VaultDocument) -> Bool {
        var identity = document
        // The records are what sync carries. A keychain item is not a database, and a
        // vault's worth of ciphertext does not belong in one.
        identity.records = []
        // `wrapPass` is the one field that must not go, and the reason is the field's
        // entire purpose: `VaultDocument` calls a passphrase "the only thing that keeps
        // the secrets out of reach of the iCloud account itself". Publishing a wrap
        // stretched from something a human chose, into the iCloud account it exists to
        // be independent of, would hand an attacker who reaches that account an offline
        // guessing target. `wrapRecovery` and `wrapCLI` are keyed by 128 and 256 bits of
        // stored randomness, so they carry no such risk and go — the recovery wrap is
        // exactly what a second Mac needs when iCloud Keychain did not deliver the key.
        //
        // No UI creates a passphrase wrap today. This is here so that whichever one does
        // cannot silently undo the guarantee it was added for.
        identity.wrapPass = nil

        // The keychain is read every time, deliberately.
        //
        // An in-process cache of "what I last published" lived here and was wrong: the
        // slot can be emptied by *another Mac* — an older build's `forgetEverything` or
        // a direct Keychain deletion propagates that removal — and a cache short-circuits
        // before the read that would notice. The self-heal this method exists to provide (a Mac holding a
        // real vault re-publishes an identity someone else cleared) then never ran until
        // the app was relaunched, and a third Mac meanwhile minted a rival `kid`.
        //
        // The cost is one `SecItemCopyMatching` and a small JSON decode per `reload()`,
        // which is sub-millisecond and not on any hot path. Correctness is worth more
        // than that here, and a cache that can be invalidated by another machine is not a
        // cache this type can hold.
        var valueToPublish = identity
        if let existing = published() {
            guard existing.kid == identity.kid else {
                Diagnostics.record(.storageState(
                    area: .vaultIdentity,
                    state: .degraded,
                    value: nil))
                return false
            }
            guard let merged = VaultDocument.mergingSharedIdentity(
                existing: existing, candidate: identity)
            else {
                // A same-`kid` document with a different salt or KDF is corrupt or from
                // an incompatible writer. Overwriting either direction would advertise
                // wraps and records under an identity they cannot open.
                Diagnostics.record(.storageState(
                    area: .vaultIdentity,
                    state: .degraded,
                    value: nil))
                return false
            }
            if existing == merged { return true }
            valueToPublish = merged
        }

        do {
            try keychain.storeItem(
                try VaultFile.encode(valueToPublish), account: Self.account)
            Diagnostics.record(.vaultAction(.publishedSharedIdentity, count: nil))
            return true
        } catch {
            Diagnostics.record(.storageFailure(
                area: .vaultIdentity,
                operation: .publish,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return false
        }
    }

    /// Drops an identity that is no longer usable on the current Keychain tier.
    /// Synchronizable-vault teardown deliberately does not call this: deleting a shared
    /// slot would propagate account-wide. This remains for device-only teardown and
    /// explicit reset or migration tools.
    func forget() {
        do {
            try keychain.deleteItem(account: Self.account)
            Diagnostics.record(.vaultAction(.removedSharedIdentity, count: nil))
        } catch {
            Diagnostics.record(.storageFailure(
                area: .vaultIdentity,
                operation: .remove,
                failure: DiagnosticFailure(error),
                attempt: nil))
        }
    }
}
