//! Fresh authentication admits one exact saved record into a revocable owner.
//! Unlocking/revealing an editor does not grant this delivery capability.
use super::*;
use crate::secure_insertion::{Authorization, Prepared, Source};
impl Vault {
    /// A worker owns this short-lived vault independently of the GTK editor.
    /// Fresh credentials never install a cached reveal/session capability.
    pub(crate) fn prepare_saved_insertion(
        root: PathBuf,
        expected_document: Document,
        authentication: Authentication,
        expected: Record,
        authorization: Authorization,
    ) -> Result<Prepared> {
        authorization.validate()?;
        let library = Library::prepare(root)?;
        let _guard = library.try_lock()?;
        authorization.validate()?;
        let mut owner = Self::open_locked(&library)?;
        if owner.document.as_ref() != Some(&expected_document) {
            return Err(EXPIRED);
        }
        let generation = owner.generation();
        owner.prepare_insertion_locked(
            &library,
            authentication,
            generation,
            expected,
            authorization,
        )
    }
    #[cfg(test)]
    fn prepare_insertion(
        &mut self,
        library: &Library,
        authentication: Authentication,
        generation: u64,
        expected: Record,
        authorization: Authorization,
    ) -> Result<Prepared> {
        authorization.validate()?;
        self.same_root(library)?;
        let _guard = library.try_lock()?;
        self.prepare_insertion_locked(library, authentication, generation, expected, authorization)
    }
    /// The single nonblocking lock covers document admission through decryption.
    fn prepare_insertion_locked(
        &mut self,
        library: &Library,
        authentication: Authentication,
        generation: u64,
        expected: Record,
        authorization: Authorization,
    ) -> Result<Prepared> {
        authorization.validate()?;
        self.same_root(library)?;
        let expected_document = self.document.clone().ok_or(UNREADABLE)?;
        crate::primary::require_ready(&library.root).map_err(|_| EXPIRED)?;
        self.reload_locked()?;
        let document = self.document.as_ref().ok_or(UNREADABLE)?;
        if *document != expected_document
            || self.generation != generation
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
            if matches!(changed, 2 | 4) {
                let mut saved = vault.document.clone().unwrap();
                if changed == 2 {
                    saved.records[0].metadata.is_enabled = false;
                } else {
                    saved.records[0].content_hash.clear();
                }
                vault.write(&saved).unwrap();
                vault.reload().unwrap();
            }
            let document = vault.document.as_ref().unwrap().clone();
            let expected = document.records[0].clone();
            let mut authentication = Authentication {
                key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
                identity: document.identity(),
            };
            let mut generation = vault.generation();
            match changed {
                0 => authentication.key = RootKey::from_bytes(&[0x22; 32]).unwrap(),
                1 => authentication.identity.kid = "Public changed identity".into(),
                2 => (),
                3 => generation = generation.wrapping_add(1),
                4 => (),
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
            if changed == 4 {
                assert!(matches!(
                    result,
                    Err(Error(
                        "This legacy secure entry needs its authenticated content hash repaired before direct insertion."
                    ))
                ));
            }
        }
    }

    #[test]
    fn insertion_worker_admits_exact_snapshot_without_unlocking_the_editor_owner() {
        for changed in 0..3 {
            let (_temp, library, mut vault) = super::super::tests::setup();
            let document = vault.document.clone().unwrap();
            let record = document.records[0].clone();
            let authentication = Authentication {
                key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
                identity: document.identity(),
            };
            if changed == 1 {
                let mut sibling = Metadata::new();
                sibling.name = "Public different saved entry".into();
                sibling.keyword = "public-other-entry".into();
                vault
                    .save(&library, sibling, b"Public other body", None)
                    .unwrap();
                assert!(vault.record(record.metadata.id).as_ref() == Some(&record));
            }
            let authorization = authorization();
            if changed == 2 {
                authorization.cancel();
            }
            vault.lock();
            let root = library.root.clone();
            let result = std::thread::spawn(move || {
                Vault::prepare_saved_insertion(
                    root,
                    document,
                    authentication,
                    record,
                    authorization,
                )
            })
            .join()
            .unwrap();
            assert_eq!(result.is_ok(), changed == 0);
            assert!(!vault.is_unlocked());
            if let Ok(prepared) = result {
                assert!(!prepared.needs_clipboard());
            }
        }
    }

    #[test]
    fn insertion_worker_refuses_a_busy_library_before_the_lock_is_released() {
        let (_temp, library, mut vault) = super::super::tests::setup();
        let document = vault.document.clone().unwrap();
        let record = document.records[0].clone();
        let authentication = Authentication {
            key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
            identity: document.identity(),
        };
        vault.lock();
        let guard = library.lock().unwrap();
        let root = library.root.clone();
        let authorization = authorization();
        let (reply, received) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let result = Vault::prepare_saved_insertion(
                root,
                document,
                authentication,
                record,
                authorization,
            );
            let _ = reply.send(result);
        });
        let result = received.recv_timeout(Duration::from_secs(1));
        // A regression must fail instead of leaving a worker indefinitely stuck.
        drop(guard);
        worker.join().unwrap();
        assert!(matches!(
            result,
            Ok(Err(Error(
                "The library is busy. Try the action again after the current operation finishes."
            )))
        ));
        assert!(!vault.is_unlocked());
        let document = vault.document.clone().unwrap();
        let record = document.records[0].clone();
        let authentication = Authentication {
            key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
            identity: document.identity(),
        };
        assert!(
            Vault::prepare_saved_insertion(
                library.root.clone(),
                document,
                authentication,
                record,
                self::authorization(),
            )
            .is_ok()
        );
    }
}
