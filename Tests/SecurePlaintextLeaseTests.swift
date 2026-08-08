import Foundation

// Standalone executable. Build and run:
//
//   swiftc -O snippets/Vault/SecurePlaintextLease.swift \
//          Tests/SecurePlaintextLeaseTests.swift -o /tmp/secure-plaintext-lease-tests \
//          && /tmp/secure-plaintext-lease-tests

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) - expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum SecurePlaintextLeaseTests {
    static func main() {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 1)
        raw.initializeMemory(as: UInt8.self, repeating: 0xA5, count: 8)
        SecureMemory.wipe(raw, byteCount: 8)
        let wipedBytes = UnsafeRawBufferPointer(start: raw, count: 8)
        assertTrue(wipedBytes.allSatisfy { $0 == 0 }, "the secure erase primitive overwrites every byte")
        raw.deallocate()

        var source = Data("correct horse battery staple".utf8)
        let lease = SecurePlaintextLease(consuming: &source)

        assertTrue(source.isEmpty, "construction discards the decrypted Data")
        assertEqual(
            lease.makeUTF8String(),
            "correct horse battery staple",
            "the owned bytes decode exactly once while live"
        )

        lease.wipe()
        assertTrue(lease.isWiped, "explicit wipe marks the lease consumed")
        assertEqual(lease.makeUTF8String(), nil, "wiped plaintext cannot be materialized")

        lease.wipe()
        assertTrue(lease.isWiped, "wipe is idempotent for layered cleanup")

        var invalid = Data([0xC3, 0x28])
        let invalidLease = SecurePlaintextLease(consuming: &invalid)
        assertEqual(invalidLease.makeUTF8String(), nil, "invalid UTF-8 is refused")
        invalidLease.wipe()

        print("SecurePlaintextLease tests passed")
    }
}
