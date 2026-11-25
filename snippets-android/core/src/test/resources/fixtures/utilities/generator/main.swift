import Foundation

// Emits fixtures for the Kotlin utilities port by running the unmodified Swift sources.
// Usage: probe <section> > file.tsv

func hex(_ text: String) -> String {
    let bytes = Array(text.utf8)
    return bytes.isEmpty ? "-" : bytes.map { String(format: "%02x", $0) }.joined()
}

func header(_ lines: [String]) {
    print("# Generated from the unmodified Swift sources (snippets/Core) by the utilities probe. Do not edit.")
    print("# macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    for line in lines { print("# " + line) }
}

let section = CommandLine.arguments.dropFirst().first ?? ""

func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "5ea4c400-0000-4000-8000-%012x", n))! }

switch section {
case "fuzzy":
    header(["locale en_US. query<TAB>target<TAB>matched<TAB>score<TAB>ranges (start:length, UTF-16)<TAB>foldedTarget<TAB>matchesFoldedTarget; text fields are UTF-8 hex, - is empty"])
    let locale = Locale(identifier: "en_US")
    let targets = ["Café", "Cafe\u{301}", "Straße", "ßss ß", "İIıi", "Привет мир",
                   "👩🏽‍💻 cafe", "🇫🇷 Français", "ﬃ file", "a\r\nb", "Kelvin", "\u{301}a",
                   "Hello World", "snake_case_name", "camelCaseName", "ⅷ roman", "x\u{20dd}y", "가나다 한글",
                   "e\u{301}e\u{301}", "A1B2", "..a..b", "Ǆungla", "ǅ", "ΣΊΣΥΦΟΣ", "ﬆop", "ŉ", "ǰ", "ΐ", "İ\u{307}"]
    let queries = ["", "cafe", "é", "ss", "sss", "i", "I", "ı", "прм", "👩🏽‍💻", "ffi", "ab", "\r\n", "k",
                   "hw", "scn", "ccn", "ee", "가", "한글", "ab ", "dz", "σς", "st", "n", "j", "ι", "viii", "xy"]
    var workspace = FuzzyMatch.Workspace()
    for target in targets {
        for query in queries {
            let preparedQuery = FuzzyMatch.PreparedQuery(query, locale: locale)
            let result = FuzzyMatch.score(query: preparedQuery, target: .init(target, locale: locale), workspace: &workspace)
            let folded = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            let ranges = result.matchedRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            print([hex(query), hex(target), result.matched ? "1" : "0", String(result.score), ranges.isEmpty ? "-" : ranges,
                   hex(folded), FuzzyMatch.matches(query: preparedQuery, foldedTarget: folded) ? "1" : "0"].joined(separator: "\t"))
        }
    }

case "substring":
    header(["text<TAB>query<TAB>String.contains<TAB>PreparedSubstringSearch; UTF-8 hex, - is empty"])
    let texts = ["", "abc xyz", "aaaaab", "a\0b", "a\r\nb", "K", "`", "Café", "Cafe\u{301}",
                 "👩🏽‍💻 code", "👩", "東京", "Σςσ", "Ångström", "가", "\u{1100}\u{1161}",
                 "🇦🇧🇨🇩", "x\u{301}y", "\r\n\r\n", "a\r\n", "\u{37e}", "e\u{328}\u{301}"]
    let queries = ["", "a", "ab", "ba", "aaab", "aaaba", "zy", "\0", "\r", "\n", "\r\n", "K", "\u{212a}", "`",
                   "é", "e\u{301}", "👩", "🏽", "💻", "東京", "σ", "Å", "A\u{30a}", "가", "\u{1100}\u{1161}",
                   "🇧🇨", "🇨🇩", "\u{301}", "x", "x\u{301}", ";", "e\u{301}\u{328}", "\n\r", "\u{1fef}"]
    for text in texts {
        let field = PreparedSubstringSearch.Field(text)
        for query in queries {
            print([hex(text), hex(query), text.contains(query) ? "1" : "0", field.contains(.init(query)) ? "1" : "0"].joined(separator: "\t"))
        }
    }

case "settings":
    header(["platform<TAB>query (UTF-8 hex)<TAB>row ids in result order, comma separated; - is none"])
    var queries = ["", " ", "backup", "encrypted backup", "browser bundle", "launch startup", "command line", "clipboard",
                   "command shift v", "clear clipboard", "clipboard exclude", "sync", "SYNC", "sýnc", "sync now", "now sync",
                   "vault", "key", "recovery", "recovery key", "json", "export", "import", "logs", "diagnostics", "about",
                   "github", "git", "icloud", "account", "cloud", "password", "restore", "privacy", "version", "license",
                   "secure", "secure snippets", "snippets", "s", "a", "e", "lock", "lock now", "delete", "file", "zzz",
                   "sync  status", "status", "state", "storage", "the", "library", "support", "export logs", "ex lo",
                   "Sécure", "  vault  key ", "b\tk", "re", "st", "up", "cli", "terminal", "history", "7 days", "mit"]
    for entry in SettingsCatalog.entries(for: .macOS) {
        queries.append(entry.title)
        queries.append(String(entry.title.prefix(4)))
    }
    for (name, platform) in [("macOS", SettingsPlatform.macOS), ("iOS", SettingsPlatform.iOS)] {
        for query in queries {
            let rows = SettingsCatalog.search(query, platform: platform).map(\.rowID.rawValue).joined(separator: ",")
            print([name, hex(query), rows.isEmpty ? "-" : rows].joined(separator: "\t"))
        }
    }

case "settings-catalog":
    header(["platform<TAB>rowID<TAB>title<TAB>detail<TAB>destination; then sections as platform<TAB>#section<TAB>title<TAB>destinations"])
    for (name, platform) in [("macOS", SettingsPlatform.macOS), ("iOS", SettingsPlatform.iOS)] {
        for entry in SettingsCatalog.entries(for: platform) {
            print([name, entry.rowID.rawValue, entry.title, entry.detail ?? "", entry.destination.rawValue].joined(separator: "\t"))
        }
        for sectionEntry in SettingsCatalog.navigationSections(for: platform) {
            print([name, "#section", sectionEntry.title, sectionEntry.destinations.map(\.rawValue).joined(separator: ",")].joined(separator: "\t"))
        }
    }

case "keywords":
    header(["candidates<TAB>name<TAB>firstLine<TAB>result (comma separated, plain ASCII; - is none)",
            "existing<TAB>query<TAB>among (hex, ; separated)<TAB>matches (hex, ; separated; - is none)<TAB>tabCompletion (hex; nil)",
            "relation<TAB>keyword<TAB>other<TAB>relation of the folded pair<TAB>relation of the raw pair"])
    let phrases: [(String, String)] = [
        ("Signature Block", "Best regards"), ("Email", ""), ("Café Order", ""), ("", "https://github.com/mike/snippets"),
        ("", "Thanks so much for the update"), ("", ""), ("日本語", "こんにちは"), ("A", ""), ("A B", ""),
        ("Invoice", "Invoice for services"), ("", "\nSecond line is not a name"), ("K elvin", "Ångström unit"),
        ("1\u{20e3} keycap", "e\u{301}cole"), ("a\r\nb", "x\r\ny z"), ("ǅungla ǆ", "ŉ ǰ"), ("ΣΊΣΥΦΟΣ", "Привет мир"),
        ("abcdefg hijklmn", "opqrstu"), ("abcdef", "ghijkl"), ("a b c d e f g h", "www.example.org"), ("http://x", "https"),
        ("Ünïcödé Nämé", "ñandú"), ("ß", "ßß"), ("ﬃ", "ﬆ"), ("x1 y2 z3", "007"), ("UPPER lower", "MiXeD"),
        ("tab\tseparated", "nb\u{a0}sp"), ("under_score", "dash-ed"), ("👩🏽‍💻dev", "a👩b"), ("İİ", "ıı"), ("Æsop", "Œuvre"),
    ]
    for (name, line) in phrases {
        let result = KeywordSuggestions.candidates(name: name, contentFirstLine: line).joined(separator: ",")
        print(["candidates", hex(name), hex(line), result.isEmpty ? "-" : result].joined(separator: "\t"))
    }
    let libraries: [[String]] = [
        ["doc.frontend", "doc.backend", "docs", "Doc.Frontend", "café.docs", "sig", "sign", "signature", "my-key", "a.b.c", "b.a", "front.doc", "api.doc.v2", "", "  ", "\\tp", "x doc"],
        ["frontend.doc", "doc.backend", "product"], ["other", "doc.frontend", "doc.backend"],
        ["doc.frontend", "doc.backend", "frontend.design"], ["cafe.doc.extra", "Café.Doc", "cafe.doc", "other.cafe.doc"],
        ["doc.frontend"], ["doc.frontend.controls"], ["my-signature.work"], ["doc.frontend", "doc.framework"],
        ["café.docs"], ["Straße.work"], ["cafe\u{301}.docs"], ["doc"], ["Straße.work", "strasse.home"],
        ["ǅungla.x", "dzungla.y"], ["👩🏽‍💻.dev", "👩.dev"], ["a\u{301}b.c", "áb.d"], ["İstanbul.tr", "istanbul.en"],
        ["x..y", ".x", "x.", "..."], ["ab.cd.ef", "cd.ab", "ef.cd.ab.gh"], ["가나.다", "가.나"], ["a-b-c", "a-b.d", "a-c"],
    ]
    let queries = ["do", "doc", "doc.", "doc.f", "DOC", "front", "doc.front", "front.doc", "frontend.doc", "front.do", "\\CAFÉ.DOC",
                   "doc.doc", " ", "", "my", "frontend", "CAF", "doc.frontend", "Stra", "STRAS", "stras", "straß", "strasse",
                   "dz", "ǆ", "D", "👩", "👩🏽‍💻", "a", "á", "A\u{301}", "i", "I", "İ", "x", "x.", ".", "ab.cd", "cd.ab", "ef.ab",
                   "가", "가나", "a-", "a-b", "a b", "s", "sig", "caf", "café", "cafe\u{301}", "b.a", "a.c", "c.a", "v2.api", "d.f", "tp"]
    for library in libraries {
        for query in queries {
            let matches = KeywordSuggestions.existingMatches(query: query, among: library)
            let tab = KeywordSuggestions.tabCompletion(query: query, among: library)
            print(["existing", hex(query), library.map(hex).joined(separator: ";"),
                   matches.isEmpty ? "-" : matches.map(hex).joined(separator: ";"), tab.map(hex) ?? "nil"].joined(separator: "\t"))
        }
    }
    func fold(_ keyword: String) -> String { SnippetTagging.filterKey(for: Snippet.sanitizedKeyword(keyword)) }
    let pairs: [(String, String)] = [("email", "em"), ("em", "email"), ("sig", "sig"), ("sig2", "sig"), ("sig", "tp"), ("em", "Email"),
                                     ("email", "EM"), ("\\CAFÉ", "cafe"), ("", "email"), ("", ""), ("e\u{301}", "é"), ("é", "e\u{301}x"),
                                     ("a\u{301}", "a"), ("a", "a\u{301}"), ("👩", "👩🏽‍💻"), ("K", "\u{212a}"), ("가", "가나"), ("\u{1100}", "가")]
    for (keyword, other) in pairs {
        print(["relation", hex(keyword), hex(other), "\(KeywordRelation.between(fold(keyword), fold(other)))",
               "\(KeywordRelation.between(keyword, other))"].joined(separator: "\t"))
    }

case "tags":
    header(["case<TAB>ordinary tags per snippet (hex; tags ; separated, snippets | separated)<TAB>secure tags (same)<TAB>tagUsage as hex:count ; separated<TAB>tagKeys (hex, sorted, ; separated)"])
    let cases: [([[String]], [[String]])] = [
        ([["Work"]], [["wörk"]]),
        ([["Work", "mail"], ["Work", "Projects"], [], ["Français", "food"], ["Adresse", "home"], ["日本語"], ["dev", "Work"], ["misc"]], [["home", "Secret"], ["Secret"]]),
        ([["b", "B", "a", "A"], ["Z", "z", "É", "e", "E", "é"], ["ß", "ss", "SS"], ["10", "9", "1", "a1", "A2"]], []),
        ([["Äpfel", "apfel", "Zebra", "zebra", "Öl", "ol", "ñ", "n", "o"], ["_x", "-x", "x", " x", "X", "~x", "[x]"]], [["İstanbul", "istanbul", "ıstanbul", "ISTANBUL"]]),
        ([["Ελληνικά", "ελληνικά", "Кириллица", "кириллица", "日本", "にほん", "한국어", "😀", "😃", "a😀"]], [["ǅ", "ǆ", "Ǆ", "dz", "DZ"]]),
        ([["e\u{301}", "é", "f", "e", "E\u{301}"], ["ſ", "s", "S", "ς", "σ", "Σ"]], []),
    ]
    var index = 0
    for (ordinaryTags, secureTags) in cases {
        var n = 0
        func snippets(_ tagLists: [[String]]) -> [Snippet] {
            tagLists.map { tags in n += 1; return Snippet(id: uuid(n), name: "n", keyword: "", content: "", tags: tags) }
        }
        var projection = SnippetLibraryProjection()
        let ordinary = snippets(ordinaryTags)
        let secure = snippets(secureTags)
        let snapshot = projection.snapshot(ordinary: ordinary, secure: secure, locale: Locale(identifier: "en_US"))
        func encode(_ lists: [Snippet]) -> String {
            let text = lists.map { $0.tags.map(hex).joined(separator: ";") }.joined(separator: "|")
            return text.isEmpty ? "-" : text
        }
        print(["tags-\(index)", encode(ordinary), encode(secure),
               snapshot.tagUsage.map { "\(hex($0.tag)):\($0.count)" }.joined(separator: ";"),
               snapshot.tagKeys.sorted().map(hex).joined(separator: ";")].joined(separator: "\t"))
        index += 1
    }

case "grammar":
    header(["template (UTF-8 hex)<TAB>containsResolvablePlaceholder<TAB>containsClipboardPlaceholder<TAB>isResolvablePlaceholder",
            "The process locale does not matter here: no date is formatted. Bodies of exactly `date \"`, `time \"` and `datetime \"` trap the Swift resolver and are absent."])
    var templates: [String] = [
        "{clipboard}", "{clipboard}\u{301}", "{clipboard\u{301}}", "{date:\u{301}yyyy}", "{date \u{301}format=\"yyyy\"}",
        "{date format=\u{301}\"yyyy\"}", "{date format=\"yyyy\"\u{301}}", "{date \"yyyy\"\u{301}}", "{date format=\"a\"\u{301}b\"}",
        "{date format=\"yy'\u{301}yy\"}", "{date format=\"yy''\u{301}yy\"}", "{date format=\"'\u{301}\"}", "{date offset=+1\u{301}d}",
        "{date offset=+1d\u{301}}", "{date offset=\"+1d \u{301}\"}", "{date offset=+\u{661}d}", "{date offset=+1d\u{a0}+1d}",
        "{date offset=+01d}", "{date offset=+000000000000000000000000001d}", "{date offset=+99999999999999999999d}",
        "{date offset=+100000y}", "{date offset=-100000y}", "{date offset=+100000M}", "{date offset=+100000h}", "{date offset=+100000m}",
        "{date offset=+1m}", "{date offset=+1h}", "{date offset=+1M}", "{date offset=+1y}", "{date offset=++1d}", "{date offset=+-1d}",
        "{date offset=+1dd}", "{date offset=+1 d}", "{date offset=\"+1d\"\"+1d\"}", "{date offset=\"+1d\" }", "{date offset=\"+1d\"  }",
        "{date  offset=+1d   format=\"yyyy\"}", "{date format=\"yyyy\" offset=+1d locale=\"fr\"}", "{date offset=+1d locale=\"fr\" format=\"y\"}",
        "{date locale=\"fr\" offset=+1d}", "{date locale=\"fr\" offset=+1d offset=+1d}", "{date a=1 b=2 c=3 d=4}", "{date offset=+1d offset=+1d offset=+1d offset=+1d}",
        "{date =x}", "{date =}", "{date x=}", "{date x}", "{date \"\"\"}", "{date \"a\"b\"}", "{date \"a b\"}", "{date \"'a'\"}",
        "{date \"yyyy\" }", "{date  \"yyyy\"}", "{date \"yyyy\"x}", "{time \"HH\"}", "{datetime \"y\"}", "{datetime:}", "{datetime:y}",
        "{time:HH:mm}", "{time: HH}", "{date:yyyy-MM-dd}", "{date:é}", "{date:y\u{301}}", "{date:y y}", "{date:y'y}", "{date:y\"}", "{date:y=}",
        "{date:_}", "{date:-}", "{date::}", "{date:0}", "{date:\u{ff11}}", "{date:y\u{2028}}", "{date\u{2028}}", "{date:y\u{85}}", "{date:y\u{b}}",
        "{date:y\u{c}}", "{date format=\"y\u{2028}y\"}", "{date format=\"y\u{b}y\"}", "{date format=\"y\ty\"}", "{date format=\"y\u{0}y\"}",
        "{date format=\"y{y\"}", "{date format=\"y y\"}", "{date format=\" \"}", "{date format=\"'\"}", "{date format=\"''\"}", "{date format=\"'''\"}",
        "{date format=\"''''\"}", "{date format=\"'a''b'\"}", "{date format=\"'a'''\"}", "{date format=\"a'b\"}", "{date format=\"😀\"}",
        "{date format='yyyy'}", "{date format=“yyyy”}", "{date FORMAT=\"yyyy\"}", "{date Format=\"yyyy\"}", "{date forma\u{74}=\"yyyy\"}",
        "{date locale=\"fr\"}", "{date locale=\"FR\"}", "{date locale=\"fr-fr\"}", "{date locale=\"fr-Latn\"}", "{date locale=\"fr-FR-u-ca-buddhist\"}",
        "{date locale=\"fr-u-hc-h12\"}", "{date locale=\"f\"}", "{date locale=\"fra\"}", "{date locale=\"fre\"}", "{date locale=\"fran\"}", "{date locale=\"fr-\"}",
        "{date locale=\"-fr\"}", "{date locale=\"fr--FR\"}", "{date locale=\"fr-FR-\"}", "{date locale=\"fr-123456789\"}", "{date locale=\"fr-12345678\"}",
        "{date locale=\"en-US-POSIX\"}", "{date locale=\"en-001\"}", "{date locale=\"en-150\"}", "{date locale=\"zh-Hans\"}", "{date locale=\"zh-Hans-CN\"}",
        "{date locale=\"zh-CN\"}", "{date locale=\"zh-TW\"}", "{date locale=\"zh\"}", "{date locale=\"sr\"}", "{date locale=\"sr-Cyrl\"}", "{date locale=\"sr-RS\"}",
        "{date locale=\"e\"}", "{date locale=\"en\"}", "{date locale=\"en-U\"}", "{date locale=\"en-u-ca-gregory\"}", "{date locale=\"en-x-private\"}",
        "{date locale=\"en-US-x-private\"}", "{date locale=\"en@calendar=buddhist\"}", "{date locale=\"en-US@x\"}", "{date locale=\"und\"}",
        "{date locale=\"root\"}", "{date locale=\"tlh\"}", "{date locale=\"haw\"}", "{date locale=\"haw-US\"}", "{date locale=\"en-us\"}", "{date locale=\"EN-US\"}",
        "{date locale=\"en-US\" locale=\"fr\"}", "{date locale=\"e\u{301}n\"}", "{date locale=\"en\u{301}\"}", "{date locale=\" en\"}", "{date locale=\"en \"}",
        "{date locale=\"en-GB-oxendict\"}", "{date locale=\"de-CH-1901\"}", "{date locale=\"ca-ES-valencia\"}", "{date locale=\"ca-valencia\"}",
        "{date locale=\"en-Latn-US\"}", "{date locale=\"az-Cyrl-AZ\"}", "{date locale=\"az-Cyrl\"}", "{date locale=\"az-AZ\"}", "{date locale=\"uz-Arab\"}",
        "x{date}y", "{date}{date}", "{{date}}", "{date}}", "{{date}", "{date\r}", "{\rdate}", "{date\n}", "a{b{clipboard}c}d", "{{clipboard}", "{clipboard}}",
        "{clipboard}{", "}{clipboard}", "{}{clipboard}", "{ {clipboard} }", "{clipboard} {clipboard}", "{a}{clipboard}{b}", "{", "}", "}{", "{}", "",
        "{date} {nonsense}", "{nonsense} {time}", "{CLIPBOARD} {clipboard}", "clipboard", "{clipboard", "clipboard}", "{clip\u{200d}board}", "{\u{feff}date}",
        "{date\u{feff}}", "{dateː}", "{time}", "{datetime}", "{date }", "{date  }", "{ date}", "{date\t}", "{date\u{a0}}", "{date\u{a0}format=\"y\"}",
        "{date format=\"y\"\u{a0}offset=+1d}", "{date format=\"y\" \u{a0}offset=+1d}",
    ]
    templates.append("{date " + String(repeating: " ", count: 1010) + "format=\"yyyy\"}")
    templates.append("{date " + String(repeating: " ", count: 1011) + "format=\"yyyy\"}")
    templates.append("{date " + String(repeating: " ", count: 1012) + "format=\"yyyy\"}")
    templates.append("{date format=\"" + String(repeating: "y", count: 512) + "\"}")
    templates.append("{date format=\"" + String(repeating: "y", count: 513) + "\"}")
    templates.append("{date format=\"" + String(repeating: "e\u{301}", count: 512) + "\"}")
    templates.append("{date format=\"" + String(repeating: "e\u{301}", count: 513) + "\"}")
    templates.append("{date format=\"" + String(repeating: "👩🏽‍💻", count: 200) + "\"}")
    templates.append("{date locale=\"en" + String(repeating: "-abcdefgh", count: 6) + "-abcdefg\"}")
    templates.append("{date locale=\"en" + String(repeating: "-abcdefgh", count: 6) + "-abcdefgh\"}")
    templates.append("{date locale=\"en-US" + String(repeating: "-u-abcde", count: 7) + "\"}")
    templates.append("{date:" + String(repeating: "y", count: 5000) + "}")
    templates.append("{date offset=\"" + String(repeating: "+1d ", count: 8) + "\"}")
    templates.append("{date offset=\"" + String(repeating: "+1d ", count: 9) + "\"}")
    for template in templates {
        print([hex(template),
               PlaceholderResolver.containsResolvablePlaceholder(in: template) ? "1" : "0",
               PlaceholderResolver.containsClipboardPlaceholder(in: template) ? "1" : "0",
               PlaceholderResolver.isResolvablePlaceholder(template) ? "1" : "0"].joined(separator: "\t"))
    }

case "links":
    header(["url (UTF-8 hex)<TAB>URL(string:) parsed<TAB>canHandle<TAB>isCreationLink<TAB>ok|error<TAB>name<TAB>keyword<TAB>content<TAB>tags (hex, ; separated) or the error case"])
    func b64(_ json: String) -> String { Data(json.utf8).base64EncodedString() }
    func b64url(_ json: String) -> String {
        b64(json).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let payload = #"{"content":"c>>>???","keyword":"k","name":"n~~~","tags":["a"],"version":1}"#
    let p1 = #"{"content":"c","keyword":"k","name":"n","version":1}"#     // 52 bytes: needs one =
    let p2 = #"{"content":"cc","keyword":"k","name":"n","version":1}"#    // needs ==
    let p0 = #"{"content":"ccc","keyword":"k","name":"n","version":1}"#   // no padding
    var urls: [String] = [
        "snippets://share?data=" + b64url(payload), "snippets://share?data=" + b64(payload),
        "snippets://share?data=" + b64url(p1), "snippets://share?data=" + b64(p1), "snippets://share?data=" + b64url(p1) + "==",
        "snippets://share?data=" + b64url(p1) + "===", "snippets://share?data=" + b64url(p1) + "====",
        "snippets://share?data=" + b64url(p2), "snippets://share?data=" + b64(p2), "snippets://share?data=" + b64url(p2) + "=",
        "snippets://share?data=" + b64url(p2) + "===", "snippets://share?data=" + b64url(p0), "snippets://share?data=" + b64(p0) + "=",
        "snippets://share?data=" + b64(p0) + "==", "snippets://share?data=" + b64(p0) + "====",
        "snippets://share?data=" + b64(p0) + b64(p0), "snippets://share?data=" + b64(p2) + b64(p2), "snippets://share?data=" + b64(p1) + b64(p1),
        "snippets://share?data=" + String(b64(p0).dropLast()), "snippets://share?data=" + String(b64(p0).dropLast(2)),
        "snippets://share?data=" + String(b64(p0).dropLast(3)), "snippets://share?data=%20" + b64(p0), "snippets://share?data=" + b64(p0) + "%0A",
        "snippets://share?data=" + b64(p0) + "%20", "snippets://share?data=" + String(b64(p0).prefix(8)) + "%0A" + String(b64(p0).dropFirst(8)),
        "snippets://share?data=" + String(b64(p0).prefix(8)) + "=" + String(b64(p0).dropFirst(8)),
        "snippets://share?data=" + String(b64(p0).prefix(8)) + "." + String(b64(p0).dropFirst(8)),
        "snippets://share?data=" + String(b64(p0).prefix(8)) + "%00" + String(b64(p0).dropFirst(8)),
        "snippets://share?data=" + b64(p0).replacingOccurrences(of: "e", with: "%65"),
        "snippets://share?data=" + String(b64(p2).dropLast(3)) + "R==", "snippets://share?data=" + String(b64(p2).dropLast(3)) + "Z==",
        "snippets://share?data=====", "snippets://share?data==", "snippets://share?data=%3D%3D%3D%3D", "snippets://share?data=A", "snippets://share?data=AA",
        "snippets://share?data=AAA", "snippets://share?data=AAAA", "snippets://share?data=e30", "snippets://share?data=W10", "snippets://share?data=bnVsbA",
        "snippets://share?data", "snippets://share?data&x=1", "snippets://share?data&data=" + b64url(p0), "snippets://share?=" + b64url(p0),
        "snippets://share?data=" + b64url(p0) + "&data=zzz", "snippets://share?data=zzz&data=" + b64url(p0), "snippets://share?%64ata=" + b64url(p0),
        "snippets://share?d%61ta=" + b64url(p0), "snippets://share?Data=" + b64url(p0), "snippets://share?data%20=" + b64url(p0),
        "snippets://share?;data=" + b64url(p0), "snippets://share?x=1;data=" + b64url(p0), "snippets://share?x&&data=" + b64url(p0) + "&&",
        "snippets://share/?data=" + b64url(p0), "snippets://share/a/b?data=" + b64url(p0), "snippets://share#data=" + b64url(p0),
        "snippets://share?data=" + b64url(p0) + "#x?data=zzz", "snippets://share?x=1#&data=" + b64url(p0),
        "snippets://share:80?data=" + b64url(p0), "snippets://share:?data=" + b64url(p0), "snippets://share:abc?data=" + b64url(p0),
        "snippets://user@share?data=" + b64url(p0), "snippets://user:pw@share:1?data=" + b64url(p0), "snippets://@share?data=" + b64url(p0),
        "snippets://share@new?name=x", "snippets://new@share?name=x", "snippets://Share?data=" + b64url(p0), "snippets://sh%61re?data=" + b64url(p0),
        "snippets://sh%41RE?data=" + b64url(p0), "snippets://share.?data=" + b64url(p0), "snippets://share.com?data=" + b64url(p0),
        "snippets://www.share?data=" + b64url(p0), "snippets://[share]?data=" + b64url(p0), "snippets://[::1]?data=" + b64url(p0),
        "snippets:///share?data=" + b64url(p0), "snippets:////share?data=" + b64url(p0), "snippets:/share?data=" + b64url(p0), "snippets:share?data=" + b64url(p0),
        "snippets://?data=" + b64url(p0), "snippets://", "snippets:", "snippets", "", " ", "://share?data=" + b64url(p0), "//share?data=" + b64url(p0),
        "Snippets://share?data=" + b64url(p0), "SNIPPETS://NEW?name=x", "sNiPpEtS://nEw?nAmE=x", "snippets ://share?data=" + b64url(p0),
        " snippets://share?data=" + b64url(p0), "snippets://share?data=" + b64url(p0) + " ", "snippets://share ?data=" + b64url(p0),
        "snippets://sha re?data=" + b64url(p0), "snippets://share?data=" + b64url(p0) + "\n", "\nsnippets://new?name=x", "snippets://new?name=x\ny",
        "snippets://new?name=a b", "snippets://new?name=a\tb", "snippets://new?name=é", "snippets://new?name=日本語&content=😀", "snippets://new?name=%E6%97%A5",
        "snippets://new?name=100%", "snippets://new?name=100%25", "snippets://new?name=%", "snippets://new?name=%2", "snippets://new?name=%zz", "snippets://new?name=%G1x",
        "snippets://new?name=%FF", "snippets://new?name=%C3", "snippets://new?name=%C3%28", "snippets://new?name=%E2%82", "snippets://new?name=%ED%A0%80",
        "snippets://new?name=%00", "snippets://new?name=a%00b", "snippets://new?name=%0A%0D", "snippets://new?name=%7B%7D", "snippets://new?name={x}",
        "snippets://new?name=\"q\"", "snippets://new?name=<x>", "snippets://new?name=a|b^c`d\\e", "snippets://new?name=[x]", "snippets://new?name=a#b", "snippets://new?name=a%23b",
        "snippets://new?name=a?b", "snippets://new?name=a/b", "snippets://new?name=a=b=c", "snippets://new?name==", "snippets://new?name", "snippets://new?name&content=c",
        "snippets://new?name&name=second", "snippets://new?name=&name=second", "snippets://new?NAME&name=second", "snippets://new?n%61me=x", "snippets://new?na%4De=x",
        "snippets://new?name%20=x", "snippets://new?%20name=x", "snippets://new?name=x&NAME=y", "snippets://new?Name=x&name=y", "snippets://new?İname=x",
        "snippets://new?content=c&tags=", "snippets://new?content=c&tags=,", "snippets://new?content=c&tags=a%2Cb", "snippets://new?content=c&tags=a,,b,%20,a,A",
        "snippets://new?content=c&tags=a&tags=b", "snippets://new?content=c&tags", "snippets://new?content=c&tags=a%20%20b,%0Ac", "snippets://new?content=c&tags=é,e\u{301},E",
        "snippets://new?keyword=%5C%5Ckw%20x", "snippets://new?keyword=%20%20", "snippets://new?keyword=a%0Ab", "snippets://new?keyword=!kw", "snippets://new?keyword=%5C",
        "snippets://new?content=%20", "snippets://new?content=+", "snippets://new?content=%2B", "snippets://new?content=a+b%20c", "snippets://new?content=a&content=b",
        "snippets://new?name=x;keyword=y", "snippets://new?name=x&amp;keyword=y", "snippets://new/?name=x", "snippets://new/path?name=x", "snippets://new#name=x",
        "snippets://new?name=x#frag", "snippets://new?#name=x", "snippets://new??name=x", "snippets://new?&name=x", "snippets://new?name=x&", "snippets://new?=x&name=y",
        "snippets://new:8080?name=x", "snippets://u:p@new?name=x", "snippets://new.?name=x", "snippets://n%65w?name=x", "snippets://new%20?name=x",
        "snippets://share?name=x", "snippets://new?data=" + b64url(p0), "snippets://new?data=" + b64url(p0) + "&name=x",
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1.0}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1e0}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1.5}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":10e-1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":01}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":-1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":0}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":true}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":null}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":9223372036854775807}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":9223372036854775808}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1e400}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1,"version":2}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":2,"version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1,}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1} "#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1}x"#),
        "snippets://share?data=" + b64url(#" {"content":"c","keyword":"k","name":"n","version":1}"#),
        "snippets://share?data=" + b64url("\u{feff}" + #"{"content":"c","keyword":"k","name":"n","version":1}"#),
        "snippets://share?data=" + b64url(#"[{"content":"c","keyword":"k","name":"n","version":1}]"#),
        "snippets://share?data=" + b64url(#"{"content":null,"keyword":"k","name":"n","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":1,"keyword":"k","name":"n","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":null,"name":"n","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":null,"version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","tags":"a","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","tags":[1],"version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","tags":[null],"version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","tags":[],"version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","tags":["B","b"," x  y ","\n"],"version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"é😀\/\n","keyword":"\\\\k k","name":"\t","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"\ud83d","keyword":"k","name":"n","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"\x","keyword":"k","name":"n","version":1}"#),
        "snippets://share?data=" + b64url(#"{"Content":"c","keyword":"k","name":"n","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1,"extra":"\x"}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"k","name":"n","version":1,"extra":01}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","content":"d","keyword":"k","name":"n","version":1}"#),
        "snippets://share?data=" + b64url(#"{"content":"c","keyword":"!\\ k","name":"  n  ","version":1}"#),
    ]
    urls.append("snippets://share?data=" + String(repeating: "A", count: 4096))
    // Measured separately: trailing bits, padding in the middle, undecodable items, hosts and ports.
    let pG = #"{"content":"c","keyword":"k","name":"n","version":1}"#
    let part1 = #"{"content":"c","#
    let partA = #"{"content":"c", "#
    let partB = #""keyword":"k","name":"n","version":1}"#
    urls += [
  "snippets://share?data=" + b64(pG), "snippets://share?data=" + String(b64(pG).dropLast(3)) + "R==", "snippets://share?data=" + String(b64(pG).dropLast(3)) + "R",
  "snippets://share?data=" + String(b64(pG).dropLast(3)) + "Z==",
  "snippets://share?data=" + b64(partA) + b64(partB), "snippets://share?data=" + b64(part1) + b64(partB),
  "snippets://share?data=%FF", "snippets://share?data=%C3", "snippets://share?data=" + b64(pG) + "%FF", "snippets://share?%FF=x&data=" + b64(pG),
  "snippets://share?da%FFta=x&data=" + b64(pG),
  "snippets://new?%FF=x&name=y", "snippets://new?na%FFme=x&content=c", "snippets://new?name=%FF&name=x", "snippets://new?name=%FF&content=c", "snippets://new?content=c&tags=%FF,a",
  "snippets://ＮＥＷ?name=x", "snippets://new\u{3002}?name=x", "snippets://ne\u{ad}w?name=x", "snippets://ſhare?name=x", "snippets://shäre?name=x", "snippets://NEW\u{200b}?name=x",
  "snippets://a b@share?data=" + b64(pG), "snippets://share\\?data=" + b64(pG), "snippets://sha\tre?data=" + b64(pG), "snippets://new\\x?name=x", "snippets:\\\\new?name=x",
  "snip pets://new?name=x", "snippets+x://new?name=x", "1snippets://new?name=x", "snippets://new?name=x%", "snippets://new?name=%E2%82%AC%", "snippets://new?name=%e2%82%ac",
  "snippets://new?\u{212a}eyword=x&content=c", "snippets://new?NAME\u{301}=x&name=y", "snippets://new?name=\u{d7ff}", "snippets://new?name=a%2", "snippets://new?name=%%41", "snippets://new?name=%4",
  "snippets://new?name=%41%", "snippets://new?name=%2541", "snippets://[new]?name=x", "snippets://[NEW]:80?name=x", "snippets://new:65536?name=x", "snippets://new:-1?name=x", "snippets://new: 80?name=x",
  "snippets://user:pa:ss@new?name=x", "snippets://us@er@new?name=x", "snippets://new?name=x#a#b", "snippets://new/?/?name=x", "snippets://new;x?name=x", "snippets://new,x?name=x",
  "snippets://new!?name=x", "snippets://n_e-w?name=x", "snippets://%6Ee%77?name=x", "snippets://%4E%45%57?name=x", "snippets://ne%00w?name=x", "snippets://new%2F?name=x", "snippets://new%3Fname=x",
  "snippets://share?data=" + b64(pG).replacingOccurrences(of: "e", with: "\u{ff45}"),
  "SNIPPETS:new?name=x", "snippets:///new?name=x", "snippets://new?name=x\u{0}", "snippets://new?name=\u{0}x", "snippets\u{0}://new?name=x", "snippets://new?name=x\r\n", "snippets://new?name=\u{7f}",
  "snippets://new?name=\u{80}", "snippets://new?name=%80", "snippets://new?name=%7F", "snippets://new?name=a%20%20b", "snippets://new?name=%09",
  "snippets://new:99999999999999999999?name=x", "snippets://new:080?name=x", "snippets://:80?name=x", "snippets://@?name=x", "snippets://new@?name=x", "snippets://[new?name=x", "snippets://new]?name=x",
  "snippets://[ne]w?name=x", "snippets://new?name=[", "snippets://new?name=]", "snippets://new/[?name=x", "snippets://new#[", "snippets://u[@new?name=x",
    ]
    // A query that is not valid as written (a raw space, a non-ASCII character, a stray `%`)
    // is percent-encoded whole by `URL(string:)`, `%` included, so its escapes stay literal.
    urls += [
  "snippets://new?name=a b%20c", "snippets://new?name=é%41", "snippets://new?name=%41&content=100%", "snippets://new?name=100%&content=%41",
  "snippets://n%65w?name=%", "snippets://n%65w?name=a b", "snippets://new?name=%41#%", "snippets://new?name=%41#a b", "snippets://new/%?name=%41", "snippets://new/a b?name=%41",
  "snippets://u%@new?name=%41", "snippets://u ser@new?name=%41", "snippets://new?name=%41%20b c", "snippets://new?name=%e9", "snippets://new?name=é%e9", "snippets://new?na me=%41&name=x",
  "snippets://new?name=\u{1F511}%F0%9F%94%91", "snippets://new?name=%F0%9F%94%91\u{1F511}", "snippets://new?name=a\tb%09", "snippets://new?name=\"%22", "snippets://new?name=<%3C", "snippets://new?name={%7B",
  "snippets://new?name=[%5B", "snippets://new?name=|%7C", "snippets://new?name=^%5E", "snippets://new?name=`%60", "snippets://new?name=\\%5C", "snippets://new?name=#%23", "snippets://new?name=a%23#b c",
  "snippets://new?name=%41\n", "snippets://new?name=\u{0}%41", "snippets://new?name=\u{7f}%41", "snippets://new?name=%41\u{a0}", "snippets://sh%61re?data=a b", "snippets://[new]?name=a b%41",
  "snippets://new?name=%2541 x", "snippets://new?name=%25 x", "snippets://new?name=%zz%41", "snippets://new?name=%4g%41", "snippets://new?name=%%", "snippets://new?name=%%%41",
  "snippets://new?name=a+b c%2B", "snippets://share?data=e30%3D =", "snippets://new?%6Eame=a b", "snippets://new?name=%41&conte nt=x&content=%42",
  "snippets://ne w?name=x", "snippets://new?name=!$'()*,;:@/?%41", "snippets://new?name=!$'()*,;:@/? %41", "snippets://new?name=%C3%A9é", "snippets://new?name=é%C3%A9",
    ]
    for text in urls {
        guard let url = URL(string: text) else {
            print([hex(text), "0", "0", "0", "error", "noURL"].joined(separator: "\t"))
            continue
        }
        var fields = [hex(text), "1", SnippetDeepLink.canHandle(url) ? "1" : "0", SnippetDeepLink.isCreationLink(url) ? "1" : "0"]
        do {
            let snippet = try SnippetDeepLink.snippet(from: url)
            precondition(snippet.isEnabled && !snippet.isPinned)
            fields += ["ok", hex(snippet.name), hex(snippet.keyword), hex(snippet.content),
                       snippet.tags.isEmpty ? "-" : snippet.tags.map(hex).joined(separator: ";")]
        } catch {
            fields += ["error", "\(error)"]
        }
        print(fields.joined(separator: "\t"))
    }

case "link-encode":
    header(["name<TAB>keyword<TAB>content<TAB>tags (hex ; separated)<TAB>url; UTF-8 hex, - is empty"])
    let samples: [(String, String, String, [String])] = [
        ("n", "k", "c", []), ("", "", "", []), ("Café ☕ \"q\"", " \\my key ", "line1\nline2\r\n\ttab / slash \\ back", ["Ünï", "日本語"]),
        ("\u{0}\u{1}\u{1f}\u{7f}\u{80}\u{9f}", "", "\u{8}\u{c}\u{b}\u{2028}\u{2029}\u{feff}", ["a/b", "\"", "\\"]),
        ("😀", "e\u{301}", "👩🏽‍💻 <>&'", ["x", "X", " y "]), ("~~~", "???", ">>>", ["~", "?", ">"]),
    ]
    for (name, keyword, content, tags) in samples {
        let url = try! SnippetDeepLink.url(for: Snippet(name: name, keyword: keyword, content: content, tags: tags), isSecure: false)
        print([hex(name), hex(keyword), hex(content), tags.isEmpty ? "-" : tags.map(hex).joined(separator: ";"), url.absoluteString].joined(separator: "\t"))
    }

case "dates":
    header(["@<TAB>locale (BCP 47)<TAB>time zone<TAB>milliseconds since 1970 starts a group; its lines are",
            "tier<TAB>pattern (UTF-8 hex)<TAB>DateFormatter output (UTF-8 hex; - is empty)",
            "tier numeric: the output holds no locale text. tier text: basic English names."])
    var lastContext = ""
    let zones = ["UTC", "Europe/Paris", "America/New_York", "Asia/Kolkata", "Asia/Kathmandu"]
    let instants: [Double] = [
        1_769_902_215, 1_774_745_999.999, 1_774_746_000, 1_709_200_800, 1_785_340_805.75, 0, -0.5, 946_684_800,
        1_609_675_200, 1_735_560_000, 1_798_761_600, -12_219_638_400, -14_830_000_000, -62_135_596_800, -63_549_000_000,
        253_402_300_799, 327_403_382_400, 1_761_352_200, 1_774_661_400,
    ]
    let numeric = ["y", "yy", "yyy", "yyyy", "yyyyy", "yyyyyyyyyyyy", "Y", "YY", "YYYY", "u", "uu", "uuuu", "U", "UUUU", "r", "rr", "rrrr",
                   "M", "MM", "MMMMMM", "L", "LL", "LLLLLL", "d", "dd", "ddd", "D", "DD", "DDD", "DDDD", "F", "FF", "g", "gggggggg", "w", "ww", "www", "W", "WW",
                   "e", "ee", "c", "cc", "H", "HH", "HHH", "k", "kk", "h", "hh", "K", "KK", "m", "mm", "mmm", "s", "ss", "sss",
                   "S", "SS", "SSS", "SSSS", "SSSSSS", "SSSSSSSSSSSSSSSS", "A", "AAAAAAAAAAAA", "Q", "QQ", "q", "qq",
                   "Z", "ZZ", "ZZZ", "ZZZZZ", "X", "XX", "XXX", "XXXX", "XXXXX", "x", "xx", "xxx", "xxxx", "xxxxx",
                   "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyyMMdd-HHmmss", "''", "'a''b'", "''''", "yyyy'年'MM'月'", "yyyy年MM月dd日", "h 'o''clock'",
                   "yyyyp-MM", "yyyy-pMM", "p", "yyyy'x'p'y'MM", "yyyyp''MM", "yyyyp'q'MM", "yyyyl-MM", "lll", "yyyyjMM", "yyyy'unterminated MM", "ypy",
                   "HHtmm", "yyyy-MM-ddTHH", "yyyy MM dd", "y/M/d", "d.M.yy", "😀yy😀", "yy\u{301}y", " y ", "y''y", "y'''y", "foo", "it''s", "Y-ww", "YYYY-'W'ww-e",
                   "dC", "dI", "dJ", "dN", "dP", "dR", "dT", "df", "di", "dj", "dn", "do", "dp", "dt", "d:d", "d-", "d'", "d''",
                   "EEEEEEE-d", "eeeeeee-d", "ccccccc-d", "MMMMMMM-d", "LLLLLLL-d", "GGGGGG-d", "QQQQQQ-d", "qqqqqq-d", "vv-d", "vvv-d", "vvvvv-d", "VVVVV-d",
                   "OO-d", "OOO-d", "OOOOO-d", "XXXXXX-d", "xxxxxx-d", "UU-d", "UUU-d", "UUUUU-d", "FFF-d", "WWW-d", "ee-d", "GGGGGGG-d",
                   "yyyyyyyyyyyyyyyyyyyyy-d", "HHHHHHHHHHHH-d", "rrrrr", "uuuuu", "gg", "AA", "kkk", "KKK", "hhh", "DDDDD", "wwww", "EEEEEEEE-d", "cc-d", "c-d"]
    let text = ["MMM", "MMMM", "MMMMM", "LLL", "LLLL", "LLLLL", "E", "EE", "EEE", "EEEE", "EEEEE", "EEEEEE", "EEEEEEE", "eee", "eeee", "eeeee", "eeeeee",
                "ccc", "cccc", "ccccc", "cccccc", "a", "aa", "aaa", "aaaa", "aaaaa", "G", "GG", "GGG", "GGGG", "GGGGG", "QQQ", "QQQQ", "QQQQQ", "qqq", "qqqq", "qqqqq",
                "O", "OOOO", "ZZZZ", "EEEE, MMMM d, y 'at' h:mm a", "MMM d, yyyy", "EEE, d MMM yyyy HH:mm:ss Z", "aaaaaa-d", "ZZZZZZ-d", "ccc-d", "E-d"]
    func emit(_ localeTag: String, _ zone: String, _ instant: Double, _ tier: String, _ pattern: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeTag)
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.dateFormat = pattern
        let output = formatter.string(from: Date(timeIntervalSince1970: instant))
        let millis = Int64((instant * 1000).rounded(.down))
        let context = ["@", localeTag, zone, String(millis)].joined(separator: "\t")
        if context != lastContext { print(context); lastContext = context }
        print([tier, hex(pattern), hex(output)].joined(separator: "\t"))
    }
    for localeTag in ["en-US", "fr-FR", "th-TH", "en-US-u-ca-buddhist", "en-US-u-ca-islamic-umalqura", "ar-SA", "en-US-u-nu-arab", "en-GB", "th-TH-u-ca-gregory", "en-US-u-ca-japanese", "en-US-u-ca-roc"] {
        for zone in zones {
            for instant in instants {
                // The full grid for the primary locales; a thinner one for the rest.
                let primary = ["en-US", "fr-FR", "th-TH"].contains(localeTag)
                if localeTag != "en-US" && primary && !(zone == "UTC" || zone == "Europe/Paris" || zone == "Asia/Kathmandu") { continue }
                if !primary && !(zone == "UTC" || zone == "Europe/Paris") { continue }
                if !primary && ![1_769_902_215, 1_709_200_800, 0, 1_609_675_200, -12_219_638_400, 253_402_300_799].contains(instant) { continue }
                for pattern in numeric { emit(localeTag, zone, instant, "numeric", pattern) }
                if localeTag == "en-US" { for pattern in text { emit(localeTag, zone, instant, "text", pattern) } }
            }
        }
    }

case "calendar":
    header(["@<TAB>calendar<TAB>time zone<TAB>milliseconds since 1970 starts a group; its lines are",
            "unit (m h d M y)<TAB>amount<TAB>result in milliseconds since 1970, or nil",
            "Calendar(identifier:).date(byAdding:value:to:) with the calendar's timeZone set."])
    let instants: [Double] = [
        1_769_902_215, 1_774_699_200, 1_709_200_800, 1_785_340_805.75, 1_774_661_400, 1_774_747_800, 1_761_352_200, 1_761_355_800, 1_761_438_600,
        1_772_951_400, 1_773_037_800, 1_793_511_000, 1_793_514_600, 0, -0.5, 1_711_843_200, 1_724_976_000, 1_704_067_199, -12_219_638_400, -12_220_000_000,
        951_782_400, 4_107_542_400, 1_761_528_600, 1_761_442_200, 1_764_034_200, 1_793_064_600, 1_793_068_200, 1_761_442_200 - 31_622_400,
    ]
    let amounts = [0, 1, -1, 2, -2, 11, 12, -12, 13, 23, 24, 25, -24, 30, 31, -31, 59, 60, 90, 365, -365, 366, 1000, -1000, -2000, -2030, -2500, -3000, -5000, -10_000, 100_000, -100_000]
    for (name, identifier) in [("gregorian", Calendar.Identifier.gregorian), ("buddhist", .buddhist)] {
        for zone in ["UTC", "Europe/Paris", "America/New_York", "Asia/Kolkata"] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(identifier: zone)!
            for instant in instants {
                if name == "buddhist" && !(zone == "Europe/Paris") { continue }
                print(["@", name, zone, String(Int64((instant * 1000).rounded(.down)))].joined(separator: "\t"))
                for (unitName, unit) in [("m", Calendar.Component.minute), ("h", .hour), ("d", .day), ("M", .month), ("y", .year)] {
                    for amount in amounts {
                        let date = Date(timeIntervalSince1970: instant)
                        let result = calendar.date(byAdding: unit, value: amount, to: date)
                        let out = result.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded(.down))) } ?? "nil"
                        print([unitName, String(amount), out].joined(separator: "\t"))
                    }
                }
            }
        }
    }

    // Steps that land in the hour the clock skips or repeats (Europe/Paris), from summer
    // and from winter, forwards and backwards.
    let transitions: [(String, String, Int)] = [
  ("2025-10-25T02:30:00+02:00", "d", 1), ("2025-10-27T02:30:00+01:00", "d", -1), ("2025-10-19T02:30:00+02:00", "d", 7), ("2025-11-02T02:30:00+01:00", "d", -7),
  ("2025-09-26T02:30:00+02:00", "M", 1), ("2025-11-26T02:30:00+01:00", "M", -1), ("2025-03-26T02:30:00+01:00", "M", 7), ("2026-03-26T02:30:00+01:00", "M", -5),
  ("2026-06-26T02:30:00+02:00", "M", -8), ("2025-01-26T02:30:00+01:00", "M", 9), ("2024-10-26T02:30:00+02:00", "y", 1), ("2026-10-26T02:30:00+01:00", "y", -1),
  ("2023-10-26T02:30:00+02:00", "y", 2), ("2027-10-26T02:30:00+02:00", "y", -2), ("2028-10-26T02:30:00+02:00", "y", -3),
  ("2026-03-28T02:30:00+01:00", "d", 1), ("2026-03-30T02:30:00+02:00", "d", -1), ("2026-03-22T02:30:00+01:00", "d", 7), ("2026-04-05T02:30:00+02:00", "d", -7),
  ("2026-02-28T02:30:00+01:00", "M", 1), ("2026-04-29T02:30:00+02:00", "M", -1), ("2025-03-29T02:30:00+01:00", "M", 12), ("2027-03-29T02:30:00+02:00", "M", -12),
  ("2025-03-29T02:30:00+01:00", "y", 1), ("2027-03-29T02:30:00+02:00", "y", -1), ("2024-03-29T02:30:00+01:00", "y", 2), ("2028-03-29T02:30:00+02:00", "y", -2),
  ("2026-08-29T02:30:00+02:00", "M", -5), ("2025-10-29T02:30:00+01:00", "M", 5),
  ("2025-10-26T02:30:00+02:00", "M", 12), ("2025-10-26T02:30:00+01:00", "M", 12), ("2025-10-26T02:30:00+02:00", "y", -1), ("2025-10-26T02:30:00+01:00", "y", -1),
  ("2025-10-26T02:30:00+02:00", "d", 0), ("2025-10-26T02:30:00+01:00", "d", 0), ("2025-10-26T02:30:00+02:00", "M", 0), ("2025-10-26T02:30:00+01:00", "y", 0),
  ("2025-10-26T02:30:00+02:00", "d", 364), ("2025-10-26T02:30:00+01:00", "d", 364), ("2025-10-26T02:30:00+02:00", "d", -364), ("2025-10-26T02:30:00+01:00", "d", -364),
  ("2025-10-26T02:30:00+02:00", "d", 1), ("2025-10-26T02:30:00+01:00", "d", 1), ("2025-10-26T02:30:00+02:00", "d", -1), ("2025-10-26T02:30:00+01:00", "d", -1),
  ("2025-10-26T02:30:00+01:00", "d", 728), ("2025-10-26T02:30:00+02:00", "d", 728),
  ("2025-06-01T02:30:00+02:00", "d", -217), ("2025-06-01T02:30:00+02:00", "d", 147), ("2025-06-01T02:30:00+02:00", "d", 511), ("2025-06-01T02:30:00+02:00", "d", -63), ("2025-06-01T02:30:00+02:00", "d", 301), ("2025-02-01T02:30:00+01:00", "d", -97), ("2025-02-01T02:30:00+01:00", "d", 267), ("2025-02-01T02:30:00+01:00", "d", 631), ("2025-02-01T02:30:00+01:00", "d", 57), ("2025-02-01T02:30:00+01:00", "d", 421), ("2025-07-01T02:30:00+02:00", "d", -247), ("2025-07-01T02:30:00+02:00", "d", 117), ("2025-07-01T02:30:00+02:00", "d", 481), ("2025-07-01T02:30:00+02:00", "d", -93), ("2025-07-01T02:30:00+02:00", "d", 271), ("2025-12-01T02:30:00+01:00", "d", -400), ("2025-12-01T02:30:00+01:00", "d", -36), ("2025-12-01T02:30:00+01:00", "d", 328), ("2025-12-01T02:30:00+01:00", "d", -246), ("2025-12-01T02:30:00+01:00", "d", 118), ("2026-01-15T02:30:00+01:00", "d", -445), ("2026-01-15T02:30:00+01:00", "d", -81), ("2026-01-15T02:30:00+01:00", "d", 283), ("2026-01-15T02:30:00+01:00", "d", -291), ("2026-01-15T02:30:00+01:00", "d", 73), ("2026-07-15T02:30:00+02:00", "d", -626), ("2026-07-15T02:30:00+02:00", "d", -262), ("2026-07-15T02:30:00+02:00", "d", 102), ("2026-07-15T02:30:00+02:00", "d", -472), ("2026-07-15T02:30:00+02:00", "d", -108), ("2024-07-15T02:30:00+02:00", "d", 104), ("2024-07-15T02:30:00+02:00", "d", 468), ("2024-07-15T02:30:00+02:00", "d", 832), ("2024-07-15T02:30:00+02:00", "d", 258), ("2024-07-15T02:30:00+02:00", "d", 622), ("2024-01-15T02:30:00+01:00", "d", 286), ("2024-01-15T02:30:00+01:00", "d", 650), ("2024-01-15T02:30:00+01:00", "d", 1014), ("2024-01-15T02:30:00+01:00", "d", 440), ("2024-01-15T02:30:00+01:00", "d", 804),
    ]
    var paris = Calendar(identifier: .gregorian)
    paris.timeZone = TimeZone(identifier: "Europe/Paris")!
    let iso = ISO8601DateFormatter()
    for (text, unitName, amount) in transitions {
        let date = iso.date(from: text)!
        let unit: Calendar.Component = unitName == "d" ? .day : unitName == "M" ? .month : .year
        let result = paris.date(byAdding: unit, value: amount, to: date)!
        print(["@", "gregorian", "Europe/Paris", String(Int64(date.timeIntervalSince1970 * 1000))].joined(separator: "\t"))
        print([unitName, String(amount), String(Int64(result.timeIntervalSince1970 * 1000))].joined(separator: "\t"))
    }

case "locales":
    header(["Locale.availableIdentifiers, sorted, one per line"])
    for identifier in Locale.availableIdentifiers.sorted() { print(identifier) }

default:
    FileHandle.standardError.write(Data("unknown section\n".utf8))
    exit(2)
}
