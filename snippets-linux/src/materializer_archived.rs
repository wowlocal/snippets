//! Only explicitly authenticated old-vault preparation uses this boundary.
//! Absent own metadata can be recovered from the authenticated AAD/body. Current
//! wire records, raw v1 carriers and the normal materializer remain strict.
use super::*;

pub(crate) struct Archived<'a, 'b> {
    keys: &'a Keyring<'b>,
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
                // Raw v1 snapshots retain their complete, canonical shape and
                // exact original fingerprint. No field is injected into them.
                let copy = if let Some(copy) = frozen.get(&variant.copy_id) {
                    let original = authenticate_variant(&variant, self.keys)?;
                    let body = self.body(copy)?;
                    validate_evidence_fields(copy, &variant)?;
                    if copy.extensions.keys().any(|key| {
                        !matches!(
                            key.as_str(),
                            "vaultKID" | "vaultContentHash" | merge::COPY_PROVENANCE
                        )
                    }) || copy.extensions.get("vaultContentHash").is_some_and(|hash| {
                        Some(hash) != variant.source_extensions.get("vaultContentHash")
                    }) {
                        return Err(Failure::MalformedVariant);
                    }
                    // Without a retained hash, even a valid same-provenance C1
                    // must not impersonate C0. Compare both authenticated bodies
                    // through the existing constant-time keyed-hash validator.
                    self.keys.verify(&body, &self.hash(&original))?;
                    copy.clone()
                } else {
                    make_copy(&variant, self.keys)?
                };
                copies.insert(copy.id, copy);
            }
        }
        Ok(Evidence { copies })
    }
}
