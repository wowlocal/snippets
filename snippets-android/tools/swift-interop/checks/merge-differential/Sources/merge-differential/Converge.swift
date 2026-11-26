import Foundation
@testable import SnippetsCore

// "converge": two real `SyncEngine`s, one `InMemoryTransport`, the value-level library of
// `Tests/Core/SyncConflictCopyTests.swift`. Answers one question with the shipping
// engine rather than by reading it: after two devices edit one record concurrently,
// does the library reach a fixed point, or do the devices rewrite it at each other?
//
// Input:  [{"ancestor": <snippet fields>, "a": <fields>, "b": <fields>, "first": "a"|"b", "rounds": n}]
//         <fields> = {"name": <hex>, "content": <hex>, "tags": [<hex>]}
// Output: [{"a": <fields>, "b": <fields>, "backend": <fields>|null,
//           "submittedPerRound": [<records submitted in each settle round>], "states": [<text>]}]
//
// Every directory the engines touch is a fresh temporary one; nothing reads or writes the
// user's support folder (`quarantineFolderURL` and the marker are passed explicitly).

private final class ConvergeLibrary: SyncLibraryAccess {
    var envelopes: [UUID: SyncEnvelope] = [:]

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] { envelopes }

    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
        RemoteClassification(applicable: envelopes, deferredIDs: [], incompatibleVaultIDs: [])
    }

    func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
        var changed: [UUID] = []
        for envelope in incoming {
            if envelope.deleted {
                if envelopes.removeValue(forKey: envelope.id) != nil { changed.append(envelope.id) }
            } else if envelopes[envelope.id] != envelope {
                envelopes[envelope.id] = envelope
                changed.append(envelope.id)
            }
        }
        return ApplyOutcome(changedIDs: changed)
    }

    func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
}

private let convergeID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!

private func convergeEnvelope(_ object: Any?, device: String, revision: UInt64) -> SyncEnvelope {
    guard let object = object as? [String: Any], let tags = object["tags"] as? [Any] else {
        fail("malformed converge fields")
    }
    return SyncEnvelope(
        id: convergeID,
        hlc: HLC(wallMs: revision, counter: 0, device: device),
        origin: device,
        secure: false,
        deleted: false,
        fields: SyncEnvelope.Fields(
            name: text(object["name"]), keyword: "shared", content: Data(text(object["content"]).utf8),
            tags: tags.map { text($0) }, isEnabled: true, isPinned: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)))
}

private func fieldsJSON(_ envelope: SyncEnvelope?) -> String {
    guard let envelope, let fields = envelope.fields else { return "null" }
    return "{\"name\":\(hexText(fields.name)),\"content\":\"\(fields.content.hex)\","
        + "\"tags\":[\(fields.tags.map(hexText).joined(separator: ","))],"
        + "\"hlc\":\"\(envelope.hlc.string)\",\"origin\":\"\(envelope.origin)\"}"
}

private func stateText(_ state: SyncEngine.State) -> String {
    switch state {
    case .idle: return "idle"
    case .halted(let reason, _): return "halted:\(reason)"
    default: return String(describing: state).components(separatedBy: "(").first ?? "other"
    }
}

@MainActor
func runConverge(_ cases: [[String: Any]]) async -> String {
    var results: [String] = []
    for entry in cases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "merge-differential-converge-\(UUID().uuidString)", isDirectory: true)
        let directoryA = root.appendingPathComponent("a", isDirectory: true)
        let directoryB = root.appendingPathComponent("b", isDirectory: true)
        for directory in [directoryA, directoryB] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = InMemoryTransport()
        let sealer = SnippetCryptoSealer(keyring: SnippetCrypto.Keyring.generate(), scopeID: "merge-converge")
        let libraryA = ConvergeLibrary()
        let libraryB = ConvergeLibrary()
        func engine(_ library: ConvergeLibrary, _ device: String, _ directory: URL) -> SyncEngine {
            SyncEngine(
                transport: backend, library: library, sealer: sealer, device: device,
                baseURL: directory.appendingPathComponent("base.json"),
                journalURL: directory.appendingPathComponent("journal.json"),
                stateURL: directory.appendingPathComponent("state.json"),
                libraryQuarantineMarkerURL: directory.appendingPathComponent("library-quarantine"),
                quarantineFolderURL: directory.appendingPathComponent("Quarantine", isDirectory: true),
                lockURL: directory.appendingPathComponent("library.lock"),
                temporaryDirectory: directory)
        }
        let engineA = engine(libraryA, "aaaaaaa1", directoryA)
        let engineB = engine(libraryB, "bbbbbbb2", directoryB)
        var states: [String] = []

        // Shared ancestor, then the concurrent edits, exactly as `race` in the Swift suite.
        libraryA.envelopes[convergeID] = convergeEnvelope(entry["ancestor"], device: "aaaaaaa1", revision: 100)
        states.append(stateText(await engineA.sync()))
        states.append(stateText(await engineB.sync()))
        libraryA.envelopes[convergeID] = convergeEnvelope(entry["a"], device: "aaaaaaa1", revision: 200)
        libraryB.envelopes[convergeID] = convergeEnvelope(entry["b"], device: "bbbbbbb2", revision: 300)
        let first = (entry["first"] as? String) == "b" ? [engineB, engineA] : [engineA, engineB]
        for engine in first { states.append(stateText(await engine.sync())) }

        let rounds = entry["rounds"] as? Int ?? 8
        var submittedPerRound: [Int] = []
        for round in 0..<rounds {
            let before = backend.submittedBatches.reduce(0) { $0 + $1.count }
            let order = round.isMultiple(of: 2) ? [engineA, engineB] : [engineB, engineA]
            for engine in order { states.append(stateText(await engine.sync())) }
            submittedPerRound.append(backend.submittedBatches.reduce(0) { $0 + $1.count } - before)
        }

        var backendEnvelope: SyncEnvelope?
        for record in backend.snapshot where record.id == convergeID {
            backendEnvelope = try? WireCodec.open(record, using: sealer)
        }
        results.append(
            "{\"a\":\(fieldsJSON(libraryA.envelopes[convergeID])),"
                + "\"b\":\(fieldsJSON(libraryB.envelopes[convergeID])),"
                + "\"backend\":\(fieldsJSON(backendEnvelope)),"
                + "\"submittedPerRound\":[\(submittedPerRound.map(String.init).joined(separator: ","))],"
                + "\"states\":[\(Set(states).sorted().map { "\"\($0)\"" }.joined(separator: ","))]}")
    }
    return results.joined(separator: ",\n")
}
