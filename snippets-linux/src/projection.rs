//! Lossless wire knowledge around the frozen ordinary/vault primary formats.
//! No filesystem or key access. Incoming secure bodies remain sealed bytes.
use crate::{
    canonical::{self, Value},
    clock::Hlc,
    crypto::Sealed,
    merge,
    model::{self, Error, Result, Snippet},
    vault::{Document, Metadata, Record},
    wire::{Envelope, Fields},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::{DateTime, Utc};
use std::collections::BTreeMap;
use uuid::Uuid;
const INVALID: Error = Error("Synchronization stopped because primary record metadata is invalid.");
const INCOMPATIBLE: Error = Error("This encrypted record belongs to a different vault.");

fn text_equal(a: &str, b: &str) -> bool {
    use unicode_normalization::UnicodeNormalization;
    a == b || a.nfc().eq(b.nfc())
}
fn metadata_equal(fields: &Fields, primary: &Snippet) -> bool {
    text_equal(&fields.name, &primary.name)
        && text_equal(&model::keyword(&fields.keyword), &primary.keyword)
        && model::normalize_tags(fields.tags.clone()) == primary.tags
        && fields.is_enabled == primary.is_enabled
        && fields.is_pinned == primary.is_pinned
}
fn nonempty(s: &str) -> Option<&str> {
    (!s.is_empty()).then_some(s)
}
fn exact_plain(envelope: &Envelope, snippet: &Snippet) -> bool {
    !envelope.secure
        && !envelope.deleted
        && envelope.id == snippet.id
        && envelope.fields.as_ref().is_some_and(|f| {
            metadata_equal(f, snippet)
                && f.created_at == snippet.created_at
                && f.updated_at == snippet.updated_at
                && f.content.as_slice() == snippet.content.as_bytes()
        })
}
pub(crate) fn primary_extensions(record: &Record) -> Result<BTreeMap<String, Value>> {
    let mut result = BTreeMap::new();
    for (key, value) in &record.extra {
        let pair = if let Some(suffix) = key.strip_prefix(merge::OPAQUE_CARRIER_PREFIX) {
            let text = value.as_str().ok_or(INVALID)?;
            if text.len() > 4 * canonical::MAX_BYTES.div_ceil(3) {
                return Err(INVALID);
            }
            let bytes = STANDARD.decode(text).map_err(|_| INVALID)?;
            if STANDARD.encode(&bytes) != text {
                return Err(INVALID);
            }
            Some((
                format!("{}{suffix}", merge::CONFLICT_PREFIX),
                canonical::parse(&bytes)?,
            ))
        } else if key.starts_with(merge::CONFLICT_PREFIX) || key == merge::COPY_PROVENANCE {
            Some((key.clone(), from_json(value)?))
        } else {
            None
        };
        if let Some((key, value)) = pair {
            if result.get(&key).is_some_and(|old| old != &value) {
                return Err(INVALID);
            }
            result.insert(key, value);
        }
    }
    Ok(result)
}
fn exact_secure(envelope: &Envelope, record: &Record, kid: &str) -> Result<bool> {
    let fields_match = envelope.secure
        && !envelope.deleted
        && envelope.id == record.metadata.id
        && envelope.fields.as_ref().is_some_and(|f| {
            metadata_equal(f, &record.metadata.shell())
                && vault_date(f.created_at).map(|d| d.timestamp_millis()).ok()
                    == Some(record.metadata.created_at.timestamp_millis())
                && vault_date(f.updated_at).map(|d| d.timestamp_millis()).ok()
                    == Some(record.metadata.updated_at.timestamp_millis())
                && f.content.as_slice() == record.sealed.text().as_bytes()
        });
    let hash = envelope
        .extensions
        .get("vaultContentHash")
        .map(Value::as_text)
        .transpose()?;
    let arriving_kid = envelope
        .extensions
        .get("vaultKID")
        .map(Value::as_text)
        .transpose()?;
    let reserved: BTreeMap<_, _> = envelope
        .extensions
        .iter()
        .filter(|(k, _)| {
            k.starts_with(merge::CONFLICT_PREFIX) || k.as_str() == merge::COPY_PROVENANCE
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    Ok(fields_match
        && hash == nonempty(&record.content_hash)
        && arriving_kid == Some(kid)
        && reserved == primary_extensions(record)?)
}
fn knowledge(weaker: Option<&Envelope>, stronger: Option<&Envelope>) -> Result<Option<Envelope>> {
    let Some(mut result) = (match (weaker, stronger) {
        (Some(a), Some(b)) => Some(if a.hlc >= b.hlc { a.clone() } else { b.clone() }),
        (Some(e), None) | (None, Some(e)) => Some(e.clone()),
        (None, None) => None,
    }) else {
        return Ok(None);
    };
    for source in [weaker, stronger].into_iter().flatten() {
        if source.id != result.id {
            return Err(INVALID);
        }
        for (key, value) in &source.extensions {
            if result.extensions.get(key).is_some_and(|old| old != value)
                && (key.starts_with(merge::CONFLICT_PREFIX) || key == merge::COPY_PROVENANCE)
            {
                return Err(INVALID);
            }
            result.extensions.insert(key.clone(), value.clone());
        }
    }
    Ok(Some(result))
}
fn remove_routing(extensions: &mut BTreeMap<String, Value>) {
    extensions.remove("vaultKID");
    extensions.remove("vaultContentHash");
}
fn unix_millis(date: f64) -> Result<u64> {
    if !date.is_finite() {
        return Err(INVALID);
    }
    let milliseconds = (date * 1000.0).floor() + model::SWIFT_EPOCH * 1000.0;
    if milliseconds > 0xffff_ffff_ffff_u64 as f64 {
        return Err(INVALID);
    }
    Ok(milliseconds.max(0.0) as u64)
}
/// The complete live primary view; absent entries are not tombstones. The
/// journal's reconciliation layer must prove and preserve local deletions.
pub fn current(
    snippets: &[Snippet],
    vault: Option<&Document>,
    device: &str,
    projected: &BTreeMap<Uuid, Envelope>,
    agreed: &BTreeMap<Uuid, Envelope>,
) -> Result<BTreeMap<Uuid, Envelope>> {
    if !crate::wire::device(device) || device == "00000000" {
        return Err(INVALID);
    }
    let mut result = BTreeMap::new();
    for snippet in snippets {
        let p = projected.get(&snippet.id);
        let a = agreed.get(&snippet.id);
        let exact = knowledge(
            p.filter(|e| exact_plain(e, snippet)),
            a.filter(|e| exact_plain(e, snippet)),
        )?;
        let mut envelope = if let Some(e) = exact {
            e
        } else {
            let known = knowledge(p, a)?;
            Envelope {
                id: snippet.id,
                hlc: Hlc::projected(
                    unix_millis(snippet.updated_at)?,
                    None,
                    known.as_ref().map(|e| &e.hlc),
                    device,
                )?,
                origin: device.into(),
                secure: false,
                deleted: false,
                fields: Some(Fields::from_snippet(snippet)),
                extensions: known.map(|e| e.extensions).unwrap_or_default(),
            }
        };
        remove_routing(&mut envelope.extensions);
        merge::validate(&envelope).map_err(|_| INVALID)?;
        if envelope.extensions.contains_key(merge::COPY_PROVENANCE)
            && !merge::valid_copy_identity(&envelope)
        {
            return Err(INVALID);
        }
        if result.insert(snippet.id, envelope).is_some() {
            return Err(INVALID);
        }
    }
    if let Some(vault) = vault {
        for record in &vault.records {
            let id = record.metadata.id;
            let p = projected.get(&id);
            let a = agreed.get(&id);
            let ep = p
                .map(|e| exact_secure(e, record, &vault.kid))
                .transpose()?
                .unwrap_or(false);
            let ea = a
                .map(|e| exact_secure(e, record, &vault.kid))
                .transpose()?
                .unwrap_or(false);
            let envelope = if let Some(exact) = knowledge(p.filter(|_| ep), a.filter(|_| ea))? {
                exact
            } else {
                let known = knowledge(p, a)?;
                let mut extensions = known
                    .as_ref()
                    .map(|e| e.extensions.clone())
                    .unwrap_or_default();
                extensions.retain(|k, _| {
                    !k.starts_with(merge::CONFLICT_PREFIX) && k != merge::COPY_PROVENANCE
                });
                extensions.extend(primary_extensions(record)?);
                if record.content_hash.is_empty() {
                    extensions.remove("vaultContentHash");
                } else {
                    extensions.insert(
                        "vaultContentHash".into(),
                        Value::text(record.content_hash.clone()),
                    );
                }
                extensions.insert("vaultKID".into(), Value::text(vault.kid.clone()));
                let mut fields = Fields::from_snippet(&record.metadata.shell());
                fields.created_at = foundation_date(record.metadata.created_at);
                fields.updated_at = foundation_date(record.metadata.updated_at);
                fields.content = zeroize::Zeroizing::new(record.sealed.text().as_bytes().to_vec());
                Envelope {
                    id,
                    hlc: Hlc::projected(
                        record.metadata.updated_at.timestamp_millis().max(0) as u64,
                        record.hlc.as_ref(),
                        known.as_ref().map(|e| &e.hlc),
                        device,
                    )?,
                    origin: device.into(),
                    secure: true,
                    deleted: false,
                    fields: Some(fields),
                    extensions,
                }
            };
            merge::validate(&envelope).map_err(|_| INVALID)?;
            if envelope.extensions.contains_key(merge::COPY_PROVENANCE)
                && !merge::valid_copy_identity(&envelope)
            {
                return Err(INVALID);
            }
            if result.insert(id, envelope).is_some() {
                return Err(INVALID);
            }
        }
    }
    Ok(result)
}
/// Exact primary echo can pass the sync boundary while locked. Other secure
/// conflict copies/unstamped bodies still need the vault owner's key validation.
pub fn exact_secure_echo(envelope: &Envelope, record: &Record, kid: &str) -> Result<bool> {
    Ok(exact_secure(envelope, record, kid)? && record.hlc.as_ref() == Some(&envelope.hlc))
}
pub fn vault_record(
    envelope: &Envelope,
    existing: Option<&Record>,
    local_kid: &str,
) -> Result<Option<Record>> {
    if !envelope.secure {
        return Ok(None);
    }
    merge::validate(envelope).map_err(|_| INVALID)?;
    if envelope.deleted {
        return Ok(None);
    }
    let fields = envelope.fields.as_ref().ok_or(INVALID)?;
    let sealed = Sealed::parse(
        std::str::from_utf8(&fields.content)
            .map_err(|_| INVALID)?
            .into(),
    )?;
    if envelope
        .extensions
        .get("vaultKID")
        .map(Value::as_text)
        .transpose()?
        .is_some_and(|kid| kid != local_kid)
    {
        return Err(INCOMPATIBLE);
    }
    if merge::secure_variants(envelope)
        .map_err(|_| INVALID)?
        .iter()
        .any(|v| {
            v.source_extensions
                .get("vaultKID")
                .and_then(|v| v.as_text().ok())
                != Some(local_kid)
        })
    {
        return Err(INCOMPATIBLE);
    }
    let carried_hash = envelope
        .extensions
        .get("vaultContentHash")
        .map(Value::as_text)
        .transpose()?;
    let preserved_hash = existing
        .filter(|r| r.sealed == sealed)
        .and_then(|r| nonempty(&r.content_hash));
    let metadata = Metadata {
        id: envelope.id,
        name: fields.name.clone(),
        keyword: fields.keyword.clone(),
        tags: fields.tags.clone(),
        is_enabled: fields.is_enabled,
        is_pinned: fields.is_pinned,
        created_at: vault_date(fields.created_at)?,
        updated_at: vault_date(fields.updated_at)?,
    }
    .validate()?;
    let mut extra = existing.map(|r| r.extra.clone()).unwrap_or_default();
    extra.retain(|k, _| {
        !k.starts_with(merge::CONFLICT_PREFIX)
            && !k.starts_with(merge::OPAQUE_CARRIER_PREFIX)
            && k != merge::COPY_PROVENANCE
    });
    for (key, value) in &envelope.extensions {
        if let Some(suffix) = key.strip_prefix(merge::CONFLICT_PREFIX) {
            extra.insert(
                format!("{}{suffix}", merge::OPAQUE_CARRIER_PREFIX),
                serde_json::Value::String(STANDARD.encode(value.encode()?)),
            );
        } else if key == merge::COPY_PROVENANCE {
            if !merge::valid_copy_identity(envelope) {
                return Err(INVALID);
            }
            // The exact marker schema has integers only; no lossy generic JSON
            // conversion is used for an opaque conflict snapshot.
            extra.insert(
                key.clone(),
                serde_json::from_slice(&value.encode()?).map_err(|_| INVALID)?,
            );
        }
    }
    Ok(Some(Record {
        metadata,
        sealed,
        content_hash: carried_hash.or(preserved_hash).unwrap_or("").into(),
        hlc: Some(envelope.hlc.clone()),
        extra,
    }))
}
pub(crate) fn vault_date(date: f64) -> Result<DateTime<Utc>> {
    let millis = (date * 1000.0).floor();
    if !millis.is_finite() || millis < i64::MIN as f64 || millis >= i64::MAX as f64 {
        return Err(INVALID);
    }
    let unix = (millis as i64)
        .checked_add(model::SWIFT_EPOCH as i64 * 1000)
        .ok_or(INVALID)?;
    DateTime::from_timestamp_millis(unix).ok_or(INVALID)
}
fn foundation_date(date: DateTime<Utc>) -> f64 {
    (date.timestamp() - model::SWIFT_EPOCH as i64) as f64
        + date.timestamp_subsec_millis() as f64 / 1000.0
}
fn from_json(value: &serde_json::Value) -> Result<Value> {
    // Legacy passthrough values may contain binary64 dates. Preserve their
    // integer/float distinction rather than round-trip them through strings.
    Ok(match value {
        serde_json::Value::Null => Value::Null,
        serde_json::Value::Bool(v) => Value::Bool(*v),
        serde_json::Value::Number(v) => {
            if v.is_f64() {
                Value::Float(v.as_f64().ok_or(INVALID)?)
            } else {
                Value::Int(v.as_i64().ok_or(INVALID)?)
            }
        }
        serde_json::Value::String(v) => Value::text(v.clone()),
        serde_json::Value::Array(v) => {
            Value::Array(v.iter().map(from_json).collect::<Result<_>>()?)
        }
        serde_json::Value::Object(v) => Value::Object(
            v.iter()
                .map(|(k, v)| Ok((k.clone(), from_json(v)?)))
                .collect::<Result<_>>()?,
        ),
    })
}

#[cfg(test)]
#[path = "projection_tests.rs"]
mod tests;
