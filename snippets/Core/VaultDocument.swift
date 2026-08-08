import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.
//
// Foundation only, and deliberately no CryptoKit: this file is the *format*, not the
// cryptography. `sealed`, the three wrap blobs and `contentHash` are opaque strings
// to everything below. That is what lets `snippets-cli list` enumerate a vault, and
// lets this file's tests run, with no key material in existence anywhere — and it
// keeps the format decisions reviewable without reading the AEAD code.

// MARK: - A lossless JSON value, for the passthrough bags

/// Any JSON value, kept intact so an unknown key can be re-emitted rather than
/// dropped.
///
/// ## Why this type exists at all
///
/// `snippets.json` solves forward compatibility by being frozen at nine keys — see
/// `SnippetLibraryCodec`. The vault cannot use that trick: it is new, it will grow
/// (per-record expiry, attachments, per-record recovery policy are all on the table),
/// and it is written by whichever build the user happens to launch. Debug and release
/// share this directory because the app cannot be sandboxed, and Sparkle rolls an
/// update out over days, so "an older build opens a newer file" is a Tuesday.
///
/// A `Codable` struct silently discards keys it does not know and writes back the
/// stripped version. For the vault that is not a cosmetic loss: the stripped write is
/// the *authoritative* copy the next sync pushes to every other device. So every
/// object in this format carries an `x` bag holding whatever it did not recognise,
/// and re-emits it verbatim.
///
/// **Honest limit.** Numbers round-trip by *value*, not by literal: `1.0` comes back
/// as `1`, and an integer beyond `Int64` degrades to `Double`. Everything else —
/// strings, booleans, null, nesting, key names — survives byte-for-byte, modulo key
/// order, which the encoder sorts anyway.
///
/// ## This is not `CanonicalJSON.Value`, and merging them would break one of them
///
/// The codebase has two JSON models and that is deliberate, so the next reader does not
/// spend an afternoon unifying them:
///
/// - **This one** is `Codable`. It rides on `JSONEncoder`/`JSONDecoder` because it lives
///   inside a document that is otherwise ordinary `Codable`, and its job is *fidelity of
///   unknown keys*, not byte-exactness.
/// - **`CanonicalJSON.Value`** (`SyncEnvelope.swift`) is hand-emitted and hand-parsed
///   because its bytes are hashed and sealed, so they must be identical on every device
///   and every OS version forever. `Encodable` cannot promise that: it will not preserve
///   int-vs-double, it cannot accept pre-encoded UTF-8, and nothing about its output is
///   contractual. It also carries a `.utf8(Data)` case so a secret body never becomes a
///   Swift `String` on the way to the wire — which is the whole point of that layer and
///   is something a `Codable` model cannot express.
///
/// Collapsing them means either giving this type a hand-rolled encoder it does not need,
/// or giving the wire a `Codable` one it cannot use.
nonisolated enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Order matters. `Bool` is tried before the numeric cases because JSON `true`
        // must not become `1`; `Int64` before `Double` because re-emitting `600000` as
        // `600000.0` would be a gratuitous change to somebody else's field.
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }

        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "value is not representable as JSON"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A `CodingKey` that accepts any name, so `allKeys` really does mean all of them.
private nonisolated struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }
}

/// Decode-unknown / re-emit-unknown, shared by the three objects in this format.
private nonisolated enum JSONPassthroughBag {

    static func decode(
        from container: KeyedDecodingContainer<AnyCodingKey>, known: Set<String>
    ) -> [String: JSONValue] {
        var bag: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            // A single unrepresentable value must not fail the whole load. There is no
            // such JSON value today, but a future `Decoder` quirk being able to
            // quarantine somebody's vault is not a trade worth making.
            guard let value = try? container.decode(JSONValue.self, forKey: key) else { continue }
            bag[key.stringValue] = value
        }
        return bag
    }

    static func encode(
        _ bag: [String: JSONValue],
        into container: inout KeyedEncodingContainer<AnyCodingKey>,
        known: Set<String>
    ) throws {
        // Sorted for a deterministic byte stream even if the encoder is ever
        // configured without `.sortedKeys`. Known names are filtered out so a bag
        // entry can never emit a second, shadowing copy of a real field — that would
        // make the file's meaning depend on which duplicate a parser happens to keep.
        for (name, value) in bag.sorted(by: { $0.key < $1.key }) where !known.contains(name) {
            try container.encode(value, forKey: AnyCodingKey(name))
        }
    }
}

// MARK: - The document

/// `Vault/vault.json` — the on-disk form of the secure snippets.
///
/// ## Why secure snippets are a separate file rather than a flag on `Snippet`
///
/// `snippets.json` is frozen at nine keys and every old binary on the machine can
/// write it. Had secure records lived there behind an `isSecure` flag, an older build
/// — which knows nothing of the flag — would read a record whose `content` is
/// `"v1.k-7f3a.…"` and cheerfully **type that ciphertext into whatever window has
/// focus** when the keyword fires. Export and share-link generation would carry it
/// too. Putting the records in a file an older build never opens removes both by
/// construction, which is a much stronger statement than "we remembered to filter".
///
/// ## Shape
///
/// Grouped below for reading; on disk the encoder sorts every key alphabetically and
/// pretty-prints, so the bytes are a pure function of the content. An `x` bag with
/// nothing in it emits no key at all — the two shown here are carrying fields written
/// by a hypothetical newer build.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "kid": "k-7f3a91c0",
///   "vaultSalt": "3Qk5Yy1xQfC0Zr8mHn2pQw",
///   "kdf": {
///     "alg": "pbkdf2-hmac-sha512",
///     "iterations": 600000,
///     "saltP": "Yh8pQm4kL1sTz0Wc7Vb9Ng"
///   },
///   "wrapPass": null,
///   "wrapRecovery": "v1.<nonce>.<ciphertext+tag>",
///   "wrapCLI": null,
///   "teamScope": {"id": "t-1"},
///   "records": [
///     {
///       "id": "6C9F0C6E-1F4B-4E27-9E4B-1D9F2A5B7C31",
///       "name": "AWS root password",
///       "keyword": "awsroot",
///       "tags": ["work", "prod"],
///       "isEnabled": true,
///       "isPinned": false,
///       "createdAt": "2026-07-29T08:00:00.000Z",
///       "updatedAt": "2026-07-29T08:00:00.500Z",
///       "hlc": "019face339f4-0003-aabbccdd",
///       "contentHash": "9d2b7c41f0a3…",
///       "sealed": "v1.<nonce>.<ciphertext+tag>",
///       "expiresAt": "2027-01-01T00:00:00.000Z"
///     }
///   ]
/// }
/// ```
///
/// `teamScope` and `expiresAt` are the passthrough bags at work: this build does not
/// know either key, keeps both, and writes them back. See `JSONValue`.
///
/// ## Threat model
///
/// **Defended.** The sync backend operator, and Apple if the transport is CloudKit,
/// see `sealed` and nothing else. A stolen powered-off Mac, a Time Machine copy of
/// this file, and a Migration Assistant transfer all yield ciphertext, because the
/// library key is never at rest outside the three wrap blobs and the passphrase is
/// never stored at all.
///
/// **Not defended, and worth saying plainly.** Someone sitting at the unlocked Mac
/// while the vault is unlocked. Any process running as the same user — it can drive
/// our own binaries, read our memory, or replace them. Root. And the metadata below.
///
/// ## Metadata is plaintext on purpose
///
/// `name`, `keyword`, `tags`, the two timestamps and `hlc` are **not** encrypted, and
/// this is a design decision rather than an omission:
///
/// - The keystroke matcher must run with the vault **locked** and the app in the
///   background. That is the entire product: you type `\awsroot`, and *that* is what
///   prompts for the passphrase. Encrypting `keyword` would mean no trigger could be
///   detected while locked, so there would be nothing to prompt from — the feature
///   could not exist.
/// - Keyword uniqueness is checked against the whole library, secure records
///   included, and that check happens in the editor with the vault locked.
/// - The list, the search field and the menu bar all render secure rows while locked.
///
/// So the backend operator learns: how many secrets you keep, what you call them,
/// what you tagged them, when each was created and last changed, and roughly how long
/// each one is (`sealed` is not length-padded; padding is the AEAD layer's decision,
/// not this file's). That is a real leak. It is disclosed in the UI at vault creation
/// rather than buried here.
nonisolated struct VaultDocument: Equatable {

    /// Bumped only for a change an older build cannot safely write back. Additive
    /// fields do **not** bump it — that is what the `x` bags are for.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Identifies the library key the sealed blobs are under. A rekey mints a new one,
    /// so a record left over from before a rekey is detectable without trying to
    /// decrypt it and failing.
    var kid: String
    /// **base64url**, unpadded — see `VaultKDFParameters.saltP` for why not standard
    /// base64, and `vaultSaltBytes` for reading it back.
    ///
    /// Domain-separates every key derived from the library key (per-record keys, the
    /// `contentHash` key, both `KeyWrap` wrapping keys), so two vaults that somehow
    /// shared a library key still do not share a single derived key.
    var vaultSalt: String
    /// Parameters for the OPTIONAL passphrase wrap. Present even when `wrapPass` is
    /// nil, so enabling a passphrase later does not have to invent them.
    var kdf: VaultKDFParameters

    // MARK: - Where the library key actually lives
    //
    // The primary home of `K_lib` is the KEYCHAIN, not this file. Nothing here is
    // required to open a vault on the machine that created it: `KeychainSecretStore`
    // holds the key under `kid`; the app gates reads with device-owner authentication
    // and — where the entitlement allows it — iCloud Keychain syncs it to the user's
    // other devices.
    //
    // That is a deliberate trade, and it should be stated rather than implied: the
    // guarantee now rests on Apple's iCloud Keychain rather than on something only the
    // user knows. Someone who compromises the iCloud account AND passes its
    // device-approval step reaches the secrets. In exchange there is no passphrase to
    // forget, no prompt on every new device, and no permanently unrecoverable vault —
    // which for a text expander is the right side of that trade.
    //
    // The wraps below are therefore ESCAPE HATCHES. The format permits all of them to
    // be absent for compatibility, but current vault creation always offers a printable
    // recovery key and commits its wrap only after the user confirms it was saved.

    /// The library key sealed under a key derived from a user passphrase.
    ///
    /// `nil` unless the user explicitly opts in. Kept because a passphrase is the only
    /// way to move a vault to a machine with no iCloud Keychain, and the only thing
    /// that keeps the secrets out of reach of the iCloud account itself.
    var wrapPass: String?
    /// The library key sealed under a printable recovery key.
    ///
    /// The escape hatch for the case the Keychain cannot cover: iCloud Keychain
    /// switched off, a Mac that will not boot, a migration that drops the item. Strongly
    /// recommended at vault creation and offered again if it is ever absent — but not
    /// mandatory, because a key the user threw away should not make the vault refuse to
    /// open on the machine that still has it in the Keychain.
    var wrapRecovery: String?
    /// Reserved format for the library key sealed under a separate 32-byte secret.
    ///
    /// No shipping path creates or consumes it: CLI reveal is deliberately brokered
    /// by the app and requires human approval. It remains in schema 1 because removing
    /// a frozen document key would itself be a format change. Encoded as an explicit
    /// `null` rather than omitted — a value that simply vanishes looks exactly like an
    /// older build stripping it, and this format's whole premise is that those cases
    /// remain distinguishable.
    var wrapCLI: String?
    /// Unknown document-level keys, preserved verbatim. See `JSONValue`.
    var x: [String: JSONValue]
    /// Order is the user's, exactly as with `snippets.json`; nothing here sorts it.
    var records: [VaultRecord]

    init(
        schemaVersion: Int = VaultDocument.currentSchemaVersion,
        kid: String,
        vaultSalt: String,
        kdf: VaultKDFParameters,
        wrapPass: String? = nil,
        wrapRecovery: String? = nil,
        wrapCLI: String? = nil,
        x: [String: JSONValue] = [:],
        records: [VaultRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.kid = kid
        self.vaultSalt = vaultSalt
        self.kdf = kdf
        self.wrapPass = wrapPass
        self.wrapRecovery = wrapRecovery
        self.wrapCLI = wrapCLI
        self.x = x
        self.records = records
    }

    func record(_ id: UUID) -> VaultRecord? {
        records.first { $0.id == id }
    }

    /// Every record as a content-free `Snippet`. See `VaultRecord.shell`.
    var shells: [Snippet] {
        records.map(\.shell)
    }

    /// `vaultSalt` as bytes, or `nil` if the field is not base64url.
    ///
    /// `nil` rather than an empty `Data` so a caller cannot `?? Data()` their way into
    /// deriving every key in the vault under an empty salt — which would succeed, be
    /// wrong, and produce a file no correct build can ever read. A `nil` here means the
    /// document is corrupt.
    var vaultSaltBytes: Data? {
        SnippetCrypto.data(fromBase64URL: vaultSalt)
    }

    /// The passphrase wrap, reassembled into the shape `PassphraseKDF` speaks.
    ///
    /// The four fields live in two places in the file (three under `kdf`, one at the
    /// top level), and stitching them back together by hand at the unlock call site is
    /// how `alg` ends up transcribed as something the KDF refuses. One accessor, so
    /// there is one stitch.
    /// `nil` when this vault has no passphrase, which is the default.
    var passphraseWrap: PassphraseKDF.WrappedKey? {
        guard let wrapPass else { return nil }
        return PassphraseKDF.WrappedKey(
            alg: kdf.alg, iterations: kdf.iterations, salt: kdf.saltP, envelope: wrapPass)
    }
}

/// How the passphrase is stretched into a key-encryption key.
///
/// Stored in the file rather than compiled in, so raising the iteration count on new
/// vaults does not lock every existing one out.
///
/// ## There are deliberately no `alg`/`iterations` constants here
///
/// There were, and they were a trap. This file used to declare
/// `pbkdf2HMACSHA256 = "pbkdf2-hmac-sha256"` and a `recommendedPBKDF2Iterations`
/// alongside it, described as "advisory — the crypto layer picks what it actually
/// uses". But the natural call site writes `VaultKDFParameters(alg: .pbkdf2HMACSHA256,
/// …)`, and `PassphraseKDF` speaks SHA-**512**; every vault created that way encoded an
/// `alg` its own unwrap path refuses, so the file was born permanently unopenable and
/// nothing failed until the user came back for their secrets. An advisory constant that
/// sits exactly where a required one goes is not advisory.
///
/// `PassphraseKDF` is the single source of truth. Build these parameters with
/// `init(_:)` below rather than by hand, and the algorithm and salt encoding come from
/// the layer that has to agree with them.
nonisolated struct VaultKDFParameters: Equatable {

    var alg: String
    var iterations: Int
    /// **base64url**, unpadded — `SnippetCrypto.base64URL`, which is what
    /// `PassphraseKDF.WrappedKey.salt` already contains.
    ///
    /// Not standard base64. The crypto layer's decoder rejects `+`, `/` and `=` on
    /// purpose, so that an envelope has exactly one spelling and can be compared for
    /// equality; a standard-base64 salt (a 16-byte salt always ends in `==`) decodes to
    /// `nil` there, which a caller then turns into an empty salt and a vault that never
    /// opens again.
    ///
    /// There is exactly one salt here and no `saltRecovery`/`saltCLI`, because those
    /// two wraps are keyed by stored randomness rather than by something a human chose.
    /// Stretching a uniformly random key buys nothing — see `KeyWrap`.
    var saltP: String
    /// Unknown KDF keys, preserved verbatim — this is where an Argon2id migration
    /// would put `memoryKiB` and `parallelism`, and an older build must not eat them.
    var x: [String: JSONValue]

    init(alg: String, iterations: Int, saltP: String, x: [String: JSONValue] = [:]) {
        self.alg = alg
        self.iterations = iterations
        self.saltP = saltP
        self.x = x
    }

    /// The parameters that produced a wrap, taken from the wrap itself.
    ///
    /// The only way these three fields can disagree with the blob they describe is if
    /// somebody types them in twice, so they are copied rather than re-stated.
    init(_ wrapped: PassphraseKDF.WrappedKey, x: [String: JSONValue] = [:]) {
        self.init(
            alg: wrapped.alg, iterations: wrapped.iterations, saltP: wrapped.salt, x: x)
    }
}

// MARK: - A record

/// One secure snippet: plaintext metadata, opaque ciphertext.
nonisolated struct VaultRecord: Equatable {

    var id: UUID
    var name: String
    var keyword: String
    var tags: [String]
    var isEnabled: Bool
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Merge ordering, exactly as in `SyncMerge`. Synthesized as
    /// `HLC.foreign(updatedAt:)` when a record arrives without one, so a hand-edited
    /// or restored file still participates in the merge instead of being unorderable.
    var hlc: HLC
    /// A **keyed** MAC over the plaintext, under a key derived from the library key.
    ///
    /// Keyed rather than a plain SHA-256 because the whole point of the vault is that
    /// the backend operator holds only ciphertext. An unkeyed digest of the plaintext
    /// would hand them an offline oracle: hash a guess, compare, confirm. With a MAC
    /// they cannot test a guess at all, while we keep the property we wanted — telling
    /// "the content really changed" from "the record was resealed with a fresh nonce",
    /// which is otherwise indistinguishable and would make every sync look dirty.
    var contentHash: String
    /// The AEAD output, as one self-describing string. Opaque here; its grammar
    /// belongs to the crypto layer, and nothing in this file parses it.
    var sealed: String
    /// Unknown record keys, preserved verbatim. See `JSONValue`.
    var x: [String: JSONValue]

    init(
        id: UUID,
        name: String,
        keyword: String,
        tags: [String] = [],
        isEnabled: Bool = true,
        isPinned: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        hlc: HLC,
        contentHash: String,
        sealed: String,
        x: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.tags = tags
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.hlc = hlc
        self.contentHash = contentHash
        self.sealed = sealed
        self.x = x
    }

    /// The record as an ordinary `Snippet` with **empty content**.
    ///
    /// This is how the rest of the app lists, searches, sorts and keyword-collision-
    /// checks secure snippets with the vault locked and no key in memory. `content` is
    /// `""` rather than a placeholder like `"••••"` on purpose: a shell is handed to
    /// code that also handles real snippets — the expander, the exporter, the share
    /// sheet — and an empty expansion is inert everywhere, whereas a placeholder is a
    /// string that eventually gets typed into somebody's chat window.
    ///
    /// A shell carries no "I am secure" marker, because `Snippet` is frozen at nine
    /// keys. The caller knows: it asked the vault for these.
    var shell: Snippet {
        Snippet(
            id: id,
            name: name,
            keyword: keyword,
            content: "",
            tags: tags,
            isEnabled: isEnabled,
            isPinned: isPinned,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }
}

// MARK: - Codable
//
// Hand-written throughout, because the `x` bags need `allKeys`, and because the
// leniency rules below are not expressible with synthesized conformances.
//
// The rule, applied identically everywhere: **`id` and `sealed` are required; every
// other field of a record falls back to a default.** The ciphertext is the only part
// that cannot be reconstructed — a name is retyped in seconds. Refusing to load a
// whole vault because one record's `isPinned` arrived as a string would be trading
// the irreplaceable thing for the replaceable one.
//
// Document-level keys are the opposite: `kid`, `vaultSalt`, `kdf`, `wrapPass`,
// `wrapRecovery` and `records` are all **required**. A document missing any of them
// cannot be unlocked, so guessing a default merely produces a plausible-looking file
// that will be written back over the real one. `records` in particular: reading a
// missing array as "empty vault" is the same mistake `LibraryWriter.read` documents
// for `snippets.json`, where a transient read failure reported as an empty library
// turns into permanent loss on the next save.

nonisolated extension VaultDocument: Codable {

    private static let knownKeys: Set<String> = [
        "schemaVersion", "kid", "vaultSalt", "kdf",
        "wrapPass", "wrapRecovery", "wrapCLI", "records",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)

        schemaVersion = try container.decode(Int.self, forKey: AnyCodingKey("schemaVersion"))
        kid = try container.decode(String.self, forKey: AnyCodingKey("kid"))
        vaultSalt = try container.decode(String.self, forKey: AnyCodingKey("vaultSalt"))
        kdf = try container.decode(VaultKDFParameters.self, forKey: AnyCodingKey("kdf"))
        // All three wraps are optional and independently absent: the vault key lives in
        // the Keychain, and a Keychain-only vault — the default — has none of them.
        // `decodeIfPresent` covers both a missing key and an explicit null, which
        // matters because the encoder writes explicit nulls (see `wrapCLI`).
        wrapPass = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("wrapPass"))
        wrapRecovery = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("wrapRecovery"))
        // Present-and-null and absent both mean "no CLI wrap".
        wrapCLI = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("wrapCLI"))
        records = try container.decode([VaultRecord].self, forKey: AnyCodingKey("records"))
        x = JSONPassthroughBag.decode(from: container, known: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)

        try container.encode(schemaVersion, forKey: AnyCodingKey("schemaVersion"))
        try container.encode(kid, forKey: AnyCodingKey("kid"))
        try container.encode(vaultSalt, forKey: AnyCodingKey("vaultSalt"))
        try container.encode(kdf, forKey: AnyCodingKey("kdf"))
        try container.encode(wrapPass, forKey: AnyCodingKey("wrapPass"))
        try container.encode(wrapRecovery, forKey: AnyCodingKey("wrapRecovery"))
        // `encode`, not `encodeIfPresent`: see the doc comment on `wrapCLI`.
        try container.encode(wrapCLI, forKey: AnyCodingKey("wrapCLI"))
        try container.encode(records, forKey: AnyCodingKey("records"))
        try JSONPassthroughBag.encode(x, into: &container, known: Self.knownKeys)
    }
}

nonisolated extension VaultKDFParameters: Codable {

    private static let knownKeys: Set<String> = ["alg", "iterations", "saltP"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        alg = try container.decode(String.self, forKey: AnyCodingKey("alg"))
        iterations = try container.decode(Int.self, forKey: AnyCodingKey("iterations"))
        saltP = try container.decode(String.self, forKey: AnyCodingKey("saltP"))
        x = JSONPassthroughBag.decode(from: container, known: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(alg, forKey: AnyCodingKey("alg"))
        try container.encode(iterations, forKey: AnyCodingKey("iterations"))
        try container.encode(saltP, forKey: AnyCodingKey("saltP"))
        try JSONPassthroughBag.encode(x, into: &container, known: Self.knownKeys)
    }
}

nonisolated extension VaultRecord: Codable {

    private static let knownKeys: Set<String> = [
        "id", "name", "keyword", "tags", "isEnabled", "isPinned",
        "createdAt", "updatedAt", "hlc", "contentHash", "sealed",
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)

        // The two that cannot be defaulted: without an id the record cannot be merged
        // or addressed, and without `sealed` there is nothing to protect.
        id = try container.decode(UUID.self, forKey: AnyCodingKey("id"))
        sealed = try container.decode(String.self, forKey: AnyCodingKey("sealed"))

        // Everything below uses `try?` deliberately, so a wrong *type* degrades the
        // same way a missing key does. See the leniency note above this extension.
        // (`try?` flattens the nested optional, so each of these is one `??`.)
        name = (try? container.decodeIfPresent(String.self, forKey: AnyCodingKey("name"))) ?? ""
        keyword = (try? container.decodeIfPresent(String.self, forKey: AnyCodingKey("keyword"))) ?? ""
        tags = SnippetTagging.normalizedTags(
            (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("tags"))) ?? [])
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("isEnabled"))) ?? true
        isPinned = (try? container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("isPinned"))) ?? false
        contentHash = (try? container.decodeIfPresent(String.self, forKey: AnyCodingKey("contentHash"))) ?? ""

        let decodedCreatedAt = try? container.decodeIfPresent(Date.self, forKey: AnyCodingKey("createdAt"))
        let decodedUpdatedAt = try? container.decodeIfPresent(Date.self, forKey: AnyCodingKey("updatedAt"))
        // `.distantPast` rather than `Date()`: a fabricated *now* would make an
        // undated record outrank every real one in the merge and in the suggestion
        // ranking. Losing to everything is the safe direction to be wrong in, and it
        // keeps this initializer free of a hidden clock read.
        createdAt = decodedCreatedAt ?? decodedUpdatedAt ?? .distantPast
        updatedAt = decodedUpdatedAt ?? createdAt

        hlc = (try? container.decodeIfPresent(HLC.self, forKey: AnyCodingKey("hlc")))
            ?? HLC.foreign(updatedAt: updatedAt)

        x = JSONPassthroughBag.decode(from: container, known: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)

        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(name, forKey: AnyCodingKey("name"))
        try container.encode(keyword, forKey: AnyCodingKey("keyword"))
        try container.encode(tags, forKey: AnyCodingKey("tags"))
        try container.encode(isEnabled, forKey: AnyCodingKey("isEnabled"))
        try container.encode(isPinned, forKey: AnyCodingKey("isPinned"))
        try container.encode(createdAt, forKey: AnyCodingKey("createdAt"))
        try container.encode(updatedAt, forKey: AnyCodingKey("updatedAt"))
        try container.encode(hlc, forKey: AnyCodingKey("hlc"))
        try container.encode(contentHash, forKey: AnyCodingKey("contentHash"))
        try container.encode(sealed, forKey: AnyCodingKey("sealed"))
        try JSONPassthroughBag.encode(x, into: &container, known: Self.knownKeys)
    }
}

// MARK: - Metadata-only view

/// What the CLI reads when it only needs to *list* the vault.
///
/// Distinct from decoding a whole `VaultDocument` in one specific, load-bearing way:
/// it never looks at `kdf` or the wrap blobs. `snippets-cli list` must keep working
/// against a vault whose KDF this build has never heard of, or whose wraps were
/// rewritten by a newer build — and it must not fail on a machine where the keychain
/// is locked or the binary is unsigned. Reading is always safe at any schema version,
/// so this path does **not** refuse a newer file; it reports the version and lets the
/// caller warn.
nonisolated struct VaultMetadata: Equatable {
    var schemaVersion: Int
    /// One content-free `Snippet` per record, in file order.
    var shells: [Snippet]

    var isNewerThanThisBuild: Bool { schemaVersion > VaultDocument.currentSchemaVersion }
}

/// The private, crypto-free mirror of the document used by `VaultFile.loadMetadata`.
private nonisolated struct VaultMetadataDocument: Decodable {

    struct Record: Decodable {
        var shell: Snippet

        init(from decoder: Decoder) throws {
            // Reuses `VaultRecord`'s leniency by construction: the same required/
            // defaulted split, minus every field a shell does not carry.
            let record = try VaultRecord(from: decoder)
            shell = record.shell
        }
    }

    var schemaVersion: Int
    var records: [Record]
}

// MARK: - Loading, writing, quarantining

nonisolated enum VaultFileError: Error, CustomStringConvertible {
    /// The bytes could not be read at all — permissions, I/O, a half-mounted volume.
    /// **Not** corruption: the file may be perfectly fine.
    case unreadable(path: String, detail: String)
    /// Bytes were read and are not a vault. This is the quarantine case.
    case undecodable(path: String, detail: String)
    /// A write was refused or failed.
    case writeRefused(String)
    case writeFailed(String)
    case quarantineFailed(String)

    var description: String {
        switch self {
        case .unreadable(let path, let detail):
            return "the vault at '\(path)' could not be read: \(detail)"
        case .undecodable(let path, let detail):
            return "the vault at '\(path)' could not be understood: \(detail)"
        case .writeRefused(let detail): return detail
        case .writeFailed(let detail): return detail
        case .quarantineFailed(let detail): return detail
        }
    }
}

/// The result of trying to load a vault.
///
/// The difference from `SyncStateFile.Outcome` is the whole point of this type, so it
/// is worth stating: **there is no `.fresh` case.** `SyncStateFile` can hand back a
/// brand-new `SyncState` when the file is unreadable, because `state.json` holds no
/// user data and regenerating it costs one reconcile. A vault holds the only copy of
/// things that exist nowhere else. So an unreadable vault reports *why*, and the only
/// legal next move is to quarantine and tell the user — never to synthesize an empty
/// one, because the very next save would rename it over the real file.
///
/// `.missing` and `.corrupt` are also kept apart for that reason. "No file yet" is
/// the ordinary first-run state and creating a vault is correct; "bytes we cannot
/// parse" is never that.
nonisolated enum VaultLoadOutcome<Value> {
    case loaded(Value)
    /// No vault exists yet. The only outcome in which creating one is allowed.
    case missing
    /// Written by a newer build. Display it, never write it back.
    case tooNew(version: Int)
    /// Could not be read. Change nothing and try again later.
    case unreadable(VaultFileError)
    /// Read, but not a vault. Quarantine; never overwrite.
    case corrupt(VaultFileError)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var tooNewVersion: Int? {
        if case .tooNew(let version) = self { return version }
        return nil
    }

    var isCorrupt: Bool {
        if case .corrupt = self { return true }
        return false
    }

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }

    /// The error a caller should record in `SyncState.Halt.detail`.
    var failure: VaultFileError? {
        switch self {
        case .unreadable(let error), .corrupt(let error): return error
        case .loaded, .missing, .tooNew: return nil
        }
    }
}

/// The vault's timestamp format: ISO-8601 in UTC **with milliseconds**.
///
/// Millisecond resolution rather than whole seconds because `HLC.wallMs` is in
/// milliseconds and `updatedAt` is one of its inputs; truncating here would
/// manufacture ties in the merge that the writer never had. Sub-millisecond precision
/// *is* lost, which is fine — nothing downstream can see below the clock's own
/// resolution — and it is called out here rather than discovered later.
///
/// It is a locked box around two formatters rather than two bare ones because
/// `JSONEncoder`'s `.custom` date strategy takes a `@Sendable` closure and Foundation's
/// formatters are not marked `Sendable`. One instance travels with each encoder, so
/// there is no shared global and no formatter allocated per timestamp.
nonisolated final class VaultTimestampCodec: @unchecked Sendable {

    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    /// Accepts a timestamp written without milliseconds — by hand, by `jq`, or by any
    /// build that used Foundation's plain `.iso8601` strategy.
    private let whole = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        whole.formatOptions = [.withInternetDateTime]
        whole.timeZone = TimeZone(secondsFromGMT: 0)
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    func date(from raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: raw) ?? whole.date(from: raw)
    }
}

nonisolated enum VaultFile {

    // MARK: Coding

    static func makeEncoder() -> JSONEncoder {
        let timestamps = VaultTimestampCodec()
        let encoder = JSONEncoder()
        // Sorted keys plus a fixed field order make the bytes a pure function of the
        // document: two devices that agree on the content produce identical files, so
        // the sync layer's byte digest does not report phantom changes.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamps.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let timestamps = VaultTimestampCodec()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = timestamps.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "malformed timestamp \"\(raw)\"; expected ISO-8601"))
            }
            return date
        }
        return decoder
    }

    static func encode(_ document: VaultDocument) throws -> Data {
        try makeEncoder().encode(document)
    }

    static func decode(_ data: Data) throws -> VaultDocument {
        try makeDecoder().decode(VaultDocument.self, from: data)
    }

    // MARK: Load

    /// Full load: version probe first, then decode.
    ///
    /// The probe runs before anything else for the reason spelled out on
    /// `SchemaVersionProbe`: decoding a future format may fail outright, and that
    /// failure must land in "this build is too old" rather than in "the file is
    /// broken". Getting it backwards means an older build quarantines a newer build's
    /// vault and then writes a fresh one — losing nothing, because quarantine
    /// preserves the bytes, but presenting the user with an empty vault and a scary
    /// dialog on a file that was never damaged.
    static func load(from url: URL = SnippetStorageLocations.vaultFileURL) -> VaultLoadOutcome<VaultDocument> {
        guard let read = readBytes(from: url) else { return .missing }
        switch read {
        case .failure(let error):
            return .unreadable(error)
        case .success(let bytes):
            if let version = probeSchemaVersion(bytes), version > VaultDocument.currentSchemaVersion {
                return .tooNew(version: version)
            }
            do {
                return .loaded(try decode(bytes))
            } catch {
                return .corrupt(.undecodable(path: url.path, detail: "\(error)"))
            }
        }
    }

    /// Metadata-only load. Never touches `kdf` or the wrap blobs, and never refuses a
    /// newer file — see `VaultMetadata`.
    static func loadMetadata(from url: URL = SnippetStorageLocations.vaultFileURL) -> VaultLoadOutcome<VaultMetadata> {
        guard let read = readBytes(from: url) else { return .missing }
        switch read {
        case .failure(let error):
            return .unreadable(error)
        case .success(let bytes):
            do {
                let document = try makeDecoder().decode(VaultMetadataDocument.self, from: bytes)
                return .loaded(VaultMetadata(
                    schemaVersion: document.schemaVersion,
                    shells: document.records.map(\.shell)))
            } catch {
                return .corrupt(.undecodable(path: url.path, detail: "\(error)"))
            }
        }
    }

    /// Reads `schemaVersion` alone. `nil` when the file is not even a JSON object.
    static func probeSchemaVersion(_ data: Data) -> Int? {
        (try? JSONDecoder().decode(SchemaVersionProbe.self, from: data))?.schemaVersion
    }

    /// `nil` means the path does not exist; otherwise the bytes or the read error.
    ///
    /// "No such file" is separated from every other errno for the reason
    /// `LibraryWriter.read` documents: a permissions failure or an I/O error reported
    /// as "no vault here" is how a transient problem becomes a fresh empty vault
    /// renamed over the user's real one.
    private static func readBytes(from url: URL) -> Result<Data, VaultFileError>? {
        do {
            return .success(try Data(contentsOf: url))
        } catch {
            let nsError = error as NSError
            if nsError.isFileNotFound { return nil }
            return .failure(.unreadable(path: url.path, detail: error.localizedDescription))
        }
    }

    // MARK: Write

    /// Writes the vault atomically, at 0600.
    ///
    /// Refuses outright when `document.schemaVersion` exceeds this build's. That guard
    /// is structural rather than advisory on purpose: "an older build must never
    /// overwrite a newer vault" is the single rule this format exists to enforce, and
    /// leaving it to every call site to remember is how it eventually is not
    /// remembered.
    /// Locked read-modify-write of the vault.
    ///
    /// **Use this, not `write`, for anything that changes an existing vault.** A
    /// whole-document overwrite from a stale copy is the same defect the library write
    /// path was built to remove — and it is worse here, because `vault.json` is the one
    /// file with no undo stack, no plaintext duplicate, and nothing to reconstruct from.
    /// Losing a record here loses a secret outright.
    ///
    /// The lock is the LIBRARY lock, deliberately. Marking a snippet secure moves it
    /// between `snippets.json` and `vault.json`, so a vault writer holding a separate
    /// lock could interleave with a promotion and leave the record in both files or in
    /// neither. One lock over both files makes that impossible.
    ///
    /// `transform` may run more than once and must be free of side effects.
    @discardableResult
    static func update(
        at url: URL = SnippetStorageLocations.vaultFileURL,
        lockURL: URL = SnippetStorageLocations.libraryLockFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL,
        lockTimeout: TimeInterval,
        transform: (VaultDocument?) throws -> VaultDocument
    ) throws -> VaultDocument {
        let held: FileGuard.Held
        do {
            held = try FileGuard.acquire(at: lockURL, timeout: lockTimeout)
        } catch {
            throw VaultFileError.writeFailed("another process is writing the vault; try again")
        }
        defer { held.release() }

        for _ in 0..<8 {
            // Read INSIDE the lock. A caller's copy from a moment ago may already be
            // stale, and overwriting a record someone else just added is exactly the
            // loss this exists to prevent.
            let bytesAtRead = try? Data(contentsOf: url)
            let before = try currentDocument(at: url)
            let updated = try transform(before)
            // The input was checked by `currentDocument`, but the transform can mint
            // a document of its own. Apply the same structural guard as `write` after
            // the transform so an older build cannot create or overwrite a vault in a
            // schema it does not understand.
            guard updated.schemaVersion <= VaultDocument.currentSchemaVersion else {
                throw VaultFileError.writeRefused(
                    "refusing to write vault schemaVersion \(updated.schemaVersion); "
                    + "this build understands \(VaultDocument.currentSchemaVersion)")
            }
            let data = try encode(updated)

            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Same compare-and-swap as the library write, for the same reason: the lock
            // can be defeated from outside, and unlike the library there is no second
            // copy of this data anywhere. Compare against the bytes this attempt READ —
            // comparing the file to itself is always true and checks nothing.
            guard (try? Data(contentsOf: url)) == bytesAtRead else { continue }

            do {
                try AtomicFileWriter.write(data, to: url, temporaryDirectory: temporaryDirectory)
            } catch {
                throw VaultFileError.writeFailed("could not save the vault: \(error)")
            }

            // And confirm ours is what survived, so a peer that raced us is folded in
            // on the next attempt rather than clobbered.
            guard (try? Data(contentsOf: url)) == data else { continue }
            return updated
        }
        throw VaultFileError.writeFailed("the vault changed under every write attempt; try again")
    }

    /// The vault as it is on disk right now, or `nil` if there is not one yet.
    ///
    /// Throws rather than returning `nil` when a vault exists but cannot be read —
    /// treating an unreadable vault as "no vault" would let a caller write a fresh
    /// empty one straight over the user's secrets.
    private static func currentDocument(at url: URL) throws -> VaultDocument? {
        switch load(from: url) {
        case .loaded(let document): return document
        case .missing: return nil
        case .tooNew(let version):
            throw VaultFileError.writeRefused(
                "vault is schemaVersion \(version); this build understands \(VaultDocument.currentSchemaVersion)")
        case .unreadable(let error):
            throw VaultFileError.writeRefused("refusing to overwrite an unreadable vault: \(error)")
        case .corrupt(let error):
            // Corrupt is NOT "no vault". Writing a fresh document over it would destroy
            // secrets that a quarantined copy might still recover. The caller must
            // quarantine deliberately first.
            throw VaultFileError.writeRefused("refusing to overwrite a corrupt vault: \(error)")
        }
    }

    /// Unlocked whole-document write. Only safe for creating a vault that does not yet
    /// exist, or in tests. Everything else must go through `update`.
    static func write(
        _ document: VaultDocument,
        to url: URL = SnippetStorageLocations.vaultFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) throws {
        guard document.schemaVersion <= VaultDocument.currentSchemaVersion else {
            throw VaultFileError.writeRefused(
                "refusing to write vault schemaVersion \(document.schemaVersion); "
                + "this build understands \(VaultDocument.currentSchemaVersion)")
        }

        let data: Data
        do {
            data = try encode(document)
        } catch {
            throw VaultFileError.writeFailed("could not encode the vault: \(error)")
        }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try AtomicFileWriter.write(data, to: url, temporaryDirectory: temporaryDirectory)
        } catch {
            throw VaultFileError.writeFailed("could not save the vault: \(error)")
        }
    }

    // MARK: Quarantine

    /// Where a damaged vault is moved to. A sibling of the vault, so the move is a
    /// `rename(2)` on one filesystem and cannot half-succeed.
    static func quarantineFolderURL(for vaultURL: URL) -> URL {
        vaultURL.deletingLastPathComponent().appendingPathComponent("Quarantine", isDirectory: true)
    }

    /// Moves an unreadable vault aside, preserving its bytes exactly.
    ///
    /// A **move**, not a copy, and not a delete:
    ///
    /// - Not a delete, obviously. Those bytes may be the only copy of the user's
    ///   secrets, and "we could not parse it" is a statement about this build, not
    ///   about the data. A future version, or `openssl` by hand, may well recover it.
    /// - Not an overwrite. Nothing in this file will ever put a fresh empty vault on
    ///   top of an existing one; `write` is the only path that writes, `load` never
    ///   calls it, and there is no `.fresh` outcome to tempt a caller.
    /// - A move rather than a copy so the damaged file stops being reloaded — and
    ///   failing — on every launch. After this returns, `load` reports `.missing`, and
    ///   the caller is expected to have already halted sync with
    ///   `SyncState.HaltReason.vaultUnreadable`, which is sticky, so the user is told
    ///   before anything replaces it.
    ///
    /// The destination name is timestamped and de-duplicated, so quarantining twice
    /// never overwrites the first attempt.
    @discardableResult
    static func quarantine(
        at url: URL = SnippetStorageLocations.vaultFileURL,
        reason: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        guard fileManager.fileExists(atPath: url.path) else {
            throw VaultFileError.quarantineFailed("nothing to quarantine at '\(url.path)'")
        }

        let folder = quarantineFolderURL(for: url)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw VaultFileError.quarantineFailed(
                "could not create '\(folder.path)': \(error.localizedDescription)")
        }

        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let destination = uniqueURL(
            in: folder, stem: "\(stem)-\(Self.stamp(now))", extension: ext, fileManager: fileManager)

        do {
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            throw VaultFileError.quarantineFailed(
                "could not move '\(url.path)' to '\(destination.path)': \(error.localizedDescription)")
        }

        // Best-effort note beside it. Six months later, a folder of timestamped JSON
        // files with no explanation is not much of a rescue.
        let note = """
            Snippets moved this file aside on \(VaultTimestampCodec().string(from: now)).

            Reason: \(reason)

            It was NOT modified and NOT deleted. Its contents are the encrypted vault
            exactly as they were found. Nothing overwrote it.
            """
        try? Data(note.utf8).write(
            to: destination.deletingPathExtension().appendingPathExtension("txt"), options: .atomic)

        return destination
    }

    /// `vault-20260808-134501.json`, then `-2`, `-3`, … if that name is taken.
    private static func uniqueURL(
        in folder: URL, stem: String, extension ext: String, fileManager: FileManager
    ) -> URL {
        var candidate = folder.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(suffix).\(ext)", isDirectory: false)
            suffix += 1
        }
        return candidate
    }

    /// `yyyyMMdd-HHmmss` in UTC. UTC rather than the local zone so a quarantine taken
    /// on a travelling laptop still sorts chronologically in the Finder.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
