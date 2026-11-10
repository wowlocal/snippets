import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Compiled into the apps and the test package. Not part of `snippets-cli`.
//
// A deliberately small, dependency-free subset of git's object model: exactly what the
// serverless git sync transport needs to read a snapshot from, and write one commit to,
// an ordinary hosted repository. It is not a general-purpose git implementation: no
// index, no working tree, no merges, no tags, no SHA-256 repositories.

/// A SHA-1 git object name.
nonisolated struct GitObjectID: Hashable, Sendable, Comparable, CustomStringConvertible {
    static let byteCount = 20
    static let hexCount = 40
    static let zero = GitObjectID(uncheckedBytes: [UInt8](repeating: 0, count: byteCount))

    let bytes: [UInt8]

    private init(uncheckedBytes: [UInt8]) { bytes = uncheckedBytes }

    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Array(bytes)
    }

    /// Accepts only canonical lowercase hex, which is what every git server emits.
    init?(hex: some StringProtocol) {
        let utf8 = Array(hex.utf8)
        guard utf8.count == Self.hexCount else { return nil }
        var result = [UInt8](repeating: 0, count: Self.byteCount)
        for index in 0..<Self.byteCount {
            guard let high = Self.nibble(utf8[2 * index]),
                  let low = Self.nibble(utf8[2 * index + 1]) else { return nil }
            result[index] = high << 4 | low
        }
        bytes = result
    }

    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(Self.hexCount)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    var isZero: Bool { bytes.allSatisfy { $0 == 0 } }
    var description: String { hex }

    static func < (lhs: GitObjectID, rhs: GitObjectID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    /// The git object name of `content` stored as `type`.
    static func hash(type: GitObjectType, content: some Collection<UInt8>) -> GitObjectID {
        var hasher = Insecure.SHA1()
        hasher.update(data: GitObjectType.header(type: type, size: content.count))
        hasher.update(data: Data(content))
        return GitObjectID(uncheckedBytes: Array(hasher.finalize()))
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}

nonisolated enum GitObjectType: UInt8, Sendable, Equatable {
    case commit = 1
    case tree = 2
    case blob = 3
    case tag = 4

    var name: String {
        switch self {
        case .commit: "commit"
        case .tree: "tree"
        case .blob: "blob"
        case .tag: "tag"
        }
    }

    init?(name: some StringProtocol) {
        switch name {
        case "commit": self = .commit
        case "tree": self = .tree
        case "blob": self = .blob
        case "tag": self = .tag
        default: return nil
        }
    }

    /// `"<type> <size>\0"`, the prefix hashed (and stored loose) before the content.
    static func header(type: GitObjectType, size: Int) -> Data {
        var data = Data("\(type.name) \(size)".utf8)
        data.append(0)
        return data
    }
}

/// One decoded object.
nonisolated struct GitObject: Sendable, Equatable {
    var type: GitObjectType
    var content: Data

    var id: GitObjectID { GitObjectID.hash(type: type, content: content) }
}

/// Every malformed-input path in this layer throws this closed error. The cases carry
/// no remote-supplied text, so they are safe to surface in a sync status.
nonisolated enum GitFormatError: Error, Equatable, Sendable {
    case invalidObject(String)
    case invalidPack(String)
    case invalidPktLine
    case invalidDelta
    case limitExceeded(String)
    case compression
}

// MARK: - Trees

nonisolated struct GitTreeEntry: Sendable, Equatable {
    static let treeMode = Array("40000".utf8)
    static let blobMode = Array("100644".utf8)

    /// Raw ASCII mode bytes, preserved verbatim so an entry this client does not own
    /// is rewritten byte-for-byte.
    var mode: [UInt8]
    /// Raw name bytes, for the same reason. Git does not require UTF-8 names.
    var name: [UInt8]
    var id: GitObjectID

    init(mode: [UInt8], name: [UInt8], id: GitObjectID) {
        self.mode = mode
        self.name = name
        self.id = id
    }

    static func tree(_ name: String, _ id: GitObjectID) -> GitTreeEntry {
        GitTreeEntry(mode: treeMode, name: Array(name.utf8), id: id)
    }

    static func blob(_ name: String, _ id: GitObjectID) -> GitTreeEntry {
        GitTreeEntry(mode: blobMode, name: Array(name.utf8), id: id)
    }

    /// Git writes `40000`; a zero-padded `040000` from another writer is still a tree.
    var isTree: Bool { Array(mode.drop { $0 == UInt8(ascii: "0") }) == Self.treeMode }
    var isRegularFile: Bool { mode == Self.blobMode || mode == Array("100755".utf8) }
    var nameString: String? { String(validating: name, as: UTF8.self) }
}

nonisolated enum GitTree {
    static let maximumEntries = 1_000_000

    static func parse(_ content: Data) throws -> [GitTreeEntry] {
        let bytes = [UInt8](content)
        var entries: [GitTreeEntry] = []
        var index = 0
        while index < bytes.count {
            guard let space = bytes[index...].firstIndex(of: UInt8(ascii: " ")),
                  space > index else {
                throw GitFormatError.invalidObject("tree_mode")
            }
            let mode = Array(bytes[index..<space])
            guard mode.count <= 6, mode.allSatisfy({ (0x30...0x37).contains($0) }) else {
                throw GitFormatError.invalidObject("tree_mode")
            }
            guard let nul = bytes[(space + 1)...].firstIndex(of: 0), nul > space + 1 else {
                throw GitFormatError.invalidObject("tree_name")
            }
            let name = Array(bytes[(space + 1)..<nul])
            guard !name.contains(UInt8(ascii: "/")) else {
                throw GitFormatError.invalidObject("tree_name")
            }
            let idStart = nul + 1
            guard idStart + GitObjectID.byteCount <= bytes.count,
                  let id = GitObjectID(bytes: bytes[idStart..<(idStart + GitObjectID.byteCount)])
            else { throw GitFormatError.invalidObject("tree_id") }
            entries.append(GitTreeEntry(mode: mode, name: name, id: id))
            guard entries.count <= maximumEntries else {
                throw GitFormatError.limitExceeded("tree_entries")
            }
            index = idStart + GitObjectID.byteCount
        }
        return entries
    }

    /// Canonical git order: byte order, with a subtree compared as though its name
    /// ended in `/`. A server's fsck rejects trees in any other order.
    static func serialize(_ entries: [GitTreeEntry]) -> Data {
        var data = Data()
        for entry in sorted(entries) {
            data.append(contentsOf: entry.mode)
            data.append(UInt8(ascii: " "))
            data.append(contentsOf: entry.name)
            data.append(0)
            data.append(contentsOf: entry.id.bytes)
        }
        return data
    }

    static func sorted(_ entries: [GitTreeEntry]) -> [GitTreeEntry] {
        entries.sorted { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }
    }

    private static func sortKey(_ entry: GitTreeEntry) -> [UInt8] {
        entry.isTree ? entry.name + [UInt8(ascii: "/")] : entry.name
    }
}

// MARK: - Commits

nonisolated struct GitCommit: Sendable, Equatable {
    var tree: GitObjectID
    var parents: [GitObjectID]

    /// Reads only the structural headers. Author, committer and message are opaque.
    static func parse(_ content: Data) throws -> GitCommit {
        let bytes = [UInt8](content)
        var tree: GitObjectID?
        var parents: [GitObjectID] = []
        var index = 0
        while index < bytes.count {
            guard let newline = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) else {
                throw GitFormatError.invalidObject("commit_header")
            }
            if newline == index { break }
            let line = bytes[index..<newline]
            if line.starts(with: Array("tree ".utf8)) {
                guard tree == nil, let id = GitObjectID(hex: String(decoding: line.dropFirst(5), as: UTF8.self))
                else { throw GitFormatError.invalidObject("commit_tree") }
                tree = id
            } else if line.starts(with: Array("parent ".utf8)) {
                guard let id = GitObjectID(hex: String(decoding: line.dropFirst(7), as: UTF8.self))
                else { throw GitFormatError.invalidObject("commit_parent") }
                parents.append(id)
            }
            index = newline + 1
        }
        guard let tree else { throw GitFormatError.invalidObject("commit_tree") }
        return GitCommit(tree: tree, parents: parents)
    }

    /// A commit with fixed, non-identifying authorship. Hosts display these fields, so
    /// they must never carry a device name, account, or anything stable per install.
    static func serialize(
        tree: GitObjectID, parents: [GitObjectID], date: Date, message: String
    ) -> Data {
        let seconds = Int64(max(0, date.timeIntervalSince1970.rounded(.down)))
        let identity = "Snippets Sync <sync@snippets.invalid> \(seconds) +0000"
        var text = "tree \(tree.hex)\n"
        for parent in parents { text += "parent \(parent.hex)\n" }
        text += "author \(identity)\ncommitter \(identity)\n\n\(message)\n"
        return Data(text.utf8)
    }
}

// MARK: - pkt-line

/// Git's length-prefixed framing (`gitprotocol-common(5)`).
nonisolated enum GitPktLine {
    /// Four length digits plus 65516 bytes of payload.
    static let maximumPayload = 65_516
    static let flush = Data("0000".utf8)

    enum Packet: Equatable {
        case data([UInt8])
        case flush
        case delimiter
        case responseEnd
    }

    static func encode(_ payload: some Collection<UInt8>) throws -> Data {
        guard payload.count <= maximumPayload else { throw GitFormatError.invalidPktLine }
        var data = Data(String(format: "%04x", payload.count + 4).utf8)
        data.append(contentsOf: payload)
        return data
    }

    static func line(_ text: String) throws -> Data {
        try encode(Array((text + "\n").utf8))
    }

    struct Reader {
        let bytes: [UInt8]
        private(set) var offset: Int

        init(_ bytes: [UInt8], offset: Int = 0) {
            self.bytes = bytes
            self.offset = offset
        }

        var isAtEnd: Bool { offset >= bytes.count }
        var remainder: ArraySlice<UInt8> { bytes[min(offset, bytes.count)...] }

        mutating func next() throws -> Packet? {
            guard offset < bytes.count else { return nil }
            // Exactly four hex digits: `Int(_:radix:)` would also accept a sign.
            guard offset + 4 <= bytes.count,
                  bytes[offset..<(offset + 4)].allSatisfy({
                      (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0)
                  }),
                  let length = Int(String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self), radix: 16)
            else { throw GitFormatError.invalidPktLine }
            switch length {
            case 0:
                offset += 4
                return .flush
            case 1:
                offset += 4
                return .delimiter
            case 2:
                offset += 4
                return .responseEnd
            case 3:
                throw GitFormatError.invalidPktLine
            default:
                guard length <= maximumPayload + 4, offset + length <= bytes.count else {
                    throw GitFormatError.invalidPktLine
                }
                let payload = Array(bytes[(offset + 4)..<(offset + length)])
                offset += length
                return .data(payload)
            }
        }
    }

    /// Payload text with one trailing newline removed, as git tolerates either form.
    static func text(_ payload: [UInt8]) -> String {
        var trimmed = payload[...]
        if trimmed.last == UInt8(ascii: "\n") { trimmed = trimmed.dropLast() }
        return String(decoding: trimmed, as: UTF8.self)
    }
}
