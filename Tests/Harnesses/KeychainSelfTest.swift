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

            try checkItems(store, check)
            print("ALL KEYCHAIN CHECKS PASSED")
        } catch {
            print("  FAIL  threw: \(error)")
            try? store.deleteKey(keyID: keyID)
            exit(1)
        }
    }

    /// The generic item path, which the sync key and the vault identity ride on.
    ///
    /// Worth exercising separately from the key path even though one calls the other:
    /// these carry payloads the 32-byte guard would have rejected, and `addItemIfAbsent`
    /// has semantics — refuse to clobber, return the incumbent — that no other call has.
    @MainActor
    private static func checkItems(
        _ store: KeychainSecretStore, _ check: (String, Bool) -> Void
    ) throws {
        let account = "item-selftest-\(UUID().uuidString.prefix(8))"
        defer { try? store.deleteItem(account: account) }

        check("no item before storing", !store.hasItem(account: account))
        check("loading an absent item is nil", try store.loadItem(account: account) == nil)

        // A vault identity is JSON of no fixed size, which is the point of a path with
        // no length guard on it.
        let identity = Data("{\"kid\":\"k-abc\",\"schemaVersion\":1}".utf8)
        try store.storeItem(identity, account: account)
        check("hasItem after storing", store.hasItem(account: account))
        check("round-trips a variable-length payload", try store.loadItem(account: account) == identity)

        let replacement = Data(repeating: 0xA5, count: 64)
        try store.storeItem(replacement, account: account)
        check("storeItem replaces in place", try store.loadItem(account: account) == replacement)
        do {
            _ = try store.loadItem(account: account, expectedByteCount: 63)
            check("a fixed-width item is validated before use", false)
        } catch KeychainSecretStore.Failure.invalidItemLength(63, 64) {
            check("a fixed-width item is validated before use", true)
        }

        // The whole reason this call exists: two Macs must not each mint a wire key. The
        // incumbent wins and is handed back, rather than being overwritten.
        let rival = Data(repeating: 0x5A, count: 64)
        let winner = try store.addItemIfAbsent(rival, account: account)
        check("addItemIfAbsent keeps the incumbent", winner == replacement)
        check("addItemIfAbsent did not overwrite", try store.loadItem(account: account) == replacement)

        try store.deleteItem(account: account)
        check("item gone after delete", !store.hasItem(account: account))

        let minted = try store.addItemIfAbsent(rival, account: account)
        check("addItemIfAbsent stores when absent", minted == rival)
        check("addItemIfAbsent is readable afterwards", try store.loadItem(account: account) == rival)

        try store.deleteItem(account: account)
        try store.deleteItem(account: account)
        check("deleting an item twice is tolerated", true)
    }
}
