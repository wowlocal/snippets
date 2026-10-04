//! Journal-first key mutations. Candidate capabilities and original signed
//! requests stay in Secret Service; each send requires fresh local authority.
use super::*;
use crate::{
    bootstrap::Invitation,
    cloud::{ActionChallenge, Mutation, Pairing, PairingState, SignedAction},
    local_auth::{Permit, Purpose, Target},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Recovery,
    Approval,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Prepared,
    Signed,
    Acknowledged,
}
pub struct Retained {
    pub kind: Kind,
    pub step: Step,
    pub confirmation_code: Option<String>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    RecoveryReady,
    ApprovalAcknowledged,
    ReviewRequired,
}

enum Intent {
    Recovery {
        prior: Option<(u64, [u8; 32])>,
        kit: RecoveryKit,
        ciphertext: Vec<u8>,
    },
    Approval {
        invitation: Invitation,
        ciphertext: Vec<u8>,
    },
}
impl Intent {
    fn kind(&self) -> Kind {
        match self {
            Self::Recovery { .. } => Kind::Recovery,
            Self::Approval { .. } => Kind::Approval,
        }
    }
    fn mutation(&self, binding: &KeyBinding) -> Result<Mutation> {
        Ok(match self {
            Self::Recovery {
                prior, ciphertext, ..
            } => Mutation::recovery(binding.epoch, prior.as_ref().map(|p| p.0), ciphertext)?,
            Self::Approval {
                invitation,
                ciphertext,
            } => Mutation::approval(binding.epoch, invitation.clone(), ciphertext)?,
        })
    }
    fn value(&self) -> Result<Value> {
        Ok(match self {
            Self::Recovery {
                prior,
                kit,
                ciphertext,
            } => object([
                ("kind", Value::text("recovery")),
                (
                    "version",
                    prior
                        .as_ref()
                        .map_or(Value::Null, |p| Value::Int(p.0 as i64)),
                ),
                (
                    "priorHash",
                    prior
                        .as_ref()
                        .map_or(Value::Null, |p| Value::text(STANDARD.encode(p.1))),
                ),
                ("kit", canonical::parse(&kit.encode_secret_qr()?)?),
                ("ciphertext", Value::text(STANDARD.encode(ciphertext))),
            ]),
            Self::Approval {
                invitation,
                ciphertext,
            } => object([
                ("kind", Value::text("approval")),
                ("invitation", canonical::parse(&invitation.encode_qr()?)?),
                ("ciphertext", Value::text(STANDARD.encode(ciphertext))),
            ]),
        })
    }
    fn parse(v: &Value) -> Result<Self> {
        let kind = v
            .as_object()?
            .get("kind")
            .ok_or(Failure::InvalidState)?
            .as_text()?;
        Ok(match kind {
            "recovery" => {
                let v = exact(v, &["kind", "version", "priorHash", "kit", "ciphertext"])?;
                let version = optional(&v["version"], |v| {
                    let n = v.as_int()?;
                    if n < 1 || n == i64::MAX {
                        return Err(Failure::InvalidState);
                    }
                    Ok(n as u64)
                })?;
                let hash = optional(&v["priorHash"], |v| array(v.as_text()?))?;
                let prior = match (version, hash) {
                    (Some(v), Some(h)) => Some((v, h)),
                    (None, None) => None,
                    _ => return Err(Failure::InvalidState),
                };
                Self::Recovery {
                    prior,
                    kit: RecoveryKit::decode_secret_qr(&v["kit"].encode()?)?,
                    ciphertext: decode64(
                        v["ciphertext"].as_text()?,
                        bootstrap::MAX_ENVELOPE_BYTES,
                    )?
                    .to_vec(),
                }
            }
            "approval" => {
                let v = exact(v, &["kind", "invitation", "ciphertext"])?;
                Self::Approval {
                    invitation: Invitation::decode_retained_qr(&v["invitation"].encode()?)?,
                    ciphertext: decode64(
                        v["ciphertext"].as_text()?,
                        bootstrap::MAX_ENVELOPE_BYTES,
                    )?
                    .to_vec(),
                }
            }
            _ => return Err(Failure::InvalidState),
        })
    }
    fn expected_version(&self) -> Option<u64> {
        match self {
            Self::Recovery { prior, .. } => Some(prior.as_ref().map_or(0, |p| p.0) + 1),
            _ => None,
        }
    }
    fn matches_recovery(&self, e: &Evidence) -> bool {
        matches!(self,Self::Recovery {ciphertext,..} if self.expected_version()==Some(e.version) && *ciphertext==e.ciphertext)
    }
}
enum Phase {
    Prepared,
    Signed(Zeroizing<Vec<u8>>),
    Acknowledged(Option<u64>),
    Inactive,
}
struct Journal {
    generation: i64,
    binding: KeyBinding,
    authority: [u8; 32],
    intent: Option<Intent>,
    phase: Phase,
    snapshot: Option<Zeroizing<Vec<u8>>>,
}
impl Journal {
    fn load<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Option<Self>> {
        Self::from_snapshot(owner.read(Slot::KeyMutation)?)
    }
    fn from_snapshot(snapshot: Option<Zeroizing<Vec<u8>>>) -> Result<Option<Self>> {
        let Some(bytes) = snapshot else {
            return Ok(None);
        };
        let value = canonical::parse(&bytes)?;
        let v = exact(
            &value,
            &[
                "schema",
                "generation",
                "binding",
                "authority",
                "intent",
                "phase",
            ],
        )?;
        let generation = v["generation"].as_int()?;
        if v["schema"].as_int() != Ok(1) || generation < 1 {
            return Err(Failure::InvalidState);
        }
        let p = exact(&v["phase"], &["kind", "proof", "version"])?;
        let proof = optional(&p["proof"], |v| Ok(v.encode()?))?;
        let version = optional(&p["version"], |v| {
            let n = v.as_int()?;
            if n < 1 {
                return Err(Failure::InvalidState);
            }
            Ok(n as u64)
        })?;
        let phase = match (p["kind"].as_text()?, proof, version) {
            ("prepared", None, None) => Phase::Prepared,
            ("signed", Some(p), None) => Phase::Signed(p),
            ("acknowledged", None, v) => Phase::Acknowledged(v),
            ("inactive", None, None) => Phase::Inactive,
            _ => return Err(Failure::InvalidState),
        };
        let journal = Self {
            generation,
            binding: KeyBinding::parse(&v["binding"])?,
            authority: array(v["authority"].as_text()?)?,
            intent: optional(&v["intent"], Intent::parse)?,
            phase,
            snapshot: Some(bytes),
        };
        journal.validate()?;
        Ok(Some(journal))
    }
    fn validate(&self) -> Result<()> {
        let Some(intent) = &self.intent else {
            return if matches!(self.phase, Phase::Inactive) {
                Ok(())
            } else {
                Err(Failure::InvalidState)
            };
        };
        if matches!(self.phase, Phase::Inactive) {
            return Err(Failure::InvalidState);
        }
        let mutation = intent.mutation(&self.binding)?;
        match intent {
            Intent::Recovery {
                kit, ciphertext, ..
            } => {
                validate_kit(kit, &self.binding)?;
                let bundle = bootstrap::open_recovery(ciphertext, kit)?;
                if Authority::new(&bundle, &self.binding.context()?).public_key() != self.authority
                {
                    return Err(Failure::KeyConflict);
                }
            }
            Intent::Approval { invitation, .. } => {
                if invitation.server() != &self.binding.server
                    || invitation.space() != self.binding.space
                {
                    return Err(Failure::ReviewRequired);
                }
            }
        }
        if let Phase::Signed(bytes) = &self.phase
            && !SignedAction::decode_secret(bytes)?.matches_owner(
                &self.binding,
                &self.authority,
                &mutation,
            )
        {
            return Err(Failure::InvalidState);
        }
        if let Phase::Acknowledged(version) = self.phase
            && version != intent.expected_version()
        {
            return Err(Failure::InvalidState);
        }
        Ok(())
    }
    fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> Result<()> {
        self.validate()?;
        let next = self
            .generation
            .checked_add(1)
            .ok_or(Failure::InvalidState)?;
        let (kind, proof, version) = match &self.phase {
            Phase::Prepared => ("prepared", Value::Null, Value::Null),
            Phase::Signed(p) => ("signed", canonical::parse(p)?, Value::Null),
            Phase::Acknowledged(v) => (
                "acknowledged",
                Value::Null,
                v.map_or(Value::Null, |v| Value::Int(v as i64)),
            ),
            Phase::Inactive => ("inactive", Value::Null, Value::Null),
        };
        let bytes = object([
            ("schema", Value::Int(1)),
            ("generation", Value::Int(next)),
            ("binding", self.binding.value()),
            ("authority", Value::text(STANDARD.encode(self.authority))),
            (
                "intent",
                self.intent
                    .as_ref()
                    .map(Intent::value)
                    .transpose()?
                    .unwrap_or(Value::Null),
            ),
            (
                "phase",
                object([
                    ("kind", Value::text(kind)),
                    ("proof", proof),
                    ("version", version),
                ]),
            ),
        ])
        .encode()?;
        owner.replace(
            Slot::KeyMutation,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.snapshot = Some(bytes);
        self.generation = next;
        Ok(())
    }
    fn check_binding(&self, binding: &KeyBinding) -> Result<()> {
        if self.binding != *binding {
            Err(Failure::ReviewRequired)
        } else {
            Ok(())
        }
    }
    fn target(&self, installed: &Installed, archive: &Archive) -> Result<Target> {
        let intent = self.intent.as_ref().ok_or(Failure::InvalidState)?;
        if matches!(self.phase, Phase::Acknowledged(_)) {
            return Err(Failure::Busy);
        }
        let mut hash = Sha256::new();
        hash.update(b"snippets-library-key-mutation-target-v1\0");
        hash.update(
            self.snapshot
                .as_ref()
                .ok_or(Failure::InvalidState)?
                .as_slice(),
        );
        hash.update(installed.value()?.encode()?.as_slice());
        hash.update(archive.generation.to_be_bytes());
        if let Some(bytes) = &archive.snapshot {
            hash.update(bytes.as_slice());
        }
        Ok(Target::new(
            self.binding.clone(),
            match intent.kind() {
                Kind::Recovery => Purpose::ReplaceRecovery,
                Kind::Approval => Purpose::ApprovePairing,
            },
            self.generation,
            hash.finalize().into(),
        )?)
    }
}

pub(crate) fn retirement_terminal(snapshot: Option<Zeroizing<Vec<u8>>>) -> Result<bool> {
    Ok(Journal::from_snapshot(snapshot)?
        .is_none_or(|journal| matches!(journal.phase, Phase::Acknowledged(_) | Phase::Inactive)))
}
pub(super) fn check_admission<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<()> {
    super::handover::require_idle(owner)?;
    if let Some(j) = Journal::load(owner)? {
        j.check_binding(binding)?;
    }
    Ok(())
}
pub(super) fn require_idle<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<()> {
    super::handover::require_idle(owner)?;
    if let Some(j) = Journal::load(owner)? {
        j.check_binding(binding)?;
        if j.intent.is_some() {
            return Err(Failure::Busy);
        }
    }
    Ok(())
}
/// Confirmation retires a promoted capability from both owning documents. Clear
/// the acknowledged mutation first, while the presentation still retains the
/// only copy needed after a crash. No confirmed receipt can leave its kit here.
pub(super) fn retire_promoted<B: Backend>(
    owner: &mut Locked<'_, B>,
    presentation: &Presentation,
) -> Result<()> {
    let Some(mut j) = Journal::load(owner)? else {
        return Ok(());
    };
    j.check_binding(&presentation.binding)?;
    let Some(
        intent @ Intent::Recovery {
            kit, ciphertext, ..
        },
    ) = &j.intent
    else {
        return Ok(());
    };
    let (shown_kit, shown_ciphertext) = presentation.retained()?;
    if intent.expected_version() != Some(presentation.version)
        || ciphertext.as_slice() != shown_ciphertext
        || kit.encode_secret_qr()? != shown_kit.encode_secret_qr()?
    {
        return Ok(());
    }
    if !matches!(j.phase, Phase::Acknowledged(_)) {
        return Err(Failure::Busy);
    }
    j.intent = None;
    j.phase = Phase::Inactive;
    j.save(owner)
}
pub fn inspect_retained<B: Backend>(
    store: &mut Store<B>,
    remote: &BoundTransport,
) -> Result<Option<Retained>> {
    let binding = remote.key_binding()?;
    store.transaction_with(|owner| {
        let Some(j) = Journal::load(owner)? else {
            return Ok(None);
        };
        j.check_binding(&binding)?;
        Ok(j.intent.as_ref().map(|i| Retained {
            kind: i.kind(),
            step: match j.phase {
                Phase::Prepared => Step::Prepared,
                Phase::Signed(_) => Step::Signed,
                Phase::Acknowledged(_) => Step::Acknowledged,
                Phase::Inactive => unreachable!(),
            },
            confirmation_code: match i {
                Intent::Approval { invitation, .. } => Some(invitation.confirmation_code()),
                _ => None,
            },
        }))
    })
}
pub(super) trait Remote: super::Remote {
    fn pairing(&mut self, invitation: &Invitation) -> Result<Pairing>;
    fn challenge(&mut self, mutation: Mutation, public: &[u8; 32]) -> Result<ActionChallenge>;
    fn replace(
        &mut self,
        signed: &SignedAction,
        guard: &mut dyn FnMut() -> std::result::Result<(), cloud::Failure>,
    ) -> Result<Evidence>;
    fn approve(
        &mut self,
        signed: &SignedAction,
        guard: &mut dyn FnMut() -> std::result::Result<(), cloud::Failure>,
    ) -> Result<Pairing>;
}
impl Remote for BoundTransport {
    fn pairing(&mut self, i: &Invitation) -> Result<Pairing> {
        Ok(BoundTransport::pairing(self, i)?)
    }
    fn challenge(&mut self, m: Mutation, p: &[u8; 32]) -> Result<ActionChallenge> {
        Ok(self.request_key_challenge(m, p)?)
    }
    fn replace(
        &mut self,
        s: &SignedAction,
        g: &mut dyn FnMut() -> std::result::Result<(), cloud::Failure>,
    ) -> Result<Evidence> {
        let e = self.replace_recovery_guarded(s, g)?;
        Ok(Evidence {
            version: e.version(),
            ciphertext: e.ciphertext().into(),
        })
    }
    fn approve(
        &mut self,
        s: &SignedAction,
        g: &mut dyn FnMut() -> std::result::Result<(), cloud::Failure>,
    ) -> Result<Pairing> {
        Ok(self.approve_pairing_guarded(s, g)?)
    }
}
fn current<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<(Archive, Installed)> {
    remote.preflight()?;
    let binding = remote.binding()?;
    recipient::require_idle(owner, &binding)?;
    let mut archive = Archive::load(owner)?;
    archive.check_binding(&binding)?;
    if archive.pending.is_some() {
        return Err(Failure::Busy);
    }
    let installed = read_installed(owner, &binding)?.ok_or(Failure::RecoveryUnavailable)?;
    verify_remote(remote, &binding, &installed.bundle)?;
    validate_presentation(&archive, &installed)?;
    if archive.needs_upgrade {
        archive.save(owner)?;
    }
    Ok((archive, installed))
}
fn permitted(remote: &impl Remote, intent: &Intent) -> Result<()> {
    if remote.role() == Role::Reader
        || (intent.kind() == Kind::Recovery && remote.role() != Role::Owner)
    {
        return Err(Failure::Cloud(cloud::Failure::ReadOnly));
    }
    Ok(())
}
fn prior_is_current(remote: &mut impl Remote, j: &Journal) -> Result<()> {
    let intent = j.intent.as_ref().ok_or(Failure::InvalidState)?;
    match intent {
        Intent::Recovery { prior, .. } => {
            let actual = remote.recovery()?;
            check_remote(remote, &j.binding)?;
            if actual
                .as_ref()
                .map(|e| (e.version, <[u8; 32]>::from(Sha256::digest(&e.ciphertext))))
                != *prior
            {
                return Err(Failure::ReviewRequired);
            }
        }
        Intent::Approval { invitation, .. } => {
            let p = remote.pairing(invitation)?;
            check_remote(remote, &j.binding)?;
            if p.invitation() != invitation || p.state() != PairingState::Pending {
                return Err(Failure::ReviewRequired);
            }
        }
    }
    Ok(())
}
pub fn prepare_recovery<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
) -> Result<Target> {
    store.transaction_with(|o| prepare_locked(o, remote, None))
}
pub fn prepare_approval<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    invitation: Invitation,
) -> Result<Target> {
    store.transaction_with(|o| prepare_locked(o, remote, Some(invitation)))
}
/// Resume the retained operation without importing another invitation or
/// generating a different candidate. Acknowledged outcomes use reconciliation.
pub fn prepare_resume<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
) -> Result<Target> {
    store.transaction_with(|owner| {
        let j = Journal::load(owner)?.ok_or(Failure::InvalidState)?;
        let invitation = match j.intent.as_ref().ok_or(Failure::InvalidState)? {
            Intent::Recovery { .. } => None,
            Intent::Approval { invitation, .. } => Some(invitation.clone()),
        };
        prepare_locked(owner, remote, invitation)
    })
}
pub(super) fn prepare_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    invitation: Option<Invitation>,
) -> Result<Target> {
    let (archive, installed) = current(owner, remote)?;
    let mut journal = Journal::load(owner)?;
    if let Some(j) = &journal {
        j.check_binding(&installed.binding)?;
        if j.authority
            != Authority::new(&installed.bundle, &installed.binding.context()?).public_key()
        {
            return Err(Failure::KeyConflict);
        }
        if let Some(intent) = &j.intent {
            let same = match (intent, &invitation) {
                (Intent::Recovery { .. }, None) => true,
                (Intent::Approval { invitation: a, .. }, Some(b)) => a == b,
                _ => false,
            };
            if !same {
                return Err(Failure::Busy);
            }
            permitted(remote, intent)?;
            if matches!(j.phase, Phase::Prepared) {
                prior_is_current(remote, j)?;
            }
            return j.target(&installed, &archive);
        }
    }
    let binding = installed.binding.clone();
    let intent = if let Some(invitation) = invitation {
        if invitation.server() != &binding.server || invitation.space() != binding.space {
            return Err(Failure::ReviewRequired);
        }
        if remote.role() == Role::Reader {
            return Err(Failure::Cloud(cloud::Failure::ReadOnly));
        }
        let p = remote.pairing(&invitation)?;
        check_remote(remote, &binding)?;
        if p.invitation() != &invitation || p.state() != PairingState::Pending {
            return Err(Failure::ReviewRequired);
        }
        Intent::Approval {
            ciphertext: bootstrap::seal_pairing(
                &installed.bundle,
                &invitation,
                chrono::Utc::now().timestamp(),
            )?,
            invitation,
        }
    } else {
        if remote.role() != Role::Owner {
            return Err(Failure::Cloud(cloud::Failure::ReadOnly));
        }
        let prior = remote.recovery()?;
        check_remote(remote, &binding)?;
        let envelope = bootstrap::create_recovery(
            &installed.bundle,
            binding.server.clone(),
            binding.space,
            binding.epoch as i64,
        )?;
        Intent::Recovery {
            prior: prior.map(|e| (e.version, Sha256::digest(&e.ciphertext).into())),
            kit: envelope.kit,
            ciphertext: envelope.ciphertext,
        }
    };
    let mut j = journal.take().unwrap_or(Journal {
        generation: 0,
        binding: binding.clone(),
        authority: Authority::new(&installed.bundle, &binding.context()?).public_key(),
        intent: None,
        phase: Phase::Inactive,
        snapshot: None,
    });
    j.intent = Some(intent);
    j.phase = Phase::Prepared;
    j.save(owner)?;
    j.target(&installed, &archive)
}
pub fn execute<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    permit: Permit,
) -> Result<Outcome> {
    store.transaction_with(|o| execute_locked(o, remote, permit))
}
pub(super) fn execute_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    permit: Permit,
) -> Result<Outcome> {
    let (archive, installed) = current(owner, remote)?;
    let mut j = Journal::load(owner)?.ok_or(Failure::InvalidState)?;
    j.check_binding(&installed.binding)?;
    let target = j.target(&installed, &archive)?;
    let lease = permit.consume(&target)?;
    let intent = j.intent.as_ref().ok_or(Failure::InvalidState)?;
    permitted(remote, intent)?;
    if j.authority != Authority::new(&installed.bundle, &j.binding.context()?).public_key() {
        return Err(Failure::KeyConflict);
    }
    if matches!(j.phase, Phase::Prepared) {
        prior_is_current(remote, &j)?;
        lease.check()?;
        let challenge = remote.challenge(intent.mutation(&j.binding)?, &j.authority)?;
        check_remote(remote, &j.binding)?;
        lease.check()?;
        if !challenge.matches_owner(&j.binding, &j.authority, &intent.mutation(&j.binding)?) {
            return Err(Failure::ReviewRequired);
        }
        permitted(remote, intent)?;
        let authority = Authority::new(&installed.bundle, &j.binding.context()?);
        let proof = authority.sign(challenge.id(), challenge.nonce())?;
        lease.check()?;
        j.phase = Phase::Signed(challenge.authorize(proof)?.encode_secret()?);
        j.save(owner)?;
    }
    let Phase::Signed(bytes) = &j.phase else {
        return Err(Failure::Busy);
    };
    let signed = SignedAction::decode_secret(bytes)?;
    if !signed.replay_allowed() {
        return Ok(Outcome::ReviewRequired);
    }
    lease.check()?;
    let mut cancelled = None;
    let mut guard = || {
        lease.check().map_err(|e| {
            cancelled = Some(e);
            cloud::Failure::InvalidResponse
        })
    };
    let result = match j.intent.as_ref().ok_or(Failure::InvalidState)? {
        Intent::Recovery { .. } => remote.replace(&signed, &mut guard).and_then(|e| {
            if !j.intent.as_ref().unwrap().matches_recovery(&e) {
                return Err(Failure::ReviewRequired);
            }
            Ok(Some(e.version))
        }),
        Intent::Approval { invitation, .. } => remote.approve(&signed, &mut guard).and_then(|p| {
            if p.invitation() != invitation || p.state() != PairingState::Approved {
                return Err(Failure::ReviewRequired);
            }
            Ok(None)
        }),
    };
    let version = match result {
        Ok(v) => v,
        Err(e) => return Err(cancelled.map_or(e, Failure::Authentication)),
    };
    j.phase = Phase::Acknowledged(version);
    j.save(owner)?;
    check_remote(remote, &j.binding)?;
    finish(owner, remote, j)
}
fn finish<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    mut j: Journal,
) -> Result<Outcome> {
    let (mut archive, installed) = current(owner, remote)?;
    j.check_binding(&installed.binding)?;
    if j.authority != Authority::new(&installed.bundle, &j.binding.context()?).public_key() {
        return Err(Failure::KeyConflict);
    }
    let Phase::Acknowledged(version) = j.phase else {
        return Err(Failure::InvalidState);
    };
    let outcome = match j.intent.as_ref().ok_or(Failure::InvalidState)? {
        Intent::Recovery {
            kit, ciphertext, ..
        } => {
            if bootstrap::open_recovery(ciphertext, kit)?.for_secure_storage()
                != installed.bundle.for_secure_storage()
            {
                return Err(Failure::KeyConflict);
            }
            let actual = remote.recovery()?.ok_or(Failure::RecoveryUnavailable)?;
            check_remote(remote, &j.binding)?;
            if !j.intent.as_ref().unwrap().matches_recovery(&actual) {
                return Err(Failure::ReviewRequired);
            }
            if !archive
                .presentation
                .as_ref()
                .is_some_and(|p| p.binding == j.binding && p.matches_evidence(&actual))
            {
                archive.presentation = Some(Presentation {
                    binding: j.binding.clone(),
                    version: version.ok_or(Failure::InvalidState)?,
                    material: PresentationMaterial::Retained {
                        kit: RecoveryKit::decode_secret_qr(&kit.encode_secret_qr()?)?,
                        ciphertext: ciphertext.clone(),
                    },
                    status: KitStatus::AwaitingPresentation,
                });
                archive.save(owner)?;
            }
            Outcome::RecoveryReady
        }
        Intent::Approval { .. } => Outcome::ApprovalAcknowledged,
    };
    j.intent = None;
    j.phase = Phase::Inactive;
    j.save(owner)?;
    Ok(outcome)
}
/// Read-only outcome reconciliation, including after proof expiry. A pairing's
/// redacted Approved status cannot prove which ciphertext won, so it never retires
/// an unacknowledged approval or obtains a replacement challenge.
pub fn reconcile<B: Backend>(store: &mut Store<B>, remote: &mut BoundTransport) -> Result<Outcome> {
    store.transaction_with(|o| reconcile_locked(o, remote))
}
pub(super) fn reconcile_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<Outcome> {
    let (_, installed) = current(owner, remote)?;
    let mut j = Journal::load(owner)?.ok_or(Failure::InvalidState)?;
    j.check_binding(&installed.binding)?;
    if j.authority != Authority::new(&installed.bundle, &j.binding.context()?).public_key() {
        return Err(Failure::KeyConflict);
    }
    if matches!(j.phase, Phase::Acknowledged(_)) {
        return finish(owner, remote, j);
    }
    if !matches!(j.phase, Phase::Signed(_)) {
        return Err(Failure::Busy);
    }
    if let Some(intent @ Intent::Recovery { .. }) = &j.intent {
        let actual = remote.recovery()?;
        check_remote(remote, &j.binding)?;
        if let Some(e) = actual
            && intent.matches_recovery(&e)
        {
            j.phase = Phase::Acknowledged(Some(e.version));
            j.save(owner)?;
            return finish(owner, remote, j);
        }
    }
    Ok(Outcome::ReviewRequired)
}
/// Only an unsigned draft can be cancelled. Sent/possibly-sent proofs and their
/// capabilities remain available for reconciliation and explicit account review.
pub fn cancel_draft<B: Backend>(store: &mut Store<B>, remote: &BoundTransport) -> Result<()> {
    let binding = remote.key_binding()?;
    store.transaction_with(|o| cancel_locked(o, &binding))
}
pub(super) fn cancel_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<()> {
    super::handover::require_idle(owner)?;
    let mut j = Journal::load(owner)?.ok_or(Failure::InvalidState)?;
    j.check_binding(binding)?;
    if !matches!(j.phase, Phase::Prepared) {
        return Err(Failure::Busy);
    }
    j.intent = None;
    j.phase = Phase::Inactive;
    j.save(owner)
}
