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
| `…/grapheme-corpus.tsv` | `Character` boundaries |
| `…/character-sets.tsv` | members of `.whitespaces`, `.newlines`, `.whitespacesAndNewlines` |
| `…/trim-split-corpus.tsv` | `trimmingCharacters(in:)`, `components(separatedBy:)` |
| `…/string-comparison-corpus.tsv` | Swift `==` and `<` on strings |
| `…/model-corpus.tsv` | `sanitizedKeyword`, `normalizedTags`, `displayName`, first content line, display order |
| `…/codec-corpus.tsv` | `SnippetLibraryCodec` decode outcomes and encoded bytes |

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

## Grapheme clusters

Swift does not publish the properties its segmenter uses, so each scalar is classified by
the `count` of short probe strings: one of 15 classes plus three flags for the Indic
conjunct rule. `GraphemeModel` replays Swift's forward segmenter over those classes and
is compared with Swift on about 44 million strings (every scalar beside one member of
every class, and four million random strings). `GraphemeBreaker.kt` is the same state
machine. `java.text.BreakIterator` is not used: its rules are those of the runtime's ICU.

## Where Kotlin deliberately follows the standard instead of Apple

Canonical equivalence and order go through `java.text.Normalizer`. Two findings, both
visible in `string-comparison-corpus.tsv` and pinned by tests in
`FoundationTextCorpusTest`:

- U+0F73, U+0F75 and U+0F81 have class 0 and decompose into marks of class 129/130.
  Apple's normalizers (the standard library's and Foundation's) do not reorder an earlier
  mark of a higher class behind them. Rows that contain one are flagged `outlier`.
- Swift's `<` on two native strings answers by length when one string's UTF-8 is a prefix
  of the other's, without normalizing. The corpus records both that answer and the order
  of the NFC forms; they differ in a handful of rows, all of them prefix pairs.

The comparison corpus only uses scalars assigned by Unicode 10.0, the version of the
oldest supported Android runtime, since normalization of later scalars depends on the
runtime.

## Relation to tools/swift-interop

`swift-interop` emits golden vectors from the Swift sources (`vectors/swift`). Its
`L03b-filterkey-table` is an independent measurement of the fold of every scalar and of
U+0301 after every base; `SwiftKeywordAndTagVectorTest` checks `foundation-fold.txt` and
the rule against all of it.
