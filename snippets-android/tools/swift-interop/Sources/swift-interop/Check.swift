import CryptoKit
import Foundation
@testable import SnippetsCore

// `swift-interop check <kind> [options] <file…>`: verifies artifacts produced by the
// Kotlin implementation with the Swift code. One JSON object per file on stdout, one
// line each; exit status 0 only when every file passed.
//
// Keys and codes default to the public fixtures in `Fixture`. Results never contain
// key material: recovered keys are reported as SHA-256 digests.

extension J {
    /// One line, no spaces.
    func compact() -> String {
        var out = ""
        func write(_ value: J) {
            switch value {
            case .null: out.append("null")
            case .bool(let flag): out.append(flag ? "true" : "false")
            case .int(let number): out.append(String(number))
            case .str(let text):
                // Reuse the pretty writer's escaping through a one-element serialization.
                let line = String(decoding: J.str(text).serialized(), as: UTF8.self)
                out.append(String(line.dropLast()))
            case .arr(let elements):
                out.append("[")
                for (index, element) in elements.enumerated() {
                    if index > 0 { out.append(",") }
                    write(element)
                }
                out.append("]")
            case .obj(let members):
                out.append("{")
                for (index, member) in members.enumerated() {
                    if index > 0 { out.append(",") }
                    write(.str(member.0))
                    out.append(":")
                    write(member.1)
                }
                out.append("}")
            }
        }
        write(self)
        return out
    }
}

enum Check {
    struct Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var files: [String] = []

        func data(_ name: String, default fallback: Data) throws -> Data {
            guard let text = values[name] else { return fallback }
            guard let data = Data(hex: text) else { throw InteropFailure("--\(name) is not hex") }
            return data
        }

        func uuid(_ name: String, default fallback: UUID) throws -> UUID {
            guard let text = values[name] else { return fallback }
            guard let id = UUID(uuidString: text) else { throw InteropFailure("--\(name) is not a UUID") }
            return id
        }
    }

    static let kinds: [(String, String)] = [
        ("canonical-json", "parse with CanonicalJSON and require the re-emitted bytes to equal the file"),
        ("envelope", "SyncEnvelope.parse on canonical ten-key bytes; reports hash and rev"),
        ("sealed-record", "open a `v1.<nonce>.<body>` text [--key hex32 --salt hex --scope text --id uuid --deleted]"),
        ("wire-record", "open a records/<xx>/<uuid>.json file with WireCodec [--material hex64 --scope text --id uuid]"),
        ("vault-document", "decode Vault/vault.json with VaultFile [--key hex32 opens every record]"),
        ("backup", "open a .snippetsbackup with EncryptedSnippetBackup [--password text]"),
        ("git-recovery", "open keys/recovery.json [--code text | --secret hex16] [--dataset uuid] [--expect-material hex64]"),
        ("git-vault", "open keys/vault.json [--material hex64 --dataset uuid --code text]"),
        ("git-manifest", "decode snippets-sync.json with GitSyncManifest"),
        ("git-markdown", "read a plain-text snippet file [--path snippets/<name>.md --assign uuid]"),
        ("library-json", "decode snippets.json with SnippetLibraryCodec; prints a canonical summary"),
    ]

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        let flagNames: Set<String> = ["deleted", "verbose"]
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), argument.count > 2 {
                let name = String(argument.dropFirst(2))
                if flagNames.contains(name) {
                    options.flags.insert(name)
                } else {
                    index += 1
                    guard index < arguments.count else { throw InteropFailure("--\(name) needs a value") }
                    options.values[name] = arguments[index]
                }
            } else {
                options.files.append(argument)
            }
            index += 1
        }
        return options
    }

    /// The summary every decoded library reduces to, so two implementations can
    /// compare one digest: canonical JSON of the nine fields, ids lowercase, dates as
    /// doubles since 2001, snippets in file order.
    static func librarySummary(_ snippets: [Snippet]) throws -> Data {
        try CanonicalJSON.data(.array(snippets.map { snippet in
            .object([
                "id": .string(lower(snippet.id)),
                "name": .string(snippet.name),
                "keyword": .string(snippet.keyword),
                "content": .string(snippet.content),
                "tags": .array(snippet.tags.map { .string($0) }),
                "isEnabled": .bool(snippet.isEnabled),
                "isPinned": .bool(snippet.isPinned),
                "createdAt": .double(snippet.createdAt.timeIntervalSinceReferenceDate),
                "updatedAt": .double(snippet.updatedAt.timeIntervalSinceReferenceDate),
            ])
        }))
    }

    static func run(kind: String, options: Options, file: String, data: Data) throws -> [(String, J)] {
        switch kind {
        case "canonical-json":
            let value = try CanonicalJSON.value(data)
            let emitted = try CanonicalJSON.data(value)
            guard emitted == data else {
                let offset = zip(emitted, data).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    ?? min(emitted.count, data.count)
                throw InteropFailure("not canonical: differs from Swift's emission at byte \(offset) (file \(data.count) bytes, canonical \(emitted.count) bytes)")
            }
            return [("bytes", .n(data.count)), ("sha256", .str(sha256Hex(data)))]

        case "envelope":
            let envelope = try SyncEnvelope.parse(data)
            let canonical = try envelope.canonicalData()
            let hash = try envelope.envelopeHash()
            return [
                ("id", .str(lower(envelope.id))), ("hlc", .str(envelope.hlc.string)),
                ("secure", .bool(envelope.secure)), ("deleted", .bool(envelope.deleted)),
                ("envelopeHash", .str(hash)), ("rev", .str(String(hash.prefix(32)))),
                ("contentHash", .opt(envelope.contentHash)),
                ("isCanonical", .bool(canonical == data)),
            ]

        case "sealed-record":
            let keyring = SnippetCrypto.Keyring(
                libraryKey: SymmetricKey(data: try options.data("key", default: Fixture.libraryKey)),
                salt: try options.data("salt", default: Fixture.vaultSalt))
            let context = SnippetCrypto.RecordContext(
                scopeID: options.values["scope"] ?? Fixture.kid,
                recordID: try options.uuid("id", default: Fixture.uuidA),
                isDeleted: options.flags.contains("deleted"))
            guard let text = String(data: data, encoding: .utf8) else { throw InteropFailure("not UTF-8") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let plaintext = try SnippetCrypto.open(trimmed, for: context, keyring: keyring)
            return [
                ("scopeID", .str(context.scopeID)), ("recordID", .str(lower(context.recordID))),
                ("isDeleted", .bool(context.isDeleted)),
                ("plaintextByteCount", .n(plaintext.count)),
                ("plaintextSHA256", .str(sha256Hex(plaintext))),
                ("contentHash", .str(SnippetCrypto.contentHash(of: plaintext, keyring: keyring))),
                ("sealedCharacterCount", .n(trimmed.utf8.count)),
            ]

        case "wire-record":
            let material = try options.data("material", default: Fixture.syncMaterial)
            let keyring = try SyncKeyStore.keyring(from: material)
            let sealer = SnippetCryptoSealer(keyring: keyring, scopeID: options.values["scope"] ?? Fixture.syncScope)
            // The record's id is the one its path names; without --id, the file's own.
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let declared = (options.values["id"] ?? object["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                throw InteropFailure("not a record file with an id")
            }
            let blobID = GitObjectID.hash(type: .blob, content: data)
            let record = try GitRecordFile.decode(data, id: declared, version: GitSyncTransport.recordVersion(blobID))
            let envelope = try WireCodec.open(record, using: sealer)
            let path = GitSyncLayout.recordPath(record.id)
            return [
                ("id", .str(lower(record.id))), ("rev", .str(record.rev)), ("deleted", .bool(record.deleted)),
                ("secure", .bool(envelope.secure)), ("hlc", .str(envelope.hlc.string)),
                ("envelopeHash", .str(try envelope.envelopeHash())),
                ("path", .str("records/\(path.prefix)/\(path.name)")),
                ("gitBlobID", .str(blobID.hex)),
                ("fileIsByteExact", .bool(try GitRecordFile.encode(record) == data)),
                ("canRenderAsMarkdown", .bool(GitPlainSnippetFile.canRender(envelope))),
            ]

        case "vault-document":
            let document = try VaultFile.decode(data)
            let reencoded = try VaultFile.encode(document)
            var members: [(String, J)] = [
                ("schemaVersion", .n(document.schemaVersion)),
                ("newerThanThisBuild", .bool(document.schemaVersion > VaultDocument.currentSchemaVersion)),
                ("kid", .str(document.kid)),
                ("recordCount", .n(document.records.count)),
                ("hasWrapRecovery", .bool(document.wrapRecovery != nil)),
                ("hasWrapPass", .bool(document.wrapPass != nil)),
                ("unknownTopLevelKeys", .strings(document.x.keys.sorted())),
                ("vaultSaltByteCount", document.vaultSaltBytes.map { .n($0.count) } ?? .null),
                // Byte equality with Foundation's printer is not required of Kotlin; a
                // stable decode-encode-decode is.
                ("reencodesByteExact", .bool(reencoded == data)),
                ("roundTripsByValue", .bool(try VaultFile.decode(reencoded) == document)),
                ("recordsWithDistantPastDates", .n(document.records.filter { $0.createdAt == .distantPast || $0.updatedAt == .distantPast }.count)),
                ("recordsWithForeignHLC", .n(document.records.filter { $0.hlc.device == HLC.foreignDevice }.count)),
            ]
            if options.values["key"] != nil || options.flags.contains("verbose") {
                guard let salt = document.vaultSaltBytes else { throw InteropFailure("vaultSalt is not base64url") }
                let keyring = SnippetCrypto.Keyring(
                    libraryKey: SymmetricKey(data: try options.data("key", default: Fixture.libraryKey)), salt: salt)
                var opened = 0, hashMismatches = 0
                for record in document.records {
                    let plaintext = try SnippetCrypto.open(
                        record.sealed, for: SnippetCrypto.RecordContext(scopeID: document.kid, recordID: record.id),
                        keyring: keyring)
                    opened += 1
                    if SnippetCrypto.contentHash(of: plaintext, keyring: keyring) != record.contentHash { hashMismatches += 1 }
                }
                members += [("recordsOpened", .n(opened)), ("contentHashMismatches", .n(hashMismatches))]
                guard hashMismatches == 0 else { throw InteropFailure("\(hashMismatches) record(s) carry a wrong contentHash") }
            }
            if let code = options.values["code"], let wrap = document.wrapRecovery, let salt = document.vaultSaltBytes {
                let key = try KeyWrap.unwrap(
                    wrap, under: try RecoveryKey.decode(code), purpose: .recovery, kid: document.kid, salt: salt)
                members.append(("recoveredVaultKeySHA256", .str(sha256Hex(key.raw))))
            }
            return members

        case "backup":
            let opened = try EncryptedSnippetBackup.open(data, passphrase: options.values["password"] ?? "Café public backup fixture")
            let records = opened.vault?.records ?? []
            return [
                ("ordinaryCount", .n(opened.ordinaryCount)),
                ("secureCount", .n(opened.secureCount)),
                ("ordinaryIDs", .strings(opened.snippets.map { lower($0.id) })),
                ("secureIDs", .strings(records.map { lower($0.id) })),
                ("vaultKID", .opt(opened.vault?.kid)),
                ("vaultKeySHA256", .opt(opened.vaultKey.map { sha256Hex($0.raw) })),
                ("librarySummarySHA256", .str(sha256Hex(try librarySummary(opened.snippets)))),
                // Hazard H2: a vault record whose dates were written as ISO strings
                // reads back as Date.distantPast without any error.
                ("vaultRecordsWithDistantPastDates", .n(records.filter { $0.createdAt == .distantPast || $0.updatedAt == .distantPast }.count)),
            ]

        case "git-recovery":
            let datasetID = try options.uuid("dataset", default: Fixture.datasetID)
            let kit: GitSyncRecovery.Kit
            if let code = options.values["code"] {
                kit = try GitSyncRecovery.Kit(code: code, datasetID: datasetID)
            } else {
                kit = GitSyncRecovery.Kit(datasetID: datasetID, secret: try options.data("secret", default: Fixture.recoverySecret))
            }
            let material = try GitSyncRecovery.open(data, kit: kit)
            var members: [(String, J)] = [
                ("datasetID", .str(lower(datasetID))),
                ("materialByteCount", .n(material.count)),
                ("materialSHA256", .str(sha256Hex(material))),
                ("gitBlobID", .str(GitVectors.blobID(data))),
            ]
            if options.values["expect-material"] != nil {
                let expected = try options.data("expect-material", default: Data())
                members.append(("materialMatchesExpected", .bool(expected == material)))
                guard expected == material else { throw InteropFailure("recovered material differs from --expect-material") }
            }
            return members

        case "git-vault":
            let datasetID = try options.uuid("dataset", default: Fixture.datasetID)
            let material = try options.data("material", default: Fixture.syncMaterial)
            let identity = try GitSyncVault.open(data, material: material, datasetID: datasetID)
            var members: [(String, J)] = [
                ("datasetID", .str(lower(datasetID))),
                ("kid", .str(identity.kid)),
                ("vaultSalt", .str(identity.vaultSalt)),
                ("kdf", .obj([("alg", .str(identity.kdf.alg)), ("iterations", .n(identity.kdf.iterations)), ("saltP", .str(identity.kdf.saltP))])),
                ("wrapRecoveryCharacterCount", .n(identity.wrapRecovery.utf8.count)),
                ("gitBlobID", .str(GitVectors.blobID(data))),
            ]
            if let code = options.values["code"], let salt = identity.vaultSaltBytes {
                let key = try KeyWrap.unwrap(
                    identity.wrapRecovery, under: try RecoveryKey.decode(code), purpose: .recovery,
                    kid: identity.kid, salt: salt)
                members.append(("recoveredVaultKeySHA256", .str(sha256Hex(key.raw))))
            }
            return members

        case "git-manifest":
            let manifest = try GitSyncManifest.decode(data)
            return [
                ("datasetID", .str(lower(manifest.datasetID))),
                ("recordProfile", .str(manifest.mode.rawValue)),
                ("schemaVersion", .n(manifest.schemaVersion)),
                ("fileIsByteExact", .bool(try manifest.encoded() == data)),
                ("gitBlobID", .str(GitVectors.blobID(data))),
            ]

        case "git-markdown":
            let path = options.values["path"] ?? "snippets/\((file as NSString).lastPathComponent)"
            let assigned = try options.values["assign"].map { text -> UUID in
                guard let id = UUID(uuidString: text) else { throw InteropFailure("--assign is not a UUID") }
                return id
            }
            let (envelope, edited) = try GitPlainSnippetFile.read(data, path: path, assigning: assigned)
            let blobID = GitObjectID.hash(type: .blob, content: data)
            return [
                ("path", .str(path)),
                ("id", .str(lower(envelope.id))),
                ("declaredID", .str(lower(GitPlainSnippetFile.declaredID(data, path: path)))),
                ("edited", .bool(edited)),
                ("hasFrontMatter", .bool(GitPlainSnippetFile.hasFrontMatter(data))),
                ("envelopeHash", .str(try envelope.envelopeHash())),
                ("envelope", utf8Text(try envelope.canonicalData())),
                ("expectedFileName", .str(GitPlainSnippetFile.fileName(name: envelope.fields?.name ?? "", id: envelope.id))),
                ("fileIsByteExact", .bool((try? GitPlainSnippetFile.render(envelope)) == data)),
                ("recordVersion", utf8Text(GitSyncTransport.markdownVersion(blobID).data)),
            ]

        case "library-json":
            let snippets = try SnippetLibraryCodec.decode(data)
            let summary = try librarySummary(snippets)
            var seen = Set<UUID>()
            let duplicateIDs = snippets.filter { !seen.insert($0.id).inserted }.count
            var members: [(String, J)] = [
                ("count", .n(snippets.count)),
                ("fileDigest", .str(SnippetLibraryCodec.digest(of: data))),
                ("summarySHA256", .str(sha256Hex(summary))),
                ("duplicateIDs", .n(duplicateIDs)),
                ("reencodesByteExact", .bool(
                    (try? SnippetLibraryCodec.encode(snippets)) == data
                        || (try? SnippetLibraryCodec.encodeCollection(snippets)) == data)),
                ("displayOrderIDs", .strings(SnippetDisplayOrder.sorted(snippets).map { lower($0.id) })),
            ]
            if options.flags.contains("verbose") {
                members.append(("summary", utf8Text(summary)))
            }
            return members

        default:
            throw InteropFailure("unknown kind \(kind)")
        }
    }

    /// Returns the process exit status.
    static func main(_ arguments: [String]) -> Int32 {
        guard let kind = arguments.first, kinds.contains(where: { $0.0 == kind }) else {
            FileHandle.standardError.write(Data(
                ("usage: swift-interop check <kind> [options] <file…>\nkinds:\n"
                    + kinds.map { "  \($0.0)\t\($0.1)" }.joined(separator: "\n") + "\n").utf8))
            return 2
        }
        let options: Options
        do { options = try parse(Array(arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("swift-interop: \(error)\n".utf8))
            return 2
        }
        guard !options.files.isEmpty else {
            FileHandle.standardError.write(Data("swift-interop: check \(kind) needs at least one file\n".utf8))
            return 2
        }
        var status: Int32 = 0
        for file in options.files {
            var members: [(String, J)] = [("kind", .str(kind)), ("file", .str(file))]
            do {
                let data = file == "-"
                    ? FileHandle.standardInput.readDataToEndOfFile()
                    : try Data(contentsOf: URL(fileURLWithPath: file))
                let result = try run(kind: kind, options: options, file: file, data: data)
                members.append(("ok", .bool(true)))
                members += result
            } catch {
                status = 1
                members.append(("ok", .bool(false)))
                members.append(("error", .str(errorName(error))))
                if let failure = error as? InteropFailure {
                    members.append(("detail", .str(failure.description)))
                } else if errorName(error) == "NSError" {
                    let underlying = error as NSError
                    members.append(("detail", .str("\(underlying.domain) \(underlying.code)")))
                }
            }
            print(J.obj(members).compact())
        }
        return status
    }
}
