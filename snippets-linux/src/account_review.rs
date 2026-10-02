//! Journal-first account/library/key review. The owning credential/key worker
//! must verify and retain the target library key before committing this ticket,
//! then finish its Secret Service activation before allowing ordinary sync.
//! This boundary never installs keys, fetches records, posts, or edits primary.
use crate::{
    crypto,
    inbound::Feed,
    journal::{self, Checkpoint, Scope},
    model, primary,
    receiver::{self, Owner, Remote},
    snapshot_review::check_epoch,
};
use sha2::{Digest, Sha256};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::{Path, PathBuf},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Data(receiver::Failure),
    Unavailable,
    LocalAbsence,
    Changed,
    InvalidReceipt,
    RetentionFull,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<receiver::Failure> for Failure {
    fn from(value: receiver::Failure) -> Self {
        Self::Data(value)
    }
}
impl From<journal::Failure> for Failure {
    fn from(value: journal::Failure) -> Self {
        Self::Data(receiver::Failure::Journal(value))
    }
}
impl From<primary::Failure> for Failure {
    fn from(value: primary::Failure) -> Self {
        Self::Data(receiver::Failure::Primary(value))
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Previous {
    pub scope: Scope,
    pub key_epoch: u64,
    /// A separately verified authority/key replacement can require review even
    /// when the server did not advance its membership, dataset or epoch pins.
    pub key_material_changed: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Summary {
    pub local_records: usize,
    pub local_intents: usize,
    pub preservation_copies: usize,
    pub previous_confirmations: usize,
}

/// Ephemeral inspection metadata, never permission to restore or synchronize.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActiveImage {
    Source,
    Target,
    Other,
    Missing,
    Unreadable,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RetainedImages {
    Verified { active: ActiveImage },
    Missing,
    Invalid,
    Unreadable,
}
/// Kept by the key owner in its durable transition before touching the journal.
/// No Debug/serde/logging interface exposes bindings, nonce, hashes or paths.
#[derive(Clone, PartialEq, Eq)]
pub struct Receipt {
    root: PathBuf,
    previous: Previous,
    scope: Scope,
    feed: Feed,
    nonce: [u8; 16],
    summary: Summary,
    source_present: bool,
    primary_hash: [u8; 32],
    source_hash: [u8; 32],
    target_hash: [u8; 32],
    device: [u8; 8],
}
pub struct Review {
    receipt: Receipt,
    source: Checkpoint,
    snapshot: primary::Snapshot,
    device: String,
    source_image: Vec<u8>,
    target_image: Vec<u8>,
}
impl Review {
    pub(crate) fn vault_recovery_header(&self) -> Result<Option<crate::vault::RecoveryHeader>> {
        Ok(self.snapshot.vault_recovery_header()?)
    }
    pub fn summary(&self) -> Summary {
        self.receipt.summary
    }
    pub fn receipt(&self) -> Receipt {
        self.receipt.clone()
    }
}
impl Receipt {
    pub fn summary(&self) -> Summary {
        self.summary
    }
    pub(crate) fn previous(&self) -> &Previous {
        &self.previous
    }
    pub(crate) fn target(&self) -> (&Scope, u64) {
        (&self.scope, self.feed.key_epoch)
    }
    pub(crate) fn transition_id(&self) -> [u8; 16] {
        self.nonce
    }
    pub(crate) fn image_hashes(&self) -> [[u8; 32]; 2] {
        [self.source_hash, self.target_hash]
    }
    /// Fixed, closed, bounded encoding for the owning Secret Service transition.
    /// This is not a plaintext file, diagnostic record or export format.
    pub fn encode_secret(&self) -> Result<zeroize::Zeroizing<Vec<u8>>> {
        validate_previous(&self.previous)?;
        self.feed.validate()?;
        let mut bytes = zeroize::Zeroizing::new(Vec::with_capacity(318));
        bytes.extend_from_slice(b"ACR2");
        bytes.extend_from_slice(self.previous.scope.membership.bytes_for_checkpoint());
        bytes.extend_from_slice(self.previous.scope.dataset.bytes_for_checkpoint());
        bytes.extend_from_slice(&self.previous.key_epoch.to_be_bytes());
        bytes.push(u8::from(self.previous.key_material_changed));
        bytes.extend_from_slice(self.scope.membership.bytes_for_checkpoint());
        bytes.extend_from_slice(self.scope.dataset.bytes_for_checkpoint());
        bytes.extend_from_slice(self.feed.epoch.as_bytes());
        bytes.extend_from_slice(&self.feed.key_epoch.to_be_bytes());
        if self.nonce == [0; 16] {
            return Err(Failure::InvalidReceipt);
        }
        bytes.extend_from_slice(&self.nonce);
        for count in [
            self.summary.local_records,
            self.summary.local_intents,
            self.summary.preservation_copies,
            self.summary.previous_confirmations,
        ] {
            if count > 1_000_000 {
                return Err(Failure::InvalidReceipt);
            }
            bytes.extend_from_slice(&(count as u64).to_be_bytes());
        }
        if !crate::wire::device(
            std::str::from_utf8(&self.device).map_err(|_| Failure::InvalidReceipt)?,
        ) || self.device == *b"00000000"
        {
            return Err(Failure::InvalidReceipt);
        }
        bytes.push(u8::from(self.source_present));
        bytes.extend_from_slice(&self.primary_hash);
        bytes.extend_from_slice(&self.source_hash);
        bytes.extend_from_slice(&self.target_hash);
        bytes.extend_from_slice(&self.device);
        Ok(bytes)
    }
    pub fn decode_secret(root: PathBuf, bytes: &[u8]) -> Result<Self> {
        if bytes.len() != 318 || &bytes[..4] != b"ACR2" {
            return Err(Failure::InvalidReceipt);
        }
        struct Reader<'a>(&'a [u8]);
        impl Reader<'_> {
            fn take<const N: usize>(&mut self) -> Result<[u8; N]> {
                if self.0.len() < N {
                    return Err(Failure::InvalidReceipt);
                }
                let (value, rest) = self.0.split_at(N);
                self.0 = rest;
                value.try_into().map_err(|_| Failure::InvalidReceipt)
            }
            fn scope(&mut self) -> Result<Scope> {
                Ok(Scope {
                    membership: crate::cloud::Binding::from_checkpoint(self.take()?),
                    dataset: crate::cloud::Binding::from_checkpoint(self.take()?),
                })
            }
            fn count(&mut self) -> Result<usize> {
                let value = u64::from_be_bytes(self.take()?);
                if value > 1_000_000 {
                    return Err(Failure::InvalidReceipt);
                }
                usize::try_from(value).map_err(|_| Failure::InvalidReceipt)
            }
        }
        let mut reader = Reader(&bytes[4..]);
        let old_scope = reader.scope()?;
        let old_epoch = u64::from_be_bytes(reader.take()?);
        let key_material_changed = match reader.take::<1>()?[0] {
            0 => false,
            1 => true,
            _ => return Err(Failure::InvalidReceipt),
        };
        let scope = reader.scope()?;
        let feed = Feed::new(
            uuid::Uuid::from_bytes(reader.take()?),
            u64::from_be_bytes(reader.take()?),
        )?;
        let nonce = reader.take()?;
        let summary = Summary {
            local_records: reader.count()?,
            local_intents: reader.count()?,
            preservation_copies: reader.count()?,
            previous_confirmations: reader.count()?,
        };
        let source_present = match reader.take::<1>()?[0] {
            0 => false,
            1 => true,
            _ => return Err(Failure::InvalidReceipt),
        };
        let primary_hash = reader.take()?;
        let source_hash = reader.take()?;
        let target_hash = reader.take()?;
        let device = reader.take()?;
        let receipt = Self {
            root,
            previous: Previous {
                scope: old_scope,
                key_epoch: old_epoch,
                key_material_changed,
            },
            scope,
            feed,
            nonce,
            summary,
            source_present,
            primary_hash,
            source_hash,
            target_hash,
            device,
        };
        if !reader.0.is_empty() || receipt.encode_secret()?.as_slice() != bytes {
            return Err(Failure::InvalidReceipt);
        }
        Ok(receipt)
    }
}

fn unchanged_scope(previous: &Previous, scope: &Scope, feed: &Feed) -> bool {
    previous.scope == *scope
        && previous.key_epoch == feed.key_epoch
        && !previous.key_material_changed
}
fn validate_previous(previous: &Previous) -> Result<()> {
    if previous.key_epoch == 0 || previous.key_epoch > i64::MAX as u64 {
        return Err(Failure::InvalidReceipt);
    }
    Ok(())
}
pub(crate) fn require_complete_primary(
    journal: &journal::Journal,
    snapshot: &primary::Snapshot,
) -> Result<()> {
    let known = journal.projection_knowledge();
    for envelope in known.values().chain(journal.projected().values()) {
        if !snapshot.has_file(envelope.secure)
            || !envelope.deleted
                && !snapshot.records.contains_key(&envelope.id)
                && !journal.known_absence(envelope.id)
        {
            return Err(Failure::LocalAbsence);
        }
    }
    Ok(())
}

impl Owner<'_> {
    pub fn prepare_account_review(
        &self,
        remote: &mut impl Remote,
        previous: Previous,
    ) -> Result<Review> {
        validate_previous(&previous)?;
        let observed = self.preflight(remote)?;
        if unchanged_scope(&previous, self.scope, &observed.feed) {
            return Err(Failure::Unavailable);
        }
        // The retained old key owner supplies this exact old pin. Recovery
        // finishes an already authorized local WAL without using its old cursor
        // or replaying a packet against the newly admitted remote library.
        primary::recover_checked(
            &self.library.root,
            self.checkpoint_key,
            self.checkpoint_salt,
            previous.scope.clone(),
            |journal| check_epoch(journal, previous.key_epoch),
        )?;
        (self.validate_session)()?;
        let source = Checkpoint::load(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            previous.scope.clone(),
        )?;
        check_epoch(&source.journal, previous.key_epoch)?;
        let device = self.local_device(&source)?;
        let snapshot = {
            let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
            let saved = Checkpoint::load_locked(
                self.library,
                self.checkpoint_key,
                self.checkpoint_salt,
                previous.scope.clone(),
            )?;
            if !source.same_snapshot(&saved) {
                return Err(Failure::Changed);
            }
            primary::snapshot_locked(self.library, &source.journal, &device)?
        };
        require_complete_primary(&source.journal, &snapshot)?;
        let mut target = source.journal.clone();
        target.resume_scope(&snapshot.records, self.scope.clone(), observed.feed.clone())?;
        let summary = Summary {
            local_records: snapshot.records.len(),
            local_intents: snapshot
                .records
                .keys()
                .chain(target.projection_knowledge().keys())
                .copied()
                .collect::<std::collections::BTreeSet<_>>()
                .len(),
            preservation_copies: source.journal.conflict_snapshots().len(),
            previous_confirmations: source.journal.agreed_envelopes().len(),
        };
        let source_image = source.encrypted_image(self.checkpoint_key, self.checkpoint_salt)?;
        // Seal the reset journal rather than returning the source's cached
        // encrypted image. The binary schema remains Linux-only.
        let target_image =
            Checkpoint::seal_journal(&target, self.checkpoint_key, self.checkpoint_salt)?;
        let after = self.preflight(remote)?;
        if after.feed != observed.feed {
            return Err(Failure::Changed);
        }
        Ok(Review {
            receipt: Receipt {
                root: self.library.root.clone(),
                previous,
                scope: self.scope.clone(),
                feed: observed.feed,
                nonce: crypto::random().map_err(|_| journal::Failure::Storage)?,
                summary,
                source_present: source.has_snapshot(),
                primary_hash: snapshot.review_fingerprint(),
                source_hash: Sha256::digest(&source_image).into(),
                target_hash: Sha256::digest(&target_image).into(),
                device: device
                    .as_bytes()
                    .try_into()
                    .map_err(|_| Failure::InvalidReceipt)?,
            },
            source,
            snapshot,
            device,
            source_image,
            target_image,
        })
    }
    pub fn resume_account_review(
        &self,
        remote: &mut impl Remote,
        review: Review,
    ) -> Result<Summary> {
        self.resume_account_review_inner(remote, review, None)
    }
    fn check_review_receipt(&self, receipt: &Receipt) -> Result<()> {
        receipt.encode_secret()?;
        if receipt.root != self.library.root
            || receipt.scope != *self.scope
            || receipt.feed.key_epoch != self.key_epoch
        {
            return Err(receiver::Failure::ScopeReview.into());
        }
        Ok(())
    }
    /// Retain both frozen encrypted images before the key owner records consent.
    /// Staging changes no active checkpoint or key slot. Orphan images are kept
    /// when the subsequent Secret Service write fails; they do not grant consent.
    pub fn stage_account_review(
        &self,
        remote: &mut impl Remote,
        review: &Review,
    ) -> Result<Summary> {
        self.check_review_receipt(&review.receipt)?;
        let observed = self.preflight(remote)?;
        if observed.feed != review.receipt.feed {
            return Err(Failure::Changed);
        }
        let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
        let saved = Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            review.receipt.previous.scope.clone(),
        )?;
        check_epoch(&saved.journal, review.receipt.previous.key_epoch)?;
        if !saved.same_snapshot(&review.source)
            || primary::snapshot_locked(self.library, &saved.journal, &review.device)?
                != review.snapshot
            || Sha256::digest(&review.source_image).as_slice() != review.receipt.source_hash
            || Sha256::digest(&review.target_image).as_slice() != review.receipt.target_hash
        {
            return Err(Failure::Changed);
        }
        retain_images(self.library, review, None)?;
        (self.validate_session)()?;
        if primary::snapshot_locked(self.library, &saved.journal, &review.device)?
            != review.snapshot
        {
            return Err(Failure::Changed);
        }
        Ok(review.receipt.summary)
    }
    /// Resume only a durably confirmed receipt. Before publication, the exact
    /// original checkpoint and both complete primary file images must still
    /// match. After publication, recognize the frozen target without another
    /// reset, even if the server has since rotated its feed.
    pub fn continue_account_review(
        &self,
        remote: &mut impl Remote,
        receipt: &Receipt,
    ) -> Result<Summary> {
        self.check_review_receipt(receipt)?;
        let observed = self.preflight(remote)?;
        let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
        let (source, target) = self
            .retained_review_locked(receipt)?
            .ok_or(Failure::InvalidReceipt)?;
        let current_target = Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
        );
        match current_target {
            Ok(saved) if target.same_snapshot(&saved) => {
                check_epoch(&saved.journal, self.key_epoch)?;
                primary::require_ready(&self.library.root)
                    .map_err(|_| primary::Failure::RecoveryRequired)?;
                (self.validate_session)()?;
                return Ok(receipt.summary);
            }
            Ok(_) | Err(journal::Failure::ScopeReview) => (),
            Err(error) => return Err(error.into()),
        }
        if observed.feed != receipt.feed {
            return Err(Failure::Changed);
        }
        let mut saved = Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            receipt.previous.scope.clone(),
        )?;
        check_epoch(&saved.journal, receipt.previous.key_epoch)?;
        if saved.has_snapshot() != receipt.source_present
            || receipt.source_present && !saved.same_snapshot(&source)
            || !receipt.source_present && saved.journal != source.journal
        {
            return Err(Failure::Changed);
        }
        let device = std::str::from_utf8(&receipt.device).map_err(|_| Failure::InvalidReceipt)?;
        let snapshot = primary::snapshot_locked(self.library, &saved.journal, device)?;
        require_complete_primary(&saved.journal, &snapshot)?;
        let mut expected = saved.journal.clone();
        expected.resume_scope(&snapshot.records, self.scope.clone(), receipt.feed.clone())?;
        if snapshot.review_fingerprint() != receipt.primary_hash || expected != target.journal {
            return Err(Failure::Changed);
        }
        (self.validate_session)()?;
        // The guard may perform keyring I/O; a cooperative writer cannot race
        // this lock, and a noncooperative writer is checked again afterwards.
        if primary::snapshot_locked(self.library, &saved.journal, device)? != snapshot {
            return Err(Failure::Changed);
        }
        saved.publish_replacement_locked(self.library, target)?;
        (self.validate_session)()?;
        Ok(receipt.summary)
    }
    pub(crate) fn retained_review_locked(
        &self,
        receipt: &Receipt,
    ) -> Result<Option<(Checkpoint, Checkpoint)>> {
        let directory = archive_directory(self.library, false)?;
        let source = read_image(&image_path(&directory, &receipt.nonce, "source"))?;
        let target = read_image(&image_path(&directory, &receipt.nonce, "target"))?;
        let Some(source) = source else {
            return if target.is_none() {
                Ok(None)
            } else {
                Err(Failure::InvalidReceipt)
            };
        };
        if Sha256::digest(&source).as_slice() != receipt.source_hash {
            return Err(Failure::InvalidReceipt);
        }
        let source = Checkpoint::from_encrypted(
            source,
            self.checkpoint_key,
            self.checkpoint_salt,
            receipt.previous.scope.clone(),
        )?;
        check_epoch(&source.journal, receipt.previous.key_epoch)?;
        let Some(target) = target else {
            return Ok(None);
        };
        if Sha256::digest(&target).as_slice() != receipt.target_hash {
            return Err(Failure::InvalidReceipt);
        }
        let target = Checkpoint::from_encrypted(
            target,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
        )?;
        check_epoch(&target.journal, self.key_epoch)?;
        let mut expected = source.journal.clone();
        expected.resume_scope(
            target.journal.projected(),
            self.scope.clone(),
            receipt.feed.clone(),
        )?;
        if expected != target.journal {
            return Err(Failure::InvalidReceipt);
        }
        Ok(Some((source, target)))
    }
    /// Caller holds the common library lock. Authenticate the complete saved
    /// reset before classifying the active ciphertext's opaque digest. The
    /// digest is process-local and never persisted, displayed or returned.
    pub(crate) fn inspect_retained_history_locked(
        &self,
        receipt: &Receipt,
        active: std::result::Result<Option<[u8; 32]>, ()>,
    ) -> Result<RetainedImages> {
        self.check_review_receipt(receipt)?;
        (self.validate_session)()?;
        let result = match self.retained_review_locked(receipt) {
            Ok(Some(_)) => RetainedImages::Verified {
                active: match active {
                    Ok(Some(hash)) if hash == receipt.source_hash => ActiveImage::Source,
                    Ok(Some(hash)) if hash == receipt.target_hash => ActiveImage::Target,
                    Ok(Some(_)) => ActiveImage::Other,
                    Ok(None) => ActiveImage::Missing,
                    Err(()) => ActiveImage::Unreadable,
                },
            },
            Ok(None) => RetainedImages::Missing,
            Err(Failure::Data(receiver::Failure::Journal(journal::Failure::Storage))) => {
                RetainedImages::Unreadable
            }
            Err(_) => RetainedImages::Invalid,
        };
        (self.validate_session)()?;
        Ok(result)
    }
    /// Authenticated local data from the fully reviewed target image. No remote
    /// cursors, offers, permissions or CAS from it may enter the active journal.
    pub(crate) fn retained_local_state_locked(
        &self,
        receipt: &Receipt,
    ) -> Result<journal::Journal> {
        self.check_review_receipt(receipt)?;
        (self.validate_session)()?;
        let (_, target) = self
            .retained_review_locked(receipt)?
            .ok_or(Failure::InvalidReceipt)?;
        (self.validate_session)()?;
        Ok(target.journal)
    }
    fn resume_account_review_inner(
        &self,
        remote: &mut impl Remote,
        mut review: Review,
        fault: Option<u8>,
    ) -> Result<Summary> {
        self.check_review_receipt(&review.receipt)?;
        let observed = self.preflight(remote)?;
        if observed.feed != review.receipt.feed {
            return Err(Failure::Changed);
        }
        (self.validate_session)()?;
        let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
        let saved = Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            review.receipt.previous.scope.clone(),
        )?;
        check_epoch(&saved.journal, review.receipt.previous.key_epoch)?;
        if !saved.same_snapshot(&review.source) {
            return Err(Failure::Changed);
        }
        let snapshot = primary::snapshot_locked(self.library, &saved.journal, &review.device)?;
        if snapshot != review.snapshot {
            return Err(Failure::Changed);
        }
        require_complete_primary(&saved.journal, &snapshot)?;
        let target = Checkpoint::from_encrypted(
            review.target_image.clone(),
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
        )?;
        check_epoch(&target.journal, self.key_epoch)?;
        if fault == Some(0) {
            return Err(journal::Failure::Storage.into());
        }
        retain_images(self.library, &review, fault)?;
        (self.validate_session)()?;
        let after = primary::snapshot_locked(self.library, &saved.journal, &review.device)?;
        if after != review.snapshot {
            return Err(Failure::Changed);
        }
        if fault == Some(3) {
            return Err(journal::Failure::Storage.into());
        }
        review
            .source
            .publish_replacement_locked(self.library, target)?;
        if fault == Some(4) {
            return Err(journal::Failure::Storage.into());
        }
        (self.validate_session)()?;
        Ok(review.receipt.summary)
    }
    /// A lost disk/key-store reply cannot justify resetting a second time. The
    /// pending key transition retains this receipt and authenticates both saved
    /// images before recognizing the exact already-published new checkpoint.
    pub fn account_review_applied(
        &self,
        remote: &mut impl Remote,
        receipt: &Receipt,
    ) -> Result<bool> {
        self.check_review_receipt(receipt)?;
        self.preflight(remote)?;
        self.account_review_published_local(receipt)
    }
    /// Read-only local proof for an already confirmed transition. It grants no
    /// server/key admission and never publishes or replaces a checkpoint.
    pub(crate) fn account_review_published_local(&self, receipt: &Receipt) -> Result<bool> {
        self.check_review_receipt(receipt)?;
        (self.validate_session)()?;
        let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
        self.account_review_published_local_locked(receipt)
    }
    /// The caller holds the common library lock, including across key-slot
    /// completion. Authenticate both retained images and the exact active target.
    pub(crate) fn account_review_published_local_locked(&self, receipt: &Receipt) -> Result<bool> {
        self.check_review_receipt(receipt)?;
        (self.validate_session)()?;
        let Some((_, target)) = self.retained_review_locked(receipt)? else {
            return Ok(false);
        };
        let saved = match Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
        ) {
            Ok(saved) => saved,
            Err(journal::Failure::ScopeReview) => return Ok(false),
            Err(error) => return Err(error.into()),
        };
        (self.validate_session)()?;
        let applied = target.same_snapshot(&saved);
        if applied {
            check_epoch(&saved.journal, self.key_epoch)?;
            primary::require_ready(&self.library.root)
                .map_err(|_| primary::Failure::RecoveryRequired)?;
        }
        Ok(applied)
    }
    /// Local cancellation needs no remote credentials. Prove the exact original
    /// checkpoint remains active; changed primary files are allowed because no
    /// reset will be published and no local intent or active key is changed.
    pub(crate) fn account_review_unpublished(&self, receipt: &Receipt) -> Result<bool> {
        self.check_review_receipt(receipt)?;
        (self.validate_session)()?;
        let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
        let (source, target) = self
            .retained_review_locked(receipt)?
            .ok_or(Failure::InvalidReceipt)?;
        match Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
        ) {
            Ok(saved) if target.same_snapshot(&saved) => return Ok(false),
            Ok(_) | Err(journal::Failure::ScopeReview) => (),
            Err(error) => return Err(error.into()),
        }
        let saved = Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            receipt.previous.scope.clone(),
        )?;
        check_epoch(&saved.journal, receipt.previous.key_epoch)?;
        if saved.has_snapshot() != receipt.source_present
            || receipt.source_present && !saved.same_snapshot(&source)
            || !receipt.source_present && saved.journal != source.journal
        {
            return Err(Failure::Changed);
        }
        primary::require_ready(&self.library.root)
            .map_err(|_| primary::Failure::RecoveryRequired)?;
        (self.validate_session)()?;
        Ok(true)
    }
}

const MAX_REVIEW_FILES: usize = 32;
const MAX_REVIEW_BYTES: u64 = 512 * 1024 * 1024;
pub(crate) fn archive_directory(library: &model::Library, create: bool) -> Result<PathBuf> {
    let sync = library.root.join("Sync");
    let directory = sync.join("Reviews");
    for path in [&sync, &directory] {
        match fs::symlink_metadata(path) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if !create {
                    return Ok(directory.clone());
                }
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(path)
                    .map_err(|_| journal::Failure::Storage)?;
                fs::File::open(path.parent().ok_or(journal::Failure::Storage)?)
                    .and_then(|file| file.sync_all())
                    .map_err(|_| journal::Failure::Storage)?;
            }
            _ => return Err(journal::Failure::Storage.into()),
        }
        if create {
            fs::set_permissions(path, fs::Permissions::from_mode(0o700))
                .map_err(|_| journal::Failure::Storage)?;
        }
    }
    Ok(directory)
}
pub(crate) fn image_path(directory: &Path, nonce: &[u8; 16], kind: &str) -> PathBuf {
    let opaque: String = nonce.iter().map(|byte| format!("{byte:02x}")).collect();
    directory.join(format!("{opaque}.{kind}"))
}
pub(crate) fn read_image(path: &Path) -> Result<Option<Vec<u8>>> {
    Ok(
        model::read_regular_bounded(path, crypto::MAX_CHECKPOINT_BYTES + 32)
            .map_err(|_| journal::Failure::Storage)?,
    )
}
fn retain_images(library: &model::Library, review: &Review, fault: Option<u8>) -> Result<()> {
    retain_pair_locked(
        library,
        &review.receipt.nonce,
        &review.source_image,
        &review.target_image,
        fault,
    )
}
pub(crate) fn retain_pair_locked(
    library: &model::Library,
    nonce: &[u8; 16],
    source: &Vec<u8>,
    target: &Vec<u8>,
    fault: Option<u8>,
) -> Result<()> {
    let directory = archive_directory(library, true)?;
    let source_path = image_path(&directory, nonce, "source");
    let target_path = image_path(&directory, nonce, "target");
    let copies = [(&source_path, source), (&target_path, target)];
    let mut count = 0usize;
    let mut bytes = 0u64;
    for entry in fs::read_dir(&directory).map_err(|_| journal::Failure::Storage)? {
        let entry = entry.map_err(|_| journal::Failure::Storage)?;
        let name = entry.file_name();
        let name = name.to_str().ok_or(journal::Failure::Storage)?;
        let name = name.as_bytes();
        if name.len() != 39
            || !name[..32]
                .iter()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
            || ![b".source".as_slice(), b".target".as_slice()].contains(&&name[32..])
        {
            return Err(journal::Failure::Storage.into());
        }
        let metadata = fs::symlink_metadata(entry.path()).map_err(|_| journal::Failure::Storage)?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(journal::Failure::Storage.into());
        }
        count = count.checked_add(1).ok_or(Failure::RetentionFull)?;
        bytes = bytes
            .checked_add(metadata.len())
            .ok_or(Failure::RetentionFull)?;
        if count > MAX_REVIEW_FILES || bytes > MAX_REVIEW_BYTES {
            return Err(Failure::RetentionFull);
        }
    }
    for (path, image) in copies {
        match read_image(path)? {
            Some(existing) if existing == *image => (),
            Some(_) => return Err(Failure::Changed),
            None => {
                count += 1;
                bytes = bytes
                    .checked_add(image.len() as u64)
                    .ok_or(Failure::RetentionFull)?;
            }
        }
    }
    if count > MAX_REVIEW_FILES || bytes > MAX_REVIEW_BYTES {
        return Err(Failure::RetentionFull);
    }
    for (index, (path, image)) in copies.into_iter().enumerate() {
        match read_image(path)? {
            Some(existing) if existing == *image => (),
            Some(_) => return Err(Failure::Changed),
            None => model::atomic_write(path, image).map_err(|_| journal::Failure::Storage)?,
        }
        if fault == Some(index as u8 + 1) {
            return Err(journal::Failure::Storage.into());
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "account_review_tests.rs"]
mod tests;
