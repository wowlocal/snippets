// Exercises the real macOS notification centres and names used by VaultSession.
//
// The iOS unit target can deterministically test deadlines, key destruction and its
// own lifecycle notifications, but it does not compile the `#if os(macOS)` observer
// wiring. Keep this tiny harness beside the other unsigned platform checks:
//
//   swiftc -O \
//     snippets/Vault/KeychainSecretStore.swift \
//     snippets/Vault/VaultSession.swift \
//     Tests/Harnesses/VaultSessionAutoLockTest.swift \
//     -o /tmp/vault-session-autolock-test \
//     && /tmp/vault-session-autolock-test
//
// It uses KeychainSecretStore's in-memory backend, so it neither prompts nor creates a
// real keychain item. LocalAuthentication itself is replaced only by VaultSession's
// existing evaluator seam; the notification centres and VaultSession implementation
// are production code.

import AppKit
import CryptoKit
import Foundation

@main
struct VaultSessionAutoLockTest {
    @MainActor
    static func main() async {
        var failures = 0

        func check(_ label: String, _ condition: @autoclosure () -> Bool) {
            let passed = condition()
            print("  \(passed ? "PASS" : "FAIL")  \(label)")
            if !passed { failures += 1 }
        }

        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.autolock-harness",
            inMemory: true)
        let keyID = "autolock-harness"
        do {
            try keychain.store(Data(repeating: 0xA5, count: 32), keyID: keyID)
        } catch {
            print("  FAIL  could not prepare in-memory key: \(error)")
            exit(1)
        }

        let session = VaultSession(
            keychain: keychain,
            authenticationEvaluator: { _ in true })
        session.adopt(keyID: keyID)

        func unlock() async -> Bool {
            do {
                _ = try await session.unlock(reason: "Auto-lock harness")
                return session.state.isUnlocked
            } catch {
                print("  FAIL  unlock threw: \(error)")
                failures += 1
                return false
            }
        }

        func waitForDistributedLock() {
            let deadline = Date().addingTimeInterval(1)
            while session.state.isUnlocked, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }

        _ = await unlock()
        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: nil)
        check("ordinary app resign-active does not lock", session.state.isUnlocked)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        check("machine sleep locks", session.state == .locked)

        _ = await unlock()
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        check("login session resign locks", session.state == .locked)

        let distributed = DistributedNotificationCenter.default()
        _ = await unlock()
        distributed.postNotificationName(
            Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
        waitForDistributedLock()
        check("screen lock locks", session.state == .locked)

        _ = await unlock()
        distributed.postNotificationName(
            Notification.Name("com.apple.screensaver.didstart"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
        waitForDistributedLock()
        check("screensaver start locks", session.state == .locked)

        print(failures == 0
              ? "ALL VAULT SESSION AUTO-LOCK CHECKS PASSED"
              : "\(failures) CHECK(S) FAILED")
        if failures > 0 { exit(1) }
    }
}

// VaultSession's two production dependencies that are irrelevant to this harness. The
// real app supplies these from Core; defining the narrow shapes here lets swiftc build
// the production session file without pulling the entire app and a second @main into an
// unsigned command-line executable.
enum SecureMemory {
    static func wipe(_ data: inout Data) {
        data.resetBytes(in: data.startIndex..<data.endIndex)
        data.removeAll(keepingCapacity: false)
    }
}

enum SyncKeyStore {
    static let account = "sync-v1"
}

enum SnippetCrypto {
    struct Keyring {
        init(libraryKey: SymmetricKey, salt: Data) {}
    }
}

enum VaultDiagnosticAction {
    case locked
    case unlocked
}

enum VaultHarnessDiagnosticEvent {
    case vaultAction(VaultDiagnosticAction, count: Int?)
}

enum Diagnostics {
    static func record(_ event: VaultHarnessDiagnosticEvent) {}
}
