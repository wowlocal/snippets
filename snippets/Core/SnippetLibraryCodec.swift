import Foundation
import CryptoKit

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// The one place `snippets.json` is encoded and decoded.
///
/// ## The format is frozen
///
/// `snippets.json` is a bare JSON array of objects with exactly the nine keys
/// `Snippet` declares, pretty-printed with sorted keys. It will not gain a tenth
/// key, ever. Everything the sync layer needs — clocks, revisions, tombstones,
/// device identity — lives in `Sync/`, and secure snippets live in `Vault/`.
///
/// The reason is compatibility in the direction that actually bites. Sparkle
/// updates roll out over days, `/usr/local/bin/snippets-cli` is a symlink the user
/// may never refresh, and debug and release builds share this directory because the
/// app is not sandboxed. `Snippet.init(from:)` ignores unknown keys and
/// `Snippet.encode(to:)` writes exactly nine, so **any older binary that opens a
/// newer file silently strips every field it does not know about and writes the
/// stripped version back**. A format that cannot grow cannot be stripped.
///
/// This also means an old build, a stale CLI, `jq`, `vim`, and a Time Machine
/// restore all remain first-class writers. The merge in `SyncMerge` is what makes
/// that safe rather than merely tolerated.
nonisolated enum SnippetLibraryCodec {

    enum Failure: Error, CustomStringConvertible {
        case unreadable

        var description: String {
            "the snippet library could not be decoded as JSON"
        }
    }

    /// The `{"snippets": [...]}` dialect that `exportSnippets(to:)` produces and
    /// that imports have always accepted.
    struct Collection: Codable {
        let snippets: [Snippet]
    }

    /// Byte-for-byte the encoder the app has always used. Changing `outputFormatting`
    /// here would rewrite every user's file on first launch, produce a spurious
    /// external-change event on every other device, and break
    /// `snippetsJSONBytesUnchangedAfterSyncEnabled`.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func encode(_ snippets: [Snippet]) throws -> Data {
        try makeEncoder().encode(snippets)
    }

    static func encodeCollection(_ snippets: [Snippet]) throws -> Data {
        try makeEncoder().encode(Collection(snippets: snippets))
    }

    /// Accepts both the bare array and the `{"snippets": …}` dialect, exactly as
    /// `SnippetStore.decodeImportData` and the CLI's loader always have.
    ///
    /// Deliberately does **not** handle the Raycast dialect: that belongs to the
    /// import path, where the user has explicitly chosen a foreign file, and must
    /// never be reachable from the code that loads the user's own library.
    static func decode(_ data: Data) throws -> [Snippet] {
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([Snippet].self, from: data) { return array }
        if let collection = try? decoder.decode(Collection.self, from: data) { return collection.snippets }
        throw Failure.unreadable
    }

    /// SHA-256 of the exact bytes on disk, hex-encoded.
    ///
    /// This is the compare-and-swap token. It is taken over bytes rather than over a
    /// decoded model on purpose: a foreign writer that reorders keys or reformats the
    /// file has changed the file, and the merge must run even though the decoded
    /// arrays compare equal.
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the library and its digest in one pass, so the digest always describes
    /// the bytes that produced the returned snippets.
    ///
    /// Returns `nil` when the file does not exist — which is a legitimate empty
    /// library, distinct from an unreadable one.
    static func read(from url: URL) throws -> (snippets: [Snippet], data: Data, digest: String)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let snippets = try decode(data)
        return (snippets, data, digest(of: data))
    }
}
