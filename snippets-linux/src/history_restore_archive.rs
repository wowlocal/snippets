//! Small protected receipts; complete before/after payloads remain encrypted
//! under the per-install checkpoint key in the shared non-evicting image store.
use super::*;
use crate::{
    local_auth::{Purpose, Target},
    model::Library,
};

const LIMIT: usize = 8;
pub(super) struct Entry {
    pub phase: Phase,
    pub binding: KeyBinding,
    pub saved_binding: KeyBinding,
    pub selection: Selection,
    pub nonce: [u8; 16],
    pub source_hash: [u8; 32],
    pub target_hash: [u8; 32],
    pub inputs_hash: [u8; 32],
    pub summary: Summary,
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Phase {
    Pending,
    Completed,
    Cancelled,
}
impl Phase {
    fn text(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
        }
    }
}
impl Entry {
    fn value(&self, phase: Phase) -> Result<Value> {
        if self.nonce == [0; 16] || self.summary.restored_records == 0 {
            return Err(super::super::Failure::InvalidState.into());
        }
        let bounded = |n: usize| {
            i64::try_from(n)
                .map(Value::Int)
                .map_err(|_| Failure::Key(super::super::Failure::InvalidState))
        };
        Ok(object([
            ("phase", Value::text(phase.text())),
            ("binding", self.binding.value()),
            ("savedBinding", self.saved_binding.value()),
            (
                "savedTransition",
                Value::text(STANDARD.encode(self.selection.transition)),
            ),
            (
                "savedHistoryHash",
                Value::text(STANDARD.encode(self.selection.history_hash)),
            ),
            ("nonce", Value::text(STANDARD.encode(self.nonce))),
            ("sourceHash", Value::text(STANDARD.encode(self.source_hash))),
            ("targetHash", Value::text(STANDARD.encode(self.target_hash))),
            ("inputsHash", Value::text(STANDARD.encode(self.inputs_hash))),
            (
                "summary",
                object([
                    ("restored", bounded(self.summary.restored_records)?),
                    ("preserved", bounded(self.summary.preserved_versions)?),
                    ("added", bounded(self.summary.added_records)?),
                    ("secure", bounded(self.summary.secure_records)?),
                ]),
            ),
        ]))
    }
    fn parse(value: &Value) -> Result<Self> {
        let fields = exact(
            value,
            &[
                "phase",
                "binding",
                "savedBinding",
                "savedTransition",
                "savedHistoryHash",
                "nonce",
                "sourceHash",
                "targetHash",
                "inputsHash",
                "summary",
            ],
        )?;
        let summary = exact(
            &fields["summary"],
            &["restored", "preserved", "added", "secure"],
        )?;
        let count = |key: &str| {
            usize::try_from(summary[key].as_int()?).map_err(|_| super::super::Failure::InvalidState)
        };
        let entry = Self {
            phase: match fields["phase"].as_text()? {
                "pending" => Phase::Pending,
                "completed" => Phase::Completed,
                "cancelled" => Phase::Cancelled,
                _ => return Err(super::super::Failure::InvalidState.into()),
            },
            binding: KeyBinding::parse(&fields["binding"])?,
            saved_binding: KeyBinding::parse(&fields["savedBinding"])?,
            selection: Selection {
                transition: array(fields["savedTransition"].as_text()?)?,
                history_hash: array(fields["savedHistoryHash"].as_text()?)?,
            },
            nonce: array(fields["nonce"].as_text()?)?,
            source_hash: array(fields["sourceHash"].as_text()?)?,
            target_hash: array(fields["targetHash"].as_text()?)?,
            inputs_hash: array(fields["inputsHash"].as_text()?)?,
            summary: Summary {
                restored_records: count("restored")?,
                preserved_versions: count("preserved")?,
                added_records: count("added")?,
                secure_records: count("secure")?,
            },
        };
        if entry.summary.added_records > entry.summary.restored_records
            || entry.summary.secure_records > entry.summary.restored_records
        {
            return Err(super::super::Failure::InvalidState.into());
        }
        entry.value(entry.phase)?;
        Ok(entry)
    }
    pub fn target(&self, purpose: Purpose, generation: i64) -> Result<Target> {
        let mut hash = Sha256::new();
        hash.update(b"Snippets saved changes authorization v1\0");
        hash.update(self.value(self.phase)?.encode()?.as_slice());
        Ok(Target::new(
            self.binding.clone(),
            purpose,
            generation,
            hash.finalize().into(),
        )?)
    }
    pub fn retained(
        &self,
        library: &Library,
        material: &[u8],
    ) -> Result<primary::frozen::Transaction> {
        if material.len() != 64 {
            return Err(super::super::Failure::InvalidState.into());
        }
        let key = RootKey::from_bytes(&material[..32])
            .map_err(|_| super::super::Failure::InvalidState)?;
        let salt = material[32..]
            .try_into()
            .map_err(|_| super::super::Failure::InvalidState)?;
        let directory = crate::account_review::archive_directory(library, false)?;
        let read = |kind, expected: [u8; 32]| -> Result<crate::journal::Checkpoint> {
            let image = crate::account_review::read_image(&crate::account_review::image_path(
                &directory,
                &self.nonce,
                kind,
            ))?
            .ok_or(Failure::Unavailable)?;
            if Sha256::digest(&image).as_slice() != expected {
                return Err(Failure::Changed);
            }
            Ok(crate::journal::Checkpoint::from_encrypted(
                image,
                &key,
                &salt,
                self.binding.checkpoint_scope(),
            )?)
        };
        let source = read("source", self.source_hash)?;
        let target = read("target", self.target_hash)?;
        if source.journal.key_epoch != Some(self.binding.epoch)
            || target.journal.key_epoch != Some(self.binding.epoch)
        {
            return Err(Failure::Changed);
        }
        let transaction =
            primary::frozen::Transaction::from_retained(source.journal, target.journal)?;
        if transaction.nonce() != self.nonce {
            return Err(Failure::Changed);
        }
        Ok(transaction)
    }
}
pub(super) struct Archive {
    pub generation: i64,
    pub entries: Vec<Entry>,
    pub snapshot: Option<Zeroizing<Vec<u8>>>,
}
impl Archive {
    pub fn ensure_capacity(&self) -> Result<()> {
        if self.entries.len() >= LIMIT || self.generation.checked_add(2).is_none() {
            return Err(Failure::RetentionFull);
        }
        Ok(())
    }
    pub fn load<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Self> {
        let snapshot = owner.read(Slot::HistoryRestore)?;
        let mut archive = Self {
            generation: 0,
            entries: Vec::new(),
            snapshot,
        };
        if let Some(bytes) = &archive.snapshot {
            let value = canonical::parse(bytes)?;
            let fields = exact(&value, &["schema", "generation", "entries"])?;
            let values = fields["entries"].as_array()?;
            archive.generation = fields["generation"].as_int()?;
            if fields["schema"].as_int()? != 1
                || archive.generation < 1
                || values.is_empty()
                || values.len() > LIMIT
            {
                return Err(super::super::Failure::InvalidState.into());
            }
            let mut seen = std::collections::BTreeSet::new();
            for (index, value) in values.iter().enumerate() {
                let entry = Entry::parse(value)?;
                if !seen.insert(entry.nonce)
                    || entry.phase == Phase::Pending && index + 1 != values.len()
                {
                    return Err(super::super::Failure::InvalidState.into());
                }
                archive.entries.push(entry);
            }
        }
        Ok(archive)
    }
    pub fn pending(&self) -> Option<&Entry> {
        self.entries
            .last()
            .filter(|entry| entry.phase == Phase::Pending)
    }
    pub fn encoded(
        &self,
        append: Option<&Entry>,
        phase: Option<Phase>,
        increments: i64,
    ) -> Result<Zeroizing<Vec<u8>>> {
        if self.entries.len() + usize::from(append.is_some()) > LIMIT {
            return Err(Failure::RetentionFull);
        }
        let generation = self
            .generation
            .checked_add(increments)
            .ok_or(Failure::RetentionFull)?;
        let mut values = Vec::new();
        let total = self.entries.len() + usize::from(append.is_some());
        for (index, entry) in self.entries.iter().chain(append).enumerate() {
            values.push(entry.value(if index + 1 == total {
                phase.unwrap_or(entry.phase)
            } else {
                entry.phase
            })?);
        }
        let bytes = object([
            ("schema", Value::Int(1)),
            ("generation", Value::Int(generation)),
            ("entries", Value::Array(values)),
        ])
        .encode()?;
        if bytes.len() > secret_store::MAX_SECRET_BYTES {
            return Err(Failure::RetentionFull);
        }
        Ok(bytes)
    }
}
