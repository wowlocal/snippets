import Foundation

nonisolated struct SnippetUsageRecord: Codable, Equatable {
    /// Weight in the document's `epoch` frame. The true decayed weight at time
    /// `t` is `weight * 2^(-(t - epoch)/H)`; that factor is the same for every
    /// record, so comparing raw weights is comparing decayed weights.
    var weight: Double
    /// Lifetime counter, never decayed. Display only.
    var count: Int
    /// Unix seconds. Display only, never ranked.
    var lastUsedAt: Double

    enum CodingKeys: String, CodingKey {
        case weight = "s"
        case count = "n"
        case lastUsedAt = "l"
    }

    init(weight: Double = 0, count: Int = 0, lastUsedAt: Double = 0) {
        self.weight = weight
        self.count = count
        self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weight = try container.decodeIfPresent(Double.self, forKey: .weight) ?? 0
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        lastUsedAt = try container.decodeIfPresent(Double.self, forKey: .lastUsedAt) ?? 0
    }
}

nonisolated struct SnippetUsageDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    /// Unix seconds, not the Foundation reference date: the file should be
    /// readable by a human and by a future CLI without knowing this app's
    /// date strategy.
    var epoch: Double
    /// The half-life the weights were written in. Keeps the file
    /// self-describing so the constant can change without invalidating data.
    var halfLifeDays: Double
    /// uuidString -> record
    var records: [String: SnippetUsageRecord]
    /// folded query prefix (1...8) -> uuidString -> weight in the same epoch
    var bindings: [String: [String: Double]]
    /// Unix seconds of the last "Reset Usage Data". A monotonic marker so a
    /// merge cannot resurrect the data from disk.
    var recordsClearedAt: Double
    /// Unix seconds of the last time selection memory was switched off.
    var bindingsClearedAt: Double

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case epoch
        case halfLifeDays = "h"
        case records = "w"
        case bindings = "b"
        case recordsClearedAt = "rc"
        case bindingsClearedAt = "bc"
    }

    /// Written out explicitly rather than synthesized. With the synthesized
    /// decoder, a future version that renames or drops any non-optional key
    /// would fail to decode entirely, land in the "unreadable" branch with
    /// `isReadOnly` still false, and let an older build overwrite a newer
    /// build's data — debug and release share this directory.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        epoch = try container.decodeIfPresent(Double.self, forKey: .epoch) ?? 0
        halfLifeDays = try container.decodeIfPresent(Double.self, forKey: .halfLifeDays)
            ?? SnippetFrecency.halfLifeDays
        records = try container.decodeIfPresent([String: SnippetUsageRecord].self, forKey: .records) ?? [:]
        bindings = try container.decodeIfPresent([String: [String: Double]].self, forKey: .bindings) ?? [:]
        recordsClearedAt = try container.decodeIfPresent(Double.self, forKey: .recordsClearedAt) ?? 0
        bindingsClearedAt = try container.decodeIfPresent(Double.self, forKey: .bindingsClearedAt) ?? 0
    }

    init(
        version: Int,
        epoch: Double,
        halfLifeDays: Double,
        records: [String: SnippetUsageRecord],
        bindings: [String: [String: Double]],
        recordsClearedAt: Double = 0,
        bindingsClearedAt: Double = 0
    ) {
        self.version = version
        self.epoch = epoch
        self.halfLifeDays = halfLifeDays
        self.records = records
        self.bindings = bindings
        self.recordsClearedAt = recordsClearedAt
        self.bindingsClearedAt = bindingsClearedAt
    }

    static func empty(now: Double) -> SnippetUsageDocument {
        SnippetUsageDocument(
            version: currentVersion,
            epoch: now,
            halfLifeDays: SnippetFrecency.halfLifeDays,
            records: [:],
            bindings: [:]
        )
    }
}

/// Read before the full decoder: decoding a future format may fail outright,
/// and when it does the failure has to land in read-only rather than in
/// "start from scratch".
nonisolated struct SnippetUsageVersionProbe: Decodable {
    let v: Int?
}

nonisolated enum SnippetUsageFile {

    // MARK: - Frame conversion

    /// Restates a document in the frame anchored at `target`.
    ///
    /// The multiplier is shared by every weight, so the ordering inside the
    /// document is preserved exactly and the binding ceiling survives. When the
    /// half-life also changes there is no conversion that preserves all future
    /// values — only the values at `target`, which is precisely what this
    /// returns.
    static func rescaled(
        _ doc: SnippetUsageDocument,
        toEpoch target: Double,
        halfLifeDays newHalfLife: Double? = nil
    ) -> SnippetUsageDocument {
        var out = doc
        out.epoch = target
        out.halfLifeDays = newHalfLife ?? doc.halfLifeDays

        let halfLifeSeconds = max(doc.halfLifeDays, 1) * 86_400
        guard target.isFinite, doc.epoch.isFinite else { return out }
        let delta = min(max(target - doc.epoch, -SnippetFrecency.maxElapsedSeconds),
                        SnippetFrecency.maxElapsedSeconds)
        let multiplier = exp2(-delta / halfLifeSeconds)
        guard multiplier.isFinite, multiplier > 0 else { return out }
        if multiplier == 1 { return out }

        out.records = doc.records.mapValues { record in
            SnippetUsageRecord(
                weight: SnippetFrecency.clamp(weight: record.weight * multiplier),
                count: record.count,
                lastUsedAt: record.lastUsedAt
            )
        }
        out.bindings = doc.bindings.mapValues { table in
            table.mapValues { SnippetFrecency.clamp(weight: $0 * multiplier) }
        }
        return out
    }

    /// Keeps the stored numbers small and the file human-readable. Also the
    /// only place a changed `halfLifeDays` constant is absorbed.
    static func rebasedIfNeeded(_ doc: SnippetUsageDocument, now: Double) -> SnippetUsageDocument {
        if doc.halfLifeDays != SnippetFrecency.halfLifeDays {
            return rescaled(doc, toEpoch: now, halfLifeDays: SnippetFrecency.halfLifeDays)
        }

        let heaviest = doc.records.values.map(\.weight).max() ?? 0
        let isStale = now - doc.epoch > SnippetFrecency.rebaseIntervalSeconds
        guard isStale || heaviest > SnippetFrecency.rebaseWeightThreshold else { return doc }
        guard now > doc.epoch else { return doc }
        return rescaled(doc, toEpoch: now)
    }

    // MARK: - Validation

    static func sanitized(_ doc: SnippetUsageDocument) -> SnippetUsageDocument {
        var out = doc

        out.version = doc.version
        out.halfLifeDays = doc.halfLifeDays.isFinite
            ? min(max(doc.halfLifeDays, 1), 365)
            : SnippetFrecency.halfLifeDays
        out.epoch = doc.epoch.isFinite ? min(max(doc.epoch, 0), SnippetFrecency.maxTimestamp) : 0
        out.recordsClearedAt = doc.recordsClearedAt.isFinite
            ? min(max(doc.recordsClearedAt, 0), SnippetFrecency.maxTimestamp)
            : 0
        out.bindingsClearedAt = doc.bindingsClearedAt.isFinite
            ? min(max(doc.bindingsClearedAt, 0), SnippetFrecency.maxTimestamp)
            : 0

        out.records = doc.records.reduce(into: [:]) { accumulated, entry in
            guard UUID(uuidString: entry.key) != nil,
                  entry.value.weight.isFinite, entry.value.weight > 0,
                  entry.value.lastUsedAt.isFinite else { return }
            accumulated[entry.key] = SnippetUsageRecord(
                weight: SnippetFrecency.clamp(weight: entry.value.weight),
                count: min(max(entry.value.count, 0), Int.max / 2),
                lastUsedAt: min(max(entry.value.lastUsedAt, 0), SnippetFrecency.maxTimestamp)
            )
        }

        out.bindings = doc.bindings.reduce(into: [:]) { accumulated, entry in
            let key = entry.key
            guard !key.isEmpty, key.count <= SnippetFrecency.maxBindingPrefixLength else { return }
            let table = entry.value.reduce(into: [String: Double]()) { inner, pair in
                guard UUID(uuidString: pair.key) != nil,
                      pair.value.isFinite, pair.value > 0 else { return }
                inner[pair.key] = SnippetFrecency.clamp(weight: pair.value)
            }
            guard !table.isEmpty else { return }
            accumulated[key] = table
        }

        return out
    }

    // MARK: - Merge

    /// Monotone join. Every component is `max()`, never `sum()`.
    ///
    /// `sum()` is not idempotent: two processes each merging the other's file
    /// would inflate weights in unbounded feedback, and a Time Machine restore
    /// would double everything. `max()` undercounts genuinely concurrent uses,
    /// which is the right trade for a ranking hint that carries no user data.
    static func join(_ lhs: SnippetUsageRecord, _ rhs: SnippetUsageRecord) -> SnippetUsageRecord {
        SnippetUsageRecord(
            weight: max(lhs.weight, rhs.weight),
            count: max(lhs.count, rhs.count),
            lastUsedAt: max(lhs.lastUsedAt, rhs.lastUsedAt)
        )
    }

    /// Merges `mine` over whatever is on disk and writes the result atomically.
    /// Parameterized by path so the tests can run two "processes" against a
    /// temporary directory.
    @discardableResult
    static func mergeAndWrite(
        _ mine: SnippetUsageDocument,
        liveIDs: Set<UUID>?,
        now: Double = Date().timeIntervalSince1970,
        folderURL: URL = SnippetStorageLocations.usageFolderURL,
        fileURL: URL = SnippetStorageLocations.usageFileURL,
        lockURL: URL? = nil,
        lockTimeout: TimeInterval = 0.25
    ) -> Bool {
        // Defensive: normally the directory was created at launch, before the
        // library store installed its monitor on the parent.
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        // Atomic replacement prevents torn JSON, but it does not make the read/join/write
        // transaction atomic: two processes can read the same ancestor, independently add
        // A and B, then have the last rename discard the other addition. Usage data has its
        // own stable lock because it is intentionally outside the library/vault transaction.
        // Derive the test default from `folderURL` so isolated tests never touch the live lock.
        let effectiveLockURL = lockURL
            ?? folderURL.appendingPathComponent("usage.lock", isDirectory: false)
        let held: FileGuard.Held
        do {
            held = try FileGuard.acquire(at: effectiveLockURL, timeout: lockTimeout)
        } catch {
            NSLog("Snippets: could not lock usage data: \(error)")
            return false
        }
        // Unlike the library writer, this path has no compare-and-swap verification fallback.
        // Proceeding after both lock mechanisms fail would silently reintroduce lost updates.
        guard !held.isUnlocked else {
            NSLog("Snippets: no supported usage lock is available; preserving the existing file")
            return false
        }
        defer { held.release() }

        var merged = sanitized(mine)

        if let data = try? Data(contentsOf: fileURL) {
            // The store performs the same check at launch, but another (newer) process can
            // replace the file after launch and before this flush. The last responsible place
            // to fail closed is here, under the same lock as the eventual write.
            if let probe = try? JSONDecoder().decode(SnippetUsageVersionProbe.self, from: data),
               let version = probe.v,
               version > SnippetUsageDocument.currentVersion {
                return false
            }

            if let disk = try? JSONDecoder().decode(SnippetUsageDocument.self, from: data) {
                merged = joined(mine: sanitized(mine), disk: sanitized(disk))
            }
        }

        merged = pruned(merged, liveIDs: liveIDs, now: now)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let out = try? encoder.encode(merged) else { return false }

        do {
            // Atomic: the temporary file is created in `folderURL` and renamed
            // within it, so the rename touches the Usage vnode. The library
            // store watches the parent.
            try out.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            NSLog("Snippets: could not write usage data: \(error.localizedDescription)")
            return false
        }
    }

    /// Commutative, associative, and idempotent, so any interleaving of any
    /// number of writers converges.
    static func joined(mine: SnippetUsageDocument, disk: SnippetUsageDocument) -> SnippetUsageDocument {
        let epoch = max(mine.epoch, disk.epoch)
        let lhs = rescaled(mine, toEpoch: epoch, halfLifeDays: SnippetFrecency.halfLifeDays)
        let rhs = rescaled(disk, toEpoch: epoch, halfLifeDays: SnippetFrecency.halfLifeDays)

        var merged = lhs
        merged.epoch = epoch
        merged.version = SnippetUsageDocument.currentVersion

        // Reset markers are `max()` too, and the later reset displaces the
        // other side's component wholesale. Without this, "Reset Usage Data"
        // and switching selection memory off would come straight back from
        // disk on the next merge, because a join can raise but never delete.
        merged.recordsClearedAt = max(lhs.recordsClearedAt, rhs.recordsClearedAt)
        merged.bindingsClearedAt = max(lhs.bindingsClearedAt, rhs.bindingsClearedAt)

        if rhs.recordsClearedAt > lhs.recordsClearedAt {
            merged.records = rhs.records
        } else if rhs.recordsClearedAt == lhs.recordsClearedAt {
            for (key, value) in rhs.records {
                merged.records[key] = merged.records[key].map { join($0, value) } ?? value
            }
        }

        if rhs.bindingsClearedAt > lhs.bindingsClearedAt {
            merged.bindings = rhs.bindings
        } else if rhs.bindingsClearedAt == lhs.bindingsClearedAt {
            for (key, table) in rhs.bindings {
                var combined = merged.bindings[key] ?? [:]
                for (id, weight) in table {
                    combined[id] = max(combined[id] ?? 0, weight)
                }
                merged.bindings[key] = combined
            }
        }

        return merged
    }

    // MARK: - Pruning

    /// Two modes that must not be confused: decayed-away entries go on every
    /// flush, capacity trimming only when a limit is actually exceeded.
    ///
    /// There is deliberately no unconditional reconciliation against the
    /// snippet library. Deleting a snippet, flushing, then pressing ⌘Z restores
    /// the same UUID — dropping orphans eagerly would silently erase the
    /// history of a snippet the user just brought back. `liveIDs` only decides
    /// who gets evicted *first* once something has to be evicted anyway.
    static func pruned(
        _ doc: SnippetUsageDocument,
        liveIDs: Set<UUID>?,
        now: Double
    ) -> SnippetUsageDocument {
        var out = doc

        let growth = SnippetFrecency.growth(
            epoch: doc.epoch, now: now, halfLifeSeconds: max(doc.halfLifeDays, 1) * 86_400)
        let floor = SnippetFrecency.pruneThreshold * growth

        out.records = doc.records.filter { $0.value.weight >= floor }
        out.bindings = doc.bindings.reduce(into: [:]) { accumulated, entry in
            let table = entry.value.filter { $0.value >= floor }
            guard !table.isEmpty else { return }
            accumulated[entry.key] = table
        }

        if out.records.count > SnippetFrecency.maxRecords {
            let orphanIDs = (liveIDs?.isEmpty == false)
                ? Set(out.records.keys.filter { UUID(uuidString: $0).map { !liveIDs!.contains($0) } ?? true })
                : []
            let ordered = out.records.sorted { lhs, rhs in
                let lhsOrphan = orphanIDs.contains(lhs.key)
                let rhsOrphan = orphanIDs.contains(rhs.key)
                if lhsOrphan != rhsOrphan { return !lhsOrphan }
                if lhs.value.weight != rhs.value.weight { return lhs.value.weight > rhs.value.weight }
                return lhs.key < rhs.key
            }
            out.records = Dictionary(
                uniqueKeysWithValues: ordered.prefix(SnippetFrecency.maxRecords).map { ($0.key, $0.value) })
        }

        out.bindings = out.bindings.mapValues { table -> [String: Double] in
            guard table.count > SnippetFrecency.maxBindingEntriesPerKey else { return table }
            let ordered = table.sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            return Dictionary(
                uniqueKeysWithValues: ordered.prefix(SnippetFrecency.maxBindingEntriesPerKey).map { ($0.key, $0.value) })
        }

        if out.bindings.count > SnippetFrecency.maxBindingKeys {
            let ordered = out.bindings.sorted { lhs, rhs in
                let lhsSum = lhs.value.values.reduce(0, +)
                let rhsSum = rhs.value.values.reduce(0, +)
                if lhsSum != rhsSum { return lhsSum > rhsSum }
                return lhs.key < rhs.key
            }
            out.bindings = Dictionary(
                uniqueKeysWithValues: ordered.prefix(SnippetFrecency.maxBindingKeys).map { ($0.key, $0.value) })
        }

        return out
    }
}
