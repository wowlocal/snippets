import CryptoKit
import Foundation
@testable import SnippetsCore

// L7: three-way merge, conflict copies, deletion guard.

enum LibraryVectorsC {

    static let id = UUID(uuidString: "ABCDEF01-1234-4000-8000-000000000001")!
    static let t0 = Date(timeIntervalSinceReferenceDate: 100)

    static func hlc(_ wall: UInt64, _ counter: UInt16 = 0, _ device: String = "aaaaaaaa") -> HLC {
        HLC(wallMs: wall, counter: counter, device: device)
    }

    static func plain(
        name: String = "Name", keyword: String = "kw", content: String = "body", tags: [String] = ["work"],
        enabled: Bool = true, pinned: Bool = false, created: Double = 100, updated: Double = 100,
        hlc clock: HLC, x: [String: CanonicalJSON.Value] = [:], id: UUID = LibraryVectorsC.id
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id, hlc: clock, origin: clock.device, secure: false, deleted: false,
            fields: SyncEnvelope.Fields(
                name: name, keyword: keyword, content: Data(content.utf8), tags: tags, isEnabled: enabled,
                isPinned: pinned, createdAt: Date(timeIntervalSinceReferenceDate: created),
                updatedAt: Date(timeIntervalSinceReferenceDate: updated)),
            x: x)
    }

    static func tomb(hlc clock: HLC, x: [String: CanonicalJSON.Value] = [:]) -> SyncEnvelope {
        .tombstone(id: id, secure: false, hlc: clock, origin: clock.device, x: x)
    }

    static func canonical(_ envelope: SyncEnvelope?) throws -> J {
        guard let envelope else { return .null }
        return utf8Text(try envelope.canonicalData())
    }

    static var linuxFixturesDirectory: String? { GitVectors.linuxFixturesDirectory }

    static func l7() throws -> VectorFile {
        var cases: [J] = []
        let base = plain(hlc: hlc(1_000))
        let localClock = hlc(2_000, 0, "aaaaaaaa")
        let remoteClock = hlc(3_000, 0, "bbbbbbbb")

        let secureA = try CryptoVectorsC.secureEnvelope(
            id: id, name: "Secret", body: Data("base secret".utf8), nonce: 0x61, hlc: hlc(1_000), origin: "aaaaaaaa")
        let secureB = try CryptoVectorsC.secureEnvelope(
            id: id, name: "Secret", body: Data("local secret".utf8), nonce: 0x62, hlc: localClock, origin: "aaaaaaaa")
        let secureC = try CryptoVectorsC.secureEnvelope(
            id: id, name: "Secret renamed", body: Data("base secret".utf8), nonce: 0x61, hlc: remoteClock, origin: "bbbbbbbb")
        let secureD = try CryptoVectorsC.secureEnvelope(
            id: id, name: "Secret", body: Data("remote secret".utf8), nonce: 0x63, hlc: remoteClock, origin: "bbbbbbbb")
        let withVariant = try SyncMerge.mergeEnvelopeOutcome(base: secureA, local: secureB, remote: secureD).survivor!

        let triples: [(String, SyncEnvelope?, SyncEnvelope?, SyncEnvelope?)] = [
            ("all-absent", nil, nil, nil),
            ("only-local", nil, plain(hlc: localClock), nil),
            ("only-remote", nil, nil, plain(hlc: remoteClock)),
            ("only-remote-with-base-is-not-a-delete", base, nil, plain(hlc: remoteClock)),
            ("identical-fields-remote-clock-higher", base, plain(hlc: localClock), plain(hlc: remoteClock)),
            ("identical-fields-local-clock-higher", base, plain(hlc: hlc(4_000)), plain(hlc: remoteClock)),
            ("identical-fields-x-union", base, plain(hlc: localClock, x: ["l": 1, "both": "local"]), plain(hlc: remoteClock, x: ["r": 2, "both": "remote"])),
            ("name-changed-locally", base, plain(name: "Local", hlc: localClock), plain(hlc: remoteClock)),
            ("name-changed-remotely", base, plain(hlc: localClock), plain(name: "Remote", hlc: remoteClock)),
            ("name-changed-both-remote-newer", base, plain(name: "Local", hlc: localClock), plain(name: "Remote", hlc: remoteClock)),
            ("name-changed-both-local-newer", base, plain(name: "Local", hlc: hlc(4_000)), plain(name: "Remote", hlc: remoteClock)),
            ("name-changed-both-to-same", base, plain(name: "Same", hlc: localClock), plain(name: "Same", hlc: remoteClock)),
            ("keyword-local-name-remote", base, plain(keyword: "lk", hlc: localClock), plain(name: "Remote", hlc: remoteClock)),
            ("keyword-changed-both", base, plain(keyword: "lk", hlc: localClock), plain(keyword: "rk", hlc: remoteClock)),
            ("enabled-local-pinned-remote", base, plain(enabled: false, hlc: localClock), plain(pinned: true, hlc: remoteClock)),
            ("enabled-toggled-both-ways", plain(enabled: false, hlc: hlc(1_000)), plain(enabled: true, hlc: localClock), plain(enabled: false, pinned: true, hlc: remoteClock)),
            ("tags-added-each-side", base, plain(tags: ["work", "local"], hlc: localClock), plain(tags: ["work", "remote"], hlc: remoteClock)),
            ("tags-removed-locally-added-remotely", plain(tags: ["a", "b", "c"], hlc: hlc(1_000)), plain(tags: ["a", "c"], hlc: localClock), plain(tags: ["a", "b", "c", "d"], hlc: remoteClock)),
            ("tags-respelled", plain(tags: ["work", "Café"], hlc: hlc(1_000)), plain(tags: ["WORK", "Café"], hlc: localClock), plain(tags: ["work", "cafe"], hlc: remoteClock)),
            ("tags-reordered-only", plain(tags: ["a", "b"], hlc: hlc(1_000)), plain(tags: ["b", "a"], hlc: localClock), plain(name: "Remote", tags: ["a", "b"], hlc: remoteClock)),
            ("tags-no-base", nil, plain(tags: ["x", "Shared"], hlc: localClock), plain(tags: ["shared", "y"], hlc: remoteClock)),
            ("tags-added-sorted-by-key", base, plain(tags: ["work", "zeta", "Alpha"], hlc: localClock), plain(tags: ["work", "émile", "beta"], hlc: remoteClock)),
            ("dates-min-created-max-updated", base, plain(name: "Local", created: 50, updated: 300, hlc: localClock), plain(created: 80, updated: 200, hlc: remoteClock)),
            ("content-changed-locally", base, plain(content: "local body", hlc: localClock), plain(name: "Remote", hlc: remoteClock)),
            ("content-changed-remotely", base, plain(name: "Local", hlc: localClock), plain(content: "remote body", hlc: remoteClock)),
            ("content-changed-both-to-same", base, plain(content: "same", hlc: localClock), plain(content: "same", hlc: remoteClock)),
            ("content-conflict-remote-wins", base, plain(content: "local body", updated: 200, hlc: localClock), plain(content: "remote body", updated: 300, hlc: remoteClock)),
            ("content-conflict-local-wins", base, plain(content: "local body", updated: 200, hlc: hlc(4_000)), plain(content: "remote body", updated: 300, hlc: remoteClock)),
            ("content-conflict-no-base", nil, plain(content: "local body", hlc: localClock), plain(content: "remote body", hlc: remoteClock)),
            ("content-conflict-equal-hlc-payload-rank", base, plain(content: "local body", hlc: hlc(5_000, 1, "cccccccc")), plain(content: "remote body", hlc: hlc(5_000, 1, "cccccccc"))),
            ("content-conflict-loser-unnamed", base, plain(name: "", content: "first line\nsecond", updated: 120, hlc: localClock), plain(content: "remote body", hlc: remoteClock)),
            ("content-conflict-loser-has-x-and-conflict-tag", base, plain(content: "local body", tags: ["Conflict", "work"], hlc: localClock, x: ["future": ["k": 1]]), plain(content: "remote body", hlc: remoteClock)),
            ("delete-local-edit-remote", base, tomb(hlc: localClock), plain(name: "Remote", hlc: remoteClock)),
            ("delete-local-unchanged-remote", base, tomb(hlc: localClock), base),
            ("edit-local-delete-remote", base, plain(name: "Local", hlc: localClock), tomb(hlc: remoteClock)),
            ("unchanged-local-delete-remote", base, base, tomb(hlc: remoteClock)),
            ("delete-both-higher-clock-wins", base, tomb(hlc: localClock), tomb(hlc: remoteClock)),
            ("delete-local-live-remote-no-base", nil, tomb(hlc: localClock), plain(hlc: remoteClock)),
            ("delete-both-no-base", nil, tomb(hlc: hlc(9_000)), tomb(hlc: remoteClock)),
            ("recreate-after-delete", tomb(hlc: hlc(1_000)), plain(name: "Again", hlc: localClock), tomb(hlc: hlc(1_000))),
            ("secure-rename-remote-body-local", secureA, secureB, secureC),
            ("secure-both-bodies-changed", secureA, secureB, secureD),
            ("secure-variant-then-delete-refused", withVariant, withVariant, tomb(hlc: hlc(9_000))),
            ("promotion-versus-plain-edit", plain(name: "Secret", keyword: "wifi", content: "plain body", tags: ["home"], enabled: true, pinned: true, created: Fixture.created.timeIntervalSinceReferenceDate, updated: Fixture.updated.timeIntervalSinceReferenceDate, hlc: hlc(1_000)),
             plain(name: "Secret", keyword: "wifi", content: "edited plain body", tags: ["home"], enabled: true, pinned: true, created: Fixture.created.timeIntervalSinceReferenceDate, updated: Fixture.updated.timeIntervalSinceReferenceDate, hlc: localClock), secureD),
        ]
        for (name, baseValue, local, remote) in triples {
            var members: [(String, J)] = [
                ("kind", .str("merge-envelope")),
                ("base", try canonical(baseValue)),
                ("local", try canonical(local)),
                ("remote", try canonical(remote)),
            ]
            do {
                let outcome = try SyncMerge.mergeEnvelopeOutcome(base: baseValue, local: local, remote: remote)
                let mirrored = try SyncMerge.mergeEnvelopeOutcome(base: baseValue, local: remote, remote: local)
                members += [
                    ("survivor", try canonical(outcome.survivor)),
                    ("survivorHash", .opt(try outcome.survivor?.envelopeHash())),
                    ("conflictCopies", .arr(try outcome.conflictCopies.map(canonical))),
                    ("mirroredGivesSameResult", .bool(
                        mirrored.survivor == outcome.survivor && mirrored.conflictCopies == outcome.conflictCopies)),
                ]
            } catch {
                members.append(("error", .str(errorName(error))))
            }
            cases.append(vcase("merge-\(name)", members))
        }

        // Plain conflict copies, in the shape of snippets-linux/tests/fixtures/conflict-copy-v1.json.
        let sources: [(String, SyncEnvelope)] = [
            ("named", plain(content: "Fictional lost body 🦀\n", updated: 120, hlc: hlc(120_000, 2))),
            ("unnamed-uses-first-line", plain(name: "  ", content: "\n  first line  \nsecond", updated: 59.999, hlc: localClock)),
            ("unnamed-empty-body", plain(name: "", content: "", updated: 0, hlc: localClock)),
            ("long-first-line", plain(name: "", content: String(repeating: "x", count: 60), updated: 86_399.5, hlc: localClock)),
            ("already-tagged-conflict", plain(tags: ["CONFLICT", "a"], updated: 978_307_200, hlc: localClock)),
            ("with-extensions", plain(hlc: localClock, x: ["future": 1, "conflictCopy.v1": ["version": 1, "sourceID": .string(lower(Fixture.uuidA)), "fingerprint": .string(String(repeating: "ab", count: 32))]])),
            ("pre-2001-date", plain(updated: -86_400.5, hlc: localClock)),
            ("pinned-disabled-with-keyword", plain(keyword: "kw", enabled: false, pinned: true, hlc: localClock)),
        ]
        for (name, source) in sources {
            let copy = try SyncMerge.makePlainContentConflictCopy(from: source)
            let provenance = SyncMerge.conflictCopyProvenance(in: copy)
            try require(SyncMerge.hasValidConflictCopyIdentity(copy), "L7 copy \(name) identity")
            cases.append(vcase("conflict-copy-\(name)", [
                ("kind", .str("conflict-copy")),
                ("source", try canonical(source)),
                ("copy", try canonical(copy)),
                ("copyID", .str(lower(copy.id))),
                ("fingerprint", .opt(provenance?.fingerprint)),
                ("copyName", .opt(copy.fields?.name)),
            ]))
        }
        if let directory = linuxFixturesDirectory,
           let data = try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("conflict-copy-v1.json")),
           let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let vectors = root["vectors"] as? [[String: Any]] {
            var matches = 0
            for vector in vectors {
                guard let source = vector["source"] as? String, let expected = vector["copy"] as? String,
                      let envelope = try? SyncEnvelope.parse(Data(source.utf8)),
                      let copy = try? SyncMerge.makePlainContentConflictCopy(from: envelope),
                      let text = try? String(decoding: copy.canonicalData(), as: UTF8.self) else { continue }
                if text == expected, lower(copy.id) == vector["copyID"] as? String { matches += 1 }
            }
            GitVectors.driftReport.append(matches == vectors.count
                ? "conflict-copy-v1.json: current Swift reproduces all \(vectors.count) checked-in vectors"
                : "conflict-copy-v1.json: DRIFT, only \(matches) of \(vectors.count) checked-in vectors reproduced")
        }

        // Scalar and tag rules directly.
        for (index, (baseValue, local, remote, localWins)) in [
            ("b" as String?, "b", "b", true), ("b", "l", "b", true), ("b", "b", "r", true), ("b", "l", "r", true),
            ("b", "l", "r", false), (nil, "l", "r", true), (nil, "l", "r", false), (nil, "s", "s", false), ("b", "s", "s", true),
        ].enumerated() {
            cases.append(vcase("scalar-\(index)", [
                ("kind", .str("mergeScalar")),
                ("base", .opt(baseValue)), ("local", .str(local)), ("remote", .str(remote)),
                ("localWins", .bool(localWins)),
                ("merged", .str(SyncMerge.mergeScalar(baseValue, local, remote, localWins: localWins))),
            ]))
        }
        for (index, (baseValue, local, remote)) in [
            (["a", "b"] as [String]?, ["a", "b"], ["a", "b"]), (["a", "b"], ["a"], ["a", "b", "c"]),
            (["a", "b"], ["b", "a"], ["a", "b"]), (["a"], ["A"], ["a", "x"]), (["a"], ["a", "Z", "m"], ["a", "É", "b"]),
            (nil, ["x", "Shared"], ["shared", "y"]), (nil, [], ["only"]), (["a", "b", "c"], [], ["a", "b", "c"]),
            (["a"], ["a", "new"], ["a", "NEW"]), (["Café"], ["cafe"], ["CAFÉ"]), ([], ["l"], ["r"]),
            (["dup", "DUP"], ["dup"], ["dup", "x"]),
        ].enumerated() {
            for localWins in [true, false] {
                cases.append(vcase("tags-\(index)-\(localWins ? "local" : "remote")-wins", [
                    ("kind", .str("mergeTags")),
                    ("base", baseValue.map { .strings($0) } ?? .null), ("local", .strings(local)), ("remote", .strings(remote)),
                    ("localWins", .bool(localWins)),
                    ("merged", .strings(SyncMerge.mergeTags(baseValue, local, remote, localWins: localWins))),
                ]))
            }
        }

        // The local-file merge (Snippet arrays, no envelopes).
        func snippet(
            _ number: Int, name: String = "n", keyword: String = "", content: String = "c", tags: [String] = [],
            enabled: Bool = true, pinned: Bool = false, updated: Double = 100
        ) -> Snippet {
            Snippet(
                id: UUID(uuidString: String(format: "10CA1000-0000-4000-8000-%012X", number))!, name: name,
                keyword: keyword, content: content, tags: tags, isEnabled: enabled, isPinned: pinned,
                createdAt: t0, updatedAt: Date(timeIntervalSinceReferenceDate: updated))
        }
        let localScenarios: [(String, [Snippet], [Snippet], [Snippet])] = [
            ("independent-edits", [snippet(1), snippet(2)], [snippet(1, name: "L"), snippet(2)], [snippet(1), snippet(2, name: "R", updated: 200)]),
            ("add-on-each-side", [snippet(1)], [snippet(1), snippet(2, name: "local add")], [snippet(3, name: "remote add"), snippet(1)]),
            ("delete-local-edit-remote", [snippet(1)], [], [snippet(1, name: "R", updated: 200)]),
            ("delete-local-unchanged-remote", [snippet(1), snippet(2)], [snippet(2)], [snippet(1), snippet(2)]),
            ("delete-remote-unchanged-local", [snippet(1), snippet(2)], [snippet(1), snippet(2)], [snippet(2)]),
            ("content-conflict-remote-newer", [snippet(1)], [snippet(1, content: "local", updated: 200)], [snippet(1, content: "remote", updated: 300)]),
            ("content-conflict-local-newer", [snippet(1)], [snippet(1, content: "local", updated: 400)], [snippet(1, content: "remote", updated: 300)]),
            ("content-conflict-same-time-digest-rank", [snippet(1)], [snippet(1, content: "local", updated: 300)], [snippet(1, content: "remote", updated: 300)]),
            ("keyword-collision-after-merge", [snippet(1, keyword: "a"), snippet(2, keyword: "b")],
             [snippet(1, keyword: "sig", updated: 200), snippet(2, keyword: "b")], [snippet(1, keyword: "a"), snippet(2, keyword: "SIG", updated: 300)]),
            ("keyword-collision-untouched-pair-left-alone", [snippet(1, keyword: "dup"), snippet(2, keyword: "DUP")],
             [snippet(1, keyword: "dup"), snippet(2, keyword: "DUP")], [snippet(1, keyword: "dup"), snippet(2, keyword: "DUP"), snippet(3, name: "new")]),
            ("no-base-same-id-differs", [], [snippet(1, name: "L", content: "l", updated: 200)], [snippet(1, name: "R", content: "r", updated: 300)]),
        ]
        for (name, baseList, local, remote) in localScenarios {
            let outcome = SyncMerge.mergeLocal(base: baseList, local: local, remote: remote)
            cases.append(vcase("merge-local-\(name)", [
                ("kind", .str("merge-local")),
                ("base", .arr(baseList.map(snippetJ))),
                ("local", .arr(local.map(snippetJ))),
                ("remote", .arr(remote.map(snippetJ))),
                ("snippets", .arr(outcome.snippets.map(snippetJ))),
                ("conflictCopies", .arr(outcome.conflictCopies.map(snippetJ))),
                ("disabledByKeywordCollision", .strings(outcome.disabledByKeywordCollision.map(lower))),
                ("needsUserAttention", .bool(outcome.needsUserAttention)),
            ]))
        }
        for (index, value) in [
            snippet(1), snippet(1, name: "ab", keyword: "c"), snippet(1, name: "a", keyword: "bc"),
            snippet(1, tags: ["a", "b"]), snippet(1, tags: ["a\u{1}b"]), snippet(1, name: "Café ☕", content: "🔑", enabled: false, pinned: true),
        ].enumerated() {
            cases.append(vcase("payload-digest-\(index)", [
                ("kind", .str("payloadDigest")),
                ("snippet", snippetJ(value)),
                ("digest", .str(SyncMerge.payloadDigest(value))),
            ]))
        }

        // Deletion guard.
        for live in [0, 1, 4, 5, 6, 24, 25, 26, 27, 29, 30, 31, 34, 35, 36, 49, 50, 51, 99, 100, 101, 1_000, 100_000, -1] {
            let allowed = DeletionGuard.allowedDeletions(liveCount: live)
            cases.append(vcase("allowed-deletions-\(live)", [
                ("kind", .str("allowedDeletions")),
                ("liveCount", .n(live)),
                ("allowedDeletions", .n(allowed)),
                ("atLimit", .str(String(describing: DeletionGuard.evaluate(liveCount: live, deletions: allowed).isAllowed))),
                ("oneOverLimit", .str(String(describing: DeletionGuard.evaluate(liveCount: live, deletions: allowed + 1).isAllowed))),
            ]))
        }
        for (live, deletions) in [(0, 0), (0, 5), (0, 6), (3, 3), (3, 6), (10, 5), (10, 6), (10, 10), (30, 6), (30, 7), (100, 20), (100, 21), (1, 1)] {
            let decision = DeletionGuard.evaluate(liveCount: live, deletions: deletions)
            cases.append(vcase("evaluate-\(live)-\(deletions)", [
                ("kind", .str("evaluate")),
                ("liveCount", .n(live)),
                ("deletions", .n(deletions)),
                ("allowed", .bool(decision.isAllowed)),
                ("refusal", decision.refusal.map { refusal in
                    .obj([
                        ("liveCount", .n(refusal.liveCount)), ("requestedDeletions", .n(refusal.requestedDeletions)),
                        ("allowedDeletions", .n(refusal.allowedDeletions)),
                        ("requestedFraction", .double(refusal.requestedFraction)),
                        ("description", .str(refusal.description)),
                    ])
                } ?? .null),
            ]))
        }
        let liveIDs = (1...10).map { UUID(uuidString: String(format: "DE1E7E00-0000-4000-8000-%012X", $0))! }
        let outside = UUID(uuidString: "0FF51DE0-0000-4000-8000-000000000001")!
        for (name, deleting) in [
            ("five-of-ten", Array(liveIDs.prefix(5))), ("six-of-ten", Array(liveIDs.prefix(6))),
            ("six-with-duplicates-and-unknown-ids", Array(liveIDs.prefix(5)) + [liveIDs[0], outside, outside]),
            ("all-ten", liveIDs), ("none", []),
        ] {
            let decision = DeletionGuard.evaluate(live: Set(liveIDs), deleting: deleting)
            let resulting = Set(liveIDs).subtracting(deleting)
            let facts = SyncDeletionSafety.facts(liveIDs: Set(liveIDs), resultingLiveIDs: resulting)
            let review = SyncDeletionSafety.review(liveIDs: Set(liveIDs), resultingLiveIDs: resulting)
            cases.append(vcase("evaluate-ids-\(name)", [
                ("kind", .str("evaluate-ids")),
                ("live", .strings(liveIDs.map(lower))),
                ("deleting", .strings(deleting.map(lower))),
                ("allowed", .bool(decision.isAllowed)),
                ("facts", facts.map { .obj([
                    ("liveCount", .n($0.liveCount)), ("requestedDeletions", .n($0.requestedDeletions)),
                    ("batchFingerprint", .str($0.batchFingerprint)),
                ]) } ?? .null),
                ("reviewRequired", .bool(review != nil)),
            ]))
        }
        for (name, ids) in [
            ("linux-fixture-id", [UUID(uuidString: "abcdef01-1234-4000-8000-000000000001")!]),
            ("three-ids", [Fixture.uuidB, Fixture.uuidA, Fixture.uuidD]), ("empty", [UUID]()),
        ] {
            let material = ids.map(\.uuidString).sorted().joined(separator: "\n")
            cases.append(vcase("deletion-fingerprint-\(name)", [
                ("kind", .str("deletionFingerprint")),
                ("ids", .strings(ids.map(lower))),
                ("preimageText", .str(material)),
                ("fingerprint", .str(SyncDeletionSafety.fingerprint(ids: Set(ids)))),
            ]))
        }
        if let directory = linuxFixturesDirectory,
           let data = try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("merge-v1.json")),
           let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ids = (root["deletionIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            let fingerprintMatches = SyncDeletionSafety.fingerprint(ids: Set(ids)) == root["deletionFingerprint"] as? String
            let snapshot = root["snapshotCanonical"] as? String ?? ""
            let snapshotMatches = sha256Hex(Data(snapshot.utf8)) == root["fingerprint"] as? String
            var copyMatches = false
            if let object = try? CanonicalJSON.value(Data(snapshot.utf8)).object, let source = object["sourceID"]?.text,
               let namespace = UUID(uuidString: source), let fingerprint = root["fingerprint"] as? String {
                copyMatches = lower(SyncMerge.deterministicUUID(
                    namespace: namespace, name: "sync-content-conflict-v1|\(fingerprint)")) == root["copyID"] as? String
            }
            GitVectors.driftReport.append(fingerprintMatches && snapshotMatches && copyMatches
                ? "merge-v1.json: current Swift reproduces the snapshot fingerprint, copy id and deletion fingerprint"
                : "merge-v1.json: DRIFT (deletion \(fingerprintMatches), snapshot \(snapshotMatches), copy id \(copyMatches))")
        }
        return VectorFile(
            name: "L07-merge",
            pins: "SyncMerge.mergeEnvelopeOutcome for each field rule, plain conflict copies, mergeScalar / mergeTags, SyncMerge.mergeLocal, payloadDigest, DeletionGuard and SyncDeletionSafety (brief 01 §4 Three-way merge, Conflict copies, Deletion guard)",
            notes: [
                "Envelopes are given as canonical ten-key JSON text (parse it with the canonical parser; dates are doubles since 2001). null is an absent record.",
                "Every merge-* case is also run with local and remote swapped; mirroredGivesSameResult records whether the outcome is identical (the merge is meant to be symmetric).",
                "conflict-copy-* has the shape of snippets-linux/tests/fixtures/conflict-copy-v1.json (source, copy, copyID, fingerprint). The copy name is \"<displayName> (conflict yyyy-MM-dd HH:mm UTC)\", en_US_POSIX, UTC.",
                "merge-local-* is the local-file merge over Snippet arrays (SyncMerge.mergeLocal); its conflict-copy id is deterministicUUID(record id, \"conflict|\" + loser.content + \"|\" + loser updatedAt in ms since 1970).",
                "allowedDeletions = max(5, (2 × max(0, liveCount) + 9) / 10) with integer division; a batch is refused only when deletions exceed it.",
                "deletion fingerprint = SHA-256 over the UPPERCASE UUID strings, sorted, joined with LF.",
            ],
            cases: cases)
    }
}
