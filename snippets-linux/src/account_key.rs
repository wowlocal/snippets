//! Server-generated Snippets Cloud account keys (server ADR 0006). The key is the
//! only native sign-in secret: it has no Debug, Display or serialization escape and
//! leaves only through the sign-in body, the secret credential store or an explicit
//! owner-visible presentation. Diagnostics never see it.
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const BODY: usize = 26;
const LENGTH: usize = BODY + 2;
const MAX_INPUT_BYTES: usize = 64;
const CHECK_DOMAIN: &[u8] = b"snippets-account-key-check-v1\n";

fn check(body: &[u8]) -> [u8; 2] {
    let mut hash = Sha256::new();
    hash.update(CHECK_DOMAIN);
    hash.update(body);
    let digest = hash.finalize();
    let value = (usize::from(digest[0]) << 2) | (usize::from(digest[1]) >> 6);
    [ALPHABET[value >> 5], ALPHABET[value & 31]]
}

/// Canonical form only: 28 uppercase Crockford symbols with a matching check.
#[derive(Clone, PartialEq, Eq)]
pub struct AccountKey(Zeroizing<String>);
impl AccountKey {
    /// Normalizes typed or pasted input. Anything else is a local typing error and
    /// must never be sent to a server.
    pub fn parse_input(input: &str) -> Option<Self> {
        if input.len() > MAX_INPUT_BYTES {
            return None;
        }
        // Allocated once at the input bound; no reallocation leaves partial copies.
        let mut symbols = Zeroizing::new(Vec::with_capacity(MAX_INPUT_BYTES));
        for byte in input.bytes() {
            if byte.is_ascii_whitespace() || byte == b'-' {
                continue;
            }
            symbols.push(match byte.to_ascii_uppercase() {
                b'O' => b'0',
                b'I' | b'L' => b'1',
                other => other,
            });
        }
        Self::validate(&symbols)
    }
    /// Wire responses and stored state must already be canonical.
    pub fn from_canonical(text: &str) -> Option<Self> {
        Self::validate(text.as_bytes())
    }
    fn validate(symbols: &[u8]) -> Option<Self> {
        if symbols.len() != LENGTH || !symbols.iter().all(|b| ALPHABET.contains(b)) {
            return None;
        }
        let (body, sum) = symbols.split_at(BODY);
        if check(body) != *sum {
            return None;
        }
        // All symbols are ASCII; this cannot fail after the alphabet check.
        let text = std::str::from_utf8(symbols).ok()?;
        Some(Self(Zeroizing::new(text.to_owned())))
    }
    /// The wire and secret-storage form.
    pub fn canonical(&self) -> &str {
        &self.0
    }
    /// Seven groups of four separated by `-`, for an owner-visible presentation.
    pub fn display(&self) -> Zeroizing<String> {
        let mut text = Zeroizing::new(String::with_capacity(LENGTH + LENGTH / 4));
        for (index, symbol) in self.0.chars().enumerate() {
            if index > 0 && index % 4 == 0 {
                text.push('-');
            }
            text.push(symbol);
        }
        text
    }
}

/// Native account identities are canonical lowercase, non-nil UUIDs.
pub fn valid_account_id(id: &str) -> bool {
    uuid::Uuid::parse_str(id)
        .is_ok_and(|uuid| !uuid.is_nil() && uuid.hyphenated().to_string() == id)
}
/// The signed-in screen shows only the first eight hex digits, uppercase, as
/// `XXXX-XXXX`. This is UI text, never a diagnostic or persisted value.
pub fn account_id_display(id: &str) -> Option<String> {
    if !valid_account_id(id) {
        return None;
    }
    let prefix = id[..8].to_ascii_uppercase();
    Some(format!("{}-{}", &prefix[..4], &prefix[4..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adr_vectors_produce_canonical_and_display_forms() {
        for (body, canonical, display) in [
            (
                "00000000000000000000000000",
                "00000000000000000000000000HF",
                "0000-0000-0000-0000-0000-0000-00HF",
            ),
            (
                "ZZZZZZZZZZZZZZZZZZZZZZZZZZ",
                "ZZZZZZZZZZZZZZZZZZZZZZZZZZ8R",
                "ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZ8R",
            ),
            (
                "7KQF9M2XR4TDH8WBZN3CP6YE1A",
                "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7",
                "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7",
            ),
            (
                "0123456789ABCDEFGHJKMNPQRS",
                "0123456789ABCDEFGHJKMNPQRS45",
                "0123-4567-89AB-CDEF-GHJK-MNPQ-RS45",
            ),
        ] {
            let sum = check(body.as_bytes());
            assert_eq!(
                format!("{body}{}", std::str::from_utf8(&sum).unwrap()),
                canonical
            );
            let key = AccountKey::from_canonical(canonical).unwrap();
            assert_eq!(key.canonical(), canonical);
            assert_eq!(key.display().as_str(), display);
            let typed = AccountKey::parse_input(display).unwrap();
            assert!(typed == key);
            assert!(AccountKey::parse_input(canonical).unwrap() == key);
        }
    }

    #[test]
    fn input_normalization_matches_the_adr_examples() {
        for input in [
            " 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-1aq7 ",
            "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-IAQ7",
            "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-lAQ7",
            "\t7KQF9M2XR4TDH8WBZN3CP6YE1AQ7\r\n",
        ] {
            assert_eq!(
                AccountKey::parse_input(input).unwrap().canonical(),
                "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"
            );
        }
        // O normalizes to zero on input.
        assert_eq!(
            AccountKey::parse_input("oooo-0000-0000-0000-0000-0000-00hf")
                .unwrap()
                .canonical(),
            "00000000000000000000000000HF"
        );
    }

    #[test]
    fn invalid_or_oversized_input_is_a_local_typing_error() {
        for input in [
            "",
            "7KQF9M2XR4TDH8WBZN3CP6YE1AQ8",
            "7KQF9M2XR4TDH8WBZN3CP6YE1AQ",
            "7KQF9M2XR4TDH8WBZN3CP6YE1AQ77",
            "UKQF9M2XR4TDH8WBZN3CP6YE1AQ7",
            "7KQF9M2XR4TDH8WBZN3CP6YE1AU7",
            "7KQF_9M2X_R4TD_H8WB_ZN3C_P6YE_1AQ7",
            "7KQF·9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7",
            "７KQF9M2XR4TDH8WBZN3CP6YE1AQ7",
        ] {
            assert!(AccountKey::parse_input(input).is_none(), "{input:?}");
        }
        // Valid symbols padded beyond 64 UTF-8 bytes are refused before parsing.
        let padded = format!("{}{}", " ".repeat(37), "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7");
        assert_eq!(padded.len(), 65);
        assert!(AccountKey::parse_input(&padded).is_none());
        assert!(AccountKey::parse_input(&padded[1..]).is_some());
        let separators = format!("{}{}", "-".repeat(36), "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7");
        assert_eq!(separators.len(), 64);
        assert!(AccountKey::parse_input(&separators).is_some());
        // Canonical decoding never normalizes.
        for text in [
            "7kqf9m2xr4tdh8wbzn3cp6ye1aq7",
            "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7",
            "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7 ",
            "OOOOOOOOOOOOOOOOOOOOOOOOOOHF",
        ] {
            assert!(AccountKey::from_canonical(text).is_none(), "{text:?}");
        }
    }

    #[test]
    fn account_id_display_uses_the_first_eight_hex_digits_only() {
        let id = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
        assert!(valid_account_id(id));
        assert_eq!(account_id_display(id).as_deref(), Some("1A2B-3C4D"));
        for invalid in [
            "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D",
            "1a2b3c4d5e6f4a7b8c9d0e1f2a3b4c5d",
            "00000000-0000-0000-0000-000000000000",
            "fictional-account",
            "",
        ] {
            assert!(!valid_account_id(invalid) && account_id_display(invalid).is_none());
        }
    }
}
