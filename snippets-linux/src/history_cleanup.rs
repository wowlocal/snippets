//! Explicit, resumable discard of unreferenced framed recovery images.
//! Protected typed archives determine references; no cleanup occurs on inspect.
use super::*;
use std::collections::BTreeSet;

struct References {
    frame: [u8; 32],
    nonces: BTreeSet<[u8; 16]>,
}
fn references<B: Backend>(owner: &mut Locked<'_, B>) -> Result<References> {
    let mut digest = Sha256::new();
    digest.update(b"Snippets recovery image references v1\0");
    let mut nonces = BTreeSet::new();
    for section in [
        Section::Switches,
        Section::Restorations,
        Section::Pairing,
        Section::FirstKeys,
        Section::Creations,
    ] {
        digest.update(section.text().as_bytes());
        let snapshot = owner.read(section.slot())?;
        digest.update((snapshot.as_ref().map_or(0, |bytes| bytes.len()) as u64).to_be_bytes());
        if let Some(snapshot) = snapshot {
            let document = document(owner, section)?;
            if document.snapshot.as_slice() != snapshot.as_slice() {
                return Err(Failure::ReviewRequired);
            }
            digest.update(snapshot.as_slice());
            for row in document.rows {
                if let Some(images) = row.images {
                    nonces.insert(images.nonce);
                }
            }
        }
    }
    Ok(References {
        frame: digest.finalize().into(),
        nonces,
    })
}
struct CleanupIntent {
    binding: KeyBinding,
    frame: [u8; 32],
    references: [u8; 32],
    nonce: [u8; 16],
    proofs: Vec<files::Proof>,
}
impl CleanupIntent {
    fn bytes(&self) -> Result<Zeroizing<Vec<u8>>> {
        Ok(object([
            ("schema", Value::Int(2)),
            ("kind", Value::text("unusedRecoveryFiles")),
            ("binding", self.binding.value()),
            ("frame", Value::text(STANDARD.encode(self.frame))),
            ("references", Value::text(STANDARD.encode(self.references))),
            ("nonce", Value::text(STANDARD.encode(self.nonce))),
            (
                "images",
                Value::Array(self.proofs.iter().map(files::Proof::value).collect()),
            ),
        ])
        .encode()?)
    }
    fn parse(bytes: &[u8]) -> Result<Self> {
        let value = canonical::parse(bytes)?;
        let fields = exact(
            &value,
            &[
                "schema",
                "kind",
                "binding",
                "frame",
                "references",
                "nonce",
                "images",
            ],
        )?;
        let array = |name: &str, length| -> Result<Zeroizing<Vec<u8>>> {
            decode64(fields[name].as_text()?, length)
        };
        let nonce = array("nonce", 16)?
            .as_slice()
            .try_into()
            .map_err(|_| Failure::InvalidState)?;
        let proofs = fields["images"]
            .as_array()?
            .iter()
            .map(files::Proof::parse)
            .collect::<Result<Vec<_>>>()?;
        if fields["schema"].as_int()? != 2
            || fields["kind"].as_text()? != "unusedRecoveryFiles"
            || nonce == [0; 16]
            || proofs.is_empty()
            || proofs.len() > 32
            || proofs.iter().any(|proof| proof.length() < 32)
            || proofs
                .windows(2)
                .any(|pair| (pair[0].nonce, pair[0].kind) >= (pair[1].nonce, pair[1].kind))
            || proofs.iter().map(files::Proof::length).sum::<u64>() > 512 * 1024 * 1024
        {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            binding: KeyBinding::parse(&fields["binding"])?,
            frame: array("frame", 32)?
                .as_slice()
                .try_into()
                .map_err(|_| Failure::InvalidState)?,
            references: array("references", 32)?
                .as_slice()
                .try_into()
                .map_err(|_| Failure::InvalidState)?,
            nonce,
            proofs,
        })
    }
    fn summary(&self) -> Summary {
        Summary {
            libraries: vec![history::SavedLibrary::new(&self.binding)],
            section: Section::UnusedImages,
            entry: 0,
            protected_bytes: 0,
            encrypted_images: self.proofs.len(),
            encrypted_bytes: self.proofs.iter().map(files::Proof::length).sum(),
        }
    }
    fn target(&self, resume: bool) -> Result<Target> {
        let mut digest = Sha256::new();
        digest.update(b"Snippets explicit unused recovery file cleanup v1\0");
        digest.update(self.bytes()?.as_slice());
        Ok(Target::new(
            self.binding.clone(),
            if resume {
                Purpose::ResumeRecoveryFileCleanup
            } else {
                Purpose::RemoveUnusedRecoveryFiles
            },
            1,
            digest.finalize().into(),
        )?)
    }
}
pub struct CleanupReview {
    intent: CleanupIntent,
    resume: bool,
}
impl CleanupReview {
    pub(super) fn summary(&self) -> Summary {
        self.intent.summary()
    }
    pub(super) fn authorization_target(&self) -> Result<Target> {
        self.intent.target(self.resume)
    }
}
pub(super) fn pending_summary(bytes: &[u8]) -> Result<Summary> {
    CleanupIntent::parse(bytes).map(|intent| intent.summary())
}

pub(super) fn prepare<B: Backend>(store: &mut Store<B>) -> Result<Option<CleanupReview>> {
    store.transaction_with(|owner| {
        let library = Library::prepare(owner.root().into())?;
        let _guard = library.lock()?;
        let installed = ready(owner, &library)?;
        let references = references(owner)?;
        let proofs = files::unused(&library, &references.nonces)?;
        if proofs.is_empty() {
            return Ok(None);
        }
        Ok(Some(CleanupReview {
            intent: CleanupIntent {
                binding: installed.binding,
                frame: frame(owner)?,
                references: references.frame,
                nonce: crate::crypto::random().map_err(|_| Failure::InvalidState)?,
                proofs,
            },
            resume: false,
        }))
    })
}
fn verify<B: Backend>(
    owner: &mut Locked<'_, B>,
    library: &Library,
    intent: &CleanupIntent,
    missing: bool,
) -> Result<()> {
    if ready(owner, library)?.binding != intent.binding || frame(owner)? != intent.frame {
        return Err(Failure::ReviewRequired);
    }
    let references = references(owner)?;
    if references.frame != intent.references
        || intent
            .proofs
            .iter()
            .any(|proof| references.nonces.contains(&proof.nonce))
    {
        return Err(Failure::ReviewRequired);
    }
    files::verify(library, &intent.proofs, missing)
}
pub(super) fn resume_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    bytes: &[u8],
) -> Result<CleanupReview> {
    let intent = CleanupIntent::parse(bytes)?;
    let library = Library::prepare(owner.root().into())?;
    let _guard = library.lock()?;
    verify(owner, &library, &intent, true)?;
    Ok(CleanupReview {
        intent,
        resume: true,
    })
}
pub(super) fn apply<B: Backend>(
    store: &mut Store<B>,
    review: CleanupReview,
    lease: &AuthorizationLease,
    fault: Option<u8>,
) -> Result<()> {
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
        verify(owner, &library, &review.intent, review.resume)?;
        lease.check()?;
        if !review.resume {
            owner.replace(Slot::HistoryMaintenance, None, Some(&expected))?;
        }
        fail(fault, 1)?;
        verify(owner, &library, &review.intent, true)?;
        files::remove_unused(&library, &review.intent.proofs, lease, fault)?;
        lease.check()?;
        owner.replace(Slot::HistoryMaintenance, Some(&expected), None)?;
        fail(fault, 35)
    })
}
