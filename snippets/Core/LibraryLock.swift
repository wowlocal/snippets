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
/// So the lock lives on its own zero-byte file that is created once and **never
/// unlinked, replaced, or written to**. Deleting it would silently disable mutual
/// exclusion for every process that still holds the old inode open.
///
/// ## Why non-blocking with a deadline
///
/// A plain blocking `flock(fd, LOCK_EX)` cannot be interrupted. `SnippetStore`
/// flushes synchronously from `applicationWillTerminate` on the main thread, so a
/// wedged or stopped peer holding the lock would hang quit — and macOS would kill
/// the app before it wrote anything. Polling to a deadline degrades to "write
/// anyway, and let the generation check catch it" instead of to a hang.
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
        let descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw Failure.cannotOpen(path: path, errno: errno)
        }

        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return LibraryLock(descriptor: descriptor, path: path)
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
    /// On a filesystem with no working `flock` this still runs `body` — see
    /// `LibraryLockPolicy.isFatal`. Serialization is then provided solely by the
    /// generation compare-and-swap, which is filesystem-independent.
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

nonisolated enum LibraryLockPolicy {
    /// Whether a failure to lock should stop the write.
    ///
    /// A timeout means a peer genuinely holds the lock; proceeding would reintroduce
    /// the very race this type exists to remove, so the caller must back off and retry.
    /// An open failure usually means the filesystem does not support `flock` at all
    /// (some network-mounted home directories), and refusing to write there would
    /// brick the app for those users. In that case we proceed unlocked and rely on the
    /// generation CAS, which catches the collision after the fact rather than before.
    static func isFatal(_ failure: LibraryLock.Failure) -> Bool {
        switch failure {
        case .timedOut: return true
        case .cannotOpen: return false
        }
    }
}
