//! Pure three-way snippets-wire-v1 merge, including preservation of losing bodies.
//! Mirrors Core/SyncMerge.swift. Nothing here opens a vault or mutates primary
//! storage: a caller must persist the dependency journal before applying outcomes.
use crate::{
    canonical::Value,
    clock::Hlc,
    model::{self, Error},
    wire::{self, Envelope, Fields},
};
use std::collections::{BTreeMap, BTreeSet};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const CONFLICT_PREFIX: &str = "contentConflict.";
pub const CONFLICT_V1_PREFIX: &str = "contentConflict.v1.";
pub const OPAQUE_CARRIER_PREFIX: &str = "contentConflictOpaque.v1.";
pub const COPY_PROVENANCE: &str = "conflictCopy.v1";
pub const MAX_VARIANTS: usize = 128;
pub const MAX_VARIANT_BYTES: usize = 512 * 1024;
const VAULT_KEYS: [&str; 2] = ["vaultContentHash", "vaultKID"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    MalformedConflict,
    UnresolvedConflictDeletion,
    MismatchedIdentity,
}
impl From<Error> for Failure {
    fn from(_: Error) -> Self {
        Self::MalformedConflict
    }
}
impl From<Failure> for Error {
    fn from(value: Failure) -> Self {
        match value {
            Failure::MalformedConflict => Error(
                "Synchronization stopped because a content conflict could not be preserved safely.",
            ),
            Failure::UnresolvedConflictDeletion => {
                Error("Preserve the unresolved content conflicts before deleting this record.")
            }
            Failure::MismatchedIdentity => {
                Error("Synchronization stopped because the records have different identities.")
            }
        }
    }
}
pub type Result<T> = std::result::Result<T, Failure>;

// Payload-bearing types intentionally have no Debug or logging conversion.
#[derive(Clone, PartialEq)]
pub struct Outcome {
    pub survivor: Option<Envelope>,
    pub conflict_copies: Vec<Envelope>,
}
impl Outcome {
    fn one(envelope: Option<&Envelope>) -> Self {
        Self {
            survivor: envelope.cloned(),
            conflict_copies: Vec::new(),
        }
    }
}
#[derive(Clone, PartialEq)]
pub struct SecureVariant {
    pub extension_key: String,
    pub fingerprint: String,
    pub copy_id: Uuid,
    pub source_id: Uuid,
    pub source_hlc: Hlc,
    pub source_origin: String,
    pub fields: Fields,
    pub source_extensions: BTreeMap<String, Value>,
}
#[derive(Clone, PartialEq, Eq)]
pub struct Provenance {
    pub source_id: Uuid,
    pub fingerprint: String,
}

pub fn has_unresolved(envelope: Option<&Envelope>) -> bool {
    envelope.is_some_and(|e| e.extensions.keys().any(|k| k.starts_with(CONFLICT_PREFIX)))
}
pub fn has_unknown_version(envelope: &Envelope) -> bool {
    envelope
        .extensions
        .keys()
        .any(|k| k.starts_with(CONFLICT_PREFIX) && !k.starts_with(CONFLICT_V1_PREFIX))
}
fn refuse_deletion(envelope: Option<&Envelope>) -> Result<()> {
    if has_unresolved(envelope) {
        Err(Failure::UnresolvedConflictDeletion)
    } else {
        Ok(())
    }
}
fn canonical_id(value: &Value) -> Result<Uuid> {
    let text = value.as_text()?;
    let id = Uuid::parse_str(text).map_err(|_| Failure::MalformedConflict)?;
    if text != id.to_string() {
        return Err(Failure::MalformedConflict);
    }
    Ok(id)
}
fn exact_keys(values: &BTreeMap<String, Value>, keys: &[&str]) -> Result<()> {
    if values.len() == keys.len() && keys.iter().all(|k| values.contains_key(*k)) {
        Ok(())
    } else {
        Err(Failure::MalformedConflict)
    }
}
fn member<'a>(values: &'a BTreeMap<String, Value>, key: &str) -> Result<&'a Value> {
    values.get(key).ok_or(Failure::MalformedConflict)
}
pub fn copy_id(source_id: Uuid, fingerprint: &str) -> Uuid {
    Uuid::new_v5(
        &source_id,
        format!("sync-content-conflict-v1|{fingerprint}").as_bytes(),
    )
}
pub fn provenance_value(source_id: Uuid, fingerprint: &str) -> Value {
    Value::Object(BTreeMap::from([
        ("version".into(), Value::Int(1)),
        ("sourceID".into(), Value::text(source_id.to_string())),
        ("fingerprint".into(), Value::text(fingerprint)),
    ]))
}
pub fn provenance(envelope: &Envelope) -> Option<Provenance> {
    let parse = || -> Result<Provenance> {
        let values = envelope
            .extensions
            .get(COPY_PROVENANCE)
            .ok_or(Failure::MalformedConflict)?
            .as_object()?;
        exact_keys(values, &["version", "sourceID", "fingerprint"])?;
        if member(values, "version")?.as_int()? != 1 {
            return Err(Failure::MalformedConflict);
        }
        let fingerprint = member(values, "fingerprint")?.as_text()?;
        if !wire::is_hash(fingerprint) {
            return Err(Failure::MalformedConflict);
        }
        Ok(Provenance {
            source_id: canonical_id(member(values, "sourceID")?)?,
            fingerprint: fingerprint.into(),
        })
    };
    parse().ok()
}
pub fn valid_copy_identity(envelope: &Envelope) -> bool {
    provenance(envelope).is_some_and(|p| envelope.id == copy_id(p.source_id, &p.fingerprint))
}
pub fn matching_provenance(envelope: &Envelope, source_id: Uuid, fingerprint: &str) -> bool {
    envelope.extensions.get(COPY_PROVENANCE) == Some(&provenance_value(source_id, fingerprint))
}
pub fn matching_plain_copy(envelope: &Envelope, candidate: &Envelope) -> bool {
    envelope.id == candidate.id
        && candidate
            .extensions
            .get(COPY_PROVENANCE)
            .is_some_and(|v| envelope.extensions.get(COPY_PROVENANCE) == Some(v))
}

pub fn secure_variants(envelope: &Envelope) -> Result<Vec<SecureVariant>> {
    if envelope.deleted && has_unresolved(Some(envelope)) {
        return Err(Failure::MalformedConflict);
    }
    let mut variants = Vec::new();
    for (key, raw) in &envelope.extensions {
        let Some(fingerprint) = key.strip_prefix(CONFLICT_V1_PREFIX) else {
            continue;
        };
        if !wire::is_hash(fingerprint) {
            return Err(Failure::MalformedConflict);
        }
        let values = raw.as_object()?;
        exact_keys(
            values,
            &[
                "version",
                "copyID",
                "sourceID",
                "sourceHLC",
                "sourceOrigin",
                "secure",
                "fields",
                "x",
            ],
        )?;
        if member(values, "version")?.as_int()? != 1 || !member(values, "secure")?.as_bool()? {
            return Err(Failure::MalformedConflict);
        }
        let source_id = canonical_id(member(values, "sourceID")?)?;
        let copy_id = canonical_id(member(values, "copyID")?)?;
        let source_hlc = Hlc::parse(member(values, "sourceHLC")?.as_text()?)?;
        let source_origin = member(values, "sourceOrigin")?.as_text()?;
        let source_extensions = member(values, "x")?.as_object()?;
        exact_keys(source_extensions, &VAULT_KEYS)?;
        if source_id != envelope.id || !wire::device(source_origin) {
            return Err(Failure::MalformedConflict);
        }
        for key in VAULT_KEYS {
            if member(source_extensions, key)?.as_text()?.len() > 256 {
                return Err(Failure::MalformedConflict);
            }
        }
        let fields = Fields::parse(member(values, "fields")?)?;
        let mut snapshot = values.clone();
        snapshot.remove("copyID");
        if wire::sha256(&Value::Object(snapshot).encode()?) != fingerprint
            || copy_id != self::copy_id(source_id, fingerprint)
        {
            return Err(Failure::MalformedConflict);
        }
        variants.push(SecureVariant {
            extension_key: key.clone(),
            fingerprint: fingerprint.into(),
            copy_id,
            source_id,
            source_hlc,
            source_origin: source_origin.into(),
            fields,
            source_extensions: source_extensions.clone(),
        });
    }
    Ok(variants)
}
/// Every input and generated output is checked before any caller may apply it.
/// Unknown versions remain opaque, bounded and deletion-blocking.
pub fn validate(envelope: &Envelope) -> Result<()> {
    envelope.encode()?;
    if envelope.deleted && has_unresolved(Some(envelope)) {
        return Err(Failure::MalformedConflict);
    }
    let mut count = 0;
    let mut aggregate = 0usize;
    for (key, value) in &envelope.extensions {
        if !key.starts_with(CONFLICT_PREFIX) {
            continue;
        }
        count += 1;
        if count > MAX_VARIANTS {
            return Err(Failure::MalformedConflict);
        }
        let parts: Vec<_> = key.split('.').collect();
        if parts.len() != 3
            || parts[0] != "contentConflict"
            || !parts[1].starts_with('v')
            || !(1..=3).contains(&parts[1][1..].len())
            || !parts[1][1..].bytes().all(|b| b.is_ascii_digit())
            || !wire::is_hash(parts[2])
        {
            return Err(Failure::MalformedConflict);
        }
        let length = key.len() + value.encode()?.len();
        if length > MAX_VARIANT_BYTES.saturating_sub(aggregate) {
            return Err(Failure::MalformedConflict);
        }
        aggregate += length;
    }
    secure_variants(envelope)?;
    Ok(())
}
/// A journal uses exact expected values as its compare-and-swap proof. This
/// never acknowledges unknown versions or a carrier changed since review.
pub fn resolve(envelope: &Envelope, expected: &BTreeMap<String, Value>) -> Option<Envelope> {
    if envelope.deleted
        || !expected.iter().all(|(key, value)| {
            key.starts_with(CONFLICT_V1_PREFIX) && envelope.extensions.get(key) == Some(value)
        })
    {
        return None;
    }
    let mut resolved = envelope.clone();
    for key in expected.keys() {
        resolved.extensions.remove(key);
    }
    Some(resolved)
}

fn snapshot(source: &Envelope) -> Result<BTreeMap<String, Value>> {
    let fields = source
        .fields
        .as_ref()
        .filter(|_| !source.deleted)
        .ok_or(Failure::MalformedConflict)?;
    // This snapshot can also be mirrored into plaintext vault metadata. Do not
    // widen that boundary by copying an arbitrary future wire extension.
    let approved = source
        .extensions
        .iter()
        .filter(|(k, _)| VAULT_KEYS.contains(&k.as_str()))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    Ok(BTreeMap::from([
        ("version".into(), Value::Int(1)),
        ("sourceID".into(), Value::text(source.id.to_string())),
        ("sourceHLC".into(), Value::text(source.hlc.text())),
        ("sourceOrigin".into(), Value::text(source.origin.clone())),
        ("secure".into(), Value::Bool(source.secure)),
        ("fields".into(), fields.value()?),
        ("x".into(), Value::Object(approved)),
    ]))
}
pub(crate) fn secure_variant(source: &Envelope) -> Result<(String, Value)> {
    if !source.secure {
        return Err(Failure::MalformedConflict);
    }
    let mut snapshot = snapshot(source)?;
    let fingerprint = wire::sha256(&Value::Object(snapshot.clone()).encode()?);
    snapshot.insert(
        "copyID".into(),
        Value::text(copy_id(source.id, &fingerprint).to_string()),
    );
    Ok((
        format!("{CONFLICT_V1_PREFIX}{fingerprint}"),
        Value::Object(snapshot),
    ))
}
pub(crate) fn plain_copy(source: &Envelope) -> Result<Envelope> {
    if source.secure || source.deleted {
        return Err(Failure::MalformedConflict);
    }
    let fingerprint = wire::sha256(&Value::Object(snapshot(source)?).encode()?);
    let mut fields = source.fields.clone().ok_or(Failure::MalformedConflict)?;
    fields.name = conflict_name(&fields)?;
    fields.keyword.clear();
    fields.is_enabled = false;
    fields.is_pinned = false;
    fields.tags = model::normalize_tags(fields.tags.into_iter().chain(["conflict".into()]));
    let mut extensions: BTreeMap<_, _> = source
        .extensions
        .iter()
        .filter(|(key, _)| !key.starts_with(CONFLICT_PREFIX) && !VAULT_KEYS.contains(&key.as_str()))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    extensions.insert(
        COPY_PROVENANCE.into(),
        provenance_value(source.id, &fingerprint),
    );
    Ok(Envelope {
        id: copy_id(source.id, &fingerprint),
        hlc: source.hlc.clone(),
        origin: source.origin.clone(),
        secure: false,
        deleted: false,
        fields: Some(fields),
        extensions,
    })
}
fn conflict_name(fields: &Fields) -> Result<String> {
    let name = fields.name.trim();
    let display = if name.is_empty() {
        let body = std::str::from_utf8(&fields.content).map_err(|_| Failure::MalformedConflict)?;
        let line = body
            .split([
                '\n', '\r', '\u{000b}', '\u{000c}', '\u{0085}', '\u{2028}', '\u{2029}',
            ])
            .map(str::trim)
            .find(|line| !line.is_empty())
            .unwrap_or("Untitled Snippet");
        let mut clusters = line.graphemes(true);
        let mut display: String = clusters.by_ref().take(50).collect();
        if clusters.next().is_some() {
            display.push('…');
        }
        display
    } else {
        name.into()
    };
    let unix = fields.updated_at + model::SWIFT_EPOCH;
    if !unix.is_finite() || unix.floor() < i64::MIN as f64 || unix.floor() >= i64::MAX as f64 {
        return Err(Failure::MalformedConflict);
    }
    let date = chrono::DateTime::from_timestamp(unix.floor() as i64, 0)
        .ok_or(Failure::MalformedConflict)?;
    Ok(format!(
        "{display} (conflict {} UTC)",
        date.format("%Y-%m-%d %H:%M")
    ))
}

fn rank(envelope: &Envelope) -> Result<zeroize::Zeroizing<Vec<u8>>> {
    let mut ranked = envelope.clone();
    ranked
        .extensions
        .retain(|k, _| !k.starts_with(CONFLICT_PREFIX));
    Ok(ranked.encode()?)
}
fn local_wins(local: &Envelope, remote: &Envelope) -> Result<bool> {
    if local == remote {
        return Ok(true);
    }
    if local.hlc != remote.hlc {
        return Ok(local.hlc > remote.hlc);
    }
    Ok(rank(local)?.as_slice() < rank(remote)?.as_slice())
}
fn changed(envelope: &Envelope, base: Option<&Envelope>) -> Result<bool> {
    match base {
        None => Ok(true),
        Some(base) => Ok(envelope.hash()? != base.hash()?),
    }
}
fn content_key(envelope: &Envelope, fields: &Fields) -> String {
    if envelope.secure {
        if let Some(hash) = envelope
            .extensions
            .get(VAULT_KEYS[0])
            .and_then(|v| v.as_text().ok())
        {
            let vault = envelope
                .extensions
                .get(VAULT_KEYS[1])
                .and_then(|v| v.as_text().ok())
                .unwrap_or("legacy");
            return format!("secure:{vault}:{hash}");
        }
        format!("secure:legacy:{}", wire::sha256(&fields.content))
    } else {
        format!("plain:{}", wire::sha256(&fields.content))
    }
}
fn union_extensions(
    local: &Envelope,
    remote: &Envelope,
    local_wins: bool,
) -> BTreeMap<String, Value> {
    let (preferred, other) = if local_wins {
        (local, remote)
    } else {
        (remote, local)
    };
    let mut union = other.extensions.clone();
    union.extend(preferred.extensions.clone());
    union
}
fn select_vault_extensions(
    extensions: &mut BTreeMap<String, Value>,
    selected: &Envelope,
    legacy_fallback: Option<&Envelope>,
) {
    for key in VAULT_KEYS {
        let value = selected
            .secure
            .then(|| {
                selected
                    .extensions
                    .get(key)
                    .or_else(|| legacy_fallback.and_then(|other| other.extensions.get(key)))
            })
            .flatten();
        if let Some(value) = value {
            extensions.insert(key.into(), value.clone());
        } else {
            extensions.remove(key);
        }
    }
}
fn scalar<T: PartialEq + Clone>(base: Option<&T>, local: &T, remote: &T, local_wins: bool) -> T {
    if local == remote || base == Some(remote) {
        local.clone()
    } else if base == Some(local) || !local_wins {
        remote.clone()
    } else {
        local.clone()
    }
}
// Swift metadata String equality uses canonical equivalence. Body and x values
// instead compare exact bytes; never normalize authenticated wire content.
fn text_equal(a: &str, b: &str) -> bool {
    a == b || a.nfc().eq(b.nfc())
}
fn text_scalar(base: Option<&str>, local: &str, remote: &str, local_wins: bool) -> String {
    if text_equal(local, remote) || base.is_some_and(|b| text_equal(b, remote)) {
        local.into()
    } else if base.is_some_and(|b| text_equal(b, local)) || !local_wins {
        remote.into()
    } else {
        local.into()
    }
}
fn fields_equal(a: &Fields, b: &Fields) -> bool {
    text_equal(&a.name, &b.name)
        && text_equal(&a.keyword, &b.keyword)
        && a.content == b.content
        && a.tags.len() == b.tags.len()
        && a.tags.iter().zip(&b.tags).all(|(a, b)| text_equal(a, b))
        && a.is_enabled == b.is_enabled
        && a.is_pinned == b.is_pinned
        && a.created_at == b.created_at
        && a.updated_at == b.updated_at
}
fn tags(
    base: Option<&[String]>,
    local: &[String],
    remote: &[String],
    local_wins: bool,
) -> Vec<String> {
    let keys = |values: &[String]| {
        values
            .iter()
            .map(|s| model::folded(s))
            .collect::<BTreeSet<_>>()
    };
    let (preferred, other) = if local_wins {
        (local, remote)
    } else {
        (remote, local)
    };
    let Some(base) = base else {
        let preferred_keys = keys(preferred);
        return model::normalize_tags(
            preferred
                .iter()
                .chain(
                    other
                        .iter()
                        .filter(|s| !preferred_keys.contains(&model::folded(s))),
                )
                .cloned(),
        );
    };
    let base_keys = keys(base);
    let local_keys = keys(local);
    let remote_keys = keys(remote);
    let spelling = |key: &str| {
        preferred
            .iter()
            .chain(other)
            .find(|s| model::folded(s) == key)
            .cloned()
    };
    let mut ordered: Vec<_> = base
        .iter()
        .filter_map(|s| {
            let key = model::folded(s);
            (local_keys.contains(&key) && remote_keys.contains(&key))
                .then(|| spelling(&key).unwrap_or_else(|| s.clone()))
        })
        .collect();
    let added = local_keys
        .union(&remote_keys)
        .filter(|key| !base_keys.contains(*key));
    for key in added {
        if let Some(value) = spelling(key) {
            ordered.push(value);
        }
    }
    model::normalize_tags(ordered)
}

pub fn merge(
    base: Option<&Envelope>,
    local: Option<&Envelope>,
    remote: Option<&Envelope>,
) -> Result<Outcome> {
    let mut id = None;
    for envelope in [base, local, remote].into_iter().flatten() {
        if id.is_some_and(|id| id != envelope.id) {
            return Err(Failure::MismatchedIdentity);
        }
        id = Some(envelope.id);
        validate(envelope)?;
    }
    let (local, remote) = match (local, remote) {
        (None, None) => return Ok(Outcome::one(None)),
        (None, Some(remote)) => return Ok(Outcome::one(Some(remote))),
        (Some(local), None) => return Ok(Outcome::one(Some(local))),
        (Some(local), Some(remote)) => (local, remote),
    };
    if local.deleted && remote.deleted {
        refuse_deletion(base)?;
        return Ok(Outcome::one(Some(if local_wins(local, remote)? {
            local
        } else {
            remote
        })));
    }
    if local.deleted || remote.deleted {
        let (deleted, live) = if local.deleted {
            (local, remote)
        } else {
            (remote, local)
        };
        let survivor = if changed(live, base)? { live } else { deleted };
        if survivor.deleted {
            refuse_deletion(base.or(Some(live)))?;
        }
        return Ok(Outcome::one(Some(survivor)));
    }
    let lf = local.fields.as_ref().ok_or(Failure::MalformedConflict)?;
    let rf = remote.fields.as_ref().ok_or(Failure::MalformedConflict)?;
    let local_wins = local_wins(local, remote)?;
    let (winner, other) = if local_wins {
        (local, remote)
    } else {
        (remote, local)
    };
    let mut extensions = union_extensions(local, remote, local_wins);
    if fields_equal(lf, rf) && local.secure == remote.secure {
        select_vault_extensions(&mut extensions, winner, Some(other));
        let mut survivor = winner.clone();
        survivor.extensions = extensions;
        validate(&survivor)?;
        return Ok(Outcome::one(Some(&survivor)));
    }
    let bf = base.and_then(|b| b.fields.as_ref());
    let local_key = content_key(local, lf);
    let remote_key = content_key(remote, rf);
    let base_key = base.and_then(|b| b.fields.as_ref().map(|f| content_key(b, f)));
    let mut conflict_copies = Vec::new();
    let selected = if local_key == remote_key {
        winner
    } else if base_key.as_ref() == Some(&remote_key) {
        local
    } else if base_key.as_ref() == Some(&local_key) {
        remote
    } else {
        if other.secure {
            let (key, value) = secure_variant(other)?;
            extensions.insert(key, value);
        } else {
            conflict_copies.push(plain_copy(other)?);
        }
        winner
    };
    let fields = Fields {
        name: text_scalar(bf.map(|f| f.name.as_str()), &lf.name, &rf.name, local_wins),
        keyword: text_scalar(
            bf.map(|f| f.keyword.as_str()),
            &lf.keyword,
            &rf.keyword,
            local_wins,
        ),
        content: selected
            .fields
            .as_ref()
            .ok_or(Failure::MalformedConflict)?
            .content
            .clone(),
        tags: tags(
            bf.map(|f| f.tags.as_slice()),
            &lf.tags,
            &rf.tags,
            local_wins,
        ),
        is_enabled: scalar(
            bf.map(|f| &f.is_enabled),
            &lf.is_enabled,
            &rf.is_enabled,
            local_wins,
        ),
        is_pinned: scalar(
            bf.map(|f| &f.is_pinned),
            &lf.is_pinned,
            &rf.is_pinned,
            local_wins,
        ),
        created_at: lf.created_at.min(rf.created_at),
        updated_at: lf.updated_at.max(rf.updated_at),
    };
    select_vault_extensions(&mut extensions, selected, None);
    let survivor = Envelope {
        id: local.id,
        hlc: local.hlc.clone().max(remote.hlc.clone()),
        origin: winner.origin.clone(),
        secure: selected.secure,
        deleted: false,
        fields: Some(fields),
        extensions,
    };
    validate(&survivor)?;
    for copy in &conflict_copies {
        validate(copy)?;
    }
    conflict_copies.sort_by_key(|c| c.id);
    Ok(Outcome {
        survivor: Some(survivor),
        conflict_copies,
    })
}

/// The fingerprint is private recovery state, never a diagnostic field.
#[derive(Clone, PartialEq, Eq)]
pub struct DeletionFacts {
    pub live_count: usize,
    pub requested_deletions: usize,
    pub batch_fingerprint: String,
}
pub fn allowed_deletions(live_count: usize) -> usize {
    // ceil(n / 5), expressed without overflow at usize::MAX.
    5.max(live_count / 5 + usize::from(!live_count.is_multiple_of(5)))
}
pub fn deletion_fingerprint(ids: &BTreeSet<Uuid>) -> String {
    let material = ids
        .iter()
        .map(|id| id.to_string().to_uppercase())
        .collect::<Vec<_>>()
        .join("\n");
    wire::sha256(material.as_bytes())
}
pub fn deletion_facts(live: &BTreeSet<Uuid>, resulting: &BTreeSet<Uuid>) -> Option<DeletionFacts> {
    let deleting = live.difference(resulting).copied().collect::<BTreeSet<_>>();
    (!deleting.is_empty()).then(|| DeletionFacts {
        live_count: live.len(),
        requested_deletions: deleting.len(),
        batch_fingerprint: deletion_fingerprint(&deleting),
    })
}
pub fn deletion_review(live: &BTreeSet<Uuid>, resulting: &BTreeSet<Uuid>) -> Option<DeletionFacts> {
    deletion_facts(live, resulting)
        .filter(|f| f.requested_deletions > allowed_deletions(live.len()))
}

#[cfg(test)]
#[path = "merge_tests.rs"]
mod tests;
