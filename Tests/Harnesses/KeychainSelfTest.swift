// Exercises the real macOS Keychain, which no unit test can.
//
// `swift test` runs unsigned, so the data-protection keychain returns
// errSecMissingEntitlement (-34018) and every test uses InMemorySecretStore instead.
// That leaves the code that actually stores and retrieves the vault key with no runtime
// coverage at all — which is why this exists.
//
//   swiftc -O snippets/Vault/KeychainSecretStore.swift Tests/Harnesses/KeychainSelfTest.swift \
//          -o /tmp/kctest && /tmp/kctest
//
// Every item uses `requireBiometry: false`, so nothing here can raise a Touch ID prompt,
// and a unique account id per run means it cannot collide with a real vault key. It
// deletes what it creates.
//
// WHAT THIS DOES NOT COVER: the biometry-gated path. An item stored with
// `requireBiometry: true` carries a SecAccessControl, and reading it raises a system
// prompt that only a human can answer. That path — and the data-protection tier, which
// needs an entitlement this build does not have — still require manual verification on a
// signed, stapled build.

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

            let key = SymmetricKey(size: .bits256)
            let bytes = key.withUnsafeBytes { Data($0) }
            try store.store(bytes, keyID: keyID, requireBiometry: false)
            check("hasKey after storing", store.hasKey(keyID: keyID))

            let round = try store.loadKey(keyID: keyID, reason: "self-test")
            check("round-trips the exact 32 bytes", round == bytes)
            check("is 256 bits", round.count == 32)

            // Replacing must not duplicate: a second item under the same account would make
            // loadKey's result depend on which one the keychain returned first.
            let second = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try store.store(second, keyID: keyID, requireBiometry: false)
            check("replacing yields the new key", try store.loadKey(keyID: keyID, reason: "self-test") == second)

            try store.deleteKey(keyID: keyID)
            check("gone after delete", !store.hasKey(keyID: keyID))

            do {
                _ = try store.loadKey(keyID: keyID, reason: "self-test")
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
