#if DEBUG
import CryptoKit
import Foundation

/// Exercises the real Keychain from inside the signed app.
///
/// `swift test` and a bare `swiftc` harness both run unsigned, so they can only reach
/// the login-keychain tier — `KeychainSecretStore.detectTier()` correctly reports
/// `.deviceOnly` for them. The data-protection tier, which is the one that carries the
/// vault key to the user's other Macs through iCloud Keychain, requires the app's
/// entitlements and therefore cannot be reached from any test harness at all.
///
/// So this runs in the app, behind `--keychain-selftest`, and is compiled out of release.
///
/// It uses a unique account id per run and deletes what it creates. On the
/// synchronizable tier both the write and the delete propagate through iCloud Keychain,
/// so a throwaway item exists on the user's other devices for a few seconds.
@MainActor
enum KeychainSelfCheck {

    static func run() {
        let store = KeychainSecretStore()
        let keyID = "k-selftest-\(UUID().uuidString.prefix(8))"
        var failures = 0

        func check(_ label: String, _ ok: Bool) {
            print("  \(ok ? "PASS" : "FAIL")  \(label)")
            if !ok { failures += 1 }
        }

        print("tier: \(store.tier)")
        print("syncs between devices: \(store.tier.syncsBetweenDevices)")

        do {
            check("no key before storing", !store.hasKey(keyID: keyID))

            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try store.store(key, keyID: keyID)
            check("hasKey after storing", store.hasKey(keyID: keyID))
            check("round-trips the exact 32 bytes", try store.loadKey(keyID: keyID) == key)

            // Replacing must update in place. A second item under the same account would
            // make `loadKey` depend on which one the keychain happened to return first —
            // and on the synchronizable tier, on which device won the race.
            let replacement = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try store.store(replacement, keyID: keyID)
            check("replacing yields the new key", try store.loadKey(keyID: keyID) == replacement)

            try store.deleteKey(keyID: keyID)
            check("gone after delete", !store.hasKey(keyID: keyID))

            do {
                _ = try store.loadKey(keyID: keyID)
                check("reading a deleted key throws", false)
            } catch KeychainSecretStore.Failure.notFound {
                check("reading a deleted key throws .notFound", true)
            }

            try store.deleteKey(keyID: keyID)
            check("deleting twice is tolerated", true)
        } catch {
            print("  FAIL  threw: \(error)")
            failures += 1
            try? store.deleteKey(keyID: keyID)
        }

        print(failures == 0 ? "ALL KEYCHAIN CHECKS PASSED" : "\(failures) KEYCHAIN CHECK(S) FAILED")
    }
}
#endif
