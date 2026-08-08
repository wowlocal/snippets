import Foundation

/// Lossless translation between the frozen local files and sync envelopes.
///
/// `snippets.json` has nowhere to store an HLC, origin, or the wire extension bag. The
/// sync projection sidecar stores all three, so this projection reuses its envelope
/// while the fields still describe the local record. The agreed base is a recovery
/// fallback when that derived sidecar is unavailable. A field change means a real
/// local edit; only then do we mint a deterministic clock above the ancestor and mark
/// this device as the origin.
///
/// This is pure Core logic rather than code embedded in the AppKit bridge so the
/// apply -> project -> diff fixed point can be tested without constructing the app.
nonisolated enum SyncLibraryProjection {

    enum Failure: Error, CustomStringConvertible, Equatable {
        case invalidSecureBody(UUID)

        var description: String {
            switch self {
            case .invalidSecureBody(let id):
                return "secure sync record \(id) does not contain a valid UTF-8 sealed value"
            }
        }
    }

    /// Builds the exact envelope view of the two local stores.
    ///
    /// - Parameter vaultKID: the `kid` of the vault `records` came out of, stamped into
    ///   each secure envelope's encrypted extension bag so a receiving Mac can tell
    ///   whether its own vault can actually open them. `nil` only when there are no
    ///   secure records to stamp.
    static func currentEnvelopes(
        snippets: [Snippet],
        records: [VaultRecord],
        deviceID: String,
        metadata: SyncBase,
        agreedBase: SyncBase = SyncBase(),
        vaultKID: String? = nil
    ) -> [UUID: SyncEnvelope] {
        var out: [UUID: SyncEnvelope] = [:]

        for snippet in snippets {
            let fields = SyncEnvelope.Fields(
                name: snippet.name, keyword: snippet.normalizedKeyword,
                content: Data(snippet.content.utf8), tags: snippet.tags,
                isEnabled: snippet.isEnabled, isPinned: snippet.isPinned,
                createdAt: snippet.createdAt, updatedAt: snippet.updatedAt)
            let projected = metadata.envelope(snippet.id)
            let agreed = agreedBase.envelope(snippet.id)

            if let known = exactPlain(projected, snippet: snippet)
                ?? exactPlain(agreed, snippet: snippet) {
                // The frozen local model cannot hold the rest of the envelope. The
                // agreed ancestor can, and equality of every persisted field proves
                // this is still that exact version.
                out[snippet.id] = known
            } else {
                let known = newest(projected, agreed)
                out[snippet.id] = SyncEnvelope(
                    id: snippet.id,
                    hlc: localClock(
                        updatedAt: snippet.updatedAt, stored: nil,
                        ancestor: known?.hlc, deviceID: deviceID),
                    origin: deviceID,
                    secure: false,
                    deleted: false,
                    fields: fields,
                    // Unknown extensions belong to the record, not to whichever
                    // version of the app happens to edit it.
                    x: known?.x ?? [:])
            }
        }

        for record in records {
            let fields = SyncEnvelope.Fields(
                name: record.name, keyword: record.keyword,
                // The sealed string, not the plaintext. Sync therefore works locked
                // and an unchanged record remains byte-stable.
                content: Data(record.sealed.utf8), tags: record.tags,
                isEnabled: record.isEnabled, isPinned: record.isPinned,
                createdAt: record.createdAt, updatedAt: record.updatedAt)
            let projected = metadata.envelope(record.id)
            let agreed = agreedBase.envelope(record.id)

            if let known = exactSecure(projected, record: record, vaultKID: vaultKID) {
                out[record.id] = known
            } else if let known = exactSecure(agreed, record: record, vaultKID: vaultKID) {
                out[record.id] = known
            } else {
                let known = newest(projected, agreed)
                var extensions = known?.x ?? [:]
                extensions[SyncEnvelope.vaultContentHashExtensionKey] =
                    nonEmpty(record.contentHash).map(CanonicalJSON.Value.string)
                // Stamped alongside the content hash, and for the same reason: the
                // receiving side cannot otherwise learn which vault sealed these bytes.
                extensions[SyncEnvelope.vaultKeyIDExtensionKey] =
                    vaultKID.map(CanonicalJSON.Value.string)
                out[record.id] = SyncEnvelope(
                    id: record.id,
                    hlc: localClock(
                        updatedAt: record.updatedAt, stored: record.hlc,
                        ancestor: known?.hlc, deviceID: deviceID),
                    origin: deviceID,
                    secure: true,
                    deleted: false,
                    fields: fields,
                    x: extensions)
            }
        }

        return out
    }

    /// Converts an incoming secure envelope without confusing its unkeyed wire digest
    /// with the vault's keyed plaintext hash.
    static func vaultRecord(
        from envelope: SyncEnvelope,
        preserving existing: VaultRecord? = nil
    ) throws -> VaultRecord? {
        guard !envelope.deleted, envelope.secure, let fields = envelope.fields else {
            return nil
        }
        guard let sealed = String(data: fields.content, encoding: .utf8) else {
            throw Failure.invalidSecureBody(envelope.id)
        }

        let carriedHash = envelope.x[SyncEnvelope.vaultContentHashExtensionKey]?.text
        let preservedHash = existing.flatMap { old in
            old.sealed == sealed ? nonEmpty(old.contentHash) : nil
        }

        return VaultRecord(
            id: envelope.id,
            name: fields.name,
            keyword: fields.keyword,
            tags: fields.tags,
            isEnabled: fields.isEnabled,
            isPinned: fields.isPinned,
            createdAt: fields.createdAt,
            updatedAt: fields.updatedAt,
            hlc: envelope.hlc,
            // A legacy peer may omit the extension. Retain a known-good local HMAC
            // only when the sealed bytes are unchanged; otherwise an empty value is
            // honest and recoverable after unlock, while a SHA of ciphertext is not.
            contentHash: carriedHash ?? preservedHash ?? "",
            sealed: sealed,
            x: existing?.x ?? [:])
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func exactPlain(
        _ candidate: SyncEnvelope?, snippet: Snippet
    ) -> SyncEnvelope? {
        guard let candidate, !candidate.deleted, !candidate.secure,
              let fields = candidate.fields,
              fields.name == snippet.name,
              Snippet.sanitizedKeyword(fields.keyword) == snippet.normalizedKeyword,
              fields.content == Data(snippet.content.utf8),
              SnippetTagging.normalizedTags(fields.tags)
                == SnippetTagging.normalizedTags(snippet.tags),
              fields.isEnabled == snippet.isEnabled,
              fields.isPinned == snippet.isPinned,
              fields.createdAt == snippet.createdAt,
              fields.updatedAt == snippet.updatedAt
        else { return nil }
        return candidate
    }

    /// - Parameter vaultKID: an otherwise-identical envelope from before the scope stamp
    ///   existed is deliberately **not** exact. Reusing it verbatim would keep a record
    ///   unstamped for as long as nothing else about it changed, which is for ever for a
    ///   snippet nobody edits — and an unstamped record is one the other Mac cannot check
    ///   before filing. Failing the match here re-projects it once, with the stamp.
    private static func exactSecure(
        _ candidate: SyncEnvelope?, record: VaultRecord, vaultKID: String?
    ) -> SyncEnvelope? {
        guard let candidate, !candidate.deleted, candidate.secure,
              let fields = candidate.fields,
              fields.name == record.name,
              fields.keyword == record.keyword,
              fields.content == Data(record.sealed.utf8),
              SnippetTagging.normalizedTags(fields.tags)
                == SnippetTagging.normalizedTags(record.tags),
              fields.isEnabled == record.isEnabled,
              fields.isPinned == record.isPinned,
              fields.createdAt == record.createdAt,
              fields.updatedAt == record.updatedAt,
              candidate.x[SyncEnvelope.vaultContentHashExtensionKey]?.text
                == nonEmpty(record.contentHash),
              candidate.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text == vaultKID
        else { return nil }
        return candidate
    }

    private static func newest(
        _ first: SyncEnvelope?, _ second: SyncEnvelope?
    ) -> SyncEnvelope? {
        switch (first, second) {
        case (.some(let first), .some(let second)):
            return first.hlc >= second.hlc ? first : second
        case (.some(let first), nil): return first
        case (nil, .some(let second)): return second
        case (nil, nil): return nil
        }
    }

    /// Deterministic because `currentEnvelopes()` may be called twice before a push.
    /// A random or stateful tick here would make the second read look like another
    /// edit. Secure-store clocks are retained when they already describe a local edit;
    /// otherwise the ancestor's next wall millisecond is an unambiguous successor.
    private static func localClock(
        updatedAt: Date,
        stored: HLC?,
        ancestor: HLC?,
        deviceID: String
    ) -> HLC {
        let device = HLC.normalizedDevice(deviceID)
        if let stored,
           stored.device == device,
           ancestor.map({ stored > $0 }) ?? true {
            return stored
        }

        let ancestorFloor: UInt64
        if let ancestor {
            ancestorFloor = ancestor.wallMs < 0xFFFF_FFFF_FFFF
                ? ancestor.wallMs + 1
                : 0xFFFF_FFFF_FFFF
        } else {
            ancestorFloor = 0
        }
        let wall = max(updatedAt.millisecondsSince1970, ancestorFloor)
        let counter: UInt16
        if let ancestor, wall == ancestor.wallMs {
            counter = ancestor.counter == UInt16.max
                ? UInt16.max : ancestor.counter + 1
        } else {
            counter = 0
        }
        return HLC(wallMs: wall, counter: counter, device: device)
    }
}
