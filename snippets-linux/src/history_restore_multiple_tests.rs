//! Whole archived graphs crossing two fictional source vaults and a current root.
use super::*;
const EXTRA_PASSWORD: &str = "Public extra vault password";
pub(super) fn mixed(queued: bool, backup: bool) -> (Saved, std::path::PathBuf) {
    let mut saved = saved(queued);
    let a = document();
    let mut b = a.clone();
    b.vault_salt = crypto::b64(&[0x88; 32]);
    b.records.clear();
    let old = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let new = RootKey::from_bytes(&[0x77; 32]).unwrap();
    let (kdf, wrap) = crypto::wrap_passphrase_cost(&new, EXTRA_PASSWORD, &b.kid, 1).unwrap();
    b.kdf = kdf;
    b.wrap_pass = Some(wrap);
    b.wrap_recovery = None;
    b.wrap_cli = None;
    let mut unrelated = a.records[0].clone();
    unrelated.metadata.id = Uuid::from_u128(9001);
    unrelated.metadata.keyword = "public-extra-source-only".into();
    let body = b"Public source-only record which must not be imported";
    unrelated.sealed = crypto::seal_record(
        body,
        &new,
        &b.salt().unwrap(),
        &b.kid,
        unrelated.metadata.id,
        false,
    )
    .unwrap();
    unrelated.content_hash = crypto::content_hash(body, &new, &b.salt().unwrap());
    b.records.push(unrelated);
    let mut cache = BTreeMap::<(Uuid, String), (crypto::Sealed, String)>::new();
    let id = saved.selected.id;
    legacy_metadata::rewrite_archive(&mut saved, |journal| {
        journal.test_transform_own_records(|e| {
            if e.id != id || !e.secure || e.deleted {
                return;
            }
            let seal = std::str::from_utf8(&e.fields.as_ref().unwrap().content)
                .unwrap()
                .to_owned();
            let (sealed, hash) = cache.entry((e.id, seal.clone())).or_insert_with(|| {
                let body = crypto::open_record(
                    &crypto::Sealed::parse(seal).unwrap(),
                    &old,
                    &a.salt().unwrap(),
                    &a.kid,
                    e.id,
                    false,
                )
                .unwrap();
                (
                    crypto::seal_record(&body, &new, &b.salt().unwrap(), &b.kid, e.id, false)
                        .unwrap(),
                    crypto::content_hash(&body, &new, &b.salt().unwrap()),
                )
            });
            e.fields.as_mut().unwrap().content = Zeroizing::new(sealed.text().as_bytes().to_vec());
            e.extensions.insert("vaultKID".into(), Value::text(&b.kid));
            e.extensions
                .insert("vaultContentHash".into(), Value::text(hash.as_str()));
        });
    });
    let file = saved.setup.temp.path().join(if backup {
        "public additional source.snippetsbackup"
    } else {
        "public additional source.json"
    });
    let bytes = if backup {
        crate::backup::seal(&[], Some((&b, &new)), EXTRA_PASSWORD).unwrap()
    } else {
        b.encode().unwrap()
    };
    crate::model::atomic_write(&file, &bytes).unwrap();
    (saved, file)
}
fn selection(saved: &mut Saved) -> restore::Selection {
    history::inspect(&mut saved.setup.store).unwrap().switches[0]
        .selection
        .clone()
}
fn primary_source(saved: &mut Saved, selection: &restore::Selection) -> restore::Source {
    restore::authenticate_source(
        &mut saved.setup.store,
        selection,
        &crypto::format_recovery(&[0x66; 16]),
        true,
    )
    .unwrap()
}
fn additional_source(
    saved: &mut Saved,
    selection: &restore::Selection,
    path: &std::path::Path,
) -> restore::Source {
    restore::inspect_additional_source_file(&mut saved.setup.store, selection, path)
        .unwrap()
        .authenticate(&mut saved.setup.store, EXTRA_PASSWORD, false)
        .unwrap()
}
pub(super) fn assert_result(
    saved: &mut Saved,
    before: &Journal,
    protected: &[Option<Zeroizing<Vec<u8>>>],
    queued: bool,
) {
    let after = read_journal(&mut saved.setup).journal;
    assert!(before.preserves_transport_state(&after) && before.outbound == after.outbound);
    assert!(capabilities(&saved.setup) == protected);
    let current_doc = crate::vault::read_document(saved.setup.temp.path())
        .unwrap()
        .unwrap();
    assert!(current_doc.same_identity(&saved.current));
    assert!(
        current_doc
            .records
            .iter()
            .all(|record| record.metadata.id != Uuid::from_u128(9001))
    );
    let mut current = unlock_current(&saved.setup, &current_doc);
    assert!(current_doc.records.iter().any(|record| {
        current.body(record.metadata.id).unwrap().as_slice() == b"Public selected secure C1 body"
    }));
    let root = RootKey::from_bytes(&[0x44; 32]).unwrap();
    let keys = Keyring::new(&root, &current_doc).unwrap();
    crate::materializer::authenticate_generations(&after.restoration_generations().unwrap(), &keys)
        .unwrap();
    current.lock();
    let originals = after.conflict_snapshots();
    let original = originals
        .values()
        .find(|e| {
            e.secure
                && merge::provenance(e)
                    .is_some_and(|p| p.source_id == document().records[0].metadata.id)
                && e.fields.as_ref().unwrap().name == saved.original.fields.as_ref().unwrap().name
        })
        .unwrap();
    let id = original.id;
    let nonces = after
        .restoration_generations()
        .unwrap()
        .iter()
        .flat_map(|g| &g.sources)
        .flat_map(|(_, copies)| copies)
        .filter(|e| e.id == id)
        .map(|e| e.hash().unwrap())
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(nonces.len(), if queued { 2 } else { 1 });
    let mut status = crate::sender::Status::MoreBatches;
    for _ in 0..8 {
        status = send_fixture(&saved.setup, &mut saved.server, false).status;
        if status == crate::sender::Status::ReceiveFirst {
            with_fixture(&saved.setup, &mut saved.server, |owner, server| {
                assert_eq!(
                    owner.receive(server, 8).unwrap().status,
                    crate::receiver::Status::Current
                )
            });
            status = crate::sender::Status::MoreBatches;
        }
        if status != crate::sender::Status::MoreBatches {
            break;
        }
    }
    assert_eq!(status, crate::sender::Status::Settled);
    let first = saved
        .server
        .submitted
        .iter()
        .position(|batch| batch.iter().any(|(e, _)| e == original))
        .unwrap();
    let last = saved
        .server
        .submitted
        .iter()
        .rposition(|batch| batch.iter().any(|(e, _)| e.id == id))
        .unwrap();
    assert!(
        first < last
            && !read_journal(&mut saved.setup)
                .journal
                .has_preservation_work()
    );
}
#[test]
fn multiple_sources_restore_cross_scope_c0_c1_and_queued_generations_with_key_free_redo() {
    for backup in [false, true] {
        for queued in [false, true] {
            for point in [None, Some(2)] {
                let (mut saved, file) = mixed(queued, backup);
                let selection = selection(&mut saved);
                let before = read_journal(&mut saved.setup).journal;
                let protected = capabilities(&saved.setup);
                let mut current = unlock_current(&saved.setup, &saved.current);
                if !backup && !queued && point.is_none() {
                    assert!(
                        restore::inspect_source_file(&mut saved.setup.store, &selection, &file)
                            .is_err()
                    );
                    for only_primary in [false, true] {
                        let source = if only_primary {
                            primary_source(&mut saved, &selection)
                        } else {
                            additional_source(&mut saved, &selection, &file)
                        };
                        assert!(
                            restore::prepare_foreign(
                                &mut saved.setup.store,
                                selection.clone(),
                                &mut current,
                                source
                            )
                            .is_err()
                        );
                        assert!(
                            before == read_journal(&mut saved.setup).journal
                                && protected == capabilities(&saved.setup)
                        );
                    }
                }
                let a = primary_source(&mut saved, &selection);
                let b = additional_source(&mut saved, &selection, &file);
                let reviewed = restore::prepare_multiple(
                    &mut saved.setup.store,
                    selection,
                    &mut current,
                    vec![a, b],
                )
                .unwrap();
                assert_eq!(
                    confirm(&mut saved.setup, reviewed, point).is_ok(),
                    point.is_none()
                );
                drop(current);
                std::fs::remove_file(file).unwrap();
                if point.is_some() {
                    saved.setup.store =
                        Store::load(saved.setup.temp.path(), saved.setup.backend.clone()).unwrap();
                    resume_restore(&mut saved.setup).unwrap();
                }
                assert_result(&mut saved, &before, &protected, queued);
            }
        }
    }
}
#[test]
fn every_selected_source_file_is_bound_until_consent_and_one_stale_file_refuses_all() {
    for replace_first in [false, true] {
        let (mut saved, file) = mixed(false, false);
        let first_file = external_source::file(&saved, false);
        let selection = selection(&mut saved);
        let before = read_journal(&mut saved.setup).journal;
        let protected = capabilities(&saved.setup);
        let mut current = unlock_current(&saved.setup, &saved.current);
        let a = restore::inspect_additional_source_file(
            &mut saved.setup.store,
            &selection,
            &first_file,
        )
        .unwrap()
        .authenticate(
            &mut saved.setup.store,
            &crypto::format_recovery(&[0x66; 16]),
            true,
        )
        .unwrap();
        let b = additional_source(&mut saved, &selection, &file);
        let reviewed =
            restore::prepare_multiple(&mut saved.setup.store, selection, &mut current, vec![a, b])
                .unwrap();
        let changed = if replace_first { first_file } else { file };
        let bytes = std::fs::read(&changed).unwrap();
        crate::model::atomic_write(&changed, &bytes).unwrap();
        assert!(matches!(
            confirm(&mut saved.setup, reviewed, None),
            Err(restore::Failure::Changed)
        ));
        assert!(
            before == read_journal(&mut saved.setup).journal
                && protected == capabilities(&saved.setup)
        );
        assert!(
            saved
                .setup
                .backend
                .memory
                .slot(Slot::HistoryRestore)
                .is_none()
        );
    }
}

#[cfg(feature = "desktop")]
#[path = "account_restoration_multiple_tests.rs"]
mod native;
