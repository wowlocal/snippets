import Foundation

/// Literal matching over already case/diacritic-folded text. ASCII fields use
/// Foundation's byte search; Unicode retains String's canonical-equivalence rules.
/// The byte representation replaces the folded body String rather than retaining
/// both. Neither queries nor fields are persisted or logged.
nonisolated enum PreparedSubstringSearch {
    fileprivate struct ASCIIMask: Sendable {
        var low: UInt64 = 0
        var high: UInt64 = 0

        init?(_ text: String) {
            for byte in text.utf8 {
                guard byte < 128 else { return nil }
                if byte < 64 { low |= 1 << byte } else { high |= 1 << (byte - 64) }
            }
        }

        func contains(_ other: ASCIIMask) -> Bool {
            low & other.low == other.low && high & other.high == other.high
        }
    }

    struct Query: Sendable {
        let text: String
        fileprivate let ascii: (bytes: Data, mask: ASCIIMask)?

        init(_ foldedText: String) {
            text = foldedText
            // A Unicode spelling can be canonically equivalent to ASCII (e.g.
            // Kelvin sign). An ASCII field can match it only if its NFD is ASCII.
            let canonical = foldedText.decomposedStringWithCanonicalMapping
            ascii = ASCIIMask(canonical).map { (Data(canonical.utf8), $0) }
        }
    }

    struct Field: Sendable {
        private enum Storage: Sendable {
            case ascii(Data, ASCIIMask)
            case unicode(String)
        }
        private let storage: Storage

        init(_ foldedText: String) {
            if let mask = ASCIIMask(foldedText) {
                storage = .ascii(Data(foldedText.utf8), mask)
            } else {
                storage = .unicode(foldedText)
            }
        }

        func contains(_ query: Query) -> Bool {
            if query.text.isEmpty { return false }
            switch storage {
            case .ascii(let bytes, let mask):
                guard let needle = query.ascii, mask.contains(needle.mask) else { return false }
                var start = bytes.startIndex
                while let match = bytes.range(of: needle.bytes, in: start..<bytes.endIndex) {
                    // CRLF is the one multi-byte ASCII grapheme. A byte match
                    // must not begin or end halfway through it.
                    let splitsStart = match.lowerBound > bytes.startIndex
                        && bytes[match.lowerBound] == 10 && bytes[match.lowerBound - 1] == 13
                    let splitsEnd = match.upperBound < bytes.endIndex
                        && bytes[match.upperBound - 1] == 13 && bytes[match.upperBound] == 10
                    if !splitsStart && !splitsEnd { return true }
                    start = match.lowerBound + 1
                }
                return false
            case .unicode(let text):
                return text.contains(query.text)
            }
        }
    }
}
