import CryptoKit
import Foundation

// Compiled into the apps and the test package. Not part of `snippets-cli`.

/// How a Git library stores its records, fixed when the library is created and named
/// by the manifest's `recordProfile`. A build that does not know a profile refuses the
/// library rather than misreading it.
nonisolated enum GitLibraryMode: String, Sendable, Equatable, CaseIterable {
    /// Every record is ciphertext under `records/`.
    case encrypted = "snippets-wire-v1"
    /// Ordinary snippets are readable Markdown files under `snippets/` that people can
    /// browse, diff and edit. Secure snippets and deletions stay ciphertext under
    /// `records/`, exactly as in an encrypted library.
    case plainText = "snippets-plain-v1"
}

/// What a plain-text library needs beyond the wire: the library sealer, to open the
/// records the engine submits and to seal the ones read back from Markdown, so the
/// engine sees ordinary sealed records either way.
nonisolated struct GitPlainCodec: Sendable {
    let sealer: any SyncBlobSealing

    init(sealer: any SyncBlobSealing) {
        self.sealer = sealer
    }
}

/// One ordinary snippet as a Markdown file with front matter:
///
///     ---
///     name: "Greeting"
///     keyword: "hi"
///     tags: ["work"]
///     enabled: true
///     pinned: false
///     id: 617a0002-0000-4000-8000-000000000002
///     sync: eyJjcmVhdGVkQXQiOjgwM…
///     ---
///     Hello there!
///
/// The body is everything after the closing `---` line, minus the single newline that
/// ends the file. `sync` carries what a person never edits (clock, origin, timestamps,
/// extension bag) and the envelope hash it was written with. Reading rebuilds the
/// envelope from the file; if its hash still matches, the file is exactly what a device
/// wrote. If not, someone edited it, and every device derives the same new revision
/// from the file alone: the foreign device's clock, one tick after the one in `sync`.
nonisolated enum GitPlainSnippetFile {
    static let directoryName = "snippets"
    static let fileExtension = ".md"
    static let maximumFileBytes = 1_100_000

    nonisolated enum Failure: Error, Equatable {
        case malformed
        /// Written by a newer Snippets (a later `sync` schema, or `sync` keys this build
        /// does not know). Delivered as unreadable and never rewritten, so an older build
        /// cannot downgrade it.
        case tooNew
    }

    /// Whether an envelope can be written as a readable file. Secure records, deletions,
    /// anything carrying extension data (which can hold a secure loser's conflict
    /// snapshot, or a future field meant to stay encrypted) and anything that would not
    /// read back exactly stay ciphertext.
    static func canRender(_ envelope: SyncEnvelope) -> Bool {
        (try? render(envelope)) != nil
    }

    /// The file for `envelope`, verified to read back as exactly that envelope.
    static func render(_ envelope: SyncEnvelope) throws -> Data {
        guard !envelope.deleted, !envelope.secure, envelope.x.isEmpty,
              envelope.schemaVersion == SyncEnvelope.currentSchemaVersion,
              let fields = envelope.fields,
              fields.content.count < maximumFileBytes - 4_096,
              String(data: fields.content, encoding: .utf8) != nil else { throw Failure.malformed }
        let data = try unverifiedRender(envelope, fields: fields)
        guard let (read, edited) = try? read(data, path: "\(directoryName)/\(envelope.id.uuidString).md"),
              !edited, read == envelope else { throw Failure.malformed }
        return data
    }

    private static func unverifiedRender(_ envelope: SyncEnvelope, fields: SyncEnvelope.Fields) throws -> Data {
        let meta: CanonicalJSON.Value = .object([
            "createdAt": .double(fields.createdAt.timeIntervalSinceReferenceDate),
            "hash": .string(try envelope.envelopeHash()),
            "hlc": .string(envelope.hlc.string),
            "id": .string(envelope.id.uuidString.lowercased()),
            "origin": .string(envelope.origin),
            "schemaVersion": .int(Int64(envelope.schemaVersion)),
            "updatedAt": .double(fields.updatedAt.timeIntervalSinceReferenceDate),
            "x": .object(envelope.x),
        ])
        var text = "---\n"
        text += "name: \(try CanonicalJSON.string(.string(fields.name)))\n"
        text += "keyword: \(try CanonicalJSON.string(.string(fields.keyword)))\n"
        text += "tags: \(try CanonicalJSON.string(.array(fields.tags.map { .string($0) })))\n"
        text += "enabled: \(fields.isEnabled)\n"
        text += "pinned: \(fields.isPinned)\n"
        text += "id: \(envelope.id.uuidString.lowercased())\n"
        text += "sync: \(base64URL(try CanonicalJSON.data(meta)))\n"
        text += "---\n"
        var data = Data(text.utf8)
        data.append(fields.content)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// `greeting-617a0002.md`: readable, sorted by name, and unique enough that two
    /// snippets with one name do not collide.
    static func fileName(name: String, id: UUID) -> String {
        "\(slug(name))-\(id.uuidString.lowercased().prefix(8))\(fileExtension)"
    }

    /// Lowercase ASCII letters and digits joined by single hyphens, at most 48 long.
    /// Other scripts are transliterated where the platform can, so `Привет` becomes
    /// `privet`; anything left is dropped, and an empty result is `snippet`.
    static func slug(_ text: String) -> String {
        var source = text
        #if canImport(Darwin)
        source = source.applyingTransform(.toLatin, reverse: false) ?? source
        source = source.applyingTransform(.stripDiacritics, reverse: false) ?? source
        #endif
        var slug = ""
        var pendingHyphen = false
        for scalar in source.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !slug.isEmpty { slug.append("-") }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
                if slug.count >= 48 { break }
            } else {
                pendingHyphen = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "snippet" : slug
    }

    /// The id a file declares in its front matter, or for a file someone added by hand
    /// without one, an id derived from its path, the same on every device. A file whose
    /// front matter does not parse still keeps an `id` line it can be matched by.
    static func declaredID(_ data: Data, path: String) -> UUID {
        if let parsed = try? parse(data), let id = parsed.meta?.id ?? parsed.id { return id }
        if let id = scanID(data) { return id }
        return derivedID(path: path)
    }

    /// Whether the file starts with a front-matter line (`---`, after an optional BOM).
    /// Such a file that fails to parse is a mistake to quarantine, never a new snippet.
    static func hasFrontMatter(_ data: Data) -> Bool {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard bytes.starts(with: Array("---".utf8)) else { return false }
        let rest = bytes.dropFirst(3).prefix { $0 != UInt8(ascii: "\n") }
        return rest.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }
    }

    /// The id of a file whose front matter does not parse: its `sync` metadata's, else
    /// its first valid `id` line's. Lines are split on bytes, so CRLF files scan too.
    private static func scanID(_ data: Data) -> UUID? {
        guard hasFrontMatter(data) else { return nil }
        var lineID: UUID?
        for raw in data.prefix(16_384).split(separator: UInt8(ascii: "\n")).dropFirst() {
            let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "---" { break }
            let lowered = text.lowercased()
            if lowered.hasPrefix("sync:"), let meta = meta(text.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
                return meta.id
            }
            if lineID == nil, lowered.hasPrefix("id:") {
                lineID = UUID(uuidString: string(text.dropFirst(3).trimmingCharacters(in: .whitespaces)))
            }
        }
        return lineID
    }

    static func derivedID(path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("snippets-git-plain-file-v1\n\(path)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80   // version 8: custom
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The envelope a file describes, and whether it was edited since a device wrote it.
    /// `assigning` gives the file a different id than it declares (a copy that kept the
    /// original's id becomes its own snippet); that is always an edit.
    static func read(
        _ data: Data, path: String, assigning assignedID: UUID? = nil
    ) throws -> (envelope: SyncEnvelope, edited: Bool) {
        guard data.count <= maximumFileBytes else { throw Failure.malformed }
        let parsed: Parsed
        if hasFrontMatter(data) {
            // A mistake in front matter quarantines this snippet; it never turns the
            // file into a different one.
            parsed = try parse(data)
            guard !parsed.newerSync else { throw Failure.tooNew }
        } else {
            // A plain Markdown file added by hand: its name is the file name.
            let stem = (path as NSString).lastPathComponent
            parsed = Parsed(
                name: stem.hasSuffix(fileExtension) ? String(stem.dropLast(fileExtension.count)) : stem,
                body: stripFinalNewline(data[...], crlf: false))
        }
        let id = assignedID ?? parsed.meta?.id ?? parsed.id ?? derivedID(path: path)
        let createdAt = parsed.meta?.createdAt ?? 0
        let updatedAt = parsed.meta?.updatedAt ?? 0
        let x = parsed.meta?.x ?? [:]

        // Exact only as a device wrote it: the current schema, and the id it declares.
        // A file read under another id (a copy, a changed `id` line) is always an edit,
        // so normalizing rewrites its `id` line.
        if let meta = parsed.meta, meta.schemaVersion == SyncEnvelope.currentSchemaVersion,
           meta.id == id, parsed.id == meta.id, let exact = try? envelope(
            id: id, schemaVersion: meta.schemaVersion, hlc: meta.hlc, origin: meta.origin,
            name: parsed.name ?? "", keyword: parsed.keyword ?? "", content: parsed.body,
            tags: parsed.tags ?? [], isEnabled: parsed.enabled ?? true, isPinned: parsed.pinned ?? false,
            createdAt: createdAt, updatedAt: updatedAt, x: x),
           (try? exact.envelopeHash()) == meta.hash {
            return (exact, false)
        }

        // Edited (or added) by hand. Deterministic from the file alone, so every device
        // derives the same revision and they never push the same edit back and forth.
        let previous = parsed.meta.flatMap { HLC(parsing: $0.hlc) }
        let hlc = previous.map(bumped) ?? HLC(wallMs: 0, counter: 0, device: HLC.foreignDevice)
        let edited = try envelope(
            id: id, schemaVersion: SyncEnvelope.currentSchemaVersion, hlc: hlc.string,
            origin: HLC.foreignDevice, name: parsed.name ?? "", keyword: parsed.keyword ?? "",
            content: parsed.body, tags: SnippetTagging.normalizedTags(parsed.tags ?? []),
            isEnabled: parsed.enabled ?? true, isPinned: parsed.pinned ?? false,
            createdAt: createdAt, updatedAt: updatedAt, x: x)
        return (edited, true)
    }

    /// The next reading after `hlc`, on the foreign device.
    static func bumped(_ hlc: HLC) -> HLC {
        hlc.counter < UInt16.max
            ? HLC(wallMs: hlc.wallMs, counter: hlc.counter + 1, device: HLC.foreignDevice)
            : HLC(wallMs: hlc.wallMs + 1, counter: 0, device: HLC.foreignDevice)
    }

    // MARK: - Parsing

    struct Meta: Equatable {
        /// The snippet's id, covered by `hash`. It, not the editable `id` line, decides
        /// which snippet a file is, so every device reads the same id from the same file.
        var id: UUID
        var hlc: String
        var origin: String
        var schemaVersion: Int
        var createdAt: Double
        var updatedAt: Double
        var x: [String: CanonicalJSON.Value]
        var hash: String
    }

    struct Parsed {
        var name: String?
        var keyword: String?
        var tags: [String]?
        var enabled: Bool?
        var pinned: Bool?
        var id: UUID?
        var meta: Meta?
        /// The `sync` line came from a newer format (see `Failure.tooNew`).
        var newerSync = false
        var body: Data

        init(name: String? = nil, body: Data) {
            self.name = name
            self.body = body
        }
    }

    /// Front matter between `---` lines, then the body. Lenient about what people type:
    /// a leading BOM, quoted or bare strings, JSON, bare or YAML block (`- item`) tag
    /// lists, `yes`/`no`/`1`/`0`, CRLF line endings, blank lines, `#` comments and lines
    /// without a key. Unknown keys are ignored.
    static func parse(_ data: Data) throws -> Parsed {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        func line(at start: Int) -> (text: String, next: Int)? {
            guard start < bytes.count else { return nil }
            var end = start
            while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
            var lineBytes = bytes[start..<end]
            if lineBytes.last == UInt8(ascii: "\r") { lineBytes = lineBytes.dropLast() }
            return (String(decoding: lineBytes, as: UTF8.self), min(end + 1, bytes.count))
        }
        guard let opening = line(at: 0), opening.text.trimmingCharacters(in: .whitespaces) == "---" else {
            throw Failure.malformed
        }
        var parsed = Parsed(body: Data())
        var cursor = opening.next
        var closed = false
        var closingWasCRLF = false
        var collectingTags = false
        while let current = line(at: cursor) {
            let raw = bytes[cursor..<current.next]
            cursor = current.next
            let text = current.text.trimmingCharacters(in: .whitespaces)
            if text == "---" {
                closed = true
                closingWasCRLF = raw.suffix(2).elementsEqual([UInt8(ascii: "\r"), UInt8(ascii: "\n")])
                break
            }
            if collectingTags, text.hasPrefix("-") {
                let item = string(String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
                if !item.isEmpty { parsed.tags = (parsed.tags ?? []) + [item] }
                continue
            }
            collectingTags = false
            if text.isEmpty || text.hasPrefix("#") { continue }
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": parsed.name = string(value)
            case "keyword": parsed.keyword = string(value)
            case "tags":
                parsed.tags = tags(value)
                collectingTags = value.isEmpty
            case "enabled": parsed.enabled = try bool(value)
            case "pinned": parsed.pinned = try bool(value)
            case "id":
                // A mangled id is ignored (the file keeps the snippet it was at this path),
                // and the first valid `id` line wins over any later one.
                if parsed.id == nil, let id = UUID(uuidString: string(value)) { parsed.id = id }
            case "sync":
                parsed.meta = meta(value)
                parsed.newerSync = isNewerSync(value)
            default: continue
            }
        }
        guard closed else { throw Failure.malformed }
        parsed.body = stripFinalNewline(Data(bytes[cursor...])[...], crlf: closingWasCRLF)
        return parsed
    }

    /// The file ends with one newline that is not part of the body; writers add `\n`,
    /// and an editor that saved the file with CRLF line endings adds `\r\n`.
    private static func stripFinalNewline(_ body: Data.SubSequence, crlf: Bool) -> Data {
        var body = body
        if crlf, body.suffix(2).elementsEqual([UInt8(ascii: "\r"), UInt8(ascii: "\n")]) {
            body = body.dropLast(2)
        } else if body.last == UInt8(ascii: "\n") {
            body = body.dropLast()
        }
        return Data(body)
    }

    private static func string(_ value: String) -> String {
        if value.hasPrefix("\""), let text = try? CanonicalJSON.value(Data(value.utf8)).text { return text }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func tags(_ value: String) -> [String] {
        if value.hasPrefix("["), let array = try? CanonicalJSON.value(Data(value.utf8)).array {
            let texts = array.compactMap(\.text)
            if texts.count == array.count { return texts }
        }
        var inner = Substring(value)
        if inner.hasPrefix("["), inner.hasSuffix("]") { inner = inner.dropFirst().dropLast() }
        return inner.split(separator: ",")
            .map { string($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func bool(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw Failure.malformed
        }
    }

    /// A well-formed `sync` object from a later schema, or with keys beyond the ones this
    /// build writes. A malformed or partial one is a hand edit, not a newer format.
    private static func isNewerSync(_ value: String) -> Bool {
        guard let data = base64URLDecoded(value),
              let object = try? CanonicalJSON.value(data).object else { return false }
        if let schemaVersion = object["schemaVersion"]?.int, schemaVersion > SyncEnvelope.currentSchemaVersion {
            return true
        }
        let known: Set<String> = ["createdAt", "hash", "hlc", "id", "origin", "schemaVersion", "updatedAt", "x"]
        return Set(object.keys).isStrictSuperset(of: known)
    }

    private static func meta(_ value: String) -> Meta? {
        guard let data = base64URLDecoded(value),
              let object = try? CanonicalJSON.value(data).object,
              Set(object.keys) == ["createdAt", "hash", "hlc", "id", "origin", "schemaVersion", "updatedAt", "x"],
              let idText = object["id"]?.text, let id = UUID(uuidString: idText), id.uuidString.lowercased() == idText,
              let hlc = object["hlc"]?.text, let origin = object["origin"]?.text,
              let schemaVersion = object["schemaVersion"]?.int,
              let createdAt = object["createdAt"]?.double, let updatedAt = object["updatedAt"]?.double,
              let x = object["x"]?.object, let hash = object["hash"]?.text else { return nil }
        return Meta(id: id, hlc: hlc, origin: origin, schemaVersion: Int(schemaVersion), createdAt: createdAt,
                    updatedAt: updatedAt, x: x, hash: hash)
    }

    /// Builds the canonical envelope bytes and has `SyncEnvelope.parse` validate them, so
    /// a file can never produce an envelope the wire layer would not accept.
    private static func envelope(
        id: UUID, schemaVersion: Int, hlc: String, origin: String, name: String, keyword: String,
        content: Data, tags: [String], isEnabled: Bool, isPinned: Bool, createdAt: Double, updatedAt: Double,
        x: [String: CanonicalJSON.Value]
    ) throws -> SyncEnvelope {
        var object: [String: CanonicalJSON.Value] = [
            "schemaVersion": .int(Int64(schemaVersion)),
            "id": .string(id.uuidString.lowercased()),
            "hlc": .string(hlc),
            "origin": .string(origin),
            "secure": .bool(false),
            "deleted": .bool(false),
            "contentHash": .string(SyncEnvelope.hex(SHA256.hash(data: content))),
            "fields": .object([
                "name": .string(name),
                "keyword": .string(keyword),
                "content": .utf8(content),
                "tags": .array(tags.map { .string($0) }),
                "isEnabled": .bool(isEnabled),
                "isPinned": .bool(isPinned),
                "createdAt": .double(createdAt),
                "updatedAt": .double(updatedAt),
            ]),
            "x": .object(x),
        ]
        object["hash"] = .string(SyncEnvelope.hex(SHA256.hash(data: try CanonicalJSON.data(.object(object)))))
        return try SyncEnvelope.parse(try CanonicalJSON.data(.object(object)))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard.append("=") }
        return Data(base64Encoded: standard)
    }
}
