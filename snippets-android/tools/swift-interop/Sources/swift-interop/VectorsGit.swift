import CryptoKit
import Foundation
@testable import SnippetsCore

// G1–G3, G5–G7: manifest, README, record file, repository locations, identities,
// plain-text Markdown. G4 (objects of a real repository) is in VectorsGitLive.swift.

enum GitVectors {

    static func blobID(_ data: Data) -> String { GitObjectID.hash(type: .blob, content: data).hex }

    // MARK: G1

    static func g1() throws -> VectorFile {
        var cases: [J] = []
        for mode in GitLibraryMode.allCases {
            for schemaVersion in [GitSyncManifest.currentSchemaVersion, GitSyncManifest.rotatedSchemaVersion] {
                let manifest = GitSyncManifest(datasetID: Fixture.datasetID, mode: mode, schemaVersion: schemaVersion)
                let data = try manifest.encoded()
                try require(try GitSyncManifest.decode(data) == manifest, "G1 round trip")
                cases.append(vcase("encode-\(mode == .encrypted ? "encrypted" : "plain")-schema-\(schemaVersion)", [
                    ("kind", .str("encode")),
                    ("datasetID", .str(lower(Fixture.datasetID))),
                    ("mode", .str(mode == .encrypted ? "encrypted" : "plainText")),
                    ("recordProfile", .str(mode.rawValue)),
                    ("schemaVersion", .n(schemaVersion)),
                    ("fileText", utf8Text(data)),
                    ("fileHex", .hex(data)),
                    ("blobID", .str(blobID(data))),
                ]))
            }
        }
        let id = lower(Fixture.datasetID)
        func manifest(
            datasetID: String = id, format: String = "\"snippets-git-sync\"",
            profile: String = "\"snippets-wire-v1\"", version: String = "1", extra: String = ""
        ) -> Data {
            Data("{\"datasetID\":\"\(datasetID)\",\"format\":\(format),\"recordProfile\":\(profile),\(extra)\"schemaVersion\":\(version)}".utf8)
        }
        let decodes: [(String, Data)] = [
            ("compact-ok", manifest()),
            ("plain-profile", manifest(profile: "\"snippets-plain-v1\"")),
            ("schema-2", manifest(version: "2")),
            ("schema-0", manifest(version: "0")),
            ("schema-3", manifest(version: "3")),
            ("schema-as-string", manifest(version: "\"1\"")),
            ("schema-as-double", manifest(version: "1.0")),
            ("schema-fraction", manifest(version: "1.5")),
            ("unknown-profile", manifest(profile: "\"snippets-wire-v2\"")),
            ("profile-not-string", manifest(profile: "1")),
            ("wrong-format-marker", manifest(format: "\"other\"")),
            ("format-not-string", manifest(format: "1")),
            ("format-missing", Data("{\"datasetID\":\"\(id)\",\"recordProfile\":\"snippets-wire-v1\",\"schemaVersion\":1}".utf8)),
            ("extra-key", manifest(extra: "\"note\":\"x\",")),
            ("extra-key-with-wrong-format", manifest(format: "\"other\"", extra: "\"note\":\"x\",")),
            ("missing-dataset", Data("{\"format\":\"snippets-git-sync\",\"recordProfile\":\"snippets-wire-v1\",\"schemaVersion\":1}".utf8)),
            ("dataset-uppercase", manifest(datasetID: Fixture.datasetID.uuidString)),
            ("dataset-not-uuid", manifest(datasetID: "library")),
            ("dataset-braced", manifest(datasetID: "{\(id)}")),
            ("not-json", Data("# not a manifest\n".utf8)),
            ("json-array", Data("[]".utf8)),
            ("empty", Data()),
            ("over-16384-bytes", manifest() + Data(repeating: 0x20, count: 16_384)),
            ("exactly-16384-bytes", manifest() + Data(repeating: 0x20, count: 16_384 - manifest().count)),
            ("with-bom", Data([0xef, 0xbb, 0xbf]) + manifest()),
            ("crlf-pretty", Data("{\r\n  \"datasetID\" : \"\(id)\",\r\n  \"format\" : \"snippets-git-sync\",\r\n  \"recordProfile\" : \"snippets-wire-v1\",\r\n  \"schemaVersion\" : 1\r\n}\r\n".utf8)),
            ("duplicate-key", Data("{\"datasetID\":\"\(id)\",\"format\":\"snippets-git-sync\",\"format\":\"snippets-git-sync\",\"recordProfile\":\"snippets-wire-v1\",\"schemaVersion\":1}".utf8)),
        ]
        for (name, data) in decodes {
            cases.append(vcase("decode-\(name)", [
                ("kind", .str("decode")),
                ("fileText", data.count > 2_000 ? .null : utf8Text(data)),
                ("fileByteCount", .n(data.count)),
                ("fileHex", data.count > 2_000 ? .null : .hex(data)),
            ] + outcome {
                let manifest = try GitSyncManifest.decode(data)
                return .obj([
                    ("datasetID", .str(lower(manifest.datasetID))),
                    ("recordProfile", .str(manifest.mode.rawValue)),
                    ("schemaVersion", .n(manifest.schemaVersion)),
                ])
            }))
        }
        return VectorFile(
            name: "G01-git-manifest",
            pins: "GitSyncManifest.encoded() bytes for schema 1 and 2, encrypted and plain-text, and GitSyncManifest.decode outcomes (brief 03 §2.2)",
            notes: [
                "notALibrary means the branch is foreign data; incompatibleSchema is git_sync_schema_unsupported.",
                "The two over/exactly-16384-byte inputs are the compact-ok bytes followed by spaces; their text is omitted.",
            ],
            cases: cases)
    }

    // MARK: G2

    static func g2() throws -> VectorFile {
        var cases: [J] = []
        for mode in GitLibraryMode.allCases {
            let text = GitSyncLayout.readme(for: mode)
            let data = Data(text.utf8)
            cases.append(vcase(mode == .encrypted ? "encrypted" : "plain", [
                ("mode", .str(mode == .encrypted ? "encrypted" : "plainText")),
                ("recordProfile", .str(mode.rawValue)),
                ("path", .str(GitSyncLayout.readmeName)),
                ("text", .str(text)),
                ("hex", .hex(data)),
                ("byteCount", .n(data.count)),
                ("sha256", .str(sha256Hex(data))),
                ("blobID", .str(blobID(data))),
            ]))
        }
        return VectorFile(
            name: "G02-git-readme",
            pins: "GitSyncLayout.readme(for:) bytes and git blob ids for both library modes (brief 03 §2.3)",
            notes: ["blobID = SHA-1(\"blob \" + decimal byte count + NUL + bytes), the id every platform must produce for README.md."],
            cases: cases)
    }

    // MARK: G3

    static func g3() throws -> VectorFile {
        var cases: [J] = []
        var nonceByte: UInt8 = 0xb0
        for (name, envelope) in try CryptoVectorsB.envelopes() {
            // The same nonces as V12, so the blobs are the V12 blobs.
            let sealer = SnippetCryptoSealer(
                keyring: Fixture.syncKeyring, scopeID: Fixture.syncScope, nonces: fixedNonce(nonceByte))
            nonceByte &+= 1
            let record = try WireCodec.seal(envelope, using: sealer)
            let data = try GitRecordFile.encode(record)
            let blob = GitObjectID.hash(type: .blob, content: data)
            let path = GitSyncLayout.recordPath(record.id)
            let decoded = try GitRecordFile.decode(data, id: record.id, version: GitSyncTransport.recordVersion(blob))
            try require(
                decoded.id == record.id && decoded.rev == record.rev && decoded.deleted == record.deleted
                    && decoded.blob == record.blob, "G3 \(name) round trip")
            cases.append(vcase("encode-\(name)", [
                ("kind", .str("encode")),
                ("wire", .obj([
                    ("id", .str(lower(record.id))),
                    ("rev", .str(record.rev)),
                    ("deleted", .bool(record.deleted)),
                    ("blobText", utf8Text(record.blob)),
                    ("blobBase64", .str(record.blob.base64EncodedString())),
                ])),
                ("path", .str("\(GitSyncLayout.recordsName)/\(path.prefix)/\(path.name)")),
                ("fileText", utf8Text(data)),
                ("fileHex", .hex(data)),
                ("gitBlobID", .str(blob.hex)),
                ("recordVersionText", utf8Text(GitSyncTransport.recordVersion(blob).data)),
                ("markdownVersionText", utf8Text(GitSyncTransport.markdownVersion(blob).data)),
            ]))
        }
        // `rev` is the only member that can need JSON escaping.
        for (name, rev) in [
            ("rev-with-slash-and-quote", "a/b\"c\\d"), ("rev-non-ascii", "révision-🔑"),
            ("rev-control", "a\u{1}b\tc"), ("rev-256-bytes", String(repeating: "r", count: 256)),
        ] {
            let record = WireRecord(id: Fixture.uuidC, rev: rev, deleted: false, blob: Data([0xfb, 0xff, 0xfe, 0x00]))
            let data = try GitRecordFile.encode(record)
            cases.append(vcase("encode-\(name)", [
                ("kind", .str("encode")),
                ("wire", .obj([
                    ("id", .str(lower(record.id))), ("rev", .text(rev)), ("deleted", .bool(false)),
                    ("blobBase64", .str(record.blob.base64EncodedString())),
                ])),
                ("fileText", utf8Text(data)),
                ("fileHex", .hex(data)),
                ("gitBlobID", .str(blobID(data))),
            ] + outcome {
                .str(try GitRecordFile.decode(data, id: record.id, version: SyncRecordVersion(Data())).rev)
            }.map { ($0.0 == "ok" ? "decodedRev" : "decodeError", $0.1) }))
        }

        for id in [Fixture.uuidA, Fixture.uuidB, Fixture.uuidC, Fixture.uuidD,
                   UUID(uuidString: "0A000000-0000-4000-8000-000000000000")!,
                   UUID(uuidString: "FE000000-0000-4000-8000-000000000000")!] {
            let path = GitSyncLayout.recordPath(id)
            cases.append(vcase("path-\(lower(id).prefix(8))", [
                ("kind", .str("path")),
                ("id", .str(lower(id))),
                ("fanout", .str(path.prefix)),
                ("fileName", .str(path.name)),
                ("path", .str("records/\(path.prefix)/\(path.name)")),
            ]))
        }
        for name in ["a0", "00", "ff", "A0", "a", "a00", "g0", "0g", "", "..", "a\u{e9}", "\u{FF10}0", "0 ", "FF"] {
            cases.append(vcase("fanout-\(Data(name.utf8).hex.isEmpty ? "empty" : Data(name.utf8).hex)", [
                ("kind", .str("isFanoutName")),
                ("input", .text(name)),
                ("isFanoutName", .bool(GitSyncLayout.isFanoutName(name))),
            ]))
        }
        let b = lower(Fixture.uuidB)
        let names: [(String, String)] = [
            ("\(b).json", "a0"), ("\(b).json", "a1"), ("\(b).json", "A0"), ("\(b.uppercased()).json", "a0"),
            ("\(b).JSON", "a0"), ("\(b)", "a0"), ("\(b).json.bak", "a0"), ("\(b).md", "a0"), (".json", "a0"),
            ("\(b.replacingOccurrences(of: "-", with: "")).json", "a0"), ("{\(b)}.json", "a0"), ("\(b) .json", "a0"),
            ("\(lower(Fixture.uuidC)).json", "00"), ("\(lower(Fixture.uuidC)).json", "0"), ("\(lower(Fixture.uuidC)).json", ""),
        ]
        for (index, (fileName, prefix)) in names.enumerated() {
            cases.append(vcase("recordID-\(index)", [
                ("kind", .str("recordID")),
                ("fileName", .str(fileName)),
                ("fanout", .str(prefix)),
                ("recordID", .opt(GitSyncLayout.recordID(fileName: fileName, prefix: prefix).map(lower))),
            ]))
        }

        let blob = Data("v1.AAAAAAAAAAAAAAAA.AAAA".utf8).base64EncodedString()
        func file(blob: String = blob, deleted: String = "false", id: String = b, rev: String = "\"r1\"", extra: String = "") -> Data {
            Data("{\"blob\":\"\(blob)\",\"deleted\":\(deleted),\"id\":\"\(id)\",\(extra)\"rev\":\(rev)}\n".utf8)
        }
        let decodes: [(String, Data)] = [
            ("ok", file()),
            ("ok-without-final-newline", Data(file().dropLast())),
            ("ok-pretty-printed", Data("{\n  \"rev\" : \"r1\",\n  \"id\" : \"\(b)\",\n  \"deleted\" : true,\n  \"blob\" : \"\(blob)\"\n}\n".utf8)),
            ("ok-empty-blob", file(blob: "")),
            ("id-of-another-record", file(id: lower(Fixture.uuidA))),
            ("id-uppercase", file(id: b.uppercased())),
            ("extra-key", file(extra: "\"recordVersion\":\"x\",")),
            ("missing-rev", Data("{\"blob\":\"\(blob)\",\"deleted\":false,\"id\":\"\(b)\"}".utf8)),
            ("rev-empty", file(rev: "\"\"")),
            ("rev-256-bytes", file(rev: "\"\(String(repeating: "r", count: 256))\"")),
            ("rev-257-bytes", file(rev: "\"\(String(repeating: "r", count: 257))\"")),
            ("rev-86-three-byte-characters", file(rev: "\"\(String(repeating: "€", count: 86))\"")),
            ("rev-number", file(rev: "1")),
            ("deleted-as-number", file(deleted: "0")),
            ("deleted-as-string", file(deleted: "\"false\"")),
            ("blob-unpadded", file(blob: "e30")),
            ("blob-overpadded", file(blob: "e30==")),
            ("blob-non-canonical-trailing-bits", file(blob: "e31=")),
            ("blob-base64url-alphabet", file(blob: "-_-_")),
            ("blob-with-space", file(blob: "e 30=")),
            ("blob-with-newline", file(blob: "e30=\\n")),
            ("blob-not-string", file(blob: "x\",\"blob\":1,\"y\":\"")),
            ("not-json", Data("record".utf8)),
            ("json-array", Data("[]".utf8)),
            ("empty", Data()),
        ]
        for (name, data) in decodes {
            cases.append(vcase("decode-\(name)", [
                ("kind", .str("decode")),
                ("expectedID", .str(b)),
                ("fileText", utf8Text(data)),
                ("fileHex", .hex(data)),
            ] + outcome {
                let record = try GitRecordFile.decode(data, id: Fixture.uuidB, version: GitSyncTransport.recordVersion(GitObjectID.hash(type: .blob, content: data)))
                return .obj([
                    ("rev", .str(record.rev)), ("deleted", .bool(record.deleted)),
                    ("blobHex", .hex(record.blob)),
                    ("recordVersionText", utf8Text(record.recordVersion?.data ?? Data())),
                ])
            }))
        }
        // Foundation's standard-base64 decoder, which the strict readers wrap with a
        // re-encode check.
        for probe in ["e30=", "e31=", "e30", "e3==", "e30==", "e 30=", "", "====", "e30=\n", "e30\u{3d}\u{3d}\u{3d}", "ZQ==", "ZR==", "Zg", "+/+/", "-_-_", "e30=e30="] {
            let decoded = Data(base64Encoded: probe)
            cases.append(vcase("base64-\(Data(probe.utf8).hex.isEmpty ? "empty" : Data(probe.utf8).hex)", [
                ("kind", .str("foundation-base64")),
                ("input", .text(probe)),
                ("decodedHex", decoded.map { .hex($0) } ?? .null),
                ("canonical", .bool(decoded.map { $0.base64EncodedString() == probe } ?? false)),
            ]))
        }
        return VectorFile(
            name: "G03-git-record-file",
            pins: "GitRecordFile.encode bytes (compact, sorted keys, LF) for the V12 wire records, GitSyncLayout.recordPath / isFanoutName / recordID, record version strings, GitRecordFile.decode outcomes (brief 03 §2.4)",
            notes: [
                "The encode-* wire records are V12's (same keys, same nonces).",
                "A blob is accepted only when Foundation decodes it AND re-encoding gives the same text (`canonical`). The foundation-base64 cases show what Foundation alone accepts.",
                "decode limits not exercised: the file is refused above 1 800 000 bytes and the decoded blob above 900 000 bytes.",
            ],
            cases: cases)
    }

    // MARK: G5

    static func locationJ(_ location: GitRepositoryLocation) -> J {
        var members: [(String, J)] = [
            ("isSSH", .bool(location.isSSH)),
            ("spec", .str(location.spec)),
            ("canonicalIdentity", .str(location.canonicalIdentity)),
        ]
        switch location {
        case .https(let url):
            members.insert(("kind", .str("https")), at: 0)
            members.append(("url", .str(url.absoluteString)))
        case .ssh(let ssh):
            members.insert(("kind", .str("ssh")), at: 0)
            members += [
                ("user", .opt(ssh.user)),
                ("host", .str(ssh.host)),
                ("port", ssh.port.map { .n($0) } ?? .null),
                ("path", .str(ssh.path)),
                ("scpStyle", .bool(ssh.scpStyle)),
                ("destination", .str(ssh.destination)),
                ("uploadPackCommand", .str(GitSSHClient.remoteCommand(.uploadPack, location: ssh))),
                ("receivePackCommand", .str(GitSSHClient.remoteCommand(.receivePack, location: ssh))),
            ]
        }
        return .obj(members)
    }

    static func g5() throws -> VectorFile {
        var cases: [J] = []
        let longPath = String(repeating: "a", count: 1_020)
        let inputs: [String] = [
            "https://github.com/Example/Snippets-Library.git",
            "https://GitHub.com/Example/Snippets-Library",
            "HTTPS://GITHUB.COM/Example/Repo.git/",
            "https://github.com/example/repo.git///",
            "https://github.com/example/repo.git/.git",
            "https://github.com/example/repo.GIT",
            "github.com/example/repo",
            "github.com/example/repo.git",
            "  https://github.com/example/repo  ",
            "https://github.com:8443/example/repo.git",
            "https://example.com/a%20b/c.git",
            "https://example.com/caf%C3%A9/r",
            "https://example.com/café/r",
            "https://bücher.example/a/b",
            "https://xn--bcher-kva.example/a/b",
            "https://192.0.2.1/git/repo.git",
            "https://[2001:db8::1]/repo.git",
            "https://gitlab.com/group/sub/group/repo.git",
            "https://github.com/a",
            "https://user@github.com/a/b",
            "https://user:secret@github.com/a/b",
            "https://github.com/a/b?x=1",
            "https://github.com/a/b#frag",
            "https://github.com",
            "https://github.com/",
            "https:///a/b",
            "http://github.com/a/b",
            "http://localhost/repo.git",
            "http://127.0.0.1:8080/repo.git",
            "http://[::1]/repo.git",
            "http://dev.localhost/repo.git",
            "http://localhost.example.com/repo.git",
            "ftp://example.com/a/b",
            "file:///tmp/repo.git",
            "git://github.com/a/b",
            "/tmp/repo.git",
            "./repo.git",
            "repo",
            "",
            "   ",
            "https://git hub.com/a/b",
            "https://github.com/a b",
            "https://github.com/a\tb",
            "https://github.com/a\u{7f}b",
            "git@github.com:Example/Repo.git",
            "github.com:example/repo",
            "git@GitHub.com:Example/Repo.git/",
            "git@github.com:/abs/repo.git",
            "git@github.com:~/repo.git",
            "git@github.com:~user/repo.git",
            "git@github.com:repo",
            "git@github.com:",
            "user.name_x-y@host.example:path/to/repo",
            "a@b@host:repo",
            "ssh://git@github.com/example/repo.git",
            "ssh://git@github.com:2222/example/repo.git",
            "SSH://git@GitHub.com/Example/Repo.git/",
            "git+ssh://git@host.example/path/repo",
            "GIT+SSH://git@host.example/path/repo",
            "ssh://host.example/~user/repo.git",
            "ssh://host.example/~/repo.git",
            "ssh://[::1]:22/repo.git",
            "ssh://git@[2001:db8::1]/repo.git",
            "ssh://git@host.example:0/repo",
            "ssh://git@host.example:65535/repo",
            "ssh://git@host.example:65536/repo",
            "ssh://user:secret@host.example/repo",
            "ssh://host.example",
            "ssh://host.example/",
            "ssh://host.example/a/../b",
            "ssh://host.example/a/./b",
            "ssh://host.example/a%20b/repo",
            "ssh://host.example/a%2Fb/repo",
            "ssh://git@host.example/repo.git?x=1",
            "ssh://git@host.example/repo.git#f",
            "ssh://git@host.example/re'po",
            "ssh://-oProxyCommand=x@host.example/repo",
            "git@host:repo with space",
            "git@host:repo;rm",
            "git@host:re$po",
            "git@host:re`po",
            "git@host:re'po",
            "git@host:re\"po",
            "git@host:re\\po",
            "git@host:a/../b",
            "git@host:..",
            "git@host:a..b",
            "git@host:-repo",
            "-oProxyCommand=x@host:repo",
            "git@-host:repo",
            "git@.host:repo",
            "git@host_name:repo",
            "git@gïthub.com:repo",
            "git@github.com:Ünï/repo",
            "git@github.com:a/b.git?x",
            "git@github.com:\(longPath)/abc",
            "git@github.com:\(longPath)/abcd",
            "C:/Users/me/repo.git",
            "localhost:3000/repo",
            "host:path:with:colons",
            "host/path:with/colon",
            "git@github.com:Example/Repo.git\n",
            "git@github.com:a\nb",
        ]
        for (index, raw) in inputs.enumerated() {
            var members: [(String, J)] = [("kind", .str("parse")), ("input", .text(raw.count > 200 ? String(raw.prefix(40)) + "…(\(raw.utf8.count) bytes, see inputUtf8Hex)" : raw))]
            if raw.count > 200 { members.append(("inputUtf8Hex", .hex(Data(raw.utf8)))) }
            members += outcome { locationJ(try GitRepositoryLocation.parse(raw)) }
            let loopback = outcome { locationJ(try GitRepositoryLocation.parse(raw, allowsInsecureLoopback: true)) }
            members.append(("withInsecureLoopbackAllowed", .obj(loopback)))
            cases.append(vcase("parse-\(index)", members))
        }

        let branches = [
            "main", "snippets", "feature/x", "release/1.0", "a", String(repeating: "b", count: 200),
            String(repeating: "b", count: 201), "", "-main", "/main", "main/", "main.", "main.lock",
            "a..b", "a//b", "HEAD", "head", "refs/heads/main", ".hidden", "a/.hidden", "a/b.", "a.lock/b",
            "has space", "ünï", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a@{b", "@", "a_b-c.d",
            "A/B", "0", "a/b/c/d", "main\n", "a.b", "..", ".", "a/./b", "x.LOCK", "lock",
        ]
        for (index, branch) in branches.enumerated() {
            cases.append(vcase("branch-\(index)", [
                ("kind", .str("isValidBranch")),
                ("branch", .text(branch.count > 60 ? "\(branch.prefix(1))×\(branch.count)" : branch)),
                ("branchByteCount", .n(branch.utf8.count)),
                ("isValid", .bool(GitRemote.isValidBranch(branch))),
                ("refName", GitRemote.isValidBranch(branch) ? .str("refs/heads/\(branch)") : .null),
            ]))
        }
        for (index, (username, token)) in [
            ("tester", "token"), ("", "token"), ("tester", ""), ("user:name", "token"),
            ("tester", "to ken"), ("tester", "to\tken"), ("tester", "tök€n"), ("te\u{7f}ster", "token"),
            (String(repeating: "u", count: 256), "t"), (String(repeating: "u", count: 257), "t"),
            ("u", String(repeating: "t", count: 4_096)), ("u", String(repeating: "t", count: 4_097)),
            ("x-access-token", "ghp_fictionalFixtureToken0000000000000000"), ("tester", "a:b"),
        ].enumerated() {
            cases.append(vcase("credential-\(index)", [
                ("kind", .str("credential")),
                ("usernameByteCount", .n(username.utf8.count)),
                ("tokenByteCount", .n(token.utf8.count)),
                ("username", .text(username.count > 40 ? "\(username.prefix(1))×\(username.count)" : username)),
                ("token", .text(token.count > 60 ? "\(token.prefix(1))×\(token.count)" : token)),
                ("isValidUsername", .bool(GitRemote.isValidUsername(username))),
                ("isValidToken", .bool(GitRemote.isValidToken(token))),
            ]))
        }
        return VectorFile(
            name: "G05-git-location",
            pins: "GitRepositoryLocation.parse, spec, canonicalIdentity, GitSSHClient.remoteCommand, GitRemote.isValidBranch / isValidUsername / isValidToken (brief 03 §2.1, §6.2)",
            notes: [
                "Each parse case is run twice: as the app does (`ok` / `error`) and with allowsInsecureLoopback (the DEBUG loopback test seam).",
                "canonicalIdentity = lowercase host + \"/\" + path without leading slashes, one trailing \".git\" and trailing slashes; no scheme, user or port. It keys every Git identity in G06 and V17.",
                "URL parsing is Foundation's (URLComponents / URL(string:)); percent-encoding, IDN and IPv6 cases record what it does on the OS that ran the emitter.",
            ],
            cases: cases)
    }

    // MARK: G6 (formula part; the transport's own values are in G04)

    static func g6() throws -> VectorFile {
        var cases: [J] = []
        let scopes: [(String, String, String, UUID)] = [
            ("github-main", "github.com/example/snippets-library", "main", Fixture.datasetID),
            ("github-other-branch", "github.com/example/snippets-library", "snippets", Fixture.datasetID),
            ("gitea-nested", "git.example.org/team/sub/library", "release/1.0", Fixture.uuidB),
            ("interop-loopback", "snippets-interop.localhost/repo", "main", Fixture.datasetID),
        ]
        for (name, location, branch, datasetID) in scopes {
            let refName = "refs/heads/\(branch)"
            let account = "snippets-git-account-v1\n\(location)\n\(refName)"
            let dataset = "snippets-git-dataset-v1\n\(location)\n\(refName)\n\(lower(datasetID))"
            let folder = ["snippets.sync.provider.v1", "git", location, refName, lower(datasetID)].joined(separator: "\u{0}")
            let folderKey = String(sha256Hex(Data(folder.utf8)).prefix(32))
            let locations = SyncProtocolLocations.http(opaqueProviderKey: folderKey)
            try require(locations?.identifier == "http-\(folderKey)", "G6 folder key is accepted")
            cases.append(vcase(name, [
                ("kind", .str("identities")),
                ("canonicalIdentity", .str(location)),
                ("branch", .str(branch)),
                ("refName", .str(refName)),
                ("datasetID", .str(lower(datasetID))),
                ("accountIdentityPreimageHex", .hex(Data(account.utf8))),
                ("accountIdentityHex", .str(sha256Hex(Data(account.utf8)))),
                ("cacheScope", .str(sha256Hex(Data(account.utf8)))),
                ("datasetIdentityPreimageHex", .hex(Data(dataset.utf8))),
                ("datasetIdentityHex", .str(sha256Hex(Data(dataset.utf8)))),
                ("keyStoreAccount", .str(GitSyncKeyStore.Scope(location: location, refName: refName, datasetID: datasetID).account)),
                ("syncStateFolderPreimageHex", .hex(Data(folder.utf8))),
                ("syncStateFolderKey", .str(folderKey)),
                ("syncStateFolder", .str("Sync/Providers/\(folderKey)")),
                ("syncProtocolIdentifier", .opt(locations?.identifier)),
            ]))
        }
        let commit = GitObjectID(hex: "0123456789abcdef0123456789abcdef01234567")!
        let cursor = GitSyncCursor(datasetID: Fixture.datasetID, commit: commit).cursor
        cases.append(vcase("cursor-format", [
            ("kind", .str("cursor")),
            ("datasetID", .str(lower(Fixture.datasetID))),
            ("commit", .str(commit.hex)),
            ("cursor", .str(cursor.rawValue)),
            ("recordVersionText", utf8Text(GitSyncTransport.recordVersion(commit).data)),
            ("markdownVersionText", utf8Text(GitSyncTransport.markdownVersion(commit).data)),
        ]))
        let d = lower(Fixture.datasetID)
        for (index, raw) in [
            "git1.\(d).\(commit.hex)", "git1.\(d.uppercased()).\(commit.hex)", "git1.\(d).\(commit.hex.uppercased())",
            "git2.\(d).\(commit.hex)", "GIT1.\(d).\(commit.hex)", "git1.\(d)", "git1.\(d).\(commit.hex).x",
            "git1.\(d).\(commit.hex.dropLast())", "git1..\(commit.hex)", "", "git1.\(d).\(String(repeating: "0", count: 40))",
            " git1.\(d).\(commit.hex)", "git1.\(d).\(commit.hex)\n",
        ].enumerated() {
            let parsed = GitSyncCursor(SyncCursor(raw))
            cases.append(vcase("cursor-parse-\(index)", [
                ("kind", .str("cursor-parse")),
                ("input", .text(raw)),
                ("datasetID", .opt(parsed.map { lower($0.datasetID) })),
                ("commit", .opt(parsed?.commit.hex)),
                ("commitForExpectedDataset", .opt(GitSyncTransport.commit(of: SyncCursor(raw), datasetID: Fixture.datasetID)?.hex)),
            ]))
        }
        return VectorFile(
            name: "G06-git-identities",
            pins: "The identities of brief 03 §2.12: account identity, dataset identity, cache scope, key-store account, local sync-state folder key, cursor and record-version strings",
            notes: [
                "keyStoreAccount, cursor, record versions and SyncProtocolLocations come from the compiled Swift sources.",
                "accountIdentity and datasetIdentity are private members of GitSyncTransport; the formulas here are transcribed from GitSyncTransport.swift (accountDigest, datasetIdentity) and are confirmed against a running transport by G04's `transportScope`, which uses the `interop-loopback` scope.",
                "syncStateFolderKey is transcribed from SyncBackendSelectionStore.gitProtocolLocations (app layer, needs CloudKit, not compiled here): first 16 bytes of SHA-256 over the five strings joined with NUL. It is device-local.",
            ],
            cases: cases)
    }

    // MARK: G7

    static func anyToJ(_ value: Any) -> J {
        switch value {
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .int(number.int64Value)
        case let text as String: return .str(text)
        case let array as [Any]: return .arr(array.map(anyToJ))
        case let dictionary as [String: Any]:
            return .obj(dictionary.keys.sorted().map { ($0, anyToJ(dictionary[$0]!)) })
        default: return .str(String(describing: value))
        }
    }

    /// Runs the repository's own generator (built beside this executable, unmodified).
    static func referenceOutput() throws -> Data {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("git-plain-reference", isDirectory: false),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InteropFailure("git-plain-reference is not built next to swift-interop; run `xcrun swift build`")
        }
        let process = Process()
        process.executableURL = executable
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InteropFailure("git-plain-reference failed") }
        return data
    }

    static var linuxFixturesDirectory: String?
    static var driftReport: [String] = []

    static func g7() throws -> VectorFile {
        let reference = try referenceOutput()
        if let directory = linuxFixturesDirectory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("git-plain-v1.json")
            if let checkedIn = try? Data(contentsOf: url) {
                driftReport.append(checkedIn == reference
                    ? "git-plain-v1.json: current Swift output is byte-identical to the checked-in Linux fixture"
                    : "git-plain-v1.json: DRIFT, current Swift output differs from the checked-in Linux fixture")
            }
        }
        guard let root = try JSONSerialization.jsonObject(with: reference) as? [String: Any] else {
            throw InteropFailure("G7 reference output is not an object")
        }
        var cases: [J] = []
        func group(_ key: String, label: (Int, [String: Any]) -> String) throws {
            guard let entries = root[key] as? [[String: Any]] else { throw InteropFailure("G7 missing \(key)") }
            for (index, entry) in entries.enumerated() {
                // The reference entry is kept whole under `entry`: its own keys include
                // `name`, which a case already uses.
                cases.append(vcase("\(key)-\(label(index, entry))", [("kind", .str(key)), ("entry", anyToJ(entry))]))
            }
        }
        try group("render") { _, entry in entry["label"] as? String ?? "?" }
        try group("read") { _, entry in entry["label"] as? String ?? "?" }
        try group("readAssigned") { index, entry in "\(index)-\(entry["label"] as? String ?? "?")" }
        try group("derivedID") { index, _ in String(index) }
        try group("fileName") { index, _ in String(index) }
        try group("normalizedTags") { index, _ in String(index) }
        for key in ["plainReadme", "encryptedReadme", "plainManifest", "manifestDataset"] {
            cases.append(vcase("constant-\(key)", [("kind", .str("constant")), ("value", anyToJ(root[key] ?? NSNull()))]))
        }

        // Extra cases beyond the reference set.
        let slugNames = [
            "Email signature", "Wi-Fi / VPN (work)", "…", "..hidden", "a.b.c", "C++ & C#", "100% done",
            "Ünïcödé Ñame", "Ærøskøbing", "Łódź", "İstanbul", "ǅemal", "ß", "Ελληνικά", "Привет, мир",
            "日本語", "中文 名称", "한국어", "العربية", "עברית", "हिन्दी", "ไทย", "🔑 key", "👨‍👩‍👧 family",
            "tab\tand\nnewline", "  ", "-", "---", "a-", "-a", "A", "é", "e\u{301}",
            String(repeating: "a", count: 47) + " b", String(repeating: "a", count: 48) + "b",
            String(repeating: "ab-", count: 20), String(repeating: "é", count: 60), "ﬁle", "№ 5", "½ cup",
            "x²", "ａｂｃ", "CON", "name.md", "snippets/escape", "..\\..\\x", "\u{200B}zero\u{200B}width",
        ]
        for (index, name) in slugNames.enumerated() {
            cases.append(vcase("slug-\(index)", [
                ("kind", .str("slug")),
                ("snippetName", .text(name)),
                ("slug", .str(GitPlainSnippetFile.slug(name))),
                ("fileName", .str(GitPlainSnippetFile.fileName(name: name, id: Fixture.uuidB))),
            ]))
        }

        func plain(
            _ id: UUID, name: String, keyword: String = "", content: Data, tags: [String] = [],
            secure: Bool = false, deleted: Bool = false, x: [String: CanonicalJSON.Value] = [:]
        ) -> SyncEnvelope {
            SyncEnvelope(
                id: id, hlc: CryptoVectorsB.hlc, origin: "aabbccdd", secure: secure, deleted: deleted,
                fields: SyncEnvelope.Fields(
                    name: name, keyword: keyword, content: content, tags: tags, isEnabled: true,
                    isPinned: false, createdAt: Fixture.created, updatedAt: Fixture.updated),
                x: x)
        }
        let extras: [(String, SyncEnvelope)] = [
            ("tricky-name-and-tags", plain(
                Fixture.uuidA, name: "Wi-Fi / VPN: \"work\" #1", keyword: "wi fi",
                content: Data("line\n".utf8), tags: ["Ünï Cödé", "tag,with,commas", "[bracket]", "'quoted'", "日本語"])),
            ("name-looks-like-yaml", plain(Fixture.uuidA, name: "- [x] yes: no # not a comment", content: Data("b".utf8))),
            ("name-with-leading-and-trailing-space", plain(Fixture.uuidA, name: "  padded  ", content: Data("b".utf8))),
            ("name-is-separator-line", plain(Fixture.uuidA, name: "---", content: Data("b".utf8))),
            ("body-crlf-without-final-newline", plain(Fixture.uuidA, name: "CRLF", content: Data("a\r\nb".utf8))),
            ("body-only-crlf", plain(Fixture.uuidA, name: "CRLF", content: Data("\r\n".utf8))),
            ("body-three-trailing-newlines", plain(Fixture.uuidA, name: "NL", content: Data("a\n\n\n".utf8))),
            ("body-starts-with-separator-and-keys", plain(Fixture.uuidA, name: "Front", content: Data("---\nname: fake\n---\nreal".utf8))),
            ("body-with-bom", plain(Fixture.uuidA, name: "BOM", content: Data([0xef, 0xbb, 0xbf]) + Data("x".utf8))),
            ("body-with-nul", plain(Fixture.uuidA, name: "NUL", content: Data([0x61, 0x00, 0x62]))),
            ("body-invalid-utf8", plain(Fixture.uuidA, name: "Bad", content: Data([0xff, 0xfe]))),
            ("secure-record", plain(Fixture.uuidB, name: "Secret", content: Data("v1.x.y".utf8), secure: true)),
            ("tombstone", plain(Fixture.uuidA, name: "Gone", content: Data(), deleted: true)),
            ("extension-bag-not-empty", plain(Fixture.uuidA, name: "X", content: Data("b".utf8), x: ["conflictCopy.v1": ["version": 1]])),
            ("tags-with-case-and-diacritic-duplicates", plain(
                Fixture.uuidA, name: "Tags", content: Data("b".utf8), tags: ["Work", "work", "WÖRK", "é", "E"])),
        ]
        for (name, envelope) in extras {
            var members: [(String, J)] = [
                ("kind", .str("render-extra")),
                // An envelope whose body is not UTF-8 has no canonical form at all.
                ("envelope", (try? envelopeJ(envelope)) ?? .obj([
                    ("id", .str(lower(envelope.id))), ("secure", .bool(envelope.secure)),
                    ("deleted", .bool(envelope.deleted)), ("fields", envelope.fields.map(fieldsJ) ?? .null),
                    ("canonicalError", .str("CanonicalJSON.Failure.invalidUTF8")),
                ])),
                ("canRender", .bool(GitPlainSnippetFile.canRender(envelope))),
                ("fileName", .str(GitPlainSnippetFile.fileName(name: envelope.fields?.name ?? "", id: envelope.id))),
            ]
            if let data = try? GitPlainSnippetFile.render(envelope) {
                let path = "snippets/" + GitPlainSnippetFile.fileName(name: envelope.fields?.name ?? "", id: envelope.id)
                let (back, edited) = try GitPlainSnippetFile.read(data, path: path)
                try require(back == envelope && !edited, "G7 \(name) reads back exactly")
                members += [
                    ("markdownText", utf8Text(data)),
                    ("markdownBase64", .str(data.base64EncodedString())),
                    ("gitBlobID", .str(blobID(data))),
                    ("markdownVersionText", utf8Text(GitSyncTransport.markdownVersion(GitObjectID.hash(type: .blob, content: data)).data)),
                ]
            } else {
                members.append(("markdownBase64", .null))
            }
            cases.append(vcase("render-extra-\(name)", members))
        }
        return VectorFile(
            name: "G07-git-plain-text",
            pins: "GitPlainSnippetFile render / read / declaredID / derivedID / fileName, SnippetTagging.normalizedTags, the plain README and manifest (brief 03 §2.6)",
            notes: [
                "The render, read, readAssigned, derivedID, fileName, normalizedTags and constant-* cases are the output of the repository's own generator, snippets-linux/tests/reference/git-plain-vectors.swift, compiled unmodified against the current Swift sources and run by this tool. Each case's `entry` is one entry of snippets-linux/tests/fixtures/git-plain-v1.json, unchanged (the case name is its group and label): `file`, `markdown` and `normalized` are base64, `envelope` and `tombstone` canonical envelope JSON, null where Swift refuses.",
                "slug-* and render-extra-* are additional cases from this tool.",
                "slug uses ICU transforms (toLatin, stripDiacritics) on Apple platforms; Linux does not transliterate. The path is cosmetic: identity never depends on it.",
            ],
            cases: cases)
    }
}
