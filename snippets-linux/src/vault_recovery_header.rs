//! Retained encrypted key wraps, without catalogue records or extra metadata.
//! This is protected-history data, never a diagnostic or plaintext export.
use super::*;

pub(crate) const MAX_HEADER_BYTES: usize = 16 * 1024;

/// Body-free worker data. No root key, credential, Debug or public serialization.
#[derive(Clone, PartialEq)]
pub struct RecoveryHeader {
    identity: Identity,
}
/// One preparation lifetime, including suspension and wall-clock changes.
/// The retained key is owned, never copied from a live editor session.
pub struct RecoveryOwner {
    authentication: Authentication,
    document: Document,
    started: Duration,
    wall: std::time::SystemTime,
}
impl RecoveryOwner {
    pub(crate) fn with_many_keys<T>(
        owners: &[&Self],
        operation: impl FnOnce(&[&crate::materializer::Keyring<'_>]) -> T,
    ) -> Result<T> {
        if owners.is_empty() || owners.len() > 8 {
            return Err(UNREADABLE);
        }
        let mut keys = Vec::with_capacity(owners.len());
        for owner in owners {
            owner.validate()?;
            keys.push(
                crate::materializer::Keyring::new(&owner.authentication.key, &owner.document)
                    .map_err(|_| UNREADABLE)?,
            );
        }
        let references = keys.iter().collect::<Vec<_>>();
        let result = operation(&references);
        for owner in owners {
            owner.validate()?;
        }
        Ok(result)
    }
    fn validate(&self) -> Result<()> {
        let now = crate::clock::uptime().ok_or(EXPIRED)?;
        self.validate_at(now, std::time::SystemTime::now())
    }
    fn validate_at(&self, now: Duration, wall: std::time::SystemTime) -> Result<()> {
        let wall = wall.duration_since(self.wall).map_err(|_| EXPIRED)?;
        if now < self.started
            || now - self.started >= Duration::from_secs(120)
            || wall >= Duration::from_secs(120)
        {
            return Err(EXPIRED);
        }
        Ok(())
    }
    #[cfg(test)]
    pub(crate) fn with_keys<T>(
        &self,
        operation: impl FnOnce(&crate::materializer::Keyring<'_>) -> T,
    ) -> Result<T> {
        self.validate()?;
        let keys = crate::materializer::Keyring::new(&self.authentication.key, &self.document)
            .map_err(|_| UNREADABLE)?;
        let result = operation(&keys);
        self.validate()?;
        Ok(result)
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Format {
    schema_version: u8,
    kid: String,
    vault_salt: String,
    kdf: KdfParameters,
    wrap_pass: Option<Sealed>,
    wrap_recovery: Option<Sealed>,
    #[serde(rename = "wrapCLI")]
    wrap_cli: Option<Sealed>,
}

impl RecoveryHeader {
    fn document(&self) -> Document {
        Document {
            schema_version: 1,
            kid: self.identity.kid.clone(),
            vault_salt: self.identity.salt.clone(),
            kdf: self.identity.kdf.clone(),
            wrap_pass: self.identity.pass.clone(),
            wrap_recovery: self.identity.recovery.clone(),
            wrap_cli: self.identity.cli.clone(),
            records: Vec::new(),
            extra: BTreeMap::new(),
        }
    }
    pub(crate) fn retain(document: &Document) -> Result<Self> {
        if document.schema_version != 1 {
            return Err(UNREADABLE);
        }
        let header = Self {
            identity: document.identity(),
        };
        // Validate the same bounds used when reopening a protected receipt.
        Self::decode_secret(&header.encode_secret()?)
    }
    pub(crate) fn encode_secret(&self) -> Result<Zeroizing<Vec<u8>>> {
        let identity = &self.identity;
        let bytes = Zeroizing::new(
            serde_json::to_vec(&Format {
                schema_version: 1,
                kid: identity.kid.clone(),
                vault_salt: identity.salt.clone(),
                kdf: identity.kdf.clone(),
                wrap_pass: identity.pass.clone(),
                wrap_recovery: identity.recovery.clone(),
                wrap_cli: identity.cli.clone(),
            })
            .map_err(|_| UNREADABLE)?,
        );
        if bytes.len() > MAX_HEADER_BYTES {
            return Err(UNREADABLE);
        }
        Ok(bytes)
    }
    pub(crate) fn decode_secret(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAX_HEADER_BYTES {
            return Err(UNREADABLE);
        }
        let format: Format = serde_json::from_slice(bytes).map_err(|_| UNREADABLE)?;
        if format.schema_version != 1 {
            return Err(UNREADABLE);
        }
        let document = Document {
            schema_version: format.schema_version,
            kid: format.kid,
            vault_salt: format.vault_salt,
            kdf: format.kdf,
            wrap_pass: format.wrap_pass,
            wrap_recovery: format.wrap_recovery,
            wrap_cli: format.wrap_cli,
            records: Vec::new(),
            extra: BTreeMap::new(),
        };
        document.encode()?;
        Ok(Self {
            identity: document.identity(),
        })
    }
    pub fn has_passphrase(&self) -> bool {
        self.identity.pass.is_some()
    }
    pub fn has_recovery(&self) -> bool {
        self.identity.recovery.is_some()
    }
    pub(crate) fn same_key_scope(&self, document: &Document) -> bool {
        self.identity.kid == document.kid && self.identity.salt == document.vault_salt
    }
    /// A fresh owner authenticates independently; no session key is copied.
    pub fn authenticate(&self, text: &str, recovery: bool) -> Result<Authentication> {
        if text.len() > 4096 {
            return Err(Error("Vault credentials must be within the 4 KiB limit."));
        }
        self.identity.authenticate(text, recovery)
    }
    pub fn authenticate_for_restoration(
        &self,
        text: &str,
        recovery: bool,
    ) -> Result<RecoveryOwner> {
        let started = crate::clock::uptime().ok_or(EXPIRED)?;
        let wall = std::time::SystemTime::now();
        let owner = RecoveryOwner {
            authentication: self.authenticate(text, recovery)?,
            document: self.document(),
            started,
            wall,
        };
        owner.validate()?;
        Ok(owner)
    }
    pub(crate) fn backup_owner(
        &self,
        key: RootKey,
        started: Duration,
        wall: std::time::SystemTime,
    ) -> Result<RecoveryOwner> {
        let owner = RecoveryOwner {
            authentication: Authentication {
                key,
                identity: self.identity.clone(),
            },
            document: self.document(),
            started,
            wall,
        };
        owner.validate()?;
        Ok(owner)
    }
}

#[cfg(test)]
#[path = "vault_recovery_header_tests.rs"]
mod tests;
