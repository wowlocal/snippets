// Exercises the real macOS Keychain, which no unit test can.
//
// `swift test` uses InMemorySecretStore and cannot exercise Security.framework. The
// data-protection tier also returns errSecMissingEntitlement (-34018) without its
// application-identifier entitlement. This harness exercises the real entitlement-free
// login-keychain tier instead.
//
//   swiftc -O snippets/Vault/KeychainSecretStore.swift Tests/Harnesses/KeychainSelfTest.swift \
//          -o /tmp/kctest && /tmp/kctest
//
// The Keychain item itself deliberately has no biometric access-control attribute:
// those attributes require the data-protection keychain and cannot be synchronizable.
// VaultSession enforces human presence separately with LocalAuthentication. That
// interactive path is not covered here. A unique account id per run avoids real vault
// keys, and this harness deletes what it creates.
//
// WHAT THIS DOES NOT COVER: VaultSession's human prompt, or the data-protection tier,
// which needs an entitlement this build does not have. Both still require manual
// verification on a signed, stapled build.

import Foundation
import CryptoKit

@main
struct KeychainSelfTest {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    static func run() {

        let store = KeychainSecretStore()
        let keyID = "k-selftest-\(UUID().uuidString.prefix(8))"
        print("tier: \(store.tier)")
        print("syncs between devices: \(store.tier.syncsBetweenDevices)")

        func check(_ label: String, _ ok: Bool) {
            print("  \(ok ? "PASS" : "FAIL")  \(label)")
            if !ok { exit(1) }
        }

        do {
            check("no key before storing", !store.hasKey(keyID: keyID))

            do {
                try store.store(Data(repeating: 0, count: 31), keyID: keyID)
                check("a malformed key is rejected", false)
            } catch KeychainSecretStore.Failure.invalidKeyLength(31) {
                check("a malformed key is rejected before touching Keychain", true)
            }

            let key = SymmetricKey(size: .bits256)
            let bytes = key.withUnsafeBytes { Data($0) }
            try store.store(bytes, keyID: keyID)
            check("hasKey after storing", store.hasKey(keyID: keyID))

            let round = try store.loadKey(keyID: keyID)
            check("round-trips the exact 32 bytes", round == bytes)
            check("is 256 bits", round.count == 32)

            // Replacing must not duplicate: a second item under the same account would make
            // loadKey's result depend on which one the keychain returned first.
            let second = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try store.store(second, keyID: keyID)
            check("replacing yields the new key", try store.loadKey(keyID: keyID) == second)

            try store.deleteKey(keyID: keyID)
            check("gone after delete", !store.hasKey(keyID: keyID))

            do {
                _ = try store.loadKey(keyID: keyID)
                check("reading a deleted key throws", false)
            } catch KeychainSecretStore.Failure.notFound {
                check("reading a deleted key throws .notFound", true)
            }

            // Deleting twice must be tolerated — quitting mid-teardown would otherwise leave
            // the app unable to clean up.
            try store.deleteKey(keyID: keyID)
            check("deleting twice is tolerated", true)
            print("ALL KEYCHAIN CHECKS PASSED")
        } catch {
            print("  FAIL  threw: \(error)")
            try? store.deleteKey(keyID: keyID)
            exit(1)
        }
    }
}
