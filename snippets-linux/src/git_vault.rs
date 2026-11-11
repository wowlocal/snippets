//! What a Git library says about its secure-snippet vault, identical to the
//! Apple `GitSyncVault`. A secure snippet's body is sealed under the vault key,
//! which the library key never protects. `keys/vault.json` names the vault
//! (`kid`, salt, passphrase KDF parameters) and carries the vault key wrapped
//! under the library's recovery code (`crypto::wrap_recovery`), so the one code
//! opens the library and its secure snippets on a new device.
//!
//! The file is sealed under a key derived from the library key, with the
//! dataset id in the associated data: only a device that already opened the
//! library can read or replace it, and it cannot be moved to another library.
//! The library key alone never yields the vault key; that takes the recovery
//! code, which no device stores. A passphrase wrap is never published.
//!
//! Replacing the file does not revoke an older code: git history keeps every
//! earlier wrap.
use crate::{bootstrap::Bundle, crypto};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::AeadInOut};
use base64::{Engine, engine::general_purpose::STANDARD};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use uuid::Uuid;
use zeroize::Zeroizing;

pub const PATH: &str = "keys/vault.json";
pub const ALGORITHM: &str = "snippets-git-vault-hkdf-sha256-aes256gcm-v1";
pub const SCHEMA_VERSION: i64 = 1;
const MAX_FILE_BYTES: usize = 8_192;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    /// Missing fields, another library's file, or values outside the format.
    InvalidEnvelope,
    /// Written by a newer build. Never replace it from this one.
    UnsupportedVersion,
    /// The library key does not open the file: another key, or tampering.
    IncorrectKey,
    Randomness,
}

/// The parameters of the optional passphrase wrap. They travel so devices
/// sharing one vault keep one identity; the passphrase wrap itself never does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Kdf {
    pub alg: String,
    pub iterations: u32,
    #[serde(rename = "saltP")]
    pub salt_p: String,
}

/// The vault a library uses. Nothing here opens a secure snippet without the
/// recovery code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub kid: String,
    /// base64url, unpadded, as in `vault.json`.
    pub vault_salt: String,
    pub kdf: Kdf,
    /// The vault key under the library's recovery code.
    pub wrap_recovery: String,
}
impl Identity {
    pub fn vault_salt_bytes(&self) -> Option<[u8; 32]> {
        crypto::unb64(&self.vault_salt).ok()?.try_into().ok()
    }
    /// The shape every writer produces. A reader refuses anything else, so a
    /// file can never smuggle an oversized or unprintable value into
    /// `vault.json`.
    fn well_formed(&self) -> bool {
        token(&self.kid, 128)
            && self.vault_salt_bytes().is_some()
            && token(&self.kdf.alg, 64)
            && (1..=100_000_000).contains(&self.kdf.iterations)
            && token(&self.kdf.salt_p, 128)
            && crypto::unb64(&self.kdf.salt_p).is_ok()
            && token(&self.wrap_recovery, 1_024)
    }
}
/// Printable ASCII without quotes or backslashes, so the canonical JSON below
/// has one spelling in every encoder.
fn token(text: &str, limit: usize) -> bool {
    !text.is_empty()
        && text.len() <= limit
        && text
            .bytes()
            .all(|byte| (0x21..=0x7e).contains(&byte) && byte != b'"' && byte != b'\\')
}

/// Fields in key order: serde writes them as declared, which is Foundation's
/// `.sortedKeys`.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    kdf: Kdf,
    kid: String,
    #[serde(rename = "schemaVersion")]
    schema_version: i64,
    #[serde(rename = "vaultSalt")]
    vault_salt: String,
    #[serde(rename = "wrapRecovery")]
    wrap_recovery: String,
}

fn associated_data(dataset: Uuid) -> Vec<u8> {
    format!("snippets-git-vault-v1\0{}", dataset.hyphenated()).into_bytes()
}
/// A key of its own, so the file's key is never the one that seals records.
fn key(bundle: &Bundle, aad: &[u8]) -> Zeroizing<[u8; 32]> {
    let material = bundle.for_secure_storage();
    let mut key = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(Some(&material[32..]), &material[..32])
        .expand(aad, key.as_mut())
        .expect("32-byte HKDF output");
    key
}

/// The `keys/vault.json` bytes for `identity`, readable with the library key.
pub fn seal(identity: &Identity, bundle: &Bundle, dataset: Uuid) -> Result<Vec<u8>, Failure> {
    let nonce: [u8; 12] = crypto::random().map_err(|_| Failure::Randomness)?;
    seal_with_nonce(identity, bundle, dataset, nonce)
}
pub(crate) fn seal_with_nonce(
    identity: &Identity,
    bundle: &Bundle,
    dataset: Uuid,
    nonce: [u8; 12],
) -> Result<Vec<u8>, Failure> {
    if !identity.well_formed() {
        return Err(Failure::InvalidEnvelope);
    }
    let plaintext = serde_json::to_vec(&Payload {
        kdf: identity.kdf.clone(),
        kid: identity.kid.clone(),
        schema_version: SCHEMA_VERSION,
        vault_salt: identity.vault_salt.clone(),
        wrap_recovery: identity.wrap_recovery.clone(),
    })
    .map_err(|_| Failure::InvalidEnvelope)?;
    let aad = associated_data(dataset);
    let mut buffer = plaintext;
    Aes256Gcm::new_from_slice(key(bundle, &aad).as_slice())
        .expect("32-byte key")
        .encrypt_in_place(&Nonce::from(nonce), &aad, &mut buffer)
        .map_err(|_| Failure::InvalidEnvelope)?;
    let mut combined = nonce.to_vec();
    combined.extend_from_slice(&buffer);
    // Foundation's `[.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]`.
    Ok(format!(
        "{{\n  \"algorithm\" : \"{ALGORITHM}\",\n  \"ciphertext\" : \"{}\",\n  \"datasetID\" : \"{}\",\n  \"schemaVersion\" : {SCHEMA_VERSION}\n}}\n",
        STANDARD.encode(combined),
        dataset.hyphenated()
    )
    .into_bytes())
}

/// The identity inside `file`, authenticated by the library key and bound to
/// `dataset`.
pub fn open(file: &[u8], bundle: &Bundle, dataset: Uuid) -> Result<Identity, Failure> {
    if file.len() > MAX_FILE_BYTES {
        return Err(Failure::InvalidEnvelope);
    }
    let Ok(serde_json::Value::Object(object)) = serde_json::from_slice(file) else {
        return Err(Failure::InvalidEnvelope);
    };
    // Probe the version before the shape: a newer format may carry other keys,
    // and it must read as "update Snippets", never as damage to overwrite.
    if object
        .get("schemaVersion")
        .and_then(serde_json::Value::as_i64)
        .is_some_and(|version| version > SCHEMA_VERSION)
    {
        return Err(Failure::UnsupportedVersion);
    }
    let keys = ["algorithm", "ciphertext", "datasetID", "schemaVersion"];
    if object.len() != keys.len() || !keys.iter().all(|k| object.contains_key(*k)) {
        return Err(Failure::InvalidEnvelope);
    }
    let (Some(algorithm), Some(text), Some(id)) = (
        object["algorithm"].as_str(),
        object["ciphertext"].as_str(),
        object["datasetID"].as_str(),
    ) else {
        return Err(Failure::InvalidEnvelope);
    };
    if !object["schemaVersion"].is_i64()
        || object["schemaVersion"].as_i64() != Some(SCHEMA_VERSION)
        || algorithm != ALGORITHM
        || id != dataset.hyphenated().to_string()
    {
        return Err(Failure::InvalidEnvelope);
    }
    let combined = STANDARD
        .decode(text)
        .map_err(|_| Failure::InvalidEnvelope)?;
    if STANDARD.encode(&combined) != text || combined.len() < 12 + 16 {
        return Err(Failure::InvalidEnvelope);
    }
    let aad = associated_data(dataset);
    let nonce: [u8; 12] = combined[..12].try_into().expect("12-byte nonce");
    let mut buffer = combined[12..].to_vec();
    Aes256Gcm::new_from_slice(key(bundle, &aad).as_slice())
        .expect("32-byte key")
        .decrypt_in_place(&Nonce::from(nonce), &aad, &mut buffer)
        .map_err(|_| Failure::IncorrectKey)?;
    let payload: Payload = serde_json::from_slice(&buffer).map_err(|_| Failure::InvalidEnvelope)?;
    if payload.schema_version != SCHEMA_VERSION {
        return Err(Failure::InvalidEnvelope);
    }
    let identity = Identity {
        kid: payload.kid,
        vault_salt: payload.vault_salt,
        kdf: payload.kdf,
        wrap_recovery: payload.wrap_recovery,
    };
    if !identity.well_formed() {
        return Err(Failure::InvalidEnvelope);
    }
    Ok(identity)
}
