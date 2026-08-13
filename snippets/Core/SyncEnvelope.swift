import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

// MARK: - Canonical JSON

/// Deterministic JSON: exactly one byte sequence per value, on every machine, in
/// every process, in every OS release.
///
/// ## Why `JSONEncoder` is not enough, even with `.sortedKeys`
///
/// For a file only this Mac reads, "some valid JSON" is fine and `SnippetLibraryCodec`
/// uses `JSONEncoder` happily. These bytes are different: they are **hashed and then
/// encrypted**. Two devices holding byte-identical content must produce byte-identical
/// output or they will compute different record hashes, decide they disagree, and push
/// at each other forever. Four specific things make `JSONEncoder` unfit here:
///
/// - **None of its output is contractual.** `.sortedKeys` is documented as
///   "lexicographic order" without saying over what; slashes are escaped unless
///   `.withoutEscapingSlashes` is passed, which is itself an admission that the
///   escaping policy is a choice rather than a rule; and no number-formatting
///   guarantee exists at all. Foundation's JSON encoder was reimplemented wholesale in
///   swift-foundation, which is exactly the kind of event a format that is *hashed*
///   cannot survive on trust. (Measured, for the record: `.sortedKeys` does today
///   order `Z < a < b < ä`, the same as the rule below. Today is not the promise we
///   need.)
/// - **Swift's `String` ordering is not a total order over distinct keys.** Two
///   canonically equivalent spellings — `é` as U+00E9 and as `e` + U+0301 — compare
///   *equal*, so a sort keyed on them leaves their relative order unspecified.
/// - **A `Double` cannot be told from an integer** once it has been through
///   `Encodable`, and this format needs the distinction to round-trip a `Date`
///   bit-exactly.
/// - **It would force the body through `String`.** A secure snippet's plaintext is
///   `Data` on purpose; `Encodable` has no way to say "these bytes are already UTF-8,
///   escape them in place".
///
/// So the emitter below is written out by hand and its rules are stated, not inherited:
///
/// 1. No whitespace anywhere.
/// 2. Object keys sorted by their **UTF-8 byte sequence**, which is exactly code-point
///    order. It needs no normalization tables, it is a total order over distinct keys,
///    and any implementation in any language can reproduce it from this sentence.
///    (RFC 8785 sorts by UTF-16 code units instead. The two disagree for keys in
///    U+E000–U+FFFF against supplementary-plane keys, because surrogates sort below
///    U+E000; we take the order that needs no surrogate special case.)
/// 3. Strings escape only what JSON requires: `"`, `\`, and the C0 controls. `/` is
///    never escaped and non-ASCII is emitted as raw UTF-8.
/// 4. Integers print as `Int64` decimal. Doubles print via the Swift standard library's
///    shortest-round-trip algorithm, which lives in the stdlib rather than in libc or
///    ICU. A finite double always carries a `.` or an `e`, so the parser can tell `1.0`
///    from `1` and the round trip is exact.
/// 5. Duplicate object keys are a parse error, not a last-one-wins merge. Note that
///    Swift's own `==` folds canonically equivalent keys together, so `é` in its two
///    spellings arrives here as a duplicate and is refused rather than silently
///    normalized. Keys are emitted as their exact bytes, so a producer must not vary
///    the normalization of a key it reuses; every key this format defines is ASCII, and
///    the `x` bag is the only place a caller could break that.
nonisolated enum CanonicalJSON {

    /// A JSON value.
    ///
    /// `.utf8` exists for one reason and it is a security reason: a secure snippet's
    /// body must never become a Swift `String`. Swift strings are copy-on-write,
    /// heap-allocated, and freely copied by the runtime, so there is no point in the
    /// program where we could reliably overwrite one — see the honesty note on
    /// `SyncEnvelope.Fields.content`. `.utf8` carries the bytes and both the emitter
    /// and the parser handle it without ever constructing a `String`.
    ///
    /// `.string` and `.utf8` are the same JSON value and compare equal.
    enum Value: Sendable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case utf8(Data)
        case array([Value])
        case object([String: Value])
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case nonFiniteNumber
        case invalidUTF8
        case unexpectedEnd
        case unexpectedByte(offset: Int)
        case duplicateKey(String)
        case trailingBytes(offset: Int)
        case tooDeep

        var description: String {
            switch self {
            case .nonFiniteNumber:
                return "a canonical JSON number must be finite; NaN and infinity have no JSON spelling"
            case .invalidUTF8:
                return "a canonical JSON string must be valid UTF-8"
            case .unexpectedEnd:
                return "the JSON input ended in the middle of a value"
            case .unexpectedByte(let offset):
                return "unexpected byte at offset \(offset)"
            case .duplicateKey(let key):
                return "duplicate object key \"\(key)\"; canonical JSON has no last-one-wins rule"
            case .trailingBytes(let offset):
                return "trailing bytes after the top-level value at offset \(offset)"
            case .tooDeep:
                return "JSON nested deeper than \(maximumDepth) levels"
            }
        }
    }

    /// A hostile or corrupt blob must not be able to overflow the stack in a recursive
    /// descent parser. Nothing we produce nests more than three deep.
    static let maximumDepth = 32

    // MARK: Emitting

    static func data(_ value: Value) throws -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(512)
        try emit(value, into: &out)
        return Data(out)
    }

    /// Convenience for tests and diagnostics. Never call this with a value that
    /// contains a secret: it materialises a `String`.
    static func string(_ value: Value) throws -> String {
        guard let text = String(data: try data(value), encoding: .utf8) else {
            throw Failure.invalidUTF8
        }
        return text
    }

    private static func emit(_ value: Value, into out: inout [UInt8]) throws {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let flag):
            out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .int(let number):
            out.append(contentsOf: Array(String(number).utf8))
        case .double(let number):
            guard number.isFinite else { throw Failure.nonFiniteNumber }
            // `Double.description` is the stdlib's own shortest-round-trip printer. It
            // always emits a `.` or an `e` for a finite value, which is what lets the
            // parser round-trip `1.0` back to `.double` instead of `.int`.
            out.append(contentsOf: Array(number.description.utf8))
        case .string(let text):
            try emitString(Array(text.utf8), into: &out)
        case .utf8(let bytes):
            try emitString([UInt8](bytes), into: &out)
        case .array(let elements):
            out.append(UInt8(ascii: "["))
            for (index, element) in elements.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                try emit(element, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            // The sort is the whole point of the type. Dictionary iteration order is
            // randomly seeded per process, so without this two runs of the same program
            // on the same input produce different bytes and therefore different hashes.
            let sorted = members
                .map { (key: $0.key, bytes: Array($0.key.utf8), value: $0.value) }
                .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
            out.append(UInt8(ascii: "{"))
            for (index, member) in sorted.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                try emitString(member.bytes, into: &out)
                out.append(UInt8(ascii: ":"))
                try emit(member.value, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func emitString(_ bytes: [UInt8], into out: inout [UInt8]) throws {
        guard isValidUTF8(bytes) else { throw Failure.invalidUTF8 }
        out.append(UInt8(ascii: "\""))
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: Array("\\\"".utf8))
            case UInt8(ascii: "\\"): out.append(contentsOf: Array("\\\\".utf8))
            case 0x08: out.append(contentsOf: Array("\\b".utf8))
            case 0x09: out.append(contentsOf: Array("\\t".utf8))
            case 0x0A: out.append(contentsOf: Array("\\n".utf8))
            case 0x0C: out.append(contentsOf: Array("\\f".utf8))
            case 0x0D: out.append(contentsOf: Array("\\r".utf8))
            case 0x00...0x1F:
                // Lowercase hex, fixed width. The only controls without a short escape.
                out.append(contentsOf: Array(String(format: "\\u%04x", Int(byte)).utf8))
            default:
                // Everything else, including `/` and every non-ASCII byte, verbatim.
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    /// Validates UTF-8 without building a `String`.
    ///
    /// `String(data:encoding:)` would answer the same question, but it allocates a
    /// copy of the bytes — and on the vault path those bytes are the user's secret.
    /// Rejecting over-long encodings and surrogates matters too: they are the classic
    /// way to smuggle a `"` past an escaper.
    static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            let continuationCount: Int
            var scalar: UInt32
            var lowerBound: UInt32

            if lead < 0x80 {
                index += 1
                continue
            } else if lead & 0xE0 == 0xC0 {
                continuationCount = 1; scalar = UInt32(lead & 0x1F); lowerBound = 0x80
            } else if lead & 0xF0 == 0xE0 {
                continuationCount = 2; scalar = UInt32(lead & 0x0F); lowerBound = 0x800
            } else if lead & 0xF8 == 0xF0 {
                continuationCount = 3; scalar = UInt32(lead & 0x07); lowerBound = 0x1_0000
            } else {
                return false
            }

            guard index + continuationCount < bytes.count else { return false }
            for offset in 1...continuationCount {
                let byte = bytes[index + offset]
                guard byte & 0xC0 == 0x80 else { return false }
                scalar = (scalar << 6) | UInt32(byte & 0x3F)
            }
            guard scalar >= lowerBound, scalar <= 0x10_FFFF else { return false }
            guard !(0xD800...0xDFFF).contains(scalar) else { return false }
            index += continuationCount + 1
        }
        return true
    }

    // MARK: Parsing

    /// Parses JSON into `Value`, producing `.utf8` for every string so a secret can be
    /// read out of a blob without ever becoming a `String`.
    ///
    /// Object *keys* are `String`s — they have to be, dictionaries are keyed by
    /// `String` — but a key is never a secret: the envelope's key set is fixed and
    /// public.
    static func value(_ data: Data) throws -> Value {
        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw Failure.trailingBytes(offset: parser.index)
        }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> Value {
            guard depth <= CanonicalJSON.maximumDepth else { throw Failure.tooDeep }
            skipWhitespace()
            guard index < bytes.count else { throw Failure.unexpectedEnd }

            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .utf8(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        private mutating func expect(_ literal: String) throws {
            let wanted = Array(literal.utf8)
            guard index + wanted.count <= bytes.count,
                  Array(bytes[index..<(index + wanted.count)]) == wanted
            else { throw Failure.unexpectedByte(offset: index) }
            index += wanted.count
        }

        private mutating func parseObject(depth: Int) throws -> Value {
            index += 1  // '{'
            var members: [String: Value] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                    throw Failure.unexpectedByte(offset: index)
                }
                let keyBytes = try parseString()
                guard let key = String(data: keyBytes, encoding: .utf8) else {
                    throw Failure.invalidUTF8
                }
                guard members[key] == nil else { throw Failure.duplicateKey(key) }

                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    throw Failure.unexpectedByte(offset: index)
                }
                index += 1
                members[key] = try parseValue(depth: depth + 1)

                skipWhitespace()
                guard index < bytes.count else { throw Failure.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw Failure.unexpectedByte(offset: index)
            }
        }

        private mutating func parseArray(depth: Int) throws -> Value {
            index += 1  // '['
            var elements: [Value] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                elements.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw Failure.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                throw Failure.unexpectedByte(offset: index)
            }
        }

        private mutating func parseString() throws -> Data {
            index += 1  // opening quote
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw Failure.unexpectedEnd }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    guard CanonicalJSON.isValidUTF8(out) else { throw Failure.invalidUTF8 }
                    return Data(out)
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    try parseEscape(into: &out)
                    continue
                }
                // A raw control character inside a string is malformed JSON; letting it
                // through would mean a value that cannot be re-emitted canonically.
                guard byte >= 0x20 else { throw Failure.unexpectedByte(offset: index) }
                out.append(byte)
                index += 1
            }
        }

        private mutating func parseEscape(into out: inout [UInt8]) throws {
            guard index < bytes.count else { throw Failure.unexpectedEnd }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = UInt32(try parseHex4())
                if (0xD800...0xDBFF).contains(scalar) {
                    // A high surrogate must be followed by `\uDC00`-`\uDFFF`; the pair
                    // encodes one supplementary-plane scalar. Emitting the halves
                    // separately would produce invalid UTF-8.
                    guard index + 1 < bytes.count,
                          bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
                    else { throw Failure.unexpectedByte(offset: index) }
                    index += 2
                    let low = UInt32(try parseHex4())
                    guard (0xDC00...0xDFFF).contains(low) else {
                        throw Failure.unexpectedByte(offset: index)
                    }
                    scalar = 0x1_0000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    throw Failure.unexpectedByte(offset: index)
                }
                guard let unicode = Unicode.Scalar(scalar) else { throw Failure.invalidUTF8 }
                out.append(contentsOf: Array(String(unicode).utf8))
            default:
                throw Failure.unexpectedByte(offset: index - 1)
            }
        }

        private mutating func parseHex4() throws -> UInt16 {
            guard index + 4 <= bytes.count else { throw Failure.unexpectedEnd }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt16
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A")) + 10
                default: throw Failure.unexpectedByte(offset: index)
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        /// Strict JSON numbers: no leading `+`, no leading zeros, no bare `.5`, no
        /// `NaN`/`Infinity`. A token with a `.` or an exponent becomes `.double`;
        /// everything else becomes `.int`, falling back to `.double` on overflow.
        private mutating func parseNumber() throws -> Value {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }

            let integerStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            guard index > integerStart else { throw Failure.unexpectedByte(offset: start) }
            if bytes[integerStart] == UInt8(ascii: "0"), index - integerStart > 1 {
                throw Failure.unexpectedByte(offset: integerStart)
            }

            var isFloating = false
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isFloating = true
                index += 1
                let fractionStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                    index += 1
                }
                guard index > fractionStart else { throw Failure.unexpectedByte(offset: index) }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isFloating = true
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                let exponentStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                    index += 1
                }
                guard index > exponentStart else { throw Failure.unexpectedByte(offset: index) }
            }

            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            if !isFloating, let integer = Int64(token) { return .int(integer) }
            guard let number = Double(token) else { throw Failure.unexpectedByte(offset: start) }
            return .double(number)
        }
    }
}

// MARK: - Canonical JSON conveniences

nonisolated extension CanonicalJSON.Value: Equatable {

    /// `.string` and `.utf8` are the same JSON value, so they must compare equal;
    /// otherwise a value that survived a parse would not equal the value that produced
    /// it, and every round-trip assertion in the suite would be meaningless.
    nonisolated static func == (lhs: CanonicalJSON.Value, rhs: CanonicalJSON.Value) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.string, _), (.utf8, _):
            guard let a = lhs.data, let b = rhs.data else { return false }
            return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        default: return false
        }
    }
}

nonisolated extension CanonicalJSON.Value {

    var isNull: Bool { if case .null = self { return true } else { return false } }

    var bool: Bool? { if case .bool(let flag) = self { return flag } else { return nil } }

    var int: Int64? {
        switch self {
        case .int(let number): return number
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }

    /// The string's bytes. Use this, never `text`, for anything that might be a secret.
    var data: Data? {
        switch self {
        case .string(let text): return Data(text.utf8)
        case .utf8(let bytes): return bytes
        default: return nil
        }
    }

    /// Materialises a `String`. The final hop, and only for values that are plaintext
    /// metadata by design (name, keyword, tags) — never for a snippet body.
    var text: String? {
        switch self {
        case .string(let value): return value
        case .utf8(let bytes): return String(data: bytes, encoding: .utf8)
        default: return nil
        }
    }

    var array: [CanonicalJSON.Value]? {
        if case .array(let elements) = self { return elements } else { return nil }
    }

    var object: [String: CanonicalJSON.Value]? {
        if case .object(let members) = self { return members } else { return nil }
    }
}

// Literal conformances so an `x` bag, and the tests that exercise one, read as JSON
// rather than as a pile of case constructors.

nonisolated extension CanonicalJSON.Value: ExpressibleByNilLiteral {
    nonisolated init(nilLiteral: ()) { self = .null }
}

nonisolated extension CanonicalJSON.Value: ExpressibleByBooleanLiteral {
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
}

nonisolated extension CanonicalJSON.Value: ExpressibleByIntegerLiteral {
    nonisolated init(integerLiteral value: Int64) { self = .int(value) }
}

nonisolated extension CanonicalJSON.Value: ExpressibleByFloatLiteral {
    nonisolated init(floatLiteral value: Double) { self = .double(value) }
}

nonisolated extension CanonicalJSON.Value: ExpressibleByStringLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
}

nonisolated extension CanonicalJSON.Value: ExpressibleByArrayLiteral {
    nonisolated init(arrayLiteral elements: CanonicalJSON.Value...) { self = .array(elements) }
}

nonisolated extension CanonicalJSON.Value: ExpressibleByDictionaryLiteral {
    nonisolated init(dictionaryLiteral elements: (String, CanonicalJSON.Value)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { first, _ in first }))
    }
}

// MARK: - The sealing seam

/// The three clear-text fields of a `WireRecord` — everything that travels *beside*
/// the blob.
///
/// Sealing binds the blob to all three, which is the entire defence against a backend
/// that shuffles records around: a blob cannot be moved onto another id, served under
/// a different revision, or have its tombstone flag flipped, because all three change
/// the bytes the AEAD tag was computed over and `open` fails rather than quietly
/// returning the wrong record.
nonisolated struct WireIdentity: Equatable, Sendable {
    var id: UUID
    var rev: String
    var deleted: Bool

    /// The authenticated-but-not-encrypted bytes.
    ///
    /// Canonical JSON rather than an ad-hoc concatenation, because an ambiguous
    /// encoding of associated data is a real attack: `id="ab" rev="c"` must not
    /// authenticate the same bytes as `id="a" rev="bc"`. (`SnippetCrypto` solves the
    /// same problem with length-prefixed fields; a conformer backed by it uses its own
    /// builder and ignores this one.)
    func associatedData() throws -> Data {
        try CanonicalJSON.data(.object([
            "id": .string(id.uuidString.lowercased()),
            "rev": .string(rev),
            "deleted": .bool(deleted),
        ]))
    }
}

/// Sealing and opening one record's bytes.
///
/// The wire layer deliberately knows nothing about key derivation, key storage, or
/// which cipher is in use — that is `SnippetCrypto`'s job, and it is the only part of
/// this feature that touches the Keychain. This protocol is the whole seam between
/// them, which is what lets the entire sync engine be exercised against
/// `InMemoryTransport` and a throwaway key with no Keychain, no entitlements, and no
/// signed bundle.
///
/// The identity is passed rather than pre-rendered AAD because `SnippetCrypto` derives
/// a **per-record key** from the record id: a conformer needs the id itself, not a
/// digest of it. `SnippetCryptoSealer` below is the shipping conformance.
nonisolated protocol SyncBlobSealing: Sendable {
    func seal(_ plaintext: Data, for identity: WireIdentity) throws -> Data
    func open(_ ciphertext: Data, for identity: WireIdentity) throws -> Data

    /// The value that goes in `WireRecord.rev`.
    ///
    /// See the default implementation for what the default choice does and does not
    /// give away.
    func revisionToken(for envelopeHash: String) -> String
}

nonisolated extension SyncBlobSealing {

    /// The unkeyed default: the first 128 bits of the envelope hash.
    ///
    /// **What this tells the backend operator.** `rev` is deterministic in the
    /// plaintext envelope, so an operator can see that two records — or two devices'
    /// copies of one record — are byte-identical, and can *confirm a guess* if they can
    /// reconstruct an entire envelope exactly (right body, right name, right keyword,
    /// right tags, right HLC, right timestamps to the bit). That last requirement makes
    /// dictionary attacks on the body alone useless, but it is not nothing, and the
    /// determinism is not free: it is what makes a re-push of unchanged content a
    /// no-op instead of an infinite loop.
    ///
    /// A conformer that wants to close even that gap overrides this with an HMAC under
    /// a key only the fleet holds. Nothing else in the wire layer has to change.
    func revisionToken(for envelopeHash: String) -> String {
        String(envelopeHash.prefix(32))
    }
}

/// The shipping conformance: `SnippetCrypto` driving the wire.
///
/// It is a thin adapter and it should stay thin. Two things are worth spelling out
/// about the join:
///
/// - **The key is per record.** `SnippetCrypto.Keyring.recordKey(for:)` derives a
///   distinct key from the record id, which is why this protocol passes a
///   `WireIdentity` rather than pre-rendered AAD: an adapter needs the id itself.
///   The per-record key is also what makes a 96-bit random nonce safe however many
///   times one record is re-sealed.
/// - **The AAD is `SnippetCrypto`'s, not ours.** `additionalData(for:)` is documented
///   there as the single AAD builder, and having two would mean two devices computing
///   different bytes for the same record. `rev` is deliberately *not* folded in:
///   `WireCodec.open` already recomputes the revision token from the opened envelope
///   and rejects a mismatch, so a rolled-back revision is caught either way, and the
///   check that does not require a second AAD dialect is the one to keep.
nonisolated struct SnippetCryptoSealer: SyncBlobSealing {

    var keyring: SnippetCrypto.Keyring
    /// Must be the vault document's `kid` — see `SnippetCrypto.RecordContext.scopeID`.
    /// Sourcing it from `SyncState.scopeID` would make every secure snippet
    /// undecryptable the first time `Sync/state.json` goes missing, because that file
    /// is designed to regenerate itself. Scopes the crypto so a shared vault can be added
    /// later without re-encrypting anything that exists today.
    var scopeID: String
    var nonces: SnippetCrypto.NonceSource

    init(
        keyring: SnippetCrypto.Keyring,
        scopeID: String,
        nonces: SnippetCrypto.NonceSource = .system
    ) {
        self.keyring = keyring
        self.scopeID = scopeID
        self.nonces = nonces
    }

    private func context(_ identity: WireIdentity) -> SnippetCrypto.RecordContext {
        SnippetCrypto.RecordContext(
            scopeID: scopeID, recordID: identity.id, isDeleted: identity.deleted)
    }

    func seal(_ plaintext: Data, for identity: WireIdentity) throws -> Data {
        // `SnippetCrypto` speaks in its own textual envelope so the same value can sit
        // in `vault.json`; the wire wants bytes. The conversion is the whole impedance
        // mismatch, and it is ASCII either way.
        Data(try SnippetCrypto.seal(
            plaintext, for: context(identity), keyring: keyring, nonces: nonces).utf8)
    }

    func open(_ ciphertext: Data, for identity: WireIdentity) throws -> Data {
        guard let text = String(data: ciphertext, encoding: .utf8) else {
            throw SnippetCrypto.Failure.malformedEnvelope("blob is not a SnippetCrypto envelope")
        }
        return try SnippetCrypto.open(text, for: context(identity), keyring: keyring)
    }
}

// MARK: - The wire record

/// The application fields that leave the device, plus opaque backend concurrency state.
///
/// Everything else — name, keyword, tags, body, `secure`, the HLC, the originating
/// device, the timestamps — lives **inside** `blob`, encrypted. A backend operator, or
/// Apple, or whoever ends up with the bucket, sees a set of opaque ids, opaque
/// revisions, a deletion flag, ciphertext, and the backend's own generation token. They
/// can count a user's snippets and
/// watch when they change; they cannot read one.
///
/// `deleted` is in the clear, and that is a deliberate concession rather than an
/// oversight. A backend has to be able to garbage-collect tombstones without holding a
/// key, and every alternative is worse: keeping every tombstone forever grows the
/// bucket without bound, and having the client re-upload a "still deleted" marker
/// turns an offline device into a resurrection machine. What it costs is that the
/// operator learns *that* a record was deleted and when — which they could infer from
/// the blob going stale anyway.
nonisolated struct WireRecord: Equatable, Sendable, Codable {
    /// The snippet's stable id. Visible so the backend can address a record at all.
    var id: UUID
    /// Opaque revision token. Compare for equality; never parse.
    var rev: String
    /// See the note above: in the clear solely so a backend can GC tombstones.
    var deleted: Bool
    /// The sealed `SyncEnvelope`.
    var blob: Data
    /// Backend-owned optimistic-concurrency metadata. It is deliberately outside the
    /// sealed identity: refreshing a CloudKit change tag does not change user content,
    /// the application revision, or the ciphertext.
    var recordVersion: SyncRecordVersion?

    init(
        id: UUID, rev: String, deleted: Bool, blob: Data,
        recordVersion: SyncRecordVersion? = nil
    ) {
        self.id = id
        self.rev = rev
        self.deleted = deleted
        self.blob = blob
        self.recordVersion = recordVersion
    }
}

// MARK: - The envelope

/// The full record, as it exists **inside** the encrypted blob.
///
/// ## The key set is frozen at exactly ten
///
/// `snippets.json` is frozen at nine keys because an older build that reads a newer
/// file strips every key it does not know and writes the stripped version back — see
/// `SnippetLibraryCodec`. The wire has the same hazard with a longer fuse: a device
/// that has not been updated in six months round-trips every record in the library.
///
/// The answer here is the same shape as there. The top-level key set never grows; a
/// future field goes inside `x`, which every build preserves verbatim without
/// understanding it. An envelope carrying an unrecognised *top-level* key is treated as
/// malformed and quarantined rather than silently stripped, because a strip is a data
/// loss that nobody notices and a quarantine is a data loss that nobody suffers.
///
/// `hash` and `contentHash` are computed, not stored, so there is no way to hold an
/// envelope whose hash is stale.
nonisolated struct SyncEnvelope: Equatable, Sendable {

    static let currentSchemaVersion = 1

    /// The vault's keyed plaintext hash, carried inside the encrypted extension bag.
    ///
    /// `contentHash` at the top level is deliberately the SHA-256 of `fields.content`.
    /// For a secure record those bytes are the stable sealed value from `vault.json`,
    /// not the plaintext, so that digest cannot be written back to
    /// `VaultRecord.contentHash`: the latter is an HMAC under the library key. Keeping
    /// the HMAC in `x` lets a locked peer preserve it without changing the frozen wire
    /// key set or exposing it outside the encrypted blob.
    static let vaultContentHashExtensionKey = "vaultContentHash"

    /// The `kid` of the vault whose key sealed this record's body, inside the encrypted
    /// extension bag.
    ///
    /// A secure record's body travels as the vault's `sealed` bytes verbatim, and those
    /// are AEAD-bound to the originating vault's `kid`. Nothing on the receiving side
    /// could see that: the scope lives in the AAD, which is not part of the envelope
    /// text, so a Mac with a *different* vault would happily file the record, show its
    /// name and keyword in the list, and fail every reveal for ever after with no
    /// explanation. Carrying the scope in the clear-to-us-but-encrypted-to-the-backend
    /// bag is what lets the import compare before writing and halt on a permanent rival
    /// identity instead of polling the same unopenable record forever.
    ///
    /// Absent on records written before this existed. Absent means "assume it matches",
    /// which is what the old code did unconditionally — no worse than before, and it
    /// keeps a pre-existing library from quarantining itself on upgrade.
    static let vaultKeyIDExtensionKey = "vaultKID"

    /// Exactly these, forever. `WireTests` asserts the count, mirroring the "exactly
    /// nine keys" discipline for `snippets.json`.
    static let topLevelKeys: Set<String> = [
        "schemaVersion", "id", "hlc", "origin", "secure", "deleted",
        "hash", "contentHash", "fields", "x",
    ]

    /// The user-meaningful payload — and, not by accident, exactly the shape of a
    /// vault record. `Vault/vault.json` stores this same set of fields with the same
    /// meanings, so promoting a snippet into the vault and syncing it are the same
    /// conversion twice.
    nonisolated struct Fields: Equatable, Sendable {

        static let keys: Set<String> = [
            "name", "keyword", "content", "tags", "isEnabled", "isPinned",
            "createdAt", "updatedAt",
        ]

        var name: String
        var keyword: String

        /// The snippet body, as bytes.
        ///
        /// **Honesty note.** This is `Data` and not `String` because a secure snippet's
        /// body passes through here, and a Swift `String` cannot be reliably zeroed:
        /// it is copy-on-write, heap-allocated, and the runtime is free to copy it when
        /// it grows, bridges, or is captured. There is no point at which we could
        /// overwrite every copy. Keeping the body as `Data` end-to-end — through the
        /// canonical emitter, which escapes bytes directly, and through the parser,
        /// which never builds a `String` for a string value — at least keeps the number
        /// of copies bounded and lets the final `String` exist only at the last hop,
        /// immediately before the characters are typed. That is a real reduction in
        /// exposure. It is *not* a guarantee that the plaintext is gone from memory,
        /// and nothing here should be read as claiming otherwise.
        var content: Data

        var tags: [String]
        var isEnabled: Bool
        var isPinned: Bool
        var createdAt: Date
        var updatedAt: Date

        init(
            name: String,
            keyword: String,
            content: Data,
            tags: [String],
            isEnabled: Bool,
            isPinned: Bool,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.name = name
            self.keyword = keyword
            self.content = content
            self.tags = SnippetTagging.normalizedTags(tags)
            self.isEnabled = isEnabled
            self.isPinned = isPinned
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Reconstitutes fields that are already on the wire without applying today's
        /// domain normalization rules to yesterday's hashed bytes. New local fields go
        /// through the public module initializer above; parsed fields must be lossless.
        private init(
            wireName name: String,
            keyword: String,
            content: Data,
            wireTags tags: [String],
            isEnabled: Bool,
            isPinned: Bool,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.name = name
            self.keyword = keyword
            self.content = content
            self.tags = tags
            self.isEnabled = isEnabled
            self.isPinned = isPinned
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var canonicalValue: CanonicalJSON.Value {
            .object([
                "name": .string(name),
                "keyword": .string(keyword),
                "content": .utf8(content),
                "tags": .array(tags.map { .string($0) }),
                "isEnabled": .bool(isEnabled),
                "isPinned": .bool(isPinned),
                // Seconds since the 2001 reference epoch — the number `Date` actually
                // stores, so the round trip is bit-exact.
                //
                // The obvious alternative, milliseconds since 1970, is *lossy*: `Date`
                // holds a `Double` of `timeIntervalSinceReferenceDate`, and adding
                // 978307200 then subtracting it again does not always land back on the
                // same bits at the magnitudes involved. Losing the low bit of
                // `updatedAt` would be a slow disaster rather than a rounding nit —
                // every sync would see a changed timestamp, rewrite the record, and
                // hand the other device a fresh change to echo back. ISO 8601 has the
                // same problem with a different spelling.
                "createdAt": .double(createdAt.timeIntervalSinceReferenceDate),
                "updatedAt": .double(updatedAt.timeIntervalSinceReferenceDate),
            ])
        }

        static func parse(_ value: CanonicalJSON.Value) throws -> Fields {
            guard let object = value.object else {
                throw SyncEnvelope.Failure.malformed("\"fields\" is not an object")
            }
            let unknown = Set(object.keys).subtracting(keys)
            guard unknown.isEmpty else {
                throw SyncEnvelope.Failure.malformed(
                    "unknown key(s) in \"fields\": \(unknown.sorted().joined(separator: ", "))")
            }
            func require(_ key: String) throws -> CanonicalJSON.Value {
                guard let member = object[key] else {
                    throw SyncEnvelope.Failure.malformed("\"fields\" is missing \"\(key)\"")
                }
                return member
            }
            guard let name = try require("name").text,
                  let keyword = try require("keyword").text,
                  let content = try require("content").data,
                  let tagValues = try require("tags").array,
                  let isEnabled = try require("isEnabled").bool,
                  let isPinned = try require("isPinned").bool,
                  let createdAt = try require("createdAt").double,
                  let updatedAt = try require("updatedAt").double
            else { throw SyncEnvelope.Failure.malformed("a \"fields\" member has the wrong type") }

            let tags = try tagValues.map { element -> String in
                guard let tag = element.text else {
                    throw SyncEnvelope.Failure.malformed("\"tags\" must be an array of strings")
                }
                return tag
            }

            return Fields(
                wireName: name, keyword: keyword, content: content, wireTags: tags,
                isEnabled: isEnabled, isPinned: isPinned,
                createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
                updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt))
        }
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        /// Written by a newer build. Display it, never push it back — the same rule
        /// `SyncStateFile` applies to `state.json`, for the same reason.
        case tooNew(version: Int)
        case malformed(String)
        /// The envelope decrypted and parsed, but its `hash` does not describe its
        /// contents. Belt and braces behind the AEAD tag: it also catches our own
        /// encoder drifting, which the AEAD cannot.
        case hashMismatch
        /// The blob's id, rev, or deletion flag disagrees with the `WireRecord` that
        /// carried it — a backend swapping blobs between records.
        case identityMismatch(String)

        var description: String {
            switch self {
            case .tooNew(let version):
                return "this record was written by a newer version of Snippets (envelope schema \(version))"
            case .malformed(let detail):
                return "malformed sync envelope: \(detail)"
            case .hashMismatch:
                return "sync envelope hash does not match its contents"
            case .identityMismatch(let detail):
                return "sync envelope does not match the record that carried it: \(detail)"
            }
        }
    }

    var schemaVersion: Int
    var id: UUID
    var hlc: HLC
    /// The device that produced this version. Eight hex characters; inside the blob, so
    /// the backend never learns how many Macs the user owns.
    var origin: String
    /// Whether the record belongs in `Vault/vault.json` rather than `snippets.json`.
    /// Inside the blob, so the backend cannot even tell which of a user's snippets are
    /// the secret ones.
    var secure: Bool
    /// A tombstone. Always accompanied by `fields == nil`.
    ///
    /// `private(set)`, along with `fields`, so the pairing cannot be broken from
    /// outside this file. It would be a one-line accident — `envelope.deleted = true`
    /// on a live record — and the result is a "tombstone" that still carries the
    /// secret it was supposed to destroy. Use `tombstoned(hlc:origin:)`.
    private(set) var deleted: Bool
    private(set) var fields: Fields?
    /// Forward-compatibility bag: anything a newer build added, preserved verbatim by
    /// every older build. Empty in every record this version writes.
    var x: [String: CanonicalJSON.Value]

    init(
        schemaVersion: Int = SyncEnvelope.currentSchemaVersion,
        id: UUID,
        hlc: HLC,
        origin: String,
        secure: Bool,
        deleted: Bool,
        fields: Fields?,
        x: [String: CanonicalJSON.Value] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.hlc = hlc
        self.origin = HLC.normalizedDevice(origin)
        self.secure = secure
        self.deleted = deleted
        // A tombstone carries no fields, and the invariant is enforced here rather than
        // checked at the call sites. A deleted secret must not linger anywhere: not in
        // the blob, not in the tombstone the backend keeps forever, not in a debug dump
        // of an envelope somebody pasted into an issue.
        self.fields = deleted ? nil : fields
        self.x = x
    }

    /// Reconstitutes a validated wire value without feeding persisted fields through
    /// domain-input normalizers. In particular, `origin` participates in `hash`, so a
    /// future change to `HLC.normalizedDevice` must not rewrite it before verification.
    private init(
        wireSchemaVersion schemaVersion: Int,
        id: UUID,
        hlc: HLC,
        wireOrigin origin: String,
        secure: Bool,
        deleted: Bool,
        fields: Fields?,
        x: [String: CanonicalJSON.Value]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.hlc = hlc
        self.origin = origin
        self.secure = secure
        self.deleted = deleted
        self.fields = deleted ? nil : fields
        self.x = x
    }

    /// SHA-256 of the body bytes, hex.
    ///
    /// Lets the engine tell "the body changed" from "only metadata changed", which is
    /// how a rename avoids re-sealing and re-uploading a large record.
    ///
    /// **This is not `SnippetCrypto.contentHash(of:keyring:)` and the two must never be
    /// compared.** That one is an HMAC under `K_hash`, because it is written to
    /// `vault.json` *in the clear*, where an unkeyed digest of a four-digit PIN is an
    /// offline oracle. This one is plain SHA-256, because it exists only inside the
    /// sealed blob and never touches disk unencrypted. Comparing "is the incoming body
    /// the same as mine" is therefore done envelope-to-envelope, never
    /// envelope-to-`vault.json`.
    ///
    /// `nil` for a tombstone, and that is not tidiness. It is the one place where this
    /// unkeyed digest could plausibly escape its ciphertext — a tombstone is the record
    /// most likely to be logged, dumped, or retained by a backend for garbage
    /// collection — and a SHA-256 of a short secret is guessable at billions of tries
    /// per second. So a tombstone carries no digest of what it used to contain.
    var contentHash: String? {
        guard !deleted, let fields else { return nil }
        return Self.hex(SHA256.hash(data: fields.content))
    }

    /// The canonical JSON object.
    ///
    /// - Parameter includingHash: `false` yields the nine-key form the hash is computed
    ///   over. A hash cannot cover itself, and excluding the key entirely is cleaner
    ///   than hashing a placeholder — there is no "empty hash" value to be mistaken for
    ///   a real one.
    func canonicalValue(includingHash: Bool = true) throws -> CanonicalJSON.Value {
        var object: [String: CanonicalJSON.Value] = [
            "schemaVersion": .int(Int64(schemaVersion)),
            "id": .string(id.uuidString.lowercased()),
            "hlc": .string(hlc.string),
            "origin": .string(origin),
            "secure": .bool(secure),
            "deleted": .bool(deleted),
            // Present as `null` rather than absent, so the key count is exactly ten for
            // every record including tombstones. A key set that varies by record is a
            // key set nobody can assert on.
            "contentHash": contentHash.map { CanonicalJSON.Value.string($0) } ?? .null,
            // `deleted ? nil : fields` and not just `fields`: the invariant is already
            // enforced in `init` and the setters are private, but this is the single
            // point where bytes leave the process, and a deleted secret must not escape
            // through a future refactor that adds one more way to set the flag.
            "fields": (deleted ? nil : fields).map(\.canonicalValue) ?? .null,
            "x": .object(x),
        ]
        if includingHash { object["hash"] = .string(try envelopeHash()) }
        return .object(object)
    }

    /// The full ten-key canonical bytes. These are what gets sealed.
    func canonicalData() throws -> Data {
        try CanonicalJSON.data(canonicalValue())
    }

    /// SHA-256 over the nine-key canonical form, hex.
    ///
    /// Throwing rather than a computed property: canonical emission can legitimately
    /// fail (a non-finite number or invalid UTF-8 smuggled in through `x`), and a
    /// property that swallowed that would hand back a hash of nothing.
    func envelopeHash() throws -> String {
        Self.hex(SHA256.hash(data: try CanonicalJSON.data(canonicalValue(includingHash: false))))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Parsing

    /// Reads an envelope back out of canonical bytes and checks that it describes
    /// itself honestly.
    static func parse(_ data: Data) throws -> SyncEnvelope {
        guard let object = try CanonicalJSON.value(data).object else {
            throw Failure.malformed("the envelope is not a JSON object")
        }

        // The version probe runs first, exactly as it does in `SyncStateFile.load`. A
        // future format may fail to decode outright, and that failure has to land in
        // "this build is too old" rather than "the record is corrupt" — otherwise an
        // older build quarantines every record a newer one wrote.
        guard let versionValue = object["schemaVersion"], let version = versionValue.int else {
            throw Failure.malformed("missing or non-integer \"schemaVersion\"")
        }
        guard version <= Int64(currentSchemaVersion) else {
            throw Failure.tooNew(version: Int(version))
        }

        let unknown = Set(object.keys).subtracting(topLevelKeys)
        guard unknown.isEmpty else {
            // Deliberately fatal for this record rather than ignored. Ignoring means
            // re-emitting the record without those keys, which is the silent strip the
            // frozen key set exists to prevent.
            throw Failure.malformed(
                "unknown top-level key(s): \(unknown.sorted().joined(separator: ", "))"
                    + "; future fields belong in \"x\"")
        }

        func require(_ key: String) throws -> CanonicalJSON.Value {
            guard let member = object[key] else {
                throw Failure.malformed("missing \"\(key)\"")
            }
            return member
        }

        guard let idText = try require("id").text, let id = UUID(uuidString: idText) else {
            throw Failure.malformed("\"id\" is not a UUID")
        }
        guard let hlcText = try require("hlc").text, let hlc = HLC(parsing: hlcText) else {
            throw Failure.malformed("\"hlc\" is not a clock reading")
        }
        guard let origin = try require("origin").text else {
            throw Failure.malformed("\"origin\" is not a string")
        }
        guard HLC.isCanonicalDeviceID(origin) else {
            throw Failure.malformed(
                "\"origin\" is not an eight-character lowercase hexadecimal device id")
        }
        guard let secure = try require("secure").bool, let deleted = try require("deleted").bool else {
            throw Failure.malformed("\"secure\" and \"deleted\" must be booleans")
        }
        guard let declaredHash = try require("hash").text else {
            throw Failure.malformed("\"hash\" is not a string")
        }
        guard let x = try require("x").object else {
            throw Failure.malformed("\"x\" is not an object")
        }

        let fieldsValue = try require("fields")
        let fields = fieldsValue.isNull ? nil : try Fields.parse(fieldsValue)

        // The tombstone invariant, checked on the way in as well as enforced on the way
        // out. A peer that sent us a "deleted" record still carrying its body is either
        // broken or hostile, and in both cases we refuse to write the body anywhere.
        if deleted, fields != nil {
            throw Failure.malformed("a tombstone must not carry \"fields\"")
        }
        if !deleted, fields == nil {
            throw Failure.malformed("a live record must carry \"fields\"")
        }
        let declaredContentHash = try require("contentHash")
        if deleted, !declaredContentHash.isNull {
            throw Failure.malformed("a tombstone must not carry \"contentHash\"")
        }

        let envelope = SyncEnvelope(
            wireSchemaVersion: Int(version), id: id, hlc: hlc, wireOrigin: origin,
            secure: secure, deleted: deleted, fields: fields, x: x)

        guard try envelope.envelopeHash() == declaredHash else { throw Failure.hashMismatch }
        if let expected = envelope.contentHash, declaredContentHash.text != expected {
            throw Failure.hashMismatch
        }
        return envelope
    }
}

// MARK: - Conversions

nonisolated extension SyncEnvelope {

    /// An ordinary snippet from `snippets.json`.
    static func plain(
        _ snippet: Snippet,
        hlc: HLC,
        origin: String,
        x: [String: CanonicalJSON.Value] = [:]
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: snippet.id, hlc: hlc, origin: origin, secure: false, deleted: false,
            fields: Fields(
                name: snippet.name, keyword: snippet.keyword,
                content: Data(snippet.content.utf8), tags: snippet.tags,
                isEnabled: snippet.isEnabled, isPinned: snippet.isPinned,
                createdAt: snippet.createdAt, updatedAt: snippet.updatedAt),
            x: x)
    }

    /// A vault record. The body arrives as `Data` and stays that way.
    ///
    /// Note what is *not* encrypted separately here: name, keyword, and tags are
    /// ordinary fields. On the wire that is moot — the whole envelope is sealed — but
    /// locally they sit in `Vault/vault.json` in the clear, because the keystroke
    /// matcher has to run with the vault locked and the app backgrounded. Encrypting
    /// the keyword would mean there is no way to detect the trigger at all. See the
    /// threat model in the vault code.
    static func secureRecord(
        id: UUID,
        name: String,
        keyword: String,
        plaintext: Data,
        tags: [String] = [],
        isEnabled: Bool = true,
        isPinned: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        hlc: HLC,
        origin: String,
        x: [String: CanonicalJSON.Value] = [:]
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id, hlc: hlc, origin: origin, secure: true, deleted: false,
            fields: Fields(
                name: name, keyword: keyword, content: plaintext, tags: tags,
                isEnabled: isEnabled, isPinned: isPinned,
                createdAt: createdAt, updatedAt: updatedAt),
            x: x)
    }

    /// A deletion. `fields` is `nil` by construction — see `init`.
    static func tombstone(
        id: UUID,
        secure: Bool,
        hlc: HLC,
        origin: String,
        x: [String: CanonicalJSON.Value] = [:]
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id, hlc: hlc, origin: origin, secure: secure, deleted: true, fields: nil, x: x)
    }

    /// Turns a live record into its own tombstone.
    ///
    /// The only supported way to delete an envelope, because it is the only one that
    /// cannot leave the body attached. The `x` bag deliberately does **not** travel: a
    /// future build could have put anything in there, including something derived from
    /// the content, and a tombstone is the last record we want carrying a souvenir.
    ///
    /// One structural exception survives for secure records: `vaultKID`. It contains no
    /// content and is needed to stop a rival vault's tombstone from deleting a local
    /// record that was authenticated under a different crypto scope.
    func tombstoned(hlc: HLC, origin: String) -> SyncEnvelope {
        var tombstoneExtensions: [String: CanonicalJSON.Value] = [:]
        if secure, let vaultKID = x[Self.vaultKeyIDExtensionKey] {
            tombstoneExtensions[Self.vaultKeyIDExtensionKey] = vaultKID
        }
        return SyncEnvelope(
            id: id, hlc: hlc, origin: origin, secure: secure, deleted: true,
            fields: nil, x: tombstoneExtensions)
    }

    /// The `snippets.json` view. `nil` for a tombstone, and `nil` for a secure record —
    /// a secure body must not be handed to a caller expecting a `String` it can put in
    /// the plaintext library.
    var plainSnippet: Snippet? {
        guard !deleted, !secure, let fields else { return nil }
        // The final hop: the body becomes a `String` here and nowhere earlier. For a
        // non-secure record there is no secret to protect; the discipline is kept
        // anyway so the two paths cannot drift.
        guard let content = String(data: fields.content, encoding: .utf8) else { return nil }
        return Snippet(
            id: id, name: fields.name, keyword: fields.keyword, content: content,
            tags: fields.tags, isEnabled: fields.isEnabled, isPinned: fields.isPinned,
            createdAt: fields.createdAt, updatedAt: fields.updatedAt)
    }

    /// The `Vault/vault.json` view: metadata plus the body as bytes.
    var vaultFields: Fields? {
        guard !deleted, secure else { return nil }
        return fields
    }

    /// The body, still as bytes, whichever store the record belongs to.
    var plaintext: Data? { deleted ? nil : fields?.content }
}

// MARK: - Sealing

/// Turns an envelope into a `WireRecord` and back.
nonisolated enum WireCodec {

    static func seal(_ envelope: SyncEnvelope, using sealer: some SyncBlobSealing) throws -> WireRecord {
        let rev = sealer.revisionToken(for: try envelope.envelopeHash())
        let identity = WireIdentity(id: envelope.id, rev: rev, deleted: envelope.deleted)
        let blob = try sealer.seal(try envelope.canonicalData(), for: identity)
        return WireRecord(id: identity.id, rev: identity.rev, deleted: identity.deleted, blob: blob)
    }

    /// Opens a record and refuses anything that does not describe itself consistently.
    ///
    /// Three checks, each closing a different hole a compromised backend could use:
    /// the AEAD tag over `{id, rev, deleted}` (a blob moved onto another record), the
    /// envelope's own `hash` (a plaintext that parsed but is not what was sealed), and
    /// the id/deleted/rev comparison (a record whose clear-text fields were edited, or
    /// an old revision advertised as a new one).
    static func open(_ record: WireRecord, using sealer: some SyncBlobSealing) throws -> SyncEnvelope {
        let identity = WireIdentity(id: record.id, rev: record.rev, deleted: record.deleted)
        let plaintext = try sealer.open(record.blob, for: identity)
        let envelope = try SyncEnvelope.parse(plaintext)

        guard envelope.id == record.id else {
            throw SyncEnvelope.Failure.identityMismatch(
                "blob is for \(envelope.id.uuidString.lowercased()), record is \(record.id.uuidString.lowercased())")
        }
        guard envelope.deleted == record.deleted else {
            throw SyncEnvelope.Failure.identityMismatch("deletion flag disagrees with the blob")
        }
        guard sealer.revisionToken(for: try envelope.envelopeHash()) == record.rev else {
            throw SyncEnvelope.Failure.identityMismatch("rev does not describe the blob")
        }
        return envelope
    }
}
