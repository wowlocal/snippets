//! Fresh authentication admits one exact saved record into a revocable owner.
//! Unlocking/revealing an editor does not grant this delivery capability.
use super::*;
use crate::secure_insertion::{Authorization, Prepared, Source};
impl Vault {
    pub(crate) fn prepare_insertion(
        &mut self,
        library: &Library,
        authentication: Authentication,
        generation: u64,
        expected: Record,
        authorization: Authorization,
    ) -> Result<Prepared> {
        authorization.validate()?;
        self.same_root(library)?;
        let _guard = library.lock()?;
        crate::primary::require_ready(&library.root).map_err(|_| EXPIRED)?;
        self.reload_locked()?;
        let document = self.document.as_ref().ok_or(UNREADABLE)?;
        if self.generation != generation
            || document.identity() != authentication.identity
            || self.record(expected.metadata.id).as_ref() != Some(&expected)
            || !expected.metadata.is_enabled
        {
            return Err(EXPIRED);
        }
        let (source, bytes) = Source::prove(&library.root)?;
        if Document::decode(&bytes)? != *document {
            return Err(EXPIRED);
        }
        let body = crypto::open_record(
            &expected.sealed,
            &authentication.key,
            &document.salt()?,
            &document.kid,
            expected.metadata.id,
            false,
        )?;
        if expected.content_hash.is_empty() {
            return Err(Error(
                "This legacy secure entry needs its authenticated content hash repaired before direct insertion.",
            ));
        }
        crypto::verify_hash(
            &expected.content_hash,
            &body,
            &authentication.key,
            &document.salt()?,
        )?;
        authorization.validate()?;
        Prepared::new(source, body, authorization)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn authorization() -> Authorization {
        Authorization::new(crate::desktop::SessionWitness::test(
            crate::desktop::SessionState::Unlocked,
            1,
        ))
        .unwrap()
    }
    #[test]
    fn fresh_record_delivery_refuses_wrong_key_identity_disabled_stale_and_unstamped_records() {
        for changed in 0..6 {
            let (_temp, library, mut vault) = super::super::tests::setup();
            let document = vault.document.as_ref().unwrap().clone();
            let mut expected = document.records[0].clone();
            let mut authentication = Authentication {
                key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
                identity: document.identity(),
            };
            let mut generation = vault.generation();
            match changed {
                0 => authentication.key = RootKey::from_bytes(&[0x22; 32]).unwrap(),
                1 => authentication.identity.kid = "Public changed identity".into(),
                2 => expected.metadata.is_enabled = false,
                3 => generation = generation.wrapping_add(1),
                4 => expected.content_hash.clear(),
                5 => (),
                _ => unreachable!(),
            }
            let result = vault.prepare_insertion(
                &library,
                authentication,
                generation,
                expected,
                authorization(),
            );
            assert_eq!(result.is_ok(), changed == 5);
        }
    }
}
