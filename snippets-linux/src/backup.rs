//! Portable Apple schema-1 encrypted backups. Export never opens secure bodies.
//! Open authenticates all layers before returning any importable data.
use crate::{
    crypto::{self, KdfParameters, RootKey, Sealed},
    model::{self, Error, Result, Snippet},
    vault::Document,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use zeroize::Zeroizing;

pub const FORMAT: &str = "com.khm.snippets.encrypted-backup";
pub const EXTENSION: &str = "snippetsbackup";
const INVALID: Error = Error("This is not a supported Snippets encrypted backup.");
const DAMAGED: Error = Error("The backup is damaged or has been modified. Nothing was imported.");
const PASSWORD: Error = Error("That password does not unlock this backup.");
const TOO_LARGE: Error = Error("The encrypted backup exceeds the 32 MiB size limit.");

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WrappedKey {
    alg: String,
    iterations: u32,
    salt: String,
    envelope: String,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Container {
    format: String,
    schema_version: u32,
    #[serde(rename = "backupID")]
    backup_id: String,
    wrapped_key: WrappedKey,
    payload: String,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Payload {
    schema_version: u32,
    snippets: serde_json::Value,
    vault: Option<Document>,
    wrapped_vault_key: Option<String>,
}
// No Debug or Serialize: the recovered key remains an owned, zeroizing secret.
pub struct Opened {
    pub snippets: Vec<Snippet>,
    pub vault: Option<Document>,
    pub(crate) vault_key: Option<RootKey>,
}
impl Opened {
    pub fn counts(&self) -> (usize, usize) {
        (
            self.snippets.len(),
            self.vault.as_ref().map_or(0, |v| v.records.len()),
        )
    }
    pub fn into_parts(self) -> (Vec<Snippet>, Option<Document>, Option<RootKey>) {
        (self.snippets, self.vault, self.vault_key)
    }
}
fn payload_aad(container: &Container) -> Vec<u8> {
    let wrapped = &container.wrapped_key;
    crypto::domain(
        "snip.backup.payload.v1",
        &[
            FORMAT.as_bytes(),
            &(container.schema_version as u64).to_be_bytes(),
            container.backup_id.as_bytes(),
            wrapped.alg.as_bytes(),
            &(wrapped.iterations as u64).to_be_bytes(),
            wrapped.salt.as_bytes(),
            wrapped.envelope.as_bytes(),
        ],
    )
}
fn validate(snippets: &[Snippet], vault: Option<&Document>) -> Result<()> {
    let mut ids = HashSet::new();
    let mut keywords = HashSet::new();
    if snippets
        .len()
        .saturating_add(vault.map_or(0, |v| v.records.len()))
        > model::MAX_SNIPPETS
    {
        return Err(INVALID);
    }
    let mut accept = |id, keyword: &str| -> Result<()> {
        let keyword = model::folded(&model::keyword(keyword));
        if !ids.insert(id) || (!keyword.is_empty() && !keywords.insert(keyword)) {
            return Err(Error(
                "The backup contains duplicate identifiers or keywords.",
            ));
        }
        Ok(())
    };
    for snippet in snippets {
        snippet.clone().validate()?;
        accept(snippet.id, &snippet.keyword)?;
    }
    if let Some(vault) = vault {
        Document::decode(&vault.encode()?)?;
        if vault.records.is_empty() {
            return Err(INVALID);
        }
        for record in &vault.records {
            accept(record.metadata.id, &record.metadata.keyword)?;
        }
    }
    Ok(())
}
fn portable(vault: &Document) -> Document {
    let mut document = vault.clone();
    document
        .extra
        .retain(|key, _| !key.starts_with("local.syncConflictC0Receipts."));
    document
}
/// Shipping callers always use the pinned 600,000-round KDF and fresh random
/// export key, backup identity and nonces. Empty vaults are omitted by the owner.
pub fn seal(
    snippets: &[Snippet],
    vault: Option<(&Document, &RootKey)>,
    passphrase: &str,
) -> Result<Vec<u8>> {
    seal_inner(snippets, vault, passphrase, crypto::PASSPHRASE_ITERATIONS)
}
fn seal_inner(
    snippets: &[Snippet],
    vault: Option<(&Document, &RootKey)>,
    passphrase: &str,
    iterations: u32,
) -> Result<Vec<u8>> {
    validate(snippets, vault.map(|(v, _)| v))?;
    let export_key = RootKey::generate()?;
    let backup_id = format!("b-{}", uuid::Uuid::new_v4());
    let (parameters, envelope) =
        crypto::wrap_passphrase_cost(&export_key, passphrase, &backup_id, iterations)?;
    let (vault, wrapped_vault_key) = if let Some((vault, key)) = vault {
        (
            Some(portable(vault)),
            Some(crypto::wrap_backup_vault(
                key,
                &export_key,
                &vault.salt()?,
                &backup_id,
                &vault.kid,
            )?),
        )
    } else {
        (None, None)
    };
    let ordinary = Zeroizing::new(model::encode_library(snippets, false)?);
    let payload = Payload {
        schema_version: 1,
        snippets: serde_json::from_slice(&ordinary).map_err(|_| INVALID)?,
        vault,
        wrapped_vault_key,
    };
    let encoded = Zeroizing::new(serde_json::to_vec(&payload).map_err(|_| INVALID)?);
    if encoded.len() > model::MAX_FILE_BYTES {
        return Err(TOO_LARGE);
    }
    let mut container = Container {
        format: FORMAT.into(),
        schema_version: 1,
        backup_id,
        wrapped_key: WrappedKey {
            alg: parameters.alg,
            iterations: parameters.iterations,
            salt: parameters.salt_p,
            envelope: envelope.text().into(),
        },
        payload: String::new(),
    };
    container.payload =
        crypto::seal_backup_payload(&encoded, &export_key, &payload_aad(&container))?;
    let data = serde_json::to_vec_pretty(&container).map_err(|_| INVALID)?;
    if data.len() > model::MAX_FILE_BYTES {
        return Err(TOO_LARGE);
    }
    Ok(data)
}
pub fn is_backup(data: &[u8]) -> bool {
    #[derive(Deserialize)]
    struct Probe {
        format: String,
    }
    data.len() <= model::MAX_FILE_BYTES
        && serde_json::from_slice::<Probe>(data).is_ok_and(|p| p.format == FORMAT)
}
pub fn open(data: &[u8], passphrase: &str) -> Result<Opened> {
    if data.len() > model::MAX_FILE_BYTES {
        return Err(TOO_LARGE);
    }
    if passphrase.is_empty() || passphrase.len() > 4096 {
        return Err(Error("Enter a backup password no larger than 4 KiB."));
    }
    let container: Container = serde_json::from_slice(data).map_err(|_| INVALID)?;
    if container.format != FORMAT
        || container.schema_version != 1
        || container.backup_id.is_empty()
        || container.backup_id.len() > 256
        || container.backup_id.contains('\0')
        || container.wrapped_key.alg != "pbkdf2-hmac-sha512"
        || !(1..=20_000_000).contains(&container.wrapped_key.iterations)
    {
        return Err(INVALID);
    }
    let salt = crypto::unb64(&container.wrapped_key.salt)?;
    if salt.is_empty() || salt.len() > 128 {
        return Err(INVALID);
    }
    let envelope = Sealed::parse(container.wrapped_key.envelope.clone()).map_err(|_| INVALID)?;
    let parameters = KdfParameters {
        alg: container.wrapped_key.alg.clone(),
        iterations: container.wrapped_key.iterations,
        salt_p: container.wrapped_key.salt.clone(),
        extra: BTreeMap::new(),
    };
    let export_key =
        crypto::unwrap_passphrase(&parameters, &envelope, passphrase, &container.backup_id)
            .map_err(|_| PASSWORD)?;
    let data =
        crypto::open_backup_payload(&container.payload, &export_key, &payload_aad(&container))
            .map_err(|_| DAMAGED)?;
    let mut payload: Payload = serde_json::from_slice(&data).map_err(|_| DAMAGED)?;
    if payload.schema_version != 1 {
        return Err(INVALID);
    }
    payload.vault = payload
        .vault
        .map(|v| Document::decode(&v.encode()?))
        .transpose()?;
    let ordinary = Zeroizing::new(serde_json::to_vec(&payload.snippets).map_err(|_| DAMAGED)?);
    let snippets = model::decode_library(&ordinary, false).map_err(|_| DAMAGED)?;
    validate(&snippets, payload.vault.as_ref())?;
    let vault_key = match (&payload.vault, &payload.wrapped_vault_key) {
        (None, None) => None,
        (Some(vault), Some(wrapped)) => {
            let key = crypto::unwrap_backup_vault(
                wrapped,
                &export_key,
                &vault.salt()?,
                &container.backup_id,
                &vault.kid,
            )
            .map_err(|_| DAMAGED)?;
            for record in &vault.records {
                let body = crypto::open_record(
                    &record.sealed,
                    &key,
                    &vault.salt()?,
                    &vault.kid,
                    record.metadata.id,
                    false,
                )
                .map_err(|_| DAMAGED)?;
                crypto::verify_hash(&record.content_hash, &body, &key, &vault.salt()?)
                    .map_err(|_| DAMAGED)?;
            }
            Some(key)
        }
        _ => return Err(DAMAGED),
    };
    payload.vault = payload.vault.as_ref().map(portable);
    Ok(Opened {
        snippets,
        vault: payload.vault,
        vault_key,
    })
}
#[path = "backup_export.rs"]
pub mod export;
#[path = "backup_import.rs"]
pub mod import;
#[cfg(test)]
#[path = "backup_tests.rs"]
mod tests;
