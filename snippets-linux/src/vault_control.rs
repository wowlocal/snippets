//! Fresh one-use vault operations. The worker retains bodies and keys; GTK sees a preview.
use super::*;
use crate::{
    control::{self, Header, Lease, Reply, Status},
    secure_insertion::{Authorization, Source},
};

enum Operation {
    Reveal(Record),
    Create(Metadata, Zeroizing<Vec<u8>>),
}
pub(crate) struct Captured {
    library: Library,
    document: Document,
    source: Source,
    operation: Operation,
    lease: Lease,
    nonce: Uuid,
}
pub(crate) struct Preview {
    pub metadata: Metadata,
    pub passphrase: bool,
    pub recovery: bool,
}
type Outcome<T> = std::result::Result<T, Status>;
pub(crate) struct Delivery {
    root: PathBuf,
    source: Source,
}
impl Delivery {
    pub(crate) fn validate(&self) -> Result<()> {
        crate::primary::require_ready(&self.root)?;
        self.source.validate()
    }
}
impl Captured {
    pub(crate) fn capture(
        root: PathBuf,
        header: &Header,
        body: Zeroizing<Vec<u8>>,
        lease: Lease,
    ) -> Outcome<Self> {
        header.validate().map_err(|_| Status::Refused)?;
        lease.check().map_err(|_| Status::Denied)?;
        if header.bytes != body.len() {
            return Err(Status::Refused);
        }
        let library = Library::prepare(root).map_err(|_| Status::Error)?;
        let guard = library.try_lock().map_err(|_| Status::Refused)?;
        let owner = Vault::open_locked(&library).map_err(|_| Status::Refused)?;
        let document = owner.document.ok_or(if header.command == "reveal" {
            Status::NotFound
        } else {
            Status::Locked
        })?;
        let (source, bytes) = Source::prove(&library.root).map_err(|_| Status::Refused)?;
        if Document::decode(&bytes).map_err(|_| Status::Refused)? != document {
            return Err(Status::Refused);
        }
        let operation = match header.command.as_str() {
            "reveal" => {
                let identifier = header.identifier.as_deref().ok_or(Status::NotFound)?;
                let folded = model::folded(&model::keyword(identifier));
                let matches: Vec<_> = document
                    .records
                    .iter()
                    .filter(|r| {
                        r.metadata.id.to_string().eq_ignore_ascii_case(identifier)
                            || !r.metadata.keyword.is_empty()
                                && model::folded(&r.metadata.keyword) == folded
                    })
                    .collect();
                if matches.len() != 1 {
                    return Err(Status::NotFound);
                }
                Operation::Reveal(matches[0].clone())
            }
            "add-secure" => {
                let addition = header.addition.as_ref().ok_or(Status::Refused)?;
                if body.is_empty()
                    || body.len() > model::MAX_BODY_BYTES
                    || std::str::from_utf8(&body).is_err()
                    || body.contains(&0)
                {
                    return Err(Status::Refused);
                }
                let mut metadata = Metadata::new();
                metadata.name = addition.name.clone();
                metadata.keyword = addition.keyword.clone();
                metadata.tags = addition.tags.clone();
                metadata.is_enabled = addition.is_enabled;
                metadata.is_pinned = addition.is_pinned;
                Operation::Create(metadata.validate().map_err(|_| Status::Refused)?, body)
            }
            _ => return Err(Status::Unsupported),
        };
        lease.check().map_err(|_| Status::Denied)?;
        drop(guard);
        Ok(Self {
            library,
            document,
            source,
            operation,
            lease,
            nonce: header.nonce,
        })
    }
    pub(crate) fn preview(&self) -> Preview {
        Preview {
            metadata: match &self.operation {
                Operation::Reveal(r) => r.metadata.clone(),
                Operation::Create(m, _) => m.clone(),
            },
            passphrase: self.document.wrap_pass.is_some(),
            recovery: self.document.wrap_recovery.is_some(),
        }
    }
    pub(crate) fn complete(
        self,
        password: Zeroizing<String>,
        recovery: bool,
        authorization: &Authorization,
    ) -> Outcome<Reply> {
        let check = || {
            self.lease.check().map_err(|_| Status::Denied)?;
            authorization.validate().map_err(|_| Status::Denied)
        };
        check()?;
        let authentication = self
            .document
            .authenticate(&password, recovery)
            .map_err(|_| Status::Locked)?;
        drop(password);
        check()?;
        let _guard = self.library.try_lock().map_err(|_| Status::Refused)?;
        crate::primary::require_ready(&self.library.root).map_err(|_| Status::Refused)?;
        self.source
            .authenticate_current()
            .map_err(|_| Status::Refused)?;
        check()?;
        let mut owner = Vault::open_locked(&self.library).map_err(|_| Status::Refused)?;
        if owner.document.as_ref() != Some(&self.document)
            || authentication.identity != self.document.identity()
        {
            return Err(Status::Refused);
        }
        match self.operation {
            Operation::Reveal(record) => {
                let body = crypto::open_record(
                    &record.sealed,
                    &authentication.key,
                    &self.document.salt().map_err(|_| Status::Error)?,
                    &self.document.kid,
                    record.metadata.id,
                    false,
                )
                .map_err(|_| Status::Error)?;
                if !record.content_hash.is_empty() {
                    crypto::verify_hash(
                        &record.content_hash,
                        &body,
                        &authentication.key,
                        &self.document.salt().map_err(|_| Status::Error)?,
                    )
                    .map_err(|_| Status::Error)?;
                }
                if body.len() > model::MAX_BODY_BYTES
                    || std::str::from_utf8(&body).is_err()
                    || body.contains(&0)
                {
                    return Err(Status::Error);
                }
                check()?;
                let mut reply = Reply::status(self.nonce, Status::Ok);
                reply.header.bytes = body.len();
                reply.body = body;
                reply.delivery = Some(Delivery {
                    root: self.library.root,
                    source: self.source,
                });
                Ok(reply)
            }
            Operation::Create(mut metadata, body) => {
                let id = metadata.id;
                // This owner dies before returning. The app/editor's session is never installed or extended.
                owner.install(authentication).map_err(|_| Status::Locked)?;
                check()?;
                owner
                    .save_locked(&self.library, &mut metadata, &body, None, &|| {
                        check().map_err(|_| control::CLOSED)
                    })
                    .map_err(|_| {
                        if check().is_err() {
                            Status::Denied
                        } else {
                            Status::Refused
                        }
                    })?;
                let mut reply = Reply::status(self.nonce, Status::Ok);
                reply.header.created_id = Some(id);
                Ok(reply)
            }
        }
    }
}

#[cfg(test)]
#[path = "vault_control_tests.rs"]
mod tests;
