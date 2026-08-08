import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

nonisolated extension NSError {
    /// True only for "the path does not exist", across both the Cocoa and POSIX
    /// error domains `Data(contentsOf:)` can surface.
    var isFileNotFound: Bool {
        if domain == NSCocoaErrorDomain {
            return code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError
        }
        if domain == NSPOSIXErrorDomain { return code == Int(ENOENT) }
        return false
    }
}

/// The single funnel every cooperating write to `snippets.json` goes through.
///
/// ## Why one funnel, shared by the app and the CLI
///
/// The app and `snippets-cli` had two independent read-modify-write implementations
/// with two different sets of bugs. Both decoded the whole array, edited it, and
/// renamed a complete replacement over whatever the other had produced meanwhile.
/// Putting both on this type means the locking, the compare-and-swap, and the merge
/// are defined once and tested once.
///
/// ## Why locking alone is not enough
///
/// Serialization fixes the interleaved-write race, but it leaves a subtler one that
/// is entirely a matter of timing:
///
/// 1. `t=0.00` the user types; the app schedules its debounced write for `t=0.30`.
/// 2. `t=0.28` the CLI writes, correctly, under the lock.
/// 3. `t=0.30` the app writes, correctly, under the lock — from its in-memory array,
///    which never saw step 2 — and records those bytes as "what is on disk".
/// 4. `t=0.33` the folder monitor fires. The bytes on disk match what the app last
///    wrote, so the reload short-circuits and the CLI's edit is gone.
///
/// Every actor behaved correctly and the edit still vanished. The fix is that the
/// writer must re-read *inside* the lock and merge if the bytes moved, rather than
/// assume its own snapshot is still current. That is what `update` does.
nonisolated enum LibraryWriter {

    struct Snapshot: Equatable {
        var snippets: [Snippet]
        var digest: String
        /// The raw bytes, kept so the next merge has a byte-exact ancestor.
        var data: Data

        static let empty = Snapshot(snippets: [], digest: "", data: Data())
    }

    struct Outcome {
        /// What is now on disk.
        var snippets: [Snippet]
        var digest: String
        var data: Data
        /// True when the transform saw bytes it had not seen before — i.e. some other
        /// writer got in between. Callers use this to decide whether to tell the UI
        /// that the library changed underneath it.
        var foldedInForeignWrite: Bool
        /// True when the lock could not be taken but the write proceeded anyway
        /// because the filesystem does not implement `flock`.
        var wroteWithoutLock: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        /// A peer held the lock for the whole timeout. The caller must retry; it must
        /// not drop the pending write.
        case busy
        case unreadable(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case .busy: return "another process is writing the snippet library; try again"
            case .unreadable(let detail): return detail
            case .writeFailed(let detail): return detail
            }
        }
    }

    /// Reads the library without taking the lock.
    ///
    /// Safe because every writer publishes with `rename(2)`: a reader sees either the
    /// complete old file or the complete new one, never a partial write.
    static func read(from url: URL = SnippetStorageLocations.snippetsFileURL) throws -> Snapshot {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // "No such file" is a legitimately empty library. EVERY other errno —
            // permissions, I/O error, a half-mounted volume — is a file we simply
            // could not read, and reporting that as an empty library is catastrophic:
            // `update` would take the emptiness at face value and save it, turning a
            // transient read failure into permanent data loss.
            if (error as NSError).isFileNotFound { return .empty }
            throw Failure.unreadable(
                "snippets file at '\(url.path)' could not be read: \(error.localizedDescription)")
        }

        do {
            let snippets = try SnippetLibraryCodec.decode(data)
            return Snapshot(snippets: snippets, digest: SnippetLibraryCodec.digest(of: data), data: data)
        } catch {
            throw Failure.unreadable(
                "snippets file at '\(url.path)' exists but could not be decoded")
        }
    }

    /// Performs a locked read-modify-write.
    ///
    /// `transform` receives what is genuinely on disk *right now*, inside the lock,
    /// and returns what should replace it. A caller holding stale in-memory state
    /// resolves the difference there — see `SyncMerge.mergeLocal`.
    ///
    /// - Parameter expectedDigest: what the caller believed was on disk. Purely
    ///   informational: it decides `foldedInForeignWrite`, never whether to proceed.
    static func update(
        libraryURL: URL = SnippetStorageLocations.snippetsFileURL,
        stateURL: URL = SnippetStorageLocations.syncStateFileURL,
        lockURL: URL = SnippetStorageLocations.libraryLockFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL,
        lockTimeout: TimeInterval,
        expectedDigest: String?,
        transform: (Snapshot) throws -> [Snippet]
    ) throws -> Outcome {
        var lock: LibraryLock?
        var wroteWithoutLock = false
        do {
            lock = try LibraryLock.acquire(at: lockURL, timeout: lockTimeout)
        } catch let failure as LibraryLock.Failure {
            guard !LibraryLockPolicy.isFatal(failure) else { throw Failure.busy }
            // The filesystem does not support advisory locking (some network-mounted
            // home directories). Refusing to write would brick the app for those
            // users; proceeding leaves the generation check as the safety net.
            wroteWithoutLock = true
        }
        defer { lock?.release() }

        let current = try read(from: libraryURL)
        let updated = try transform(current)

        let data: Data
        do {
            data = try SnippetLibraryCodec.encode(updated)
        } catch {
            throw Failure.writeFailed("could not encode the snippet library: \(error)")
        }

        // Nothing changed: skip the write entirely. This keeps the folder monitor
        // quiet and, more importantly, stops two devices from ping-ponging identical
        // content back and forth forever once sync is live.
        if data == current.data {
            return Outcome(
                snippets: current.snippets, digest: current.digest, data: current.data,
                foldedInForeignWrite: expectedDigest != nil && expectedDigest != current.digest,
                wroteWithoutLock: wroteWithoutLock)
        }

        do {
            try AtomicFileWriter.write(data, to: libraryURL, temporaryDirectory: temporaryDirectory)
        } catch {
            throw Failure.writeFailed("could not save the snippet library: \(error)")
        }

        let digest = SnippetLibraryCodec.digest(of: data)
        bumpGeneration(
            stateURL: stateURL, temporaryDirectory: temporaryDirectory,
            digest: digest, observedOnDisk: current.digest)

        return Outcome(
            snippets: updated, digest: digest, data: data,
            foldedInForeignWrite: expectedDigest != nil && expectedDigest != current.digest,
            wroteWithoutLock: wroteWithoutLock)
    }

    /// Advances the generation counter and records the bytes it describes.
    ///
    /// Best-effort on purpose: this is bookkeeping for diagnostics and for the sync
    /// engine's dirty check. A failure to update it must never fail a write that has
    /// already durably landed — the library is the user's data, `state.json` is not.
    private static func bumpGeneration(
        stateURL: URL, temporaryDirectory: URL, digest: String, observedOnDisk: String
    ) {
        guard case .loaded(var state) = SyncStateFile.load(from: stateURL) else { return }
        // A digest we did not write means somebody outside this funnel wrote the file
        // — an old app build, a stale CLI, an editor. Worth recording; `doctor`
        // reports it, and it is the signal that a full reconcile is needed.
        if let known = state.librarySHA256, known != observedOnDisk, !observedOnDisk.isEmpty {
            state.generation &+= 1
        }
        state.generation &+= 1
        state.librarySHA256 = digest
        try? SyncStateFile.write(state, to: stateURL, temporaryDirectory: temporaryDirectory)
    }
}
