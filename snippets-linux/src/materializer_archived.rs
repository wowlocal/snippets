//! Only explicitly authenticated old-vault preparation uses this boundary.
//! Absent own metadata can be recovered from the authenticated AAD/body. Current
//! wire records, raw v1 carriers and the normal materializer remain strict.
use super::*;

pub(crate) struct Archived<'a, 'b> {
    keys: &'a Keyring<'b>,
}
/// Borrowed only inside all bounded source owners. A stamp is a candidate hint;
/// exactly one authenticated AAD/body/hash owner is required for every body.
pub(crate) struct ArchivedKeys<'a, 'b> {
    pub(super) keys: &'a [&'a Keyring<'b>],
}
impl<'a, 'b> ArchivedKeys<'a, 'b> {
    pub(crate) fn new(keys: &'a [&'a Keyring<'b>]) -> Result<Self> {
        if keys.is_empty() || keys.len() > 8 {
            return Err(Failure::IncompatibleVault);
        }
        Ok(Self { keys })
    }
    pub(super) fn body(&self, source: &Envelope) -> Result<(usize, Zeroizing<Vec<u8>>)> {
        let mut result = None;
        for (index, keys) in self.keys.iter().enumerate() {
            if let Ok(body) = Archived::new(keys).body(source) {
                if result.is_some() {
                    return Err(Failure::IncompatibleVault);
                }
                result = Some((index, body));
            }
        }
        result.ok_or(Failure::IncompatibleVault)
    }
    pub(super) fn variant(&self, variant: &SecureVariant) -> Result<(usize, Zeroizing<Vec<u8>>)> {
        let mut result = None;
        for (index, keys) in self.keys.iter().enumerate() {
            if let Ok(body) = authenticate_variant(variant, keys) {
                if result.is_some() {
                    return Err(Failure::IncompatibleVault);
                }
                result = Some((index, body));
            }
        }
        result.ok_or(Failure::IncompatibleVault)
    }
    pub(super) fn hash(&self, index: usize, body: &[u8]) -> String {
        Archived::new(self.keys[index]).hash(body)
    }
    pub(crate) fn evidence(
        &self,
        sources: &[Envelope],
        frozen: &BTreeMap<Uuid, Envelope>,
    ) -> Result<Evidence> {
        let mut copies = BTreeMap::new();
        for source in sources {
            merge::validate(source)?;
            for variant in merge::secure_variants(source)? {
                if copies.contains_key(&variant.copy_id) {
                    return Err(Failure::IdentifierCollision);
                }
                let (index, original) = self.variant(&variant)?;
                let copy = if let Some(copy) = frozen.get(&variant.copy_id) {
                    let (_, body) = self.body(copy)?;
                    validate_evidence_fields(copy, &variant)?;
                    if copy.extensions.keys().any(|key| {
                        !matches!(
                            key.as_str(),
                            "vaultKID" | "vaultContentHash" | merge::COPY_PROVENANCE
                        )
                    }) {
                        return Err(Failure::MalformedVariant);
                    }
                    // The exact C0 may have been sealed by another explicitly
                    // authenticated vault. Its own hash was checked with that
                    // key; compare its body with the original using one key.
                    self.keys[index].verify(&body, &self.hash(index, &original))?;
                    copy.clone()
                } else {
                    make_copy(&variant, self.keys[index])?
                };
                copies.insert(copy.id, copy);
            }
        }
        Ok(Evidence { copies })
    }
}

#[cfg(test)]
#[path = "materializer_archived_tests.rs"]
mod tests;
impl<'a, 'b> Archived<'a, 'b> {
    pub(crate) fn new(keys: &'a Keyring<'b>) -> Self {
        Self { keys }
    }
    pub(super) fn body(&self, envelope: &Envelope) -> Result<Zeroizing<Vec<u8>>> {
        merge::validate(envelope)?;
        if envelope.deleted || !envelope.secure {
            return Err(Failure::IncompatibleVault);
        }
        // Only absence is repairable. A present wrong/empty/malformed stamp or
        // hash is never replaced by a guessed current value.
        stamp(envelope, self.keys, false)?;
        let fields = envelope.fields.as_ref().ok_or(Failure::MalformedVariant)?;
        let body = self.keys.open(&fields.content, envelope.id)?;
        if let Some(hash) = envelope.extensions.get("vaultContentHash") {
            self.keys.verify(&body, hash.as_text()?)?;
        }
        Ok(body)
    }
    pub(super) fn hash(&self, body: &[u8]) -> String {
        crypto::content_hash(body, self.keys.key, &self.keys.salt)
    }
    #[cfg(test)]
    pub(crate) fn evidence(
        &self,
        sources: &[Envelope],
        frozen: &BTreeMap<Uuid, Envelope>,
    ) -> Result<Evidence> {
        ArchivedKeys::new(&[self.keys])?.evidence(sources, frozen)
    }
}
