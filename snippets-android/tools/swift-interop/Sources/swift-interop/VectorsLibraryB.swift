import CryptoKit
import Foundation
@testable import SnippetsCore

// L4–L6: fuzzy match and search, placeholders, keyword suggestions, import, deep links.

enum LibraryVectorsB {

    // MARK: L4

    static func l4() throws -> VectorFile {
        var cases: [J] = []
        let pairs: [(String, String, String)] = [
            ("", "anything", "en_US"), ("a", "", "en_US"), ("", "", "en_US"),
            ("sig", "Signature", "en_US"), ("sig", "Email signature", "en_US"), ("sig", "design", "en_US"),
            ("es", "Email signature", "en_US"), ("ES", "email signature", "en_US"),
            ("prjal", "Project Alpha", "en_US"), ("pa", "Project Alpha", "en_US"), ("pa", "papa", "en_US"),
            ("abc", "a-b-c", "en_US"), ("abc", "abc", "en_US"), ("abc", "xabc", "en_US"), ("abc", "ab", "en_US"),
            ("abc", "acb", "en_US"), ("aaa", "aaaa", "en_US"), ("aaaaaa", String(repeating: "a", count: 256), "en_US"),
            ("ab", "a b a b", "en_US"), ("ab", "ba ab", "en_US"), ("fb", "FooBar foo_bar fooBar", "en_US"),
            ("foo bar", "foo bar", "en_US"), ("foobar", "foo bar", "en_US"), ("f b", "foo bar", "en_US"),
            ("wifi", "Wi-Fi password", "en_US"), ("w-f", "Wi-Fi password", "en_US"), ("123", "a1b2c3", "en_US"),
            ("a1", "A1 steak", "en_US"), ("cafe", "Café crème", "en_US"), ("café", "Cafe creme", "en_US"),
            ("creme", "Café crème", "en_US"), ("cc", "Café crème", "en_US"), ("ss", "Straße", "en_US"),
            ("strasse", "Straße", "en_US"), ("straße", "Strasse", "en_US"), ("e", "e\u{301}", "en_US"),
            ("é", "e\u{301}", "en_US"), ("fi", "ﬁle", "en_US"), ("file", "ﬁle", "en_US"),
            ("日本", "日本語のテキスト", "en_US"), ("語テ", "日本語のテキスト", "en_US"), ("key", "🔑 key", "en_US"),
            ("🔑", "🔑 key 🔑", "en_US"), ("👩", "👩🏽‍💻 dev", "en_US"), ("dev", "👩🏽‍💻 dev", "en_US"),
            ("ab", "a\r\nb", "en_US"), ("b", "a\r\nb", "en_US"), ("привет", "Привет мир", "en_US"),
            ("пм", "Привет мир", "en_US"), ("i", "İstanbul", "en_US"), ("ı", "ISTANBUL", "en_US"),
            ("i", "ISTANBUL", "en_US"), ("i", "İstanbul", "tr_TR"), ("ı", "ISTANBUL", "tr_TR"),
            ("i", "ISTANBUL", "tr_TR"), ("I", "ıstanbul", "tr_TR"), ("title", "TITLE", "tr_TR"),
            ("title", "TITLE", "az_AZ"), ("a.b", "a.b.c", "en_US"), ("{d", "{date}", "en_US"),
            ("xyz", "The quick brown fox", "en_US"), ("tqbf", "The quick brown fox", "en_US"),
            ("the", "The quick brown fox", "en_US"), ("ox", "The quick brown fox", "en_US"),
            ("quick fox", "The quick brown fox", "en_US"), ("  sig", "sig", "en_US"),
        ]
        for (index, (query, target, localeID)) in pairs.enumerated() {
            let locale = Locale(identifier: localeID)
            var workspace = FuzzyMatch.Workspace()
            let preparedQuery = FuzzyMatch.PreparedQuery(query, locale: locale)
            let preparedTarget = FuzzyMatch.PreparedTarget(target, locale: locale)
            let result = FuzzyMatch.score(query: preparedQuery, target: preparedTarget, workspace: &workspace)
            let membership = FuzzyMatch.matches(query: preparedQuery, target: preparedTarget)
            let folded = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            cases.append(vcase("fuzzy-\(index)", [
                ("kind", .str("fuzzy")),
                ("query", .text(query.count > 40 ? String(query.prefix(40)) : query)),
                ("target", target.count > 80 ? .obj([("text", .str("a×\(target.count)")), ("utf8Hex", .hex(Data(target.utf8)))]) : .text(target)),
                ("locale", .str(localeID)),
                ("matched", .bool(result.matched)),
                ("score", .n(result.score)),
                ("matchedRangesUTF16", .arr(result.matchedRanges.map { .arr([.n($0.location), .n($0.length)]) })),
                ("subsequenceMatches", .bool(membership)),
                ("foldedTarget", .text(folded.count > 80 ? "a×\(folded.count)" : folded)),
                ("matchesFoldedTarget", .bool(FuzzyMatch.matches(query: preparedQuery, foldedTarget: folded))),
            ]))
        }

        for (index, (field, needle)) in [
            ("cafe creme", "cafe"), ("cafe creme", "CAFE"), ("cafe creme", ""), ("", ""), ("", "a"),
            ("e\u{301}cole", "\u{e9}"), ("\u{e9}cole", "e\u{301}"), ("\u{e9}cole", "e"), ("e\u{301}cole", "e"),
            ("a\r\nb", "\r"), ("a\r\nb", "\n"), ("a\r\nb", "\r\n"), ("a\nb", "\n"),
            ("👩🏽‍💻 dev", "👩"), ("👩🏽‍💻 dev", "👩🏽‍💻"), ("kelvin \u{212A}", "k"), ("kelvin \u{212A}", "K"),
            ("abc", "abcd"), ("abcabc", "cab"), ("日本語", "本"), ("a/b", "/"), ("tab\there", "\t"),
        ].enumerated() {
            cases.append(vcase("substring-\(index)", [
                ("kind", .str("preparedSubstring")),
                ("field", .text(field)),
                ("needle", .text(needle)),
                ("contains", .bool(PreparedSubstringSearch.Field(field).contains(PreparedSubstringSearch.Query(needle)))),
                ("swiftStringContains", .bool(field.contains(needle))),
            ]))
        }

        // Search over a fixed library, in display order as the app passes it.
        func snippet(
            _ id: Int, _ name: String, _ keyword: String, _ content: String, _ tags: [String] = [],
            pinned: Bool = false, created: Double
        ) -> Snippet {
            Snippet(
                id: UUID(uuidString: String(format: "5EA4C400-0000-4000-8000-%012X", id))!, name: name,
                keyword: keyword, content: content, tags: tags, isEnabled: true, isPinned: pinned,
                createdAt: Date(timeIntervalSinceReferenceDate: created),
                updatedAt: Date(timeIntervalSinceReferenceDate: created))
        }
        let ordinary = [
            snippet(1, "Email signature", "sig", "Best regards,\nMichael", ["Work", "mail"], created: 100),
            snippet(2, "Project Alpha kickoff", "pa", "Agenda for the kickoff meeting", ["Work", "Projects"], pinned: true, created: 90),
            snippet(3, "", "", "Project Alpha notes in the body only\nsecond line", [], created: 80),
            snippet(4, "Café order", "\\cafe", "Un café crème, s'il vous plaît", ["Français", "food"], created: 70),
            snippet(5, "Straße & Hausnummer", "addr", "Musterstraße 1\n12345 Berlin", ["home", "Adresse"], created: 60),
            snippet(6, "日本語メモ", "jp", "これは日本語のテキストです", ["日本語"], created: 50),
            snippet(7, "Temporary Password", "tp", "TP-{date:yyyyMMdd}-{clipboard}", ["work"], pinned: true, created: 40),
            snippet(8, "git commands", "gitc", "git status\r\ngit log --oneline", ["dev", "Work"], created: 30),
            snippet(9, "  ", "ws", "   \n\tIndented first line", ["misc"], created: 20),
        ]
        let secure = [
            snippet(10, "Wi-Fi password", "wifi", "", ["home", "Secret"], created: 95),
            snippet(11, "Bank PIN", "pin", "", ["Secret"], created: 10),
        ]
        let display = SnippetDisplayOrder.sorted(ordinary + secure)
        let locale = Locale(identifier: "en_US")
        let snapshot = SnippetSearchSnapshot.build(from: display, locale: locale, maximumNormalizedBytes: 16 * 1_024 * 1_024)
        var projection = SnippetLibraryProjection()
        let projected = projection.snapshot(ordinary: ordinary, secure: secure, locale: locale)
        cases.append(vcase("search-library", [
            ("kind", .str("search-library")),
            ("locale", .str("en_US")),
            ("ordinary", .arr(ordinary.map(snippetJ))),
            ("secureShells", .arr(secure.map(snippetJ))),
            ("displayOrderIDs", .strings(display.map { lower($0.id) })),
            ("projectionSortedIDs", .strings(projected.sorted.map { lower($0.id) })),
            ("tagUsage", .arr(projected.tagUsage.map { .obj([("tag", .str($0.tag)), ("count", .n($0.count))]) })),
            ("tagKeys", .strings(projected.tagKeys.sorted())),
        ]))
        let queries: [(String, [String])] = [
            ("sig", []), ("SIG", []), ("  sig  ", []), ("signature", []), ("regards", []), ("prjal", []),
            ("project alpha", []), ("alpha", []), ("pa", []), ("cafe", []), ("café", []), ("creme", []),
            ("strasse", []), ("straße", []), ("musterstrasse", []), ("hausnummer", []), ("日本", []),
            ("テキスト", []), ("wifi", []), ("wi-fi", []), ("secret", []), ("pin", []), ("work", []),
            ("wrk", []), ("{date", []), ("clipboard", []), ("git log", []), ("status\r\ngit", []),
            ("status\ngit", []), ("indented", []), ("untitled", []), ("zzz", []), ("a", []), (" ", []),
            ("mail", ["work"]), ("", ["work"]), ("", ["work", "mail"]), ("", ["secret"]), ("", ["home", "secret"]),
            ("p", ["work"]), ("alpha", ["projects"]), ("alpha", ["home"]), ("", ["francais"]), ("", ["missing"]),
            ("e", ["日本語"]),
        ]
        for (index, (query, tags)) in queries.enumerated() {
            let normalized = SnippetSearchSnapshot.normalizedQuery(query, locale: locale)
            let keys = Set(tags)
            var members: [(String, J)] = [
                ("kind", .str("search")),
                ("query", .text(query)),
                ("normalizedQuery", .text(normalized)),
                ("activeTagKeys", .strings(tags)),
            ]
            if normalized.isEmpty {
                // Callers skip the index for an empty query.
                members.append(("resultIDs", .strings(
                    SnippetSearchSnapshot.resultsForEmptySearch(in: display, activeTagKeys: keys).map { lower($0.id) })))
                members.append(("usesEmptySearchPath", .bool(true)))
            } else {
                let evaluation = snapshot.evaluate(searchText: query, activeTagKeys: keys)
                members.append(("searchMatchIDs", .strings(evaluation.searchMatches.map { lower($0.id) })))
                members.append(("resultIDs", .strings(evaluation.snippets.map { lower($0.id) })))
                members.append(("usesEmptySearchPath", .bool(false)))
            }
            cases.append(vcase("search-\(index)", members))
        }
        return VectorFile(
            name: "L04-search",
            pins: "FuzzyMatch score and highlight ranges, FuzzyMatch membership, PreparedSubstringSearch, SnippetSearchSnapshot results and SnippetLibraryProjection tag list for a fixed library (brief 01 §6 Fuzzy match, Search index)",
            notes: [
                "matchedRangesUTF16 are [location, length] in UTF-16 units of the target. When several alignments reach the same score the highlighted path is not unique by contract (Swift's own tests accept any); score and matched are.",
                "Search has no ranking: results keep the input (display) order. searchMatchIDs is before the tag filter, resultIDs after. Tag keys are SnippetTagging.filterKey values.",
                "Locales are passed explicitly (en_US, tr_TR, az_AZ); the app passes the user's locale.",
                "Secure snippets enter the index as shells with empty content.",
            ],
            cases: cases)
    }

    // MARK: L5 (placeholders run in child processes, one per locale and time zone)

    static let placeholderNows: [(String, Double)] = [
        ("month-end", 1_769_902_215),      // 2026-01-31T23:30:15Z
        ("dst-eve", 1_774_699_200),        // 2026-03-28T12:00:00Z
        ("leap-day", 1_709_200_800),       // 2024-02-29T10:00:00Z
        ("afternoon", 1_785_340_805.75),   // 2026-07-29T16:00:05.75Z
    ]

    static let placeholderTemplates: [String] = [
        "{clipboard}", "{date}", "{time}", "{datetime}", "{date:yyyy-MM-dd}",
        "{date format=\"EEEE, MMMM d\"}", "{date locale=\"fr-FR\"}", "{date offset=+1d}",
        "{datetime offset=\"+1d -2h\"}",
        "Update for {date:yyyy-MM-dd}\n\nReference: {clipboard}\nNext check: {date format=\"EEEE, MMMM d\" offset=+1d}",
        "TP-{date:yyyyMMdd}-{clipboard}",
        "{time:HH:mm}", "{time:HH:mm:ss}", "{time:h:mm_a}", "{datetime:yyyy-MM-dd_HH-mm-ss}", "{date:EEEE}",
        "{date:MMMM}", "{date:y}", "{date:Y-ww}", "{date:D}", "{date:Q}", "{date:G}", "{time:z}", "{time:Z}",
        "{time:ZZZZZ}", "{time:SSS}", "{time:A}", "{date:e}", "{date:c}", "{date:LLLL}", "{date:yy}",
        "{date:MMMMM}", "{date:u}", "{date:U}", "{date:r}", "{time:a}", "{time:B}", "{time:k}", "{time:K}",
        "{date format=\"yyyy-MM-dd'T'HH:mm:ssXXXXX\"}", "{date format=\"d MMM y 'at' HH 'h' mm\"}",
        "{date format=\"'quoted' ''apostrophe'' yyyy\"}", "{date format=\"EEEE d MMMM y\" offset=\"+1M\"}",
        "{time format=\"HH:mm\" offset=\"+90m\"}", "{datetime format=\"yyyy-MM-dd HH:mm\" offset=\"-1y +2M -3d +4h -5m\"}",
        "{date offset=\"+1M\"}", "{date offset=+1M}", "{date offset=-1M}", "{date offset=+1y}", "{date offset=-1y}",
        "{date offset=\"+1d\"}", "{datetime offset=+24h}", "{datetime offset=+1d}", "{datetime offset=\"+1d +1d\"}",
        "{datetime offset=\"+1M -1M\"}", "{datetime offset=\"-1M +1M\"}", "{date offset=+0d}", "{date offset=-0d}",
        "{date offset=+100000d}", "{date offset=+100001d}", "{date offset=\"+1d +1d +1d +1d +1d +1d +1d +1d\"}",
        "{date offset=\"+1d +1d +1d +1d +1d +1d +1d +1d +1d\"}", "{date offset=1d}", "{date offset=+1}",
        "{date offset=+d}", "{date offset=+1w}", "{date offset=+1D}", "{date offset=+1H}", "{date offset=+ 1d}",
        "{date offset=\"\"}", "{date offset=}", "{date offset=+1d offset=+2d}", "{date offset=\"+1d  -2h\"}",
        "{date offset=\" +1d\"}", "{date offset=+١d}",
        "{date locale=\"en-US\"}", "{time locale=\"en-US\"}", "{datetime locale=\"en-GB\"}", "{datetime locale=\"de-DE\"}",
        "{datetime locale=\"ja-JP\"}", "{datetime locale=\"ar-SA\"}", "{datetime locale=\"th-TH\"}",
        "{datetime locale=\"fa-IR\"}", "{datetime locale=\"he-IL\"}", "{datetime locale=\"zh-Hant-TW\"}",
        "{date locale=\"fr\"}", "{date locale=\"fr-CA\"}", "{date locale=\"sr-Latn-RS\"}",
        "{time locale=\"en-US-u-hc-h23\"}", "{time locale=\"fr-FR-u-hc-h12\"}", "{date locale=\"th-TH-u-ca-gregory\"}",
        "{date locale=\"en-US-u-nu-arab\"}", "{date locale=\"fr-FR\" offset=+1d}", "{date offset=+1M locale=\"ar-SA\"}",
        "{date locale=\"fr_FR\"}", "{date locale=fr-FR}", "{date locale=\"xx-XX\"}", "{date locale=\"zz\"}",
        "{date locale=\"\"}", "{date locale=\"english\"}", "{date locale=\"en-US\" format=\"yyyy\"}",
        "{date format=\"yyyy\" locale=\"en-US\"}", "{date format=yyyy-MM-dd}", "{date format=\"\"}",
        "{date format=\"it's\"}", "{date format=\"it''s\"}", "{date format=\"a{b\"}", "{date format=\"yyyy\" format=\"MM\"}",
        "{date format=\"yyyy\" extra=1}", "{date format=\"yyyy\"x}", "{date  format=\"yyyy\"}", "{date format =\"yyyy\"}",
        "{date format= \"yyyy\"}", "{date\tformat=\"yyyy\"}", "{date format=\"yyyy\" }", "{date format=\"yyyy\"  offset=+1d}",
        "{date \"yyyy-MM-dd\"}", "{time \"HH:mm\"}", "{datetime \"yyyy-MM-dd HH:mm\"}", "{date \"\"}", "{date \"it's\"}",
        "{date \"yyyy\" offset=+1d}",
        "{DATE}", "{Date}", "{CLIPBOARD}", "{ date }", "{date }", "{ date}", "{date:}", "{date: yyyy}",
        "{date:yyyy MM}", "{date:yyyy/MM}", "{date:yyyy.MM}", "{date:value,time:value}", "{date:'x'}",
        "{clipboard:x}", "{clipboard }", "{clipboard offset=+1d}", "{cursor}", "{argument}", "{uuid}",
        "{selection}", "{snippet name=\"x\"}", "{nonsense}", "{}", "{ }", "{{date}}", "{date}}", "{{date}",
        "{date\n}", "{da\nte}", "date}", "{date", "\\{date\\}", "{date}{time}", "{date}{clipboard}{date}",
        "{clipboard}{clipboard}", "a{clipboard}b{clipboard}c", "{style: {color: red}}", "{date:yyyy}-{unknown}-{time:HH}",
        "plain text without placeholders", "", "émoji 🔑 {date:yyyy} 🔑", "{date:yyyy}\r\n{time:HH}",
        "{date:" + String(repeating: "y", count: 600) + "}",
        "{date format=\"" + String(repeating: "y", count: 512) + "\"}",
        "{date format=\"" + String(repeating: "y", count: 513) + "\"}",
    ]

    static let raycastInputs: [String] = [
        "{date \"yyyy-MM-dd\"}", "{time \"HH:mm\"}", "{datetime \"yyyy-MM-dd HH:mm\"}",
        "Sent {date \"EEEE, MMMM d\"} at {time \"h:mm a\"}", "{date \"it's\"}", "{date \"it''s\"}", "{date \"\"}",
        "{date \"a{b\"}", "{date format=\"yyyy\"}", "{date offset=+1d}", "{date:yyyy-MM-dd}", "{date}", "{clipboard}",
        "{cursor}", "{argument name=\"x\"}", "{uuid}", "{selection}", "{DATE \"yyyy\"}", "{date  \"yyyy\"}",
        "{date \"yyyy\" offset=+1d}", "{date \"yyyy\"}{time \"HH\"}", "no placeholders", "",
        "{date \"" + String(repeating: "y", count: 513) + "\"}",
    ]

    /// Child entry point: resolves every template in this process's locale and zone.
    static func runPlaceholderChild() {
        var cases: [J] = []
        let environment: [(String, J)] = [
            ("locale", .str(Locale.current.identifier)),
            ("timeZone", .str(TimeZone.current.identifier)),
            ("calendar", .str(String(describing: Calendar.current.identifier))),
        ]
        for (nowName, unix) in placeholderNows {
            let now = Date(timeIntervalSince1970: unix)
            for (index, template) in placeholderTemplates.enumerated() {
                // The large table runs against the first instant; the others only for
                // templates whose result depends on the calendar position.
                if nowName != placeholderNows[0].0,
                   !(template.contains("offset") || ["{date}", "{time}", "{datetime}", "{date:yyyy-MM-dd}", "{time:HH:mm:ss}", "{time:ZZZZZ}", "{time:z}", "{date:Y-ww}", "{date:D}"].contains(template)) {
                    continue
                }
                var clipboardReads = 0
                let resolved = PlaceholderResolver.resolve(
                    template: template, clipboard: { clipboardReads += 1; return "Clip {date} 🔑" }, now: { now })
                let preview = PlaceholderResolver.resolveForPreview(
                    template: template, clipboard: { "Clip {date} 🔑" }, now: { now })
                let long = template.count > 200
                cases.append(vcase("\(nowName)-\(index)", [
                    ("kind", .str("resolve")),
                    ("now", .str(nowName)),
                    ("template", long ? .obj([("text", .str(String(template.prefix(30)) + "…")), ("utf8Hex", .hex(Data(template.utf8)))]) : .text(template)),
                    ("resolved", long ? .obj([("utf8Hex", .hex(Data(resolved.utf8)))]) : .text(resolved)),
                    ("previewEqualsResolved", .bool(preview == resolved)),
                    ("unchanged", .bool(resolved == template)),
                    ("clipboardReads", .n(clipboardReads)),
                    ("containsResolvablePlaceholder", .bool(PlaceholderResolver.containsResolvablePlaceholder(in: template))),
                    ("containsClipboardPlaceholder", .bool(PlaceholderResolver.containsClipboardPlaceholder(in: template))),
                    ("isResolvablePlaceholder", .bool(PlaceholderResolver.isResolvablePlaceholder(template))),
                ]))
            }
        }
        let now = Date(timeIntervalSince1970: placeholderNows[0].1)
        cases.append(vcase("clipboard-nil", [
            ("kind", .str("clipboard")),
            ("template", .str("[{clipboard}]")),
            ("clipboard", .null),
            ("resolved", .str(PlaceholderResolver.resolve(template: "[{clipboard}]", clipboard: { nil }, now: { now }))),
        ]))
        for count in [999, 1_000, 1_001] {
            let clip = String(repeating: "c", count: count)
            let preview = PlaceholderResolver.resolveForPreview(template: "{clipboard}", clipboard: { clip }, now: { now })
            cases.append(vcase("preview-clipboard-\(count)", [
                ("kind", .str("preview")),
                ("template", .str("{clipboard}")),
                ("clipboardCharacterCount", .n(count)),
                ("previewCharacterCount", .n(preview.count)),
                ("previewSuffix", .str(String(preview.suffix(40)))),
            ]))
        }
        for count in [1_999, 2_000, 2_001] {
            let template = String(repeating: "t", count: count)
            let preview = PlaceholderResolver.resolveForPreview(template: template, clipboard: { nil }, now: { now })
            cases.append(vcase("preview-rendered-\(count)", [
                ("kind", .str("preview")),
                ("templateCharacterCount", .n(count)),
                ("previewCharacterCount", .n(preview.count)),
                ("previewSuffix", .str(String(preview.suffix(30)))),
            ]))
        }
        for (index, text) in raycastInputs.enumerated() {
            let converted = RaycastPlaceholders.converted(text)
            let long = text.count > 200
            cases.append(vcase("raycast-\(index)", [
                ("kind", .str("raycast")),
                ("input", long ? .obj([("utf8Hex", .hex(Data(text.utf8)))]) : .text(text)),
                ("converted", long ? .obj([("utf8Hex", .hex(Data(converted.utf8)))]) : .text(converted)),
                ("changed", .bool(converted != text)),
            ]))
        }
        cases.append(vcase("completion-tokens", [
            ("kind", .str("completion")),
            ("tokens", .strings(PlaceholderResolver.completionTokens)),
            ("allResolve", .bool(PlaceholderResolver.completionTokensAllResolve())),
        ]))
        FileHandle.standardOutput.write(J.obj(environment + [("cases", .arr(cases))]).serialized())
    }

    static func l5() throws -> [VectorFile] {
        guard let executable = Bundle.main.executableURL else { throw InteropFailure("L5 executable path") }
        var files: [VectorFile] = []
        for (localeID, language) in [("en_US", "en-US"), ("fr_FR", "fr-FR"), ("th_TH", "th-TH")] {
            for zone in ["UTC", "Europe/Paris"] {
                let process = Process()
                process.executableURL = executable
                // NSArgumentDomain overrides the user's own preferences for this child only.
                process.arguments = [
                    "_placeholders",
                    "-AppleLocale", localeID, "-AppleLanguages", "(\"\(language)\")",
                    "-AppleICUForce24HourTime", "NO", "-AppleICUForce12HourTime", "NO",
                    "-AppleICUDateFormatStrings", "{}", "-AppleICUTimeFormatStrings", "{}",
                    "-AppleFirstWeekday", "{}", "-AppleICUNumberSymbols", "{}",
                ]
                var environment = ProcessInfo.processInfo.environment
                environment["TZ"] = zone
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let entries = root["cases"] as? [[String: Any]] else {
                    throw InteropFailure("L5 child for \(localeID) \(zone) failed")
                }
                try require(root["locale"] as? String == localeID, "L5 child locale is \(root["locale"] ?? "?"), wanted \(localeID)")
                try require(root["timeZone"] as? String == zone
                    || (zone == "UTC" && ["GMT", "UTC", "Etc/UTC"].contains(root["timeZone"] as? String ?? "")),
                    "L5 child zone is \(root["timeZone"] ?? "?"), wanted \(zone)")
                let cases: [J] = entries.map { entry in
                    guard case .obj(var members) = GitVectors.anyToJ(entry) else { return .null }
                    // `name` first, the rest alphabetical (JSONSerialization lost the order).
                    let name = members.first { $0.0 == "name" }?.1 ?? .str("?")
                    members.removeAll { $0.0 == "name" }
                    return .obj([("name", name)] + members)
                }
                files.append(VectorFile(
                    name: "L05-placeholders-\(localeID)-\(zone.replacingOccurrences(of: "/", with: "-"))",
                    pins: "PlaceholderResolver.resolve / resolveForPreview / containsResolvablePlaceholder / isResolvablePlaceholder and RaycastPlaceholders.converted with the process locale \(localeID), time zone \(zone) (brief 01 §6 Placeholders)",
                    notes: [
                        "Environment of the resolving process: locale \(root["locale"] ?? "?"), time zone \(root["timeZone"] ?? "?"), calendar \(root["calendar"] ?? "?"). The resolver has a seam for the clock only; locale, zone and calendar are the process defaults, so each file is produced by a child process started with -AppleLocale / -AppleLanguages (NSArgumentDomain) and TZ, with the 12/24-hour overrides and custom format strings neutralised.",
                        "Fixed instants (`now`): month-end = 2026-01-31T23:30:15Z, dst-eve = 2026-03-28T12:00:00Z, leap-day = 2024-02-29T10:00:00Z, afternoon = 2026-07-29T16:00:05.75Z. The full template table runs at month-end; the other instants run the offset and default-style templates.",
                        "Clipboard text is `Clip {date} 🔑`: inserted text is never rescanned, so the `{date}` inside it stays literal.",
                        "`unchanged` true means the template came back byte for byte (malformed or unknown placeholders stay literal).",
                        "Localised text (medium styles, month and weekday names, digits, the narrow no-break space U+202F before AM/PM) is ICU/CLDR data of the OS that ran the emitter. Kotlin on Android formats with the device's own CLDR and need not match these strings byte for byte; the grammar outcomes (resolved or literal), the offset arithmetic and the explicit numeric patterns must.",
                    ],
                    cases: cases))
            }
        }
        return files
    }

    // MARK: L6

    static func l6() throws -> VectorFile {
        var cases: [J] = []
        for (index, (name, line)) in [
            ("Signature Block", "Best regards"), ("Café Order", ""), ("", ""), ("", "https://example.com/path"),
            ("", "www.example.com"), ("Email", "Hello there"), ("A", "B"), ("Temporary Password", "TP-{date:yyyyMMdd}"),
            ("one two three four five six seven", ""), ("Wi-Fi password (home)", "hunter2"), ("日本語メモ", "これは"),
            ("Straße", "Größe"), ("x", "y"), ("ab", "cd"), ("abcdef", "abcdefg"), ("ABCDEFG", ""), ("  spaced   name  ", "  line  "),
            ("C++ & C#", "int main()"), ("2024 report", "Q4"), ("ﬁle ﬁnder", ""), ("İstanbul Notes", ""),
            ("naïve résumé", "naïve"), ("http", "http server"), ("https www", "https://x"), ("Sign", "Signature"),
            ("e-mail", "re: e-mail"), ("snake_case name", ""), ("🔑 Keys", "🔑"),
        ].enumerated() {
            cases.append(vcase("candidates-\(index)", [
                ("kind", .str("candidates")),
                ("snippetName", .text(name)),
                ("contentFirstLine", .text(line)),
                ("candidates", .strings(KeywordSuggestions.candidates(name: name, contentFirstLine: line))),
            ]))
        }
        for (index, (keyword, other)) in [
            ("sig", "sig"), ("sig", "SIG"), ("sig", "sign"), ("sign", "sig"), ("sig", "xsig"), ("", ""), ("", "sig"),
            ("sig", ""), ("café", "cafe"), ("cafe", "CAFÉ-au"), ("\\sig", "sig"), (" sig ", "sig"), ("my key", "my-key"),
            ("a", "b"), ("straße", "STRASSE"), ("ss", "ß"),
        ].enumerated() {
            cases.append(vcase("relation-\(index)", [
                ("kind", .str("relation")),
                ("keyword", .text(keyword)),
                ("other", .text(other)),
                ("foldedKeyword", .str(SnippetTagging.filterKey(for: Snippet.sanitizedKeyword(keyword)))),
                ("foldedOther", .str(SnippetTagging.filterKey(for: Snippet.sanitizedKeyword(other)))),
                ("relationOfFolded", .str(String(describing: KeywordRelation.between(
                    SnippetTagging.filterKey(for: Snippet.sanitizedKeyword(keyword)),
                    SnippetTagging.filterKey(for: Snippet.sanitizedKeyword(other)))))),
                ("relationOfRaw", .str(String(describing: KeywordRelation.between(keyword, other)))),
            ]))
        }
        let pool = ["doc.frontend", "doc.backend", "docs", "Doc.Frontend", "café.docs", "sig", "sign", "signature",
                    "my-key", "a.b.c", "b.a", "front.doc", "api.doc.v2", "", "  ", "\\tp", "x doc"]
        for (index, query) in ["do", "doc", "doc.", "doc.f", "DOC", "front", "doc.front", "front.doc", "b.a", "a.c",
                               "c.a", "caf", "CAF", "café", "sig", "s", "", "zzz", "my", "my-", "v2.api", "d.f", "tp", "x"].enumerated() {
            cases.append(vcase("keywords-\(index)", [
                ("kind", .str("existing-keywords")),
                ("query", .text(query)),
                ("among", .strings(pool)),
                ("existingMatches", .strings(KeywordSuggestions.existingMatches(query: query, among: pool))),
                ("tabCompletion", .opt(KeywordSuggestions.tabCompletion(query: query, among: pool))),
            ]))
        }

        // Import.
        let id = Fixture.uuidA.uuidString
        let native = "{\"id\":\"\(id)\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"tags\":[\"T\",\"t\"],\"isEnabled\":false,\"isPinned\":true,\"createdAt\":700000000.25,\"updatedAt\":700000123.5}"
        let imports: [(String, String)] = [
            ("native-array", "[\(native)]"),
            ("native-collection", "{\"snippets\":[\(native)]}"),
            ("native-empty-array", "[]"),
            ("native-empty-collection", "{\"snippets\":[]}"),
            ("raycast-basic", "[{\"name\":\"Greeting\",\"text\":\"Hello {clipboard}\",\"keyword\":\"hi\"}]"),
            ("raycast-no-keyword", "[{\"name\":\"Note\",\"text\":\"body\"}]"),
            ("raycast-exclamation-keywords", "[{\"name\":\"A\",\"text\":\"a\",\"keyword\":\"!addr\"},{\"name\":\"B\",\"text\":\"b\",\"keyword\":\"!!two\"},{\"name\":\"C\",\"text\":\"c\",\"keyword\":\" ! spaced key \"},{\"name\":\"D\",\"text\":\"d\",\"keyword\":\"!\"},{\"name\":\"E\",\"text\":\"e\",\"keyword\":\"\\\\!bs\"}]"),
            ("raycast-legacy-placeholders", "[{\"name\":\"Dated\",\"text\":\"On {date \\\"yyyy-MM-dd\\\"} at {time \\\"HH:mm\\\"} {cursor} {date \\\"it's\\\"}\",\"keyword\":\"dt\"}]"),
            ("raycast-extra-keys", "[{\"name\":\"X\",\"text\":\"x\",\"keyword\":\"x\",\"id\":\"ignored\",\"other\":1}]"),
            ("raycast-keyword-null", "[{\"name\":\"X\",\"text\":\"x\",\"keyword\":null}]"),
            ("raycast-missing-text", "[{\"name\":\"X\",\"keyword\":\"x\"}]"),
            ("raycast-one-bad-element", "[{\"name\":\"X\",\"text\":\"x\"},{\"name\":\"Y\"}]"),
            ("mixed-native-and-raycast", "[\(native),{\"name\":\"X\",\"text\":\"x\"}]"),
            ("native-with-text-key-is-native", "[{\"id\":\"\(id)\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"text\":\"t\",\"createdAt\":1,\"updatedAt\":2}]"),
            ("object-without-snippets", "{\"items\":[]}"),
            ("not-json", "hello"),
            ("empty", ""),
            ("top-level-number", "42"),
        ]
        for (name, text) in imports {
            var members: [(String, J)] = [("kind", .str("import")), ("fileText", .str(text))]
            do {
                let prepared = try SnippetImportParser.parse(Data(text.utf8))
                // Raycast items get a fresh UUID and the current time; only the
                // deterministic fields are recorded. Native items carry their own.
                let isNative = text.contains("\"content\"")
                func describe(_ snippets: [Snippet]) -> J {
                    .arr(snippets.map { snippet in
                        isNative ? snippetJ(snippet) : .obj([
                            ("name", .str(snippet.name)), ("keyword", .str(snippet.keyword)),
                            ("content", .str(snippet.content)), ("tags", .strings(snippet.tags)),
                            ("isEnabled", .bool(snippet.isEnabled)), ("isPinned", .bool(snippet.isPinned)),
                        ])
                    })
                }
                members += [
                    ("dialect", .str(isNative ? "native" : "raycast")),
                    ("hasRaycastExclamationKeywords", .bool(prepared.hasRaycastExclamationKeywords)),
                    ("snippets", describe(prepared.snippets)),
                    ("snippetsPreservingExclamationPrefix", describe(prepared.snippetsPreservingExclamationPrefix)),
                ]
            } catch {
                members.append(("error", .str(errorName(error))))
            }
            cases.append(vcase("import-\(name)", members))
        }

        // Deep links.
        let shareable: [(String, Snippet)] = [
            ("basic", Snippet(id: Fixture.uuidA, name: "Email signature", keyword: "sig", content: "Best regards,\nMichael", tags: ["Work", "mail"], createdAt: Fixture.created, updatedAt: Fixture.updated)),
            ("no-tags", Snippet(id: Fixture.uuidA, name: "Plain", keyword: "", content: "body", createdAt: Fixture.created, updatedAt: Fixture.updated)),
            ("unsanitised-keyword", Snippet(id: Fixture.uuidA, name: "KW", keyword: " \\my key ", content: "body", createdAt: Fixture.created, updatedAt: Fixture.updated)),
            ("unicode", Snippet(id: Fixture.uuidA, name: "Café ☕ \"q\"", keyword: "café", content: "emoji 🔑 / slash ? & = # + % \u{2028}", tags: ["Ünï", "日本語"], createdAt: Fixture.created, updatedAt: Fixture.updated)),
            ("empty", Snippet(id: Fixture.uuidA, name: "", keyword: "", content: "", createdAt: Fixture.created, updatedAt: Fixture.updated)),
            ("payload-with-url-unsafe-base64", Snippet(id: Fixture.uuidA, name: "???>>>", keyword: "", content: "~~~???>>>~~~", createdAt: Fixture.created, updatedAt: Fixture.updated)),
            ("long-content", Snippet(id: Fixture.uuidA, name: "Long", keyword: "long", content: String(repeating: "0123456789", count: 10_000), createdAt: Fixture.created, updatedAt: Fixture.updated)),
        ]
        var firstLink = ""
        for (name, snippet) in shareable {
            let url = try SnippetDeepLink.url(for: snippet, isSecure: false)
            let text = url.absoluteString
            if firstLink.isEmpty { firstLink = text }
            let back = try SnippetDeepLink.snippet(from: url)
            let payload = String(text.dropFirst("snippets://share?data=".count))
            var padded = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while padded.count % 4 != 0 { padded.append("=") }
            let json = Data(base64Encoded: padded) ?? Data()
            let long = text.count > 4_000
            cases.append(vcase("link-encode-\(name)", [
                ("kind", .str("link-encode")),
                ("snippet", long ? .obj([("name", .str(snippet.name)), ("keyword", .str(snippet.keyword)), ("contentCharacterCount", .n(snippet.content.count))]) : snippetJ(snippet)),
                ("url", long ? .null : .str(text)),
                ("urlCharacterCount", .n(text.count)),
                ("urlSHA256", .str(sha256Hex(Data(text.utf8)))),
                ("payloadJSON", long ? .null : utf8Text(json)),
                ("decoded", .obj([
                    ("name", .str(back.name)), ("keyword", .str(back.keyword)),
                    ("content", long ? .null : .str(back.content)), ("contentEqualsOriginal", .bool(back.content == snippet.content)),
                    ("tags", .strings(back.tags)), ("isEnabled", .bool(back.isEnabled)), ("isPinned", .bool(back.isPinned)),
                    ("idEqualsOriginal", .bool(back.id == snippet.id)),
                ])),
            ]))
        }
        cases.append(vcase("link-encode-secure-refused", [
            ("kind", .str("link-encode")),
        ] + outcome { .str(try SnippetDeepLink.url(for: shareable[0].1, isSecure: true).absoluteString) }))

        func payloadLink(_ json: String) -> String {
            "snippets://share?data=" + Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let data = String(firstLink.dropFirst("snippets://share?data=".count))
        let links: [(String, String)] = [
            ("share-ok", firstLink),
            ("share-uppercase-scheme-and-host", "SNIPPETS://SHARE?data=\(data)"),
            ("share-with-path-and-fragment", "snippets://share/ignored/path?data=\(data)#frag"),
            ("share-padded-base64", "snippets://share?data=\(data)" + String(repeating: "=", count: (4 - data.count % 4) % 4)),
            ("share-standard-base64-alphabet", "snippets://share?data=" + data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
            ("share-extra-query-items", "snippets://share?x=1&data=\(data)&data=ignored"),
            ("share-data-uppercase-name", "snippets://share?DATA=\(data)"),
            ("share-missing-data", "snippets://share"),
            ("share-empty-data", "snippets://share?data="),
            ("share-data-not-base64", "snippets://share?data=***"),
            ("share-data-not-json", payloadLink("hello")),
            ("share-version-2", payloadLink("{\"content\":\"c\",\"keyword\":\"k\",\"name\":\"n\",\"version\":2}")),
            ("share-version-missing", payloadLink("{\"content\":\"c\",\"keyword\":\"k\",\"name\":\"n\"}")),
            ("share-version-string", payloadLink("{\"content\":\"c\",\"keyword\":\"k\",\"name\":\"n\",\"version\":\"1\"}")),
            ("share-missing-keyword", payloadLink("{\"content\":\"c\",\"name\":\"n\",\"version\":1}")),
            ("share-extra-keys-and-flags", payloadLink("{\"content\":\"c\",\"keyword\":\" \\\\k w \",\"name\":\"n\",\"tags\":[\" A \",\"a\",\"\"],\"version\":1,\"isEnabled\":false,\"isPinned\":true,\"id\":\"x\"}")),
            ("share-tags-null", payloadLink("{\"content\":\"c\",\"keyword\":\"k\",\"name\":\"n\",\"tags\":null,\"version\":1}")),
            ("share-all-empty", payloadLink("{\"content\":\"\",\"keyword\":\"\",\"name\":\"\",\"version\":1}")),
            ("new-all-fields", "snippets://new?name=My%20Name&keyword=my%20key&content=line1%0Aline2&tags=a,b,%20A%20,,c%20d"),
            ("new-uppercase-names", "snippets://NEW?NAME=N&Keyword=K&CONTENT=C&TAGS=x"),
            ("new-plus-stays-plus", "snippets://new?name=a+b&content=1%2B1"),
            ("new-only-name", "snippets://new?name=Only"),
            ("new-only-keyword", "snippets://new?keyword=%5Ckw"),
            ("new-only-tags", "snippets://new?tags=a,b"),
            ("new-empty", "snippets://new"),
            ("new-empty-values", "snippets://new?name=&keyword=&content="),
            ("new-duplicate-items-first-wins", "snippets://new?name=first&name=second&content=c"),
            ("new-unicode", "snippets://new?name=Caf%C3%A9%20%E2%98%95&content=%F0%9F%94%91"),
            ("new-encoded-ampersand-and-equals", "snippets://new?name=a%26b%3Dc&content=x"),
            ("other-host", "snippets://open?data=\(data)"),
            ("other-scheme", "https://share?data=\(data)"),
            ("no-host", "snippets:share?data=\(data)"),
            ("snippets-cli-scheme", "snippet://share?data=\(data)"),
        ]
        for (name, text) in links {
            var members: [(String, J)] = [("kind", .str("link-parse")), ("url", .str(text))]
            if let url = URL(string: text) {
                members.append(("canHandle", .bool(SnippetDeepLink.canHandle(url))))
                members.append(("isCreationLink", .bool(SnippetDeepLink.isCreationLink(url))))
                members += outcome {
                    let snippet = try SnippetDeepLink.snippet(from: url)
                    return .obj([
                        ("name", .str(snippet.name)), ("keyword", .str(snippet.keyword)),
                        ("content", .str(snippet.content)), ("tags", .strings(snippet.tags)),
                        ("isEnabled", .bool(snippet.isEnabled)), ("isPinned", .bool(snippet.isPinned)),
                    ])
                }
            } else {
                members.append(("urlParses", .bool(false)))
            }
            cases.append(vcase("link-parse-\(name)", members))
        }
        return VectorFile(
            name: "L06-keywords-import-links",
            pins: "KeywordSuggestions (candidates, existingMatches, tabCompletion), KeywordRelation, SnippetImportParser (native and Raycast dialects), SnippetDeepLink encode and parse (brief 01 §6)",
            notes: [
                "KeywordRelation.between compares its inputs as given; callers pass folded keywords (relationOfFolded). relationOfRaw shows the unfolded call.",
                "Raycast imports and link parses create a fresh UUID and use the current time for both dates; those fields are not recorded.",
                "SnippetDeepLink has no size limit: link-encode-long-content is a 100 000-character body (URL recorded by length and SHA-256 only).",
                "A parsed link yields an enabled, unpinned snippet; the iOS coordinator disables it on import.",
            ],
            cases: cases)
    }
}
