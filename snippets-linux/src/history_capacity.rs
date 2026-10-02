//! Explicit retirement of terminal protected history. Durable consent precedes
//! archive replacement and file removal; no key or ciphertext is auto-evicted.
use super::*;
use crate::local_auth::{AuthorizationLease, Permit, Purpose, Target};
use crate::model::Library;

#[path = "history_capacity_files.rs"]
mod files;
#[cfg(test)]
#[path = "history_capacity_tests.rs"]
mod tests;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Section {
    Switches,
    Pairing,
    FirstKeys,
    Restorations,
    Creations,
}
impl Section {
    fn text(self) -> &'static str {
        match self {
            Self::Switches => "switches",
            Self::Pairing => "pairing",
            Self::FirstKeys => "firstKeys",
            Self::Restorations => "restorations",
            Self::Creations => "creations",
        }
    }
    fn parse(value: &Value) -> Result<Self> {
        match value.as_text()? {
            "switches" => Ok(Self::Switches),
            "pairing" => Ok(Self::Pairing),
            "firstKeys" => Ok(Self::FirstKeys),
            "restorations" => Ok(Self::Restorations),
            "creations" => Ok(Self::Creations),
            _ => Err(Failure::InvalidState),
        }
    }
    fn slot(self) -> Slot {
        match self {
            Self::Switches => Slot::AccountReview,
            Self::Pairing => Slot::PairingCandidate,
            Self::FirstKeys => Slot::BootstrapCandidate,
            Self::Restorations => Slot::HistoryRestore,
            Self::Creations => Slot::SpaceCreation,
        }
    }
    fn schema(self) -> i64 {
        match self {
            Self::Switches => 4,
            Self::Creations => 3,
            _ => 2,
        }
    }
    fn max_bytes(self) -> usize {
        if self == Self::Creations {
            crate::auth_store::creation::MAX_BYTES
        } else {
            secret_store::MAX_SECRET_BYTES
        }
    }
}
/// Exact row and document version. No Debug, persistence or generic constructor.
#[derive(Clone)]
pub struct Selection {
    section: Section,
    index: usize,
    hash: [u8; 32],
}
impl Selection {
    pub(crate) fn new(section: Section, index: usize, snapshot: &[u8]) -> Self {
        Self {
            section,
            index,
            hash: Sha256::digest(snapshot).into(),
        }
    }
}
#[derive(Clone)]
pub struct Summary {
    pub libraries: Vec<history::SavedLibrary>,
    pub section: Section,
    pub entry: usize,
    pub protected_bytes: usize,
    pub encrypted_images: usize,
    pub encrypted_bytes: u64,
}
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct Images {
    pub nonce: [u8; 16],
    pub hashes: [[u8; 32]; 2],
}
pub(crate) struct Row {
    pub libraries: Vec<KeyBinding>,
    pub eligible: bool,
    pub images: Option<Images>,
}
pub(crate) struct Document {
    snapshot: Zeroizing<Vec<u8>>,
    generation: i64,
    values: Vec<Value>,
    rows: Vec<Row>,
}
impl Document {
    /// Call only after the owning archive's typed loader validates every entry.
    pub(crate) fn validated(
        snapshot: Option<Zeroizing<Vec<u8>>>,
        generation: i64,
        rows: Vec<Row>,
    ) -> Result<Self> {
        let snapshot = snapshot.ok_or(Failure::RecoveryUnavailable)?;
        let value = canonical::parse(&snapshot)?;
        let fields = exact(&value, &["schema", "generation", "entries"])?;
        let values = fields["entries"].as_array()?.to_vec();
        if fields["generation"].as_int()? != generation || values.len() != rows.len() {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            snapshot,
            generation,
            values,
            rows,
        })
    }
    fn removed(&self, selection: &Selection) -> Result<Zeroizing<Vec<u8>>> {
        if Sha256::digest(&self.snapshot).as_slice() != selection.hash {
            return Err(Failure::ReviewRequired);
        }
        if !self
            .rows
            .get(selection.index)
            .ok_or(Failure::RecoveryUnavailable)?
            .eligible
        {
            return Err(Failure::Busy);
        }
        let mut entries = self.values.clone();
        entries.remove(selection.index);
        let bytes = object([
            ("schema", Value::Int(selection.section.schema())),
            (
                "generation",
                Value::Int(
                    self.generation
                        .checked_add(1)
                        .ok_or(Failure::InvalidState)?,
                ),
            ),
            ("entries", Value::Array(entries)),
        ])
        .encode()?;
        if bytes.len() > selection.section.max_bytes() {
            return Err(Failure::Busy);
        }
        Ok(bytes)
    }
}
fn document<B: Backend>(owner: &mut Locked<'_, B>, section: Section) -> Result<Document> {
    match section {
        Section::Switches => handover::removal_document_locked(owner),
        Section::Pairing => candidate::removal_document_locked(owner),
        Section::FirstKeys => initial_candidate::removal_document_locked(owner),
        Section::Restorations => restoration::removal_document_locked(owner),
        Section::Creations => crate::auth_store::creation::removal_document_locked(owner),
    }
}
/// Owning candidate codecs decide whether a creation receipt still supports an
/// unfinished key request. Account stamps and generic JSON are not classifiers.
pub(crate) fn creation_candidate_pending_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<bool> {
    for section in [Section::Pairing, Section::FirstKeys] {
        if owner.read(section.slot())?.is_some()
            && document(owner, section)?
                .rows
                .iter()
                .any(|row| !row.eligible && row.libraries.iter().any(|b| b.same_library(binding)))
        {
            return Ok(true);
        }
    }
    Ok(false)
}
fn ready<B: Backend>(owner: &mut Locked<'_, B>, library: &Library) -> Result<Installed> {
    handover::require_idle(owner)?;
    crate::primary::require_ready(owner.root()).map_err(|_| Failure::Busy)?;
    let installed = Installed::decode(
        &owner
            .read(Slot::LibraryKey)?
            .ok_or(Failure::RecoveryUnavailable)?,
    )?;
    let sync = owner.root().join("Sync");
    match std::fs::symlink_metadata(&sync) {
        Ok(m) if m.is_dir() && !m.file_type().is_symlink() => (),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(installed),
        _ => return Err(Failure::InvalidState),
    }
    if crate::model::read_regular_bounded(
        &sync.join("journal.bin"),
        crate::crypto::MAX_CHECKPOINT_BYTES + 32,
    )?
    .is_some()
    {
        let material = owner
            .checkpoint_material(false)?
            .ok_or(Failure::InvalidState)?;
        let key = RootKey::from_bytes(&material[..32]).map_err(|_| Failure::InvalidState)?;
        let salt = material[32..]
            .try_into()
            .map_err(|_| Failure::InvalidState)?;
        let checkpoint = crate::journal::Checkpoint::load_locked(
            library,
            &key,
            &salt,
            installed.binding.checkpoint_scope(),
        )
        .map_err(|_| Failure::InvalidState)?;
        if checkpoint.journal.primary_intent.is_some()
            || checkpoint.journal.key_epoch != Some(installed.binding.epoch)
        {
            return Err(Failure::Busy);
        }
    }
    Ok(installed)
}
fn frame<B: Backend>(owner: &mut Locked<'_, B>) -> Result<[u8; 32]> {
    let mut hash = Sha256::new();
    hash.update(b"Snippets history removal active owner v1\0");
    for slot in [Slot::LibraryKey, Slot::CheckpointKey] {
        let value = owner.read(slot)?;
        hash.update((value.as_ref().map_or(0, |v| v.len()) as u64).to_be_bytes());
        if let Some(value) = value {
            hash.update(value.as_slice());
        }
    }
    Ok(hash.finalize().into())
}
struct Intent {
    libraries: Vec<KeyBinding>,
    binding: KeyBinding,
    frame: [u8; 32],
    nonce: [u8; 16],
    selection: Selection,
    generation: i64,
    after: [u8; 32],
    proofs: Vec<files::Proof>,
    summary: Summary,
}
impl Intent {
    fn value(&self) -> Result<Value> {
        Ok(object([
            ("schema", Value::Int(1)),
            (
                "libraries",
                Value::Array(self.libraries.iter().map(KeyBinding::value).collect()),
            ),
            ("binding", self.binding.value()),
            ("frame", Value::text(STANDARD.encode(self.frame))),
            ("nonce", Value::text(STANDARD.encode(self.nonce))),
            ("section", Value::text(self.selection.section.text())),
            ("index", Value::Int(self.selection.index as i64)),
            ("before", Value::text(STANDARD.encode(self.selection.hash))),
            ("after", Value::text(STANDARD.encode(self.after))),
            ("generation", Value::Int(self.generation)),
            (
                "protectedBytes",
                Value::Int(self.summary.protected_bytes as i64),
            ),
            (
                "images",
                Value::Array(self.proofs.iter().map(files::Proof::value).collect()),
            ),
        ]))
    }
    fn bytes(&self) -> Result<Zeroizing<Vec<u8>>> {
        Ok(self.value()?.encode()?)
    }
    fn parse(bytes: &[u8]) -> Result<Self> {
        let value = canonical::parse(bytes)?;
        let fields = exact(
            &value,
            &[
                "schema",
                "libraries",
                "binding",
                "frame",
                "nonce",
                "section",
                "index",
                "before",
                "after",
                "generation",
                "protectedBytes",
                "images",
            ],
        )?;
        let array = |name: &str| -> Result<Zeroizing<Vec<u8>>> {
            decode64(
                fields[name].as_text()?,
                if name == "nonce" { 16 } else { 32 },
            )
        };
        let selection = Selection {
            section: Section::parse(&fields["section"])?,
            index: usize::try_from(fields["index"].as_int()?).map_err(|_| Failure::InvalidState)?,
            hash: array("before")?
                .as_slice()
                .try_into()
                .map_err(|_| Failure::InvalidState)?,
        };
        let generation = fields["generation"].as_int()?;
        let libraries = fields["libraries"]
            .as_array()?
            .iter()
            .map(KeyBinding::parse)
            .collect::<Result<Vec<_>>>()?;
        let protected_bytes = usize::try_from(fields["protectedBytes"].as_int()?)
            .map_err(|_| Failure::InvalidState)?;
        let proofs = fields["images"]
            .as_array()?
            .iter()
            .map(files::Proof::parse)
            .collect::<Result<Vec<_>>>()?;
        let nonce = array("nonce")?
            .as_slice()
            .try_into()
            .map_err(|_| Failure::InvalidState)?;
        if fields["schema"].as_int()? != 1
            || libraries.len()
                != if matches!(selection.section, Section::Switches | Section::Restorations) {
                    2
                } else {
                    1
                }
            || generation < 1
            || generation.checked_add(1).is_none()
            || selection.index >= history::MAX_ENTRIES
            || protected_bytes > selection.section.max_bytes()
            || nonce == [0; 16]
            || !matches!(proofs.len(), 0 | 2)
            || matches!(selection.section, Section::Switches | Section::Restorations)
                != (proofs.len() == 2)
            || proofs.windows(2).any(|pair| {
                pair[0].nonce != pair[1].nonce || pair[0].kind != 0 || pair[1].kind != 1
            })
        {
            return Err(Failure::InvalidState);
        }
        let summary = Summary {
            libraries: libraries.iter().map(history::SavedLibrary::new).collect(),
            section: selection.section,
            entry: selection.index + 1,
            protected_bytes,
            encrypted_images: proofs.len(),
            encrypted_bytes: proofs.iter().map(|p| p.length()).sum(),
        };
        Ok(Self {
            libraries,
            binding: KeyBinding::parse(&fields["binding"])?,
            frame: array("frame")?
                .as_slice()
                .try_into()
                .map_err(|_| Failure::InvalidState)?,
            nonce,
            selection,
            generation,
            after: array("after")?
                .as_slice()
                .try_into()
                .map_err(|_| Failure::InvalidState)?,
            proofs,
            summary,
        })
    }
    fn target(&self, purpose: Purpose) -> Result<Target> {
        let mut hash = Sha256::new();
        hash.update(b"Snippets explicit history removal v1\0");
        hash.update(self.bytes()?.as_slice());
        Ok(Target::new(
            self.binding.clone(),
            purpose,
            self.generation,
            hash.finalize().into(),
        )?)
    }
}
pub struct Review {
    intent: Intent,
    resume: bool,
}
impl Review {
    pub fn summary(&self) -> Summary {
        self.intent.summary.clone()
    }
    pub fn authorization_target(&self) -> Result<Target> {
        self.intent.target(if self.resume {
            Purpose::ResumeHistoryRemoval
        } else {
            Purpose::RemoveSavedHistory
        })
    }
}
pub(super) fn pending_locked<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Option<Summary>> {
    owner
        .read(Slot::HistoryMaintenance)?
        .map(|bytes| Intent::parse(&bytes).map(|intent| intent.summary))
        .transpose()
}
pub fn prepare<B: Backend>(store: &mut Store<B>, selection: Selection) -> Result<Review> {
    store.transaction_with(|owner| {
        let library = Library::prepare(owner.root().into())?;
        let _guard = library.lock()?;
        let installed = ready(owner, &library)?;
        let doc = document(owner, selection.section)?;
        let after = doc.removed(&selection)?;
        let images = &doc.rows[selection.index].images;
        let mut proofs = Vec::new();
        if let Some(images) = images {
            for section in [Section::Switches, Section::Restorations] {
                if owner.read(section.slot())?.is_none() {
                    continue;
                }
                let other = document(owner, section)?;
                for (index, row) in other.rows.iter().enumerate() {
                    if section == selection.section && index == selection.index {
                        continue;
                    }
                    if row
                        .images
                        .as_ref()
                        .is_some_and(|other| other.nonce == images.nonce)
                    {
                        return Err(Failure::Busy);
                    }
                }
            }
            match selection.section {
                Section::Switches => {
                    handover::validate_removal_images_locked(owner, &library, selection.index)?
                }
                Section::Restorations => {
                    restoration::validate_removal_images_locked(owner, &library, selection.index)?
                }
                _ => return Err(Failure::InvalidState),
            }
            proofs = files::prove(&library, images)?;
        }
        let summary = Summary {
            libraries: doc.rows[selection.index]
                .libraries
                .iter()
                .map(history::SavedLibrary::new)
                .collect(),
            section: selection.section,
            entry: selection.index + 1,
            protected_bytes: doc.snapshot.len().saturating_sub(after.len()),
            encrypted_images: proofs.len(),
            encrypted_bytes: proofs.iter().map(files::Proof::length).sum(),
        };
        Ok(Review {
            intent: Intent {
                libraries: doc.rows[selection.index].libraries.clone(),
                binding: installed.binding,
                frame: frame(owner)?,
                nonce: crate::crypto::random().map_err(|_| Failure::InvalidState)?,
                selection,
                generation: doc.generation,
                after: Sha256::digest(after).into(),
                proofs,
                summary,
            },
            resume: false,
        })
    })
}
pub fn prepare_resume<B: Backend>(store: &mut Store<B>) -> Result<Review> {
    store.history_transaction_with(|owner| {
        let bytes = owner
            .read(Slot::HistoryMaintenance)?
            .ok_or(Failure::RecoveryUnavailable)?;
        let intent = Intent::parse(&bytes)?;
        let library = Library::prepare(owner.root().into())?;
        let _guard = library.lock()?;
        verify(owner, &library, &intent)?;
        Ok(Review {
            intent,
            resume: true,
        })
    })
}
fn verify<B: Backend>(owner: &mut Locked<'_, B>, library: &Library, intent: &Intent) -> Result<()> {
    if ready(owner, library)?.binding != intent.binding || frame(owner)? != intent.frame {
        return Err(Failure::ReviewRequired);
    }
    if intent.selection.section == Section::Creations {
        crate::auth_store::creation::verify_retirement_locked(owner, &intent.libraries[0])?;
    }
    let doc = document(owner, intent.selection.section)?;
    let hash: [u8; 32] = Sha256::digest(&doc.snapshot).into();
    if matches!(
        intent.selection.section,
        Section::Switches | Section::Restorations
    ) != (intent.proofs.len() == 2)
    {
        return Err(Failure::InvalidState);
    }
    for section in [Section::Switches, Section::Restorations] {
        if owner.read(section.slot())?.is_none() {
            continue;
        }
        for (index, row) in document(owner, section)?.rows.iter().enumerate() {
            if hash == intent.selection.hash
                && section == intent.selection.section
                && index == intent.selection.index
            {
                continue;
            }
            if row.images.as_ref().is_some_and(|images| {
                intent
                    .proofs
                    .iter()
                    .any(|proof| proof.nonce == images.nonce)
            }) {
                return Err(Failure::Busy);
            }
        }
    }
    if hash == intent.selection.hash {
        if doc
            .rows
            .get(intent.selection.index)
            .is_none_or(|row| row.libraries != intent.libraries)
        {
            return Err(Failure::ReviewRequired);
        }
        let after = doc.removed(&intent.selection)?;
        if doc.generation != intent.generation || Sha256::digest(after).as_slice() != intent.after {
            return Err(Failure::ReviewRequired);
        }
        files::verify(library, &intent.proofs, false)?;
        if let Some(images) = &doc.rows[intent.selection.index].images
            && intent.proofs.iter().enumerate().any(|(index, proof)| {
                proof.nonce != images.nonce
                    || proof.kind as usize != index
                    || proof.hash() != images.hashes[index]
            })
        {
            return Err(Failure::InvalidState);
        }
    } else if hash == intent.after && doc.generation == intent.generation + 1 {
        files::verify(library, &intent.proofs, true)?;
    } else {
        return Err(Failure::ReviewRequired);
    }
    Ok(())
}
pub fn apply<B: Backend>(store: &mut Store<B>, review: Review, permit: Permit) -> Result<()> {
    apply_inner(store, review, permit, None)
}
#[cfg(test)]
pub(crate) fn apply_with_fault<B: Backend>(
    store: &mut Store<B>,
    review: Review,
    permit: Permit,
    fault: Option<u8>,
) -> Result<()> {
    apply_inner(store, review, permit, fault)
}
fn apply_inner<B: Backend>(
    store: &mut Store<B>,
    review: Review,
    permit: Permit,
    fault: Option<u8>,
) -> Result<()> {
    let lease = permit.consume(&review.authorization_target()?)?;
    store.history_transaction_with(|owner| {
        let library = Library::prepare(owner.root().into())?;
        let _guard = library.lock()?;
        let expected = review.intent.bytes()?;
        let pending = owner.read(Slot::HistoryMaintenance)?;
        if review.resume {
            if pending.as_deref().map(Vec::as_slice) != Some(expected.as_slice()) {
                return Err(Failure::ReviewRequired);
            }
        } else if pending.is_some() {
            return Err(Failure::Busy);
        }
        verify(owner, &library, &review.intent)?;
        lease.check()?;
        if !review.resume {
            owner.replace(Slot::HistoryMaintenance, None, Some(&expected))?;
        }
        fail(fault, 1)?;
        finish(owner, &library, &review.intent, &expected, &lease, fault)
    })
}
fn finish<B: Backend>(
    owner: &mut Locked<'_, B>,
    library: &Library,
    intent: &Intent,
    expected: &[u8],
    lease: &AuthorizationLease,
    fault: Option<u8>,
) -> Result<()> {
    let doc = document(owner, intent.selection.section)?;
    if Sha256::digest(&doc.snapshot).as_slice() == intent.selection.hash {
        let after = doc.removed(&intent.selection)?;
        lease.check()?;
        owner.replace(
            intent.selection.section.slot(),
            Some(&doc.snapshot),
            Some(&after),
        )?;
    }
    fail(fault, 2)?;
    files::remove(library, &intent.proofs, lease, fault)?;
    lease.check()?;
    owner.replace(Slot::HistoryMaintenance, Some(expected), None)?;
    Ok(())
}
fn fail(fault: Option<u8>, step: u8) -> Result<()> {
    if fault == Some(step) {
        Err(Failure::InvalidState)
    } else {
        Ok(())
    }
}
