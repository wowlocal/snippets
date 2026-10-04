//! Durable recipient-side pairing. Only a persisted invitation can be displayed;
//! only a retained, authenticated claim with a matching authority can install a key.
use super::*;
use crate::{
    bootstrap::{Invitation, PairingDraft, PendingPairing},
    cloud::{Pairing, PairingState},
};

pub enum Outcome {
    Waiting(Invitation),
    CreationUnconfirmed,
    Ready { kit: KitStatus },
    Cancelled,
}
/// Last durable step only, never a claim of live account/key/sync readiness.
pub enum RetainedStatus {
    Creating,
    Waiting {
        invitation: Invitation,
        received: bool,
    },
    Cancelling,
    Inactive,
}
/// No network, key installation or secret disclosure. The UI may show the saved
/// public invitation/countdown during network trouble, including after restart.
pub fn inspect_retained<B: Backend>(
    store: &mut Store<B>,
    remote: &BoundTransport,
) -> super::Result<Option<RetainedStatus>> {
    let binding = remote.key_binding()?;
    store.transaction_with(|owner| inspect_locked(owner, &binding))
}
pub(super) fn inspect_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> super::Result<Option<RetainedStatus>> {
    let Some(journal) = Journal::load(owner)? else {
        return Ok(None);
    };
    journal.check_binding(binding)?;
    Ok(Some(match journal.phase {
        Some(Phase::Creating { .. }) => RetainedStatus::Creating,
        Some(Phase::Waiting(p)) => RetainedStatus::Waiting {
            invitation: p.invitation().clone(),
            received: false,
        },
        Some(Phase::Claimed { pending, .. }) => RetainedStatus::Waiting {
            invitation: pending.invitation().clone(),
            received: true,
        },
        Some(Phase::Cancelling(_)) => RetainedStatus::Cancelling,
        None => RetainedStatus::Inactive,
    }))
}
/// A failed secret write must not turn an already received envelope into a generic
/// error. The caller retains this ownership and retries persistence before polling.
pub struct Rejected {
    pub failure: Failure,
    pub unrecorded: Option<Unrecorded>,
}
pub struct Unrecorded {
    journal: Box<Journal>,
    target: Zeroizing<Vec<u8>>,
}
pub type Result<T> = std::result::Result<T, Rejected>;
impl From<Failure> for Rejected {
    fn from(failure: Failure) -> Self {
        Self {
            failure,
            unrecorded: None,
        }
    }
}
impl From<secret_store::Failure> for Rejected {
    fn from(value: secret_store::Failure) -> Self {
        Failure::from(value).into()
    }
}
impl From<bootstrap::Failure> for Rejected {
    fn from(value: bootstrap::Failure) -> Self {
        Failure::from(value).into()
    }
}
impl Unrecorded {
    /// Keeps ownership on every failure. The exact previous snapshot and target
    /// prevent a stale receipt from overwriting a cancelled or newer invitation.
    /// This writes no library key and needs no HTTP or unexpired invitation.
    pub fn retain<B: Backend>(mut self, store: &mut Store<B>) -> Result<()> {
        let result: super::Result<()> = store.transaction_with(|owner| {
            super::handover::require_idle(owner)?;
            let current = owner.read(Slot::PairingRecipient)?;
            if current.as_deref() == Some(&self.target) {
                Journal::load(owner)?.ok_or(Failure::InvalidState)?;
                return Ok(());
            }
            if current != self.journal.snapshot {
                return Err(Failure::Secret(secret_store::Failure::Stale));
            }
            self.journal.save(owner)
        });
        result.map_err(|failure| Rejected {
            failure,
            unrecorded: Some(self),
        })
    }
}

pub(super) enum Phase {
    Creating {
        draft: PairingDraft,
        sent: bool,
    },
    Waiting(PendingPairing),
    Claimed {
        pending: PendingPairing,
        ciphertext: Vec<u8>,
    },
    Cancelling(PendingPairing),
}
impl Phase {
    pub(super) fn value(&self) -> super::Result<Value> {
        let (kind, secret, cipher, sent) = match self {
            Self::Creating { draft, sent } => ("creating", draft.encode_secret()?, None, *sent),
            Self::Waiting(p) => ("waiting", p.encode_secret()?, None, false),
            Self::Claimed {
                pending,
                ciphertext,
            } => ("claimed", pending.encode_secret()?, Some(ciphertext), false),
            Self::Cancelling(p) => ("cancelling", p.encode_secret()?, None, false),
        };
        Ok(object([
            ("kind", Value::text(kind)),
            ("secret", canonical::parse(&secret)?),
            (
                "ciphertext",
                cipher.map_or(Value::Null, |v| Value::text(STANDARD.encode(v))),
            ),
            ("sent", Value::Bool(sent)),
        ]))
    }
    pub(super) fn parse(value: &Value) -> super::Result<Self> {
        let v = exact(value, &["kind", "secret", "ciphertext", "sent"])?;
        let sent = match &v["sent"] {
            Value::Bool(sent) => *sent,
            _ => return Err(Failure::InvalidState),
        };
        let cipher = optional(&v["ciphertext"], |v| {
            Ok(decode64(v.as_text()?, bootstrap::MAX_ENVELOPE_BYTES)?.to_vec())
        })?;
        let secret = v["secret"].encode()?;
        if v["kind"].as_text()? == "creating" && cipher.is_none() {
            return Ok(Self::Creating {
                draft: PairingDraft::decode_secret(&secret)?,
                sent,
            });
        }
        if sent {
            return Err(Failure::InvalidState);
        }
        let pending = PendingPairing::decode_retained_secret(&secret)?;
        match (v["kind"].as_text()?, cipher) {
            ("waiting", None) => Ok(Self::Waiting(pending)),
            ("cancelling", None) => Ok(Self::Cancelling(pending)),
            ("claimed", Some(ciphertext)) => Ok(Self::Claimed {
                pending,
                ciphertext,
            }),
            _ => Err(Failure::InvalidState),
        }
    }
    pub(super) fn validate(&self, binding: &KeyBinding) -> super::Result<()> {
        let pending = match self {
            Self::Creating { .. } => return Ok(()),
            Self::Waiting(p) | Self::Cancelling(p) => p,
            Self::Claimed {
                pending,
                ciphertext,
            } => {
                // A retained claim is safe to authenticate after server expiry.
                bootstrap::open_retained_pairing(ciphertext, pending)?;
                pending
            }
        };
        if pending.invitation().server() != &binding.server
            || pending.invitation().space() != binding.space
        {
            return Err(Failure::ReviewRequired);
        }
        Ok(())
    }
}
struct Journal {
    generation: i64,
    binding: KeyBinding,
    phase: Option<Phase>,
    snapshot: Option<Zeroizing<Vec<u8>>>,
}
impl Journal {
    fn load<B: Backend>(owner: &mut Locked<'_, B>) -> super::Result<Option<Self>> {
        Self::from_snapshot(owner.read(Slot::PairingRecipient)?)
    }
    fn from_snapshot(snapshot: Option<Zeroizing<Vec<u8>>>) -> super::Result<Option<Self>> {
        let Some(bytes) = snapshot else {
            return Ok(None);
        };
        let value = canonical::parse(&bytes)?;
        let v = exact(&value, &["schema", "generation", "binding", "phase"])?;
        let generation = v["generation"].as_int()?;
        if v["schema"].as_int()? != 1 || generation < 1 {
            return Err(Failure::InvalidState);
        }
        let result = Self {
            generation,
            binding: KeyBinding::parse(&v["binding"])?,
            phase: optional(&v["phase"], Phase::parse)?,
            snapshot: Some(bytes),
        };
        result.validate()?;
        Ok(Some(result))
    }
    fn validate(&self) -> super::Result<()> {
        if let Some(phase) = &self.phase {
            phase.validate(&self.binding)?;
        }
        Ok(())
    }
    fn encode_next(&self) -> super::Result<Zeroizing<Vec<u8>>> {
        self.validate()?;
        Ok(object([
            ("schema", Value::Int(1)),
            (
                "generation",
                Value::Int(
                    self.generation
                        .checked_add(1)
                        .ok_or(Failure::InvalidState)?,
                ),
            ),
            ("binding", self.binding.value()),
            (
                "phase",
                self.phase
                    .as_ref()
                    .map(Phase::value)
                    .transpose()?
                    .unwrap_or(Value::Null),
            ),
        ])
        .encode()?)
    }
    fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> super::Result<()> {
        let bytes = self.encode_next()?;
        owner.replace(
            Slot::PairingRecipient,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.generation += 1;
        self.snapshot = Some(bytes);
        Ok(())
    }
    fn save_receipt<B: Backend>(mut self, owner: &mut Locked<'_, B>) -> Result<Self> {
        let target = self.encode_next()?;
        match self.save(owner) {
            Ok(()) => Ok(self),
            Err(failure) => Err(Rejected {
                failure,
                unrecorded: Some(Unrecorded {
                    journal: Box::new(self),
                    target,
                }),
            }),
        }
    }
    fn check_binding(&self, binding: &KeyBinding) -> super::Result<()> {
        if &self.binding != binding {
            return Err(Failure::ReviewRequired);
        }
        Ok(())
    }
}

pub(crate) fn retirement_terminal(snapshot: Option<Zeroizing<Vec<u8>>>) -> super::Result<bool> {
    Ok(Journal::from_snapshot(snapshot)?.is_none_or(|journal| journal.phase.is_none()))
}
pub(super) fn check_admission<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> super::Result<()> {
    super::handover::require_idle(owner)?;
    if let Some(journal) = Journal::load(owner)? {
        journal.check_binding(binding)?;
    }
    Ok(())
}
pub(super) fn require_idle<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> super::Result<()> {
    super::handover::require_idle(owner)?;
    crate::auth_store::creation::check_target(owner, binding)?;
    if let Some(journal) = Journal::load(owner)? {
        journal.check_binding(binding)?;
        if journal.phase.is_some() {
            return Err(Failure::Busy);
        }
    }
    Ok(())
}
pub(super) trait Remote: super::Remote {
    fn create(&mut self, draft: &PairingDraft) -> super::Result<Pairing>;
    /// A pairing created by another device for this device's own key and nonce.
    fn observe(
        &mut self,
        pairing: Uuid,
        public: &[u8; 65],
        nonce: &[u8; 32],
    ) -> super::Result<Pairing>;
    fn poll(&mut self, invitation: &Invitation) -> super::Result<Pairing>;
    fn claim(&mut self, expected: &Pairing) -> super::Result<Vec<u8>>;
    fn cancel(&mut self, invitation: &Invitation) -> super::Result<()>;
}
impl Remote for BoundTransport {
    fn create(&mut self, draft: &PairingDraft) -> super::Result<Pairing> {
        Ok(self.create_pairing(draft)?)
    }
    fn observe(
        &mut self,
        pairing: Uuid,
        public: &[u8; 65],
        nonce: &[u8; 32],
    ) -> super::Result<Pairing> {
        Ok(self.observe_pairing(pairing, public, nonce)?)
    }
    fn poll(&mut self, invitation: &Invitation) -> super::Result<Pairing> {
        Ok(self.pairing(invitation)?)
    }
    fn claim(&mut self, expected: &Pairing) -> super::Result<Vec<u8>> {
        Ok(self.claim_pairing(expected)?)
    }
    fn cancel(&mut self, invitation: &Invitation) -> super::Result<()> {
        Ok(self.cancel_pairing(invitation)?)
    }
}
fn preparation<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> super::Result<(KeyBinding, Archive)> {
    remote.preflight()?;
    let binding = remote.binding()?;
    crate::auth_store::creation::check_target(owner, &binding)?;
    mutations::require_idle(owner, &binding)?;
    let archive = Archive::load(owner)?;
    archive.check_binding(&binding)?;
    if archive.pending.is_some() {
        return Err(Failure::Busy);
    }
    if let Some(installed) = read_installed(owner, &binding)? {
        validate_presentation(&archive, &installed)?;
    }
    owner.check_checkpoint_scope(binding.checkpoint_scope(), true)?;
    Ok((binding, archive))
}
/// Explicit pairing only; no request or private key is created at app startup.
pub fn begin<B: Backend>(store: &mut Store<B>, remote: &mut BoundTransport) -> Result<Outcome> {
    store.transaction_with(|owner| begin_locked(owner, remote))
}
pub(super) fn begin_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<Outcome> {
    let (binding, archive) = preparation(owner, remote)?;
    let mut journal = Journal::load(owner)?;
    if let Some(journal) = &journal {
        journal.check_binding(&binding)?;
        if journal.phase.is_some() {
            let saved = journal_owned(owner)?;
            return advance(owner, remote, saved);
        }
    }
    if let Some(installed) = read_installed(owner, &binding)? {
        verify_remote(remote, &binding, &installed.bundle)?;
        validate_presentation(&archive, &installed)?;
        return ready(owner, remote, &binding, &installed.bundle).map_err(Into::into);
    }
    if remote.role() == Role::Reader {
        return Err(Failure::Cloud(cloud::Failure::ReadOnly).into());
    }
    let authority = remote.authority()?;
    check_remote(remote, &binding)?;
    if authority.is_none() {
        return Err(Failure::KeyConflict.into());
    }
    let mut journal = journal.take().unwrap_or(Journal {
        generation: 0,
        binding,
        phase: None,
        snapshot: None,
    });
    journal.phase = Some(Phase::Creating {
        draft: PairingDraft::generate()?,
        sent: false,
    });
    journal.save(owner)?;
    advance(owner, remote, journal)
}
/// Device-approved sign-in (ADR 0007): the approving device already created and
/// approved a pairing for this device's retained recipient key and nonce. That
/// material moves into this ordinary recipient journal, and the existing claim,
/// AEAD, authority and installation steps finish exactly as for this device's
/// own invitation. The recipient key/nonce equality is checked before claiming.
pub fn adopt_device_sign_in<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
) -> Result<Outcome> {
    store.transaction_with(|owner| adopt_device_locked(owner, remote))
}
pub(super) fn adopt_device_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<Outcome> {
    let (binding, _) = preparation(owner, remote)?;
    let journal = Journal::load(owner)?;
    if let Some(journal) = &journal {
        journal.check_binding(&binding)?;
        if journal.phase.is_some() {
            let saved = journal_owned(owner)?;
            return advance(owner, remote, saved);
        }
    }
    let (deployment, draft, approval, snapshot) = crate::auth_store::device::approved_draft(owner)
        .map_err(|_| Failure::InvalidState)?
        .ok_or(Failure::InvalidState)?;
    if !binding.matches_deployment(&deployment) || approval.space != binding.space {
        return Err(Failure::ReviewRequired.into());
    }
    if let Some(installed) = read_installed(owner, &binding)? {
        // This device already holds the library key; nothing remains to claim.
        verify_remote(remote, &binding, &installed.bundle)?;
        crate::auth_store::device::retire(owner, &snapshot).map_err(|_| Failure::InvalidState)?;
        return ready(owner, remote, &binding, &installed.bundle).map_err(Into::into);
    }
    check_remote(remote, &binding)?;
    let pairing = remote.observe(approval.pairing, draft.public_key(), draft.nonce())?;
    check_remote(remote, &binding)?;
    if pairing.state() != PairingState::Approved
        || pairing.invitation().pairing() != approval.pairing
    {
        return Err(Failure::ReviewRequired.into());
    }
    // The existing binding check: the pairing's recipient key and nonce must be
    // this device's own before any envelope is claimed or opened.
    let pending = PendingPairing::new(draft, pairing.invitation().clone())?;
    let mut journal = journal.unwrap_or(Journal {
        generation: 0,
        binding,
        phase: None,
        snapshot: None,
    });
    journal.phase = Some(Phase::Waiting(pending));
    journal.save(owner)?;
    crate::auth_store::device::retire(owner, &snapshot).map_err(|_| Failure::InvalidState)?;
    advance(owner, remote, journal)
}
/// Polls a stored invitation. An already retained claim completes even after
/// expiry; it performs no new claim and still verifies fresh server authority.
pub fn check<B: Backend>(store: &mut Store<B>, remote: &mut BoundTransport) -> Result<Outcome> {
    store.transaction_with(|owner| check_locked(owner, remote))
}
pub(super) fn check_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<Outcome> {
    let (binding, _) = preparation(owner, remote)?;
    let journal = journal_owned(owner)?;
    journal.check_binding(&binding)?;
    advance(owner, remote, journal)
}
fn journal_owned<B: Backend>(owner: &mut Locked<'_, B>) -> super::Result<Journal> {
    Journal::load(owner)?.ok_or(Failure::InvalidState)
}
fn ready<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl super::Remote,
    binding: &KeyBinding,
    bundle: &Bundle,
) -> super::Result<Outcome> {
    let mut archive = Archive::load(owner)?;
    archive.check_binding(binding)?;
    if archive.pending.is_some() {
        return Err(Failure::Busy);
    }
    if let Some(p) = &archive.presentation
        && !p.matches_bundle(bundle)?
    {
        return Err(Failure::KeyConflict);
    }
    refresh_presentation(owner, remote, &mut archive, binding)?;
    Ok(Outcome::Ready {
        kit: archive
            .presentation
            .as_ref()
            .map_or(KitStatus::None, Presentation::status),
    })
}
fn advance<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    mut journal: Journal,
) -> Result<Outcome> {
    check_remote(remote, &journal.binding)?;
    match journal.phase.as_mut() {
        Some(Phase::Creating { sent: true, .. }) => Ok(Outcome::CreationUnconfirmed),
        Some(Phase::Creating { sent, .. }) => {
            if remote.role() == Role::Reader {
                return Err(Failure::Cloud(cloud::Failure::ReadOnly).into());
            }
            *sent = true;
            journal.save(owner)?;
            let Some(Phase::Creating { draft, .. }) = journal.phase.take() else {
                return Err(Failure::InvalidState.into());
            };
            let result = remote.create(&draft)?;
            check_remote(remote, &journal.binding)?;
            if result.state() != PairingState::Pending {
                return Err(Failure::InvalidState.into());
            }
            let pending = PendingPairing::new(draft, result.invitation().clone())?;
            let invitation = pending.invitation().clone();
            journal.phase = Some(Phase::Waiting(pending));
            let _journal = journal.save_receipt(owner)?;
            Ok(Outcome::Waiting(invitation))
        }
        Some(Phase::Waiting(pending)) => {
            let result = remote.poll(pending.invitation())?;
            check_remote(remote, &journal.binding)?;
            if result.invitation() != pending.invitation() {
                return Err(Failure::InvalidState.into());
            }
            if result.state() == PairingState::Pending {
                return Ok(Outcome::Waiting(pending.invitation().clone()));
            }
            let ciphertext = remote.claim(&result)?;
            // Retention grants no activation until AEAD and authority both match.
            let Some(Phase::Waiting(pending)) = journal.phase.take() else {
                return Err(Failure::InvalidState.into());
            };
            journal.phase = Some(Phase::Claimed {
                pending,
                ciphertext,
            });
            let journal = journal.save_receipt(owner)?;
            // Preserve an authenticated response before another scope check.
            // A later boundary halt must keep the received capability for review.
            check_remote(remote, &journal.binding)?;
            advance(owner, remote, journal)
        }
        Some(Phase::Claimed {
            pending,
            ciphertext,
        }) => {
            let bundle = bootstrap::open_retained_pairing(ciphertext, pending)?;
            verify_remote(remote, &journal.binding, &bundle)?;
            let outcome = ready(owner, remote, &journal.binding, &bundle)?;
            owner.check_checkpoint_scope(journal.binding.checkpoint_scope(), true)?;
            if let Some(installed) = read_installed(owner, &journal.binding)? {
                if installed.bundle.for_secure_storage() != bundle.for_secure_storage() {
                    return Err(Failure::KeyConflict.into());
                }
            } else {
                let bytes = Installed {
                    binding: journal.binding.clone(),
                    bundle,
                }
                .value()?
                .encode()
                .map_err(Failure::from)?;
                owner.replace(Slot::LibraryKey, None, Some(&bytes))?;
            }
            journal.phase = None;
            journal.save(owner)?;
            Ok(outcome)
        }
        Some(Phase::Cancelling(pending)) => {
            remote.cancel(pending.invitation())?;
            check_remote(remote, &journal.binding)?;
            journal.phase = None;
            journal.save(owner)?;
            Ok(Outcome::Cancelled)
        }
        None => match load_locked(owner, remote)? {
            Some(key) => ready(owner, remote, &key.binding, &key.bundle).map_err(Into::into),
            None => Ok(Outcome::Cancelled),
        },
    }
}
/// Explicit cancellation. A received key cannot be discarded by this path;
/// complete its activation or use the separate account-review workflow.
pub fn cancel<B: Backend>(store: &mut Store<B>, remote: &mut BoundTransport) -> Result<Outcome> {
    store.transaction_with(|owner| cancel_locked(owner, remote))
}
pub(super) fn cancel_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<Outcome> {
    let (binding, _) = preparation(owner, remote)?;
    let mut journal = journal_owned(owner)?;
    journal.check_binding(&binding)?;
    match journal.phase.take() {
        Some(Phase::Claimed { .. }) => return Err(Failure::Busy.into()),
        Some(Phase::Waiting(p)) | Some(Phase::Cancelling(p)) => {
            journal.phase = Some(Phase::Cancelling(p));
        }
        // The non-idempotent create endpoint returned no known invitation ID.
        // Nothing was displayed; any unreachable server invitation expires itself.
        Some(Phase::Creating { .. }) => {
            journal.save(owner)?;
            return Ok(Outcome::Cancelled);
        }
        None => return advance(owner, remote, journal),
    }
    journal.save(owner)?;
    advance(owner, remote, journal)
}
