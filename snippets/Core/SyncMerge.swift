import Foundation
import CryptoKit

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// Three-way merge of a snippet library.
///
/// ## Why three-way rather than last-writer-wins
///
/// Every alternative loses data in a case that happens weekly:
///
/// - **Whole-file last-writer-wins** (what the app does today) throws away
///   everything the loser did. A CLI write landing within 300 ms of a keystroke is
///   discarded silently while the CLI prints a success receipt.
/// - **Whole-record last-writer-wins on `updatedAt`** loses a field on every
///   cross-device edit: rename a snippet on one Mac, edit its body on another, and
///   one of the two changes evaporates. `updatedAt` is also a live input to
///   suggestion ranking, so it is not free to repurpose as a merge token.
///
/// With a common ancestor, most conflicts are not conflicts at all. If only one
/// side moved a field away from base, that side is simply right, and **no clock is
/// consulted** — which is why clock skew between devices barely matters here. A
/// clock is needed only when both sides genuinely moved the same field.
///
/// ## The two invariants worth stating out loud
///
/// 1. **Absence is never a delete.** A record missing from one side is only a
///    deletion if the ancestor proves it was there and left. Without that proof,
///    absence means "this side has not seen it yet", and treating it as a delete is
///    how a fresh install wipes a library.
/// 2. **An edit always beats a delete.** A deletion the user meant is trivially
///    repeatable — they delete it again. An edit that a delete swallowed is gone.
///    So when one side deleted and the other edited, the edit survives.
nonisolated enum SyncMerge {

    struct Outcome {
        /// The merged library, in a stable order: surviving records in their local
        /// order, then records only the other side had.
        var snippets: [Snippet]
        /// Losing sides of a genuine content conflict, preserved as disabled copies.
        var conflictCopies: [Snippet]
        /// Records disabled because the merge left two live snippets sharing a keyword.
        var disabledByKeywordCollision: [UUID]

        /// Whether the merge had to take an action the user should be told about.
        ///
        /// Deliberately **not** "did anything change" — an ordinary successful merge
        /// changes plenty and needs no announcement. Renaming it away from the more
        /// obvious `didChangeAnything` because that name invited exactly the wrong
        /// call site: `guard didChangeAnything else { return }` before persisting.
        var needsUserAttention: Bool {
            !conflictCopies.isEmpty || !disabledByKeywordCollision.isEmpty
        }
    }

    /// The six fields the app itself treats as "the user changed something" —
    /// `SnippetStore.update` uses exactly this list to decide whether an edit is
    /// worth persisting. `createdAt` and `updatedAt` are excluded deliberately:
    /// they are bookkeeping, and a re-save that only bumped `updatedAt` must not
    /// count as an edit that outranks a deliberate deletion.
    static func payloadEquals(_ lhs: Snippet, _ rhs: Snippet) -> Bool {
        lhs.name == rhs.name
            && lhs.keyword == rhs.keyword
            && lhs.content == rhs.content
            && lhs.tags == rhs.tags
            && lhs.isEnabled == rhs.isEnabled
            && lhs.isPinned == rhs.isPinned
    }

    /// Merges the in-memory library against what another writer put on disk.
    ///
    /// - Parameters:
    ///   - base: the bytes this process last saw on disk — the common ancestor. The
    ///     app maintains this for free as `lastKnownDiskData`.
    ///   - local: this process's in-memory library.
    ///   - remote: what is on disk now.
    ///
    /// Takes no device identity: the tiebreak is symmetric by construction (see
    /// `localOutranksRemote`), and an earlier version that used device identity here
    /// could not converge.
    static func mergeLocal(
        base: [Snippet],
        local: [Snippet],
        remote: [Snippet]
    ) -> Outcome {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var merged: [UUID: Snippet] = [:]
        var conflictCopies: [Snippet] = []

        for id in Set(baseByID.keys).union(localByID.keys).union(remoteByID.keys) {
            let (survivor, copy) = mergeRecord(
                base: baseByID[id], local: localByID[id], remote: remoteByID[id])
            if let survivor { merged[id] = survivor }
            if let copy { conflictCopies.append(copy) }
        }

        // Sorted before use: the loop above walks a `Set`, whose iteration order is
        // randomly seeded per process, so without this the *array* handed back to
        // callers (and shown to the user) would differ between two identical merges.
        conflictCopies.sort { $0.id.uuidString < $1.id.uuidString }

        // Conflict copies are added after the main pass so a copy can never be
        // mistaken for an ancestor of anything in it.
        for copy in conflictCopies { merged[copy.id] = copy }

        var ordered = orderedResult(merged: merged, local: local, remote: remote)

        // Only records this merge created or changed are candidates for being
        // disabled. A duplicate keyword that already existed in `local` and was
        // untouched here is the editor's warning to surface, not ours to enforce.
        var touched = Set(conflictCopies.map(\.id))
        let localByIDForTouch = localByID
        for record in ordered where !(localByIDForTouch[record.id].map { payloadEquals($0, record) } ?? false) {
            touched.insert(record.id)
        }
        let disabled = resolveKeywordCollisions(&ordered, touched: touched)

        return Outcome(
            snippets: ordered, conflictCopies: conflictCopies, disabledByKeywordCollision: disabled)
    }

    /// Rebases an undo/redo snapshot onto a merged library.
    ///
    /// **Not a merge, deliberately.** An undo entry is a *stated intent* — "put the
    /// library back to exactly this" — not a competing edit by another device. Running
    /// it through `mergeLocal` treats it as one, and that goes wrong with no
    /// concurrency at all: edit a snippet v1 → v2, let the CLI write v3, and the
    /// rebase sees base v2, local v1, remote v3, all three distinct. That is the
    /// definition of a content conflict, so undo would restore nothing and instead
    /// mint a disabled `(conflict …)` record into the shared library — which then
    /// survives every later rebase. Pressing ⌘Z would create junk rather than undo.
    ///
    /// So the rebase replays only what the snapshot actually *changes* relative to the
    /// state it was captured against, and takes the merged library for everything
    /// else. No clock, no arbitration, no conflict copies.
    static func rebaseSnapshot(
        _ snapshot: [Snippet], from capturedAgainst: [Snippet], onto merged: [Snippet]
    ) -> [Snippet] {
        let capturedByID = Dictionary(
            capturedAgainst.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let snapshotByID = Dictionary(
            snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // What this snapshot means, expressed against its own baseline.
        let deletedByUndo = Set(capturedByID.keys).subtracting(snapshotByID.keys)
        let changedByUndo = snapshotByID.filter { id, value in
            guard let captured = capturedByID[id] else { return true }   // undo re-adds it
            return !payloadEquals(captured, value)
        }

        var out: [Snippet] = []
        var emitted = Set<UUID>()
        for record in merged {
            if deletedByUndo.contains(record.id) { continue }
            emitted.insert(record.id)
            out.append(changedByUndo[record.id] ?? record)
        }
        // Records the undo genuinely brings BACK — not ones it merely carries along.
        //
        // `changedByUndo` is the difference between the snapshot and the state it was
        // captured against, so a record in it is one the undo has an opinion about:
        // either it was re-added, or its content differs. A record absent from it is
        // untouched baggage, and re-appending that resurrects whatever the merge just
        // decided to remove.
        //
        // That is not theoretical. Encrypting a snippet removes it from the plaintext
        // library, but every undo level captured beforehand still holds it *with its
        // content*. Without this condition the next rebase put it back, and ⌘Z — the
        // reflex gesture right after clicking the lock — wrote the plaintext into
        // snippets.json next to the sealed copy, from where it reached exports, share
        // links and `snippets-cli list`. The recovery gesture was the leak.
        for record in snapshot
        where !emitted.contains(record.id) && changedByUndo[record.id] != nil {
            out.append(record)
        }
        return out
    }

    /// Resolves one record. Returns the survivor (or `nil` if it should not exist)
    /// and, when both sides changed the content, the losing side preserved as a copy.
    static func mergeRecord(
        base: Snippet?,
        local: Snippet?,
        remote: Snippet?
    ) -> (survivor: Snippet?, conflictCopy: Snippet?) {
        switch (local, remote) {
        case (nil, nil):
            // Both sides agree it is gone, or it never existed.
            return (nil, nil)

        case (nil, .some(let remote)):
            // Missing locally. Only a deletion if the ancestor proves we had it and
            // the other side left it untouched; otherwise the other side is simply
            // ahead of us, or edited what we deleted — and an edit beats a delete.
            guard let base, payloadEquals(base, remote) else { return (remote, nil) }
            return (nil, nil)

        case (.some(let local), nil):
            guard let base, payloadEquals(base, local) else { return (local, nil) }
            return (nil, nil)

        case (.some(let local), .some(let remote)):
            if payloadEquals(local, remote) {
                // Same content on both sides. Keep the later timestamps so the record
                // does not appear to travel backwards in the suggestion ranking.
                var survivor = local
                survivor.createdAt = min(local.createdAt, remote.createdAt)
                survivor.updatedAt = max(local.updatedAt, remote.updatedAt)
                return (survivor, nil)
            }
            return mergeChangedRecord(base: base, local: local, remote: remote)
        }
    }

    /// Decides which side outranks the other, in a way both devices compute identically.
    ///
    /// The obvious implementation — stamp our record with our real device id and the
    /// other side's with `HLC.foreignDevice`, then compare — **does not converge**.
    /// It is asymmetric: each device labels its own record with the higher-sorting id,
    /// so on an exact millisecond tie *both* devices conclude "mine wins", each writes
    /// its own version, and they rewrite the file at each other forever. Ties are not
    /// exotic either: `updatedAt` truncates to whole milliseconds, and the app-versus-
    /// CLI collision the lock exists for is by definition two writers in the same
    /// instant.
    ///
    /// So the tiebreak is taken from the data itself. Both sides hash the same two
    /// payloads and pick the same winner, whichever machine is asking. This gives up
    /// the older "the in-app edit always wins a tie" rule, which was never expressible
    /// symmetrically — and which now matters far less, because a tie can only be
    /// reached when both sides changed *the same field* to *different values* inside
    /// the same millisecond, and content specifically is preserved as a conflict copy
    /// rather than discarded.
    static func localOutranksRemote(_ local: Snippet, _ remote: Snippet) -> Bool {
        if local.updatedAt != remote.updatedAt { return local.updatedAt > remote.updatedAt }
        return payloadDigest(local) < payloadDigest(remote)
    }

    /// A stable digest of the six user-meaningful fields. Used only to break exact
    /// ties, so it needs determinism across processes and machines, not secrecy.
    static func payloadDigest(_ snippet: Snippet) -> String {
        // Length-prefixed, so no combination of field contents can be confused for a
        // different combination (\"ab\"+\"c\" must not hash as \"a\"+\"bc\").
        var joined = ""
        for field in [snippet.name, snippet.keyword, snippet.content, snippet.tags.joined(separator: "\u{1}")] {
            joined += "\(field.utf8.count):\(field)\u{2}"
        }
        joined += snippet.isEnabled ? "1" : "0"
        joined += snippet.isPinned ? "1" : "0"
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func mergeChangedRecord(
        base: Snippet?,
        local: Snippet,
        remote: Snippet
    ) -> (survivor: Snippet?, conflictCopy: Snippet?) {
        let localWins = localOutranksRemote(local, remote)

        var survivor = local
        survivor.name = mergeScalar(base?.name, local.name, remote.name, localWins: localWins)
        survivor.keyword = mergeScalar(base?.keyword, local.keyword, remote.keyword, localWins: localWins)
        survivor.isEnabled = mergeScalar(base?.isEnabled, local.isEnabled, remote.isEnabled, localWins: localWins)
        survivor.isPinned = mergeScalar(base?.isPinned, local.isPinned, remote.isPinned, localWins: localWins)
        survivor.tags = mergeTags(base?.tags, local.tags, remote.tags, localWins: localWins)

        // Creation never moves forward and modification never moves backward.
        // `updatedAt` feeds `enabledSnippetsSorted`, so a merge that lowered it would
        // silently reshuffle which snippet wins an ambiguous keyword prefix.
        survivor.createdAt = min(local.createdAt, remote.createdAt)
        survivor.updatedAt = max(local.updatedAt, remote.updatedAt)

        let (content, copy) = mergeContent(
            base: base, local: local, remote: remote, localWins: localWins)
        survivor.content = content

        return (survivor, copy)
    }

    /// Three-way merge of one scalar field.
    ///
    /// The two middle branches are the whole point: when only one side moved, that
    /// side wins outright and **no clock is consulted**. Clock skew can therefore
    /// only ever affect a field that both devices genuinely changed.
    static func mergeScalar<T: Equatable>(_ base: T?, _ local: T, _ remote: T, localWins: Bool) -> T {
        if local == remote { return local }
        if let base, local == base { return remote }
        if let base, remote == base { return local }
        return localWins ? local : remote
    }

    /// Three-way set merge for tags.
    ///
    /// With an ancestor, the add-versus-remove conflict that an OR-Set exists to
    /// solve cannot arise: removing a tag requires it to be in base, adding one
    /// requires it to be absent from base, so the two operations are never in
    /// contention for the same element. The ancestor *is* the causal context an
    /// OR-Set carries per element, and it is already free.
    ///
    /// Ordering is deterministic — base order first, then new tags sorted — so both
    /// devices independently produce the identical array and the merge is
    /// commutative.
    static func mergeTags(_ base: [String]?, _ local: [String], _ remote: [String], localWins: Bool) -> [String] {
        let key = SnippetTagging.filterKey
        let baseKeys = Set((base ?? []).map(key))
        let localKeys = Set(local.map(key))
        let remoteKeys = Set(remote.map(key))

        // Survivors from the ancestor: everything neither side removed.
        let removed = baseKeys.subtracting(localKeys).union(baseKeys.subtracting(remoteKeys))
        let kept = baseKeys.subtracting(removed)
        let added = localKeys.subtracting(baseKeys).union(remoteKeys.subtracting(baseKeys))

        // Preserve the user's hand-ordering for tags that were already there.
        //
        // With no ancestor, everything counts as "added", and sorting the whole list
        // would silently alphabetise every hand-ordered tag array on the very first
        // merge — a visible reshuffle plus a pointless write for every record. So the
        // no-ancestor case keeps the preferred side's order verbatim and only appends
        // what the other side additionally had.
        guard base != nil else {
            let preferred = localWins ? local : remote
            let other = localWins ? remote : local
            let preferredKeys = Set(preferred.map(key))
            return SnippetTagging.normalizedTags(
                preferred + other.filter { !preferredKeys.contains(key($0)) })
        }

        // Surviving tags keep the ancestor's ORDER but take the winning side's
        // spelling. Emitting the ancestor's string outright would revert a casing
        // change both devices agreed on — base ["work"], both sides ["Work"], result
        // "work" — which breaks the per-field rule this file is built on: a value both
        // sides moved must never be overridden by the value neither of them kept.
        let preferredSide = localWins ? local : remote
        let otherSide = localWins ? remote : local
        func spelling(_ tagKey: String, fallback: String) -> String {
            preferredSide.first { key($0) == tagKey }
                ?? otherSide.first { key($0) == tagKey }
                ?? fallback
        }

        var ordered = (base ?? [])
            .filter { kept.contains(key($0)) }
            .map { spelling(key($0), fallback: $0) }
        // Newly added ones go in a deterministic order so both sides converge.
        for tagKey in added.sorted() {
            guard let casing = preferredSide.first(where: { key($0) == tagKey })
                ?? otherSide.first(where: { key($0) == tagKey }) else { continue }
            ordered.append(casing)
        }
        return SnippetTagging.normalizedTags(ordered)
    }

    /// Content is the only field that is never discarded.
    ///
    /// A lost name is retyped in seconds; a lost snippet body may be the only copy
    /// that ever existed. So when both sides genuinely changed the content, the
    /// loser is preserved as a separate, disabled snippet rather than overwritten.
    static func mergeContent(
        base: Snippet?,
        local: Snippet,
        remote: Snippet,
        localWins: Bool
    ) -> (content: String, conflictCopy: Snippet?) {
        if local.content == remote.content { return (local.content, nil) }
        if let base, base.content == local.content { return (remote.content, nil) }
        if let base, base.content == remote.content { return (local.content, nil) }

        let winner = localWins ? local : remote
        let loser = localWins ? remote : local

        // A DETERMINISTIC id, derived from the record and the losing side's content.
        // Both devices compute the same UUID independently, so exactly one conflict
        // copy exists across the fleet and syncing a third time is a no-op. With a
        // random id, every sync round would mint another copy — conflict copies would
        // breed without bound, which is the classic way this feature goes wrong.
        let copyID = deterministicUUID(
            namespace: local.id,
            name: "conflict|\(loser.content)|\(loser.updatedAt.millisecondsSince1970)")

        var copy = loser
        copy.id = copyID
        copy.name = conflictName(for: loser)
        // Two live snippets may never share a keyword, and the copy must never be
        // reachable by typing.
        copy.keyword = ""
        copy.isEnabled = false
        copy.isPinned = false
        copy.tags = SnippetTagging.normalizedTags(loser.tags + ["conflict"])

        return (winner.content, copy)
    }

    private static func conflictName(for loser: Snippet) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // UTC, not the local zone. The copy's *id* is derived deterministically so both
        // devices agree it is one record — but if its *name* were rendered in local
        // time, two machines in different zones would forever disagree about the name
        // of the same record and overwrite each other's version of it.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return "\(loser.displayName) (conflict \(formatter.string(from: loser.updatedAt)))"
    }

    /// A UUIDv5-style name-based identifier: SHA-1 over a namespace and a name, with
    /// the version and variant bits set. Stable across devices and across runs.
    static func deterministicUUID(namespace: UUID, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Stable output order: local order first, then anything only the other side had.
    ///
    /// Without this the merged array's order would follow `Set` iteration, which is
    /// randomly seeded per process — the list would reshuffle itself on every merge.
    private static func orderedResult(
        merged: [UUID: Snippet], local: [Snippet], remote: [Snippet]
    ) -> [Snippet] {
        var ordered: [Snippet] = []
        ordered.reserveCapacity(merged.count)
        var emitted = Set<UUID>()

        for snippet in local {
            guard let survivor = merged[snippet.id], emitted.insert(snippet.id).inserted else { continue }
            ordered.append(survivor)
        }
        for snippet in remote {
            guard let survivor = merged[snippet.id], emitted.insert(snippet.id).inserted else { continue }
            ordered.append(survivor)
        }
        // Conflict copies and anything else the two passes missed, in id order so the
        // result is fully deterministic.
        for id in merged.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard emitted.insert(id).inserted, let survivor = merged[id] else { continue }
            ordered.append(survivor)
        }
        return ordered
    }

    /// Final pass: a merge can produce two live snippets sharing a keyword even
    /// though neither device ever saw a collision.
    ///
    /// The merge cannot reject a record, so it disables the loser instead. The
    /// keyword is deliberately **not** cleared — that would destroy what the user
    /// typed, and the existing keyword-conflict warning in the editor already
    /// surfaces the situation for them to resolve.
    ///
    /// Scoped to records the merge actually touched. Sweeping the whole array would
    /// mean the first merge after this code ships silently disables any duplicate
    /// keyword the user has been living with for months — the app only ever *warned*
    /// about those, and a merge is not the place to start enforcing a rule
    /// retroactively.
    @discardableResult
    static func resolveKeywordCollisions(
        _ snippets: inout [Snippet], touched: Set<UUID>? = nil
    ) -> [UUID] {
        var winners: [String: Int] = [:]
        var disabled: [UUID] = []

        // Incumbents first, so an untouched record always wins against a newly merged
        // one and a pre-existing duplicate is never the side that gets disabled.
        let order = snippets.indices.sorted { lhs, rhs in
            let lhsTouched = touched?.contains(snippets[lhs].id) ?? true
            let rhsTouched = touched?.contains(snippets[rhs].id) ?? true
            if lhsTouched != rhsTouched { return !lhsTouched }
            return lhs < rhs
        }

        for index in order where snippets[index].isEnabled {
            let key = SnippetTagging.filterKey(for: snippets[index].normalizedKeyword)
            guard !key.isEmpty else { continue }

            guard let incumbent = winners[key] else {
                winners[key] = index
                continue
            }

            // Neither side is new: this collision predates the merge, so leave it to
            // the editor's existing keyword warning rather than disabling silently.
            if let touched, !touched.contains(snippets[index].id),
               !touched.contains(snippets[incumbent].id) { continue }

            // Newer wins; an exact tie falls back to id order so both devices agree.
            let challengerWins: Bool
            if snippets[index].updatedAt != snippets[incumbent].updatedAt {
                challengerWins = snippets[index].updatedAt > snippets[incumbent].updatedAt
            } else {
                challengerWins = snippets[index].id.uuidString < snippets[incumbent].id.uuidString
            }

            let loser = challengerWins ? incumbent : index
            snippets[loser].isEnabled = false
            disabled.append(snippets[loser].id)
            if challengerWins { winners[key] = index }
        }

        return disabled
    }
}

// MARK: - Merging across devices

nonisolated extension SyncMerge {

    /// Three-way merge of one record as it travels between devices.
    ///
    /// The same rules as `mergeRecord`, restated over envelopes so a cross-device merge
    /// is not weaker than a local one. Whole-record last-writer-wins would have been far
    /// less code and would lose a field every time two devices touch the same snippet —
    /// rename it on the Mac, edit its body on the iPhone, and one change evaporates.
    ///
    /// Content is compared by `contentHash` rather than by bytes, which is what lets a
    /// **locked** vault take part: the hash is keyed and travels in the envelope, so a
    /// device that cannot decrypt a secure record can still tell whether it changed. It
    /// also stops a fresh AES-GCM nonce — different bytes, identical plaintext — from
    /// looking like an edit and starting a ping-pong.
    static func mergeEnvelope(
        base: SyncEnvelope?, local: SyncEnvelope?, remote: SyncEnvelope?
    ) -> SyncEnvelope? {
        switch (local, remote) {
        case (nil, nil):
            return nil

        // Absence is never a delete without an ancestor to prove it, exactly as locally.
        case (nil, .some(let remote)):
            return remote
        case (.some(let local), nil):
            return local

        case (.some(let local), .some(let remote)):
            // An explicit tombstone on one side loses to a real edit on the other: a
            // deletion is trivially repeatable, an edit that a delete swallowed is gone.
            if local.deleted && remote.deleted { return local.hlc > remote.hlc ? local : remote }
            if local.deleted { return changed(remote, since: base) ? remote : local }
            if remote.deleted { return changed(local, since: base) ? local : remote }

            guard let localFields = local.fields, let remoteFields = remote.fields else {
                return local.hlc > remote.hlc ? local : remote
            }
            if localFields == remoteFields, local.secure == remote.secure {
                let localWins = local.hlc >= remote.hlc
                let winner = localWins ? local : remote
                var mergedX = local.x.merging(remote.x) { mine, theirs in
                    localWins ? mine : theirs
                }
                if local.secure {
                    // Same sealed body means either keyed hash describes the same
                    // plaintext. Prefer the clock winner's value, but let a newer peer
                    // backfill a legacy envelope that did not carry one at all.
                    mergedX[SyncEnvelope.vaultContentHashExtensionKey] =
                        winner.x[SyncEnvelope.vaultContentHashExtensionKey]
                        ?? (localWins ? remote.x : local.x)[
                            SyncEnvelope.vaultContentHashExtensionKey]
                } else {
                    mergedX[SyncEnvelope.vaultContentHashExtensionKey] = nil
                }
                return SyncEnvelope(
                    id: winner.id, hlc: winner.hlc, origin: winner.origin,
                    secure: winner.secure, deleted: false, fields: winner.fields, x: mergedX)
            }

            // `fields.content` has two representations: plaintext in a plain
            // envelope, and the opaque vault seal in a secure one. A one-sided move
            // relative to the ancestor is explicit and must carry its representation
            // with it. OR-ing the flags and then merging the body independently can
            // put plaintext in `VaultRecord.sealed`, and also makes a real demotion
            // impossible to sync.
            let mergedSecure: Bool
            let representationCameFromLocal: Bool?
            if local.secure == remote.secure {
                mergedSecure = local.secure
                representationCameFromLocal = nil
            } else if let base {
                let localMoved = local.secure != base.secure
                let remoteMoved = remote.secure != base.secure
                if localMoved != remoteMoved {
                    representationCameFromLocal = localMoved
                    mergedSecure = localMoved ? local.secure : remote.secure
                } else {
                    // Defensive fallback for an inconsistent ancestor. Keeping the
                    // secure representation is the non-leaking direction.
                    mergedSecure = true
                    representationCameFromLocal = local.secure
                }
            } else {
                // With no ancestor there is no proof that a plain copy is a deliberate
                // demotion. Keep the secure representation.
                mergedSecure = true
                representationCameFromLocal = local.secure
            }

            // Symmetric, so both devices pick the same winner from mirrored inputs. The
            // HLC already carries a device tiebreak, so unlike the local merge there is
            // no need to hash payloads here.
            let localWins = local.hlc > remote.hlc
            let baseFields = base?.fields

            var merged = SyncEnvelope.Fields(
                name: mergeScalar(baseFields?.name, localFields.name, remoteFields.name, localWins: localWins),
                keyword: mergeScalar(baseFields?.keyword, localFields.keyword, remoteFields.keyword, localWins: localWins),
                content: localFields.content,
                tags: mergeTags(baseFields?.tags, localFields.tags, remoteFields.tags, localWins: localWins),
                isEnabled: mergeScalar(baseFields?.isEnabled, localFields.isEnabled, remoteFields.isEnabled, localWins: localWins),
                isPinned: mergeScalar(baseFields?.isPinned, localFields.isPinned, remoteFields.isPinned, localWins: localWins),
                createdAt: min(localFields.createdAt, remoteFields.createdAt),
                updatedAt: max(localFields.updatedAt, remoteFields.updatedAt))

            // Content resolves on the keyed hash, so this branch is identical whether or
            // not the vault happens to be unlocked.
            let localKey = mergeContentKey(local, fields: localFields)
            let remoteKey = mergeContentKey(remote, fields: remoteFields)
            let baseKey = base.flatMap { envelope in
                envelope.fields.map { mergeContentKey(envelope, fields: $0) }
            }

            let contentCameFromLocal: Bool
            if let representationCameFromLocal {
                merged.content = representationCameFromLocal
                    ? localFields.content : remoteFields.content
                contentCameFromLocal = representationCameFromLocal
            } else if localKey == remoteKey || baseKey == remoteKey {
                merged.content = localFields.content
                contentCameFromLocal = true
            } else if baseKey == localKey {
                merged.content = remoteFields.content
                contentCameFromLocal = false
            } else {
                // Both sides genuinely changed the body. Unlike the local merge there is
                // no conflict copy here: minting one would require sealing a new record,
                // which needs the vault key — and this path has to work while locked.
                // The loser is preserved by the OTHER device, which does hold its own
                // copy and will push it back as an ordinary edit if the user keeps it.
                merged.content = localWins ? localFields.content : remoteFields.content
                contentCameFromLocal = localWins
            }

            let winner = localWins ? local : remote
            var mergedX = local.x.merging(remote.x) { mine, theirs in
                localWins ? mine : theirs
            }
            if mergedSecure {
                // This extension is the vault HMAC for the selected sealed body. It
                // must follow the content winner, which can differ from the overall
                // HLC winner when only one side changed the body from the ancestor.
                mergedX[SyncEnvelope.vaultContentHashExtensionKey] =
                    (contentCameFromLocal ? local.x : remote.x)[
                        SyncEnvelope.vaultContentHashExtensionKey]
            } else {
                mergedX[SyncEnvelope.vaultContentHashExtensionKey] = nil
            }
            return SyncEnvelope(
                id: local.id,
                hlc: max(local.hlc, remote.hlc),
                origin: winner.origin,
                secure: mergedSecure,
                deleted: false,
                fields: merged,
                x: mergedX)
        }
    }

    /// Whether a side moved away from the ancestor. With no ancestor, anything present
    /// counts as a change — the conservative direction, since it keeps data.
    private static func changed(_ envelope: SyncEnvelope, since base: SyncEnvelope?) -> Bool {
        guard let base else { return true }
        return (try? base.envelopeHash()) != (try? envelope.envelopeHash())
    }

    private static func mergeContentKey(
        _ envelope: SyncEnvelope, fields: SyncEnvelope.Fields
    ) -> String {
        if envelope.secure,
           let keyedHash = envelope.x[SyncEnvelope.vaultContentHashExtensionKey]?.text {
            return keyedHash
        }
        return envelope.contentHash
            ?? SHA256.hash(data: fields.content).map { String(format: "%02x", $0) }.joined()
    }
}
