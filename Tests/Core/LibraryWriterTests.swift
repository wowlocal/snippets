import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

@testable import SnippetsCore

// Tests for the write path: `AtomicFileWriter`, `LibraryLock`, `SnippetLibraryCodec`,
// and the `LibraryWriter.update` funnel that ties the three together.
//
// Every test here works in its own directory under the system temporary directory.
// Nothing in this file may ever name `SnippetStorageLocations.supportFolderURL` or
// any of its children: `swift test` runs suites in parallel and the real support
// folder belongs to the user's running app.
//
// Holding to that rule turned up a source bug: see the note at the bottom of this
// file for the parameter that had to be added before the generation counter could be
// tested at all.

@Suite struct LibraryWriterTests {

    // MARK: - AtomicFileWriter

    /// The claim in `AtomicFileWriter`'s header is that a reader sees "either the
    /// previous contents or the new contents — never a mixture". A single-threaded
    /// before/after assertion cannot distinguish that from a plain `write(2)` loop,
    /// so this drives a concurrent reader across a run of renames and checks every
    /// single thing it saw.
    ///
    /// The two payloads have different lengths, so a torn write is detectable by size
    /// alone, and both are far larger than one `write(2)` will accept in a single
    /// call — which is what exercises the `writeAll` loop the header calls "the
    /// contract" rather than "defensive programming". The writer alternates so the
    /// reader is guaranteed to straddle a rename; seeing *both* states is asserted,
    /// because a reader that only ever saw the final file would prove nothing.
    ///
    /// Two things here are about the *test* being sound rather than about the writer,
    /// and both were failures observed in the full parallel suite:
    ///
    /// 1. The reader gets a dedicated `Thread`, not `DispatchQueue.global()`. With the
    ///    whole suite in flight the global pool is saturated, and the reader block was
    ///    not scheduled until after `stop()` — the loop body never ran once, and the
    ///    test then failed reporting a torn write for a file nothing had looked at.
    /// 2. The writer alternates until the reader has actually observed both states,
    ///    not for a fixed number of passes. Under load an entire pass can land between
    ///    two of the reader's `read(2)`s, and "how many renames happened" is not the
    ///    property under test — "did a reader that was watching ever see a mixture" is.
    @Test func aConcurrentReaderNeverObservesAPartiallyWrittenFile() throws {
        let sandbox = try Sandbox("partial")
        defer { sandbox.destroy() }

        let shorter = Data(repeating: 0x41, count: 2 << 20)
        let longer = repeatingPattern(byteCount: 3 << 20)
        let shorterDigest = SnippetLibraryCodec.digest(of: shorter)
        let longerDigest = SnippetLibraryCodec.digest(of: longer)

        try AtomicFileWriter.write(shorter, to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)

        let reader = ObservationLog()
        let readerFinished = DispatchSemaphore(value: 0)
        let readerThread = Thread { [library = sandbox.library] in
            while !reader.isStopped {
                reader.record(try? Data(contentsOf: library))
            }
            readerFinished.signal()
        }
        readerThread.qualityOfService = .userInitiated
        readerThread.start()
        try #require(reader.waitForFirstObservation(timeout: 60),
                     "the reader thread never ran, so nothing below would be meaningful")

        // The deadline only bounds a hang; it is never asserted on, so the verdict
        // stays a function of what the reader saw rather than of machine speed.
        let deadline = Date().addingTimeInterval(60)
        var pass = 0
        while Date() < deadline {
            try AtomicFileWriter.write(
                pass.isMultiple(of: 2) ? longer : shorter,
                to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)
            pass += 1
            let seen = reader.distinctDigests
            if pass >= 12, seen.contains(shorterDigest), seen.contains(longerDigest) { break }
        }
        // Pin the end state regardless of which payload the loop happened to stop on.
        try AtomicFileWriter.write(shorter, to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)

        reader.stop()
        #expect(readerFinished.wait(timeout: .now() + 60) == .success)

        let observed = reader.distinctDigests
        #expect(observed.contains(shorterDigest) && observed.contains(longerDigest),
                """
                the reader never straddled a rename in \(pass) passes and \
                \(reader.observationCount) reads, so it did not test anything
                """)
        let unexpected = observed.subtracting([shorterDigest, longerDigest])
        #expect(unexpected.isEmpty,
                "a reader saw \(unexpected.count) state(s) that were neither the old nor the new file")

        #expect(try Data(contentsOf: sandbox.library) == shorter)
        #expect(entries(of: sandbox.tmpFolder) == [])
    }

    /// `snippets.json` can hold anything the user has ever copied, so the file must
    /// not be group- or world-readable. `mkstemp` already creates at 0600; the
    /// explicit `fchmod` is what makes that true regardless of umask, and — because
    /// `rename(2)` replaces the inode — it is also what *tightens* an existing file
    /// that some earlier build or a restore left at 0644.
    @Test func writingTightensPermissionsToOwnerOnlyEvenOverAWideOpenExistingFile() throws {
        let sandbox = try Sandbox("permissions")
        defer { sandbox.destroy() }

        FileManager.default.createFile(
            atPath: sandbox.library.path, contents: Data("stale".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o644 as mode_t)])
        #expect(permissions(of: sandbox.library) == 0o644)

        try AtomicFileWriter.write(Data("fresh".utf8), to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)
        #expect(permissions(of: sandbox.library) == 0o600)

        // The parameter is honoured, so a caller that genuinely wants a shared file
        // does not have to reimplement the writer.
        let shared = sandbox.root.appendingPathComponent("shared.json")
        try AtomicFileWriter.write(Data("x".utf8), to: shared, temporaryDirectory: sandbox.tmpFolder, permissions: 0o644)
        #expect(permissions(of: shared) == 0o644)
    }

    /// Staging outside the destination directory is not a tidiness preference: the
    /// app watches the support folder with a `DispatchSource`, and a temp file
    /// created next to `snippets.json` costs a second monitor event that arrives
    /// while the file is half written. So the destination directory must contain
    /// exactly the destination, and the temp directory must be empty again the
    /// instant the write returns.
    @Test func theWriteStagesInTheGivenTemporaryDirectoryAndLeavesNothingBehind() throws {
        let sandbox = try Sandbox("staging")
        defer { sandbox.destroy() }

        // A directory that does not exist yet, so its later existence is proof the
        // writer actually used the directory it was handed.
        let stagingArea = sandbox.root.appendingPathComponent("Staging", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: stagingArea.path))

        try AtomicFileWriter.write(Data("body".utf8), to: sandbox.library, temporaryDirectory: stagingArea)

        #expect(FileManager.default.fileExists(atPath: stagingArea.path))
        #expect(entries(of: stagingArea) == [], "a temporary file survived a successful write")
        #expect(entries(of: sandbox.root).contains("snippets.json"))
        #expect(!entries(of: sandbox.root).contains { $0.hasPrefix("snippets.json.") },
                "the destination directory picked up a staging file, which doubles the folder monitor's events")
    }

    /// The `defer { if shouldUnlink { unlink(temporaryPath) } }` in the writer is the
    /// only thing standing between a failing write and an ever-growing `Tmp/`. The
    /// failure is induced past `mkstemp`, `write`, and `fsync` — the destination is a
    /// directory, so only the `rename(2)` can fail — which is precisely the window
    /// where a temp file exists and could be orphaned.
    @Test func aFailedWriteLeavesTheOldContentsIntactAndNoTemporaryFileBehind() throws {
        let sandbox = try Sandbox("failed-write")
        defer { sandbox.destroy() }

        let destination = sandbox.root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let failure = #expect(throws: AtomicFileWriter.Failure.self) {
            try AtomicFileWriter.write(Data("body".utf8), to: destination, temporaryDirectory: sandbox.tmpFolder)
        }
        guard case .renameFailed = try #require(failure) else {
            Issue.record("expected a rename failure, got \(String(describing: failure))")
            return
        }
        #expect(entries(of: sandbox.tmpFolder) == [], "a failed write orphaned its temporary file")

        // A temp directory that cannot be created at all fails before anything is
        // staged, and must still leave the destination alone.
        try AtomicFileWriter.write(Data("original".utf8), to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)
        let blocked = sandbox.root.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: blocked.path, contents: Data())

        let openFailure = #expect(throws: AtomicFileWriter.Failure.self) {
            try AtomicFileWriter.write(Data("replacement".utf8), to: sandbox.library, temporaryDirectory: blocked)
        }
        guard case .cannotCreateTemporary = try #require(openFailure) else {
            Issue.record("expected a temporary-file failure, got \(String(describing: openFailure))")
            return
        }
        #expect(try Data(contentsOf: sandbox.library) == Data("original".utf8))
        #expect(entries(of: sandbox.tmpFolder) == [])
    }

    // MARK: - LibraryLock, across real processes

    /// The whole point of `LibraryLock` is cross-*process* exclusion between the app
    /// and `snippets-cli`. An in-process test would pass just as happily if `flock`
    /// were swapped for an `NSLock`, so this spawns real processes.
    ///
    /// The helper is a tiny `main.swift` compiled against the shipping
    /// `LibraryLock.swift` and `Snippet.swift` — not a re-implementation — so what is
    /// under test is the code the app runs. (`python3` with `fcntl.flock` would also
    /// work and needs no compiler, but it would test *a* flock rather than *this*
    /// one, including the timeout, the poll jitter, and the O_CREAT-without-O_TRUNC
    /// open.) Each process does the exact read-modify-write the header describes as
    /// losing "roughly two thirds" of its writes when unsynchronised; the sleep
    /// between read and write widens that window so a broken lock fails every run
    /// rather than one in fifty.
    @Test func theLibraryLockIsMutuallyExclusiveAcrossProcesses() throws {
        let sandbox = try Sandbox("cross-process")
        defer { sandbox.destroy() }

        let helper = try compileLockHelper(into: sandbox)
        let ledger = sandbox.root.appendingPathComponent("ledger.txt")
        let startLine = sandbox.root.appendingPathComponent("go")
        FileManager.default.createFile(atPath: ledger.path, contents: Data())

        let writerCount = 6
        let appendsPerWriter = 20
        var processes: [Process] = []
        for writer in 0..<writerCount {
            let process = Process()
            process.executableURL = helper
            process.arguments = [
                sandbox.lockFile.path, ledger.path, startLine.path,
                "writer\(writer)", String(appendsPerWriter),
            ]
            try process.run()
            processes.append(process)
        }
        // Released only once every process is up, so they genuinely contend.
        FileManager.default.createFile(atPath: startLine.path, contents: Data())

        for process in processes {
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "a locking helper exited with \(process.terminationStatus)")
        }

        let lines = try String(contentsOf: ledger, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == writerCount * appendsPerWriter,
                "\(writerCount * appendsPerWriter - lines.count) appends were lost; the lock did not serialise the writers")
        for writer in 0..<writerCount {
            #expect(lines.filter { $0 == "writer\(writer)" }.count == appendsPerWriter)
        }
    }

    /// `flock` binds to an open file description, i.e. to an inode. Every write in
    /// this codebase ends in `rename(2)`, which points a path at a *new* inode — so
    /// if the lock file were ever replaced, two processes would flock two different
    /// inodes and both would proceed. The header calls this "as bad as no lock at
    /// all", so the invariant is asserted directly: the lock file's inode must be
    /// the same one after a pile of writes, and it must still be zero bytes because
    /// `O_CREAT` is deliberately not `O_TRUNC`.
    ///
    /// The contrast is the point of the test: `snippets.json`'s inode *does* change,
    /// which is exactly why the lock cannot live on it.
    @Test func theLockFileKeepsOneInodeWhileTheLibraryGetsANewOneEveryWrite() throws {
        let sandbox = try Sandbox("lock-inode")
        defer { sandbox.destroy() }

        _ = try update(sandbox) { _ in [makeSnippet(index: 0)] }
        let lockAtStart = try #require(identity(of: sandbox.lockFile))
        let libraryAtStart = try #require(identity(of: sandbox.library))

        var libraryInodes: Set<UInt64> = [libraryAtStart.inode]
        for index in 1...25 {
            _ = try update(sandbox) { snapshot in snapshot.snippets + [makeSnippet(index: index)] }
            libraryInodes.insert(try #require(identity(of: sandbox.library)).inode)
        }

        let lockAtEnd = try #require(identity(of: sandbox.lockFile))
        #expect(lockAtEnd.inode == lockAtStart.inode,
                "the lock file was replaced; every process still holding the old inode has silently lost mutual exclusion")
        #expect(lockAtEnd.size == 0, "the lock file was written to; it is a pure flock target and must stay empty")
        #expect(libraryInodes.count == 26,
                "the library was not republished by rename; if it were locked directly, writers would hold different inodes")
    }

    /// A blocking `flock(LOCK_EX)` cannot be interrupted, and `SnippetStore` flushes
    /// from `applicationWillTerminate` on the main thread — so a wedged peer would
    /// hang quit until macOS killed the app before it wrote anything. The contract is
    /// therefore "fail by the deadline", never "wait".
    ///
    /// The semaphore is the assertion that matters: if `acquire` hung, the wait times
    /// out and the test fails rather than blocking the whole suite forever. Elapsed
    /// time is measured on a monotonic clock, and the upper bound is loose on purpose
    /// — tests run in parallel and a tight bound would flake under load without
    /// proving anything the semaphore does not already prove.
    @Test func aHeldLockMakesAnotherAcquireTimeOutInsteadOfHanging() throws {
        let sandbox = try Sandbox("timeout")
        defer { sandbox.destroy() }

        let held = try LibraryLock.acquire(at: sandbox.lockFile, timeout: 5)
        defer { held.release() }

        let requested: TimeInterval = 0.25
        let attempt = AcquireAttempt()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [lockFile = sandbox.lockFile] in
            let start = DispatchTime.now()
            do {
                let unexpected = try LibraryLock.acquire(at: lockFile, timeout: requested)
                unexpected.release()
                attempt.succeeded = true
            } catch let failure as LibraryLock.Failure {
                attempt.failure = failure
            } catch {
                attempt.otherError = error
            }
            attempt.elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 30) == .success,
                "acquiring a held lock hung; a wedged peer would now hang the app's terminate path")
        #expect(!attempt.succeeded, "two holders of the same lock at once")

        guard case .timedOut(let path, let seconds) = try #require(attempt.failure) else {
            Issue.record("expected a timeout, got \(String(describing: attempt.failure))")
            return
        }
        #expect(path == sandbox.lockFile.path)
        #expect(seconds == requested)
        #expect(attempt.elapsed >= requested * 0.9, "gave up before the caller's deadline")
        #expect(attempt.elapsed < requested + 5, "took far longer than the requested \(requested)s")

        // A timeout means a peer really holds the lock, so the caller must back off
        // rather than write anyway; an open failure means the filesystem has no
        // advisory locking, where refusing to write would brick the app.
        #expect(LibraryLockPolicy.isFatal(.timedOut(path: sandbox.lockFile.path, seconds: 1)))
        #expect(!LibraryLockPolicy.isFatal(.cannotOpen(path: sandbox.lockFile.path, errno: EPERM)))
    }

    /// A PID is not a process identity: after the owner crashes, macOS can assign its
    /// PID to an unrelated process. The old sentinel then looked permanently live and
    /// every future write on a no-`flock` filesystem timed out forever. A mismatched
    /// start generation must be stolen even when `kill(pid, 0)` says that PID exists.
    @Test func aSentinelOwnedByAnEarlierIncarnationOfALivePIDIsStolen() throws {
        let sandbox = try Sandbox("sentinel-pid-reuse")
        defer { sandbox.destroy() }

        let sentinel = sandbox.lockFile.appendingPathExtension("sentinel")
        let actual = try #require(SentinelLock.processGeneration(for: getpid()))
        let impossibleMicroseconds = actual.microseconds + 1
        let staleOwner = "\(ProcessInfo.processInfo.hostName)\n\(getpid())\n"
            + "\(actual.seconds)\n\(impossibleMicroseconds)\n"
        try staleOwner.write(to: sentinel, atomically: false, encoding: .utf8)

        // This times out on the PID-only implementation because the test process is
        // demonstrably alive. With the generation check it replaces the stale name.
        let held = try SentinelLock.acquire(sentinelURL: sentinel, timeout: 0.25)
        defer { held.release() }

        let replacement = try String(contentsOf: sentinel, encoding: .utf8)
        #expect(replacement != staleOwner)
        #expect(replacement.contains("\n\(actual.seconds)\n\(actual.microseconds)\n"))
    }

    @Test func aStaleLegacySentinelCannotBeHeldForeverByAReusedLivePID() throws {
        let sandbox = try Sandbox("sentinel-legacy-pid-reuse")
        defer { sandbox.destroy() }

        let sentinel = sandbox.lockFile.appendingPathExtension("sentinel")
        let legacyOwner = "\(ProcessInfo.processInfo.hostName)\n\(getpid())\n"
        try legacyOwner.write(to: sentinel, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(SentinelLock.staleAfter + 1))],
            ofItemAtPath: sentinel.path)

        let held = try SentinelLock.acquire(sentinelURL: sentinel, timeout: 0.25)
        defer { held.release() }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) != legacyOwner)
    }

    /// The policy above, as `LibraryWriter` applies it: a contended lock surfaces as
    /// `.busy` and the transform never runs, so a caller cannot accidentally publish
    /// a decision made from a snapshot it was never allowed to take.
    @Test func anUpdateThatCannotTakeTheLockFailsBusyWithoutTouchingTheFile() throws {
        let sandbox = try Sandbox("busy")
        defer { sandbox.destroy() }

        _ = try update(sandbox) { _ in [makeSnippet(index: 1)] }
        let before = try #require(identity(of: sandbox.library))
        let bytesBefore = try Data(contentsOf: sandbox.library)

        let held = try LibraryLock.acquire(at: sandbox.lockFile, timeout: 5)
        defer { held.release() }

        var transformRan = false
        let failure = #expect(throws: LibraryWriter.Failure.self) {
            _ = try self.update(sandbox, lockTimeout: 0.05) { _ in
                transformRan = true
                return []
            }
        }
        guard case .busy = try #require(failure) else {
            Issue.record("expected .busy, got \(String(describing: failure))")
            return
        }
        #expect(!transformRan, "the transform ran without the lock; its snapshot could already be stale")
        #expect(identity(of: sandbox.library) == before)
        #expect(try Data(contentsOf: sandbox.library) == bytesBefore)
    }

    // MARK: - The compare-and-swap funnel

    /// The exact interleaving `LibraryGeneration.swift` documents:
    ///
    ///   the caller believed digest D1; another writer has since put D2 on disk; the
    ///   caller writes from its own in-memory array and the other writer's edit is
    ///   gone, with every actor having behaved correctly.
    ///
    /// The fix is that `transform` is handed what is genuinely on disk *inside the
    /// lock*, not what the caller believed. So this asserts three things: the
    /// snapshot carries D2 rather than D1, `foldedInForeignWrite` is set so the UI
    /// can be told the library moved underneath it, and the foreign record is still
    /// there afterwards.
    @Test func updateFoldsInAConcurrentForeignWriteAndKeepsTheOtherWritersRecord() throws {
        let sandbox = try Sandbox("fold-in")
        defer { sandbox.destroy() }

        let mine = makeSnippet(index: 1, name: "Signature", keyword: "sig", content: "Best, Ada")
        let theirs = makeSnippet(index: 2, name: "Address", keyword: "addr", content: "1 Analytical Way")

        let first = try update(sandbox) { _ in [mine] }
        let believedDigest = first.digest
        #expect(!first.foldedInForeignWrite)

        // The other writer, between the caller's read and its write.
        let foreignBytes = try SnippetLibraryCodec.encode([mine, theirs])
        try AtomicFileWriter.write(foreignBytes, to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)
        let foreignDigest = SnippetLibraryCodec.digest(of: foreignBytes)
        #expect(foreignDigest != believedDigest)

        var edited = mine
        edited.content = "Warmly, Ada"
        var snapshotDigest: String?
        let outcome = try update(sandbox, expectedDigest: believedDigest) { snapshot in
            snapshotDigest = snapshot.digest
            // What a real caller does: reconcile its own change against disk truth
            // rather than overwrite with its stale array.
            return snapshot.snippets.map { $0.id == edited.id ? edited : $0 }
        }

        #expect(snapshotDigest == foreignDigest,
                "the transform was handed the caller's stale belief instead of what is on disk")
        #expect(outcome.foldedInForeignWrite,
                "a foreign write went unreported, so the UI would keep showing a library that no longer exists")
        #expect(!outcome.wroteWithoutLock)

        let onDisk = try SnippetLibraryCodec.decode(try Data(contentsOf: sandbox.library))
        #expect(onDisk.count == 2)
        #expect(onDisk.contains { $0.id == theirs.id && $0.content == theirs.content },
                "the other writer's record was clobbered — the exact loss this funnel exists to prevent")
        #expect(onDisk.contains { $0.id == mine.id && $0.content == "Warmly, Ada" })
        #expect(outcome.digest == SnippetLibraryCodec.digest(of: try Data(contentsOf: sandbox.library)))
    }

    /// `foldedInForeignWrite` is derived from bytes, not from the decoded model, so a
    /// foreign writer that merely reformatted the file still counts as a change the
    /// caller has not seen. That is what keeps `jq`, `vim`, and a Time Machine
    /// restore first-class writers rather than invisible ones.
    @Test func aReformattedFileStillCountsAsAForeignWriteEvenThoughItDecodesIdentically() throws {
        let sandbox = try Sandbox("reformatted")
        defer { sandbox.destroy() }

        let snippets = [makeSnippet(index: 1), makeSnippet(index: 2)]
        let canonical = try SnippetLibraryCodec.encode(snippets)
        let believedDigest = SnippetLibraryCodec.digest(of: canonical)
        try AtomicFileWriter.write(canonical, to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)

        // Same records, different bytes: the `{"snippets": …}` dialect an export or a
        // hand-edit can leave behind.
        let reformatted = try SnippetLibraryCodec.encodeCollection(snippets)
        #expect(try SnippetLibraryCodec.decode(reformatted) == snippets)
        #expect(SnippetLibraryCodec.digest(of: reformatted) != believedDigest)
        try AtomicFileWriter.write(reformatted, to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)

        let outcome = try update(sandbox, expectedDigest: believedDigest) { $0.snippets }
        #expect(outcome.foldedInForeignWrite)
        // Identical records, different bytes: the funnel rewrites once, back to the
        // canonical form, and the next pass is a no-op.
        #expect(outcome.data == canonical)
        let settled = try update(sandbox, expectedDigest: outcome.digest) { $0.snippets }
        #expect(!settled.foldedInForeignWrite)
    }

    /// Once sync is live, a write that changes nothing is a change event on every
    /// other device, which answers with a write of its own. Skipping the write is
    /// what stops that loop. The inode is the strong assertion — `rename(2)` cannot
    /// republish a file without changing it — and the modification timestamp catches
    /// an in-place rewrite that kept the inode.
    @Test func aTransformThatChangesNothingLeavesTheFileCompletelyUntouched() throws {
        let sandbox = try Sandbox("no-op")
        defer { sandbox.destroy() }

        let written = try update(sandbox) { _ in [makeSnippet(index: 1), makeSnippet(index: 2)] }
        let before = try #require(identity(of: sandbox.library))

        let outcome = try update(sandbox, expectedDigest: written.digest) { snapshot in snapshot.snippets }

        #expect(identity(of: sandbox.library) == before,
                "an identical library was republished; two synced devices would now answer each other forever")
        #expect(outcome.data == written.data)
        #expect(outcome.digest == written.digest)
        #expect(!outcome.foldedInForeignWrite)
        #expect(entries(of: sandbox.tmpFolder) == [], "a no-op write still staged a temporary file")

        // Reordering *is* a storage change even though presentation now applies a
        // canonical order: the digest is a compare-and-swap token over exact bytes.
        let reordered = try update(sandbox, expectedDigest: outcome.digest) { $0.snippets.reversed() }
        #expect(identity(of: sandbox.library) != before)
        #expect(reordered.digest != written.digest)
    }

    /// The no-op path still has to report that the bytes moved, or a caller whose
    /// pending edit happened to be a no-op would never learn that someone else's
    /// edit landed — and would keep showing the old library.
    @Test func aNoOpUpdateStillReportsThatSomebodyElseWroteTheFile() throws {
        let sandbox = try Sandbox("no-op-foreign")
        defer { sandbox.destroy() }

        _ = try update(sandbox) { _ in [makeSnippet(index: 1)] }
        let staleDigest = "0000000000000000000000000000000000000000000000000000000000000000"
        let before = try #require(identity(of: sandbox.library))

        let outcome = try update(sandbox, expectedDigest: staleDigest) { $0.snippets }
        #expect(outcome.foldedInForeignWrite)
        #expect(identity(of: sandbox.library) == before)
    }

    /// `Snippet.init(from:)` normalises tags on the way in and `encode(to:)` writes
    /// them back verbatim, so a file written by `vim` or an older build is not a
    /// fixed point of the codec: the first cooperating write canonicalises it. The
    /// guarantee that matters is that this happens exactly *once* — otherwise the
    /// ping-pong the no-op check prevents would simply move one level up.
    @Test func aDenormalizedFileIsCanonicalizedOnceAndThenStopsChanging() throws {
        let sandbox = try Sandbox("canonicalize")
        defer { sandbox.destroy() }

        var handEdited = makeSnippet(index: 1)
        handEdited.tags = ["Work", " work ", "WORK", "  ", "Email"]
        try AtomicFileWriter.write(
            try SnippetLibraryCodec.encode([handEdited]),
            to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)
        let beforeFirstPass = try #require(identity(of: sandbox.library))

        let first = try update(sandbox) { $0.snippets }
        #expect(identity(of: sandbox.library) != beforeFirstPass)
        #expect(first.snippets.first?.tags == ["Work", "Email"])

        let afterFirstPass = try #require(identity(of: sandbox.library))
        let second = try update(sandbox, expectedDigest: first.digest) { $0.snippets }
        #expect(identity(of: sandbox.library) == afterFirstPass,
                "canonicalisation did not converge; every write would trigger the next one")
        #expect(second.digest == first.digest)
    }

    // MARK: - SnippetLibraryCodec, the frozen format

    /// The format is frozen because an older binary that opens a newer file strips
    /// every key it does not know and writes the stripped version back. "Frozen"
    /// operationally means: read a file, write it back, and the bytes are identical
    /// — no reordering, no re-escaping, no lost precision on the dates. Anything
    /// less would show up on every device as a spurious external-change event.
    ///
    /// The library is generated from a seeded xorshift so a failure reproduces
    /// exactly; timestamps use exact binary fractions so the assertion is about the
    /// encoder rather than about float formatting.
    @Test func encodingADecodedLibraryReproducesTheOriginalBytesExactly() throws {
        let sandbox = try Sandbox("byte-identity")
        defer { sandbox.destroy() }

        let library = makeRealisticLibrary(count: 40, seed: 0x5EED_1234)
        let original = try SnippetLibraryCodec.encode(library)
        try AtomicFileWriter.write(original, to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)

        let fromDisk = try Data(contentsOf: sandbox.library)
        #expect(fromDisk == original)

        let decoded = try SnippetLibraryCodec.decode(fromDisk)
        #expect(decoded == library)
        let reencoded = try SnippetLibraryCodec.encode(decoded)
        #expect(reencoded == fromDisk, "re-encoding a decoded library changed the bytes; the format is not frozen")
        #expect(SnippetLibraryCodec.digest(of: reencoded) == SnippetLibraryCodec.digest(of: fromDisk))

        // And once more, so a one-off normalisation could not masquerade as stability.
        #expect(try SnippetLibraryCodec.encode(try SnippetLibraryCodec.decode(reencoded)) == fromDisk)
    }

    /// "It will not gain a tenth key, ever." Asserted against the serialised JSON
    /// rather than against `CodingKeys`, because it is the bytes an older build sees
    /// that decide whether anything gets stripped.
    @Test func everyEncodedSnippetCarriesExactlyTheNineFrozenKeys() throws {
        let library = makeRealisticLibrary(count: 12, seed: 0xC0FFEE)
        let objects = try #require(
            try JSONSerialization.jsonObject(with: try SnippetLibraryCodec.encode(library)) as? [[String: Any]])

        let frozenKeys: Set<String> = [
            "id", "name", "keyword", "content", "tags", "isEnabled", "isPinned", "createdAt", "updatedAt",
        ]
        #expect(objects.count == library.count)
        for object in objects {
            #expect(Set(object.keys) == frozenKeys, "unexpected keys: \(Set(object.keys).symmetricDifference(frozenKeys))")
        }

        // The exact wire form, pinned. Changing `outputFormatting` would rewrite
        // every user's file on first launch and fire an external-change event on
        // every other device.
        let pinned = Snippet(
            id: try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001")),
            name: "Sig \"quoted\"", keyword: "sig", content: "line1\nline2\ttab\\slash",
            tags: ["Work"], isEnabled: true, isPinned: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000.25),
            updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_123.5))
        let expected = """
        [
          {
            "content" : "line1\\nline2\\ttab\\\\slash",
            "createdAt" : 700000000.25,
            "id" : "00000000-0000-4000-8000-000000000001",
            "isEnabled" : true,
            "isPinned" : false,
            "keyword" : "sig",
            "name" : "Sig \\"quoted\\"",
            "tags" : [
              "Work"
            ],
            "updatedAt" : 700000123.5
          }
        ]
        """
        #expect(String(data: try SnippetLibraryCodec.encode([pinned]), encoding: .utf8) == expected)
    }

    /// Both dialects have always been accepted — the bare array the app writes and
    /// the `{"snippets": …}` wrapper `exportSnippets(to:)` produces — because a user
    /// who moves an export into place must not lose their library. The Raycast
    /// dialect deliberately is *not* accepted here: that belongs to the import path,
    /// where the user explicitly chose a foreign file.
    @Test func decodeAcceptsBothTheBareArrayAndTheSnippetsWrapperButNoOtherDialect() throws {
        let library = makeRealisticLibrary(count: 5, seed: 0xABCD)

        #expect(try SnippetLibraryCodec.decode(try SnippetLibraryCodec.encode(library)) == library)
        #expect(try SnippetLibraryCodec.decode(try SnippetLibraryCodec.encodeCollection(library)) == library)
        #expect(try SnippetLibraryCodec.decode(Data("[]".utf8)) == [])

        let raycast = Data("""
        {"snippets":[{"name":"Sig","text":"Best, Ada","keyword":"sig"}]}
        """.utf8)
        #expect(throws: SnippetLibraryCodec.Failure.self) {
            _ = try SnippetLibraryCodec.decode(raycast)
        }
    }

    /// The digest is the compare-and-swap token and is taken over bytes on purpose:
    /// a writer that reordered keys or reformatted the file *has* changed the file,
    /// and the merge has to run even though the decoded arrays compare equal.
    @Test func theDigestIsTakenOverBytesSoAReformatIsStillAChange() throws {
        let library = makeRealisticLibrary(count: 6, seed: 0xFACE)
        let bare = try SnippetLibraryCodec.encode(library)
        let wrapped = try SnippetLibraryCodec.encodeCollection(library)

        #expect(try SnippetLibraryCodec.decode(bare) == (try SnippetLibraryCodec.decode(wrapped)))
        #expect(SnippetLibraryCodec.digest(of: bare) != SnippetLibraryCodec.digest(of: wrapped))
        #expect(SnippetLibraryCodec.digest(of: bare) == SnippetLibraryCodec.digest(of: bare))
        #expect(SnippetLibraryCodec.digest(of: Data()).count == 64)
    }

    // MARK: - Unreadable input

    /// A decode failure must never be able to present as "the user has no snippets",
    /// because the very next thing that happens to an empty library is that it gets
    /// saved. So an undecodable file throws out of `read`, throws out of `update`
    /// before the transform is even consulted, and leaves the damaged bytes exactly
    /// where they are for the quarantine path to deal with.
    @Test func anUndecodableLibraryThrowsRatherThanPresentingAsAnEmptyLibrary() throws {
        let sandbox = try Sandbox("undecodable")
        defer { sandbox.destroy() }

        let damaged: [String: Data] = [
            "not JSON at all": Data("this is not json".utf8),
            "truncated mid-record": Data("[{\"id\":\"00000000-0000-4000-8000-0000000".utf8),
            "an object that is not the wrapper": Data("{\"records\":[]}".utf8),
            "a record missing its id": Data("[{\"name\":\"Sig\",\"keyword\":\"sig\",\"content\":\"x\"}]".utf8),
            "empty file": Data(),
        ]

        for (description, bytes) in damaged {
            try AtomicFileWriter.write(bytes, to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)
            let before = try #require(identity(of: sandbox.library))

            #expect(throws: SnippetLibraryCodec.Failure.self, "\(description) decoded") {
                _ = try SnippetLibraryCodec.decode(bytes)
            }

            let readFailure = #expect(throws: LibraryWriter.Failure.self, "\(description) read as a library") {
                _ = try LibraryWriter.read(from: sandbox.library)
            }
            guard case .unreadable = try #require(readFailure) else {
                Issue.record("expected .unreadable for \(description), got \(String(describing: readFailure))")
                return
            }

            var transformRan = false
            #expect(throws: LibraryWriter.Failure.self, "\(description) was written over") {
                _ = try self.update(sandbox) { _ in
                    transformRan = true
                    return []
                }
            }
            #expect(!transformRan, "the transform saw \(description) as a library it could edit")
            #expect(try Data(contentsOf: sandbox.library) == bytes, "\(description) was modified")
            #expect(identity(of: sandbox.library) == before)
        }
    }

    /// The other half of the same rule: a file that is simply *absent* is a genuine
    /// empty library — first launch — and must not throw, or the app could never
    /// write its starter snippet. `SnippetLibraryCodec.read` reports the same
    /// distinction as `nil` rather than as an empty array.
    @Test func aMissingLibraryIsAnEmptyLibraryRatherThanAnError() throws {
        let sandbox = try Sandbox("missing")
        defer { sandbox.destroy() }

        #expect(try SnippetLibraryCodec.read(from: sandbox.library) == nil)
        let snapshot = try LibraryWriter.read(from: sandbox.library)  // missing file
        #expect(snapshot == LibraryWriter.Snapshot.missing)
        #expect(snapshot.snippets.isEmpty)
        #expect(snapshot.digest.isEmpty)

        let outcome = try update(sandbox) { _ in [Snippet.starterSnippet] }
        #expect(outcome.snippets.count == 1)
        #expect(!outcome.foldedInForeignWrite, "a first write reported a foreign write it could not have seen")
        #expect(try SnippetLibraryCodec.read(from: sandbox.library)?.snippets.count == 1)
    }

    // MARK: - The generation counter

    /// The counter's whole job is to let a later reader say "somebody wrote this file
    /// without going through the funnel". That only works if a cooperating write moves
    /// it by exactly one and records the bytes it produced, so the *next* write can
    /// compare what it found against what we claim we left.
    @Test func aCooperatingWriteAdvancesTheGenerationByOneAndRecordsTheBytesItWrote() throws {
        let sandbox = try Sandbox("generation-one")
        defer { sandbox.destroy() }
        try seedState(sandbox, generation: 7)

        let outcome = try update(sandbox) { _ in [makeSnippet(index: 1, name: "First", keyword: "one")] }

        let state = try #require(loadState(sandbox))
        #expect(state.generation == 8)
        #expect(state.librarySHA256 == outcome.digest)
        // Everything else in the file is this device's identity, which a library write
        // has no business touching.
        #expect(state.deviceID == "a1b2c3d4")
        #expect(state.scopeID == "fixed-scope")
    }

    /// The double bump is the alarm, not an off-by-one: when the digest we recorded
    /// last time is not the digest actually on disk, some non-participating writer got
    /// in between. Recording that as a *gap* is what lets `doctor` notice, so the two
    /// increments must be distinguishable from two ordinary writes.
    @Test func aWriteOverSomebodyElsesBytesAdvancesTheGenerationTwiceToLeaveAGap() throws {
        let sandbox = try Sandbox("generation-gap")
        defer { sandbox.destroy() }
        try seedState(sandbox, generation: 7)

        // A first cooperating write, so state.json holds a digest to disagree with.
        _ = try update(sandbox) { _ in [makeSnippet(index: 1, name: "First", keyword: "one")] }
        #expect(loadState(sandbox)?.generation == 8)

        // Somebody outside the funnel rewrites the library — an old build, `vim`.
        try AtomicFileWriter.write(
            try SnippetLibraryCodec.encode([makeSnippet(index: 2, name: "Stranger", keyword: "two")]),
            to: sandbox.library, temporaryDirectory: sandbox.tmpFolder)

        _ = try update(sandbox) { existing in
            existing.snippets + [makeSnippet(index: 3, name: "Third", keyword: "three")]
        }
        #expect(loadState(sandbox)?.generation == 10,
                "a foreign write between two cooperating writes must leave a detectable gap")
    }

    /// `update` returns before writing when nothing changed, and the counter has to
    /// return with it. A generation that moves on a no-op is a generation that reports
    /// a foreign write on every idle save — the same false alarm the byte comparison
    /// at LibraryGeneration.swift:129 exists to suppress.
    @Test func aWriteThatChangesNothingLeavesTheGenerationAlone() throws {
        let sandbox = try Sandbox("generation-noop")
        defer { sandbox.destroy() }
        try seedState(sandbox, generation: 7)

        _ = try update(sandbox) { _ in [makeSnippet(index: 1, name: "First", keyword: "one")] }
        let afterFirst = try #require(loadState(sandbox))
        #expect(afterFirst.generation == 8)

        _ = try update(sandbox) { existing in existing.snippets }
        let afterNoOp = try #require(loadState(sandbox))
        #expect(afterNoOp == afterFirst, "an identity transform moved the generation counter")
    }

    /// Regression test for the reason the three tests above did not exist at first:
    /// `bumpGeneration` used to stage its temporary file through
    /// `SnippetStorageLocations.tmpFolderURL` no matter where `stateURL` pointed, so
    /// merely exercising it wrote into the user's real support folder. `state.json`
    /// must stage in the directory its caller was handed — and, because
    /// `AtomicFileWriter` falls back to staging *inside the destination* when
    /// `rename(2)` returns EXDEV, that is what keeps a cross-volume library from
    /// dropping a temp file into the monitored folder.
    ///
    /// What this test can and cannot see, since a passing test that proves nothing is
    /// worse than no test: the library write in the same `update` also creates the
    /// injected directory, so "the directory exists afterwards" holds either way and
    /// is *not* the detector. What this pins is the half that lives in this file —
    /// that `bumpGeneration` runs against the sandbox at all and leaves no staged file
    /// anywhere in it. That `SyncStateFile.write` actually honours the directory it is
    /// handed is pinned deterministically by its sibling,
    /// `ClockAndStateTests.StateFile.syncStateRoundTripsThroughWriteAndLoadWithDatesOnTheWireAsISO8601`,
    /// which fails the moment the parameter stops being threaded (verified by
    /// reintroducing the bug).
    @Test func theGenerationCounterIsWrittenThroughTheInjectedTemporaryDirectory() throws {
        let sandbox = try Sandbox("generation-staging")
        defer { sandbox.destroy() }
        try seedState(sandbox, generation: 0)

        let staging = sandbox.root.appendingPathComponent("Staging", isDirectory: true)

        _ = try LibraryWriter.update(
            libraryURL: sandbox.library,
            stateURL: sandbox.stateFile,
            lockURL: sandbox.lockFile,
            temporaryDirectory: staging,
            lockTimeout: 10,
            expectedDigest: nil,
            transform: { _ in [makeSnippet(index: 1, name: "First", keyword: "one")] })

        #expect(loadState(sandbox)?.generation == 1, "bumpGeneration did not run at all")
        #expect(FileManager.default.fileExists(atPath: staging.path))
        #expect(entries(of: staging) == [], "a staged temporary file survived the write")
        // Nothing was staged beside `state.json` either — the property the folder
        // monitor depends on, and the one `AtomicFileWriter`'s EXDEV fallback breaks.
        #expect(entries(of: sandbox.syncFolder).filter { $0.hasPrefix("state.json.") } == [])
    }

    // MARK: - Test helpers

    /// A state file with a fixed identity, so an assertion can tell "the write left
    /// the identity alone" apart from "the write replaced the file wholesale".
    private func seedState(_ sandbox: Sandbox, generation: UInt64) throws {
        var state = SyncState.fresh(
            deviceID: "a1b2c3d4", now: Date(timeIntervalSince1970: 1_769_000_000))
        state.scopeID = "fixed-scope"
        state.generation = generation
        try SyncStateFile.write(state, to: sandbox.stateFile, temporaryDirectory: sandbox.tmpFolder)
    }

    private func loadState(_ sandbox: Sandbox) -> SyncState? {
        guard case .loaded(let state) = SyncStateFile.load(from: sandbox.stateFile) else { return nil }
        return state
    }

    private func update(
        _ sandbox: Sandbox,
        expectedDigest: String? = nil,
        lockTimeout: TimeInterval = 10,
        transform: (LibraryWriter.Snapshot) throws -> [Snippet]
    ) throws -> LibraryWriter.Outcome {
        try LibraryWriter.update(
            libraryURL: sandbox.library,
            stateURL: sandbox.stateFile,
            lockURL: sandbox.lockFile,
            temporaryDirectory: sandbox.tmpFolder,
            lockTimeout: lockTimeout,
            expectedDigest: expectedDigest,
            transform: transform)
    }
}

// MARK: - Sandboxing

/// One private directory tree per test, laid out like the real support folder.
///
/// `swift test` runs in parallel and the real `~/Library/Application Support/
/// SnippetsClone` belongs to the user's running app, so no test may name it.
private final class Sandbox {
    let root: URL

    init(_ label: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryWriterTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
    }

    var library: URL { root.appendingPathComponent("snippets.json", isDirectory: false) }
    var syncFolder: URL { root.appendingPathComponent("Sync", isDirectory: true) }
    var lockFile: URL { syncFolder.appendingPathComponent("library.lock", isDirectory: false) }
    var stateFile: URL { syncFolder.appendingPathComponent("state.json", isDirectory: false) }
    var tmpFolder: URL { root.appendingPathComponent("Tmp", isDirectory: true) }

    func destroy() { try? FileManager.default.removeItem(at: root) }
}

/// Everything that distinguishes "this file was republished" from "this file was left
/// alone". The inode is the load-bearing field — an atomic write always renames a new
/// one into place — with the modification timestamp catching a hypothetical in-place
/// rewrite. Read straight from `stat(2)` because `FileManager`'s date rounds.
private struct FileIdentity: Equatable {
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
}

private func identity(of url: URL) -> FileIdentity? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return FileIdentity(
        inode: UInt64(info.st_ino),
        size: Int64(info.st_size),
        modifiedSeconds: info.st_mtimespec.tv_sec,
        modifiedNanoseconds: info.st_mtimespec.tv_nsec)
}

private func permissions(of url: URL) -> mode_t? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o7777
}

private func entries(of url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
}

/// A payload larger than one `write(2)` will take in a single call, so the writer's
/// short-write loop is actually exercised rather than merely present.
private func repeatingPattern(byteCount: Int) -> Data {
    let block = Data((0..<4096).map { UInt8($0 & 0xFF) })
    var data = Data(capacity: byteCount)
    while data.count < byteCount { data.append(block) }
    return data.prefix(byteCount)
}

/// Observations made by the reader thread in the torn-write test, folded into a set of
/// digests so a fast spin over a multi-megabyte file cannot exhaust memory. Only the
/// *distinct* states matter to the assertion — a legal run has exactly two of them —
/// so nothing is gained by keeping the sequence, and keeping it forced a cap that
/// could silently discard the very observation the test is hunting for.
private final class ObservationLog: @unchecked Sendable {
    private let mutex = NSLock()
    private var stopped = false
    private var distinct: Set<String> = []
    private var count = 0
    private var announcedFirst = false
    private let firstObservation = DispatchSemaphore(value: 0)

    var isStopped: Bool { mutex.withLock { stopped } }
    var distinctDigests: Set<String> { mutex.withLock { distinct } }
    var observationCount: Int { mutex.withLock { count } }

    func stop() { mutex.withLock { stopped = true } }

    /// Blocks until the reader has genuinely read the file at least once. Without this
    /// handshake the writer can complete every rename before the reader is scheduled,
    /// which turns a test of `rename(2)` atomicity into a test of the scheduler.
    func waitForFirstObservation(timeout: TimeInterval) -> Bool {
        firstObservation.wait(timeout: .now() + timeout) == .success
    }

    func record(_ data: Data?) {
        // `nil` would mean the path briefly referred to nothing, which `rename(2)`
        // must never allow; recorded as its own value so it fails the assertion.
        let digest = data.map(SnippetLibraryCodec.digest(of:)) ?? "unreadable"
        let isFirst: Bool = mutex.withLock {
            distinct.insert(digest)
            count += 1
            let first = !announcedFirst
            announcedFirst = true
            return first
        }
        if isFirst { firstObservation.signal() }
    }
}

/// The result of an `acquire` running on another thread.
private final class AcquireAttempt: @unchecked Sendable {
    var succeeded = false
    var failure: LibraryLock.Failure?
    var otherError: Error?
    var elapsed: TimeInterval = 0
}

// MARK: - The cross-process locking helper

/// Builds the helper that `theLibraryLockIsMutuallyExclusiveAcrossProcesses` spawns.
///
/// It is compiled against the shipping `LibraryLock.swift` and `Snippet.swift`, so
/// the subprocesses exercise the same `flock` code the app runs — poll interval,
/// jitter, `O_CREAT`-without-`O_TRUNC` and all — rather than a stand-in written in
/// another language.
private func compileLockHelper(into sandbox: Sandbox) throws -> URL {
    let root = try #require(repositoryRoot(), "could not locate snippets/Core from \(#filePath)")
    let sourceFolder = sandbox.root.appendingPathComponent("helper-src", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)

    // Must be called main.swift: only that filename may hold top-level statements.
    let main = sourceFolder.appendingPathComponent("main.swift")
    try Data(lockHelperSource.utf8).write(to: main)

    let binary = sandbox.root.appendingPathComponent("lock-helper")
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = [
        "swiftc", "-O", "-swift-version", "5",
        main.path,
        root.appendingPathComponent("snippets/Core/LibraryLock.swift").path,
        root.appendingPathComponent("snippets/Core/Snippet.swift").path,
        "-o", binary.path,
    ]
    let diagnostics = Pipe()
    compiler.standardError = diagnostics
    compiler.standardOutput = diagnostics
    try compiler.run()
    let output = diagnostics.fileHandleForReading.readDataToEndOfFile()
    compiler.waitUntilExit()
    #expect(compiler.terminationStatus == 0,
            "could not build the locking helper: \(String(data: output, encoding: .utf8) ?? "")")
    return binary
}

/// Walks up from this file looking for the directory that holds `snippets/Core`.
///
/// A fixed number of `..` hops is not safe: SwiftPM reaches these tests through
/// `CorePackage/Tests/SnippetsCoreTests`, a symlink, so `#filePath` may arrive by
/// either route depending on how the build resolved it.
private func repositoryRoot() -> URL? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        let marker = directory.appendingPathComponent("snippets/Core/LibraryLock.swift")
        if FileManager.default.fileExists(atPath: marker.path) { return directory }
        directory = directory.deletingLastPathComponent()
    }
    return nil
}

private let lockHelperSource = """
import Foundation

// Spawned by LibraryWriterTests.theLibraryLockIsMutuallyExclusiveAcrossProcesses.
// Arguments: lock path, ledger path, start-line path, token, iteration count.
let arguments = CommandLine.arguments
let lockURL = URL(fileURLWithPath: arguments[1])
let ledgerURL = URL(fileURLWithPath: arguments[2])
let startLineURL = URL(fileURLWithPath: arguments[3])
let token = arguments[4]
let iterations = Int(arguments[5])!

// Wait for the start line so every process is already running before any of them
// contends; otherwise the writers could serialise by accident and prove nothing.
let startDeadline = Date().addingTimeInterval(60)
while !FileManager.default.fileExists(atPath: startLineURL.path), Date() < startDeadline {
    Thread.sleep(forTimeInterval: 0.002)
}

for _ in 0..<iterations {
    try LibraryLock.withExclusiveLock(at: lockURL, timeout: 60) {
        // Read, pause, then write the whole file back — the same read-modify-write
        // the app and the CLI perform on snippets.json. The pause widens the race so
        // a lock that does not work loses appends on every run rather than one in
        // fifty: with this helper's lock removed, 100 of the 120 appends vanish.
        var ledger = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
        Thread.sleep(forTimeInterval: 0.001)
        ledger += token + "\\n"
        try ledger.write(to: ledgerURL, atomically: false, encoding: .utf8)
    }
}
"""

// MARK: - Deterministic fixtures

/// xorshift64, matching `Tests/SnippetFrecencyTests.swift`. Seeded so a property
/// failure reproduces exactly instead of arriving once and never again.
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

    mutating func bool() -> Bool { next() & 1 == 0 }

    mutating func pick<T>(_ options: [T]) -> T { options[int(options.count)] }

    mutating func uuid() -> UUID {
        let a = next()
        let b = next()
        func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: value >> shift) }
        return UUID(uuid: (
            byte(a, 0), byte(a, 8), byte(a, 16), byte(a, 24),
            byte(a, 32), byte(a, 40), byte(a, 48), byte(a, 56),
            byte(b, 0), byte(b, 8), byte(b, 16), byte(b, 24),
            byte(b, 32), byte(b, 40), byte(b, 48), byte(b, 56)
        ))
    }
}

/// A snippet with everything pinned. `Snippet.init` defaults both timestamps to
/// `Date()`, which would make any byte-level assertion irreproducible.
private func makeSnippet(
    index: Int,
    name: String? = nil,
    keyword: String? = nil,
    content: String? = nil,
    tags: [String] = [],
    isEnabled: Bool = true,
    isPinned: Bool = false
) -> Snippet {
    Snippet(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
        name: name ?? "Snippet \(index)",
        keyword: keyword ?? "kw\(index)",
        content: content ?? "Body of snippet \(index)",
        tags: tags,
        isEnabled: isEnabled,
        isPinned: isPinned,
        createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index)),
        updatedAt: Date(timeIntervalSinceReferenceDate: 700_100_000 + Double(index)))
}

/// A library that looks like a real one: unicode, emoji, multi-line bodies, quotes
/// and backslashes, empty and populated tag lists, disabled and pinned records.
///
/// Tags are already normalised and timestamps are exact eighths of a second. Both
/// are deliberate: `Snippet.init(from:)` normalises tags on decode, so a
/// denormalised fixture would fail the byte-identity test for a reason that has
/// nothing to do with the encoder (that case has its own test), and an exact binary
/// fraction removes any argument about float formatting from the result.
private func makeRealisticLibrary(count: Int, seed: UInt64) -> [Snippet] {
    var random = SeededRandom(seed: seed)
    let names = [
        "Email signature", "Zoom link", "Résumé blurb", "住所", "Shrug ¯\\_(ツ)_/¯",
        "Invoice footer", "PR checklist ✅", "Tab\tseparated", "He said \"hi\"",
    ]
    let bodies = [
        "Best,\nAda", "https://example.com/j/1234567890",
        "line one\nline two\tindented\nline three",
        "Path: C:\\Users\\ada\\notes.txt",
        "— em dash, ünïcödé, and an emoji 🎉",
        "{date:yyyyMMdd}-{clipboard}",
        "",
    ]
    let tagPools = [[], ["Work"], ["Work", "Email"], ["Personal"], ["Snippets", "Ops", "Réf"]]

    return (0..<count).map { index in
        Snippet(
            id: random.uuid(),
            name: random.pick(names) + " \(index)",
            keyword: "kw\(index)",
            content: random.pick(bodies),
            tags: random.pick(tagPools),
            isEnabled: random.bool(),
            isPinned: random.bool(),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(random.int(8192)) / 8.0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 720_000_000 + Double(random.int(8192)) / 8.0))
    }
}

// MARK: - A note on what made the generation tests possible
//
// These four tests could not be written when this file was first drafted: `update`
// threaded its injected `temporaryDirectory` into the library write but not into
// `bumpGeneration`, and `SyncStateFile.write` took no temporary directory at all, so
// letting `bumpGeneration` run at all staged a file inside the user's real
// ~/Library/Application Support/SnippetsClone/Tmp. Every `update` above therefore had
// to point `stateURL` at a nonexistent file to keep `bumpGeneration` from writing.
//
// That parameter now exists and is threaded through. `theGenerationCounterIsWritten
// ThroughTheInjectedTemporaryDirectory` is the regression test for it.
