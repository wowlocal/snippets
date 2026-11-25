import CryptoKit
import Foundation
@testable import SnippetsCore

// V1–V9: record AAD, key derivation, record sealing, padding, content hash,
// PBKDF2, passphrase wrap, key wrap, recovery-key text.

enum CryptoVectorsA {

    // MARK: V1

    static func v1() throws -> VectorFile {
        let contexts: [(String, String, UUID, Bool)] = [
            ("vault-live", Fixture.kid, Fixture.uuidA, false),
            ("vault-deleted", Fixture.kid, Fixture.uuidA, true),
            ("wire-live", Fixture.syncScope, Fixture.uuidA, false),
            ("wire-deleted", Fixture.syncScope, Fixture.uuidA, true),
            ("wire-live-other-id", Fixture.syncScope, Fixture.uuidB, false),
            ("empty-scope", "", Fixture.uuidC, false),
            ("non-ascii-scope", "k-café-🔑", Fixture.uuidD, true),
        ]
        var cases = contexts.map { name, scope, id, deleted in
            vcase(name, [
                ("scopeID", .text(scope)),
                ("recordID", .str(lower(id))),
                ("isDeleted", .bool(deleted)),
                ("aadHex", .hex(SnippetCrypto.additionalData(for: SnippetCrypto.RecordContext(
                    scopeID: scope, recordID: id, isDeleted: deleted)))),
            ])
        }
        let lists: [(String, String, [Data])] = [
            ("domainSeparated-no-fields", "d", []),
            ("domainSeparated-empty-field", "snip.test", [Data()]),
            ("domainSeparated-ab-vs-a-b-1", "snip.test", [Data("ab".utf8), Data("c".utf8)]),
            ("domainSeparated-ab-vs-a-b-2", "snip.test", [Data("a".utf8), Data("bc".utf8)]),
            ("domainSeparated-300-byte-field", "snip.test", [Data.counting(from: 0, 300)]),
        ]
        cases += lists.map { name, domain, fields in
            vcase(name, [
                ("domain", .str(domain)),
                ("fieldsHex", .arr(fields.map { .hex($0) })),
                ("outputHex", .hex(SnippetCrypto.domainSeparated(domain, fields))),
            ])
        }
        return VectorFile(
            name: "V01-record-aad",
            pins: "SnippetCrypto.additionalData(for:) and SnippetCrypto.domainSeparated (brief 02 §2.1, §2.3)",
            cases: cases)
    }

    // MARK: V2

    static func v2() throws -> VectorFile {
        let keyrings: [(String, Data, Data)] = [
            ("vault", Fixture.libraryKey, Fixture.vaultSalt),
            ("sync", Data.filled(0x99, 32), Data.filled(0xaa, 32)),
            ("counting", Data.counting(from: 0x80, 32), Data.counting(from: 0x40, 32)),
            ("salt-16-bytes", Data.filled(0x11, 32), Data.filled(0x22, 16)),
        ]
        var cases: [J] = []
        for (name, key, salt) in keyrings {
            let keyring = SnippetCrypto.Keyring(libraryKey: SymmetricKey(data: key), salt: salt)
            for id in [Fixture.uuidA, Fixture.uuidB, Fixture.uuidC, Fixture.uuidD] {
                var info = Data(SnippetCrypto.recordKeyInfoPrefix.utf8)
                info.append(SnippetCrypto.uuidBytes(id))
                cases.append(vcase("recordKey-\(name)-\(lower(id).prefix(8))", [
                    ("kind", .str("recordKey")),
                    ("rootKeyHex", .hex(key)),
                    ("saltHex", .hex(salt)),
                    ("recordID", .str(lower(id))),
                    ("uuid16Hex", .hex(SnippetCrypto.uuidBytes(id))),
                    ("hkdfInfoHex", .hex(info)),
                    ("keyHex", .hex(keyring.recordKey(for: id).raw)),
                ]))
            }
            cases.append(vcase("contentHashKey-\(name)", [
                ("kind", .str("contentHashKey")),
                ("rootKeyHex", .hex(key)),
                ("saltHex", .hex(salt)),
                ("hkdfInfoHex", .hex(Data(SnippetCrypto.contentHashInfo.utf8))),
                ("keyHex", .hex(keyring.contentHashKey.raw)),
            ]))
        }
        return VectorFile(
            name: "V02-record-keys",
            pins: "Keyring.recordKey(for:) and Keyring.contentHashKey raw bytes (HKDF-SHA256, brief 02 §1.2)",
            cases: cases)
    }

    // MARK: V3

    static let bodies: [(String, Data)] = [
        ("empty", Data()),
        ("one-byte", Data([0x41])),
        ("255-bytes", Data.counting(from: 1, 255)),
        ("256-bytes", Data.counting(from: 1, 256)),
        ("257-bytes", Data.counting(from: 1, 257)),
        ("511-bytes", Data.counting(from: 7, 511)),
        ("512-bytes", Data.counting(from: 7, 512)),
        ("utf8-multibyte", Data("Café ☕ naïve 日本語 🔑 e\u{301}".utf8)),
        ("ends-in-0x80", Data([0x01, 0x02, 0x80])),
        ("ends-in-zeros", Data([0x80, 0x00, 0x00])),
        ("not-utf8", Data([0xff, 0xfe, 0x00, 0xc3])),
    ]

    static func v3() throws -> VectorFile {
        var cases: [J] = []
        var nonceByte: UInt8 = 0x40
        func add(_ label: String, scope: String, keyring: SnippetCrypto.Keyring,
                 rootHex: Data, saltHex: Data, id: UUID, deleted: Bool, body: Data) throws {
            let nonce = Data.filled(nonceByte, 12)
            nonceByte &+= 1
            let context = SnippetCrypto.RecordContext(scopeID: scope, recordID: id, isDeleted: deleted)
            let text = try SnippetCrypto.seal(body, for: context, keyring: keyring, nonces: fixedNonce(nonce))
            try require(try SnippetCrypto.open(text, for: context, keyring: keyring) == body, "V3 \(label) reopen")
            cases.append(vcase(label, [
                ("rootKeyHex", .hex(rootHex)),
                ("saltHex", .hex(saltHex)),
                ("scopeID", .str(scope)),
                ("recordID", .str(lower(id))),
                ("isDeleted", .bool(deleted)),
                ("nonceHex", .hex(nonce)),
                ("plaintextHex", .hex(body)),
                ("plaintextByteCount", .n(body.count)),
                ("sealed", .str(text)),
                ("sealedCharacterCount", .n(text.utf8.count)),
            ] + (try envelopeParts(text)).filter { $0.0 == "ciphertextAndTagHex" }))
        }
        for (name, body) in bodies {
            try add("vault-\(name)", scope: Fixture.kid, keyring: Fixture.vaultKeyring,
                    rootHex: Fixture.libraryKey, saltHex: Fixture.vaultSalt,
                    id: Fixture.uuidA, deleted: false, body: body)
        }
        try add("wire-scope-live", scope: Fixture.syncScope, keyring: Fixture.syncKeyring,
                rootHex: Data.filled(0x99, 32), saltHex: Data.filled(0xaa, 32),
                id: Fixture.uuidB, deleted: false, body: Data("{\"k\":1}".utf8))
        try add("wire-scope-deleted", scope: Fixture.syncScope, keyring: Fixture.syncKeyring,
                rootHex: Data.filled(0x99, 32), saltHex: Data.filled(0xaa, 32),
                id: Fixture.uuidB, deleted: true, body: Data("{\"k\":1}".utf8))

        // Failures a reader must reproduce, all against the first sealed case.
        let good = try SnippetCrypto.seal(
            Data("body".utf8), for: SnippetCrypto.RecordContext(scopeID: Fixture.kid, recordID: Fixture.uuidA),
            keyring: Fixture.vaultKeyring, nonces: fixedNonce(0x7e))
        let parts = good.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var flipped = Array(parts[2])
        flipped[0] = flipped[0] == "A" ? "B" : "A"
        let shortBody = SnippetCrypto.base64URL(Data.filled(0, 16))
        let openCases: [(String, String, String, UUID, Bool)] = [
            ("open-ok", good, Fixture.kid, Fixture.uuidA, false),
            ("open-wrong-scope", good, Fixture.syncScope, Fixture.uuidA, false),
            ("open-wrong-id", good, Fixture.kid, Fixture.uuidB, false),
            ("open-wrong-deleted-flag", good, Fixture.kid, Fixture.uuidA, true),
            ("open-tampered-body", "\(parts[0]).\(parts[1]).\(String(flipped))", Fixture.kid, Fixture.uuidA, false),
            ("open-version-v2", "v2.\(parts[1]).\(parts[2])", Fixture.kid, Fixture.uuidA, false),
            ("open-two-fields", "\(parts[0]).\(parts[1])", Fixture.kid, Fixture.uuidA, false),
            ("open-four-fields", good + ".AAAA", Fixture.kid, Fixture.uuidA, false),
            ("open-empty-nonce-field", "v1..\(parts[2])", Fixture.kid, Fixture.uuidA, false),
            ("open-nonce-11-bytes", "v1.\(SnippetCrypto.base64URL(Data.filled(1, 11))).\(parts[2])", Fixture.kid, Fixture.uuidA, false),
            ("open-nonce-with-padding-char", "v1.\(parts[1])=.\(parts[2])", Fixture.kid, Fixture.uuidA, false),
            ("open-body-standard-base64-alphabet", "v1.\(parts[1]).\(parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))+", Fixture.kid, Fixture.uuidA, false),
            ("open-body-16-bytes", "v1.\(parts[1]).\(shortBody)", Fixture.kid, Fixture.uuidA, false),
            ("open-body-one-extra-character", "v1.\(parts[1]).\(parts[2])A", Fixture.kid, Fixture.uuidA, false),
            ("open-body-length-4n+1", "v1.\(parts[1]).\(parts[2].dropLast(2))", Fixture.kid, Fixture.uuidA, false),
            ("open-nonce-length-4n+1", "v1.\(parts[1].dropLast(3)).\(parts[2])", Fixture.kid, Fixture.uuidA, false),
        ]
        for (name, text, scope, id, deleted) in openCases {
            cases.append(vcase(name, [
                ("rootKeyHex", .hex(Fixture.libraryKey)),
                ("saltHex", .hex(Fixture.vaultSalt)),
                ("scopeID", .str(scope)),
                ("recordID", .str(lower(id))),
                ("isDeleted", .bool(deleted)),
                ("sealed", .str(text)),
            ] + outcome {
                .hex(try SnippetCrypto.open(
                    text, for: SnippetCrypto.RecordContext(scopeID: scope, recordID: id, isDeleted: deleted),
                    keyring: Fixture.vaultKeyring))
            }))
        }
        return VectorFile(
            name: "V03-record-seal",
            pins: "SnippetCrypto.seal(_:for:keyring:nonces:) full envelope text for boundary bodies, and open() outcomes (brief 02 §2.2, §2.3)",
            notes: [
                "Seal cases: inject nonceHex, expect the exact `sealed` text. `ok` in open cases is the recovered plaintext hex.",
                "A valid tag over unpadded plaintext cannot be produced through the Swift API, so malformedPadding after authentication is covered by V04's unpad cases only.",
            ],
            cases: cases)
    }

    // MARK: V4

    static func v4() throws -> VectorFile {
        var cases: [J] = []
        for count in [0, 1, 2, 254, 255, 256, 257, 510, 511, 512, 513, 1023, 1024] {
            let body = Data.counting(from: 0x10, count)
            let padded = SnippetCrypto.Padding.pad(body)
            try require(try SnippetCrypto.Padding.unpad(padded) == body, "V4 unpad \(count)")
            cases.append(vcase("pad-\(count)", [
                ("kind", .str("pad")),
                ("inputHex", .hex(body)),
                ("inputByteCount", .n(count)),
                ("paddedByteCount", .n(padded.count)),
                ("paddedHex", .hex(padded)),
            ]))
        }
        for (name, body) in [
            ("pad-body-ending-0x80", Data([0x41, 0x80])),
            ("pad-body-ending-0x80-0x00", Data([0x41, 0x80, 0x00])),
            ("pad-body-all-zero", Data.filled(0, 3)),
        ] {
            let padded = SnippetCrypto.Padding.pad(body)
            try require(try SnippetCrypto.Padding.unpad(padded) == body, "V4 unpad \(name)")
            cases.append(vcase(name, [
                ("kind", .str("pad")),
                ("inputHex", .hex(body)),
                ("inputByteCount", .n(body.count)),
                ("paddedByteCount", .n(padded.count)),
                ("paddedHex", .hex(padded)),
            ]))
        }
        var noMarker = Data.filled(0x41, 256)
        var lastNonZero = Data.filled(0, 256); lastNonZero[255] = 0x01
        var markerThenGarbage = Data.filled(0, 256); markerThenGarbage[0] = 0x80; markerThenGarbage[200] = 0x02
        noMarker[255] = 0x41
        let unpads: [(String, Data)] = [
            ("unpad-empty", Data()),
            ("unpad-255-bytes", Data([0x80]) + Data.filled(0, 254)),
            ("unpad-257-bytes", Data([0x80]) + Data.filled(0, 256)),
            ("unpad-all-zero-block", Data.filled(0, 256)),
            ("unpad-no-marker", noMarker),
            ("unpad-last-byte-0x01", lastNonZero),
            ("unpad-marker-then-nonzero", markerThenGarbage),
            ("unpad-marker-only-block", Data([0x80]) + Data.filled(0, 255)),
            ("unpad-marker-is-last-byte", Data.filled(0x41, 255) + Data([0x80])),
            ("unpad-two-markers", Data([0x41, 0x80, 0x80]) + Data.filled(0, 253)),
        ]
        for (name, padded) in unpads {
            cases.append(vcase(name, [
                ("kind", .str("unpad")),
                ("paddedHex", .hex(padded)),
            ] + outcome { .hex(try SnippetCrypto.Padding.unpad(padded)) }))
        }
        return VectorFile(
            name: "V04-padding",
            pins: "SnippetCrypto.Padding.pad / unpad (ISO/IEC 7816-4, block 256; brief 02 §2.2)",
            cases: cases)
    }

    // MARK: V5

    static func v5() throws -> VectorFile {
        var cases: [J] = []
        for (name, body) in bodies {
            cases.append(vcase("vault-\(name)", [
                ("rootKeyHex", .hex(Fixture.libraryKey)),
                ("saltHex", .hex(Fixture.vaultSalt)),
                ("contentHashKeyHex", .hex(Fixture.vaultKeyring.contentHashKey.raw)),
                ("plaintextHex", .hex(body)),
                ("contentHash", .str(SnippetCrypto.contentHash(of: body, keyring: Fixture.vaultKeyring))),
            ]))
        }
        let other = SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data.counting(from: 0x80, 32)), salt: Data.counting(from: 0x40, 32))
        cases.append(vcase("counting-keyring", [
            ("rootKeyHex", .hex(Data.counting(from: 0x80, 32))),
            ("saltHex", .hex(Data.counting(from: 0x40, 32))),
            ("contentHashKeyHex", .hex(other.contentHashKey.raw)),
            ("plaintextHex", .hex(Data("hunter2".utf8))),
            ("contentHash", .str(SnippetCrypto.contentHash(of: Data("hunter2".utf8), keyring: other))),
        ]))
        return VectorFile(
            name: "V05-content-hash",
            pins: "SnippetCrypto.contentHash(of:keyring:): hex(HMAC-SHA256(K_hash, body)[0..<16]) (brief 02 §2.4)",
            cases: cases)
    }

    // MARK: V6

    static let passphrases: [(String, String)] = [
        ("ascii", "correct horse battery staple"),
        ("cafe-nfc", "Caf\u{e9} public fixture"),
        ("cafe-nfd", "Cafe\u{301} public fixture"),
        ("non-bmp", "pässwörd 🔑 𝒳𝓎𝓏"),
        ("angstrom-sign", "\u{212B}ngstr\u{f6}m"),
        ("hangul-jamo", "\u{1112}\u{1161}\u{11AB}"),
        ("compatibility-ligature", "o\u{FB03}ce"),
        ("single-space", " "),
    ]

    static func v6() throws -> VectorFile {
        var cases: [J] = []
        let salt = Data.filled(0x55, 16)
        for (name, passphrase) in passphrases {
            let nfc = passphrase.precomposedStringWithCanonicalMapping
            for iterations in [1, 2, 4096] {
                let key = try PassphraseKDF.derive(passphrase: passphrase, salt: salt, iterations: iterations)
                cases.append(vcase("\(name)-\(iterations)", [
                    ("passphrase", .text(passphrase)),
                    ("passwordBytesHex", .hex(Data(nfc.utf8))),
                    ("saltHex", .hex(salt)),
                    ("iterations", .n(iterations)),
                    ("derivedKeyHex", .hex(key.raw)),
                ]))
            }
        }
        for (name, passphrase) in passphrases.prefix(4) {
            let key = try PassphraseKDF.derive(
                passphrase: passphrase, salt: salt, iterations: PassphraseKDF.iterations)
            cases.append(vcase("\(name)-600000", [
                ("passphrase", .text(passphrase)),
                ("passwordBytesHex", .hex(Data(passphrase.precomposedStringWithCanonicalMapping.utf8))),
                ("saltHex", .hex(salt)),
                ("iterations", .n(PassphraseKDF.iterations)),
                ("derivedKeyHex", .hex(key.raw)),
            ]))
        }
        let long = String(repeating: "long passphrase over one SHA-512 block ", count: 5)
        for saltCase in [("salt-1-byte", Data([0x01])), ("salt-64-bytes", Data.counting(from: 0, 64))] {
            let key = try PassphraseKDF.derive(passphrase: long, salt: saltCase.1, iterations: 3)
            cases.append(vcase("long-passphrase-\(saltCase.0)", [
                ("passphrase", .text(long)),
                ("passwordBytesHex", .hex(Data(long.utf8))),
                ("saltHex", .hex(saltCase.1)),
                ("iterations", .n(3)),
                ("derivedKeyHex", .hex(key.raw)),
            ]))
        }
        let failures: [(String, String, Data, Int)] = [
            ("fail-empty-passphrase", "", salt, 1),
            ("fail-empty-salt", "x", Data(), 1),
            ("fail-zero-iterations", "x", salt, 0),
            ("fail-negative-iterations", "x", salt, -1),
            ("fail-above-ceiling", "x", salt, PassphraseKDF.maximumIterations + 1),
        ]
        for (name, passphrase, salt, iterations) in failures {
            cases.append(vcase(name, [
                ("passphrase", .text(passphrase)),
                ("saltHex", .hex(salt)),
                ("iterations", .n(iterations)),
            ] + outcome { .hex(try PassphraseKDF.derive(passphrase: passphrase, salt: salt, iterations: iterations).raw) }))
        }
        return VectorFile(
            name: "V06-pbkdf2",
            pins: "PassphraseKDF.derive: PBKDF2-HMAC-SHA512 over UTF-8(NFC(passphrase)), dkLen 32 (brief 02 §2.6, hazard H15)",
            notes: [
                "passwordBytesHex is what Swift feeds to PBKDF2 (after precomposedStringWithCanonicalMapping); cafe-nfc and cafe-nfd must therefore derive the same key.",
                "The ceiling itself (20 000 000 iterations) is accepted; it is not exercised because it takes several seconds.",
            ],
            cases: cases)
    }

    // MARK: V7

    static func v7() throws -> VectorFile {
        var cases: [J] = []
        let key = SymmetricKey(data: Data.filled(0x88, 32))
        let salt = Data.filled(0x55, 16)
        let wraps: [(String, String, String, Int, UInt8)] = [
            ("low-iterations", "correct horse battery staple", Fixture.kid, 2, 0x31),
            ("nfd-passphrase-low-iterations", "Cafe\u{301} public fixture", Fixture.kid, 2, 0x32),
            ("backup-kid-low-iterations", Fixture.passphrase, "b-617a0001-0000-4000-8000-0000000000aa", 2, 0x33),
            ("pinned-600000", Fixture.passphrase, Fixture.kid, PassphraseKDF.iterations, 0x34),
        ]
        var firstWrapped: PassphraseKDF.WrappedKey?
        for (name, passphrase, kid, iterations, nonceByte) in wraps {
            let wrapped = try PassphraseKDF.wrap(
                key, passphrase: passphrase, salt: salt, kid: kid, iterations: iterations,
                nonces: fixedNonce(nonceByte))
            try require(try PassphraseKDF.unwrap(wrapped, passphrase: passphrase, kid: kid).raw == key.raw, "V7 \(name)")
            if firstWrapped == nil { firstWrapped = wrapped }
            cases.append(vcase(name, [
                ("keyHex", .hex(key.raw)),
                ("passphrase", .text(passphrase)),
                ("saltHex", .hex(salt)),
                ("kid", .str(kid)),
                ("iterations", .n(iterations)),
                ("nonceHex", .hex(Data.filled(nonceByte, 12))),
                ("wrappingKeyHex", .hex(try PassphraseKDF.derive(passphrase: passphrase, salt: salt, iterations: iterations).raw)),
                ("aadHex", .hex(PassphraseKDF.additionalData(
                    alg: PassphraseKDF.algorithm, iterations: iterations, salt: salt, kid: kid))),
                ("wrappedKey", .obj([
                    ("alg", .str(wrapped.alg)),
                    ("iterations", .n(wrapped.iterations)),
                    ("salt", .str(wrapped.salt)),
                    ("envelope", .str(wrapped.envelope)),
                ])),
            ]))
        }
        let base = firstWrapped!
        var wrongAlg = base; wrongAlg.alg = "argon2id"
        var badSalt = base; badSalt.salt = "not base64url!"
        var emptySalt = base; emptySalt.salt = ""
        var paddedSalt = base; paddedSalt.salt = base.salt + "=="
        var zeroIterations = base; zeroIterations.iterations = 0
        var otherIterations = base; otherIterations.iterations = 3
        var truncated = base; truncated.envelope = String(base.envelope.dropLast(30))
        var twoFields = base; twoFields.envelope = "v1.AAAA"
        let unwraps: [(String, PassphraseKDF.WrappedKey, String, String)] = [
            ("unwrap-ok", base, "correct horse battery staple", Fixture.kid),
            ("unwrap-wrong-passphrase", base, "correct horse battery stapl", Fixture.kid),
            ("unwrap-wrong-kid", base, "correct horse battery staple", "k-other"),
            ("unwrap-empty-passphrase", base, "", Fixture.kid),
            ("unwrap-unknown-alg", wrongAlg, "correct horse battery staple", Fixture.kid),
            ("unwrap-salt-not-base64url", badSalt, "correct horse battery staple", Fixture.kid),
            ("unwrap-empty-salt", emptySalt, "correct horse battery staple", Fixture.kid),
            ("unwrap-salt-with-padding", paddedSalt, "correct horse battery staple", Fixture.kid),
            ("unwrap-zero-iterations", zeroIterations, "correct horse battery staple", Fixture.kid),
            ("unwrap-changed-iterations", otherIterations, "correct horse battery staple", Fixture.kid),
            ("unwrap-truncated-envelope", truncated, "correct horse battery staple", Fixture.kid),
            ("unwrap-malformed-envelope", twoFields, "correct horse battery staple", Fixture.kid),
        ]
        for (name, wrapped, passphrase, kid) in unwraps {
            cases.append(vcase(name, [
                ("wrappedKey", .obj([
                    ("alg", .str(wrapped.alg)),
                    ("iterations", .n(wrapped.iterations)),
                    ("salt", .str(wrapped.salt)),
                    ("envelope", .str(wrapped.envelope)),
                ])),
                ("passphrase", .text(passphrase)),
                ("kid", .str(kid)),
            ] + outcome { .hex(try PassphraseKDF.unwrap(wrapped, passphrase: passphrase, kid: kid).raw) }))
        }
        return VectorFile(
            name: "V07-passphrase-wrap",
            pins: "PassphraseKDF.wrap full WrappedKey with a fixed nonce, its AAD, and unwrap outcomes (brief 02 §2.6)",
            notes: ["`ok` in unwrap cases is the recovered 32-byte key (public fixture 0x88×32)."],
            cases: cases)
    }

    // MARK: V8

    static func v8() throws -> VectorFile {
        var cases: [J] = []
        let libraryKey = SymmetricKey(data: Data.counting(from: 0x80, 32))
        let salt = Data.counting(from: 0x40, 32)
        let kid = "k-0f1e2d3c-4b5"
        let wraps: [(String, KeyWrap.Purpose, Data, Data, UInt8)] = [
            ("recovery-16-byte-material", .recovery, Fixture.recoverySecret, salt, 0x10),
            ("cli-16-byte-material", .cli, Fixture.recoverySecret, salt, 0x10),
            ("cli-32-byte-material", .cli, Data.counting(from: 0xc0, 32), salt, 0x11),
            ("recovery-16-byte-salt", .recovery, Fixture.recoverySecret, Data.filled(0x22, 16), 0x12),
        ]
        var envelopes: [String: String] = [:]
        for (name, purpose, material, salt, nonceStart) in wraps {
            let nonce = Data.counting(from: nonceStart, 12)
            let text = try KeyWrap.wrap(
                libraryKey, under: material, purpose: purpose, kid: kid, salt: salt, nonces: fixedNonce(nonce))
            try require(
                try KeyWrap.unwrap(text, under: material, purpose: purpose, kid: kid, salt: salt).raw == libraryKey.raw,
                "V8 \(name)")
            envelopes[name] = text
            cases.append(vcase(name, [
                ("libraryKeyHex", .hex(libraryKey.raw)),
                ("materialHex", .hex(material)),
                ("purpose", .str(purpose.rawValue)),
                ("kid", .str(kid)),
                ("saltHex", .hex(salt)),
                ("nonceHex", .hex(nonce)),
                ("wrappingKeyHex", .hex(try KeyWrap.wrappingKey(from: material, purpose: purpose, salt: salt).raw)),
                ("aadHex", .hex(KeyWrap.additionalData(purpose: purpose, kid: kid))),
                ("wrapped", .str(text)),
            ]))
        }
        let recovery = envelopes["recovery-16-byte-material"]!
        let cli = envelopes["cli-16-byte-material"]!
        let shortBodyKey = try KeyWrap.wrappingKey(from: Fixture.recoverySecret, purpose: .recovery, salt: salt)
        let wrappedShort = try SnippetCrypto.seal(
            Data.filled(0x01, 31), key: shortBodyKey,
            aad: KeyWrap.additionalData(purpose: .recovery, kid: kid), nonces: fixedNonce(0x13))
        var wrongMaterial = Fixture.recoverySecret; wrongMaterial[0] ^= 1
        let unwraps: [(String, String, Data, KeyWrap.Purpose, String, Data)] = [
            ("unwrap-recovery-ok", recovery, Fixture.recoverySecret, .recovery, kid, salt),
            ("unwrap-cli-ok", cli, Fixture.recoverySecret, .cli, kid, salt),
            ("unwrap-recovery-envelope-as-cli", recovery, Fixture.recoverySecret, .cli, kid, salt),
            ("unwrap-cli-envelope-as-recovery", cli, Fixture.recoverySecret, .recovery, kid, salt),
            ("unwrap-wrong-material", recovery, wrongMaterial, .recovery, kid, salt),
            ("unwrap-wrong-kid", recovery, Fixture.recoverySecret, .recovery, "k-other", salt),
            ("unwrap-wrong-salt", recovery, Fixture.recoverySecret, .recovery, kid, Data.filled(0x41, 32)),
            ("unwrap-material-15-bytes", recovery, Data.filled(0x01, 15), .recovery, kid, salt),
            ("unwrap-empty-salt", recovery, Fixture.recoverySecret, .recovery, kid, Data()),
            ("unwrap-malformed-envelope", "v1.AAAA", Fixture.recoverySecret, .recovery, kid, salt),
            ("unwrap-version-v2", "v2" + recovery.dropFirst(2), Fixture.recoverySecret, .recovery, kid, salt),
            ("unwrap-31-byte-plaintext", wrappedShort, Fixture.recoverySecret, .recovery, kid, salt),
        ]
        for (name, text, material, purpose, kid, salt) in unwraps {
            cases.append(vcase(name, [
                ("wrapped", .str(text)),
                ("materialHex", .hex(material)),
                ("purpose", .str(purpose.rawValue)),
                ("kid", .str(kid)),
                ("saltHex", .hex(salt)),
            ] + outcome { .hex(try KeyWrap.unwrap(text, under: material, purpose: purpose, kid: kid, salt: salt).raw) }))
        }
        return VectorFile(
            name: "V08-key-wrap",
            pins: "KeyWrap.wrap for purposes `recovery` and `cli` with fixed nonces, the wrapping key and AAD, and unwrap outcomes (brief 02 §2.5)",
            notes: [
                "recovery-16-byte-material repeats the literal of Tests/Core/GitSyncVaultTests.knownAnswerMatchesTheLinuxMirror (key 0x80…0x9f, salt 0x40…0x5f, kid k-0f1e2d3c-4b5, nonce 0x10…0x1b).",
                "KeyWrap.Failure.wrongKey carries the purpose as payload; only the case name is recorded.",
            ],
            cases: cases)
    }

    // MARK: V9

    static func v9() throws -> VectorFile {
        var cases: [J] = []
        let patterns: [(String, Data)] = [
            ("zeros", Data.filled(0, 16)),
            ("ones", Data.filled(0xff, 16)),
            ("a0-af", Data.counting(from: 0xa0, 16)),
            ("00-0f", Data.counting(from: 0, 16)),
            ("66x16", Data.filled(0x66, 16)),
            ("alternating", Data((0..<16).map { $0 % 2 == 0 ? 0xaa : 0x55 })),
            ("last-bits-set", Data.filled(0, 15) + Data([0x07])),
            ("first-bit-set", Data([0x80]) + Data.filled(0, 15)),
            ("mixed", Data(hex: "0123456789abcdeffedcba9876543210")!),
        ]
        for (name, bytes) in patterns {
            let canonical = try RecoveryKey.encode(bytes)
            let display = try RecoveryKey.formatted(bytes)
            try require(try RecoveryKey.decode(display) == bytes, "V9 \(name)")
            cases.append(vcase("encode-\(name)", [
                ("kind", .str("encode")),
                ("bytesHex", .hex(bytes)),
                ("canonical", .str(canonical)),
                ("display", .str(display)),
                ("symbols", .arr(RecoveryKey.symbolsFromBytes(bytes).map { .n(Int($0)) })),
                ("checkSymbol", .n(Int(RecoveryKey.checkSymbol(RecoveryKey.symbolsFromBytes(bytes))))),
            ]))
        }
        for count in [0, 15, 17] {
            cases.append(vcase("encode-\(count)-bytes", [
                ("kind", .str("encode")),
                ("bytesHex", .hex(Data.filled(1, count))),
            ] + outcome { .str(try RecoveryKey.encode(Data.filled(1, count))) }))
        }

        let secret = Data.counting(from: 0xa0, 16)
        let canonical = try RecoveryKey.encode(secret)          // M2GT58X4MPKAFA59NANTSBDENWJ
        let display = try RecoveryKey.formatted(secret)
        // A payload whose 26th symbol has a spare bit set, with a matching check symbol.
        var nonCanonicalSymbols = RecoveryKey.symbolsFromBytes(secret)
        nonCanonicalSymbols[25] |= 0x01
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let nonCanonical = String((nonCanonicalSymbols + [RecoveryKey.checkSymbol(nonCanonicalSymbols)])
            .map { alphabet[Int($0)] })
        var wrongCheck = Array(canonical)
        wrongCheck[26] = wrongCheck[26] == "0" ? "1" : "0"
        var swapped = Array(canonical)
        swapped.swapAt(0, 1)
        var oneTypo = Array(canonical)
        oneTypo[5] = oneTypo[5] == "A" ? "B" : "A"
        // A key that contains 0 and 1 so the O/I/L substitutions have something to hit.
        let zeroOne = try RecoveryKey.encode(Data(hex: "08421084210842108421084210842108")!)
        let decodes: [(String, String)] = [
            ("decode-canonical", canonical),
            ("decode-display", display),
            ("decode-lowercase", display.lowercased()),
            ("decode-spaces", canonical.map(String.init).joined(separator: " ")),
            ("decode-tabs-and-line-feeds", "\t" + display.replacingOccurrences(of: "-", with: "\n") + "\n"),
            ("decode-carriage-returns", display.replacingOccurrences(of: "-", with: "\r") + "\r"),
            ("decode-trailing-crlf-is-one-character", display + "\r\n"),
            ("decode-crlf-separators", display.replacingOccurrences(of: "-", with: "\r\n")),
            ("decode-nbsp", display.replacingOccurrences(of: "-", with: "\u{00A0}")),
            ("decode-unicode-hyphen-2010", display.replacingOccurrences(of: "-", with: "\u{2010}")),
            ("decode-non-breaking-hyphen-2011", display.replacingOccurrences(of: "-", with: "\u{2011}")),
            ("decode-figure-dash-2012", display.replacingOccurrences(of: "-", with: "\u{2012}")),
            ("decode-en-dash-2013", display.replacingOccurrences(of: "-", with: "\u{2013}")),
            ("decode-em-dash-2014", display.replacingOccurrences(of: "-", with: "\u{2014}")),
            ("decode-minus-sign-2212", display.replacingOccurrences(of: "-", with: "\u{2212}")),
            ("decode-underscore", display.replacingOccurrences(of: "-", with: "_")),
            ("decode-horizontal-bar-2015-not-stripped", display.replacingOccurrences(of: "-", with: "\u{2015}")),
            ("decode-zero-one-canonical", zeroOne),
            ("decode-O-for-zero", zeroOne.replacingOccurrences(of: "0", with: "O")),
            ("decode-lowercase-o-for-zero", zeroOne.replacingOccurrences(of: "0", with: "o")),
            ("decode-I-for-one", zeroOne.replacingOccurrences(of: "1", with: "I")),
            ("decode-lowercase-l-for-one", zeroOne.replacingOccurrences(of: "1", with: "l")),
            ("decode-dotless-i-for-one", zeroOne.replacingOccurrences(of: "1", with: "\u{0131}")),
            ("decode-dotted-capital-I-for-one", zeroOne.replacingOccurrences(of: "1", with: "\u{0130}")),
            ("decode-empty", ""),
            ("decode-only-separators", " - _ \n"),
            ("decode-26-characters", String(canonical.dropLast())),
            ("decode-28-characters", canonical + "0"),
            ("decode-letter-U", "U" + canonical.dropFirst()),
            ("decode-sharp-s-uppercases-to-two-letters", "ß" + canonical.dropFirst(2)),
            ("decode-fullwidth-digit", "\u{FF10}" + canonical.dropFirst()),
            ("decode-wrong-check-symbol", String(wrongCheck)),
            ("decode-swapped-first-two", String(swapped)),
            ("decode-one-typo", String(oneTypo)),
            ("decode-non-canonical-spare-bits", nonCanonical),
        ]
        for (name, text) in decodes {
            cases.append(vcase(name, [
                ("kind", .str("decode")),
                ("input", .text(text)),
                ("normalized", .str(RecoveryKey.normalized(text))),
            ] + outcome { .hex(try RecoveryKey.decode(text)) }))
        }
        return VectorFile(
            name: "V09-recovery-key",
            pins: "RecoveryKey.encode / formatted / normalized / decode, every failure case (brief 02 §2.8, hazard H16)",
            notes: [
                "a0-af is the literal shared with Linux: M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ.",
                "Swift's String.uppercased() is locale-independent full case mapping: U+0131 becomes I (then 1), ß becomes SS (two characters), U+0130 stays itself.",
                "normalized() walks Swift Characters (grapheme clusters). CR LF is ONE Character, equal to neither \"\\r\" nor \"\\n\", so a code pasted with a Windows line ending is NOT stripped and fails with wrongLength. Lone CR and lone LF are stripped.",
                "Failure payloads (the length, the offending character) are not recorded, only the case.",
            ],
            cases: cases)
    }
}
