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
        case incompatibleSecureConflictVault(UUID)
        case invalidSecureConflictCarrier(UUID)

        var description: String {
            switch self {
            case .invalidSecureBody(let id):
                return "secure sync record \(id) does not contain a valid UTF-8 sealed value"
            case .incompatibleSecureConflictVault(let id):
                return "secure sync record \(id) contains a conflict from another vault"
            case .invalidSecureConflictCarrier(let id):
                return "secure sync record \(id) contains an invalid conflict carrier"
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

            let exactProjected = exactPlain(projected, snippet: snippet)
            let exactAgreed = exactPlain(agreed, snippet: snippet)
            if let known = mergedKnowledge(
                weaker: exactProjected,
                stronger: exactAgreed
            ) {
                // The frozen local model cannot hold the rest of the envelope. The
                // sidecar and durable journal/base can each own disjoint unknown
                // extensions. Equality of every persisted field proves both describe
                // this exact primary version, so preserve their union.
                out[snippet.id] = strippingSecureOnlyExtensions(from: known)
            } else {
                let known = mergedKnowledge(weaker: projected, stronger: agreed)
                let extensions = strippingSecureOnlyExtensions(
                    from: known)?.x ?? [:]
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
                    x: extensions)
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

            let exactProjected = exactSecure(
                projected, record: record, vaultKID: vaultKID)
            let exactAgreed = exactSecure(
                agreed, record: record, vaultKID: vaultKID)
            if let known = mergedKnowledge(
                weaker: exactProjected,
                stronger: exactAgreed
            ) {
                out[record.id] = known
            } else {
                let known = mergedKnowledge(weaker: projected, stronger: agreed)
                // Primary storage is authoritative for resolution. Derived metadata
                // may still carry a variant/provenance from before the transaction
                // removed it, so replace (including with the empty set) rather than
                // unioning these reserved keys back into the record.
                var extensions = (known?.x ?? [:]).filter {
                    !SyncMerge.isContentConflictExtension($0.key)
                        && $0.key != SyncMerge.plainConflictCopyExtensionKey
                }
                for (key, value) in record.x {
                    if key.hasPrefix(SyncMerge.contentConflictOpaqueCarrierPrefix),
                       case .string(let base64) = value,
                       let bytes = Data(base64Encoded: base64),
                       let restored = try? CanonicalJSON.value(bytes) {
                        let suffix = String(key.dropFirst(
                            SyncMerge.contentConflictOpaqueCarrierPrefix.count))
                        let restoredKey = SyncMerge.contentConflictExtensionPrefix + suffix
                        if let existing = extensions[restoredKey], existing != restored {
                            // Legacy direct and current opaque encodings of the same
                            // member must agree regardless of Dictionary iteration order.
                            extensions[SyncMerge.contentConflictExtensionPrefix + "invalid"] =
                                .null
                        } else {
                            extensions[restoredKey] = restored
                        }
                    } else if key.hasPrefix(SyncMerge.contentConflictExtensionPrefix) {
                        // Legacy builds briefly wrote structured variants directly.
                        // Preserve their JSON value; strict validation at the app
                        // projection boundary decides whether it is safe to sync.
                        let restored = canonicalValue(value)
                        if let existing = extensions[key], existing != restored {
                            extensions[SyncMerge.contentConflictExtensionPrefix + "invalid"] =
                                .null
                        } else {
                            extensions[key] = restored
                        }
                    } else if key.hasPrefix(SyncMerge.contentConflictOpaqueCarrierPrefix) {
                        // Preserve an unmistakably reserved invalid sentinel. The app
                        // boundary validates and halts before this can be offered; most
                        // importantly it can never look like a resolved/deletable record.
                        extensions[SyncMerge.contentConflictExtensionPrefix + "invalid"] =
                            .null
                    } else if key == SyncMerge.plainConflictCopyExtensionKey {
                        if let provenance = conflictCopyProvenance(value) {
                            extensions[key] = provenance
                        } else {
                            // The reserved key is itself causal evidence. Silently
                            // dropping a value from a newer/corrupt writer would turn a
                            // deterministic preservation copy into an ordinary record.
                            // Emit the same invalid sentinel used for malformed carrier
                            // values so the bridge and transition boundaries fail closed.
                            extensions[
                                SyncMerge.contentConflictExtensionPrefix + "invalid"
                            ] = .null
                        }
                    }
                }
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
        guard envelope.secure else { return nil }
        if envelope.deleted {
            // Tombstones are not vault records, but a tombstone carrying the sole
            // unresolved secure-conflict snapshot is malformed and must not hide it.
            try SyncMerge.validateContentConflictExtensions(in: envelope)
            return nil
        }
        guard let fields = envelope.fields else { return nil }
        guard let sealed = String(data: fields.content, encoding: .utf8) else {
            throw Failure.invalidSecureBody(envelope.id)
        }
        // Preserve this boundary's specific invalid-body diagnosis. The complete wire
        // budget validator canonicalizes the envelope and would otherwise surface its
        // lower-level UTF-8 error before this projection can explain what is wrong.
        try SyncMerge.validateContentConflictExtensions(in: envelope)

        let variants = try SyncMerge.secureContentConflictVariants(in: envelope)
        if let localKID = envelope.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text,
           variants.contains(where: {
               $0.sourceExtensions[SyncEnvelope.vaultKeyIDExtensionKey]?.text != localKID
           }) {
            throw Failure.incompatibleSecureConflictVault(envelope.id)
        }
        let carriedHash = envelope.x[SyncEnvelope.vaultContentHashExtensionKey]?.text
        let preservedHash = existing.flatMap { old in
            old.sealed == sealed ? nonEmpty(old.contentHash) : nil
        }
        var recordExtensions = (existing?.x ?? [:]).filter {
            !$0.key.hasPrefix(SyncMerge.contentConflictOpaqueCarrierPrefix)
                && !SyncMerge.isContentConflictExtension($0.key)
                && $0.key != SyncMerge.plainConflictCopyExtensionKey
        }
        // Secure losing versions remain encrypted wire metadata until the vault key is
        // available. Mirror them into the vault record's passthrough bag so a missing
        // derived sync sidecar or an ordinary metadata edit cannot strip the only copy.
        for key in envelope.x.keys where SyncMerge.isContentConflictExtension(key) {
            guard let value = envelope.x[key] else { continue }
            let suffix = String(key.dropFirst(SyncMerge.contentConflictExtensionPrefix.count))
            recordExtensions[SyncMerge.contentConflictOpaqueCarrierPrefix + suffix] =
                .string(try CanonicalJSON.data(value).base64EncodedString())
        }
        if let provenance = envelope.x[SyncMerge.plainConflictCopyExtensionKey],
           let value = conflictCopyProvenance(provenance) {
            recordExtensions[SyncMerge.plainConflictCopyExtensionKey] = value
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
            x: recordExtensions)
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func canonicalValue(_ value: JSONValue) -> CanonicalJSON.Value {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .integer(let number): return .int(number)
        case .double(let number): return .double(number)
        case .string(let text): return .string(text)
        case .array(let values): return .array(values.map(canonicalValue))
        case .object(let object): return .object(object.mapValues(canonicalValue))
        }
    }

    private static func conflictCopyProvenance(
        _ value: JSONValue
    ) -> CanonicalJSON.Value? {
        guard case .object(let object) = value,
              Set(object.keys) == ["version", "sourceID", "fingerprint"],
              object["version"] == .integer(1),
              case .string(let sourceText)? = object["sourceID"],
              let sourceID = UUID(uuidString: sourceText),
              sourceText == sourceID.uuidString.lowercased(),
              case .string(let fingerprint)? = object["fingerprint"],
              isLowercaseSHA256(fingerprint)
        else { return nil }
        return .object([
            "version": .int(1),
            "sourceID": .string(sourceText),
            "fingerprint": .string(fingerprint),
        ])
    }

    private static func conflictCopyProvenance(
        _ value: CanonicalJSON.Value
    ) -> JSONValue? {
        guard let object = value.object,
              Set(object.keys) == ["version", "sourceID", "fingerprint"],
              object["version"]?.int == 1,
              let sourceText = object["sourceID"]?.text,
              let sourceID = UUID(uuidString: sourceText),
              sourceText == sourceID.uuidString.lowercased(),
              let fingerprint = object["fingerprint"]?.text,
              isLowercaseSHA256(fingerprint)
        else { return nil }
        return .object([
            "version": .integer(1),
            "sourceID": .string(sourceText),
            "fingerprint": .string(fingerprint),
        ])
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
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
        let storedProvenance: CanonicalJSON.Value?
        if let value = record.x[SyncMerge.plainConflictCopyExtensionKey] {
            guard let parsed = conflictCopyProvenance(value) else { return nil }
            storedProvenance = parsed
        } else {
            storedProvenance = nil
        }
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
              candidate.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text == vaultKID,
              let storedConflicts = conflictExtensions(record.x),
              conflictExtensions(candidate.x) == storedConflicts,
              candidate.x[SyncMerge.plainConflictCopyExtensionKey]
                == storedProvenance
        else { return nil }
        return candidate
    }

    /// True only when a live secure envelope is an exact echo of the primary vault
    /// record for all persisted fields and safety-critical extension state. This lets
    /// an already-authenticated conflict copy pass through sync while the vault session
    /// is locked; changed ciphertext/provenance still requires a fresh key validation.
    static func matchesExactSecurePrimary(
        _ envelope: SyncEnvelope,
        record: VaultRecord,
        vaultKID: String
    ) -> Bool {
        exactSecure(envelope, record: record, vaultKID: vaultKID) != nil
            && envelope.hlc == record.hlc
    }

    /// Legacy wire records predate the vault scope stamp. They are safe to accept while
    /// locked only when adding this vault's stamp makes them an exact primary echo;
    /// every changed/absent legacy body still requires fresh AEAD/HMAC validation.
    static func matchesExactLegacyUnstampedSecurePrimary(
        _ envelope: SyncEnvelope,
        record: VaultRecord,
        vaultKID: String
    ) -> Bool {
        guard envelope.x[SyncEnvelope.vaultKeyIDExtensionKey] == nil else { return false }
        var stamped = envelope
        stamped.x[SyncEnvelope.vaultKeyIDExtensionKey] = .string(vaultKID)
        return matchesExactSecurePrimary(stamped, record: record, vaultKID: vaultKID)
    }

    private static func conflictExtensions(
        _ values: [String: CanonicalJSON.Value]
    ) -> [String: CanonicalJSON.Value] {
        values.filter { $0.key.hasPrefix(SyncMerge.contentConflictExtensionPrefix) }
    }

    private static func conflictExtensions(
        _ values: [String: JSONValue]
    ) -> [String: CanonicalJSON.Value]? {
        var result: [String: CanonicalJSON.Value] = [:]
        for pair in values {
            if pair.key.hasPrefix(SyncMerge.contentConflictOpaqueCarrierPrefix) {
                guard case .string(let base64) = pair.value,
                      let bytes = Data(base64Encoded: base64),
                      let value = try? CanonicalJSON.value(bytes)
                else { return nil }
                let suffix = String(pair.key.dropFirst(
                    SyncMerge.contentConflictOpaqueCarrierPrefix.count))
                let restoredKey = SyncMerge.contentConflictExtensionPrefix + suffix
                if let existing = result[restoredKey], existing != value { return nil }
                result[restoredKey] = value
            } else if SyncMerge.isContentConflictExtension(pair.key) {
                let value = canonicalValue(pair.value)
                if let existing = result[pair.key], existing != value { return nil }
                result[pair.key] = value
            }
        }
        return result
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

    /// A representation transition can leave the strongest durable knowledge as the
    /// prior secure envelope while primary storage is already plain. Hash and vault kid
    /// describe sealed bytes, so carrying them onto plaintext would lie about content
    /// identity and can wedge the next three-way merge. All other extension knowledge
    /// remains record metadata and survives the transition.
    private static func strippingSecureOnlyExtensions(
        from envelope: SyncEnvelope?
    ) -> SyncEnvelope? {
        guard var envelope else { return nil }
        envelope.x[SyncEnvelope.vaultContentHashExtensionKey] = nil
        envelope.x[SyncEnvelope.vaultKeyIDExtensionKey] = nil
        return envelope
    }

    /// Combines extension knowledge from a derived sidecar and a durable ancestor or
    /// journal snapshot. The second source is authoritative on a same-key disagreement;
    /// disjoint keys are causal metadata and must never be lost merely because one file
    /// was stale when the other was written.
    ///
    /// Reserved conflict members are stricter than ordinary forward-compatible fields:
    /// disagreement cannot be resolved by LWW without potentially dropping the sole
    /// losing body. Install an unmistakably invalid sentinel so the bridge's validator
    /// quarantines the projection before transport.
    private static func mergedKnowledge(
        weaker: SyncEnvelope?, stronger: SyncEnvelope?
    ) -> SyncEnvelope? {
        guard var result = newest(weaker, stronger) else { return nil }
        if let weaker {
            mergeExtensions(from: weaker, into: &result, authoritative: false)
        }
        if let stronger {
            mergeExtensions(from: stronger, into: &result, authoritative: true)
        }
        return result
    }

    private static func mergeExtensions(
        from source: SyncEnvelope,
        into result: inout SyncEnvelope,
        authoritative: Bool
    ) {
            for (key, value) in source.x {
                guard let existing = result.x[key], existing != value else {
                    result.x[key] = value
                    continue
                }
                if SyncMerge.isContentConflictExtension(key)
                    || key == SyncMerge.plainConflictCopyExtensionKey {
                    result.x[SyncMerge.contentConflictExtensionPrefix + "invalid"] = .null
                } else if authoritative {
                    result.x[key] = value
                }
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
