import Foundation

// Usage: foundation-tables <main resources dir> <test fixtures dir> <swift version string>
// Run through ../regenerate.sh, which builds this together with the app's Snippet.swift
// and SnippetLibraryCodec.swift.

// Progress lines should appear as they are printed, also when piped.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: foundation-tables <resources> <fixtures> <swift version>\n".utf8))
    exit(2)
}
let resources = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fixtures = URL(fileURLWithPath: arguments[2], isDirectory: true)
let environment = GeneratorEnvironment(
    macOS: ProcessInfo.processInfo.operatingSystemVersionString,
    swift: arguments[3])

print("probing the fold tables...")
let foldTables = probeFoldTables()
print("  \(foldTables.base.count) scalars change, \(foldTables.nonBase.filter { $0 }.count) non-base scalars, "
    + "\(foldTables.markDecomposition.count) decomposing marks")
let foldChecks = verifyFoldModel(foldTables)
print("  fold rule matches Foundation on \(foldChecks) strings")
write(foldResourceLines(foldTables, environment: environment),
      to: resources.appendingPathComponent("foundation-fold.txt"))
write(foldCorpusLines(foldTables, environment: environment),
      to: fixtures.appendingPathComponent("fold-corpus.tsv"))

print("probing grapheme cluster classes...")
let graphemeTables = probeGraphemeTables()
let graphemeChecks = verifyGraphemeModel(graphemeTables)
print("  segmentation rule matches Swift on \(graphemeChecks) strings")
write(graphemeResourceLines(graphemeTables, environment: environment),
      to: resources.appendingPathComponent("grapheme-break.txt"))
write(graphemeCorpusLines(graphemeTables, environment: environment),
      to: fixtures.appendingPathComponent("grapheme-corpus.tsv"))

print("probing the case mappings...")
let caseTables = probeCaseTables()
print("  \(caseTables.lower.count) scalars change in lowercased(), \(caseTables.upper.count) in uppercased()")
let caseChecks = verifyCaseModel(caseTables)
print("  scalar-by-scalar mapping matches Swift on \(caseChecks) strings")
write(caseResourceLines(caseTables, environment: environment),
      to: resources.appendingPathComponent("swift-case.txt"))
write(caseCorpusLines(caseTables, environment: environment),
      to: fixtures.appendingPathComponent("case-corpus.tsv"))

print("writing the remaining corpora...")
write(characterSetLines(environment: environment),
      to: fixtures.appendingPathComponent("character-sets.tsv"))
write(trimAndSplitCorpusLines(environment: environment),
      to: fixtures.appendingPathComponent("trim-split-corpus.tsv"))
write(comparisonCorpusLines(environment: environment),
      to: fixtures.appendingPathComponent("string-comparison-corpus.tsv"))
write(modelCorpusLines(environment: environment),
      to: fixtures.appendingPathComponent("model-corpus.tsv"))
write(codecCorpusLines(environment: environment),
      to: fixtures.appendingPathComponent("codec-corpus.tsv"))
print("done")
