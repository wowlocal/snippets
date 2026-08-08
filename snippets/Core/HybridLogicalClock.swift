import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// A hybrid logical clock: a wall-clock reading that can only ever move forward,
/// disambiguated by a counter and then by device identity.
///
/// ## Why not just `updatedAt`
///
/// The merge in `SyncMerge` consults a clock only when *both* sides moved a field
/// away from their common ancestor, which is rare. But when it does, plain wall
/// time is not enough:
///
/// - Two edits inside the same millisecond compare equal, and a tie has no defined
///   winner, so two devices can converge on different answers. The counter fixes
///   the first case and the device id fixes the second, which is what makes the
///   merge *deterministic* rather than merely usually-right.
/// - `updatedAt` moves backwards. Undo restores an older `updatedAt` verbatim, and
///   a user who undoes a change on one device must beat the remote copy of the
///   change they just reverted. `stamp(updatedAt:baseHLC:)` guarantees a local
///   change never receives an HLC at or below its own ancestor's.
/// - A device with a badly wrong clock would otherwise poison every record it
///   touches, permanently. `observe` refuses to adopt a remote reading more than a
///   day ahead of local time.
///
/// The string form is fixed-width hex — 12 digits of milliseconds, 4 of counter,
/// 8 of device — so **lexicographic string comparison is exactly the total order**,
/// and the device tiebreak needs no special case anywhere.
nonisolated struct HLC: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {

    /// Milliseconds since the Unix epoch, capped to 48 bits (good past the year
    /// 10000, which is longer than JSON will exist).
    let wallMs: UInt64
    /// Disambiguates events within the same millisecond on the same device.
    let counter: UInt16
    /// Eight lowercase hex characters. Random per install, never the hardware UUID.
    let device: String

    /// The device id given to records written by something with no clock of its own:
    /// a stale CLI, `vim`, a Time Machine restore.
    ///
    /// All zeroes sorts strictly below every real device id.
    ///
    /// NOTE: `SyncMerge` deliberately does **not** use this to break ties. Doing so is
    /// asymmetric — each device would label its own record with the higher-sorting id,
    /// both would conclude they had won, and the two would rewrite the file at each
    /// other forever. `SyncMerge.localOutranksRemote` hashes the payloads instead. This
    /// constant remains for ordering records that genuinely arrived without a clock.
    static let foreignDevice = "00000000"

    init(wallMs: UInt64, counter: UInt16, device: String) {
        self.wallMs = min(wallMs, 0xFFFF_FFFF_FFFF)
        self.counter = counter
        self.device = HLC.normalizedDevice(device)
    }

    /// The synthesized clock for a record that arrived without one.
    static func foreign(updatedAt: Date) -> HLC {
        HLC(wallMs: updatedAt.millisecondsSince1970, counter: 0, device: foreignDevice)
    }

    var description: String { string }

    var string: String {
        String(format: "%012llx-%04hx-%@", wallMs, counter, device)
    }

    static func < (lhs: HLC, rhs: HLC) -> Bool {
        // Field-wise rather than on `string`: identical ordering, no formatting cost
        // on a path the merge runs per record per field.
        if lhs.wallMs != rhs.wallMs { return lhs.wallMs < rhs.wallMs }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.device < rhs.device
    }

    // MARK: - Codable
    //
    // Encoded as the single string, not as three keys: it is one value, it belongs in
    // a JSON field a human can read, and it keeps the wire envelope's key count fixed.

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = HLC(parsing: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "malformed HLC \"\(raw)\"; expected 12hex-4hex-8hex"))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    init?(parsing raw: String) {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 12, parts[1].count == 4, parts[2].count == 8,
              let wall = UInt64(parts[0], radix: 16),
              let counter = UInt16(parts[1], radix: 16),
              parts[2].allSatisfy(\.isHexDigit)
        else { return nil }
        self.init(wallMs: wall, counter: counter, device: String(parts[2]))
    }

    /// Eight lowercase hex characters, whatever was handed in. A malformed device id
    /// must not be able to break the fixed-width ordering invariant.
    ///
    /// The all-zero result is reserved for `foreignDevice`, so a real id can never
    /// land on it by accident. Without this guard any string containing no hex digits
    /// — including the empty string a truncated `state.json` yields — would normalize
    /// to all zeroes, and that Mac would silently lose every tie it ever entered.
    static func normalizedDevice(_ raw: String) -> String {
        let hex = raw.lowercased().filter(\.isHexDigit)
        let padded: String
        if hex.count == 8 { padded = hex }
        else if hex.count > 8 { padded = String(hex.prefix(8)) }
        else { padded = String(repeating: "0", count: 8 - hex.count) + hex }
        return padded == foreignDevice && raw != foreignDevice ? "00000001" : padded
    }

    /// A fresh, random device identity. Deliberately not derived from the hardware
    /// UUID: that is a stable cross-app identifier we have no business putting in a
    /// file, and it changes on a logic-board repair anyway.
    static func makeDeviceID() -> String {
        // Never mint the reserved foreign id, however unlikely a 1-in-4-billion draw is.
        var value = UInt32.random(in: UInt32.min...UInt32.max)
        if value == 0 { value = 1 }
        return String(format: "%08x", value)
    }
}

/// Issues monotonically increasing `HLC`s for one device.
///
/// Not thread-safe by construction: it is owned by `SnippetStore`, which is
/// `@MainActor`. Making it an actor would force every stamp to be `await`ed from
/// synchronous mutation paths that cannot suspend.
nonisolated final class HLCGenerator {

    /// Injected so tests can drive time by hand. Nothing in this type reads the
    /// system clock directly.
    var physicalNowMs: () -> UInt64

    /// How far ahead of us a remote reading may be before we refuse to adopt it.
    ///
    /// Without this, a single device with a clock set to 2099 would drag every
    /// device's clock to 2099 on first contact and keep it there forever — every
    /// subsequent local edit would carry a fabricated future timestamp, and the
    /// damage would be permanent and fleet-wide.
    static let maxDriftMs: UInt64 = 24 * 60 * 60 * 1000

    let device: String
    private(set) var last: HLC
    /// Diagnostics for the sync status pane; never affects behaviour.
    private(set) var rejectedSkewCount = 0

    init(device: String, persisted: HLC? = nil, physicalNowMs: @escaping () -> UInt64 = HLCGenerator.systemNowMs) {
        self.device = HLC.normalizedDevice(device)
        self.physicalNowMs = physicalNowMs
        // Start from whichever is later: what we persisted, or the wall clock. A
        // backwards NTP correction or a DST-confused clock must never let us reissue
        // a timestamp we have already used.
        let now = HLC(wallMs: physicalNowMs(), counter: 0, device: self.device)
        if let persisted, persisted > now {
            self.last = persisted
        } else {
            self.last = now
        }
    }

    static func systemNowMs() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1000))
    }

    /// The next clock reading for a locally originated change.
    @discardableResult
    func send() -> HLC {
        send(atLeast: physicalNowMs())
    }

    @discardableResult
    func send(atLeast floorMs: UInt64) -> HLC {
        let wall = max(physicalNowMs(), floorMs)
        if wall > last.wallMs {
            last = HLC(wallMs: wall, counter: 0, device: device)
        } else if last.counter == UInt16.max {
            // The counter is full for this millisecond. Carrying into `wallMs` keeps
            // the sequence strictly increasing; wrapping (`&+ 1` back to zero) would
            // silently reissue a reading already used 65 536 events ago and break the
            // one property the whole type exists to provide.
            last = HLC(wallMs: last.wallMs &+ 1, counter: 0, device: device)
        } else {
            // Same millisecond (or the clock went backwards): keep the reading and
            // advance the counter, which is the whole point of the hybrid design.
            last = HLC(wallMs: last.wallMs, counter: last.counter + 1, device: device)
        }
        return last
    }

    /// Stamps a local edit, guaranteeing the result is strictly greater than the
    /// record's own ancestor.
    ///
    /// This is what makes undo work under sync. `undo()` restores an older array
    /// verbatim, including its older `updatedAt`; stamping from `updatedAt` alone
    /// would produce a clock reading *below* the remote copy of the change being
    /// undone, and the merge would faithfully reinstate it.
    func stamp(updatedAt: Date, baseHLC: HLC?) -> HLC {
        let floor = max(updatedAt.millisecondsSince1970, (baseHLC?.wallMs ?? 0) &+ 1)
        return send(atLeast: floor)
    }

    /// Folds a clock reading seen from another device into ours.
    func observe(_ remote: HLC) {
        let now = physicalNowMs()
        guard remote.wallMs <= now &+ Self.maxDriftMs else {
            // Reject and carry on. Adopting it would be permanent; ignoring it costs
            // only that this one record's ordering falls back to the device tiebreak.
            rejectedSkewCount += 1
            return
        }
        guard remote > last else { return }
        last = HLC(wallMs: remote.wallMs, counter: remote.counter &+ 1, device: device)
    }
}

nonisolated extension Date {
    var millisecondsSince1970: UInt64 {
        let seconds = timeIntervalSince1970
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds * 1000, 0xFFFF_FFFF_FFFF))
    }
}
