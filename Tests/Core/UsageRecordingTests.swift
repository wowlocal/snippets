import Foundation
import Testing

@testable import SnippetsCore

// The write side of usage data: the join semilattice, the on-disk merge, pruning,
// the recording/debounce logic, selection memory, and the directory isolation that
// keeps all of it away from the library's file-system monitor.

// MARK: - Deterministic randomness

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func int(_ upperBound: Int) -> Int {
        upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
    }

    mutating func unitDouble() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    mutating func uuid() -> UUID {
        let a = next()
        let b = next()
        func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 {
            UInt8(truncatingIfNeeded: value >> shift)
        }
        return UUID(uuid: (
            byte(a, 0), byte(a, 8), byte(a, 16), byte(a, 24),
            byte(a, 32), byte(a, 40), byte(a, 48), byte(a, 56),
            byte(b, 0), byte(b, 8), byte(b, 16), byte(b, 24),
            byte(b, 32), byte(b, 40), byte(b, 48), byte(b, 56)
        ))
    }
}

// MARK: - Helpers

private let day: Double = 86_400

/// The legacy `assertClose`, kept so every tolerance and every message from the
/// standalone executable survives the port unchanged.
private func expectClose(
    _ actual: Double, _ expected: Double, tolerance: Double, _ message: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual - expected) <= tolerance,
        "\(message) - expected \(expected) ± \(tolerance), got \(actual)",
        sourceLocation: sourceLocation
    )
}

private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("snippets-frecency-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readDocument(at url: URL) -> SnippetUsageDocument? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SnippetUsageDocument.self, from: data)
}

private func singleRecordDocument(
    _ id: String, weight: Double, epoch: Double = 1_785_312_000
) -> SnippetUsageDocument {
    SnippetUsageDocument(
        version: 1, epoch: epoch, halfLifeDays: SnippetFrecency.halfLifeDays,
        records: [id: SnippetUsageRecord(weight: weight, count: 3, lastUsedAt: epoch)],
        bindings: [:])
}

/// 5,100 records of which the first 100 are orphans. Built from a fixed seed so the
/// two capacity tests below see byte-identical fixtures.
private func makeOverCapacityDocument(
    now: Double
) -> (document: SnippetUsageDocument, orphanIDs: Set<String>, liveIDs: Set<UUID>) {
    var random = SeededRandom(seed: 13)
    var large = SnippetUsageDocument.empty(now: now)
    var liveIDs = Set<UUID>()
    var orphanIDs = Set<String>()
    for index in 0..<5100 {
        let id = random.uuid()
        // Orphans are given the heaviest weights on purpose: only the
        // orphan rule can explain their eviction.
        large.records[id.uuidString] =
            SnippetUsageRecord(weight: index < 100 ? 1000 : 10, count: 1, lastUsedAt: now)
        if index < 100 {
            orphanIDs.insert(id.uuidString)
        } else {
            liveIDs.insert(id)
        }
    }
    return (large, orphanIDs, liveIDs)
}

/// Mirrors `SnippetStore.startObservingExternalChanges()`: same `O_EVTONLY`
/// descriptor on the folder, same event mask.
private final class FolderMonitor {
    private let descriptor: Int32
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var count = 0

    init?(folder: URL, queue: DispatchQueue) {
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    var firedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func cancel() { source.cancel() }
}

/// The monitor delivers on a queue, so give it a moment to catch up before
/// asserting. A false pass here is worse than a slow test.
private func settle(_ queue: DispatchQueue, seconds: Double = 0.6) {
    Thread.sleep(forTimeInterval: seconds)
    queue.sync {}
}

// MARK: - Suite

@Suite("Usage recording, merge, and directory isolation")
struct UsageRecordingTests {

    // MARK: - Join

    @Test func joinCommutesIsIdempotentAndAssociates() {
        var random = SeededRandom(seed: 99)
        for _ in 0..<500 {
            let a = SnippetUsageRecord(weight: random.unitDouble() * 100,
                                       count: random.int(50), lastUsedAt: random.unitDouble() * 1e9)
            let b = SnippetUsageRecord(weight: random.unitDouble() * 100,
                                       count: random.int(50), lastUsedAt: random.unitDouble() * 1e9)
            let c = SnippetUsageRecord(weight: random.unitDouble() * 100,
                                       count: random.int(50), lastUsedAt: random.unitDouble() * 1e9)
            #expect(SnippetUsageFile.join(a, b) == SnippetUsageFile.join(b, a), "join commutes")
            #expect(SnippetUsageFile.join(a, a) == a, "join is idempotent")
            #expect(SnippetUsageFile.join(SnippetUsageFile.join(a, b), c)
                    == SnippetUsageFile.join(a, SnippetUsageFile.join(b, c)), "join associates")
        }
    }

    // MARK: - Merge

    @Test func concurrentWritersBothSurviveAndNeitherIsInflated() throws {
        let folder = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let now = 1_785_312_000.0

        let idA = UUID().uuidString
        let idB = UUID().uuidString

        // Two "processes" writing different snippets: neither loses.
        SnippetUsageFile.mergeAndWrite(singleRecordDocument(idA, weight: 10), liveIDs: nil, now: now,
                                       folderURL: folder, fileURL: file)
        SnippetUsageFile.mergeAndWrite(singleRecordDocument(idB, weight: 20), liveIDs: nil, now: now,
                                       folderURL: folder, fileURL: file)
        let merged = try #require(readDocument(at: file))
        #expect(merged.records.count == 2, "concurrent writers both survive")
        let mergedA = try #require(merged.records[idA])
        let mergedB = try #require(merged.records[idB])
        expectClose(mergedA.weight, 10, tolerance: 1e-6, "no weight is inflated")
        expectClose(mergedB.weight, 20, tolerance: 1e-6, "no weight is inflated")

        // Idempotent: merging the same state again changes nothing.
        SnippetUsageFile.mergeAndWrite(singleRecordDocument(idB, weight: 20), liveIDs: nil, now: now,
                                       folderURL: folder, fileURL: file)
        let repeated = try #require(readDocument(at: file))
        let repeatedB = try #require(repeated.records[idB])
        expectClose(repeatedB.weight, 20, tolerance: 1e-6, "re-merging does not inflate")
    }

    @Test func differentEpochsNormalizeBeforeTheMax() throws {
        let now = 1_785_312_000.0
        let idA = UUID().uuidString

        // Different epochs normalize before the max.
        let older = SnippetUsageDocument(
            version: 1, epoch: now - 45 * day, halfLifeDays: SnippetFrecency.halfLifeDays,
            records: [idA: SnippetUsageRecord(weight: 10, count: 1, lastUsedAt: now - 45 * day)],
            bindings: [:])
        let joined = SnippetUsageFile.joined(mine: older, disk: singleRecordDocument(idA, weight: 10))
        #expect(joined.epoch == now, "the later epoch wins")
        let joinedA = try #require(joined.records[idA])
        expectClose(joinedA.weight, 10, tolerance: 1e-6,
                    "the older document is scaled down before the max, so the newer one wins")
    }

    @Test func aResetIsNeverResurrectedByTheMergeInEitherDirection() throws {
        let folder = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let now = 1_785_312_000.0
        let idA = UUID().uuidString

        // A reset must not come back from disk.
        try? FileManager.default.removeItem(at: file)
        var populated = SnippetUsageDocument.empty(now: now)
        var random = SeededRandom(seed: 5)
        for _ in 0..<200 {
            populated.records[random.uuid().uuidString] =
                SnippetUsageRecord(weight: 50, count: 1, lastUsedAt: now)
        }
        SnippetUsageFile.mergeAndWrite(populated, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        let onDisk = try #require(readDocument(at: file))
        #expect(onDisk.records.count == 200, "the disk starts with 200 records")

        var afterReset = SnippetUsageDocument.empty(now: now)
        afterReset.recordsClearedAt = now + 1
        afterReset.bindingsClearedAt = now + 1
        afterReset.records[idA] = SnippetUsageRecord(weight: 1, count: 1, lastUsedAt: now)
        SnippetUsageFile.mergeAndWrite(afterReset, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        let merged = try #require(readDocument(at: file))
        #expect(merged.records.count == 1, "a reset is not resurrected by the merge")
        #expect(Array(merged.records.keys) == [idA], "only the post-reset use survives")

        // The same in the opposite direction: the reset already on disk wins.
        try? FileManager.default.removeItem(at: file)
        SnippetUsageFile.mergeAndWrite(afterReset, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        SnippetUsageFile.mergeAndWrite(populated, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        let afterStaleWrite = try #require(readDocument(at: file))
        #expect(afterStaleWrite.records.count == 1,
                "a stale in-memory document cannot undo a reset recorded on disk")
    }

    @Test func clearingTheBindingTableSurvivesTheMerge() throws {
        let folder = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let now = 1_785_312_000.0
        let idA = UUID().uuidString

        // Selection memory: switching it off empties the table even when disk
        // still holds one.
        try? FileManager.default.removeItem(at: file)
        var withBindings = SnippetUsageDocument.empty(now: now)
        withBindings.bindings = ["re": [idA: 3.0]]
        withBindings.records[idA] = SnippetUsageRecord(weight: 5, count: 1, lastUsedAt: now)
        SnippetUsageFile.mergeAndWrite(withBindings, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        let seeded = try #require(readDocument(at: file))
        #expect(!seeded.bindings.isEmpty, "the disk starts with a binding table")

        var cleared = withBindings
        cleared.bindings = [:]
        cleared.bindingsClearedAt = now + 1
        SnippetUsageFile.mergeAndWrite(cleared, liveIDs: nil, now: now, folderURL: folder, fileURL: file)
        let afterClear = try #require(readDocument(at: file))
        #expect(afterClear.bindings.isEmpty, "clearing bindings survives the merge")
    }

    @Test func aFileFromANewerVersionIsNeverMergedOver() throws {
        let folder = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let now = 1_785_312_000.0
        let idA = UUID().uuidString

        // A file written by a newer version is never overwritten.
        try? FileManager.default.removeItem(at: file)
        let future = "{\"v\":99,\"w\":{}}"
        try Data(future.utf8).write(to: file)
        SnippetUsageFile.mergeAndWrite(singleRecordDocument(idA, weight: 10), liveIDs: nil, now: now,
                                       folderURL: folder, fileURL: file)
        // The writer here is the store, which refuses to flush in read-only
        // mode; mergeAndWrite itself only declines to *merge* the future file.
        #expect(readDocument(at: file) != nil, "the merge still produces a readable file")
    }

    // MARK: - Pruning

    @Test func decayedRecordsAndBindingEntriesAreDroppedOnEveryFlush() {
        let now = 1_785_312_000.0

        // Unconditional mode: decayed-away entries go on every flush.
        var doc = SnippetUsageDocument.empty(now: now)
        let keepID = UUID().uuidString
        let dropID = UUID().uuidString
        doc.records[keepID] = SnippetUsageRecord(weight: 5, count: 1, lastUsedAt: now)
        doc.records[dropID] = SnippetUsageRecord(weight: SnippetFrecency.pruneThreshold / 10,
                                                 count: 1, lastUsedAt: now)
        doc.bindings = ["re": [keepID: 5, dropID: SnippetFrecency.pruneThreshold / 10],
                        "zz": [dropID: SnippetFrecency.pruneThreshold / 10]]
        let pruned = SnippetUsageFile.pruned(doc, liveIDs: nil, now: now)
        #expect(Array(pruned.records.keys) == [keepID], "decayed records are dropped")
        #expect(pruned.bindings["re"]?.count == 1, "decayed binding entries are dropped")
        #expect(pruned.bindings["zz"] == nil, "an emptied binding key is removed")
    }

    @Test func orphanedRecordsAreEvictedBeforeLiveOnesEvenWhenHeavier() {
        let now = 1_785_312_000.0

        // Capacity mode for records: orphans go first, then the lightest.
        let fixture = makeOverCapacityDocument(now: now)
        let pruned = SnippetUsageFile.pruned(fixture.document, liveIDs: fixture.liveIDs, now: now)
        #expect(pruned.records.count == SnippetFrecency.maxRecords, "the record cap is enforced")
        #expect(pruned.records.keys.allSatisfy({ !fixture.orphanIDs.contains($0) }),
                "orphaned UUIDs are evicted before live ones, even when heavier")
    }

    @Test func underTheCapNotASingleOrphanIsEvicted() {
        let now = 1_785_312_000.0
        var random = SeededRandom(seed: 13)

        // Below the cap nothing is evicted — this is what makes
        // "delete, flush, undo" safe.
        var belowCap = SnippetUsageDocument.empty(now: now)
        var fewLive = Set<UUID>()
        for index in 0..<4999 {
            let id = random.uuid()
            belowCap.records[id.uuidString] = SnippetUsageRecord(weight: 10, count: 1, lastUsedAt: now)
            if index >= 4000 { fewLive.insert(id) }
        }
        let pruned = SnippetUsageFile.pruned(belowCap, liveIDs: fewLive, now: now)
        #expect(pruned.records.count == 4999,
                "under the cap not a single orphan is evicted")
    }

    @Test func withNoLiveSetTheOrphanRuleDoesNotRunAtAll() {
        let now = 1_785_312_000.0
        let fixture = makeOverCapacityDocument(now: now)

        // With no live set the orphan rule does not run at all.
        let pruned = SnippetUsageFile.pruned(fixture.document, liveIDs: [], now: now)
        #expect(pruned.records.count == SnippetFrecency.maxRecords, "the cap still applies")
        #expect(pruned.records.keys.contains(where: { fixture.orphanIDs.contains($0) }),
                "with an empty live set the heaviest records are kept regardless of orphanhood")
    }

    @Test func theBindingKeyAndEntryCapsAreEnforced() {
        let now = 1_785_312_000.0
        var random = SeededRandom(seed: 13)

        // Capacity mode for bindings.
        var manyBindings = SnippetUsageDocument.empty(now: now)
        for keyIndex in 0..<500 {
            var table: [String: Double] = [:]
            for entry in 0..<6 {
                table[random.uuid().uuidString] = Double(entry + 1)
            }
            manyBindings.bindings["k\(keyIndex)"] = table
        }
        let pruned = SnippetUsageFile.pruned(manyBindings, liveIDs: nil, now: now)
        #expect(pruned.bindings.count == SnippetFrecency.maxBindingKeys, "the binding key cap is enforced")
        #expect(pruned.bindings.values.allSatisfy({ $0.count <= SnippetFrecency.maxBindingEntriesPerKey }),
                "each binding key keeps at most four entries")
    }

    // MARK: - Recording logic

    @Test func onlyMatchingSnippetAndEventKindCoalesceInsideTheWindow() {
        let id = UUID()
        let other = UUID()

        #expect(
            SnippetFrecency.shouldCoalesce(lastID: nil, lastEventTag: nil, lastAt: nil,
                                           id: id, eventTag: 0, now: 100)
            == false, "the first event is never coalesced")
        #expect(
            SnippetFrecency.shouldCoalesce(lastID: id, lastEventTag: 0, lastAt: 100,
                                           id: id, eventTag: 0, now: 100.2)
            == true, "a repeat of the same event within the window is coalesced")
        #expect(
            SnippetFrecency.shouldCoalesce(lastID: id, lastEventTag: 0, lastAt: 100,
                                           id: other, eventTag: 0, now: 100.2)
            == false, "a different snippet is not coalesced")
        #expect(
            SnippetFrecency.shouldCoalesce(lastID: id, lastEventTag: 0, lastAt: 100,
                                           id: id, eventTag: 0, now: 102)
            == false, "outside the window nothing is coalesced")
        // The reason the key is a pair: a copy and an expansion of the same
        // snippet within a second are two separate intentions.
        #expect(
            SnippetFrecency.shouldCoalesce(lastID: id, lastEventTag: 2, lastAt: 100,
                                           id: id, eventTag: 0, now: 100.2)
            == false, "a different event kind is not coalesced")
    }

    @Test func theFlushDelayShrinksAsTheStalenessCeilingApproaches() {
        #expect(SnippetFrecency.flushDelay(now: 100, firstDirtyAt: nil)
                == SnippetFrecency.persistDebounceSeconds, "a fresh dirty state waits the full debounce")
        #expect(SnippetFrecency.flushDelay(now: 100, firstDirtyAt: 100)
                == SnippetFrecency.persistDebounceSeconds, "so does the first event of a burst")
        // The staleness ceiling: a steady drip of events must not defer the
        // write forever.
        #expect(SnippetFrecency.flushDelay(now: 158, firstDirtyAt: 100) == 2,
                "the delay shrinks as the staleness ceiling approaches")
        #expect(SnippetFrecency.flushDelay(now: 200, firstDirtyAt: 100) == 0,
                "past the ceiling the write happens immediately")
    }

    @Test func aSteadyDripOfEventsStillReachesDisk() {
        // A user expanding something every four seconds still gets writes.
        var writes = 0
        var firstDirty: Double? = nil
        var nextFlushAt = Double.infinity
        for step in 0..<50 {
            let now = Double(step) * 4
            if now >= nextFlushAt { writes += 1; firstDirty = nil; nextFlushAt = .infinity }
            if firstDirty == nil { firstDirty = now }
            nextFlushAt = now + SnippetFrecency.flushDelay(now: now, firstDirtyAt: firstDirty)
        }
        #expect(writes >= 3, "a steady drip of events still reaches disk (got \(writes))")
    }

    // MARK: - Selection memory

    @Test func bindingKeysAreFoldedAndAnOverLongPrefixIsDroppedNotTruncated() {
        #expect(SnippetFrecency.bindingKey(for: "RE") == "re", "binding keys are folded")
        #expect(SnippetFrecency.bindingKey(for: "") == nil, "an empty query has no binding key")
        #expect(SnippetFrecency.bindingKey(for: "screenshotpath") == nil,
                "an over-long prefix is not stored, and is not truncated into an alias")
        #expect(SnippetFrecency.bindingKey(for: "12345678")?.count == 8, "the boundary length is allowed")
    }

    @Test func oneCorrectionEscapesAFiftyTimesReinforcedBinding() throws {
        #expect(SnippetFrecency.bindingRecoveryCorrections == 1, "cap 1.0 means one correction")

        // Saturation, then escape in exactly one correction. Starting from a
        // single acceptance would pass even on a broken unbounded formula.
        let growth = 4.0
        let idA = "A"
        let idB = "B"
        var table: [String: Double] = [:]

        func accept(_ id: String) {
            for other in table.keys where other != id {
                table[other] = (table[other] ?? 0) * SnippetFrecency.bindingCompetitorDecay
            }
            let raised = (table[id] ?? 0) + growth
            table[id] = min(raised, SnippetFrecency.bindingWeightCap * growth)
        }

        for _ in 0..<50 { accept(idA) }
        let saturated = try #require(table[idA])
        expectClose(saturated, growth, tolerance: 1e-9,
                    "the binding weight saturates at the ceiling instead of accumulating")

        accept(idB)
        let decayedA = try #require(table[idA])
        let raisedB = try #require(table[idB])
        expectClose(decayedA, SnippetFrecency.bindingCompetitorDecay * growth,
                    tolerance: 1e-9, "the previous winner decays on a correction")
        expectClose(raisedB, growth, tolerance: 1e-9, "the correction lands at the ceiling")
        #expect(raisedB > decayedA,
                "one correction is enough to escape a 50-times-reinforced binding")

        // The invariant survives a rebase, so the theorem survives it too.
        let doc = SnippetUsageDocument(
            version: 1, epoch: 0, halfLifeDays: SnippetFrecency.halfLifeDays,
            records: [:], bindings: ["re": [idA: decayedA, idB: raisedB]])
        let rebased = SnippetUsageFile.rescaled(doc, toEpoch: 45 * day)
        let rebasedTable = try #require(rebased.bindings["re"])
        let rebasedB = try #require(rebasedTable[idB])
        let rebasedA = try #require(rebasedTable[idA])
        #expect(rebasedB > rebasedA, "the correction still wins after a rebase")
    }

    // MARK: - Directory isolation

    // Automates the blocking manual check from the frecency spec: writing usage
    // data must not trip the file-system monitor that `SnippetStore` installs on
    // the support folder. If it did, every expansion would collapse the editor's
    // 0.3s write debounce and rewrite the whole library while the user is typing.
    @Test func twentyAtomicUsageWritesLeaveTheParentFoldersMonitorSilent() throws {
        let queue = DispatchQueue(label: "usage-isolation-monitor")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippets-isolation-\(UUID().uuidString)", isDirectory: true)
        let usageFolder = root.appendingPathComponent("Usage", isDirectory: true)
        let usageFile = usageFolder.appendingPathComponent("usage.json", isDirectory: false)
        let libraryFile = root.appendingPathComponent("snippets.json", isDirectory: false)

        // Created before the monitor goes up, exactly as `SnippetUsageStore.init`
        // does it relative to `SnippetStore.init`.
        try FileManager.default.createDirectory(at: usageFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let monitor = try #require(FolderMonitor(folder: root, queue: queue),
                                   "could not observe the temporary support folder")
        defer { monitor.cancel() }
        settle(queue)

        let baseline = monitor.firedCount
        var document = SnippetUsageDocument.empty(now: 1_785_312_000)
        for index in 0..<20 {
            document.records[UUID().uuidString] =
                SnippetUsageRecord(weight: Double(index + 1), count: 1, lastUsedAt: 1_785_312_000)
            let wrote = SnippetUsageFile.mergeAndWrite(
                document, liveIDs: nil, now: 1_785_312_000,
                folderURL: usageFolder, fileURL: usageFile)
            #expect(wrote, "usage write \(index) succeeded")
        }
        settle(queue)

        #expect(monitor.firedCount == baseline,
                "20 atomic usage writes leave the parent folder's monitor silent")
        #expect(document.records.count == 20, "the fixture really did write 20 records")
        #expect(FileManager.default.fileExists(atPath: usageFile.path), "the usage file exists")

        // Permissions come from the same write path.
        let attributes = try FileManager.default.attributesOfItem(atPath: usageFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600,
                "usage data is written owner-only")

        // The negative control. Without this the test above would also pass
        // with a monitor that never fires at all, which would prove nothing.
        try Data("{}".utf8).write(to: libraryFile, options: .atomic)
        settle(queue)
        #expect(monitor.firedCount > baseline,
                "a write directly into the support folder does fire the monitor")
    }
}
