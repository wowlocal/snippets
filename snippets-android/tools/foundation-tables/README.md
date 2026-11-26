# foundation-tables

Generates the data `:core` needs to behave like Foundation and the Swift standard library
where the JVM has no equivalent: `String.folding`, extended grapheme clusters, the
character sets, and corpora of expected results for the tests.

Everything here is measured by calling Foundation on a Mac. Nothing is copied from
Unicode data files, because the point is to match what Apple's code does, including where
that differs from the standard.

## Run

```sh
tools/foundation-tables/regenerate.sh     # from snippets-android/, about a minute
```

It compiles `Sources/*.swift` together with the app's own `snippets/Core/Snippet.swift`
and `SnippetLibraryCodec.swift` (unmodified, so model results come from the shipping
code), runs the probes, checks the rules below against Foundation, and writes:

| File | Content |
|---|---|
| `core/src/main/resources/com/khm/snippets/core/text/foundation-fold.txt` | fold tables, read by `FoundationFold` |
| `core/src/main/resources/com/khm/snippets/core/text/grapheme-break.txt` | grapheme classes, read by `GraphemeBreaker` |
| `core/src/test/resources/fixtures/foundation/fold-corpus.tsv` | whole-string folds |
| `core/src/main/resources/com/khm/snippets/core/text/swift-case.txt` | case mappings, read by `SwiftCase` |
| `…/grapheme-corpus.tsv` | `Character` boundaries |
| `…/case-corpus.tsv` | `String.lowercased()`, `String.uppercased()` |
| `…/character-sets.tsv` | members of `.whitespaces`, `.newlines`, `.whitespacesAndNewlines` |
| `…/trim-split-corpus.tsv` | `trimmingCharacters(in:)`, `components(separatedBy:)` |
| `…/string-comparison-corpus.tsv` | Swift `==` and `<` on strings |
| `…/model-corpus.tsv` | `sanitizedKeyword`, `normalizedTags`, `displayName`, first content line, display order |
| `…/codec-corpus.tsv` | `SnippetLibraryCodec` decode outcomes and encoded bytes |
| `core/src/main/resources/com/khm/snippets/core/text/foundation-precomposed.txt` | precomposition tables, read by `FoundationPrecomposed` |
| `…/precomposed-digests.tsv` | SHA-256 per 65,536 results of `precomposedStringWithCanonicalMapping` over 39 million strings |
| `…/precomposed-corpus.tsv` | a readable sample of those results |

Each file's header records the macOS and Swift versions that produced it and its line
format. Strings are written as space-separated scalar values. Random cases come from a
fixed seed, so a second run on the same system writes the same files (a timestamp that
defaults to the decode time is recorded as `now`, never as a value).

Regenerate after a macOS or Xcode upgrade and read the diff: a changed table means
Foundation's data changed, and `:core:test` then says whether the rules still hold.
The generator stops with `generator check failed: …` if a rule below no longer
reproduces Foundation; in that case the rule, not just the data, has to be revisited.

## The fold rule

`SnippetTagging.filterKey` is
`String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: en_US_POSIX)`.
The fold of a string is **not** the concatenation of the folds of its scalars.
CoreFoundation (`CFStringFold`) walks the string in clusters: one leading scalar and the
"non-base" scalars after it.

1. U+0000 is copied and never leads a cluster.
2. The leader is replaced by its own fold (`[base]`: 1,943 scalars change).
3. If the last scalar of that fold is below U+0510, every follower is dropped.
4. Otherwise followers are kept; but if the leader's fold is the leader itself, a first
   follower at or below U+050F is dropped.
5. A kept follower is canonically decomposed (`[markdecomposition]`, 37 scalars).
6. A cluster holds at most 64 scalars. A follower that does not fit ends the cluster and
   leads the next. A decomposing follower needs the listed number of free slots, which is
   more than its length when the decomposition is nested (U+0CCB needs 4 for 3 scalars).
7. The kept followers and the scalar before them are stably sorted by combining class
   (`[priority]`).

`[nonbase]` is CoreFoundation's own set (2,237 scalars); it is close to, but not the same
as, `Grapheme_Extend`. The generator checks rule 3/4 for every scalar, derives the
classes by asking Foundation to order pairs of marks, and then compares the rule with
Foundation on about 6.5 million strings (every scalar alone and with followers, every
non-base scalar after sixteen kinds of leader, two million random strings, and runs that
cross the 64-scalar buffer). `FoundationFold.kt` is the same rule.

## Precomposition (`precomposedStringWithCanonicalMapping`)

`PassphraseKDF.derive` stretches `passphrase.precomposedStringWithCanonicalMapping`, which on
Apple platforms is CoreFoundation's `CFStringNormalize(_, .C)` and not Unicode NFC. The
rule (`PrecomposedModel`, and `FoundationPrecomposed.kt`) is that function statement for
statement, on a UTF-16 buffer edited in place, over measured data:

- `[decomposition]`: the normal form D of every scalar alone, which for a class-0 scalar at
  the end of a string is CoreFoundation's unsorted decomposition (Hangul syllables are
  algorithmic);
- `[rank]`: combining classes, placed on a ladder by asking Foundation to order marks;
- `[compose]`: a scalar that comes back from its own decomposition composes from the
  composed prefix and the last piece; a BMP mark looks its base up by the low 16 bits;
- `[nonbasestarter]`: class-0 marks that join a run after a base that does not decompose;
- `[markspace]`: how much of the 64-scalar buffer a decomposable mark needs.

Where it departs from NFC: a Hangul syllable is never decomposed (`AC00 11AB` stays);
conjoining jamo compose with off-by-one bounds (`1105 1176` is `B9C8`, `1113 1176` a lone
surrogate read back as U+FFFD); `10041 030A` is `00C5`; U+0F73, U+0F75 and U+0F81 are
decomposed in place without reordering; a decomposable mark that does not fit the buffer is
dropped. The generator checks that nothing below U+0300 ever changes (the Kotlin fast path)
and compares the rule with Foundation on 39,048,691 strings: every scalar alone, after `a`
and 13 other leaders, before U+0301 and 13 other followers, inside three-scalar contexts,
every jamo pair, every L V T triple around the bounds, every syllable before every trailing
consonant, three million random strings from the 3,952 scalars the tables mention (one in
ten from anywhere), and runs that reach the buffer limit. The Kotlin test walks the same
families and compares digests. `FOUNDATION_TABLES_ONLY=precomposed regenerate.sh` writes
only these three files.

## Grapheme clusters

Swift does not publish the properties its segmenter uses, so each scalar is classified by
the `count` of short probe strings: one of 15 classes plus three flags for the Indic
conjunct rule. `GraphemeModel` replays Swift's forward segmenter over those classes and
is compared with Swift on about 44 million strings (every scalar beside one member of
every class, and four million random strings). `GraphemeBreaker.kt` is the same state
machine. `java.text.BreakIterator` is not used: its rules are those of the runtime's ICU.

## Case mappings

`String.lowercased()` and `uppercased()` of the standard library map every scalar on its
own and concatenate: no locale and no context, so `ΑΣ` lowercases to `ασ` where the JVM's
`lowercase(Locale.ROOT)` writes a final sigma. The per-scalar mappings (1,488 scalars
change in `lowercased()`, 1,580 in `uppercased()`) are measured, and the scalar-by-scalar
rule is compared with Swift on about 4.2 million strings. `SwiftCase.kt` applies them;
`FoundationText.swiftLowercased` / `swiftUppercased` are the entry points.

## Where Kotlin deliberately follows the standard instead of Apple

Canonical equivalence and order go through `java.text.Normalizer`. Two findings, both
visible in `string-comparison-corpus.tsv` and pinned by tests in
`FoundationTextCorpusTest`:

- U+0F73, U+0F75 and U+0F81 have class 0 and decompose into marks of class 129/130.
  Apple's normalizers (the standard library's and Foundation's) do not reorder an earlier
  mark of a higher class behind them. Rows that contain one are flagged `outlier`.
- Swift's `<` is not a consistent order for strings that are not in NFC (the review found
  cycles, and pairs for which neither side is smaller), so it cannot be copied.
  `FoundationText.compare` is the scalar order of the NFC forms, which is what Swift
  documents and what Swift answers for two NFC strings. The corpus records both answers.
  They differ when one string's UTF-8 is a prefix of the other's (Swift answers by length
  without normalizing) and when the NFC forms are in a prefix relation; see the KDoc of
  `FoundationText.compare` and `review/foundation/SwiftStringOrderTest`.

The comparison corpus only uses scalars assigned by Unicode 10.0, the version of the
oldest supported Android runtime, since normalization of later scalars depends on the
runtime.

## Relation to tools/swift-interop

`swift-interop` emits golden vectors from the Swift sources (`vectors/swift`). Its
`L03b-filterkey-table` is an independent measurement of the fold of every scalar and of
U+0301 after every base; `SwiftKeywordAndTagVectorTest` checks `foundation-fold.txt` and
the rule against all of it.
