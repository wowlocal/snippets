// Generates tests/fixtures/git-plain-v1.json from the Apple reference
// (snippets/Core/Git/GitPlainText.swift, GitSyncTransport.swift's layout and
// manifest, SnippetTagging) without modifying it. Development only; Cargo
// reads only the checked-in JSON.
//
// Run from a scratch SwiftPM package outside the repository:
//
//   Package.swift:  .package(path: "<checkout>/CorePackage"), and an
//                   executableTarget depending on product "SnippetsCore"
//                   (swiftLanguageMode .v5)
//   Sources/PlainVectors/main.swift: this file
//   xcrun swift build && .build/debug/PlainVectors > tests/fixtures/git-plain-v1.json
//
// `@testable import` works because SwiftPM builds the dependency with
// testability in debug.
import Foundation
@testable import SnippetsCore

// Prints tests/fixtures/git-plain-v1.json for snippets-linux: what the Apple
// reference (GitPlainSnippetFile, GitSyncLayout, GitSyncManifest,
// SnippetTagging) produces for a fixed set of inputs.

func envelope(
    _ id: String = "617a0002-0000-4000-8000-000000000002", name: String = "Greeting", keyword: String = "hi",
    content: String = "Hello there!", tags: [String] = ["work"], enabled: Bool = true, pinned: Bool = false,
    created: Double = 800_000_000.125, updated: Double = 810_000_000.5,
    wall: UInt64 = 1_786_579_200_000, counter: UInt16 = 3, device: String = "a1b2c3d4",
    x: [String: CanonicalJSON.Value] = [:]
) -> SyncEnvelope {
    SyncEnvelope(
        id: UUID(uuidString: id)!, hlc: HLC(wallMs: wall, counter: counter, device: device), origin: device,
        secure: false, deleted: false,
        fields: SyncEnvelope.Fields(
            name: name, keyword: keyword, content: Data(content.utf8), tags: tags, isEnabled: enabled,
            isPinned: pinned, createdAt: Date(timeIntervalSinceReferenceDate: created),
            updatedAt: Date(timeIntervalSinceReferenceDate: updated)),
        x: x)
}

func canonical(_ envelope: SyncEnvelope) -> String {
    String(decoding: try! envelope.canonicalData(), as: UTF8.self)
}

var renders: [[String: Any]] = []
var reads: [[String: Any]] = []
var readInputs: [(String, String, Data)] = []  // (label, path, bytes)

let renderCases: [(String, SyncEnvelope)] = [
    ("basic", envelope()),
    ("multi-line", envelope(content: "two\nlines\n")),
    ("empty", envelope(content: "")),
    ("non-ascii", envelope(content: "тест 🙂 Grüße – 日本語")),
    ("trailing-blank", envelope(content: "trailing blank\n\n")),
    ("dashes", envelope(content: "---\nnot a header")),
    ("crlf-body", envelope(content: "a\r\nb\r\n")),
    ("newline-only", envelope(content: "\n")),
    ("escaped-metadata", envelope(
        "617a0003-0000-4000-8000-000000000003", name: "Say \"hi\"\\ \n\t\u{01}/", keyword: "",
        tags: ["b", "A", "c d"], enabled: false, pinned: true)),
    ("numbers", envelope(
        "617a0004-0000-4000-8000-000000000004", name: "Numbers", created: -0.0, updated: 1e-7)),
    ("large-numbers", envelope(
        "617a0005-0000-4000-8000-000000000005", name: "Large", created: 0.0001,
        updated: 12_345_678_901_234_567_890.0)),
    ("extensions", envelope(
        "617a0006-0000-4000-8000-000000000006", name: "Extensions", counter: 0xFFFF,
        x: ["future": .object(["a": .array([.int(1), .double(2.5), .string("s"), .bool(true), .null])]),
            "zz": .string("é")])),
    ("unicode-name", envelope(
        "617a0007-0000-4000-8000-000000000007", name: "Привет мир", keyword: "привет", tags: ["Работа"])),
    ("carriage-return-end", envelope("617a0008-0000-4000-8000-000000000008", name: "CR", content: "x\r")),
    ("foreign-origin", envelope(
        "617a0009-0000-4000-8000-000000000009", name: "Hello, World!", wall: 0, counter: 0, device: "00000000")),
]

for (label, value) in renderCases {
    let fileName = GitPlainSnippetFile.fileName(name: value.fields!.name, id: value.id)
    guard let data = try? GitPlainSnippetFile.render(value) else {
        renders.append(["label": label, "envelope": canonical(value), "fileName": fileName, "markdown": NSNull()])
        continue
    }
    renders.append([
        "label": label, "envelope": canonical(value), "fileName": fileName,
        "markdown": data.base64EncodedString(),
    ])
    readInputs.append(("render:\(label)", "snippets/\(fileName)", data))
}

let base = try GitPlainSnippetFile.render(envelope())
let baseText = String(decoding: base, as: UTF8.self)
func edited(_ label: String, _ transform: (String) -> String, path: String = "snippets/greeting-617a0002.md") {
    readInputs.append((label, path, Data(transform(baseText).utf8)))
}
func raw(_ label: String, _ path: String, _ text: String) { readInputs.append((label, path, Data(text.utf8))) }
func bytes(_ label: String, _ path: String, _ data: Data) { readInputs.append((label, path, data)) }

edited("edit-body") { $0.replacingOccurrences(of: "Hello there!", with: "Hello, edited on GitHub") }
edited("edit-apple-test") {
    $0.replacingOccurrences(of: "Hello there!", with: "Hello, edited on GitHub")
        .replacingOccurrences(of: "name: \"Greeting\"", with: "name: Greeting edited")
        .replacingOccurrences(of: "tags: [\"work\"]", with: "tags: [work, Mail]")
        .replacingOccurrences(of: "\n", with: "\r\n")
}
edited("crlf-only") { $0.replacingOccurrences(of: "\n", with: "\r\n") }
edited("no-final-newline") { String($0.dropLast()) }
edited("extra-final-newline") { $0 + "\n" }
edited("edit-keyword-unicode") { $0.replacingOccurrences(of: "keyword: \"hi\"", with: "keyword: \"h\\u00e9llo\"") }
edited("edit-tags-tricky") {
    $0.replacingOccurrences(
        of: "tags: [\"work\"]",
        with: "tags: [\"Work\", \"work\", \"  a   b \", \"Ａ\", \"A\", \"ß\", \"SS\", \"ss\", \"É\", \"e\", \"ﬁ\", \"fi\", \"İ\", \"i\", \"ı\", \"Σ\", \"σ\", \"ς\", \"ø\", \"o\", \"Å\", \"Å\", \"\", \" \", \"x\\ty\", \"ǅ\", \"ǆ\"]")
}
edited("edit-tags-bare-mixed") { $0.replacingOccurrences(of: "tags: [\"work\"]", with: "tags: [a, \"b, c\", d,, 'e''f' ]") }
edited("edit-tags-empty") { $0.replacingOccurrences(of: "tags: [\"work\"]", with: "tags:") }
edited("edit-tags-bare-no-brackets") { $0.replacingOccurrences(of: "tags: [\"work\"]", with: "tags: one,  two , one") }
edited("edit-tags-json-nonstring") { $0.replacingOccurrences(of: "tags: [\"work\"]", with: "tags: [\"a\", 1]") }
edited("edit-flags") {
    $0.replacingOccurrences(of: "enabled: true", with: "ENABLED: Off")
        .replacingOccurrences(of: "pinned: false", with: "pinned: YES")
}
edited("bad-bool") { $0.replacingOccurrences(of: "pinned: false", with: "pinned: maybe") }
edited("no-colon") { $0.replacingOccurrences(of: "pinned: false", with: "pinned false") }
edited("unknown-key-and-comments") {
    $0.replacingOccurrences(of: "pinned: false\n", with: "pinned: false\n\n# a comment\ncolor: blue\n  \t\n")
}
edited("indented-keys") {
    $0.replacingOccurrences(of: "name: ", with: "  \tName :  ")
        .replacingOccurrences(of: "keyword: ", with: "\u{00A0}keyword:\u{3000}")
}
edited("single-quoted-name") { $0.replacingOccurrences(of: "name: \"Greeting\"", with: "name: 'It''s ''here'''") }
edited("quoted-trailing") { $0.replacingOccurrences(of: "name: \"Greeting\"", with: "name: \"Greeting\" extra") }
edited("lone-quote") { $0.replacingOccurrences(of: "name: \"Greeting\"", with: "name: '") }
edited("duplicate-key") { $0.replacingOccurrences(of: "keyword: \"hi\"", with: "keyword: \"hi\"\nkeyword: second") }
edited("id-uppercase-quoted") {
    $0.replacingOccurrences(of: "id: 617a0002-0000-4000-8000-000000000002", with: "id: '617A0002-0000-4000-8000-000000000002'")
}
edited("id-braced") {
    $0.replacingOccurrences(of: "id: 617a0002-0000-4000-8000-000000000002", with: "id: {617a0002-0000-4000-8000-000000000002}")
}
edited("id-simple") {
    $0.replacingOccurrences(of: "id: 617a0002-0000-4000-8000-000000000002", with: "id: 617a00020000400080000000000000002")
}
edited("id-removed") { $0.replacingOccurrences(of: "id: 617a0002-0000-4000-8000-000000000002\n", with: "") }
edited("sync-removed") {
    $0.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("sync: ") }.joined(separator: "\n")
}
edited("sync-corrupt") { $0.replacingOccurrences(of: "sync: ey", with: "sync: !!ey") }
edited("sync-truncated") {
    $0.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.hasPrefix("sync: ") ? String($0.dropLast(5)) : String($0)
    }.joined(separator: "\n")
}
edited("sync-padded") {
    $0.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard line.hasPrefix("sync: ") else { return String(line) }
        var value = String(line.dropFirst(6))
        while value.count % 4 != 0 { value += "=" }
        return "sync: \(value)"
    }.joined(separator: "\n")
}
edited("unclosed") {
    $0.replacingOccurrences(of: "\n---\nHello there!\n", with: "\nHello there!\n")
}
edited("open-with-spaces") { "---  \t" + $0.dropFirst(3) }
edited("bom") { "\u{FEFF}" + $0 }
edited("colon-combining") { $0.replacingOccurrences(of: "pinned: false", with: "pinned:\u{0301} false") }
edited("hash-combining-comment") { $0.replacingOccurrences(of: "pinned: false\n", with: "pinned: false\n#\u{0301}comment\n") }
edited("bom-front-matter") { "\u{FEFF}" + $0 }
edited("bom-crlf") { "\u{FEFF}" + $0.replacingOccurrences(of: "\n", with: "\r\n") }
edited("crlf-closing-only") { $0.replacingOccurrences(of: "\n---\nHello", with: "\n---\r\nHello").replacingOccurrences(of: "Hello there!\n", with: "Hello there!\r\n") }
edited("crlf-body-lf-closing") { $0.replacingOccurrences(of: "Hello there!\n", with: "Hello there!\r\n") }
edited("yaml-tags") { $0.replacingOccurrences(of: "tags: [\"work\"]", with: "tags:\n  - work\n- 'Mail'\n  -\n  - \"x, y\"\n -Home") }
edited("yaml-tags-then-key") { $0.replacingOccurrences(of: "tags: [\"work\"]\nenabled: true", with: "tags:\nenabled: true\n- stray") }
edited("bool-digits") { $0.replacingOccurrences(of: "enabled: true", with: "enabled: 0").replacingOccurrences(of: "pinned: false", with: "pinned: 1") }
edited("id-invalid-ignored") { $0.replacingOccurrences(of: "id: 617a0002-0000-4000-8000-000000000002", with: "id: not-a-uuid") }
edited("id-twice-last-invalid") { $0.replacingOccurrences(of: "id: 617a0002-0000-4000-8000-000000000002", with: "id: 617a0002-0000-4000-8000-000000000002\nid: nope") }
edited("id-changed") { $0.replacingOccurrences(of: "id: 617a0002-0000-4000-8000-000000000002", with: "id: 617a0bbb-0000-4000-8000-000000000bbb") }
edited("unclosed-with-id") { $0.replacingOccurrences(of: "\n---\nHello there!\n", with: "\nHello there!\n") }
edited("unclosed-crlf-with-id") { $0.replacingOccurrences(of: "\n---\nHello there!\n", with: "\nHello there!\n").replacingOccurrences(of: "\n", with: "\r\n") }
edited("unclosed-uppercase-id") { $0.replacingOccurrences(of: "\n---\nHello there!\n", with: "\nHello\n").replacingOccurrences(of: "id: 617a0002", with: "  ID:  '617A0002").replacingOccurrences(of: "000000000002\n", with: "000000000002'\n") }
// Unparseable front matter is matched by a byte-line scan: a parseable `sync`
// line first, else the first valid `id` line.
func unclosed(_ text: String) -> String { text.replacingOccurrences(of: "\n---\nHello there!\n", with: "\nHello there!\n") }
func syncLine(_ text: String, _ change: (String) -> String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        line.hasPrefix("sync: ") ? change(String(line)) : String(line)
    }.joined(separator: "\n")
}
let otherIDLine = "id: 617a0bbb-0000-4000-8000-000000000bbb"
let idLine = "id: 617a0002-0000-4000-8000-000000000002"
edited("unclosed-id-changed") { unclosed($0).replacingOccurrences(of: idLine, with: otherIDLine) }
edited("unclosed-crlf-id-changed") {
    unclosed($0).replacingOccurrences(of: idLine, with: otherIDLine).replacingOccurrences(of: "\n", with: "\r\n")
}
edited("unclosed-sync-corrupt") {
    syncLine(unclosed($0).replacingOccurrences(of: idLine, with: otherIDLine)) { "sync: !!" + $0.dropFirst(6) }
}
edited("unclosed-sync-uppercase-key") {
    syncLine(unclosed($0).replacingOccurrences(of: idLine, with: otherIDLine)) { " \tSYNC:\t " + $0.dropFirst(6) + " " }
}
edited("unclosed-sync-only") { unclosed($0).replacingOccurrences(of: idLine + "\n", with: "") }
edited("unclosed-sync-first") {
    let lines = unclosed($0).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let sync = lines.first { $0.hasPrefix("sync: ") }!
    return lines.filter { $0 != sync }.map { $0 == "---" ? "---\n\(sync)" : $0 }.joined(separator: "\n")
        .replacingOccurrences(of: idLine, with: otherIDLine)
}
edited("unclosed-line-separator-id") {
    syncLine(unclosed($0), { _ in "sync: !!" }).replacingOccurrences(of: "\n" + idLine, with: "\n\u{2028}" + otherIDLine)
}
edited("unclosed-invalid-then-valid-id") {
    syncLine(unclosed($0), { _ in "" }).replacingOccurrences(of: idLine, with: "id: nope\n" + otherIDLine)
}
edited("unclosed-after-closing-line") {
    syncLine(unclosed($0), { _ in "" }).replacingOccurrences(of: idLine, with: "---\n" + otherIDLine)
}
edited("sync-and-id-line-swap") {
    syncLine($0.replacingOccurrences(of: idLine, with: otherIDLine), { $0 })
}
edited("opening-indented") { "  " + $0 }
edited("opening-trailing-text") { $0.replacingOccurrences(of: "---\nname", with: "--- x\nname") }
edited("body-with-separators") { $0.replacingOccurrences(of: "Hello there!", with: "---\nname: inner\n---\n") }

// The sync metadata itself, varied: a counter at its maximum, a newer schema,
// an unknown extension, an over-large integer and a non-finite number.
func withSync(_ label: String, _ meta: String, body: String = "Edited body") {
    let encoded = Data(meta.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let text = baseText.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        line.hasPrefix("sync: ") ? "sync: \(encoded)" : String(line)
    }.joined(separator: "\n").replacingOccurrences(of: "Hello there!", with: body)
    raw(label, "snippets/greeting-617a0002.md", text)
}
let hashPlaceholder = String(repeating: "0", count: 64)
withSync("sync-counter-max",
         #"{"createdAt":800000000.125,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-ffff-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":810000000.5,"x":{}}"#)
withSync("sync-wall-and-counter-max",
         #"{"createdAt":1,"hash":"\#(hashPlaceholder)","hlc":"ffffffffffff-ffff-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":2,"x":{}}"#)
withSync("sync-schema-2",
         #"{"createdAt":800000000.125,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":2,"updatedAt":810000000.5,"x":{}}"#)
withSync("sync-extension",
         #"{"createdAt":800000000.125,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":810000000.5,"x":{"future":{"k":[1,2.5e-300,"v"]}}}"#)
withSync("sync-big-int",
         #"{"createdAt":800000000.125,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":810000000.5,"x":{"k":99999999999999999999}}"#)
withSync("sync-non-finite",
         #"{"createdAt":800000000.125,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":810000000.5,"x":{"k":1e999}}"#)
withSync("sync-int-timestamps",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":-7,"x":{}}"#)
withSync("sync-bad-hlc",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019F8A2B6C00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-bad-origin",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"A1B2C3D4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-extra-key",
         #"{"createdAt":5,"extra":1,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-user-deletion-on-live",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{"userDeletion.v1":["\#(hashPlaceholder)"]}}"#)
withSync("sync-whitespace-json",
         #"{ "createdAt" : 5 , "hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{ } }"#)
// The id inside `sync` decides the snippet; it must be lowercase, and the
// earlier seven-key metadata without it is no metadata at all.
withSync("sync-id-differs-from-line",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0ccc-0000-4000-8000-000000000ccc","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-id-uppercase",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617A0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-id-invalid",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-id-not-text",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":7,"origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-without-id",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
// Written by a newer Snippets: a later integer schema (even with keys missing)
// or a strict superset of the eight keys is unreadable, never a hand edit and
// never normalized. Anything short of that is still a hand edit.
withSync("sync-newer-schema-partial", #"{"schemaVersion":2}"#)
withSync("sync-newer-superset",
         #"{"createdAt":5,"future":{"k":1},"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-newer-superset-bad-types",
         #"{"createdAt":"5","future":1,"hash":7,"hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":[]}"#)
withSync("sync-schema-float-2",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":2.0,"updatedAt":6,"x":{}}"#)
withSync("sync-schema-huge",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":99999999999999999999,"updatedAt":6,"x":{}}"#)
withSync("sync-schema-0",
         #"{"createdAt":5,"hash":"\#(hashPlaceholder)","hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":0,"updatedAt":6,"x":{}}"#)
withSync("sync-extra-key-missing-one",
         #"{"createdAt":5,"extra":1,"hlc":"019f8a2b6c00-0003-a1b2c3d4","id":"617a0002-0000-4000-8000-000000000002","origin":"a1b2c3d4","schemaVersion":1,"updatedAt":6,"x":{}}"#)
withSync("sync-newer-array", #"[{"schemaVersion":2}]"#)
func encodedSync(_ json: String) -> String {
    Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let newerLine = "sync: " + encodedSync(#"{"schemaVersion":3}"#)
// The last `sync` line decides, as for the metadata itself.
edited("sync-newer-then-current") { syncLine($0) { newerLine + "\n" + $0 } }
edited("sync-current-then-newer") { syncLine($0) { $0 + "\n" + newerLine } }
edited("sync-newer-unclosed") { syncLine(unclosed($0)) { _ in newerLine } }
edited("sync-newer-crlf") { syncLine($0) { _ in newerLine }.replacingOccurrences(of: "\n", with: "\r\n") }

// A device-written sync value with its unused trailing base64 bits set. The
// creation time is chosen so the value does not fill its last quantum.
let trailingBitsFile: String = {
    for created in [800_000_000.25, 800_000_000.5, 800_000_000.375] {
        let data = try! GitPlainSnippetFile.render(envelope(created: created))
        let text = String(decoding: data, as: UTF8.self)
        let sync = text.split(separator: "\n").first { $0.hasPrefix("sync: ") }!
        if (sync.count - 6) % 4 != 0 { return text }
    }
    fatalError("no creation time leaves trailing bits")
}()
raw("sync-trailing-bits", "snippets/greeting-617a0002.md", {
    trailingBitsFile.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard line.hasPrefix("sync: ") else { return String(line) }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var value = Array(line.dropFirst(6))
        precondition(value.count % 4 != 0)
        let index = alphabet.firstIndex(of: value[value.count - 1])!
        value[value.count - 1] = alphabet[index | 1]
        return "sync: " + String(value)
    }.joined(separator: "\n")
}())

// Hand-created files.
raw("hand-bare", "snippets/Meeting notes.md", "Just some text\n")
raw("hand-sig", "snippets/sig.md", "---\n# a comment\nname: 'Sig'\nkeyword: sig\ntags: a, b\nenabled: yes\npinned: no\n---\nBest,\nM\n")
raw("hand-front-only-name", "snippets/added.md", "---\nname: Added\nkeyword: added\n---\nAdded by hand\n")
raw("hand-empty", "snippets/empty.md", "")
raw("hand-uppercase-extension", "snippets/Notes.MD", "Upper\n")
raw("hand-unicode-path", "snippets/Заметка é.md", "Тело\r\n")
raw("hand-closing-at-eof", "snippets/eof.md", "---\nname: EOF\n---")
raw("hand-only-opening", "snippets/opening.md", "---\n")
raw("hand-crlf-front", "snippets/crlf.md", "---\r\nname: CRLF\r\nkeyword: crlf\r\n---\r\nline one\r\nline two\r\n")
raw("hand-with-id", "snippets/with-id.md", "---\nname: With id\nid: 617A00FF-0000-4000-8000-0000000000FF\n---\nbody\n")
raw("hand-json-escapes", "snippets/escapes.md", "---\nname: \"Tab\\there \\ud83d\\ude42 \\/ \\u0041\"\nkeyword: \"k\\\\w\"\n---\nx\n")
raw("hand-bad-json-name", "snippets/bad.md", "---\nname: \"unterminated\n---\nx\n")
var invalidUTF8Name = Data("---\nname: bad ".utf8); invalidUTF8Name.append(contentsOf: [0xFF, 0xC3]); invalidUTF8Name.append(Data("\n---\nbody\n".utf8))
bytes("hand-invalid-utf8-name", "snippets/invalid-name.md", invalidUTF8Name)
var invalidUTF8Body = Data("---\nname: ok\n---\nbody ".utf8); invalidUTF8Body.append(contentsOf: [0xFF]); invalidUTF8Body.append(0x0A)
bytes("hand-invalid-utf8-body", "snippets/invalid-body.md", invalidUTF8Body)
raw("hand-nul-in-body", "snippets/nul.md", "---\nname: nul\n---\na\u{0}b\n")
raw("hand-cr-end", "snippets/cr.md", "Ends with CR\r\n")
raw("hand-bom-bare", "snippets/bom.md", "\u{FEFF}Body only\n")
raw("hand-front-unclosed-no-id", "snippets/unclosed.md", "---\nname: x\nbody\n")
raw("hand-combining-quotes", "snippets/combining.md", "---\nname: '\u{0301}x'\nkeyword: \"e\u{0301}\"\ntags: [a\u{0301}, b]\n---\nbody\n")

let otherID = UUID(uuidString: "617a00aa-0000-4000-8000-0000000000aa")!
let originalID = UUID(uuidString: "617a0002-0000-4000-8000-000000000002")!
var assigned: [[String: Any]] = []
// Exact needs the assigned id to be the `sync` id and the `id` line to agree;
// anything else (a copy read under another id, a changed or missing `id`
// line) is an edit.
let assignments: [(String, UUID)] = [
    ("render:basic", otherID), ("edit-body", otherID), ("hand-bare", otherID), ("hand-sig", otherID),
    ("id-changed", otherID), ("render:basic", originalID), ("crlf-only", originalID), ("id-changed", originalID),
    ("id-removed", GitPlainSnippetFile.derivedID(path: "snippets/greeting-617a0002.md")),
    ("id-removed", originalID), ("sync-id-differs-from-line", originalID),
    ("sync-id-differs-from-line", UUID(uuidString: "617a0ccc-0000-4000-8000-000000000ccc")!),
    ("hand-with-id", UUID(uuidString: "617a00ff-0000-4000-8000-0000000000ff")!),
]
for (wanted, assignedID) in assignments {
    guard let (label, path, data) = readInputs.first(where: { $0.0 == wanted }) else { fatalError(wanted) }
    var entry: [String: Any] = ["label": label, "path": path, "file": data.base64EncodedString(),
                                "assigned": assignedID.uuidString.lowercased()]
    if let (value, wasEdited) = try? GitPlainSnippetFile.read(data, path: path, assigning: assignedID) {
        entry["edited"] = wasEdited
        entry["envelope"] = canonical(value)
    } else {
        entry["edited"] = NSNull(); entry["envelope"] = NSNull()
    }
    assigned.append(entry)
}
for (label, path, data) in readInputs {
    var entry: [String: Any] = [
        "label": label, "path": path, "file": data.base64EncodedString(),
        "declaredID": GitPlainSnippetFile.declaredID(data, path: path).uuidString.lowercased(),
        "hasFrontMatter": GitPlainSnippetFile.hasFrontMatter(data),
    ]
    do {
        let (value, wasEdited) = try GitPlainSnippetFile.read(data, path: path)
        entry["edited"] = wasEdited
        entry["envelope"] = canonical(value)
        entry["normalized"] = wasEdited ? ((try? GitPlainSnippetFile.render(value))?.base64EncodedString() ?? NSNull()) : NSNull()
        let tombstone = value.tombstoned(hlc: GitPlainSnippetFile.bumped(value.hlc), origin: HLC.foreignDevice)
        entry["tombstone"] = canonical(tombstone)
        entry["renamedFrom"] = (try? GitPlainSnippetFile.parse(data))?.name ?? NSNull()
    } catch {
        entry["edited"] = NSNull()
        entry["envelope"] = NSNull()
    }
    reads.append(entry)
}

let derivedPaths = ["snippets/added.md", "snippets/Meeting notes.md", "snippets/Заметка é.md", "", "snippets/a/b.md"]
let derived = derivedPaths.map { ["path": $0, "id": GitPlainSnippetFile.derivedID(path: $0).uuidString.lowercased()] }

let slugID = UUID(uuidString: "617a0002-0000-4000-8000-000000000002")!
let slugNames = [
    "Hello, World!", "Greeting", "  leading and trailing  ", "a--b__c", "UPPER lower 123", String(repeating: "a", count: 80),
    String(repeating: "ab ", count: 30), "", "!!!", "x", "snake_case-and.dots", "Tab\tSeparated\nLines",
    "Café crème", "Привет мир", "🙂", "日本語のテキスト", "Straße", "naïve résumé",
]
let slugs = slugNames.map { name -> [String: Any] in
    ["name": name, "ascii": name.unicodeScalars.allSatisfy(\.isASCII),
     "fileName": GitPlainSnippetFile.fileName(name: name, id: slugID)]
}

let tagInputs: [[String]] = [
    ["work", "Work", "WORK"], ["  a   b ", "a b"], ["Ａ", "A", "a"], ["ß", "SS", "ss", "Straße", "STRASSE"],
    ["É", "e", "é", "e\u{0301}"], ["ﬁ", "fi", "FI"], ["İ", "i", "ı", "I"], ["Σ", "σ", "ς"], ["ø", "o", "Ø"],
    ["Å", "Å", "A"], ["", " ", "\t", "\n"], ["x\ty", "x y"], ["ǅ", "ǆ", "Ǆ"], ["ⅰ", "i", "Ⅰ"], ["ｶ", "カ"],
    ["ŉ", "ʼn"], ["ﬀ", "ff"], ["Ω", "Ω", "ω"], ["K", "K", "k"], ["ä", "a\u{0308}", "A"], ["ő", "o"], ["ł", "l"],
    ["đ", "d"], ["ħ", "h"], ["æ", "ae"], ["œ", "oe"], ["þ", "th"], ["ı", "i"], ["ĸ", "q"], ["ǰ", "j"], ["ẞ", "ß"],
    ["\u{00A0}nbsp\u{3000}", "nbsp"], ["a\u{200B}b", "ab"], ["①", "1"], ["²", "2"], ["ｗｏｒｋ", "work"],
    ["Ა", "ა"], ["ᲀ", "в", "В"], ["ᏸ", "Ᏸ"], ["ꭰ", "Ꭰ"], ["𐐨", "𐐀"], ["Ǳ", "ǲ", "ǳ", "dz"], ["ﬅ", "ﬆ", "st"],
    ["ſ", "s"], ["ẛ", "ṡ"], ["ΰ", "υ"], ["ᾳ", "α", "ᾼ"], ["❤\u{FE0F}", "❤"], ["👍🏽", "👍"], ["a\u{200D}", "a"],
    ["कि", "क"], ["के", "क"], ["ช่", "ช"], ["שׁ", "ש"], ["が", "か"], ["한", "\u{1112}\u{1161}\u{11AB}"],
]
let tags = tagInputs.map { ["input": $0, "normalized": SnippetTagging.normalizedTags($0)] }

let dataset = UUID(uuidString: "8f0c2b4e-8f6e-4c1a-9d3b-1a2b3c4d5e6f")!
let output: [String: Any] = [
    "source": "snippets/Core/Git/GitPlainText.swift and GitSyncTransport.swift via CorePackage (@testable import)",
    "render": renders,
    "read": reads,
    "readAssigned": assigned,
    "derivedID": derived,
    "fileName": slugs,
    "normalizedTags": tags,
    "plainReadme": GitSyncLayout.plainReadme,
    "encryptedReadme": GitSyncLayout.readme,
    "plainManifest": String(decoding: try GitSyncManifest(datasetID: dataset, mode: .plainText).encoded(), as: UTF8.self),
    "manifestDataset": dataset.uuidString.lowercased(),
]
let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))

// Foundation's base64 leniency, for the Rust decoder (stderr only).
for probe in ["e30=", "e31=", "e30", "e3==", "e30==", "e 30="] {
    let decoded = Data(base64Encoded: probe)
    FileHandle.standardError.write(Data("base64 \(probe.debugDescription) -> \(decoded.map { Array($0) }.debugDescription)\n".utf8))
}
