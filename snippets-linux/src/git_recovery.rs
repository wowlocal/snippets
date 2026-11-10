//! The offline way to give another device a Git library's key, identical to
//! the Apple `GitSyncRecovery`. The repository holds `keys/recovery.json`: the
//! portable sync-v1 bundle sealed under a key derived from a 128-bit recovery
//! code only the user has. The code is bound to the library's random dataset
//! id, not to the host, so moving the repository keeps the code valid while a
//! code can never open a different library.
//!
//! Replacing the envelope does not revoke an older code: git history keeps
//! every envelope. Revoking a leaked code means creating a new library.
use crate::{bootstrap::Bundle, crypto};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::AeadInOut};
use base64::{Engine, engine::general_purpose::STANDARD};
use hkdf::Hkdf;
use sha2::Sha256;
use uuid::Uuid;
use zeroize::Zeroizing;

pub const ALGORITHM: &str = "snippets-git-recovery-hkdf-sha256-aes256gcm-v1";
pub const SCHEMA_VERSION: i64 = 1;
const MAX_FILE_BYTES: usize = 8_192;
const SALT: &[u8] = b"snippets-git-recovery-salt-v1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    /// Not a well-formed recovery code (length, alphabet or check symbol).
    InvalidCode,
    /// A well-formed code that does not open this library's envelope.
    IncorrectCode,
    /// The repository's envelope is missing, malformed, or for another library.
    InvalidEnvelope,
    Randomness,
}

/// A recovery secret bound to one library. No Debug, Display or Clone.
pub struct Kit {
    dataset: Uuid,
    secret: Zeroizing<[u8; 16]>,
}
impl Kit {
    pub fn generate(dataset: Uuid) -> Result<Self, Failure> {
        Ok(Self {
            dataset,
            secret: Zeroizing::new(crypto::random().map_err(|_| Failure::Randomness)?),
        })
    }
    /// Accepts what a person types: case, spaces, dashes and the classic
    /// misreadings are normalized exactly like the Apple `RecoveryKey`.
    pub fn from_code(code: &str, dataset: Uuid) -> Result<Self, Failure> {
        let secret = crypto::decode_recovery(code).map_err(|_| Failure::InvalidCode)?;
        Ok(Self { dataset, secret })
    }
    /// `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX`.
    pub fn code(&self) -> Zeroizing<String> {
        crypto::format_recovery(&self.secret)
    }
    fn associated_data(&self) -> Vec<u8> {
        format!("snippets-git-recovery-v1\0{}", self.dataset.hyphenated()).into_bytes()
    }
    fn key(&self, aad: &[u8]) -> Zeroizing<[u8; 32]> {
        let mut key = Zeroizing::new([0u8; 32]);
        Hkdf::<Sha256>::new(Some(SALT), self.secret.as_slice())
            .expand(aad, key.as_mut())
            .expect("32-byte HKDF output");
        key
    }
    /// The `keys/recovery.json` bytes for `bundle` under this kit.
    pub fn seal(&self, bundle: &Bundle) -> Result<Vec<u8>, Failure> {
        let plaintext = bundle
            .encode_secret()
            .map_err(|_| Failure::InvalidEnvelope)?;
        let aad = self.associated_data();
        let nonce: [u8; 12] = crypto::random().map_err(|_| Failure::Randomness)?;
        let mut buffer = Zeroizing::new(plaintext.to_vec());
        Aes256Gcm::new_from_slice(self.key(&aad).as_slice())
            .expect("32-byte key")
            .encrypt_in_place(&Nonce::from(nonce), &aad, &mut *buffer)
            .map_err(|_| Failure::InvalidEnvelope)?;
        let mut combined = nonce.to_vec();
        combined.extend_from_slice(&buffer);
        // Foundation's `[.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]`.
        Ok(format!(
            "{{\n  \"algorithm\" : \"{ALGORITHM}\",\n  \"ciphertext\" : \"{}\",\n  \"datasetID\" : \"{}\",\n  \"schemaVersion\" : {SCHEMA_VERSION}\n}}\n",
            STANDARD.encode(combined),
            self.dataset.hyphenated()
        )
        .into_bytes())
    }
    /// The bundle inside `file`, or `IncorrectCode` if this kit does not open it.
    pub fn open(&self, file: &[u8]) -> Result<Bundle, Failure> {
        if file.len() > MAX_FILE_BYTES {
            return Err(Failure::InvalidEnvelope);
        }
        let Ok(serde_json::Value::Object(object)) = serde_json::from_slice(file) else {
            return Err(Failure::InvalidEnvelope);
        };
        let keys = ["algorithm", "ciphertext", "datasetID", "schemaVersion"];
        if object.len() != keys.len() || !keys.iter().all(|k| object.contains_key(*k)) {
            return Err(Failure::InvalidEnvelope);
        }
        let dataset = self.dataset.hyphenated().to_string();
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
            || id != dataset
        {
            return Err(Failure::InvalidEnvelope);
        }
        let combined = STANDARD
            .decode(text)
            .map_err(|_| Failure::InvalidEnvelope)?;
        if STANDARD.encode(&combined) != text || combined.len() < 12 + 16 {
            return Err(Failure::InvalidEnvelope);
        }
        let aad = self.associated_data();
        let nonce: [u8; 12] = combined[..12].try_into().expect("12-byte nonce");
        let mut buffer = Zeroizing::new(combined[12..].to_vec());
        Aes256Gcm::new_from_slice(self.key(&aad).as_slice())
            .expect("32-byte key")
            .decrypt_in_place(&Nonce::from(nonce), &aad, &mut *buffer)
            .map_err(|_| Failure::IncorrectCode)?;
        Bundle::decode(&buffer).map_err(|_| Failure::InvalidEnvelope)
    }
}
