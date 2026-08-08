import Darwin
import Foundation

/// Best-effort erasure for Foundation buffers that temporarily carry plaintext.
///
/// `Data` is copy-on-write, so this can overwrite the buffer owned by this value but
/// cannot prove that Foundation or CryptoKit never made another copy. The expansion
/// path therefore moves plaintext into `SecurePlaintextLease` immediately; that lease
/// owns a raw allocation whose lifetime and erasure we do control.
nonisolated enum SecureMemory {
    static func wipe(_ address: UnsafeMutableRawPointer, byteCount: Int) {
        guard byteCount > 0 else { return }
        // C11 Annex K requires this write to be observable, so the optimiser may not
        // remove it merely because the allocation is about to be released.
        _ = memset_s(address, byteCount, 0, byteCount)
    }

    static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = buffer.baseAddress, !buffer.isEmpty else { return }
            wipe(baseAddress, byteCount: buffer.count)
        }
        data.removeAll(keepingCapacity: false)
    }
}

/// A one-owner, one-use plaintext buffer for authenticated secure expansion.
///
/// The decrypted `Data` is copied into a private raw allocation and wiped during
/// construction. `wipe()` uses `memset_s`, which the compiler is forbidden to
/// optimise away, then frees the allocation. `deinit` is a backstop for cancellation
/// and every early-return path.
///
/// The lease is intentionally not thread-safe. It is created, read, and explicitly
/// wiped on the main actor; `nonisolated` only keeps its low-level storage semantics
/// independent of the app target's default actor-isolation build setting.
nonisolated final class SecurePlaintextLease {
    private var storage: UnsafeMutableRawPointer?
    private let byteCount: Int
    private(set) var isWiped = false

    init(consuming plaintext: inout Data) {
        byteCount = plaintext.count
        let allocation = UnsafeMutableRawPointer.allocate(
            byteCount: max(byteCount, 1),
            alignment: MemoryLayout<UInt8>.alignment
        )
        storage = allocation

        if byteCount > 0 {
            plaintext.withUnsafeBytes { source in
                guard let baseAddress = source.baseAddress else { return }
                allocation.copyMemory(from: baseAddress, byteCount: byteCount)
            }
        }
        SecureMemory.wipe(&plaintext)
    }

    /// The only intentional conversion to an unwipeable Swift `String`. Call as late
    /// as possible and discard the returned value immediately after insertion.
    func makeUTF8String() -> String? {
        guard !isWiped, let storage else { return nil }
        let bytes = UnsafeRawBufferPointer(start: storage, count: byteCount)
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Idempotent so both the injection operation and its cancellation backstop can
    /// call it without coordinating ownership.
    func wipe() {
        guard let storage else {
            isWiped = true
            return
        }
        SecureMemory.wipe(storage, byteCount: byteCount)
        storage.deallocate()
        self.storage = nil
        isWiped = true
    }

    deinit {
        wipe()
    }
}
