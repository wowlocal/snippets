//! Fresh, single-use disclosure of the exact retained recovery presentation.
//! This is control-plane access only; it never activates keys or reads record data.
use super::*;
use crate::local_auth::{AuthorizationLease, Permit, Purpose, Target};
use sha2::{Digest, Sha256};
use unicode_segmentation::UnicodeSegmentation;

pub struct Disclosure {
    payload: Zeroizing<Vec<u8>>,
    code: Zeroizing<String>,
    lease: AuthorizationLease,
    target: Target,
}
impl Disclosure {
    pub fn qr_payload(&self) -> Result<&[u8]> {
        self.lease.check()?;
        Ok(&self.payload)
    }
    pub fn long_code(&self) -> Result<&str> {
        self.lease.check()?;
        Ok(&self.code)
    }
    #[cfg(all(test, feature = "desktop"))]
    pub(crate) fn fixture(permit: Permit, target: Target) -> Self {
        // Synthetic visual fixture: exact lease semantics, no key/account/PAM.
        Self {
            payload: Zeroizing::new(br#"{"fixture":"public recovery UI test"}"#.to_vec()),
            code: Zeroizing::new("PUBLIC-FIXTURE-CODE-1234-5678".into()),
            lease: permit.consume(&target).unwrap(),
            target,
        }
    }
}
/// Verify the current server envelope without revealing its kit. The UI uses
/// this target to start its native owner authentication dialog.
pub fn prepare<B: Backend>(store: &mut Store<B>, remote: &mut BoundTransport) -> Result<Target> {
    store.transaction_with(|owner| Ok(prepare_locked(owner, remote)?.1))
}
pub(super) fn prepare_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
) -> Result<(Archive, Target)> {
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
    // A damaged checkpoint cannot remove the only saved recovery capability.
    // No data-plane read, cursor use or key activation occurs along this path.
    refresh_presentation(owner, remote, &mut archive, &binding)?;
    let presentation = archive
        .presentation
        .as_ref()
        .ok_or(Failure::RecoveryUnavailable)?;
    if presentation.status != KitStatus::AwaitingPresentation {
        return Err(Failure::RecoveryUnavailable);
    }
    presentation.retained()?;
    let bytes = presentation.value()?.encode()?;
    let mut digest = Sha256::new();
    digest.update(b"snippets-recovery-disclosure-v1\0");
    digest.update(&bytes);
    let target = Target::new(
        binding,
        Purpose::RevealRecovery,
        archive.generation,
        digest.finalize().into(),
    )?;
    Ok((archive, target))
}
/// Consume authority only after rereading the exact saved state and revalidating
/// remote scope/authority/envelope. A stale permit can disclose no secret bytes.
pub fn reveal<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    permit: Permit,
) -> Result<Disclosure> {
    store.transaction_with(|owner| reveal_locked(owner, remote, permit))
}
pub(super) fn reveal_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    permit: Permit,
) -> Result<Disclosure> {
    let (archive, target) = prepare_locked(owner, remote)?;
    let lease = permit.consume(&target)?;
    let presentation = archive.presentation.ok_or(Failure::RecoveryUnavailable)?;
    let (kit, _) = presentation.retained()?;
    let disclosure = Disclosure {
        payload: kit.encode_secret_qr()?,
        code: kit.encode_secret_code(),
        lease,
        target,
    };
    disclosure.lease.check()?;
    Ok(disclosure)
}

/// Consume the current presentation and an explicit saved-code suffix. Success
/// atomically replaces the retained kit with verification metadata. Any failure
/// drops the process-local disclosure; an ambiguous write is resolved by a fresh
/// status read, never by reconstructing or redisclosing a retired kit.
pub fn confirm_saved<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    disclosure: Disclosure,
    entered_suffix: Zeroizing<String>,
) -> Result<Outcome> {
    store.transaction_with(|owner| confirm_saved_locked(owner, remote, disclosure, entered_suffix))
}
pub(super) fn confirm_saved_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    disclosure: Disclosure,
    entered_suffix: Zeroizing<String>,
) -> Result<Outcome> {
    disclosure.lease.check()?;
    if !matches_suffix(&disclosure.code, &entered_suffix) {
        return Err(Failure::VerificationMismatch);
    }
    let (mut archive, target) = prepare_locked(owner, remote)?;
    disclosure.lease.check()?;
    if target != disclosure.target {
        return Err(Failure::Authentication(
            crate::local_auth::Failure::WrongTarget,
        ));
    }
    mutations::retire_promoted(
        owner,
        archive
            .presentation
            .as_ref()
            .ok_or(Failure::RecoveryUnavailable)?,
    )?;
    disclosure.lease.check()?;
    initial_candidate::retire_promoted(
        owner,
        archive
            .presentation
            .as_ref()
            .ok_or(Failure::RecoveryUnavailable)?,
    )?;
    disclosure.lease.check()?;
    handover::retire_promoted(
        owner,
        archive
            .presentation
            .as_ref()
            .ok_or(Failure::RecoveryUnavailable)?,
    )?;
    disclosure.lease.check()?;
    archive
        .presentation
        .as_mut()
        .ok_or(Failure::RecoveryUnavailable)?
        .confirm_saved()?;
    disclosure.lease.check()?;
    archive.save(owner)?;
    disclosure.lease.check()?;
    Ok(archive.outcome())
}
const SUFFIX_LENGTH: usize = 8;
pub(super) fn matches_suffix(code: &str, entered: &str) -> bool {
    if entered.len() > 128 {
        return false;
    }
    // Matches the Apple saved-code verifier: discard separators, uppercase, and
    // require exactly eight characters. No Crockford I/L/O aliases are accepted.
    let normalized = Zeroizing::new(
        entered
            .graphemes(true)
            .filter(|cluster| cluster.chars().next().is_some_and(char::is_alphanumeric))
            .flat_map(str::chars)
            .flat_map(char::to_uppercase)
            .collect::<String>(),
    );
    let mut expected = Zeroizing::new(
        code.bytes()
            .rev()
            .filter(u8::is_ascii_alphanumeric)
            .take(SUFFIX_LENGTH)
            .collect::<Vec<_>>(),
    );
    expected.reverse();
    if expected.len() != SUFFIX_LENGTH || normalized.len() != SUFFIX_LENGTH {
        return false;
    }
    normalized
        .as_bytes()
        .iter()
        .zip(expected.iter())
        .fold(0u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}
