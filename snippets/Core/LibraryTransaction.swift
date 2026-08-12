import Foundation

// Compiled into the app and the test package — see `Snippet.swift`.

/// One locked critical section spanning **both** `snippets.json` and `Vault/vault.json`.
///
/// ## Why this has to exist
///
/// Marking a snippet secure moves it from one file to the other. Doing that as
/// `LibraryWriter.update { … }` wrapped around `VaultFile.update { … }` would
/// **deadlock the process against itself**: `flock` is associated with an open file
/// description, so the inner `open` creates a second description of the same inode and
/// its `flock` blocks on the lock the outer call already holds. Not a race — a
/// guaranteed hang, on the main thread, every time.
///
/// So the two files share one acquisition. That is also what makes the move safe
/// against *other* writers: a CLI or a peer cannot observe a state where the record has
/// left one file and not yet arrived in the other.
///
/// ## What it does not promise
///
/// Two files cannot be updated atomically with respect to a **crash**. There is a
/// window between the two renames. The transaction writes each move's destination
/// before removing its source and leaves a marker describing what was in flight, so the
/// next launch can finish the job — see `CrashMarker` and
/// `SecureSnippetStore.reconcileAfterCrash`. The invariant is that the window can only
/// ever produce a *duplicate*, never a disappearance: whichever way it crashes, the
/// record exists in at least one file.
nonisolated enum LibraryTransaction {

    /// Records a move that is part-done, so a crash is repairable rather than silent.
    ///
    /// Only `demoting` is strictly load-bearing. A promote that crashes leaves the
    /// record in both files, and the reconcile rule "the vault copy wins" completes it
    /// correctly with no marker at all. A demote also leaves it in both files, and that
    /// same rule would silently *undo* the user's demotion — so the marker is what
    /// tells reconcile to prefer the plaintext copy instead.
    enum CrashMarker: Equatable {
        case none
        case promoting(UUID)
        case demoting(UUID)
    }

    struct Contents {
        /// The plaintext library. Mutate freely; written back only if it changed.
        var snippets: [Snippet]
        /// The vault, or `nil` if none exists yet.
        var vault: VaultDocument?
        /// Whether `snippets.json` was actually present — a vanished file is not an
        /// empty library. See `LibraryWriter.Snapshot.fileExisted`.
        var libraryExisted: Bool
        /// Set by the body to describe a move that spans both files.
        var marker: CrashMarker = .none
    }

    struct Outcome<T> {
        var value: T
        var snippets: [Snippet]
        var vault: VaultDocument?
        var wroteLibrary: Bool
        var wroteVault: Bool
        /// Neither `flock` nor the sentinel was available; the write went ahead anyway.
        var wroteWithoutLock: Bool
        var attempts: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case busy
        case libraryUnreadable(String)
        case vaultUnreadable(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case .busy: return "another process is writing the snippet library; try again"
            case .libraryUnreadable(let detail): return detail
            case .vaultUnreadable(let detail): return detail
            case .writeFailed(let detail): return detail
            }
        }
    }

    private static let maxAttempts = 12

    /// Which durable write has to land first to keep every moved record recoverable.
    ///
    /// A promotion can also create an additional plaintext conflict copy in the same
    /// transaction. Writing the vault first would then expose a crash window in which
    /// startup reconciliation removes the old plaintext source before that generated
    /// copy ever lands. Every promotion therefore gets an intermediate plaintext
    /// library which retains its old source while installing all final plaintext
    /// destinations. After that duplicate stage, either final file may be written
    /// without creating a disappearance window. The same plan naturally covers a mixed
    /// promotion/demotion batch.
    private enum WritePlan {
        case vaultThenLibrary
        case libraryThenVault
        case duplicateLibraryThenVaultThenLibrary(promoting: Set<UUID>)
    }

    static func perform<T>(
        libraryURL: URL = SnippetStorageLocations.snippetsFileURL,
        vaultURL: URL = SnippetStorageLocations.vaultFileURL,
        stateURL: URL = SnippetStorageLocations.syncStateFileURL,
        lockURL: URL = SnippetStorageLocations.libraryLockFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL,
        lockTimeout: TimeInterval,
        body: (inout Contents) throws -> T
    ) throws -> Outcome<T> {
        let held: FileGuard.Held
        do {
            held = try FileGuard.acquire(at: lockURL, timeout: lockTimeout)
        } catch {
            throw Failure.busy
        }
        defer { held.release() }

        for attempt in 1...maxAttempts {
            let librarySnapshot = try readLibrary(libraryURL)
            let vaultBytes = try? Data(contentsOf: vaultURL)
            let vault = try readVault(vaultURL)

            var contents = Contents(
                snippets: librarySnapshot.snippets,
                vault: vault,
                libraryExisted: librarySnapshot.fileExisted)
            let value = try body(&contents)

            let libraryChanged = contents.snippets != librarySnapshot.snippets
            let vaultChanged = contents.vault != vault

            if !libraryChanged && !vaultChanged {
                return Outcome(
                    value: value, snippets: contents.snippets, vault: contents.vault,
                    wroteLibrary: false, wroteVault: false,
                    wroteWithoutLock: held.isUnlocked, attempts: attempt)
            }

            // Compare-and-swap on BOTH files before touching either. The lock can be
            // defeated from outside (see `FileGuard`), and a half-applied move is the
            // one outcome worth more than a retry.
            guard (try? Data(contentsOf: libraryURL)) == (librarySnapshot.fileExisted ? librarySnapshot.data : nil),
                  (try? Data(contentsOf: vaultURL)) == vaultBytes
            else {
                guard attempt < maxAttempts else { throw Failure.busy }
                continue
            }

            // Encode before either half lands. An encoding refusal is not a crash
            // window and should leave both original files exactly as they were.
            let encodedLibrary: Data?
            if libraryChanged {
                do {
                    encodedLibrary = try SnippetLibraryCodec.encode(contents.snippets)
                } catch {
                    throw Failure.writeFailed("could not encode the snippet library: \(error)")
                }
            } else {
                encodedLibrary = nil
            }

            let plan = writePlan(
                beforeSnippets: librarySnapshot.snippets,
                beforeVault: vault,
                after: contents)

            func writeLibrary(_ data: Data?) throws {
                guard let data else { return }
                do {
                    try AtomicFileWriter.write(data, to: libraryURL, temporaryDirectory: temporaryDirectory)
                } catch {
                    throw Failure.writeFailed("could not save the snippet library: \(error)")
                }
            }

            func writeVault() throws {
                guard vaultChanged else { return }
                if let updated = contents.vault {
                    do {
                        try VaultFile.write(updated, to: vaultURL, temporaryDirectory: temporaryDirectory)
                    } catch {
                        throw Failure.writeFailed("could not save the vault: \(error)")
                    }
                } else {
                    // Removing the vault entirely is only legitimate when it holds
                    // nothing; anything else would be deleting secrets by omission.
                    do {
                        try FileManager.default.removeItem(at: vaultURL)
                    } catch {
                        let nsError = error as NSError
                        if !nsError.isFileNotFound {
                            throw Failure.writeFailed("could not remove the empty vault: \(error)")
                        }
                    }
                }
            }

            // ORDERING IS THE CONTRACT. The destination lands first, then the marker,
            // then the old source is removed. A failure of the first write leaves the
            // original source and no misleading marker; a failure of the second leaves
            // a duplicate plus the marker reconcile needs.
            switch plan {
            case .vaultThenLibrary:
                try writeVault()
                writeMarker(contents.marker, stateURL: stateURL, temporaryDirectory: temporaryDirectory)
                try writeLibrary(encodedLibrary)

            case .libraryThenVault:
                try writeLibrary(encodedLibrary)
                writeMarker(contents.marker, stateURL: stateURL, temporaryDirectory: temporaryDirectory)
                try writeVault()

            case .duplicateLibraryThenVaultThenLibrary(let promoting):
                // Retain the old plaintext source of every promotion while installing
                // all final plaintext destinations. The extra write is required even
                // for a one-way promotion when that transaction also generated another
                // record which preserves the losing content.
                let finalIDs = Set(contents.snippets.map(\.id))
                let retainedSources = librarySnapshot.snippets.filter {
                    promoting.contains($0.id) && !finalIDs.contains($0.id)
                }
                let intermediate = contents.snippets + retainedSources
                let intermediateData: Data
                do {
                    intermediateData = try SnippetLibraryCodec.encode(intermediate)
                } catch {
                    throw Failure.writeFailed("could not encode the intermediate snippet library: \(error)")
                }

                try writeLibrary(intermediateData)
                writeMarker(contents.marker, stateURL: stateURL, temporaryDirectory: temporaryDirectory)
                try writeVault()
                try writeLibrary(encodedLibrary)
            }

            // Both halves are on disk, so the move is no longer in flight.
            writeMarker(.none, stateURL: stateURL, temporaryDirectory: temporaryDirectory)

            return Outcome(
                value: value, snippets: contents.snippets, vault: contents.vault,
                wroteLibrary: libraryChanged, wroteVault: vaultChanged,
                wroteWithoutLock: held.isUnlocked, attempts: attempt)
        }
        throw Failure.busy
    }

    /// Derives direction from actual ownership changes first, using the marker only
    /// when the diff itself does not identify a move. This makes a stale or mistaken
    /// marker unable to select the one ordering that could delete a record from both
    /// files, while still making the marker an explicit intent for ordinary callers.
    private static func writePlan(
        beforeSnippets: [Snippet],
        beforeVault: VaultDocument?,
        after: Contents
    ) -> WritePlan {
        let beforeLibraryIDs = Set(beforeSnippets.map(\.id))
        let afterLibraryIDs = Set(after.snippets.map(\.id))
        let beforeVaultIDs = Set(beforeVault?.records.map(\.id) ?? [])
        let afterVaultIDs = Set(after.vault?.records.map(\.id) ?? [])

        let promoting = beforeLibraryIDs
            .subtracting(afterLibraryIDs)
            .intersection(afterVaultIDs)
        let demoting = beforeVaultIDs
            .subtracting(afterVaultIDs)
            .intersection(afterLibraryIDs)

        if !promoting.isEmpty {
            return .duplicateLibraryThenVaultThenLibrary(promoting: promoting)
        }
        if !demoting.isEmpty { return .libraryThenVault }

        switch after.marker {
        case .demoting: return .libraryThenVault
        case .none, .promoting: return .vaultThenLibrary
        }
    }

    // MARK: - Reading

    private static func readLibrary(_ url: URL) throws -> LibraryWriter.Snapshot {
        do {
            return try LibraryWriter.read(from: url)
        } catch {
            throw Failure.libraryUnreadable("\(error)")
        }
    }

    /// Distinguishes "no vault" from "a vault I could not read", because writing over
    /// the second destroys secrets that a quarantine pass could still rescue.
    private static func readVault(_ url: URL) throws -> VaultDocument? {
        switch VaultFile.load(from: url) {
        case .loaded(let document): return document
        case .missing: return nil
        case .tooNew(let version):
            throw Failure.vaultUnreadable(
                "the vault is schemaVersion \(version); this build understands \(VaultDocument.currentSchemaVersion)")
        case .unreadable(let error):
            throw Failure.vaultUnreadable("the vault could not be read: \(error)")
        case .corrupt(let error):
            throw Failure.vaultUnreadable("the vault is damaged: \(error)")
        }
    }

    // MARK: - Crash marker

    /// Best effort by design. The marker improves a crash recovery; failing to write it
    /// must never fail a move whose data has already landed correctly.
    private static func writeMarker(_ marker: CrashMarker, stateURL: URL, temporaryDirectory: URL) {
        guard case .loaded(var state) = SyncStateFile.load(from: stateURL) else { return }

        let promoting: UUID?
        let demoting: UUID?
        switch marker {
        case .none: promoting = nil; demoting = nil
        case .promoting(let id): promoting = id; demoting = nil
        case .demoting(let id): promoting = nil; demoting = id
        }

        guard state.promoting != promoting || state.demoting != demoting else { return }
        state.promoting = promoting
        state.demoting = demoting
        try? SyncStateFile.write(state, to: stateURL, temporaryDirectory: temporaryDirectory)
    }

    /// The marker left by a move that did not finish, if any.
    static func pendingMarker(stateURL: URL = SnippetStorageLocations.syncStateFileURL) -> CrashMarker {
        guard case .loaded(let state) = SyncStateFile.load(from: stateURL) else { return .none }
        if let id = state.promoting { return .promoting(id) }
        if let id = state.demoting { return .demoting(id) }
        return .none
    }
}
