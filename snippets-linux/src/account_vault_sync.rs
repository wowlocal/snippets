//! One-use current-vault authentication for an explicit bounded sync cycle.
//! No editor session, plaintext, key or record metadata is returned to GTK.
use super::*;
use crate::{
    journal::Scope,
    materializer::Keyring,
    secure_insertion::Source,
    vault::{Authentication, Document},
};
use std::path::Path;

pub(crate) type Authorization = restoration_task::Preparation;
pub(crate) struct Request {
    token: uuid::Uuid,
    scope: Scope,
    epoch: u64,
    document: Document,
    source: Source,
    authorization: Authorization,
}
pub(crate) struct Authenticated {
    request: Request,
    authentication: Authentication,
}
#[derive(Clone, Copy)]
pub(crate) struct Methods {
    pub(crate) passphrase: bool,
    pub(crate) recovery: bool,
}
impl Request {
    pub(crate) fn capture(
        root: &Path,
        scope: &Scope,
        epoch: u64,
        authorization: Authorization,
    ) -> Result<Self> {
        authorization.validate()?;
        let library = crate::model::Library::prepare(root.into())
            .map_err(|_| Failure::VaultAuthentication)?;
        let _lock = library
            .try_lock()
            .map_err(|_| Failure::VaultAuthentication)?;
        let document = crate::vault::read_document_locked(root)
            .map_err(|_| Failure::VaultAuthentication)?
            .ok_or(Failure::VaultAuthentication)?;
        if document.wrap_pass.is_none() && document.wrap_recovery.is_none() {
            return Err(Failure::VaultAuthentication);
        }
        let (source, bytes) = Source::prove(root).map_err(|_| Failure::VaultAuthentication)?;
        if Document::decode(&bytes).map_err(|_| Failure::VaultAuthentication)? != document {
            return Err(Failure::VaultAuthentication);
        }
        authorization.validate()?;
        Ok(Self {
            token: uuid::Uuid::new_v4(),
            scope: scope.clone(),
            epoch,
            document,
            source,
            authorization,
        })
    }
    pub(crate) fn presentation(&self) -> (uuid::Uuid, Methods) {
        (
            self.token,
            Methods {
                passphrase: self.document.wrap_pass.is_some(),
                recovery: self.document.wrap_recovery.is_some(),
            },
        )
    }
    pub(crate) fn authenticate(
        self,
        token: uuid::Uuid,
        credential: Zeroizing<String>,
        recovery: bool,
    ) -> Result<Authenticated> {
        self.authorization.validate()?;
        if token != self.token || credential.is_empty() || credential.len() > 4096 {
            return Err(Failure::VaultAuthentication);
        }
        self.source
            .authenticate_current()
            .map_err(|_| Failure::VaultAuthentication)?;
        let authentication = self
            .document
            .authenticate(&credential, recovery)
            .map_err(|_| Failure::VaultAuthentication)?;
        drop(credential);
        self.authorization.validate()?;
        self.source
            .authenticate_current()
            .map_err(|_| Failure::VaultAuthentication)?;
        authentication
            .sync_keyring(&self.document)
            .map_err(|_| Failure::VaultAuthentication)?;
        Ok(Authenticated {
            request: self,
            authentication,
        })
    }
}
impl Authenticated {
    pub(crate) fn validate(&self) -> Result<()> {
        self.request.authorization.validate()
    }
    pub(crate) fn bind(&self, scope: &Scope, epoch: u64) -> Result<()> {
        self.validate()?;
        if &self.request.scope != scope || self.request.epoch != epoch {
            return Err(local_auth::Failure::WrongTarget.into());
        }
        // Called exactly once before entering the data plane; later own record
        // changes are admitted by Keyring::matches and exact primary before-images.
        self.request
            .source
            .authenticate_current()
            .map_err(|_| Failure::VaultAuthentication)
    }
    pub(crate) fn keys(&self) -> Result<Keyring<'_>> {
        self.validate()?;
        self.authentication
            .sync_keyring(&self.request.document)
            .map_err(|_| Failure::VaultAuthentication)
    }
}
#[cfg(test)]
#[path = "account_vault_sync_tests.rs"]
mod tests;
