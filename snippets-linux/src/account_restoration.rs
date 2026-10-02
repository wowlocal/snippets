//! Vault preparation on the serialized account worker. Keys are local owners;
//! only authentication methods and a ciphertext review can leave this boundary.
use super::*;
use crate::{
    desktop::{SessionState, SessionWitness},
    model::Library,
    secret_store::Backend,
    vault::Vault,
};
use std::{path::Path, time::SystemTime};

/// Revocation covers queued work, both KDFs, planning and an uncommitted review.
/// This is preparation lifetime, not the separate purpose-bound write permit.
#[derive(Clone)]
pub(crate) struct Preparation {
    cancelled: Arc<AtomicBool>,
    witness: SessionWitness,
    epoch: u64,
    started: Duration,
    wall: SystemTime,
}
impl Preparation {
    pub(crate) fn new(witness: SessionWitness) -> Result<Self> {
        let (state, epoch) = witness.snapshot();
        if state != SessionState::Unlocked {
            return Err(local_auth::Failure::DesktopUnavailable.into());
        }
        Ok(Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            witness,
            epoch,
            started: crate::clock::uptime().ok_or(local_auth::Failure::Expired)?,
            wall: SystemTime::now(),
        })
    }
    pub(crate) fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub(crate) fn validate(&self) -> Result<()> {
        self.validate_at(
            crate::clock::uptime().ok_or(local_auth::Failure::Expired)?,
            SystemTime::now(),
        )
    }
    fn validate_at(&self, now: Duration, wall: SystemTime) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(local_auth::Failure::Cancelled.into());
        }
        let wall = wall
            .duration_since(self.wall)
            .map_err(|_| local_auth::Failure::Expired)?;
        if now < self.started
            || now - self.started >= Duration::from_secs(120)
            || wall >= Duration::from_secs(120)
            || self.witness.snapshot() != (SessionState::Unlocked, self.epoch)
        {
            return Err(local_auth::Failure::Expired.into());
        }
        Ok(())
    }
}

pub(crate) struct Credential {
    pub(crate) value: Zeroizing<String>,
    pub(crate) recovery: bool,
}
impl Credential {
    fn validate(&self) -> Result<()> {
        if self.value.is_empty() || self.value.len() > 4096 {
            return Err(Failure::VaultAuthentication);
        }
        Ok(())
    }
}
pub(crate) struct Credentials {
    pub(crate) current: Credential,
    pub(crate) previous: Option<Credential>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Methods {
    pub(crate) passphrase: bool,
    pub(crate) recovery: bool,
}
impl Methods {
    pub(crate) fn available(self) -> bool {
        self.passphrase || self.recovery
    }
}
/// Body-free UI hints. Scope equality does not authorize or prove a matching key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Authentication {
    pub(crate) current: Methods,
    pub(crate) previous: Option<Methods>,
    pub(crate) previous_suggested: bool,
    pub(crate) previous_backup: bool,
}
pub(crate) enum Outcome {
    Authentication(Authentication),
    Reviewed(Reviewed),
}
pub(crate) struct Reviewed {
    token: uuid::Uuid,
    review: Box<restoration::Review>,
    preparation: Preparation,
    rekeyed: bool,
}
impl Reviewed {
    pub(crate) fn reply(&self) -> Result<Reply> {
        self.preparation.validate()?;
        Ok(Reply::RestorationReview {
            saved: self.review.saved_library(),
            current: self.review.current_library(),
            token: Some(self.token),
            summary: self.review.summary(),
            target: self.review.authorization_target()?,
            rekeyed: self.rekeyed,
        })
    }
    pub(crate) fn consume(self, token: uuid::Uuid) -> Result<restoration::Review> {
        self.preparation.validate()?;
        if token != self.token {
            return Err(Failure::InvalidState);
        }
        Ok(*self.review)
    }
}

pub(super) fn unlock_current(
    root: &Path,
    credential: &Credential,
    check: &dyn Fn() -> Result<()>,
) -> Result<Vault> {
    check()?;
    credential.validate()?;
    let library = Library::prepare(root.into()).map_err(|_| Failure::VaultAuthentication)?;
    let document = crate::vault::read_document(root)
        .map_err(|_| Failure::VaultAuthentication)?
        .ok_or(Failure::VaultAuthentication)?;
    let authentication = document
        .authenticate(&credential.value, credential.recovery)
        .map_err(|_| Failure::VaultAuthentication)?;
    check()?;
    let mut vault = Vault::open(&library).map_err(|_| Failure::VaultAuthentication)?;
    vault
        .finish_authentication(authentication, vault.generation())
        .map_err(|_| Failure::VaultAuthentication)?;
    check()?;
    Ok(vault)
}
fn methods<B: Backend>(
    store: &mut Store<B>,
    selection: &restoration::Selection,
) -> Result<Authentication> {
    let header = restoration::saved_vault_header(store, selection)?;
    let root = store.transaction(|owner| Ok(owner.root().to_path_buf()))?;
    let current = crate::vault::read_document(&root)
        .map_err(|_| Failure::VaultAuthentication)?
        .ok_or(Failure::VaultAuthentication)?;
    let current_methods = Methods {
        passphrase: current.wrap_pass.is_some(),
        recovery: current.wrap_recovery.is_some(),
    };
    if !current_methods.available() {
        return Err(Failure::VaultAuthentication);
    }
    Ok(Authentication {
        current: current_methods,
        previous: header.as_ref().map(|header| Methods {
            passphrase: header.has_passphrase(),
            recovery: header.has_recovery(),
        }),
        previous_suggested: header
            .as_ref()
            .is_some_and(|header| !header.same_key_scope(&current)),
        previous_backup: false,
    })
}
#[cfg(test)]
pub(crate) fn prepare<B: Backend>(
    store: &mut Store<B>,
    selection: restoration::Selection,
    credentials: Option<Credentials>,
    preparation: Preparation,
) -> Result<Outcome> {
    prepare_with_file(store, selection, credentials, preparation, None)
}
pub(crate) fn prepare_with_file<B: Backend>(
    store: &mut Store<B>,
    selection: restoration::Selection,
    credentials: Option<Credentials>,
    preparation: Preparation,
    external: Option<restoration::SourceFile>,
) -> Result<Outcome> {
    preparation.validate()?;
    if external.is_some()
        && credentials
            .as_ref()
            .is_none_or(|credentials| credentials.previous.is_none())
    {
        return Err(Failure::InvalidState);
    }
    if external
        .as_ref()
        .is_some_and(|file| !file.matches_selection(&selection))
    {
        return Err(restoration::Failure::Changed.into());
    }
    let rekeyed = credentials
        .as_ref()
        .is_some_and(|credentials| credentials.previous.is_some());
    let result = if let Some(credentials) = credentials {
        credentials.current.validate()?;
        if let Some(previous) = &credentials.previous {
            previous.validate()?;
        }
        let root = store.transaction(|owner| Ok(owner.root().to_path_buf()))?;
        let mut current = unlock_current(&root, &credentials.current, &|| preparation.validate())?;
        if let Some(previous) = credentials.previous {
            preparation.validate()?;
            let authenticated = if let Some(file) = external {
                file.authenticate(store, &previous.value, previous.recovery)
            } else {
                restoration::authenticate_source(
                    store,
                    &selection,
                    &previous.value,
                    previous.recovery,
                )
            };
            preparation.validate()?;
            let source = authenticated.map_err(|error| match error {
                restoration::Failure::Key(key_store::Failure::InvalidState) => {
                    Failure::PreviousVaultAuthentication
                }
                other => other.into(),
            })?;
            preparation.validate()?;
            restoration::prepare_foreign(store, selection, &mut current, source)
        } else {
            if external.is_some() {
                return Err(Failure::InvalidState);
            }
            restoration::prepare(store, selection, Some(&mut current))
        }
    } else {
        match restoration::prepare(store, selection.clone(), None) {
            Err(restoration::Failure::Primary(crate::primary::Failure::VaultLocked)) => {
                let authentication = methods(store, &selection)?;
                preparation.validate()?;
                return Ok(Outcome::Authentication(authentication));
            }
            other => other,
        }
    };
    preparation.validate()?;
    Ok(Outcome::Reviewed(Reviewed {
        token: uuid::Uuid::new_v4(),
        review: Box::new(result?),
        preparation,
        rekeyed,
    }))
}

pub(crate) struct SelectedFile {
    token: uuid::Uuid,
    file: restoration::SourceFile,
    preparation: Preparation,
}
impl SelectedFile {
    pub(crate) fn inspect<B: Backend>(
        store: &mut Store<B>,
        selection: &restoration::Selection,
        path: &Path,
        preparation: Preparation,
    ) -> Result<(Self, Authentication)> {
        preparation.validate()?;
        let file = restoration::inspect_source_file(store, selection, path)?;
        preparation.validate()?;
        let mut access = methods(store, selection)?;
        access.previous = Some(Methods {
            passphrase: file.has_passphrase(),
            recovery: file.has_recovery(),
        });
        access.previous_suggested = true;
        access.previous_backup = file.is_backup();
        let selected = Self {
            token: uuid::Uuid::new_v4(),
            file,
            preparation,
        };
        Ok((selected, access))
    }
    pub(crate) fn token(&self) -> uuid::Uuid {
        self.token
    }
    pub(crate) fn consume<B: Backend>(
        self,
        store: &mut Store<B>,
        token: uuid::Uuid,
        selection: &restoration::Selection,
    ) -> Result<restoration::SourceFile> {
        self.preparation.validate()?;
        if token != self.token || !self.file.matches_selection(selection) {
            return Err(Failure::InvalidState);
        }
        self.file.validate(store)?;
        Ok(self.file)
    }
}

#[cfg(test)]
#[path = "account_restoration_tests.rs"]
mod tests;
