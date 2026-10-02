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
pub(crate) struct MultipleCredentials {
    pub(crate) current: Credential,
    pub(crate) retained: Option<Credential>,
    pub(crate) files: Vec<Credential>,
}
#[derive(Clone, Copy)]
pub(crate) struct FileMethods {
    pub(crate) methods: Methods,
    pub(crate) backup: bool,
}
pub(crate) struct MultipleAuthentication {
    pub(crate) base: Authentication,
    pub(crate) files: Vec<FileMethods>,
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
            let source = authenticated.map_err(previous_failure)?;
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
fn previous_failure(error: restoration::Failure) -> Failure {
    match error {
        restoration::Failure::Key(key_store::Failure::InvalidState) => {
            Failure::PreviousVaultAuthentication
        }
        other => other.into(),
    }
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
        preparation.validate()?;
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

/// Serialized worker retention. Tokens are consumed even by a failed attempt;
/// neither roots nor credentials survive a preparation call.
#[derive(Default)]
pub(crate) struct Retained {
    file: Option<SelectedFile>,
    files: Option<SelectedFiles>,
    reviewed: Option<Reviewed>,
}
impl Retained {
    pub(crate) fn keep_for(&mut self, command: &Command) {
        if !matches!(
            command,
            Command::CommitRestoration { .. } | Command::Authenticate { .. }
        ) {
            self.reviewed = None;
        }
        if !matches!(command, Command::PrepareRestoration { .. }) {
            self.file = None;
        }
        if !matches!(command, Command::PrepareMultipleRestoration { .. }) {
            self.files = None;
        }
    }
    pub(crate) fn inspect<B: Backend>(
        &mut self,
        store: &mut Store<B>,
        selection: &restoration::Selection,
        path: &Path,
        preparation: Preparation,
    ) -> Result<Reply> {
        self.file = None;
        self.files = None;
        self.reviewed = None;
        let (selected, methods) = SelectedFile::inspect(store, selection, path, preparation)?;
        let token = selected.token();
        self.file = Some(selected);
        Ok(Reply::RestorationFile { token, methods })
    }
    pub(crate) fn prepare<B: Backend>(
        &mut self,
        store: &mut Store<B>,
        selection: restoration::Selection,
        credentials: Option<Credentials>,
        preparation: Preparation,
        source_file: Option<uuid::Uuid>,
    ) -> Result<Reply> {
        self.reviewed = None;
        self.files = None;
        let selected = self.file.take();
        preparation.validate()?;
        let file = match source_file {
            Some(token) => Some(
                selected
                    .ok_or(Failure::InvalidState)?
                    .consume(store, token, &selection)?,
            ),
            None => None,
        };
        match prepare_with_file(store, selection, credentials, preparation, file)? {
            Outcome::Authentication(methods) => Ok(Reply::RestorationAuthentication(methods)),
            Outcome::Reviewed(reviewed) => {
                let reply = reviewed.reply()?;
                self.reviewed = Some(reviewed);
                Ok(reply)
            }
        }
    }
    pub(crate) fn consume(&mut self, token: uuid::Uuid) -> Result<restoration::Review> {
        self.reviewed
            .take()
            .ok_or(Failure::InvalidState)?
            .consume(token)
    }
    pub(crate) fn inspect_multiple<B: Backend>(
        &mut self,
        store: &mut Store<B>,
        selection: &restoration::Selection,
        paths: &[std::path::PathBuf],
        preparation: Preparation,
    ) -> Result<Reply> {
        self.file = None;
        self.files = None;
        self.reviewed = None;
        preparation.validate()?;
        if paths.is_empty() || paths.len() > 8 {
            return Err(Failure::InvalidState);
        }
        let mut files = Vec::with_capacity(paths.len());
        let mut hints = Vec::with_capacity(paths.len());
        for path in paths {
            preparation.validate()?;
            let file = restoration::inspect_additional_source_file(store, selection, path)?;
            hints.push(FileMethods {
                methods: Methods {
                    passphrase: file.has_passphrase(),
                    recovery: file.has_recovery(),
                },
                backup: file.is_backup(),
            });
            files.push(file);
        }
        let base = methods(store, selection)?;
        preparation.validate()?;
        for file in &files {
            file.validate(store)?;
            preparation.validate()?;
        }
        let token = uuid::Uuid::new_v4();
        self.files = Some(SelectedFiles {
            token,
            files,
            preparation,
        });
        Ok(Reply::RestorationFiles {
            token,
            methods: MultipleAuthentication { base, files: hints },
        })
    }
    pub(crate) fn prepare_multiple<B: Backend>(
        &mut self,
        store: &mut Store<B>,
        selection: restoration::Selection,
        credentials: MultipleCredentials,
        preparation: Preparation,
        source_files: uuid::Uuid,
    ) -> Result<Reply> {
        self.file = None;
        self.reviewed = None;
        let selected = self.files.take().ok_or(Failure::InvalidState)?;
        preparation.validate()?;
        selected.preparation.validate()?;
        if selected.token != source_files
            || selected.files.len() != credentials.files.len()
            || selected.files.len() + usize::from(credentials.retained.is_some()) > 8
            || selected
                .files
                .iter()
                .any(|file| !file.matches_selection(&selection))
        {
            return Err(Failure::InvalidState);
        }
        credentials.current.validate()?;
        for credential in credentials.retained.iter().chain(&credentials.files) {
            credential.validate()?;
        }
        let root = store.transaction(|owner| Ok(owner.root().to_path_buf()))?;
        let mut current = unlock_current(&root, &credentials.current, &|| preparation.validate())?;
        let mut sources = Vec::with_capacity(selected.files.len() + 1);
        if let Some(credential) = credentials.retained {
            preparation.validate()?;
            sources.push(
                restoration::authenticate_source(
                    store,
                    &selection,
                    &credential.value,
                    credential.recovery,
                )
                .map_err(previous_failure)?,
            );
        }
        for (file, credential) in selected.files.into_iter().zip(credentials.files) {
            preparation.validate()?;
            selected.preparation.validate()?;
            sources.push(
                file.authenticate(store, &credential.value, credential.recovery)
                    .map_err(previous_failure)?,
            );
            preparation.validate()?;
        }
        selected.preparation.validate()?;
        let review = restoration::prepare_multiple(store, selection, &mut current, sources)?;
        selected.preparation.validate()?;
        preparation.validate()?;
        let reviewed = Reviewed {
            token: uuid::Uuid::new_v4(),
            review: Box::new(review),
            preparation,
            rekeyed: true,
        };
        let reply = reviewed.reply()?;
        self.reviewed = Some(reviewed);
        Ok(reply)
    }
}
struct SelectedFiles {
    token: uuid::Uuid,
    files: Vec<restoration::SourceFile>,
    preparation: Preparation,
}

#[cfg(test)]
#[path = "account_restoration_tests.rs"]
mod tests;
