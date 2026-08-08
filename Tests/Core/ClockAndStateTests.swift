import Foundation
import Testing

@testable import SnippetsCore

// Covers the two pieces of the sync foundation that everything else is calibrated
// against: the hybrid logical clock (`HybridLogicalClock.swift`) and this device's
// own bookkeeping file (`SyncStateFile.swift`), plus the storage layout both of
// them live in (`SnippetStorageLocations`).
//
// Nothing here reads the system clock or the real support folder: `HLCGenerator`
// takes an injected `physicalNowMs`, and `SyncStateFile` takes both an injected URL
// and an injected `temporaryDirectory`. The latter parameter was added while writing
// these tests: without it, every state write staged inside the user's real
// `~/Library/Application Support/SnippetsClone` no matter where `url` pointed.

// MARK: - Deterministic randomness
//
// Same xorshift as `Tests/SnippetFrecencyTests.swift`. Property tests over a clock
// are only useful if a failure reproduces, and a seeded generator means a red run
// names the exact input.

private struct ClockRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func uInt64(below bound: UInt64) -> UInt64 {
        bound == 0 ? 0 : next() % bound
    }

    mutating func deviceID() -> String {
        String(format: "%08x", UInt32(truncatingIfNeeded: next()))
    }

    /// 2020-01-01, and a fifteen-year span. Wall readings are kept inside the range
    /// a shipping build can actually produce; the 48-bit saturation edge is a
    /// separate, explicit case rather than something a property test stumbles into.
    static let epochFloorMs: UInt64 = 1_577_836_800_000
    static let epochSpanMs: UInt64 = 15 * 365 * 24 * 60 * 60 * 1000

    mutating func hlc() -> HLC {
        HLC(
            wallMs: ClockRandom.epochFloorMs + uInt64(below: ClockRandom.epochSpanMs),
            counter: UInt16(truncatingIfNeeded: next()),
            device: deviceID())
    }

    /// Draws from a tiny pool so exact ties and one-bit differences are common.
    /// Ordering bugs hide next to equality, not out in the open.
    mutating func clusteredHLC() -> HLC {
        let devices = ["00000000", "00000001", "0fffffff", "10000000", "fffffffe", "ffffffff"]
        return HLC(
            wallMs: ClockRandom.epochFloorMs + uInt64(below: 3),
            counter: UInt16(uInt64(below: 3)),
            device: devices[Int(uInt64(below: UInt64(devices.count)))])
    }
}

// MARK: - A physical clock the test moves by hand

/// `HLCGenerator` never reads the system clock; it calls this. Freezing it, stepping
/// it back, and jumping it by hours is how the NTP and DST cases below are staged.
private final class ManualPhysicalClock {
    private(set) var nowMs: UInt64

    init(nowMs: UInt64) { self.nowMs = nowMs }

    func set(_ ms: UInt64) { nowMs = ms }
    func advance(by ms: UInt64) { nowMs &+= ms }
    func rewind(by ms: UInt64) { nowMs &-= ms }

    var reader: () -> UInt64 { { [self] in self.nowMs } }
}

// MARK: - Scratch directory
//
// Tests run in parallel, so every filesystem test gets its own directory and takes
// it away again.

private struct ScratchDirectory {
    let url: URL

    init(_ label: String) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippets-clock-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name, isDirectory: false) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func date(ms: UInt64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

/// Trailing-slash-free, lexically standardized path. Used to compare a folder URL
/// against a file URL's parent without tripping over `file:///a/b/` vs `file:///a/b`.
private func normalizedPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
}

private extension SyncStateFile.Outcome {
    var loadedState: SyncState? {
        if case .loaded(let state) = self { return state }
        return nil
    }

    var freshState: SyncState? {
        if case .fresh(let state) = self { return state }
        return nil
    }

    var tooNewVersion: Int? {
        if case .tooNew(let version) = self { return version }
        return nil
    }
}

@Suite("HLC, sync state, and storage layout")
struct ClockAndStateTests {

    // MARK: - Wire format and total order

    @Suite("HLC wire format")
    struct WireFormat {

        /// The fixed-width form is a load-bearing promise, not cosmetics: the merge
        /// compares field-wise for speed while anything downstream (a backend that
        /// sorts keys as text, `jq`, a shell script picking the newest record) sorts
        /// the strings. If the two orders ever disagreed, two devices would pick
        /// different winners for the same pair and sync would stop converging.
        @Test func lexicographicStringOrderIsExactlyTheComparableOrder() {
            var random = ClockRandom(seed: 0xC10C_C10C)
            var clocks: [HLC] = [
                HLC(wallMs: 0, counter: 0, device: "00000000"),
                HLC(wallMs: 0, counter: .max, device: "ffffffff"),
                HLC(wallMs: 0xFFFF_FFFF_FFFF, counter: 0, device: "00000000"),
                HLC(wallMs: 0xFFFF_FFFF_FFFF, counter: .max, device: "ffffffff"),
            ]
            for _ in 0..<4_000 { clocks.append(random.hlc()) }
            for _ in 0..<2_000 { clocks.append(random.clusteredHLC()) }

            // Sorting the whole set both ways catches a disagreement anywhere in it,
            // where spot-checked pairs only cover the values that were spot-checked.
            // Comparing the string projections keeps this valid despite `sorted()`
            // being unstable: two HLCs with the same string are the same HLC.
            let byValue = clocks.sorted()
            let byString = clocks.sorted { $0.string < $1.string }
            #expect(byValue.map(\.string) == byString.map(\.string))

            for _ in 0..<3_000 {
                let (a, b) = (random.clusteredHLC(), random.clusteredHLC())
                #expect((a < b) == (a.string < b.string), "\(a.string) vs \(b.string)")
                #expect((a == b) == (a.string == b.string), "\(a.string) vs \(b.string)")
            }
        }

        /// Twelve, four, eight — at every value, including the extremes. A single
        /// short field would slide the separator and make a small clock sort above a
        /// large one for every text-sorting consumer.
        @Test func theStringFormIsAlwaysTwelveFourEightLowercaseHex() {
            var random = ClockRandom(seed: 0x1D_1D_1D)
            for _ in 0..<1_000 {
                let string = random.hlc().string
                let parts = string.split(separator: "-", omittingEmptySubsequences: false)
                #expect(parts.map(\.count) == [12, 4, 8], "\(string)")
                #expect(string.allSatisfy { $0.isHexDigit || $0 == "-" }, "\(string)")
                #expect(string == string.lowercased(), "\(string)")
            }

            #expect(HLC(wallMs: 0, counter: 0, device: "00000000").string
                == "000000000000-0000-00000000")
            // wallMs saturates at 48 bits and the device id is truncated to eight, so
            // neither can ever widen the string.
            #expect(HLC(wallMs: .max, counter: .max, device: "ffffffffffffffff").string
                == "ffffffffffff-ffff-ffffffff")
            #expect(HLC(wallMs: 1, counter: 1, device: "1").string
                == "000000000001-0001-00000001")
        }

        @Test func everyClockRoundTripsThroughItsStringAndThroughCodable() throws {
            var random = ClockRandom(seed: 0xBEEF_CAFE)
            let clocks = (0..<1_000).map { _ in random.hlc() }
            for clock in clocks {
                #expect(HLC(parsing: clock.string) == clock, "\(clock.string)")
            }

            // Encoded as one JSON string rather than three keys: it is one value, a
            // human reads it in the file, and the envelope's key count stays frozen.
            let data = try JSONEncoder().encode(clocks)
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains("\"\(clocks[0].string)\""))
            #expect(!text.contains("wallMs"))
            #expect(try JSONDecoder().decode([HLC].self, from: data) == clocks)
        }

        /// A malformed clock must not decode. The failure mode being prevented is a
        /// silent zero clock: it parses as "1970, counter 0, foreign device", which
        /// sorts below everything, so every field of that record would lose every
        /// merge forever — and nothing would ever report an error.
        @Test func malformedStringsParseToNilAndFailToDecodeRatherThanBecomingAZeroClock() throws {
            let malformed = [
                "",
                "0",
                "0-0-0",                                // right shape, wrong widths
                "000000000000-0000-0000000",            // seven-digit device
                "000000000000-0000-000000000",          // nine-digit device
                "00000000000-0000-00000000",            // eleven-digit wall reading
                "0000000000000-0000-00000000",          // thirteen
                "000000000000-000-00000000",            // three-digit counter
                "zzzzzzzzzzzz-0000-00000000",           // non-hex wall reading
                "000000000000-000g-00000000",           // non-hex counter
                "00000000000g-0000-00000000",
                "000000000000-0000-0000000g",           // non-hex device
                "000000000000_0000_00000000",           // wrong separator
                "000000000000-0000-00000000-00000000",  // four fields
                "-000000000000-0000-0000000",
                "000000000000-0000",
            ]

            for raw in malformed {
                #expect(HLC(parsing: raw) == nil, "\"\(raw)\" must not parse")
                let json = Data("[\"\(raw)\"]".utf8)
                #expect(throws: DecodingError.self, "\"\(raw)\" must not decode") {
                    try JSONDecoder().decode([HLC].self, from: json)
                }
            }

            // The zero clock itself is legal — it is what `HLC.foreign` produces for a
            // record with no timestamp at all — so the rejections above are about
            // shape, not about the value.
            #expect(HLC(parsing: "000000000000-0000-00000000")
                == HLC(wallMs: 0, counter: 0, device: HLC.foreignDevice))
        }

        /// The HLC spelling is part of an envelope's hash. Accepting uppercase and
        /// silently lowercasing it would verify different bytes from those received.
        @Test func noncanonicalClockSpellingsAreRejectedRatherThanNormalized() throws {
            #expect(HLC(parsing: "0000018FE1A2-00FF-AbCdEf01") == nil)
            #expect(HLC(parsing: "0000018fe1a2-00ff-abcdef01")?.string
                == "0000018fe1a2-00ff-abcdef01")

            #expect(HLC.isCanonicalDeviceID("abcdef01"))
            #expect(!HLC.isCanonicalDeviceID("ABCDEF01"))
            #expect(!HLC.isCanonicalDeviceID("abcdef0"))
            #expect(!HLC.isCanonicalDeviceID("１２３４５６７８"))
        }

        /// The rule that makes an exact-millisecond tie go to the in-app edit:
        /// `SyncMerge.mergeChangedRecord` stamps the local side with the real device
        /// id and the remote side with `foreignDevice`, then asks `localClock >
        /// remoteClock`. That is only "local wins the tie" if all zeroes sorts strictly
        /// below every real device id.
        @Test func theForeignDeviceIdSortsStrictlyBelowEveryRealDeviceId() {
            var random = ClockRandom(seed: 0xF0DE_1234)
            let wallMs: UInt64 = 1_770_000_000_000
            let foreign = HLC.foreign(updatedAt: date(ms: wallMs))
            #expect(foreign.device == HLC.foreignDevice)
            #expect(foreign.wallMs == wallMs)
            #expect(foreign.counter == 0)

            var checked = 0
            for _ in 0..<5_000 {
                let device = random.deviceID()
                // `makeDeviceID()` can in principle draw all zeroes; such a device is
                // not a "real" one for this invariant. See the report.
                guard device != HLC.foreignDevice else { continue }
                checked += 1

                let inApp = HLC(wallMs: wallMs, counter: 0, device: device)
                #expect(foreign < inApp, "foreign must lose the tie against \(device)")
                #expect(!(inApp < foreign))
                #expect(HLC.foreignDevice < device)
                // Only the tie is narrowed: a later foreign write still wins outright.
                #expect(inApp < HLC(wallMs: wallMs + 1, counter: 0, device: HLC.foreignDevice))
            }
            #expect(checked > 4_900)
        }

        /// The all-zero id is reserved for `foreignDevice`, and normalization must
        /// never hand it to a real device by accident.
        ///
        /// An input with no hex digits at all — including the empty string a truncated
        /// `state.json` produces — would otherwise pad to all zeroes, and that Mac
        /// would then silently lose every exact tie it ever entered, forever. Only an
        /// input that genuinely *is* the foreign id is allowed to keep it.
        @Test func aDeviceIdIsAlwaysNormalizedToEightLowercaseHexDigits() {
            #expect(HLC.normalizedDevice("ABCDEF01") == "abcdef01")
            #expect(HLC.normalizedDevice("abcdef0123456789") == "abcdef01")
            #expect(HLC.normalizedDevice("1") == "00000001")
            #expect(HLC.normalizedDevice("ab-cd-ef-01") == "abcdef01")
            #expect(HLC.normalizedDevice("not hex at all") == "00000eaa")

            // Reserved id: only the literal foreign id normalizes to itself.
            #expect(HLC.normalizedDevice(HLC.foreignDevice) == HLC.foreignDevice)
            #expect(HLC.normalizedDevice("") != HLC.foreignDevice)
            #expect(HLC.normalizedDevice("zzzz") != HLC.foreignDevice)
            #expect(HLC.makeDeviceID() != HLC.foreignDevice)

            var random = ClockRandom(seed: 0xDEAD_10CC)
            for _ in 0..<500 {
                let device = HLC(wallMs: 0, counter: 0, device: random.deviceID()).device
                #expect(device.count == 8)
                #expect(device.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            }
        }
    }

    // MARK: - The generator

    @Suite("HLC generator")
    struct Generator {

        /// A laptop's wall clock freezes (a burst of edits inside one millisecond),
        /// steps backwards (an NTP correction), and jumps by hours (a DST- or
        /// timezone-confused clock, or a VM resuming from a snapshot). `send()` is the
        /// only source of local readings, so if any of those could make it repeat or
        /// lower a value, two records would carry the same clock and the merge would
        /// have no defined winner.
        @Test func sendIsStrictlyMonotonicWhileThePhysicalClockFreezesStepsBackAndJumpsHours() {
            let baseMs: UInt64 = 1_770_000_000_000
            let clock = ManualPhysicalClock(nowMs: baseMs)
            let generator = HLCGenerator(device: "a1b2c3d4", physicalNowMs: clock.reader)

            var issued: [HLC] = []
            for _ in 0..<64 { issued.append(generator.send()) }   // frozen
            clock.rewind(by: 250)                                 // small NTP step back
            for _ in 0..<64 { issued.append(generator.send()) }
            clock.rewind(by: 3 * 60 * 60 * 1000)                  // DST / timezone jump
            for _ in 0..<64 { issued.append(generator.send()) }
            clock.set(baseMs + 5)                                 // clock recovers
            let firstAfterRecovery = generator.send()
            issued.append(firstAfterRecovery)
            for _ in 0..<63 { issued.append(generator.send()) }

            for (earlier, later) in zip(issued, issued.dropFirst()) {
                #expect(earlier < later, "\(earlier.string) then \(later.string)")
            }
            #expect(Set(issued.map(\.string)).count == issued.count)
            // The high-water wall reading never regressed even though the clock did.
            #expect(issued.allSatisfy { $0.wallMs >= baseMs })
            #expect(issued.allSatisfy { $0.device == "a1b2c3d4" })
            #expect(generator.last == issued.last)

            // Once the clock is genuinely ahead again the counter resets, which is what
            // keeps it from becoming a permanent one-way ratchet.
            #expect(firstAfterRecovery.wallMs == baseMs + 5)
            #expect(firstAfterRecovery.counter == 0)
            #expect(issued.last?.wallMs == baseMs + 5)
        }

        /// `stamp` exists for undo. `undo()` restores an older array verbatim,
        /// including its older `updatedAt`, so a reading derived from `updatedAt`
        /// alone would land *below* the remote copy of the change being undone and the
        /// merge would faithfully reinstate that change — the user would watch their
        /// undo evaporate on the next sync. Flooring one tick above the record's own
        /// ancestor is what makes a local edit outrank whatever it was derived from,
        /// no matter how far its timestamp moves backwards.
        @Test func stampNeverReturnsAValueAtOrBelowTheRecordsOwnAncestor() {
            var random = ClockRandom(seed: 0x5741_4D50)
            let clock = ManualPhysicalClock(nowMs: ClockRandom.epochFloorMs)
            let generator = HLCGenerator(device: "0f1e2d3c", physicalNowMs: clock.reader)

            for _ in 0..<3_000 {
                // Move the physical clock arbitrarily — forwards, backwards, nowhere.
                clock.set(ClockRandom.epochFloorMs + random.uInt64(below: ClockRandom.epochSpanMs))

                let ancestor = random.hlc()
                let updatedAt = date(ms: ClockRandom.epochFloorMs
                    + random.uInt64(below: ClockRandom.epochSpanMs))

                let stamped = generator.stamp(updatedAt: updatedAt, baseHLC: ancestor)
                #expect(stamped > ancestor, "\(stamped.string) must beat \(ancestor.string)")
                #expect(stamped == generator.last)
                #expect(stamped.device == "0f1e2d3c")
                // It is also at least the record's own modification time, so a record
                // never carries a clock older than the timestamp it advertises.
                #expect(stamped.wallMs >= updatedAt.millisecondsSince1970)
            }
        }

        /// The concrete undo case, staged with the physical clock running *behind* the
        /// remote device so the floor is the only thing that can save it.
        @Test func undoOutranksTheRemoteEditItIsReverting() {
            let t0: UInt64 = 1_770_000_000_000
            let clock = ManualPhysicalClock(nowMs: t0)
            let generator = HLCGenerator(device: "0f1e2d3c", physicalNowMs: clock.reader)

            let original = generator.stamp(updatedAt: date(ms: t0), baseHLC: nil)

            // Another writer edits the same record thirty seconds later.
            let remoteEdit = HLC(wallMs: t0 + 30_000, counter: 0, device: HLC.foreignDevice)
            #expect(original < remoteEdit)

            // Our clock is a minute behind theirs, and undo restores the ORIGINAL
            // `updatedAt` — so naive stamping would produce this, which loses:
            clock.set(t0 - 60_000)
            let naive = HLC(wallMs: t0, counter: 0, device: "0f1e2d3c")
            #expect(naive < remoteEdit)

            let undone = generator.stamp(updatedAt: date(ms: t0), baseHLC: remoteEdit)
            #expect(undone > remoteEdit)
            #expect(undone.wallMs == remoteEdit.wallMs + 1)
        }

        /// One device with a clock set to 2099 must not be able to drag the fleet to
        /// 2099. Adopting such a reading is permanent — every later local edit would
        /// carry a fabricated future timestamp on every device that ever saw it —
        /// while ignoring it costs only that this one record's ordering falls back to
        /// the device tiebreak.
        @Test func aRemoteClockBeyondTheDriftLimitIsRejectedAndLeavesOursUntouched() {
            let nowMs: UInt64 = 1_770_000_000_000
            let clock = ManualPhysicalClock(nowMs: nowMs)
            let generator = HLCGenerator(device: "abcdef01", physicalNowMs: clock.reader)
            let before = generator.last

            let justOverTheLine = HLC(
                wallMs: nowMs + HLCGenerator.maxDriftMs + 1, counter: 0, device: "deadbeef")
            generator.observe(justOverTheLine)
            #expect(generator.last == before)
            #expect(generator.rejectedSkewCount == 1)

            // A clock set to the year 2100 is rejected the same way, and the rejection
            // is counted rather than swallowed so the sync pane can surface it.
            generator.observe(HLC(wallMs: 4_102_444_800_000, counter: 9, device: "deadbeef"))
            #expect(generator.last == before)
            #expect(generator.rejectedSkewCount == 2)

            // And we keep issuing from our own honest clock afterwards.
            let next = generator.send()
            #expect(next.wallMs == nowMs)
            #expect(next < justOverTheLine)
        }

        /// Honest skew still has to converge, or two devices a few hours apart would
        /// never agree on an order. Twenty-three hours is inside the limit.
        @Test func aRemoteClockTwentyThreeHoursAheadIsAdopted() {
            let nowMs: UInt64 = 1_770_000_000_000
            let aheadMs = nowMs + 23 * 60 * 60 * 1000
            let clock = ManualPhysicalClock(nowMs: nowMs)
            let generator = HLCGenerator(device: "abcdef01", physicalNowMs: clock.reader)

            let remote = HLC(wallMs: aheadMs, counter: 4, device: "deadbeef")
            generator.observe(remote)
            #expect(generator.rejectedSkewCount == 0)
            #expect(generator.last.wallMs == aheadMs)
            #expect(generator.last.counter == 5)          // one past what we saw
            #expect(generator.last.device == "abcdef01")  // we issue it, so we own it
            #expect(generator.last > remote)

            // Everything issued from here outranks what we observed, which is the whole
            // point of folding a remote reading in.
            #expect(generator.send() > remote)

            // A reading we are already past changes nothing and is not skew.
            let steady = generator.last
            generator.observe(HLC(wallMs: nowMs, counter: 0, device: "deadbeef"))
            #expect(generator.last == steady)
            #expect(generator.rejectedSkewCount == 0)
        }

        /// Pins the comparison itself: exactly `maxDriftMs` ahead is adopted, one
        /// millisecond further is not. Without this, a refactor could turn `<=` into
        /// `<`, or the constant into 24h-1ms, and nothing would notice until a device
        /// sitting near the boundary started dropping every reading it saw.
        @Test func theDriftLimitIsInclusiveAtExactlyTwentyFourHours() {
            let nowMs: UInt64 = 1_770_000_000_000
            #expect(HLCGenerator.maxDriftMs == 24 * 60 * 60 * 1000)

            let accepting = HLCGenerator(
                device: "abcdef01", physicalNowMs: ManualPhysicalClock(nowMs: nowMs).reader)
            accepting.observe(HLC(wallMs: nowMs + HLCGenerator.maxDriftMs, counter: 0, device: "deadbeef"))
            #expect(accepting.rejectedSkewCount == 0)
            #expect(accepting.last.wallMs == nowMs + HLCGenerator.maxDriftMs)

            let rejecting = HLCGenerator(
                device: "abcdef01", physicalNowMs: ManualPhysicalClock(nowMs: nowMs).reader)
            let before = rejecting.last
            rejecting.observe(HLC(wallMs: nowMs + HLCGenerator.maxDriftMs + 1, counter: 0, device: "deadbeef"))
            #expect(rejecting.rejectedSkewCount == 1)
            #expect(rejecting.last == before)
        }

        /// The relaunch path. `state.json` holds the highest reading this device ever
        /// issued; if the wall clock is behind it at launch (a backwards NTP step
        /// across a restart, a machine restored from a snapshot) we must resume above
        /// the persisted value, not reissue readings we have already handed out.
        @Test func aGeneratorRestoredFromAClockAheadOfTheWallClockKeepsIssuingAboveIt() {
            let nowMs: UInt64 = 1_770_000_000_000
            let persisted = HLC(wallMs: nowMs + 10 * 60 * 1000, counter: 7, device: "abcdef01")
            let clock = ManualPhysicalClock(nowMs: nowMs)
            let generator = HLCGenerator(
                device: "abcdef01", persisted: persisted, physicalNowMs: clock.reader)

            #expect(generator.last == persisted)

            var previous = persisted
            for _ in 0..<32 {
                let next = generator.send()
                #expect(next > persisted)
                #expect(next > previous)
                // The wall reading is held and the counter carries the order, which is
                // exactly what the hybrid part of the clock is for.
                #expect(next.wallMs == persisted.wallMs)
                previous = next
            }

            clock.set(persisted.wallMs + 1)
            let recovered = generator.send()
            #expect(recovered.wallMs == persisted.wallMs + 1)
            #expect(recovered.counter == 0)
            #expect(recovered > previous)
        }

        @Test func aGeneratorRestoredFromAStaleClockStartsFromTheWallClockInstead() {
            let nowMs: UInt64 = 1_770_000_000_000
            let stale = HLC(wallMs: nowMs - 5_000, counter: 900, device: "abcdef01")
            let generator = HLCGenerator(
                device: "abcdef01",
                persisted: stale,
                physicalNowMs: ManualPhysicalClock(nowMs: nowMs).reader)

            #expect(generator.last.wallMs == nowMs)
            // The stale counter is dropped rather than carried forward: it only ever
            // disambiguated within its own millisecond.
            #expect(generator.last.counter == 0)
            #expect(generator.last > stale)
        }

        /// Restart round trip: whatever we persist, a generator restored from it never
        /// hands out a reading the previous run already used.
        @Test func aRelaunchNeverReissuesAReadingTheEarlierRunAlreadyHandedOut() {
            var random = ClockRandom(seed: 0x5211_0AD)
            var clock = ManualPhysicalClock(nowMs: 1_770_000_000_000)
            var generator = HLCGenerator(device: "abcdef01", physicalNowMs: clock.reader)
            var issued: [HLC] = []

            for _ in 0..<12 {
                for _ in 0..<8 { issued.append(generator.send()) }
                // Relaunch, with the wall clock landing anywhere within a day either
                // side of where it was.
                let jitter = random.uInt64(below: 2 * 24 * 60 * 60 * 1000)
                let nowMs = (1_770_000_000_000 - 24 * 60 * 60 * 1000) + jitter
                clock = ManualPhysicalClock(nowMs: nowMs)
                generator = HLCGenerator(
                    device: "abcdef01", persisted: generator.last, physicalNowMs: clock.reader)
            }

            for (earlier, later) in zip(issued, issued.dropFirst()) {
                #expect(earlier < later, "\(earlier.string) then \(later.string)")
            }
            #expect(Set(issued.map(\.string)).count == issued.count)
        }
    }

    // MARK: - state.json

    @Suite("Sync state file")
    struct StateFile {

        static func sampleState() -> SyncState {
            var state = SyncState.fresh(
                deviceID: "a1b2c3d4", now: Date(timeIntervalSince1970: 1_769_000_000))
            state.generation = 42
            state.librarySHA256 = String(repeating: "ab", count: 32)
            state.backend = .icloud
            state.cursor = "cursor-token-7"
            state.lastSyncAt = Date(timeIntervalSince1970: 1_770_000_000)
            state.halt = SyncState.Halt(
                reason: .massDeletion,
                detail: "remote asked to delete 91 of 93 records",
                at: Date(timeIntervalSince1970: 1_769_999_400))
            state.promoting = UUID(uuidString: "1F1E1D1C-0B0A-4908-8706-050403020100")
            return state
        }

        @Test func syncStateRoundTripsThroughWriteAndLoadWithDatesOnTheWireAsISO8601() throws {
            let scratch = ScratchDirectory("state-roundtrip")
            defer { scratch.remove() }
            let url = scratch.file("state.json")
            let state = Self.sampleState()

            // Staging inside the same scratch directory, which is also the assertion
            // that `temporaryDirectory` is honoured: were it ignored, this write would
            // reach into the user's real support folder instead.
            try SyncStateFile.write(state, to: url, temporaryDirectory: scratch.file("Tmp"))
            #expect(FileManager.default.fileExists(atPath: scratch.file("Tmp").path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Tmp").path) == [],
                    "a staged temporary file survived a successful state write")

            let text = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
            // Whole seconds throughout: `.iso8601` is RFC-3339 *without* fractional
            // seconds. Millisecond resolution in this file lives in the HLC, which is
            // why these dates only have to stay human-readable.
            #expect(text.contains("\"lastSyncAt\" : \"2026-02-02T02:40:00Z\""))
            #expect(text.contains("\"at\" : \"2026-02-02T02:30:00Z\""))
            // The clock is one readable string, not a nested object and not a date:
            // it is the only field in this file that carries millisecond resolution.
            #expect(state.hlc.wallMs == 1_769_000_000_000)
            #expect(text.contains("\"hlc\" : \"\(state.hlc.string)\""))
            #expect(!text.contains("wallMs"))

            let sentinel = SyncState.fresh(deviceID: "ffffffff", now: Date(timeIntervalSince1970: 0))
            let reloaded = try #require(
                SyncStateFile.load(from: url, makeFresh: { sentinel }).loadedState)
            #expect(reloaded == state)
            #expect(reloaded.hlc == state.hlc)
            #expect(reloaded.lastSyncAt == state.lastSyncAt)
            #expect(reloaded.halt?.at == state.halt?.at)
            #expect(reloaded.halt?.reason == .massDeletion)
            #expect(reloaded.promoting == state.promoting)
            #expect(reloaded.demoting == nil)
        }

        /// The version probe runs BEFORE the full decode, and this is the case that
        /// proves it: a file from a newer schema whose body this build cannot decode
        /// at all. Landing in "the file is corrupt, start fresh" would have this build
        /// write a v1 state straight over the v2 one — and debug and release builds
        /// genuinely share this directory, because the app cannot be sandboxed, so an
        /// older build meeting a newer build's state is routine rather than
        /// hypothetical. (`SnippetUsageStore.loadSynchronously()` learned this the
        /// same way.)
        @Test func aFileFromANewerSchemaIsTooNewEvenWhenTheRestOfItIsGarbage() throws {
            let scratch = ScratchDirectory("state-too-new-garbage")
            defer { scratch.remove() }
            let url = scratch.file("state.json")

            let data = Data("""
            {
              "schemaVersion" : 99,
              "deviceID" : ["not", "a", "string"],
              "hlc" : 12345,
              "generation" : "definitely not a number",
              "somethingThisBuildHasNeverHeardOf" : { "nested" : [1, 2, 3] }
            }
            """.utf8)
            try data.write(to: url)

            // The body really is undecodable, so the outcome below can only be
            // explained by the probe having run first.
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SyncState.self, from: data)
            }

            let outcome = SyncStateFile.load(from: url, makeFresh: {
                Issue.record("load fell through to `fresh`, which would overwrite a newer state")
                return SyncState.fresh(deviceID: "ffffffff", now: Date(timeIntervalSince1970: 0))
            })
            #expect(outcome.tooNewVersion == 99)
            #expect(outcome.loadedState == nil)
            #expect(outcome.freshState == nil)
        }

        /// And a future file that *would* decode cleanly is still `.tooNew`, never
        /// `.loaded`: the version, not decodability, is what decides. Returning
        /// `.loaded` here would let this build write back a v2 file with every field
        /// it does not understand quietly dropped.
        @Test func aFileFromANewerSchemaIsTooNewEvenWhenItWouldDecodeCleanly() throws {
            let scratch = ScratchDirectory("state-too-new-valid")
            defer { scratch.remove() }
            let url = scratch.file("state.json")

            var state = Self.sampleState()
            state.schemaVersion = SyncState.currentSchemaVersion + 1
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: url)

            // Decodable — and still refused.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            #expect(throws: Never.self) { try decoder.decode(SyncState.self, from: data) }

            let outcome = SyncStateFile.load(from: url, makeFresh: {
                SyncState.fresh(deviceID: "ffffffff", now: Date(timeIntervalSince1970: 0))
            })
            #expect(outcome.tooNewVersion == SyncState.currentSchemaVersion + 1)
            #expect(outcome.loadedState == nil)

            // The halt that corresponds to this outcome is the one that never
            // auto-heals: there is no safe way for an older build to resume writing.
            #expect(SyncState.HaltReason.schemaTooNew.isUserRecoverable == false)
        }

        /// A file at the current version loads, so the probe is not simply refusing
        /// everything.
        @Test func aFileAtTheCurrentSchemaVersionLoadsNormally() throws {
            let scratch = ScratchDirectory("state-current-version")
            defer { scratch.remove() }
            let url = scratch.file("state.json")

            let state = Self.sampleState()
            #expect(state.schemaVersion == SyncState.currentSchemaVersion)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: url)

            let outcome = SyncStateFile.load(from: url, makeFresh: {
                Issue.record("a current-version file must not land in `fresh`")
                return SyncState.fresh(deviceID: "ffffffff", now: Date(timeIntervalSince1970: 0))
            })
            #expect(outcome.loadedState == state)
        }

        /// A device identity is minted per install and must not be shared, or two
        /// machines would tie on the device tiebreak and the merge would stop being
        /// deterministic between them. The default `makeFresh` is used deliberately —
        /// the randomness is what is under test. (A collision is a 1-in-2^32 flake.)
        @Test func aMissingFileYieldsAFreshStateWithADistinctRandomDeviceIdentityEachTime() throws {
            let scratch = ScratchDirectory("state-missing")
            defer { scratch.remove() }
            let url = scratch.file("state.json")  // never created

            let first = try #require(SyncStateFile.load(from: url).freshState)
            let second = try #require(SyncStateFile.load(from: url).freshState)

            #expect(first.deviceID != second.deviceID)
            #expect(first.scopeID != second.scopeID)

            for state in [first, second] {
                #expect(state.schemaVersion == SyncState.currentSchemaVersion)
                #expect(state.deviceID.count == 8)
                #expect(state.deviceID.allSatisfy { $0.isHexDigit && !$0.isUppercase })
                // The clock has to carry this device's identity from the first write,
                // otherwise the very first record it stamps ties with somebody else's.
                #expect(state.hlc.device == state.deviceID)
                #expect(state.hlc.counter == 0)
                #expect(state.generation == 0)
                #expect(state.librarySHA256 == nil)
                #expect(state.cursor == nil)
                #expect(state.lastSyncAt == nil)
                #expect(state.halt == nil)
                #expect(state.promoting == nil)
                #expect(state.demoting == nil)
                // `none` is the shipped default: all of this is worth having with no
                // network at all.
                #expect(state.backend == .none)
            }
        }

        /// A state file we cannot make sense of is thrown away rather than repaired,
        /// because it holds no user data: the cost is one new device identity and one
        /// full reconcile, and it can never lose a snippet.
        @Test func anUnreadableFileYieldsAFreshStateBecauseItHoldsNoUserData() throws {
            let scratch = ScratchDirectory("state-corrupt")
            defer { scratch.remove() }
            let sentinel = SyncState.fresh(deviceID: "ffffffff", now: Date(timeIntervalSince1970: 0))

            let cases: [(String, Data)] = [
                ("empty", Data()),
                ("truncated mid-write", Data("{\"schemaVersion\" : 1, \"deviceID\" : \"a1b2".utf8)),
                ("binary", Data([0xFF, 0x00, 0x1B, 0x7F, 0xC3, 0x28])),
                ("json, but not a state", Data("{\"hello\":\"world\"}".utf8)),
                ("a bare array", Data("[]".utf8)),
                ("a bare number", Data("17".utf8)),
                // Current version, right shape, unusable clock: the strictness of
                // `HLC(from:)` is what routes this here instead of silently seating a
                // zero clock that would lose every merge.
                ("current version with a malformed hlc", Data("""
                {
                  "schemaVersion" : 1,
                  "deviceID" : "a1b2c3d4",
                  "hlc" : "not-a-clock",
                  "generation" : 0,
                  "scopeID" : "s",
                  "backend" : "none"
                }
                """.utf8)),
            ]

            for (index, testCase) in cases.enumerated() {
                let (label, bytes) = testCase
                let url = scratch.file("state-\(index).json")
                try bytes.write(to: url)

                let outcome = SyncStateFile.load(from: url, makeFresh: { sentinel })
                #expect(outcome.freshState == sentinel, "\(label) should start fresh")
                #expect(outcome.loadedState == nil, "\(label)")
                #expect(outcome.tooNewVersion == nil, "\(label)")
            }
        }
    }

    // MARK: - Storage layout

    @Suite("Storage layout")
    struct Layout {

        /// Every file a subsystem writes, with the name it is known by in the source.
        static let files: [(String, URL)] = [
            ("Usage/usage.json", SnippetStorageLocations.usageFileURL),
            ("Sync/state.json", SnippetStorageLocations.syncStateFileURL),
            ("Sync/base.json", SnippetStorageLocations.syncBaseFileURL),
            ("Sync/library-metadata.json", SnippetStorageLocations.syncLibraryMetadataFileURL),
            ("Sync/tombstones.json", SnippetStorageLocations.tombstonesFileURL),
            ("Sync/library.lock", SnippetStorageLocations.libraryLockFileURL),
            ("Vault/vault.json", SnippetStorageLocations.vaultFileURL),
            ("Vault/audit.json", SnippetStorageLocations.vaultAuditFileURL),
        ]

        /// Exactly the list `createAllDirectories()` promises to create.
        static let folders: [(String, URL)] = [
            ("Usage", SnippetStorageLocations.usageFolderURL),
            ("Sync", SnippetStorageLocations.syncFolderURL),
            ("Sync/Quarantine", SnippetStorageLocations.syncQuarantineFolderURL),
            ("Vault", SnippetStorageLocations.vaultFolderURL),
            ("Backups", SnippetStorageLocations.backupsFolderURL),
            ("Tmp", SnippetStorageLocations.tmpFolderURL),
        ]

        /// Path components of `url` below the support folder, or `nil` if it is not
        /// below it at all. No I/O: these are lexical URLs.
        static func componentsBelowSupportFolder(_ url: URL) -> [String]? {
            let root = normalizedPath(SnippetStorageLocations.supportFolderURL)
            let path = normalizedPath(url)
            guard path.hasPrefix(root + "/") else { return nil }
            return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        }

        /// `SnippetStore` watches `supportFolderURL` with a `DispatchSource`, and
        /// `rename(2)` — how every atomic write ends — mutates the *destination*
        /// directory's vnode. A sidecar file living next to `snippets.json` would fire
        /// that monitor on every sync tick, every lock acquisition, and every backup,
        /// collapsing the editor's 0.3s write debounce and rewriting the whole library
        /// while the user is still typing. So no new subsystem may put a file directly
        /// in the support folder; `snippets.json` is the single deliberate exception.
        @Test func noSubsystemWritesAFileDirectlyIntoTheSupportFolder() {
            for (label, url) in Self.files {
                let components = Self.componentsBelowSupportFolder(url)
                #expect(components != nil, "\(label) must live under the support folder")
                #expect((components?.count ?? 0) >= 2,
                        "\(label) must be inside a subdirectory, not a direct child of the support folder")
                #expect(!url.hasDirectoryPath, "\(label) is a file")
            }

            // The exception, stated once and on purpose.
            #expect(Self.componentsBelowSupportFolder(SnippetStorageLocations.snippetsFileURL)
                == ["snippets.json"])

            for (label, url) in Self.folders {
                let components = Self.componentsBelowSupportFolder(url)
                #expect((components?.count ?? 0) >= 1, "\(label) must be under the support folder")
                #expect(url.hasDirectoryPath, "\(label) is a directory")
            }

            // No two subsystems may share a path.
            let everything = Self.files.map(\.1) + Self.folders.map(\.1)
                + [SnippetStorageLocations.snippetsFileURL, SnippetStorageLocations.supportFolderURL]
            #expect(Set(everything.map(normalizedPath)).count == everything.count)
        }

        /// Two placement rules that are load-bearing rather than tidy, both stated in
        /// the source comments:
        ///
        /// - The `flock(2)` target is a file of its own. Locking `snippets.json`
        ///   itself does not work at all: an atomic write renames a fresh inode over
        ///   the path, so the next writer flocks a different file than the one already
        ///   held and both proceed. Measured to lose as many writes as no lock.
        /// - The reveal-audit log is deliberately not in `Usage/`, which carries a
        ///   published promise never to leave the Mac and a different retention policy.
        @Test func theLockFileAndTheVaultAuditLogLiveWhereTheirCommentsSayTheyDo() {
            let lock = SnippetStorageLocations.libraryLockFileURL
            #expect(normalizedPath(lock) != normalizedPath(SnippetStorageLocations.snippetsFileURL))
            #expect(Self.componentsBelowSupportFolder(lock) == ["Sync", "library.lock"])

            let audit = SnippetStorageLocations.vaultAuditFileURL
            #expect(Self.componentsBelowSupportFolder(audit)?.first == "Vault")
            #expect(Self.componentsBelowSupportFolder(audit)?.first != "Usage")
        }

        /// Every file the app writes must have its directory created up front.
        /// A missing parent is not a soft failure: `AtomicFileWriter` ends in
        /// `rename(2)`, which returns ENOENT, so the write is simply lost.
        @Test func everyFileLivesInADirectoryThatCreateAllDirectoriesPromisesToCreate() {
            let created = Set(
                ([SnippetStorageLocations.supportFolderURL] + Self.folders.map(\.1))
                    .map(normalizedPath))
            for (label, url) in Self.files {
                #expect(created.contains(normalizedPath(url.deletingLastPathComponent())),
                        "nothing creates the directory for \(label)")
            }
            #expect(created.contains(
                normalizedPath(SnippetStorageLocations.snippetsFileURL.deletingLastPathComponent())))
        }

        /// `createAllDirectories(fileManager:)` injects a `FileManager` but not a
        /// root, so the URLs it asks for are always the real ones. Subclassing is how
        /// the test observes exactly which directories it asks for while creating them
        /// under a scratch root, so the real support folder is never touched.
        @Test func createAllDirectoriesCreatesEverythingItPromisesAndIsIdempotent() throws {
            let scratch = ScratchDirectory("create-all-directories")
            defer { scratch.remove() }
            let fileManager = RedirectingFileManager(root: scratch.url)

            SnippetStorageLocations.createAllDirectories(fileManager: fileManager)

            // Exactly the folder URLs the type exposes — no more, no fewer. Adding a
            // new subsystem folder without adding it here fails this assertion, which
            // is the point: a folder created lazily on first use fires the folder
            // monitor at an arbitrary later moment.
            let promised = Set(
                ([SnippetStorageLocations.supportFolderURL] + Self.folders.map(\.1))
                    .map(normalizedPath))
            #expect(Set(fileManager.requested) == promised)
            #expect(fileManager.failures.isEmpty)

            for path in promised {
                var isDirectory: ObjCBool = false
                let redirected = fileManager.redirect(URL(fileURLWithPath: path))
                #expect(FileManager.default.fileExists(atPath: redirected.path, isDirectory: &isDirectory),
                        "\(path) was never created")
                #expect(isDirectory.boolValue, "\(path) is not a directory")
            }

            // Idempotent: it runs at every launch, over directories that already
            // exist, and must neither fail nor ask for anything different.
            fileManager.reset()
            SnippetStorageLocations.createAllDirectories(fileManager: fileManager)
            #expect(Set(fileManager.requested) == promised)
            #expect(fileManager.failures.isEmpty)
        }
    }
}

// MARK: - A FileManager that answers with a scratch root

private final class RedirectingFileManager: FileManager {
    let root: URL
    private(set) var requested: [String] = []
    private(set) var failures: [String] = []

    init(root: URL) {
        self.root = root
        super.init()
    }

    func reset() {
        requested.removeAll()
        failures.removeAll()
    }

    func redirect(_ url: URL) -> URL {
        let supportFolder = normalizedPath(SnippetStorageLocations.supportFolderURL)
        let path = normalizedPath(url)
        if path == supportFolder { return root }
        guard path.hasPrefix(supportFolder + "/") else {
            // Anything outside the support folder lands somewhere obvious rather than
            // on the real filesystem; the `requested` assertion is what catches it.
            return root.appendingPathComponent("outside-the-support-folder", isDirectory: true)
        }
        return root.appendingPathComponent(
            String(path.dropFirst(supportFolder.count + 1)), isDirectory: true)
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        requested.append(normalizedPath(url))
        do {
            try super.createDirectory(
                at: redirect(url),
                withIntermediateDirectories: createIntermediates,
                attributes: attributes)
        } catch {
            // `createAllDirectories` swallows errors with `try?`, so record them here
            // or the idempotency assertion would have nothing to look at.
            failures.append("\(normalizedPath(url)): \(error)")
            throw error
        }
    }
}
