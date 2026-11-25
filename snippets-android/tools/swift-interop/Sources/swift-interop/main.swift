import CryptoKit
import Foundation
@testable import SnippetsCore

// swift-interop: proves byte compatibility between the Swift core (the authority) and
// the pure-Kotlin Android rebuild.
//
//   swift-interop emit <outDir> [--swift-version <text>] [--only <prefix>[,<prefix>…]]
//                               [--linux-fixtures <snippets-linux/tests/fixtures>]
//       writes <outDir>/sealed/*.json (deterministic) and <outDir>/open/*.json
//   swift-interop check <kind> [options] <file…>
//       verifies Kotlin-produced artifacts with the Swift code; one JSON line per file
//   swift-interop kinds
//
// See README.md beside Package.swift.

setvbuf(stdout, nil, _IOLBF, 0)

let allVectors: [(String, () async throws -> [VectorFile])] = [
    ("V01", { [try CryptoVectorsA.v1()] }),
    ("V02", { [try CryptoVectorsA.v2()] }),
    ("V03", { [try CryptoVectorsA.v3()] }),
    ("V04", { [try CryptoVectorsA.v4()] }),
    ("V05", { [try CryptoVectorsA.v5()] }),
    ("V06", { [try CryptoVectorsA.v6()] }),
    ("V07", { [try CryptoVectorsA.v7()] }),
    ("V08", { [try CryptoVectorsA.v8()] }),
    ("V09", { [try CryptoVectorsA.v9()] }),
    ("V10", { [try CryptoVectorsB.v10()] }),
    ("V11", { [try CryptoVectorsB.v11()] }),
    ("V12", { [try CryptoVectorsB.v12()] }),
    ("V13", { [try CryptoVectorsC.v13()] }),
    ("V14", { [try CryptoVectorsC.v14()] }),
    ("V15", { try CryptoVectorsC.backupVectors() }),
    ("V16", { try CryptoVectorsC.recoveryVectors() }),
    ("V17", { [try CryptoVectorsC.v17()] }),
    ("V18", { [try CryptoVectorsC.v18()] }),
    ("V19", { [try CryptoVectorsC.v19()] }),
    ("L01", { [try LibraryVectorsA.l1()] }),
    ("L02", { [try LibraryVectorsA.l2()] }),
    ("L03", { try LibraryVectorsA.l3() }),
    ("L04", { [try LibraryVectorsB.l4()] }),
    ("L05", { try LibraryVectorsB.l5() }),
    ("L06", { [try LibraryVectorsB.l6()] }),
    ("L07", { [try LibraryVectorsC.l7()] }),
    ("G01", { [try GitVectors.g1()] }),
    ("G02", { [try GitVectors.g2()] }),
    ("G03", { [try GitVectors.g3()] }),
    ("G04", { [try await GitLiveVectors.g4()] }),
    ("G05", { [try GitVectors.g5()] }),
    ("G06", { [try GitVectors.g6()] }),
    ("G07", { [try GitVectors.g7()] }),
]

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("swift-interop: \(message)\n".utf8))
    exit(code)
}

@MainActor func runEmit(_ arguments: [String]) async throws {
    var positional: [String] = []
    var only: [String] = []
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--swift-version":
            index += 1
            guard index < arguments.count else { fail("--swift-version needs a value") }
            VectorFile.swiftVersion = arguments[index]
        case "--linux-fixtures":
            index += 1
            guard index < arguments.count else { fail("--linux-fixtures needs a directory") }
            GitVectors.linuxFixturesDirectory = arguments[index]
        case "--only":
            index += 1
            guard index < arguments.count else { fail("--only needs a value") }
            only = arguments[index].split(separator: ",").map(String.init)
        default:
            positional.append(arguments[index])
        }
        index += 1
    }
    guard positional.count == 1 else { fail("usage: swift-interop emit <outDir>") }
    let root = URL(fileURLWithPath: positional[0], isDirectory: true)
    let fileManager = FileManager.default
    var manifest: [(String, J)] = []
    var written = 0
    var writtenNames = Set<String>()

    for (key, make) in allVectors where only.isEmpty || only.contains(where: { key.hasPrefix($0) }) {
        let files: [VectorFile]
        do { files = try await make() }
        catch { fail("\(key): \(error)", code: 1) }
        for file in files {
            if let path = J.arr(file.cases).duplicateKeyPath() {
                fail("\(file.name): an object repeats a key at cases\(path)", code: 1)
            }
            var names = Set<String>()
            for entry in file.cases {
                guard case .obj(let members) = entry, case .str(let name)? = members.first?.1,
                      names.insert(name).inserted else {
                    fail("\(file.name): duplicate or missing case name", code: 1)
                }
            }
            let folder = root.appendingPathComponent(file.direction.rawValue, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = file.data()
            let name = "\(file.name).json"
            try data.write(to: folder.appendingPathComponent(name, isDirectory: false), options: .atomic)
            written += 1
            writtenNames.insert("\(file.direction.rawValue)/\(name)")
            if file.direction == .sealed {
                manifest.append((name, .obj([
                    ("cases", .n(file.cases.count)),
                    ("sha256", .str(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())),
                ])))
            }
            print("\(file.direction.rawValue)/\(name)\t\(file.cases.count) cases")
        }
    }
    if only.isEmpty {
        // A full run owns both folders: drop vector files an earlier version wrote
        // under a name this version no longer produces.
        for folder in ["sealed", "open"] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
            where name.hasSuffix(".json") && name != "MANIFEST.json" && !writtenNames.contains("\(folder)/\(name)")
                && name.range(of: #"^[VGL][0-9]{2}"#, options: .regularExpression) != nil {
                try? fileManager.removeItem(at: url.appendingPathComponent(name))
                print("removed stale \(folder)/\(name)")
            }
        }
        let sealed = root.appendingPathComponent("sealed", isDirectory: true)
        try J.obj([
            ("format", .str("snippets-swift-interop/manifest/v1")),
            ("files", .obj(manifest.sorted { $0.0 < $1.0 })),
        ]).serialized().write(
            to: sealed.appendingPathComponent("MANIFEST.json", isDirectory: false), options: .atomic)
    }
    if let directory = GitVectors.linuxFixturesDirectory, only.isEmpty {
        GitVectors.driftReport += FixtureAudit.run(directory: directory)
    }
    for line in GitVectors.driftReport { print("drift-check\t\(line)") }
    print("wrote \(written) files under \(root.path)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: swift-interop emit <outDir> | check <kind> <file…> | kinds")
}
do {
    switch command {
    case "emit": try await runEmit(Array(arguments.dropFirst()))
    case "_placeholders": LibraryVectorsB.runPlaceholderChild()
    case "check": exit(Check.main(Array(arguments.dropFirst())))
    case "kinds":
        for (name, summary) in Check.kinds { print("\(name)\t\(summary)") }
    default: fail("unknown command \(command)")
    }
} catch {
    fail("\(error)", code: 1)
}
