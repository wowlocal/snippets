//! Journal-first primary apply/redo for the ordinary and sealed vault files.
//! Scope is authenticated before reading primary. Pending markers fence every
//! normal app/CLI writer until the encrypted transaction has been recovered.
use crate::{
    crypto::{self, RootKey},
    journal::{self, Checkpoint, Journal, Scope},
    materializer::{self, Evidence, Keyring},
    merge::{self, Outcome},
    model::{self, Error, Library, Snippet},
    projection,
    vault::Document,
    wire::Envelope,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::Path,
};
use uuid::Uuid;
use zeroize::Zeroizing;
#[path = "primary_frozen.rs"]
pub(crate) mod frozen;
#[path = "primary_groups.rs"]
mod groups;
const MARKER: &str = "primary.pending";
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    InvalidState,
    StalePrimary,
    RecoveryRequired,
    IncompatibleVault,
    VaultLocked,
    ReservedCollision,
    Storage,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<Error> for Failure {
    fn from(_: Error) -> Self {
        Self::InvalidState
    }
}
impl From<merge::Failure> for Failure {
    fn from(_: merge::Failure) -> Self {
        Self::InvalidState
    }
}
impl From<journal::Failure> for Failure {
    fn from(_: journal::Failure) -> Self {
        Self::RecoveryRequired
    }
}
impl From<materializer::Failure> for Failure {
    fn from(value: materializer::Failure) -> Self {
        match value {
            materializer::Failure::IncompatibleVault => Self::IncompatibleVault,
            materializer::Failure::IdentifierCollision => Self::ReservedCollision,
            _ => Self::InvalidState,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Readiness {
    Ready,
    RecoveryRequired,
}
/// Inspect only the recovery fence, never either primary file. A marker does
/// not authorize recovery: the encrypted checkpoint and its owner still must.
pub(crate) fn readiness(root: &Path) -> model::Result<Readiness> {
    if crate::backup::import::pending(root)? {
        return Ok(Readiness::RecoveryRequired);
    }
    sync_readiness(root)
}
/// Backup redo owns its separate fence; it must still refuse any Cloud apply.
pub(crate) fn sync_readiness(root: &Path) -> model::Result<Readiness> {
    let directory = root.join("Sync");
    match fs::symlink_metadata(&directory) {
        Ok(m) if m.is_dir() && !m.file_type().is_symlink() => (),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Readiness::Ready),
        _ => {
            return Err(Error(
                "Synchronization storage is unavailable. Recover it before editing.",
            ));
        }
    }
    marker(root)
        .map(|marker| {
            if marker.is_some() {
                Readiness::RecoveryRequired
            } else {
                Readiness::Ready
            }
        })
        .map_err(|_| {
            Error("Synchronization recovery storage is invalid. No library files were read.")
        })
}
pub(crate) fn require_ready(root: &Path) -> model::Result<()> {
    crate::backup::import::require_clear(root)?;
    match readiness(root)? {
        Readiness::Ready => Ok(()),
        Readiness::RecoveryRequired => Err(Error(
            "An interrupted synchronization update needs recovery before reading or editing.",
        )),
    }
}
#[derive(Clone, PartialEq)]
pub(crate) struct Intent {
    pub nonce: [u8; 16],
    pub before_plain: Option<Zeroizing<Vec<u8>>>,
    pub before_vault: Option<Zeroizing<Vec<u8>>>,
    pub after_plain: Option<Zeroizing<Vec<u8>>>,
    pub after_vault: Option<Zeroizing<Vec<u8>>>,
}
impl Intent {
    pub(crate) fn validate(&self) -> journal::Result<()> {
        for bytes in [&self.before_plain, &self.after_plain]
            .into_iter()
            .flatten()
        {
            model::decode_library(bytes, false).map_err(|_| journal::Failure::InvalidState)?;
        }
        for bytes in [&self.before_vault, &self.after_vault]
            .into_iter()
            .flatten()
        {
            Document::decode(bytes).map_err(|_| journal::Failure::InvalidState)?;
        }
        // Applying records can empty a file but cannot remove a vault document,
        // wraps or an existing ordinary library. Absence is preserved exactly.
        if self.before_plain.is_some() && self.after_plain.is_none()
            || self.before_vault.is_some() && self.after_vault.is_none()
        {
            return Err(journal::Failure::InvalidState);
        }
        if let Some(before) = &self.before_vault {
            let mut before = Document::decode(before)?;
            let mut after = Document::decode(
                self.after_vault
                    .as_ref()
                    .ok_or(journal::Failure::InvalidState)?,
            )?;
            before.records.clear();
            after.records.clear();
            if before != after {
                return Err(journal::Failure::InvalidState);
            }
        } else if self.after_vault.is_some() {
            // A remote-record apply cannot create/replace vault key material.
            return Err(journal::Failure::InvalidState);
        }
        Ok(())
    }
}
struct Contents {
    snippets: Vec<Snippet>,
    vault: Option<Document>,
    plain_bytes: Option<Zeroizing<Vec<u8>>>,
    vault_bytes: Option<Zeroizing<Vec<u8>>>,
}
#[derive(Clone, PartialEq)]
pub(crate) struct Snapshot {
    pub records: BTreeMap<Uuid, Envelope>,
    plain: Option<Zeroizing<Vec<u8>>>,
    vault: Option<Zeroizing<Vec<u8>>>,
}
impl Snapshot {
    /// A protected account-review receipt binds the complete file generation,
    /// including vault wraps and JSON whitespace, without retaining plaintext.
    pub(crate) fn review_fingerprint(&self) -> [u8; 32] {
        use sha2::{Digest, Sha256};
        let mut hash = Sha256::new();
        hash.update(b"Snippets account review primary v1\0");
        for image in [&self.plain, &self.vault] {
            hash.update([u8::from(image.is_some())]);
            if let Some(image) = image {
                hash.update((image.len() as u64).to_be_bytes());
                hash.update(image.as_slice());
            }
        }
        hash.finalize().into()
    }
    pub fn has_file(&self, secure: bool) -> bool {
        if secure {
            self.vault.is_some()
        } else {
            self.plain.is_some()
        }
    }
}
fn read_contents(root: &Path) -> Result<Contents> {
    check_vault_directory(root)?;
    let plain_bytes = model::read_regular(&root.join("snippets.json"))?.map(Zeroizing::new);
    let vault_bytes = model::read_regular(&root.join("Vault/vault.json"))?.map(Zeroizing::new);
    let snippets = plain_bytes
        .as_ref()
        .map(|b| model::decode_library(b, false))
        .transpose()?
        .unwrap_or_default();
    let vault = vault_bytes
        .as_ref()
        .map(|b| Document::decode(b))
        .transpose()?;
    Ok(Contents {
        snippets,
        vault,
        plain_bytes,
        vault_bytes,
    })
}
fn check_vault_directory(root: &Path) -> Result<()> {
    match fs::symlink_metadata(root.join("Vault")) {
        Ok(m) if m.is_dir() && !m.file_type().is_symlink() => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(Failure::Storage),
    }
}
/// Complete read set: `None` is a known absent primary record, never unknown.
pub type ReadSet = BTreeMap<Uuid, Option<Envelope>>;
/// Freeze direct roles and every existing implicit copy's own descendants.
/// The locked apply boundary rechecks these exact values as a connected group.
pub(crate) fn preservation_read_set(
    outcomes: &[Outcome],
    current: &BTreeMap<Uuid, Envelope>,
) -> Result<ReadSet> {
    let mut ids = BTreeSet::new();
    let mut queue = std::collections::VecDeque::new();
    for e in outcomes
        .iter()
        .flat_map(|o| o.survivor.iter().chain(&o.conflict_copies))
    {
        merge::validate(e)?;
        queue.push_back(e.id);
        queue.extend(merge::secure_variants(e)?.into_iter().map(|v| v.copy_id));
    }
    while let Some(id) = queue.pop_front() {
        if ids.insert(id)
            && let Some(e) = current.get(&id)
        {
            queue.extend(merge::secure_variants(e)?.into_iter().map(|v| v.copy_id));
        }
    }
    Ok(ids
        .into_iter()
        .map(|id| (id, current.get(&id).cloned()))
        .collect())
}
/// Read both primary files under the same lock, after checkpoint scope recovery.
pub(crate) fn current(
    library: &Library,
    journal: &Journal,
    device: &str,
) -> Result<BTreeMap<Uuid, Envelope>> {
    if journal.primary_intent.is_some() {
        return Err(Failure::RecoveryRequired);
    }
    let _guard = library.lock().map_err(|_| Failure::Storage)?;
    current_locked(library, journal, device)
}
pub(crate) fn current_locked(
    library: &Library,
    journal: &Journal,
    device: &str,
) -> Result<BTreeMap<Uuid, Envelope>> {
    Ok(snapshot_locked(library, journal, device)?.records)
}
pub(crate) fn snapshot_locked(
    library: &Library,
    journal: &Journal,
    device: &str,
) -> Result<Snapshot> {
    if journal.primary_intent.is_some() {
        return Err(Failure::RecoveryRequired);
    }
    require_ready(&library.root)?;
    let contents = read_contents(&library.root)?;
    let records = projection::current(
        &contents.snippets,
        contents.vault.as_ref(),
        device,
        journal.projected(),
        &journal.projection_knowledge(),
    )?;
    Ok(Snapshot {
        records,
        plain: contents.plain_bytes,
        vault: contents.vault_bytes,
    })
}
pub struct Prepared {
    intent: Intent,
    projected: BTreeMap<Uuid, Envelope>,
    dependencies: Vec<(Envelope, Vec<Envelope>)>,
    authenticated: Vec<Envelope>,
    held: BTreeMap<Uuid, Envelope>,
    release_targets: BTreeMap<Uuid, Envelope>,
    administrative: bool,
    primary_changed: bool,
    history: Vec<([u8; 16], crate::journal::RestorationGeneration)>,
    pub changed_ids: BTreeSet<Uuid>,
    pub retry_ids: BTreeSet<Uuid>,
    pub deferred_ids: BTreeSet<Uuid>,
    pub incompatible_ids: BTreeSet<Uuid>,
}
impl Prepared {
    /// Only an exact native deletion decision can release a never-offered
    /// source as a tombstone after its originals receive real acknowledgements.
    pub(crate) fn release_reviewed_deletion(
        &mut self,
        source: &Journal,
        reviewed: &Journal,
        target: &Envelope,
    ) -> Result<()> {
        if !reviewed.deletion_approved(target)? {
            return Err(Failure::InvalidState);
        }
        if source.can_release_deletion_source(target.id) {
            self.release_targets.insert(target.id, target.clone());
        }
        Ok(())
    }
    pub(crate) fn release_reviewed_keep(
        &mut self,
        source: &Journal,
        deleted: &Envelope,
        keep: &Envelope,
    ) -> Result<()> {
        if !deleted.deleted
            || keep.deleted
            || deleted.id != keep.id
            || self.projected.get(&keep.id) != Some(keep)
        {
            return Err(Failure::InvalidState);
        }
        if source.can_release_deletion_source(keep.id)
            && self
                .release_targets
                .get(&keep.id)
                .map(|e| equal(Some(e), Some(deleted)))
                .transpose()?
                .unwrap_or(false)
        {
            self.release_targets.insert(keep.id, keep.clone());
        }
        Ok(())
    }
    pub(crate) fn matches_snapshot(&self, snapshot: &Snapshot) -> bool {
        self.intent.before_plain == snapshot.plain && self.intent.before_vault == snapshot.vault
    }
}
fn equal(a: Option<&Envelope>, b: Option<&Envelope>) -> Result<bool> {
    match (a, b) {
        (None, None) => Ok(true),
        (Some(a), Some(b)) => Ok(a.hash()? == b.hash()?),
        _ => Ok(false),
    }
}
/// Already-merged outcomes are checked against the latest complete primary
/// snapshot. Unrelated changes survive; touched records that raced are retried.
/// Key-dependent secure conflicts defer as a complete preservation unit while locked.
#[path = "primary_deletion.rs"]
mod deletion;
pub(crate) use deletion::DeletionGroup;

pub fn prepare(
    library: &Library,
    journal: &Journal,
    device: &str,
    outcomes: &[Outcome],
    expected: &ReadSet,
) -> Result<Prepared> {
    prepare_impl(
        library,
        journal,
        device,
        outcomes,
        expected,
        None,
        &[],
        None,
    )
}
/// The native vault owner borrows its current key for this bounded operation.
/// The locked snapshot must still have the same wraps, salt and vault identity.
pub fn prepare_authenticated(
    library: &Library,
    journal: &Journal,
    device: &str,
    outcomes: &[Outcome],
    expected: &ReadSet,
    keys: &Keyring<'_>,
) -> Result<Prepared> {
    prepare_impl(
        library,
        journal,
        device,
        outcomes,
        expected,
        Some(keys),
        &[],
        None,
    )
}
pub(crate) fn prepare_restoration(
    library: &Library,
    journal: &Journal,
    device: &str,
    outcomes: &[Outcome],
    expected: &ReadSet,
    keys: Option<&Keyring<'_>>,
    history: &[crate::journal::RestorationGeneration],
) -> Result<Prepared> {
    prepare_impl(
        library, journal, device, outcomes, expected, keys, history, None,
    )
}
pub(crate) fn prepare_deletion_repair(
    library: &Library,
    journal: &Journal,
    device: &str,
    outcomes: &[Outcome],
    expected: &ReadSet,
    repair: &crate::journal::PreservationRepair,
    keys: Option<&Keyring<'_>>,
) -> Result<Prepared> {
    let mut prepared = prepare_impl(
        library,
        journal,
        device,
        outcomes,
        expected,
        keys,
        &[],
        None,
    )?;
    let _guard = library.lock().map_err(|_| Failure::Storage)?;
    let snapshot = snapshot_locked(library, journal, device)?;
    if !prepared.matches_snapshot(&snapshot) {
        return Err(Failure::StalePrimary);
    }
    prepared.history = history::prepare_repair(repair, journal, &snapshot.records, expected, keys)?;
    Ok(prepared)
}
#[path = "primary_history.rs"]
mod history;
#[allow(clippy::too_many_arguments)]
pub(crate) fn prepare_deletion_group(
    library: &Library,
    journal: &Journal,
    device: &str,
    outcomes: &[Outcome],
    expected: &ReadSet,
    group: &DeletionGroup,
    keys: &Keyring<'_>,
    repair: Option<&crate::journal::PreservationRepair>,
) -> Result<Prepared> {
    let mut prepared = prepare_impl(
        library,
        journal,
        device,
        outcomes,
        expected,
        Some(keys),
        &[],
        Some(group),
    )?;
    if let Some(repair) = repair {
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        let snapshot = snapshot_locked(library, journal, device)?;
        if !prepared.matches_snapshot(&snapshot) {
            return Err(Failure::StalePrimary);
        }
        prepared.history =
            history::prepare_repair(repair, journal, &snapshot.records, expected, Some(keys))?;
    }
    Ok(prepared)
}
#[allow(clippy::too_many_arguments)]
fn prepare_impl(
    library: &Library,
    journal: &Journal,
    device: &str,
    outcomes: &[Outcome],
    expected: &ReadSet,
    keys: Option<&Keyring<'_>>,
    historical: &[crate::journal::RestorationGeneration],
    deletion: Option<&DeletionGroup>,
) -> Result<Prepared> {
    if journal.primary_intent.is_some() {
        return Err(Failure::RecoveryRequired);
    }
    let _guard = library.lock().map_err(|_| Failure::Storage)?;
    require_ready(&library.root)?;
    let mut contents = read_contents(&library.root)?;
    if let Some(keys) = keys
        && !contents
            .vault
            .as_ref()
            .is_some_and(|document| keys.matches(document))
    {
        return Err(Failure::IncompatibleVault);
    }
    let primary = projection::current(
        &contents.snippets,
        contents.vault.as_ref(),
        device,
        journal.projected(),
        &journal.projection_knowledge(),
    )?;
    let resolutions = journal.carrier_resolutions(&primary)?;
    if let Some(group) = deletion {
        group.validate(
            journal,
            &primary,
            expected,
            outcomes,
            keys.ok_or(Failure::VaultLocked)?,
        )?;
    }
    let administrative = !outcomes.is_empty()
        && outcomes.iter().all(|o| {
            o.conflict_copies.is_empty()
                && o.survivor.as_ref().is_some_and(|e| {
                    resolutions
                        .iter()
                        .any(|r| r.source_id == e.id && r.resolved == *e)
                })
        });
    let mut prepared = Prepared {
        intent: Intent {
            nonce: crypto::random()?,
            before_plain: contents.plain_bytes.clone(),
            before_vault: contents.vault_bytes.clone(),
            after_plain: contents.plain_bytes.clone(),
            after_vault: contents.vault_bytes.clone(),
        },
        projected: journal.projected().clone(),
        dependencies: Vec::new(),
        authenticated: Vec::new(),
        held: BTreeMap::new(),
        release_targets: journal.release_targets(&primary)?,
        administrative,
        primary_changed: false,
        history: history::prepare(historical, &primary, expected, keys)?,
        changed_ids: BTreeSet::new(),
        retry_ids: BTreeSet::new(),
        deferred_ids: BTreeSet::new(),
        incompatible_ids: BTreeSet::new(),
    };
    let original_snippets = contents.snippets.clone();
    let original_vault = contents.vault.clone();
    for group in groups::prepare(
        outcomes,
        &primary,
        journal,
        expected,
        if administrative { None } else { keys },
        !administrative,
        deletion.map(DeletionGroup::originals),
    )? {
        let mut retry = false;
        let mut defer = false;
        let mut incompatible = false;
        for held in group.held.values() {
            merge::validate(held)?;
            if held.secure
                && !held.deleted
                && let Some(keys) = keys
            {
                materializer::authenticate(held, keys, true)?;
            }
            if merge::secure_variants(held)?.iter().any(|v| {
                group
                    .targets
                    .get(&held.id)
                    .and_then(|target| target.extensions.get(&v.extension_key))
                    != held.extensions.get(&v.extension_key)
            }) {
                defer = true;
            }
        }
        for e in group.targets.values().chain(&group.originals) {
            if e.extensions.contains_key(merge::COPY_PROVENANCE)
                && let Some(occupant) = primary.get(&e.id)
            {
                let p = merge::provenance(e).ok_or(Failure::InvalidState)?;
                if !merge::matching_provenance(occupant, p.source_id, &p.fingerprint) {
                    return Err(Failure::ReservedCollision);
                }
            }
            if !equal(
                primary.get(&e.id),
                expected.get(&e.id).and_then(Option::as_ref),
            )? {
                retry = true;
            }
            if e.deleted
                && merge::has_unresolved(primary.get(&e.id))
                && !deletion.is_some_and(|group| group.permits(e.id, primary.get(&e.id)))
            {
                return Err(Failure::InvalidState);
            }
            let variants = merge::secure_variants(e).map_err(|_| Failure::InvalidState)?;
            if !variants.is_empty() && keys.is_none() && !administrative {
                defer = true;
            }
            // Primary absence beside journal-only intent needs the explicit
            // absence/review recovery boundary; do not resurrect a local delete.
            if group.implicit.contains(&e.id)
                && !primary.contains_key(&e.id)
                && journal.entry(e.id).is_some()
            {
                defer = true;
            }
            if e.secure {
                if let Some(vault) = &contents.vault {
                    if e.extensions
                        .get("vaultKID")
                        .map(|v| v.as_text())
                        .transpose()?
                        .is_some_and(|kid| kid != vault.kid)
                    {
                        incompatible = true;
                    }
                    let existing = vault.records.iter().find(|r| r.metadata.id == e.id);
                    let exact = existing
                        .map(|r| projection::exact_secure_echo(e, r, &vault.kid))
                        .transpose()?
                        .unwrap_or(false);
                    let resolved_echo = resolutions
                        .iter()
                        .find(|r| r.source_id == e.id)
                        .map(|r| equal(Some(e), Some(&r.resolved)))
                        .transpose()?
                        .unwrap_or(false);
                    if !e.deleted
                        && (e.extensions.contains_key(merge::COPY_PROVENANCE)
                            || !e.extensions.contains_key("vaultKID"))
                        && !exact
                        && !resolved_echo
                        && keys.is_none()
                    {
                        defer = true;
                    }
                } else if !e.deleted {
                    defer = true;
                }
                if !e.deleted
                    && let Some(keys) = keys
                {
                    materializer::authenticate(e, keys, true)?;
                }
            }
            for variant in variants {
                if let Some(vault) = &contents.vault
                    && variant
                        .source_extensions
                        .get("vaultKID")
                        .and_then(|v| v.as_text().ok())
                        != Some(vault.kid.as_str())
                {
                    incompatible = true;
                }
            }
        }
        if retry || defer || incompatible {
            let destination = if incompatible {
                &mut prepared.incompatible_ids
            } else if retry {
                &mut prepared.retry_ids
            } else {
                &mut prepared.deferred_ids
            };
            destination.extend(group.targets.keys().copied());
            continue;
        }
        for e in group.targets.into_values() {
            prepared.primary_changed |= !equal(primary.get(&e.id), Some(&e))?;
            if e.deleted {
                contents.snippets.retain(|s| s.id != e.id);
                if let Some(vault) = &mut contents.vault {
                    vault.records.retain(|r| r.metadata.id != e.id);
                }
            } else if e.secure {
                let vault = contents.vault.as_mut().ok_or(Failure::InvalidState)?;
                let old = vault.records.iter().find(|r| r.metadata.id == e.id);
                let record =
                    projection::vault_record(&e, old, &vault.kid)?.ok_or(Failure::InvalidState)?;
                contents.snippets.retain(|s| s.id != e.id);
                if let Some(old) = vault.records.iter_mut().find(|r| r.metadata.id == e.id) {
                    *old = record;
                } else {
                    vault.records.push(record);
                }
            } else {
                let snippet = e.snippet()?.ok_or(Failure::InvalidState)?;
                if let Some(vault) = &mut contents.vault {
                    vault.records.retain(|r| r.metadata.id != e.id);
                }
                if let Some(old) = contents.snippets.iter_mut().find(|s| s.id == e.id) {
                    *old = snippet;
                } else {
                    contents.snippets.push(snippet);
                }
            }
            prepared.projected.insert(e.id, e.clone());
            prepared.changed_ids.insert(e.id);
            if !administrative && !merge::secure_variants(&e)?.is_empty() {
                prepared.dependencies.push((e, Vec::new()));
            }
        }
        for index in group.outcomes {
            let outcome = &outcomes[index];
            if let Some(source) = &outcome.survivor
                && !outcome.conflict_copies.is_empty()
            {
                prepared
                    .dependencies
                    .push((source.clone(), outcome.conflict_copies.clone()));
            }
        }
        prepared.authenticated.extend(group.authenticated);
        prepared.held.extend(group.held);
    }
    if let Some(group) = deletion {
        group.attach(&mut prepared);
    }
    validate_keywords(
        &contents.snippets,
        contents.vault.as_ref(),
        &original_snippets,
        original_vault.as_ref(),
    )?;
    if contents.snippets != original_snippets {
        prepared.intent.after_plain = Some(Zeroizing::new(model::encode_library(
            &contents.snippets,
            false,
        )?));
    }
    if contents.vault != original_vault {
        prepared.intent.after_vault = contents
            .vault
            .as_ref()
            .map(|v| v.encode().map(Zeroizing::new))
            .transpose()?;
    }
    prepared.intent.validate()?;
    Ok(prepared)
}
fn validate_keywords(
    snippets: &[Snippet],
    vault: Option<&Document>,
    before: &[Snippet],
    before_vault: Option<&Document>,
) -> Result<()> {
    // The merger's collision arbitration is still an engine obligation. The
    // filesystem boundary cannot persist a newly colliding keyword meanwhile.
    fn groups(snippets: &[Snippet], vault: Option<&Document>) -> BTreeMap<String, BTreeSet<Uuid>> {
        let mut result = BTreeMap::<_, BTreeSet<_>>::new();
        for (id, keyword) in snippets
            .iter()
            .filter(|s| s.is_enabled)
            .map(|s| (s.id, &s.keyword))
            .chain(vault.into_iter().flat_map(|v| {
                v.records
                    .iter()
                    .filter(|r| r.metadata.is_enabled)
                    .map(|r| (r.metadata.id, &r.metadata.keyword))
            }))
        {
            if !keyword.is_empty() {
                result.entry(model::folded(keyword)).or_default().insert(id);
            }
        }
        result
    }
    let before = groups(before, before_vault);
    for (key, owners) in groups(snippets, vault) {
        if owners.len() > 1 && !before.get(&key).is_some_and(|old| owners.is_subset(old)) {
            return Err(Failure::InvalidState);
        }
    }
    Ok(())
}
pub fn commit(
    library: &Library,
    checkpoint: &mut Checkpoint,
    key: &RootKey,
    salt: &[u8; 32],
    prepared: Prepared,
) -> Result<()> {
    commit_with_fault(library, checkpoint, key, salt, prepared, None)
}
fn commit_with_fault(
    library: &Library,
    checkpoint: &mut Checkpoint,
    key: &RootKey,
    salt: &[u8; 32],
    prepared: Prepared,
    fault: Option<u8>,
) -> Result<()> {
    commit_impl(library, checkpoint, key, salt, prepared, None, fault)
}
/// The decision/receipt and its primary images share one WAL publication.
/// Only the owning review boundary may provide a staged journal.
pub(crate) fn commit_staged(
    library: &Library,
    checkpoint: &mut Checkpoint,
    key: &RootKey,
    salt: &[u8; 32],
    prepared: Prepared,
    next: Journal,
    fault: Option<u8>,
) -> Result<()> {
    if next.scope() != checkpoint.journal.scope()
        || (checkpoint.journal.key_epoch.is_some()
            && next.key_epoch != checkpoint.journal.key_epoch)
        || next.primary_intent.is_some()
        || next.primary_epoch != checkpoint.journal.primary_epoch
    {
        return Err(Failure::InvalidState);
    }
    commit_impl(library, checkpoint, key, salt, prepared, Some(next), fault)
}
#[allow(clippy::too_many_arguments)]
fn commit_impl(
    library: &Library,
    checkpoint: &mut Checkpoint,
    key: &RootKey,
    salt: &[u8; 32],
    prepared: Prepared,
    staged: Option<Journal>,
    fault: Option<u8>,
) -> Result<()> {
    if prepared.changed_ids.is_empty() {
        return if staged.is_none() {
            Ok(())
        } else {
            Err(Failure::InvalidState)
        };
    }
    let _guard = library.lock().map_err(|_| Failure::Storage)?;
    require_ready(&library.root)?;
    let current = read_contents(&library.root)?;
    if current.plain_bytes != prepared.intent.before_plain
        || current.vault_bytes != prepared.intent.before_vault
    {
        return Err(Failure::StalePrimary);
    }
    if checkpoint.journal.primary_intent.is_some() {
        return Err(Failure::RecoveryRequired);
    }
    let next = staged.unwrap_or_else(|| checkpoint.journal.clone());
    let next = stage_prepared(next, &prepared)?;
    // Also establishes an authenticated no-intent baseline for the very first
    // transaction, so even a pre-WAL marker interruption is recoverable.
    checkpoint.journal.primary_epoch = Some(prepared.intent.nonce);
    checkpoint.save_locked(library, key, salt)?;
    // The marker is written first. A crash before the encrypted WAL is published
    // is an authenticated no-intent recovery; no primary write has begun yet.
    write_marker(library, &prepared.intent.nonce)?;
    if fault == Some(0) {
        return Err(Failure::RecoveryRequired);
    }
    checkpoint.journal = next;
    checkpoint.save_locked(library, key, salt)?;
    if fault == Some(1) {
        return Err(Failure::RecoveryRequired);
    }
    finish_locked(library, checkpoint, key, salt, fault)
}
fn stage_prepared(mut next: Journal, prepared: &Prepared) -> Result<Journal> {
    for intent in prepared.held.values() {
        next.desire(intent.clone())?;
    }
    for (nonce, generation) in &prepared.history {
        next.stage_restoration_generation(*nonce, generation, &prepared.release_targets)?;
    }
    if !prepared.administrative
        && !prepared.changed_ids.is_empty()
        && (prepared.primary_changed || !prepared.dependencies.is_empty())
    {
        let mut targets: BTreeMap<_, _> = prepared
            .changed_ids
            .iter()
            .map(|id| {
                (
                    *id,
                    prepared.projected.get(id).expect("prepared target").clone(),
                )
            })
            .collect();
        targets.extend(prepared.held.clone());
        next.stage_generation(
            prepared.intent.nonce,
            &prepared.dependencies,
            &prepared.authenticated,
            &targets,
            &prepared.release_targets,
        )?;
    }
    next.projected = prepared.projected.clone();
    next.primary_intent = Some(prepared.intent.clone());
    next.primary_epoch = Some(prepared.intent.nonce);
    Ok(next)
}
fn write_marker(library: &Library, nonce: &[u8; 16]) -> Result<()> {
    let directory = library.root.join("Sync");
    match fs::symlink_metadata(&directory) {
        Ok(m) if m.is_dir() && !m.file_type().is_symlink() => (),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .map_err(|_| Failure::Storage)?;
            fs::File::open(&library.root)
                .and_then(|f| f.sync_all())
                .map_err(|_| Failure::Storage)?;
        }
        _ => return Err(Failure::Storage),
    }
    let mut bytes = b"SPT1".to_vec();
    bytes.extend_from_slice(nonce);
    model::atomic_write(&directory.join(MARKER), &bytes)?;
    Ok(())
}
fn marker(root: &Path) -> Result<Option<[u8; 16]>> {
    let bytes = model::read_regular_bounded(&root.join("Sync").join(MARKER), 20)?;
    bytes
        .map(|b| {
            if b.len() != 20 || &b[..4] != b"SPT1" {
                return Err(Failure::InvalidState);
            }
            b[4..].try_into().map_err(|_| Failure::InvalidState)
        })
        .transpose()
}
fn remove_marker(root: &Path) -> Result<()> {
    fs::remove_file(root.join("Sync").join(MARKER)).map_err(|_| Failure::Storage)?;
    fs::File::open(root.join("Sync"))
        .and_then(|f| f.sync_all())
        .map_err(|_| Failure::Storage)
}
fn finish_locked(
    library: &Library,
    checkpoint: &mut Checkpoint,
    key: &RootKey,
    salt: &[u8; 32],
    fault: Option<u8>,
) -> Result<()> {
    finish_checked_locked(library, checkpoint, key, salt, fault, &|| Ok(()), true)
}
#[allow(clippy::too_many_arguments)]
fn finish_checked_locked(
    library: &Library,
    checkpoint: &mut Checkpoint,
    key: &RootKey,
    salt: &[u8; 32],
    fault: Option<u8>,
    validate: &dyn Fn() -> Result<()>,
    clear_marker: bool,
) -> Result<()> {
    validate()?;
    let intent = checkpoint
        .journal
        .primary_intent
        .clone()
        .ok_or(Failure::InvalidState)?;
    if marker(&library.root)? != Some(intent.nonce) {
        return Err(Failure::RecoveryRequired);
    }
    let current = read_contents(&library.root)?;
    // Each image must still be exactly pre-apply or already post-apply. No
    // unrecognized local edit can be overwritten by an interrupted redo.
    if current.plain_bytes != intent.before_plain && current.plain_bytes != intent.after_plain
        || current.vault_bytes != intent.before_vault && current.vault_bytes != intent.after_vault
    {
        return Err(Failure::StalePrimary);
    }
    // Readers are fenced throughout both replacements. After any crash the WAL
    // retains the complete post-images, including every losing conflict body.
    if current.plain_bytes != intent.after_plain
        && let Some(bytes) = &intent.after_plain
    {
        model::atomic_write(&library.root.join("snippets.json"), bytes)?;
    }
    if fault == Some(2) {
        return Err(Failure::RecoveryRequired);
    }
    validate()?;
    let current = read_contents(&library.root)?;
    if current.plain_bytes != intent.after_plain
        || current.vault_bytes != intent.before_vault && current.vault_bytes != intent.after_vault
    {
        return Err(Failure::StalePrimary);
    }
    if current.vault_bytes != intent.after_vault
        && let Some(bytes) = &intent.after_vault
    {
        check_vault_directory(&library.root)?;
        let directory = library.root.join("Vault");
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .or_else(|e| {
                if e.kind() == std::io::ErrorKind::AlreadyExists {
                    Ok(())
                } else {
                    Err(e)
                }
            })
            .map_err(|_| Failure::Storage)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .map_err(|_| Failure::Storage)?;
        fs::File::open(&library.root)
            .and_then(|f| f.sync_all())
            .map_err(|_| Failure::Storage)?;
        model::atomic_write(&directory.join("vault.json"), bytes)?;
    }
    if fault == Some(3) {
        return Err(Failure::RecoveryRequired);
    }
    validate()?;
    let current = read_contents(&library.root)?;
    if current.plain_bytes != intent.after_plain || current.vault_bytes != intent.after_vault {
        return Err(Failure::StalePrimary);
    }
    checkpoint.journal.primary_intent = None;
    checkpoint.save_locked(library, key, salt)?;
    if fault == Some(4) {
        return Err(Failure::RecoveryRequired);
    }
    validate()?;
    if clear_marker {
        remove_marker(&library.root)
    } else {
        Ok(())
    }
}
/// Boot recovery authenticates the checkpoint and scope before reading either
/// primary file. Absent/corrupt/wrong-key checkpoints never erase a marker.
pub fn recover(root: &Path, key: &RootKey, salt: &[u8; 32], scope: Scope) -> Result<Checkpoint> {
    recover_checked(root, key, salt, scope, |_| Ok(()))
}
pub(crate) fn recover_checked(
    root: &Path,
    key: &RootKey,
    salt: &[u8; 32],
    scope: Scope,
    validate: impl FnOnce(&Journal) -> Result<()>,
) -> Result<Checkpoint> {
    let library = Library::prepare(root.into())?;
    let _guard = library.lock().map_err(|_| Failure::Storage)?;
    crate::backup::import::require_clear(root)?;
    let mut checkpoint = Checkpoint::load_locked(&library, key, salt, scope)?;
    validate(&checkpoint.journal)?;
    match (marker(root)?, checkpoint.journal.primary_intent.as_ref()) {
        (Some(nonce), None) => {
            // A durable authenticated checkpoint with no intent proves either a
            // pre-WAL interruption or a completed apply awaiting marker removal.
            if checkpoint.journal.primary_epoch != Some(nonce)
                || model::read_regular_bounded(
                    &root.join("Sync/journal.bin"),
                    crypto::MAX_CHECKPOINT_BYTES + 32,
                )?
                .is_none()
            {
                return Err(Failure::RecoveryRequired);
            }
            remove_marker(root)?;
        }
        (Some(_), Some(_)) => finish_locked(&library, &mut checkpoint, key, salt, None)?,
        (None, Some(_)) => return Err(Failure::RecoveryRequired),
        (None, None) => (),
    }
    Ok(checkpoint)
}

#[cfg(test)]
#[path = "primary_tests.rs"]
pub(crate) mod tests;
