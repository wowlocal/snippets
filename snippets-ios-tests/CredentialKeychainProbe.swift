import Foundation
import Security
@testable import Snippets

/// Dictionary-backed Security.framework boundary for one Snippets Cloud Keychain store.
///
/// Background reads of the accounts passed to `hold(_:)` block at the real synchronous
/// `SecItemCopyMatching` boundary until `release()`, with a bounded escape so a
/// regression fails the test instead of hanging the simulator host. Main-thread reads
/// never block; they are recorded so a test can prove a phase stayed off MainActor.
/// Every operation is logged in completion order with the thread it ran on.
nonisolated final class CredentialKeychainProbe: @unchecked Sendable {
    enum Kind: Equatable { case read, write, delete }

    struct Operation: Equatable {
        let kind: Kind
        let account: String
        let onMainThread: Bool
    }

    private let condition = NSCondition()
    private var items: [String: Data] = [:]
    private var held: Set<String> = []
    private var entered = false
    private var log: [Operation] = []

    /// True once a background read of a held account is waiting at the boundary.
    var hasEnteredHeldRead: Bool { condition.withLock { entered } }
    var operations: [Operation] { condition.withLock { log } }

    func hold(_ accounts: Set<String>) {
        condition.withLock {
            held = accounts
            entered = false
        }
    }

    func release() {
        condition.withLock {
            held = []
            condition.broadcast()
        }
    }

    func clearLog() { condition.withLock { log = [] } }

    /// Test-side inspection that does not pass through, or appear in, the log.
    func storedValue(for account: String) -> Data? { condition.withLock { items[account] } }

    func keychain() -> KeychainSecretStore {
        KeychainSecretStore(
            tier: .deviceOnly,
            service: "credential-keychain-probe",
            itemAccessibility: .afterFirstUnlock,
            keychainOperations: KeychainItemOperations(
                copyMatching: { [self] query, result in copyMatching(query, result) },
                update: { [self] query, values in update(query, values) },
                add: { [self] attributes, _ in add(attributes) },
                delete: { [self] query in delete(query) }))
    }

    private func account(in query: CFDictionary) -> String? {
        (query as NSDictionary)[kSecAttrAccount] as? String
    }

    private func copyMatching(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        guard let account = account(in: query) else { return errSecParam }
        let attributes = query as NSDictionary
        let onMainThread = Thread.isMainThread
        condition.lock()
        defer { condition.unlock() }
        if !onMainThread, held.contains(account) {
            entered = true
            let deadline = Date().addingTimeInterval(5)
            while held.contains(account) {
                if !condition.wait(until: deadline) { break }
            }
        }
        log.append(Operation(kind: .read, account: account, onMainThread: onMainThread))
        guard let data = items[account] else { return errSecItemNotFound }
        if attributes[kSecReturnAttributes] as? Bool == true {
            result?.pointee = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary
        } else if attributes[kSecReturnData] as? Bool == true {
            result?.pointee = data as CFData
        }
        return errSecSuccess
    }

    private func update(_ query: CFDictionary, _ values: CFDictionary) -> OSStatus {
        guard let account = account(in: query) else { return errSecParam }
        let onMainThread = Thread.isMainThread
        return condition.withLock {
            guard items[account] != nil else { return errSecItemNotFound }
            if let data = (values as NSDictionary)[kSecValueData] as? Data {
                items[account] = data
                log.append(Operation(kind: .write, account: account, onMainThread: onMainThread))
            }
            return errSecSuccess
        }
    }

    private func add(_ attributes: CFDictionary) -> OSStatus {
        guard let account = account(in: attributes),
              let data = (attributes as NSDictionary)[kSecValueData] as? Data else {
            return errSecParam
        }
        let onMainThread = Thread.isMainThread
        return condition.withLock {
            guard items[account] == nil else { return errSecDuplicateItem }
            items[account] = data
            log.append(Operation(kind: .write, account: account, onMainThread: onMainThread))
            return errSecSuccess
        }
    }

    private func delete(_ query: CFDictionary) -> OSStatus {
        guard let account = account(in: query) else { return errSecParam }
        let onMainThread = Thread.isMainThread
        return condition.withLock {
            log.append(Operation(kind: .delete, account: account, onMainThread: onMainThread))
            return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

extension CredentialKeychainProbe {
    /// The three items the Snippets Cloud credential lineage preflight inspects.
    @MainActor
    static var lineageAccounts: Set<String> {
        [
            SyncBackendSelectionStore.oauthSessionAccount,
            SyncBackendSelectionStore.oauthSessionReplacementAccount,
            SyncBackendSelectionStore.oauthRevocationAccount,
        ]
    }

    /// Lineage reads (session, replacement, revocation) that ran on the main thread.
    @MainActor
    var mainThreadLineageReads: [Operation] {
        let lineage = Self.lineageAccounts
        return operations.filter {
            $0.kind == .read && $0.onMainThread && lineage.contains($0.account)
        }
    }
}
