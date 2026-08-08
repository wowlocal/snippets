import Foundation

#if canImport(Darwin)
import Darwin
#endif

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// Writes a file atomically and durably, with the temporary file staged outside the
/// destination directory.
///
/// `Data.write(to:options:.atomic)` already renames into place, but it creates its
/// temporary file *in the destination directory*. `SnippetStore` watches the support
/// folder with a `DispatchSource`, so every such write costs two monitor events —
/// one for the create, one for the rename — and the create arrives while the file is
/// still half-written. Staging in `Tmp/` halves the events and makes every one of
/// them correspond to a complete file.
///
/// The `fsync` before the rename is what makes the write durable rather than merely
/// atomic. Without it a power loss can leave the rename visible while the data
/// blocks are not, which presents as a truncated or zero-length library — precisely
/// the failure mode the quarantine path exists to survive, but far better avoided.
nonisolated enum AtomicFileWriter {

    enum Failure: Error, CustomStringConvertible {
        case cannotCreateTemporary(directory: String, errno: Int32)
        case writeFailed(errno: Int32)
        case renameFailed(destination: String, errno: Int32)

        var description: String {
            switch self {
            case .cannotCreateTemporary(let directory, let code):
                return "could not create a temporary file in \(directory): \(String(cString: strerror(code))) (\(code))"
            case .writeFailed(let code):
                return "could not write the temporary file: \(String(cString: strerror(code))) (\(code))"
            case .renameFailed(let destination, let code):
                return "could not move the temporary file onto \(destination): \(String(cString: strerror(code))) (\(code))"
            }
        }
    }

    /// Writes `data` to `url`, leaving either the previous contents or the new
    /// contents in place — never a mixture, and never an empty file.
    ///
    /// - Parameter temporaryDirectory: must be on the same filesystem as `url`, since
    ///   `rename(2)` cannot cross mount points. Both live under Application Support,
    ///   so this holds; the fallback below covers the case where it somehow does not.
    static func write(
        _ data: Data,
        to url: URL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL,
        permissions: mode_t = 0o600
    ) throws {
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let template = temporaryDirectory
            .appendingPathComponent("\(url.lastPathComponent).XXXXXX", isDirectory: false)
        var templateBytes = Array(template.path.utf8CString)

        let descriptor = templateBytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else {
            throw Failure.cannotCreateTemporary(directory: temporaryDirectory.path, errno: errno)
        }

        let temporaryPath = String(cString: templateBytes)
        // Any failure past this point must not leave a stray temp file behind.
        var shouldUnlink = true
        defer { if shouldUnlink { unlink(temporaryPath) } }

        // mkstemp creates with 0600, but an explicit fchmod documents the intent and
        // covers a umask that somehow widened it.
        fchmod(descriptor, permissions)

        do {
            try writeAll(data, to: descriptor)
            // Durability barrier: the bytes must reach stable storage before the
            // rename publishes them under the real name.
            guard fsync(descriptor) == 0 else { throw Failure.writeFailed(errno: errno) }
        } catch {
            close(descriptor)
            throw error
        }
        close(descriptor)

        guard rename(temporaryPath, url.path) == 0 else {
            let code = errno
            // EXDEV means the temp directory landed on a different filesystem than the
            // destination. Fall back to Foundation's atomic write, which stages inside
            // the destination directory: noisier for the folder monitor, but correct.
            if code == EXDEV {
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
                return
            }
            throw Failure.renameFailed(destination: url.path, errno: code)
        }
        shouldUnlink = false

        // fsync the *directory* as well. Syncing the file guarantees its contents are
        // on stable storage; it says nothing about the directory entry that now points
        // at them. Without this the rename can be lost across a power failure while
        // the data blocks survive — which presents as the old file, or as no file at
        // all, and makes the durability claim above untrue.
        let parent = url.deletingLastPathComponent()
        let directory = open(parent.path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
    }

    /// `write(2)` is permitted to write fewer bytes than asked, and does on large
    /// buffers. Looping is not defensive programming here; it is the contract.
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure.writeFailed(errno: errno)
                }
                offset += written
            }
        }
    }
}
