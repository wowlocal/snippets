import Foundation

/// Reads and classifies an imported document off the main actor with hard size bounds.
/// The returned value is already decoded for ordinary JSON, so UIKit only performs the
/// small, actor-isolated preflight and merge.
nonisolated enum IncomingDocumentLoader {
    static let maximumJSONBytes = 16 * 1_024 * 1_024
    static let maximumEncryptedBackupBytes = 32 * 1_024 * 1_024

    enum Failure: Error, Equatable, LocalizedError, Sendable {
        case cannotRead
        case invalidFormat
        case tooLarge(maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case .cannotRead:
                return "The selected file could not be read."
            case .invalidFormat:
                return "Unsupported file format. Expected JSON exported from Snippets or Raycast."
            case .tooLarge(let maximumBytes):
                let limit = ByteCountFormatter.string(
                    fromByteCount: Int64(maximumBytes),
                    countStyle: .file
                )
                return "The selected file is too large. The maximum supported size is \(limit)."
            }
        }
    }

    enum Loaded: Sendable {
        case snippets(PreparedSnippetImport)
        case encryptedBackup(Data)
    }

    static func load(_ url: URL) throws -> Loaded {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumEncryptedBackupBytes {
            throw Failure.tooLarge(maximumBytes: maximumEncryptedBackupBytes)
        }

        let data = try readBounded(
            url,
            maximumBytes: maximumEncryptedBackupBytes
        )

        let hasEncryptedExtension = url.pathExtension.caseInsensitiveCompare(
            EncryptedSnippetBackup.preferredFilenameExtension
        ) == .orderedSame
        if hasEncryptedExtension || EncryptedSnippetBackup.isEncryptedBackup(data) {
            return .encryptedBackup(data)
        }

        guard data.count <= maximumJSONBytes else {
            throw Failure.tooLarge(maximumBytes: maximumJSONBytes)
        }
        do {
            return .snippets(try SnippetImportParser.parse(data))
        } catch {
            throw Failure.invalidFormat
        }
    }

    /// Reads at most `maximumBytes + 1`, so a missing/stale file-size resource value or
    /// a provider that grows the file between the metadata lookup and the read cannot
    /// turn the nominal limit above into an unbounded allocation.
    private static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.cannotRead
        }
        defer { try? handle.close() }

        var data = Data()
        let chunkSize = 1_024 * 1_024
        do {
            while true {
                let remaining = maximumBytes - data.count
                let requested = min(chunkSize, remaining + 1)
                guard let chunk = try handle.read(upToCount: requested),
                      !chunk.isEmpty else { return data }
                data.append(chunk)
                guard data.count <= maximumBytes else {
                    throw Failure.tooLarge(maximumBytes: maximumBytes)
                }
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cannotRead
        }
    }
}
