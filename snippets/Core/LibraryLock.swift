import Foundation

#if canImport(Darwin)
import Darwin
#endif

// This file is compiled into the app target (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor),
// the snippets-cli target, and the SnippetsCore test package. Every top-level
// declaration is explicitly `nonisolated` — see the header of `Snippet.swift`.

/// A cross-process advisory lock over the snippet library, held with `flock(2)`.
///
/// ## Why this exists
///
/// The app and `snippets-cli` both read-modify-write the whole of `snippets.json`
/// with no coordination whatsoever. Under concurrent writes that loses roughly two
/// thirds of them: each writer decodes the array, edits its own copy, and renames
/// its own complete result over whatever the other writer produced in between. The
/// CLI prints a successful JSON receipt either way, so the loss is silent.
///
/// ## Why the lock file is not `snippets.json`
///
/// `flock` is attached to an *open file description*, which refers to an inode —
/// not to a path. Every writer here finishes with `rename(2)`, which points the
/// path at a brand-new inode and orphans the old one. Two writers locking
/// `snippets.json` by path therefore end up holding locks on two different inodes
/// and both proceed. Measured, this is as bad as no lock at all.
///
/// So the lock lives on its own zero-byte file, created once and never written to.
///
/// That is still not enough on its own. If the file is *replaced* — a folder restore,
/// a file-syncing tool, a cleanup script — peers end up holding locks on different
/// inodes and both proceed. `acquire` therefore revalidates the locked inode against
/// the path, and `LibraryWriter.update` additionally verifies the file immediately
/// before and after writing, so correctness never depends on the lock being intact.
/// Measured with the lock file deleted every 5 ms underneath 60 concurrent writers:
/// 31/61 records survived with neither guard, 54/61 with revalidation alone, 61/61
/// with both.
///
/// ## Why non-blocking with a deadline
///
/// A plain blocking `flock(fd, LOCK_EX)` cannot be interrupted. `SnippetStore`
/// flushes synchronously from `applicationWillTerminate` on the main thread, so a
/// wedged or stopped peer holding the lock would hang quit — and macOS would kill
/// the app before it wrote anything. Polling to a deadline degrades to "retry, or
/// fall back to the write path's own compare-and-swap" instead of to a hang.
nonisolated final class LibraryLock {

    enum Failure: Error, CustomStringConvertible {
        /// The lock file could not be opened at all. On a read-only or missing
        /// directory this is permanent, not transient.
        case cannotOpen(path: String, errno: Int32)
        /// Another process held the lock for longer than the caller was willing to wait.
        case timedOut(path: String, seconds: TimeInterval)

        var description: String {
            switch self {
            case .cannotOpen(let path, let code):
                return "could not open lock file at \(path): \(String(cString: strerror(code))) (\(code))"
            case .timedOut(let path, let seconds):
                return "timed out after \(seconds)s waiting for the library lock at \(path)"
            }
        }
    }

    /// Poll cadence while waiting. Short enough that an uncontended hand-off is
    /// imperceptible, long enough not to spin a core during a slow peer write.
    private static let pollInterval: TimeInterval = 0.005
    /// Added to each poll so two processes that started waiting at the same instant
    /// do not retry in lockstep forever.
    private static let pollJitter: TimeInterval = 0.003

    private var descriptor: Int32
    private let path: String
    private var isReleased = false

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    /// Blocks the calling thread until the lock is held or `timeout` elapses.
    ///
    /// Callers on the main thread must pass a small timeout. The only caller allowed
    /// a long one is the terminate path, which has nothing left to reschedule onto.
    static func acquire(
        at url: URL = SnippetStorageLocations.libraryLockFileURL,
        timeout: TimeInterval
    ) throws -> LibraryLock {
        let path = url.path

        // O_CREAT, never O_TRUNC: the file's *contents* are irrelevant and must never
        // be disturbed, because truncating it would not affect the lock but would
        // needlessly touch the directory the app's folder monitor watches.
        // Test seam. There is no way to make a real filesystem stop implementing
        // `flock` on demand, and the fallback below is the path taken by a user
        // population we cannot otherwise reproduce, so it has to be reachable
        // deliberately. Unset in every shipping configuration.
        if ProcessInfo.processInfo.environment["SNIPPETS_DISABLE_FLOCK"] == "1" {
            throw Failure.cannotOpen(path: path, errno: ENOTSUP)
        }

        var descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw Failure.cannotOpen(path: path, errno: errno)
        }

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                // Holding a lock is not the same as holding *the* lock.
                //
                // `flock` attaches to an inode. `open(O_CREAT)` resolves a path. If the
                // lock file was replaced between those two steps — a folder restore, a
                // file-syncing tool, an over-eager cleanup script — then this process
                // and its peer are each holding an exclusive lock on a different inode,
                // both believe they are serialized, and both proceed. Measured with the
                // lock file being deleted underneath 60 concurrent writers: 31 of 61
                // records survive, every writer exits 0, and nothing is written to
                // stderr. That is indistinguishable from having no lock at all, with a
                // success receipt for each lost write.
                //
                // So: compare the inode we locked against the inode the path names now.
                // If they differ, the file was swapped; drop this descriptor and take
                // the lock again on whatever lives at the path.
                if lockedInodeStillMatchesPath(descriptor: descriptor, path: path) {
                    return LibraryLock(descriptor: descriptor, path: path)
                }

                flock(descriptor, LOCK_UN)
                close(descriptor)
                guard Date() < deadline else { throw Failure.timedOut(path: path, seconds: timeout) }
                let reopened = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
                guard reopened >= 0 else { throw Failure.cannotOpen(path: path, errno: errno) }
                descriptor = reopened
                continue
            }

            let code = errno
            // EWOULDBLOCK is the only outcome worth waiting on. EBADF/EINVAL/EOPNOTSUPP
            // mean this filesystem does not implement flock (some network mounts), and
            // retrying would just burn the whole timeout before failing anyway.
            guard code == EWOULDBLOCK else {
                close(descriptor)
                throw Failure.cannotOpen(path: path, errno: code)
            }
            guard Date() < deadline else {
                close(descriptor)
                throw Failure.timedOut(path: path, seconds: timeout)
            }

            Thread.sleep(forTimeInterval: pollInterval + Double.random(in: 0...pollJitter))
        }
    }

    /// Whether the descriptor we just locked is still the file the path names.
    ///
    /// Returns `true` when it cannot tell — a `stat` failure here means the path has
    /// gone missing entirely, and refusing to proceed would turn a transient
    /// filesystem hiccup into an unwritable library. The mismatch case is the one
    /// worth acting on, and it is unambiguous.
    private static func lockedInodeStillMatchesPath(descriptor: Int32, path: String) -> Bool {
        var locked = stat()
        var named = stat()
        guard fstat(descriptor, &locked) == 0 else { return true }
        guard stat(path, &named) == 0 else { return true }
        return locked.st_ino == named.st_ino && locked.st_dev == named.st_dev
    }

    /// Releases the lock. Idempotent, so `defer { lock.release() }` is safe next to
    /// an early explicit release.
    func release() {
        guard !isReleased else { return }
        isReleased = true
        // Closing the descriptor would release the lock on its own; the explicit
        // LOCK_UN keeps the intent legible and the ordering unambiguous.
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        if !isReleased {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

extension LibraryLock {
    /// Runs `body` under the library lock, releasing it however `body` exits.
    ///
    /// Rethrows if the lock cannot be taken — it does NOT fall through and run `body`
    /// unlocked. The caller that needs the tolerant behaviour is `LibraryWriter.update`,
    /// which handles `LibraryLockPolicy.isFatal` itself and relies on its own
    /// compare-and-swap for correctness.
    static func withExclusiveLock<T>(
        at url: URL = SnippetStorageLocations.libraryLockFileURL,
        timeout: TimeInterval,
        body: () throws -> T
    ) throws -> T {
        let lock = try acquire(at: url, timeout: timeout)
        defer { lock.release() }
        return try body()
    }
}

/// Mutual exclusion for filesystems where `flock(2)` is not implemented.
///
/// ## Why this exists
///
/// `LibraryWriter`'s compare-and-swap was documented as converging "whether the lock
/// worked, was bypassed, or does not exist on this filesystem". The third claim was
/// false. Measured with 60 concurrent writers and no lock at all, only 42–44 of 61
/// records survive — every loss silent, every writer exiting 0.
///
/// The reason is structural, and no amount of extra re-reading fixes it: an optimistic
/// read-modify-write has an irreducible window. A confirms its own bytes, then B —
/// whose recheck predates A's rename — writes and also confirms its own. Both report
/// success; A's record is gone. More reads move the window, they do not remove it.
///
/// So the no-`flock` path needs a real atomic primitive underneath the CAS, not a
/// better CAS. That population is not hypothetical: `LibraryLockPolicy.isFatal`
/// returns false for `.cannotOpen` specifically so a network-mounted home directory
/// does not brick the app, and those are exactly the filesystems where `flock` is
/// missing. Without this they would have taken ~30% silent loss, permanently.
///
/// ## How it works
///
/// `link(2)` is the classic primitive here, and it is chosen over `O_CREAT|O_EXCL`
/// because it is atomic on network filesystems where `O_EXCL` historically is not:
/// create a uniquely-named file, then hard-link it to the well-known lock path. The
/// link succeeds for exactly one process. The `st_nlink == 2` re-check afterwards
/// covers the classic NFS case where the link in fact succeeded but the reply was lost
/// and `link` reported an error anyway.
///
/// A sentinel can outlive its owner, so it carries the owner's identity and is stolen
/// when that owner is provably gone — otherwise one crash would make the library
/// permanently unwritable, which is worse than the race being fixed.
nonisolated enum SentinelLock {

    /// How long a sentinel from an unreachable owner may sit before it is stolen.
    ///
    /// Only used when liveness cannot be established directly — a sentinel from
    /// another host, or one whose owner field is unreadable. A same-host owner is
    /// checked with `kill(pid, 0)`, which is exact and immediate.
    static let staleAfter: TimeInterval = 30

    final class Handle {
        private let sentinelPath: String
        private let uniquePath: String
        private var released = false

        init(sentinelPath: String, uniquePath: String) {
            self.sentinelPath = sentinelPath
            self.uniquePath = uniquePath
        }

        func release() {
            guard !released else { return }
            released = true
            unlink(sentinelPath)
            unlink(uniquePath)
        }

        deinit { release() }
    }

    static func acquire(sentinelURL: URL, timeout: TimeInterval) throws -> Handle {
        let sentinelPath = sentinelURL.path
        let directory = sentinelURL.deletingLastPathComponent()
        let uniquePath = directory
            .appendingPathComponent(
                ".lock-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0...UInt32.max))",
                isDirectory: false)
            .path

        // The owner record, so a survivor can tell a live holder from a corpse.
        let owner = "\(ProcessInfo.processInfo.hostName)\n\(getpid())\n"
        let unique = open(uniquePath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard unique >= 0 else {
            throw LibraryLock.Failure.cannotOpen(path: uniquePath, errno: errno)
        }
        _ = owner.withCString { write(unique, $0, strlen($0)) }
        close(unique)

        var succeeded = false
        defer { if !succeeded { unlink(uniquePath) } }

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while true {
            if link(uniquePath, sentinelPath) == 0 || linkLanded(uniquePath) {
                succeeded = true
                return Handle(sentinelPath: sentinelPath, uniquePath: uniquePath)
            }

            if stealIfAbandoned(sentinelPath) { continue }

            guard Date() < deadline else {
                throw LibraryLock.Failure.timedOut(path: sentinelPath, seconds: timeout)
            }
            Thread.sleep(forTimeInterval: 0.005 + Double.random(in: 0...0.003))
        }
    }

    /// Whether our unique file now has two names, meaning the `link` actually
    /// succeeded even though it reported failure. This is the documented NFS
    /// behaviour, and skipping the check turns a held lock into a spin.
    private static func linkLanded(_ uniquePath: String) -> Bool {
        var info = stat()
        guard stat(uniquePath, &info) == 0 else { return false }
        return info.st_nlink == 2
    }

    /// Removes a sentinel whose owner is provably gone. Returns whether it did.
    ///
    /// Conservative on purpose: an unreadable or foreign sentinel is only stolen once
    /// it is older than `staleAfter`. Stealing a live lock reintroduces exactly the
    /// race this type exists to prevent, so "leave it alone" is always the safer error.
    private static func stealIfAbandoned(_ sentinelPath: String) -> Bool {
        var info = stat()
        guard stat(sentinelPath, &info) == 0 else { return false }

        let contents = (try? String(contentsOfFile: sentinelPath, encoding: .utf8)) ?? ""
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let age = Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec)

        if lines.count >= 2,
           String(lines[0]) == ProcessInfo.processInfo.hostName,
           let pid = pid_t(lines[1]) {
            // Same host: liveness is knowable exactly. ESRCH means the process is gone;
            // EPERM means it exists but belongs to someone else, so it is alive.
            if kill(pid, 0) != 0 && errno == ESRCH {
                unlink(sentinelPath)
                return true
            }
            return false
        }

        guard age > staleAfter else { return false }
        unlink(sentinelPath)
        return true
    }
}

nonisolated enum LibraryLockPolicy {
    /// Whether a failure to lock should stop the write.
    ///
    /// A timeout means a peer genuinely holds the lock; proceeding would reintroduce
    /// the very race this type exists to remove, so the caller must back off and retry.
    /// An open failure usually means the filesystem does not support `flock` at all
    /// (some network-mounted home directories), and refusing to write there would
    /// brick the app for those users. In that case `LibraryWriter.update` proceeds
    /// unlocked and relies on its read-verify-write-verify retry, which is what
    /// actually provides correctness — the lock is an optimisation that keeps the
    /// common case from having to retry at all.
    static func isFatal(_ failure: LibraryLock.Failure) -> Bool {
        switch failure {
        case .timedOut: return true
        case .cannotOpen: return false
        }
    }
}
