//! Authenticated secure conflict preservation. Keys are borrowed from their
//! bounded owner; plaintext never enters an envelope, record, or returned proof.
use crate::{
    canonical::Value,
    crypto::{self, RootKey, Sealed},
    merge::{self, SecureVariant},
    model::{self, Error, Snippet},
    vault::{Document, Record},
    wire::{Envelope, Fields},
};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    MalformedVariant,
    IncompatibleVault,
    IdentifierCollision,
    ContentHashMismatch,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<Error> for Failure {
    fn from(_: Error) -> Self {
        Self::MalformedVariant
    }
}
impl From<merge::Failure> for Failure {
    fn from(_: merge::Failure) -> Self {
        Self::MalformedVariant
    }
}

/// No Clone/Debug/serialization. A caller cannot retain a copied owner key.
pub struct Keyring<'a> {
    key: &'a RootKey,
    document: &'a Document,
    salt: [u8; 32],
}
impl<'a> Keyring<'a> {
    pub fn new(key: &'a RootKey, document: &'a Document) -> Result<Self> {
        if document.schema_version != 1
            || document.kid.is_empty()
            || document.kid.len() > 256
            || document.kid.contains('\0')
        {
            return Err(Failure::IncompatibleVault);
        }
        Ok(Self {
            key,
            document,
            salt: document.salt().map_err(|_| Failure::IncompatibleVault)?,
        })
    }
    pub(crate) fn matches(&self, document: &Document) -> bool {
        self.document.same_identity(document) && self.document.extra == document.extra
    }
    fn kid(&self) -> &str {
        &self.document.kid
    }
    fn open(&self, bytes: &[u8], id: Uuid) -> Result<Zeroizing<Vec<u8>>> {
        let text = std::str::from_utf8(bytes).map_err(|_| Failure::MalformedVariant)?;
        let sealed = Sealed::parse(text.into())?;
        let body = crypto::open_record(&sealed, self.key, &self.salt, self.kid(), id, false)?;
        if std::str::from_utf8(&body).is_err() || body.contains(&0) {
            return Err(Failure::MalformedVariant);
        }
        Ok(body)
    }
    fn verify(&self, body: &[u8], expected: &str) -> Result<()> {
        crypto::verify_hash(expected, body, self.key, &self.salt)
            .map_err(|_| Failure::ContentHashMismatch)
    }
}

/// Exact random-nonce C0 envelopes, suitable for freezing before primary apply.
/// Payload-bearing types deliberately have no Debug or logging conversion.
#[derive(Clone, PartialEq)]
pub struct Evidence {
    copies: BTreeMap<Uuid, Envelope>,
}
impl Evidence {
    pub fn copies(&self) -> &BTreeMap<Uuid, Envelope> {
        &self.copies
    }
    /// Existing journal snapshots win only after authenticating the exact
    /// carrier-derived C0. A valid C1 with matching provenance is insufficient.
    pub fn prepare(
        sources: &[Envelope],
        keys: &Keyring<'_>,
        frozen: &BTreeMap<Uuid, Envelope>,
    ) -> Result<Self> {
        let mut copies = BTreeMap::new();
        for source in sources {
            merge::validate(source)?;
            for variant in merge::secure_variants(source)? {
                if copies.contains_key(&variant.copy_id) {
                    return Err(Failure::IdentifierCollision);
                }
                let copy = if let Some(copy) = frozen.get(&variant.copy_id) {
                    validate_evidence(copy, &variant, keys)?;
                    // Authenticate the source as well: a keyed hash declaration
                    // beside malformed source ciphertext cannot authorize cleanup.
                    authenticate_variant(&variant, keys)?;
                    copy.clone()
                } else {
                    make_copy(&variant, keys)?
                };
                copies.insert(copy.id, copy);
            }
        }
        Ok(Self { copies })
    }
    pub fn validate(&self, sources: &[Envelope], keys: &Keyring<'_>) -> Result<()> {
        let mut expected = BTreeSet::new();
        for source in sources {
            merge::validate(source)?;
            for variant in merge::secure_variants(source)? {
                if !expected.insert(variant.copy_id) {
                    return Err(Failure::IdentifierCollision);
                }
                authenticate_variant(&variant, keys)?;
                validate_evidence(
                    self.copies
                        .get(&variant.copy_id)
                        .ok_or(Failure::MalformedVariant)?,
                    &variant,
                    keys,
                )?;
            }
        }
        if expected != self.copies.keys().copied().collect() {
            return Err(Failure::MalformedVariant);
        }
        Ok(())
    }
}

/// Verify every connected historical body without changing offers, CAS, original
/// nonces or acceptance. Each frame has its own C0, even when UUIDs repeat.
pub(crate) fn authenticate_generations(
    frames: &[crate::journal::RestorationGeneration],
    keys: &Keyring<'_>,
) -> Result<()> {
    for frame in frames {
        let mut originals = BTreeMap::new();
        for (source, copies) in &frame.sources {
            for copy in copies {
                let p = merge::provenance(copy).ok_or(Failure::MalformedVariant)?;
                if p.source_id != source.id || originals.insert(copy.id, copy.clone()).is_some() {
                    return Err(Failure::IdentifierCollision);
                }
            }
        }
        for e in frame
            .targets
            .values()
            .chain(frame.sources.iter().map(|(source, _)| source))
            .chain(originals.values())
        {
            merge::validate(e)?;
            if e.secure
                && e.deleted
                && e.extensions.get("vaultKID").and_then(|v| v.as_text().ok()) != Some(keys.kid())
            {
                return Err(Failure::IncompatibleVault);
            }
            if e.secure && !e.deleted {
                authenticate(e, keys, true)?;
            }
        }
        let sources: Vec<_> = frame
            .sources
            .iter()
            .map(|(source, _)| source.clone())
            .collect();
        let proof = Evidence::prepare(&sources, keys, &originals)?;
        // Recovery never manufactures a missing original or reseals an old one.
        if proof
            .copies()
            .iter()
            .any(|(id, copy)| originals.get(id) != Some(copy))
        {
            return Err(Failure::MalformedVariant);
        }
    }
    Ok(())
}
fn stamp(envelope: &Envelope, keys: &Keyring<'_>, require: bool) -> Result<()> {
    match envelope.extensions.get("vaultKID") {
        Some(value) if value.as_text().ok() == Some(keys.kid()) => Ok(()),
        None if !require => Ok(()),
        _ => Err(Failure::IncompatibleVault),
    }
}
/// Authentication is required even for an already stamped incoming C1.
pub fn authenticate(envelope: &Envelope, keys: &Keyring<'_>, require_stamp: bool) -> Result<()> {
    merge::validate(envelope)?;
    if envelope.deleted || !envelope.secure {
        return Err(Failure::IncompatibleVault);
    }
    stamp(envelope, keys, require_stamp)?;
    let fields = envelope.fields.as_ref().ok_or(Failure::MalformedVariant)?;
    let expected = envelope
        .extensions
        .get("vaultContentHash")
        .and_then(|v| v.as_text().ok())
        .ok_or(Failure::IncompatibleVault)?;
    let body = keys.open(&fields.content, envelope.id)?;
    keys.verify(&body, expected)
}
fn authenticate_variant(variant: &SecureVariant, keys: &Keyring<'_>) -> Result<Zeroizing<Vec<u8>>> {
    if variant
        .source_extensions
        .get("vaultKID")
        .and_then(|v| v.as_text().ok())
        != Some(keys.kid())
    {
        return Err(Failure::IncompatibleVault);
    }
    let expected = variant
        .source_extensions
        .get("vaultContentHash")
        .and_then(|v| v.as_text().ok())
        .ok_or(Failure::IncompatibleVault)?;
    let body = keys.open(&variant.fields.content, variant.source_id)?;
    keys.verify(&body, expected)?;
    Ok(body)
}
pub(crate) fn copy_display_name(variant: &SecureVariant) -> Result<String> {
    let source = &variant.fields;
    // The Swift secure materializer uses the supplied metadata name verbatim,
    // never a preview of decrypted content, including for whitespace-only names.
    let display = if source.name.is_empty() {
        "Untitled"
    } else {
        &source.name
    };
    let unix = source.updated_at + model::SWIFT_EPOCH;
    if !unix.is_finite() || unix.floor() < i64::MIN as f64 || unix.floor() >= i64::MAX as f64 {
        return Err(Failure::MalformedVariant);
    }
    let date = chrono::DateTime::from_timestamp(unix.floor() as i64, 0)
        .ok_or(Failure::MalformedVariant)?;
    Ok(format!(
        "{display} (conflict {} UTC)",
        date.format("%Y-%m-%d %H:%M")
    ))
}
fn copy_fields(variant: &SecureVariant) -> Result<Fields> {
    let source = &variant.fields;
    let mut fields = source.clone();
    fields.name = copy_display_name(variant)?;
    fields.keyword.clear();
    fields.tags = model::normalize_tags(source.tags.iter().cloned().chain(["conflict".into()]));
    fields.is_enabled = false;
    fields.is_pinned = false;
    Ok(fields)
}
fn make_copy(variant: &SecureVariant, keys: &Keyring<'_>) -> Result<Envelope> {
    let body = authenticate_variant(variant, keys)?;
    let sealed = crypto::seal_record(
        &body,
        keys.key,
        &keys.salt,
        keys.kid(),
        variant.copy_id,
        false,
    )?;
    let mut fields = copy_fields(variant)?;
    fields.content = Zeroizing::new(sealed.text().as_bytes().to_vec());
    let mut extensions = variant.source_extensions.clone();
    extensions.insert(
        merge::COPY_PROVENANCE.into(),
        merge::provenance_value(variant.source_id, &variant.fingerprint),
    );
    let copy = Envelope {
        id: variant.copy_id,
        hlc: variant.source_hlc.clone(),
        origin: variant.source_origin.clone(),
        secure: true,
        deleted: false,
        fields: Some(fields),
        extensions,
    };
    validate_evidence(&copy, variant, keys)?;
    Ok(copy)
}
pub fn validate_evidence(
    copy: &Envelope,
    variant: &SecureVariant,
    keys: &Keyring<'_>,
) -> Result<()> {
    authenticate(copy, keys, true)?;
    let fields = copy.fields.as_ref().ok_or(Failure::MalformedVariant)?;
    let expected = copy_fields(variant)?;
    if copy.id != variant.copy_id
        || !merge::valid_copy_identity(copy)
        || !merge::matching_provenance(copy, variant.source_id, &variant.fingerprint)
        || copy.hlc != variant.source_hlc
        || copy.origin != variant.source_origin
        || copy.extensions.len() != 3
        || copy.extensions.get("vaultContentHash")
            != variant.source_extensions.get("vaultContentHash")
        || fields.name != expected.name
        || !fields.keyword.is_empty()
        || model::normalize_tags(fields.tags.clone()) != expected.tags
        || fields.is_enabled
        || fields.is_pinned
        || fields.created_at.to_bits() != expected.created_at.to_bits()
        || fields.updated_at.to_bits() != expected.updated_at.to_bits()
    {
        return Err(Failure::MalformedVariant);
    }
    Ok(())
}

pub struct Materialized {
    pub records: Vec<Record>,
    pub materialized_ids: BTreeSet<Uuid>,
    pub evidence: Evidence,
}
/// Preserves authenticated same-provenance C1 occupants; always returns separate
/// exact C0 evidence. Any unrelated or duplicated UUID refuses the whole result.
pub fn materialize(
    source: &Envelope,
    keys: &Keyring<'_>,
    snippets: &[Snippet],
    records: &[Record],
    frozen: &BTreeMap<Uuid, Envelope>,
) -> Result<Materialized> {
    let evidence = Evidence::prepare(std::slice::from_ref(source), keys, frozen)?;
    let mut records = records.to_vec();
    let mut materialized_ids = BTreeSet::new();
    for (id, copy) in evidence.copies() {
        if snippets.iter().any(|s| s.id == *id) {
            return Err(Failure::IdentifierCollision);
        }
        let existing: Vec<_> = records.iter().filter(|r| r.metadata.id == *id).collect();
        if existing.len() > 1 {
            return Err(Failure::IdentifierCollision);
        }
        if let Some(record) = existing.first() {
            let p = merge::provenance(copy).ok_or(Failure::MalformedVariant)?;
            let extensions = crate::projection::primary_extensions(record)?;
            if extensions.get(merge::COPY_PROVENANCE) != copy.extensions.get(merge::COPY_PROVENANCE)
            {
                return Err(Failure::IdentifierCollision);
            }
            let mut echo = copy.clone();
            echo.fields = Some(Fields::from_snippet(&record.metadata.shell()));
            echo.fields.as_mut().expect("fields").content =
                Zeroizing::new(record.sealed.text().as_bytes().to_vec());
            echo.extensions
                .insert("vaultContentHash".into(), Value::text(&record.content_hash));
            if !merge::matching_provenance(&echo, p.source_id, &p.fingerprint) {
                return Err(Failure::IdentifierCollision);
            }
            authenticate(&echo, keys, true)?;
        } else {
            let record = crate::projection::vault_record(copy, None, keys.kid())?
                .ok_or(Failure::MalformedVariant)?;
            records.push(record);
            materialized_ids.insert(*id);
        }
    }
    Ok(Materialized {
        records,
        materialized_ids,
        evidence,
    })
}

#[cfg(test)]
#[path = "materializer_tests.rs"]
mod tests;
