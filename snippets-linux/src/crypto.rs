//! Frozen Snippets v1 wire format; cryptographic operations use RustCrypto.
//! Secret owners have no Debug/Serialize implementation and clear owned memory
//! on drop. This does not promise to erase every CPU, toolkit, or OS copy.
use crate::model::{Error, MAX_BODY_BYTES, Result};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::AeadInOut};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Sha256, Sha512};
use std::collections::BTreeMap;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;
use zeroize::Zeroizing;

pub const PASSPHRASE_ITERATIONS: u32 = 600_000;
const AUTHENTICATION: Error = Error("The encrypted content could not be authenticated.");
const MALFORMED: Error = Error("The encrypted record is invalid or uses an unsupported format.");
pub const MAX_WIRE_PLAINTEXT: usize = 674_815;
pub(crate) const MAX_CHECKPOINT_BYTES: usize = 256 * 1024 * 1024 - 32;

pub struct RootKey(Zeroizing<[u8; 32]>);
impl RootKey {
    pub fn generate() -> Result<Self> {
        Ok(Self(Zeroizing::new(random()?)))
    }
    pub(crate) fn from_bytes(bytes: &[u8]) -> Result<Self> {
        Ok(Self(Zeroizing::new(
            bytes.try_into().map_err(|_| MALFORMED)?,
        )))
    }
    fn bytes(&self) -> &[u8; 32] {
        &self.0
    }
    pub(crate) fn same_key(&self, other: &Self) -> bool {
        let mut first = Hmac::<Sha256>::new_from_slice(self.bytes()).expect("key");
        first.update(b"snip.backup.key-identity.v1");
        let mut second = Hmac::<Sha256>::new_from_slice(other.bytes()).expect("key");
        second.update(b"snip.backup.key-identity.v1");
        second.verify_slice(&first.finalize().into_bytes()).is_ok()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Sealed(String);
impl Sealed {
    pub fn parse(text: String) -> Result<Self> {
        parse_envelope(&text)?;
        Ok(Self(text))
    }
    pub(crate) fn text(&self) -> &str {
        &self.0
    }
    pub fn validate(&self) -> Result<()> {
        parse_envelope(&self.0).map(|_| ())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KdfParameters {
    pub alg: String,
    pub iterations: u32,
    pub salt_p: String,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}
pub fn random<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).map_err(|_| Error("Secure randomness is unavailable."))?;
    Ok(bytes)
}

// Linux-only checkpoint format. The caller supplies a separate per-install key,
// never the synchronized vault or transport key. Scope identities live inside
// the authenticated plaintext, ahead of every envelope in the bounded decoder.
pub(crate) fn seal_checkpoint(bytes: &[u8], root: &RootKey, salt: &[u8; 32]) -> Result<Vec<u8>> {
    if bytes.len() > MAX_CHECKPOINT_BYTES {
        return Err(MALFORMED);
    }
    let key = derive(root.bytes(), salt, b"snip.linux-checkpoint.key.v1");
    let nonce: [u8; 12] = random()?;
    let mut buffer = Zeroizing::new(Vec::with_capacity(bytes.len() + 16));
    buffer.extend_from_slice(bytes);
    Aes256Gcm::new_from_slice(&*key)
        .expect("32-byte key")
        .encrypt_in_place(
            &Nonce::from(nonce),
            b"snip.linux-checkpoint.v1",
            &mut *buffer,
        )
        .map_err(|_| MALFORMED)?;
    let mut result = Vec::with_capacity(buffer.len() + 16);
    result.extend_from_slice(b"SCJ1");
    result.extend_from_slice(&nonce);
    result.extend_from_slice(&buffer);
    Ok(result)
}
pub(crate) fn open_checkpoint(
    bytes: &[u8],
    root: &RootKey,
    salt: &[u8; 32],
) -> Result<Zeroizing<Vec<u8>>> {
    if !(32..=MAX_CHECKPOINT_BYTES + 32).contains(&bytes.len()) || &bytes[..4] != b"SCJ1" {
        return Err(MALFORMED);
    }
    let key = derive(root.bytes(), salt, b"snip.linux-checkpoint.key.v1");
    let nonce: [u8; 12] = bytes[4..16].try_into().map_err(|_| MALFORMED)?;
    let mut buffer = Zeroizing::new(bytes[16..].to_vec());
    Aes256Gcm::new_from_slice(&*key)
        .expect("32-byte key")
        .decrypt_in_place(
            &Nonce::from(nonce),
            b"snip.linux-checkpoint.v1",
            &mut *buffer,
        )
        .map_err(|_| AUTHENTICATION)?;
    Ok(buffer)
}
pub fn b64(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}
pub fn unb64(text: &str) -> Result<Vec<u8>> {
    if text.is_empty() || text.len() > 2 * MAX_BODY_BYTES {
        return Err(MALFORMED);
    }
    URL_SAFE_NO_PAD.decode(text).map_err(|_| MALFORMED)
}
pub fn domain(name: &str, fields: &[&[u8]]) -> Vec<u8> {
    let mut bytes = Vec::new();
    for field in std::iter::once(name.as_bytes()).chain(fields.iter().copied()) {
        bytes.extend_from_slice(&(field.len() as u32).to_be_bytes());
        bytes.extend_from_slice(field);
    }
    bytes
}
fn derive(input: &[u8], salt: &[u8], info: &[u8]) -> Zeroizing<[u8; 32]> {
    let mut key = Zeroizing::new([0; 32]);
    Hkdf::<Sha256>::new(Some(salt), input)
        .expand(info, key.as_mut())
        .expect("32-byte HKDF output");
    key
}
fn record_key(root: &RootKey, salt: &[u8; 32], id: Uuid) -> Zeroizing<[u8; 32]> {
    let mut info = b"snip.wire.v1|".to_vec();
    info.extend_from_slice(id.as_bytes());
    derive(root.bytes(), salt, &info)
}
pub fn record_aad(kid: &str, id: Uuid, deleted: bool) -> Vec<u8> {
    domain(
        "snip.aad.v1",
        &[b"v1", kid.as_bytes(), id.as_bytes(), &[u8::from(deleted)]],
    )
}
fn parse_envelope_bounded(text: &str, limit: usize) -> Result<([u8; 12], Vec<u8>)> {
    if text.len() > 2 * limit {
        return Err(MALFORMED);
    }
    let fields: Vec<_> = text.split('.').collect();
    if fields.len() != 3 || fields[0] != "v1" {
        return Err(MALFORMED);
    }
    let nonce = URL_SAFE_NO_PAD
        .decode(fields[1])
        .map_err(|_| MALFORMED)?
        .try_into()
        .map_err(|_| MALFORMED)?;
    let bytes = URL_SAFE_NO_PAD.decode(fields[2]).map_err(|_| MALFORMED)?;
    if bytes.len() < 272 || (bytes.len() - 16) % 256 != 0 || bytes.len() > limit + 256 + 16 {
        return Err(MALFORMED);
    }
    Ok((nonce, bytes))
}
fn parse_envelope(text: &str) -> Result<([u8; 12], Vec<u8>)> {
    parse_envelope_bounded(text, MAX_BODY_BYTES)
}
fn seal_bounded(bytes: &[u8], key: &[u8; 32], aad: &[u8], limit: usize) -> Result<Sealed> {
    if bytes.len() > limit {
        return Err(Error("Secure content exceeds the 256 KiB limit."));
    }
    let padded = (bytes.len() + 1).div_ceil(256) * 256;
    let mut buffer = Zeroizing::new(Vec::with_capacity(padded + 16));
    buffer.extend_from_slice(bytes);
    buffer.push(0x80);
    buffer.resize(padded, 0);
    let nonce_bytes: [u8; 12] = random()?;
    Aes256Gcm::new_from_slice(key)
        .expect("32-byte key")
        .encrypt_in_place(&Nonce::from(nonce_bytes), aad, &mut *buffer)
        .map_err(|_| MALFORMED)?;
    Ok(Sealed(format!("v1.{}.{}", b64(&nonce_bytes), b64(&buffer))))
}
fn seal(bytes: &[u8], key: &[u8; 32], aad: &[u8]) -> Result<Sealed> {
    seal_bounded(bytes, key, aad, MAX_BODY_BYTES)
}
fn open_bounded(
    envelope: &Sealed,
    key: &[u8; 32],
    aad: &[u8],
    limit: usize,
) -> Result<Zeroizing<Vec<u8>>> {
    let (nonce, bytes) = parse_envelope_bounded(envelope.text(), limit)?;
    let mut buffer = Zeroizing::new(bytes);
    Aes256Gcm::new_from_slice(key)
        .expect("32-byte key")
        .decrypt_in_place(&Nonce::from(nonce), aad, &mut *buffer)
        .map_err(|_| AUTHENTICATION)?;
    let Some(marker) = buffer.iter().rposition(|byte| *byte != 0) else {
        return Err(MALFORMED);
    };
    if buffer[marker] != 0x80 || marker > limit {
        return Err(MALFORMED);
    }
    buffer.truncate(marker);
    Ok(buffer)
}
fn open(envelope: &Sealed, key: &[u8; 32], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    open_bounded(envelope, key, aad, MAX_BODY_BYTES)
}
pub(crate) fn seal_wire(
    bytes: &[u8],
    root: &RootKey,
    salt: &[u8; 32],
    id: Uuid,
    deleted: bool,
) -> Result<Vec<u8>> {
    Ok(seal_bounded(
        bytes,
        &record_key(root, salt, id),
        &record_aad("sync-v1", id, deleted),
        MAX_WIRE_PLAINTEXT,
    )?
    .0
    .into_bytes())
}
pub(crate) fn open_wire(
    bytes: &[u8],
    root: &RootKey,
    salt: &[u8; 32],
    id: Uuid,
    deleted: bool,
) -> Result<Zeroizing<Vec<u8>>> {
    let text = std::str::from_utf8(bytes).map_err(|_| MALFORMED)?;
    open_bounded(
        &Sealed(text.to_owned()),
        &record_key(root, salt, id),
        &record_aad("sync-v1", id, deleted),
        MAX_WIRE_PLAINTEXT,
    )
}
pub fn seal_record(
    bytes: &[u8],
    root: &RootKey,
    salt: &[u8; 32],
    kid: &str,
    id: Uuid,
    deleted: bool,
) -> Result<Sealed> {
    seal(
        bytes,
        &record_key(root, salt, id),
        &record_aad(kid, id, deleted),
    )
}
pub fn open_record(
    envelope: &Sealed,
    root: &RootKey,
    salt: &[u8; 32],
    kid: &str,
    id: Uuid,
    deleted: bool,
) -> Result<Zeroizing<Vec<u8>>> {
    open(
        envelope,
        &record_key(root, salt, id),
        &record_aad(kid, id, deleted),
    )
}
fn draft_aad(kid: &str, id: Uuid) -> Vec<u8> {
    domain(
        "snip.local-draft.v1",
        &[b"v1", kid.as_bytes(), id.as_bytes()],
    )
}
pub(crate) fn seal_draft(
    bytes: &[u8],
    root: &RootKey,
    salt: &[u8; 32],
    kid: &str,
    id: Uuid,
) -> Result<Sealed> {
    seal(bytes, &record_key(root, salt, id), &draft_aad(kid, id))
}
pub(crate) fn open_draft(
    envelope: &Sealed,
    root: &RootKey,
    salt: &[u8; 32],
    kid: &str,
    id: Uuid,
) -> Result<Zeroizing<Vec<u8>>> {
    open(envelope, &record_key(root, salt, id), &draft_aad(kid, id))
}
fn hash_mac(bytes: &[u8], root: &RootKey, salt: &[u8; 32]) -> Hmac<Sha256> {
    let key = derive(root.bytes(), salt, b"snip.chash.v1");
    let mut mac = Hmac::<Sha256>::new_from_slice(&*key).expect("32-byte HMAC key");
    mac.update(bytes);
    mac
}
pub fn content_hash(bytes: &[u8], root: &RootKey, salt: &[u8; 32]) -> String {
    hash_mac(bytes, root, salt).finalize().into_bytes()[..16]
        .iter()
        .map(|v| format!("{v:02x}"))
        .collect()
}
pub fn verify_hash(expected: &str, bytes: &[u8], root: &RootKey, salt: &[u8; 32]) -> Result<()> {
    if expected.len() != 32
        || !expected
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(MALFORMED);
    }
    let tag: Vec<_> = (0..32)
        .step_by(2)
        .map(|index| u8::from_str_radix(&expected[index..index + 2], 16).expect("hex checked"))
        .collect();
    hash_mac(bytes, root, salt)
        .verify_truncated_left(&tag)
        .map_err(|_| AUTHENTICATION)
}
fn passphrase_key(passphrase: &str, salt: &[u8], iterations: u32) -> Result<Zeroizing<[u8; 32]>> {
    if passphrase.is_empty() || passphrase.len() > 4096 {
        return Err(Error("Enter a passphrase no larger than 4 KiB."));
    }
    if !(1..=20_000_000).contains(&iterations) || salt.is_empty() || salt.len() > 128 {
        return Err(Error("The vault has unsupported passphrase parameters."));
    }
    let normalized = Zeroizing::new(passphrase.nfc().collect::<String>());
    let mut key = Zeroizing::new([0; 32]);
    pbkdf2::pbkdf2_hmac::<Sha512>(normalized.as_bytes(), salt, iterations, key.as_mut());
    Ok(key)
}
fn passphrase_aad(kid: &str, salt: &[u8], iterations: u32) -> Vec<u8> {
    domain(
        "snip.kdf.v1",
        &[
            b"pbkdf2-hmac-sha512",
            &(iterations as u64).to_be_bytes(),
            salt,
            kid.as_bytes(),
        ],
    )
}
pub fn wrap_passphrase(
    root: &RootKey,
    passphrase: &str,
    kid: &str,
) -> Result<(KdfParameters, Sealed)> {
    wrap_passphrase_cost(root, passphrase, kid, PASSPHRASE_ITERATIONS)
}
pub(crate) fn wrap_passphrase_cost(
    root: &RootKey,
    passphrase: &str,
    kid: &str,
    iterations: u32,
) -> Result<(KdfParameters, Sealed)> {
    let salt: [u8; 16] = random()?;
    let key = passphrase_key(passphrase, &salt, iterations)?;
    Ok((
        KdfParameters {
            alg: "pbkdf2-hmac-sha512".into(),
            iterations,
            salt_p: b64(&salt),
            extra: BTreeMap::new(),
        },
        seal(root.bytes(), &key, &passphrase_aad(kid, &salt, iterations))?,
    ))
}

// Portable Apple backup domains. Keys stay inside this module; only sealed
// vault material or a non-serializable owner can cross its boundary.
pub(crate) fn seal_backup_payload(bytes: &[u8], key: &RootKey, aad: &[u8]) -> Result<String> {
    Ok(seal_bounded(bytes, key.bytes(), aad, crate::model::MAX_FILE_BYTES)?.0)
}
pub(crate) fn open_backup_payload(
    text: &str,
    key: &RootKey,
    aad: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    open_bounded(
        &Sealed(text.into()),
        key.bytes(),
        aad,
        crate::model::MAX_FILE_BYTES,
    )
}
fn backup_vault_key(
    export: &RootKey,
    salt: &[u8; 32],
    backup: &str,
    kid: &str,
) -> Zeroizing<[u8; 32]> {
    let mut info = b"snip.backup.vault-key.v1|".to_vec();
    info.extend_from_slice(backup.as_bytes());
    info.push(0);
    info.extend_from_slice(kid.as_bytes());
    derive(export.bytes(), salt, &info)
}
fn backup_vault_aad(backup: &str, kid: &str) -> Vec<u8> {
    domain(
        "snip.backup.vault-key-aad.v1",
        &[b"v1", backup.as_bytes(), kid.as_bytes()],
    )
}
pub(crate) fn wrap_backup_vault(
    root: &RootKey,
    export: &RootKey,
    salt: &[u8; 32],
    backup: &str,
    kid: &str,
) -> Result<String> {
    Ok(seal(
        root.bytes(),
        &backup_vault_key(export, salt, backup, kid),
        &backup_vault_aad(backup, kid),
    )?
    .0)
}
pub(crate) fn unwrap_backup_vault(
    text: &str,
    export: &RootKey,
    salt: &[u8; 32],
    backup: &str,
    kid: &str,
) -> Result<RootKey> {
    RootKey::from_bytes(&open(
        &Sealed::parse(text.into())?,
        &backup_vault_key(export, salt, backup, kid),
        &backup_vault_aad(backup, kid),
    )?)
}
pub fn unwrap_passphrase(
    parameters: &KdfParameters,
    envelope: &Sealed,
    passphrase: &str,
    kid: &str,
) -> Result<RootKey> {
    if parameters.alg != "pbkdf2-hmac-sha512" {
        return Err(Error(
            "The vault needs a supported passphrase wrap or its recovery key.",
        ));
    }
    let salt = unb64(&parameters.salt_p)?;
    let key = passphrase_key(passphrase, &salt, parameters.iterations)?;
    RootKey::from_bytes(&open(
        envelope,
        &key,
        &passphrase_aad(kid, &salt, parameters.iterations),
    )?)
}
fn recovery_key(material: &[u8; 16], salt: &[u8; 32]) -> Zeroizing<[u8; 32]> {
    derive(material, salt, b"snip.wrap.v1|recovery")
}
fn recovery_aad(kid: &str) -> Vec<u8> {
    domain("snip.wrap.v1", &[b"v1", b"recovery", kid.as_bytes()])
}
pub fn wrap_recovery(
    root: &RootKey,
    material: &[u8; 16],
    salt: &[u8; 32],
    kid: &str,
) -> Result<Sealed> {
    seal(
        root.bytes(),
        &recovery_key(material, salt),
        &recovery_aad(kid),
    )
}
pub fn unwrap_recovery(
    envelope: &Sealed,
    material: &[u8; 16],
    salt: &[u8; 32],
    kid: &str,
) -> Result<RootKey> {
    RootKey::from_bytes(&open(
        envelope,
        &recovery_key(material, salt),
        &recovery_aad(kid),
    )?)
}

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
pub fn format_recovery(bytes: &[u8; 16]) -> Zeroizing<String> {
    let mut symbols = Zeroizing::new(Vec::with_capacity(27));
    let (mut accumulator, mut bits) = (0u32, 0u32);
    for byte in bytes {
        accumulator = (accumulator << 8) | *byte as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            symbols.push(((accumulator >> bits) & 31) as u8);
            accumulator &= (1 << bits) - 1;
        }
    }
    if bits > 0 {
        symbols.push(((accumulator << (5 - bits)) & 31) as u8);
    }
    let checksum = symbols
        .iter()
        .enumerate()
        .map(|(i, v)| (2 * i + 1) * *v as usize)
        .sum::<usize>()
        % 32;
    symbols.push(checksum as u8);
    let mut text = Zeroizing::new(String::with_capacity(33));
    for (index, symbol) in symbols.iter().enumerate() {
        if index > 0 && index % 4 == 0 {
            text.push('-');
        }
        text.push(ALPHABET[*symbol as usize] as char);
    }
    text
}
pub fn decode_recovery(text: &str) -> Result<Zeroizing<[u8; 16]>> {
    if text.len() > 4096 {
        return Err(Error("Enter the full recovery key."));
    }
    let mut symbols = Zeroizing::new(Vec::with_capacity(27));
    for c in text.chars().flat_map(char::to_uppercase) {
        let c = match c {
            ' ' | '\t' | '\n' | '\r' | '\u{a0}' | '-' | '\u{2010}' | '\u{2011}' | '\u{2012}'
            | '\u{2013}' | '\u{2014}' | '\u{2212}' | '_' => continue,
            'I' | 'L' => '1',
            'O' => '0',
            c => c,
        };
        let value = ALPHABET
            .iter()
            .position(|v| *v as char == c)
            .ok_or(Error("Enter the full recovery key."))?;
        symbols.push(value as u8);
        if symbols.len() > 27 {
            return Err(Error("Enter the full recovery key."));
        }
    }
    if symbols.len() != 27 {
        return Err(Error("Enter the full recovery key."));
    }
    if symbols[..26]
        .iter()
        .enumerate()
        .map(|(i, v)| (2 * i + 1) * *v as usize)
        .sum::<usize>()
        % 32
        != symbols[26] as usize
    {
        return Err(Error("The recovery key has a transcription error."));
    }
    let mut bytes = Zeroizing::new([0u8; 16]);
    let (mut accumulator, mut bits, mut index) = (0u32, 0u32, 0);
    for symbol in &symbols[..26] {
        accumulator = (accumulator << 5) | *symbol as u32;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            bytes[index] = ((accumulator >> bits) & 255) as u8;
            index += 1;
            accumulator &= (1 << bits) - 1;
        }
    }
    if accumulator != 0 {
        return Err(Error("The recovery key has an invalid encoding."));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> serde_json::Value {
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap()
    }
    #[test]
    fn independent_openssl_fixture_matches_key_hierarchy_aad_and_padding() {
        let fixture = fixture();
        let record = &fixture["document"]["records"][0];
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let salt = [0x22; 32];
        let id = Uuid::parse_str(record["id"].as_str().unwrap()).unwrap();
        let kid = fixture["document"]["kid"].as_str().unwrap();
        let envelope = Sealed::parse(record["sealed"].as_str().unwrap().into()).unwrap();
        let body = open_record(&envelope, &root, &salt, kid, id, false).unwrap();
        assert!(*body == fixture["plaintext"].as_str().unwrap().as_bytes());
        assert!(content_hash(&body, &root, &salt) == record["contentHash"].as_str().unwrap());
        verify_hash(record["contentHash"].as_str().unwrap(), &body, &root, &salt).unwrap();
    }
    #[test]
    fn envelope_authenticates_id_scope_deletion_flag_key_and_salt() {
        let root = RootKey::generate().unwrap();
        let id = Uuid::new_v4();
        let salt = [0x22; 32];
        let sealed = seal_record(b"Fictional secret", &root, &salt, "fixture", id, false).unwrap();
        assert!(open_record(&sealed, &root, &salt, "other", id, false).is_err());
        assert!(open_record(&sealed, &root, &salt, "fixture", Uuid::new_v4(), false).is_err());
        assert!(open_record(&sealed, &root, &salt, "fixture", id, true).is_err());
        assert!(
            open_record(
                &sealed,
                &RootKey::generate().unwrap(),
                &salt,
                "fixture",
                id,
                false
            )
            .is_err()
        );
        assert!(open_record(&sealed, &root, &[0x23; 32], "fixture", id, false).is_err());
        let (nonce, mut ciphertext) = parse_envelope(sealed.text()).unwrap();
        ciphertext[20] ^= 1;
        let damaged = Sealed(format!("v1.{}.{}", b64(&nonce), b64(&ciphertext)));
        assert!(open_record(&damaged, &root, &salt, "fixture", id, false).is_err());
        let mut nonce = nonce;
        nonce[0] ^= 1;
        let damaged = Sealed(format!(
            "v1.{}.{}",
            b64(&nonce),
            sealed.text().split('.').nth(2).unwrap()
        ));
        assert!(open_record(&damaged, &root, &salt, "fixture", id, false).is_err());
    }
    #[test]
    fn padding_preserves_empty_full_block_and_trailing_zero_data_with_fresh_nonces() {
        let root = RootKey::generate().unwrap();
        let id = Uuid::new_v4();
        for length in [0, 1, 255, 256, 257, MAX_BODY_BYTES] {
            let body = Zeroizing::new(vec![0; length]);
            let first = seal_record(&body, &root, &[1; 32], "fixture", id, false).unwrap();
            let second = seal_record(&body, &root, &[1; 32], "fixture", id, false).unwrap();
            assert!(first != second);
            assert!(*open_record(&first, &root, &[1; 32], "fixture", id, false).unwrap() == *body);
            assert!((parse_envelope(first.text()).unwrap().1.len() - 16).is_multiple_of(256));
        }
        assert!(
            seal_record(
                &vec![0; MAX_BODY_BYTES + 1],
                &root,
                &[1; 32],
                "fixture",
                id,
                false
            )
            .is_err()
        );
    }
    #[test]
    fn noncanonical_encodings_and_unbounded_or_unknown_envelopes_are_refused() {
        for text in ["Zg==", "Zh", "AA+_", "", "x"] {
            assert!(unb64(text).is_err());
        }
        for text in ["v2.AAAA.AAAA", "v1.AAAA.AAAA", "v1..", "v1.a.b.c"] {
            assert!(Sealed::parse(text.into()).is_err());
        }
        assert!(Sealed::parse("x".repeat(2 * MAX_BODY_BYTES + 1)).is_err());
    }
    #[test]
    fn passphrase_normalization_parameters_and_scope_match_the_independent_fixture() {
        let fixture = fixture();
        let document = &fixture["document"];
        let parameters: KdfParameters = serde_json::from_value(document["kdf"].clone()).unwrap();
        let envelope: Sealed = serde_json::from_value(document["wrapPass"].clone()).unwrap();
        let kid = document["kid"].as_str().unwrap();
        let key =
            unwrap_passphrase(&parameters, &envelope, "Cafe\u{301} public fixture", kid).unwrap();
        assert!(key.bytes() == &[0x11; 32]);
        assert!(unwrap_passphrase(&parameters, &envelope, "Wrong public fixture", kid).is_err());
        assert!(unwrap_passphrase(&parameters, &envelope, "Café public fixture", "other").is_err());
        for iterations in [0, 20_000_001] {
            let mut changed = parameters.clone();
            changed.iterations = iterations;
            assert!(unwrap_passphrase(&changed, &envelope, "Café public fixture", kid).is_err());
        }
        assert!(passphrase_key("", &[1; 16], 1).is_err());
        assert!(passphrase_key(&"x".repeat(4097), &[1; 16], 1).is_err());
    }
    #[test]
    fn recovery_wrap_and_every_single_symbol_transcription_are_checked() {
        let fixture = fixture();
        let document = &fixture["document"];
        let envelope: Sealed = serde_json::from_value(document["wrapRecovery"].clone()).unwrap();
        let root = unwrap_recovery(
            &envelope,
            &[0x66; 16],
            &[0x22; 32],
            document["kid"].as_str().unwrap(),
        )
        .unwrap();
        assert!(root.bytes() == &[0x11; 32]);
        assert!(
            unwrap_recovery(
                &envelope,
                &[0x67; 16],
                &[0x22; 32],
                document["kid"].as_str().unwrap()
            )
            .is_err()
        );
        for material in [[0; 16], [0xff; 16], [0x66; 16]] {
            let formatted = format_recovery(&material);
            assert!(*decode_recovery(&formatted).unwrap() == material);
            let alias = formatted
                .to_lowercase()
                .replace('0', "O")
                .replace('1', "l")
                .replace('-', "\u{2011}");
            assert!(*decode_recovery(&alias).unwrap() == material);
            let original = formatted.replace('-', "").into_bytes();
            for index in 0..27 {
                for symbol in ALPHABET {
                    if *symbol == original[index] {
                        continue;
                    }
                    let mut changed = original.clone();
                    changed[index] = *symbol;
                    assert!(decode_recovery(std::str::from_utf8(&changed).unwrap()).is_err());
                }
            }
        }
    }
}
