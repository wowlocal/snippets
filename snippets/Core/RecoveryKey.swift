import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.
// Foundation only: this is bit-shuffling and string hygiene, nothing cryptographic
// beyond the one call to the system CSPRNG in `generate()`.

/// The second door to the vault: 128 bits of machine-generated entropy, written down
/// once on paper, that wrap the same `K_lib` a passphrase does.
///
/// A vault with only a passphrase has a failure mode with no recovery: the user
/// forgets it and their secure snippets are gone, permanently and by design, because
/// there is no server-side key escrow to appeal to. So the app generates one of these
/// at setup, shows it once, and tells the user to put it somewhere physical. It is
/// also the answer to "PBKDF2 is not memory-hard" — 128 bits of CSPRNG output is not
/// guessable at any budget, so the recovery path is strictly stronger than the
/// passphrase path.
///
/// ## Format
///
/// Crockford base32, because this string gets read aloud over a phone, copied off a
/// photo of a scrap of paper, and typed by someone who is already annoyed. Crockford
/// drops `I`, `L`, `O` and `U` from the alphabet, and `decode` folds the classic
/// misreadings (`I`/`L` → `1`, `O` → `0`), ignores case, and ignores spaces, hyphens
/// and the em/en dashes that a note-taking app will silently substitute for a hyphen.
///
/// ```
///  bytes:  16 (128 bits)
///  symbols: 26 payload  +  1 check  =  27 characters
///  shown:  XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX
/// ```
///
/// ## Why 27 characters and not 26
///
/// 128 bits needs ⌈128/5⌉ = 26 base-32 symbols, which is where the tempting round
/// number "a 26-character recovery key" comes from. But 26 symbols carry 130 bits, so
/// a 26-character string that also held the key would have exactly **2 bits** left
/// over for a checksum — and 2 bits cannot catch every single-character typo, it
/// catches 3 in 4. The argument is a counting one, not an implementation detail: a
/// wrong symbol perturbs 5 bits, the check has to distinguish all 31 wrong values of
/// that symbol at each of the positions, and 4 checksum states provably cannot. Since
/// the whole point of a checksum here is to tell the user "you mistyped it" instead of
/// "your recovery key is wrong, your snippets are gone", correctness wins over the
/// round number and the key is 27 characters: 26 of payload and one full 5-bit check
/// symbol, which catches *every* single-character substitution.
nonisolated enum RecoveryKey {

    // MARK: - Shape

    static let byteCount = 16
    /// 26 symbols × 5 bits = 130 bits, of which the low 2 are zero padding that
    /// `decode` insists on — see `Failure.nonCanonical`.
    static let payloadCharacterCount = 26
    static let characterCount = payloadCharacterCount + 1
    static let groupSize = 4
    static let groupSeparator: Character = "-"

    /// Crockford's alphabet: the digits, then the letters with `I`, `L`, `O` and `U`
    /// removed. `I`/`L`/`O` go because they are read as `1`/`1`/`0`; `U` goes because
    /// its presence is how a randomly generated key ends up spelling something the
    /// user would rather not read aloud.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    enum Failure: Error, Equatable, CustomStringConvertible {
        case wrongByteCount(Int)
        case wrongLength(Int)
        case invalidCharacter(Character)
        case checksumMismatch
        /// The 26th symbol had non-zero trailing bits. Not producible by `encode`, so
        /// it means the string came from somewhere else — or from a substitution that
        /// happened to land in the final symbol.
        case nonCanonical

        var description: String {
            switch self {
            case .wrongByteCount(let count):
                return "a recovery key is \(RecoveryKey.byteCount) bytes, got \(count)"
            case .wrongLength(let count):
                return "a recovery key is \(RecoveryKey.characterCount) characters, got \(count)"
            case .invalidCharacter(let character):
                return "\"\(character)\" is not part of a recovery key"
            case .checksumMismatch:
                return "that recovery key has a typo in it"
            case .nonCanonical:
                return "that recovery key is not a well-formed encoding"
            }
        }
    }

    // MARK: - Generating

    /// 128 fresh bits from the system CSPRNG.
    static func generate() -> Data {
        SnippetCrypto.randomBytes(byteCount)
    }

    // MARK: - Encoding

    /// The canonical 27-character form: no separators, uppercase.
    ///
    /// This is what gets hashed, compared, and stored if it is ever stored. The
    /// grouped form is presentation only — `decode` accepts either.
    static func encode(_ bytes: Data) throws -> String {
        guard bytes.count == byteCount else { throw Failure.wrongByteCount(bytes.count) }
        var symbols = symbolsFromBytes(bytes)
        symbols.append(checkSymbol(symbols))
        return String(symbols.map { alphabet[Int($0)] })
    }

    /// The form to show a human: groups of four, hyphen separated, last group ragged.
    ///
    /// Grouping is not decoration — an unbroken 27-character run is measurably harder
    /// to transcribe without losing your place, and the hyphens give the eye somewhere
    /// to rest when reading it back off paper.
    static func formatted(_ bytes: Data) throws -> String {
        grouped(try encode(bytes))
    }

    static func grouped(_ canonical: String) -> String {
        var out = ""
        for (offset, character) in canonical.enumerated() {
            if offset > 0, offset % groupSize == 0 { out.append(groupSeparator) }
            out.append(character)
        }
        return out
    }

    // MARK: - Decoding

    /// Accepts what a human actually types.
    ///
    /// Lowercase, mixed case, no hyphens, hyphens in the wrong places, spaces from a
    /// wrapped line, non-breaking spaces from a web page, and the en/em dashes a notes
    /// app substitutes for `-` all decode to the same 16 bytes. What does *not* decode
    /// is a key with a typo in it, which is the entire reason the check symbol exists.
    static func decode(_ text: String) throws -> Data {
        let normalized = normalized(text)
        guard normalized.count == characterCount else {
            throw Failure.wrongLength(normalized.count)
        }

        var symbols: [UInt8] = []
        symbols.reserveCapacity(characterCount)
        for character in normalized {
            guard let index = alphabet.firstIndex(of: character) else {
                throw Failure.invalidCharacter(character)
            }
            symbols.append(UInt8(index))
        }

        let payload = Array(symbols[..<payloadCharacterCount])
        guard symbols[payloadCharacterCount] == checkSymbol(payload) else {
            throw Failure.checksumMismatch
        }
        return try bytesFromSymbols(payload)
    }

    /// Uppercases, drops the separators a human or an app might have inserted, and
    /// folds the confusable glyphs onto the characters Crockford intends them to be.
    ///
    /// The dash list is longer than it looks like it needs to be because macOS text
    /// substitution turns a typed `-` into `–` in exactly the places a user is likely
    /// to be writing this down: Notes, Mail, Messages.
    static func normalized(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text.uppercased() {
            switch character {
            case " ", "\t", "\n", "\r", "\u{00A0}",                  // whitespace, incl. non-breaking
                 "-", "\u{2010}", "\u{2011}", "\u{2012}",            // hyphen and its Unicode cousins
                 "\u{2013}", "\u{2014}", "\u{2212}", "_":            // en dash, em dash, minus sign
                continue
            case "I", "L": out.append("1")
            case "O": out.append("0")
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: - Checksum

    /// A weighted sum mod 32 over the payload symbols, emitted as one more symbol from
    /// the same alphabet.
    ///
    /// Every weight is **odd**, and odd numbers are exactly the units of ℤ/32 — so
    /// changing symbol *i* by δ ≠ 0 changes the sum by `(2i+1)·δ`, which is non-zero
    /// mod 32 because an invertible multiplier cannot map a non-zero δ to zero. That
    /// is the whole proof that every single-character substitution is caught, and it
    /// is why the weights are not simply `i` (even weights lose a bit and let
    /// δ = 16 slip past at every even position).
    ///
    /// The position weighting additionally catches most transpositions, which a plain
    /// sum or XOR would not: swapping neighbours shifts the total by `2(a−b)`, which
    /// only vanishes when the two symbols differ by exactly 16.
    static func checkSymbol(_ payload: [UInt8]) -> UInt8 {
        var sum = 0
        for (index, symbol) in payload.enumerated() {
            sum = (sum + (2 * index + 1) * Int(symbol)) % 32
        }
        return UInt8(sum)
    }

    // MARK: - Bit packing
    //
    // Plain big-endian base32: bits stream out of the bytes most-significant first and
    // into 5-bit symbols. 128 bits fills 25 symbols exactly and leaves 3 bits, which
    // become the top of a 26th symbol whose low 2 bits are zero.

    static func symbolsFromBytes(_ bytes: Data) -> [UInt8] {
        var symbols: [UInt8] = []
        symbols.reserveCapacity(payloadCharacterCount)
        var accumulator: UInt32 = 0
        var bits = 0

        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                symbols.append(UInt8((accumulator >> UInt32(bits)) & 0x1F))
                accumulator &= (UInt32(1) << UInt32(bits)) &- 1
            }
        }
        if bits > 0 {
            symbols.append(UInt8((accumulator << UInt32(5 - bits)) & 0x1F))
        }
        return symbols
    }

    static func bytesFromSymbols(_ symbols: [UInt8]) throws -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        var accumulator: UInt32 = 0
        var bits = 0

        for symbol in symbols {
            accumulator = (accumulator << 5) | UInt32(symbol)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
                accumulator &= (UInt32(1) << UInt32(bits)) &- 1
            }
        }

        // The leftover bits must be zero. `encode` never sets them, so a string that
        // does is either not one of ours or has been mistyped in its final symbol —
        // and silently discarding the bits would mean two different strings decoding
        // to the same key, which turns "you have a typo" into "you have a valid key
        // that opens nothing".
        guard accumulator == 0 else { throw Failure.nonCanonical }
        guard bytes.count == byteCount else { throw Failure.wrongByteCount(bytes.count) }
        return Data(bytes)
    }
}
