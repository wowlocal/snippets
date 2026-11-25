import CryptoKit
import Foundation
@testable import SnippetsCore

// MARK: - Ordered JSON for vector files

/// A JSON tree whose objects keep insertion order, so a vector file is a pure function
/// of the code that built it. Foundation's `JSONSerialization` is avoided on purpose:
/// its number and key handling is not something a byte-identical rerun should rest on.
indirect enum J {
    case null
    case bool(Bool)
    case int(Int64)
    case str(String)
    case arr([J])
    case obj([(String, J)])

    static func hex(_ data: Data) -> J { .str(data.hex) }
    static func hex(_ bytes: [UInt8]) -> J { .str(Data(bytes).hex) }
    static func n(_ value: Int) -> J { .int(Int64(value)) }
    static func strings(_ values: [String]) -> J { .arr(values.map { .str($0) }) }
    static func opt(_ value: String?) -> J { value.map { .str($0) } ?? .null }

    /// A double as its IEEE-754 bit pattern plus Swift's own `description`. A JSON
    /// number would force every reader through its own parser first.
    static func double(_ value: Double) -> J {
        .obj([
            ("bits", .str(String(format: "%016llx", value.bitPattern))),
            ("swift", .str(value.description)),
        ])
    }

    /// A `Date` as the double the Swift model actually stores.
    static func date(_ value: Date) -> J { double(value.timeIntervalSinceReferenceDate) }

    /// Text plus its exact UTF-8 bytes, for inputs where normalisation form or an
    /// invisible character is the point of the case.
    static func text(_ value: String) -> J {
        .obj([("text", .str(value)), ("utf8Hex", .str(Data(value.utf8).hex))])
    }

    /// The first object in the tree that repeats a key, as a path, if any.
    func duplicateKeyPath(_ path: String = "") -> String? {
        switch self {
        case .arr(let elements):
            for (index, element) in elements.enumerated() {
                if let found = element.duplicateKeyPath("\(path)/\(index)") { return found }
            }
            return nil
        case .obj(let members):
            var seen = Set<String>()
            for member in members {
                guard seen.insert(member.0).inserted else { return "\(path)/\(member.0)" }
                if let found = member.1.duplicateKeyPath("\(path)/\(member.0)") { return found }
            }
            return nil
        default:
            return nil
        }
    }

    func serialized() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        out.append("\n")
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .null: out.append("null")
        case .bool(let flag): out.append(flag ? "true" : "false")
        case .int(let number): out.append(String(number))
        case .str(let text): J.writeString(text, into: &out)
        case .arr(let elements):
            if elements.isEmpty { out.append("[]"); return }
            let scalarOnly = elements.allSatisfy(\.isScalar)
            if scalarOnly, elements.count <= 8 {
                out.append("[")
                for (index, element) in elements.enumerated() {
                    if index > 0 { out.append(", ") }
                    element.write(into: &out, indent: indent + 1)
                }
                out.append("]")
                return
            }
            out.append("[\n")
            for (index, element) in elements.enumerated() {
                out.append(pad + "  ")
                element.write(into: &out, indent: indent + 1)
                out.append(index + 1 < elements.count ? ",\n" : "\n")
            }
            out.append(pad + "]")
        case .obj(let members):
            if members.isEmpty { out.append("{}"); return }
            out.append("{\n")
            for (index, member) in members.enumerated() {
                out.append(pad + "  ")
                J.writeString(member.0, into: &out)
                out.append(": ")
                member.1.write(into: &out, indent: indent + 1)
                out.append(index + 1 < members.count ? ",\n" : "\n")
            }
            out.append(pad + "}")
        }
    }

    private var isScalar: Bool {
        switch self {
        case .arr, .obj: return false
        default: return true
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x09: out.append("\\t")
            case 0x0A: out.append("\\n")
            case 0x0C: out.append("\\f")
            case 0x0D: out.append("\\r")
            // Controls, DEL, the C1 block, the two line separators, the BOM and other
            // invisible format characters are escaped so no editor or reader can
            // normalise them away. Everything else is raw UTF-8.
            case 0x00...0x1F, 0x7F...0x9F, 0xAD, 0x200B...0x200F, 0x2028...0x202F,
                 0x2060...0x206F, 0xFEFF, 0xFFF9...0xFFFF:
                out.append(String(format: "\\u%04x", scalar.value))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }
}

// MARK: - Bytes

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = Data.nibble(characters[index]),
                  let low = Data.nibble(characters[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    static func filled(_ byte: UInt8, _ count: Int) -> Data { Data(repeating: byte, count: count) }

    /// `start, start+1, …` wrapping at 256.
    static func counting(from start: UInt8, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int(start) + $0) })
    }
}

extension SymmetricKey {
    var raw: Data { withUnsafeBytes { Data($0) } }
}

func utf8Text(_ data: Data) -> J {
    String(data: data, encoding: .utf8).map { J.str($0) } ?? .null
}

// MARK: - Fixed nonces

/// A stationary nonce. Reusing a nonce under one key is exactly what GCM forbids; it
/// is safe here only because every key in this tool is published test data.
func fixedNonce(_ bytes: Data) -> SnippetCrypto.NonceSource {
    SnippetCrypto.NonceSource { bytes }
}

func fixedNonce(_ byte: UInt8) -> SnippetCrypto.NonceSource {
    fixedNonce(Data.filled(byte, SnippetCrypto.nonceByteCount))
}

/// The nonce (hex) and ciphertext‖tag (hex) inside a `v1.<nonce>.<body>` envelope.
func envelopeParts(_ text: String) throws -> [(String, J)] {
    let parsed = try SnippetCrypto.Envelope.parse(text)
    return [
        ("nonceHex", .hex(parsed.nonce)),
        ("ciphertextAndTagHex", .hex(parsed.sealed)),
    ]
}

// MARK: - Errors

@_silgen_name("swift_EnumCaseName")
private func _enumCaseName<T>(_ value: T) -> UnsafePointer<CChar>?

/// `Type.case` for an enum error, independent of any `description` it carries.
func errorName(_ error: Error) -> String {
    if error is InteropFailure { return "InteropFailure" }
    let typeName = String(reflecting: type(of: error))
        .replacingOccurrences(of: "SnippetsCore.", with: "")
    if Mirror(reflecting: error).displayStyle == .enum, let name = _enumCaseName(error) {
        return "\(typeName).\(String(cString: name))"
    }
    return typeName
}

/// Runs `body` and reports `{"ok": …}` or `{"error": "Type.case"}`.
func outcome(_ body: () throws -> J) -> [(String, J)] {
    do { return [("ok", try body())] }
    catch { return [("error", .str(errorName(error)))] }
}

struct InteropFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String) throws {
    guard try condition() else { throw InteropFailure("self-check failed: \(message())") }
}

// MARK: - Vector files

enum Direction: String {
    /// Deterministic: a rerun writes the same bytes.
    case sealed
    /// Produced through a Swift API that draws its own randomness; differs per run.
    case open
}

struct VectorFile {
    var name: String
    var direction: Direction = .sealed
    var pins: String
    var notes: [String] = []
    var cases: [J]

    static var swiftVersion = "unknown"

    func data() -> Data {
        var members: [(String, J)] = [
            ("format", .str("snippets-swift-interop/\(name)/v1")),
            ("generator", .obj([
                ("tool", .str("swift-interop")),
                ("swift", .str(VectorFile.swiftVersion)),
                ("source", .str("unmodified snippets/Core (+ GitSyncKeyStore, SyncKeyStore)")),
            ])),
            ("direction", .str(direction.rawValue)),
            ("pins", .str(pins)),
        ]
        if !notes.isEmpty { members.append(("notes", .strings(notes))) }
        members.append(("cases", .arr(cases)))
        return J.obj(members).serialized()
    }
}

func vcase(_ name: String, _ members: [(String, J)]) -> J {
    .obj([("name", .str(name))] + members)
}

// MARK: - Shared fixtures (all fictional, all public)

enum Fixture {
    static let uuidA = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let uuidB = UUID(uuidString: "A0B1C2D3-E4F5-4607-8899-AABBCCDDEEFF")!
    static let uuidC = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let uuidD = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")!
    static let datasetID = UUID(uuidString: "617A0001-0000-4000-8000-0000000000AA")!

    static let libraryKey = Data.filled(0x11, 32)
    static let vaultSalt = Data.filled(0x22, 32)
    static let kid = "k-7f3a91c0-1b2"
    static var vaultKeyring: SnippetCrypto.Keyring {
        SnippetCrypto.Keyring(libraryKey: SymmetricKey(data: libraryKey), salt: vaultSalt)
    }

    /// `K_sync` material: key 0x99×32 ‖ salt 0xaa×32.
    static let syncMaterial = Data.filled(0x99, 32) + Data.filled(0xaa, 32)
    static let syncScope = "sync-v1"
    static var syncKeyring: SnippetCrypto.Keyring {
        SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data.filled(0x99, 32)), salt: Data.filled(0xaa, 32))
    }

    static let recoverySecret = Data.counting(from: 0xa0, 16)
    static let passphrase = "Café public fixture"

    /// 2026-07-29T08:00:00.500Z as seconds since 2001.
    static let created = Date(timeIntervalSinceReferenceDate: 807_004_800.5)
    static let updated = Date(timeIntervalSinceReferenceDate: 812_578_800.123456)
}

func lower(_ id: UUID) -> String { id.uuidString.lowercased() }
