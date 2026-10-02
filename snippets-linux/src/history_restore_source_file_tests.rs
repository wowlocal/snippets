//! Explicit old headers for legacy history. Fictional vaults/files and memory
//! credentials; current primary state, offers and protected capabilities are real.
use super::*;
use std::os::unix::fs::symlink;

pub(super) fn legacy(saved: &mut Saved, schema: i64) -> restore::Selection {
    super::super::super::vault_headers::rewrite_legacy(&mut saved.setup, schema);
    let selection = history::inspect(&mut saved.setup.store).unwrap().switches[0]
        .selection
        .clone();
    assert!(
        restore::saved_vault_header(&mut saved.setup.store, &selection)
            .unwrap()
            .is_none()
    );
    selection
}
pub(super) fn file(saved: &Saved, backup: bool) -> std::path::PathBuf {
    let path = saved.setup.temp.path().join(if backup {
        "public prior vault.snippetsbackup"
    } else {
        "public prior vault.json"
    });
    let bytes = if backup {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/backup-v1.json")).unwrap();
        let bytes = serde_json::to_vec(&fixture["container"]).unwrap();
        let opened = crate::backup::open(&bytes, "Café public backup fixture").unwrap();
        assert!(opened.vault.as_ref().unwrap().same_identity(&document()));
        bytes
    } else {
        document().encode().unwrap()
    };
    crate::model::atomic_write(&path, &bytes).unwrap();
    path
}
fn source(
    saved: &mut Saved,
    selection: &restore::Selection,
    path: &std::path::Path,
) -> restore::Source {
    let file = restore::inspect_source_file(&mut saved.setup.store, selection, path).unwrap();
    if file.is_backup() {
        assert!(file.has_passphrase() && !file.has_recovery());
        file.authenticate(&mut saved.setup.store, "Café public backup fixture", false)
            .unwrap()
    } else {
        assert!(file.has_passphrase() && file.has_recovery());
        file.authenticate(
            &mut saved.setup.store,
            &crypto::format_recovery(&[0x66; 16]),
            true,
        )
        .unwrap()
    }
}
fn review(
    saved: &mut Saved,
    selection: restore::Selection,
    path: &std::path::Path,
) -> restore::Review {
    let source = source(saved, &selection, path);
    let mut current = unlock_current(&saved.setup, &saved.current);
    restore::prepare_foreign(&mut saved.setup.store, selection, &mut current, source).unwrap()
}
fn assert_result(saved: &mut Saved, before: &Journal, protected: &[Option<Zeroizing<Vec<u8>>>]) {
    let after = read_journal(&mut saved.setup).journal;
    assert!(before.preserves_transport_state(&after));
    assert!(before.outbound == after.outbound);
    assert!(capabilities(&saved.setup) == protected);
    let current = crate::vault::read_document(saved.setup.temp.path())
        .unwrap()
        .unwrap();
    assert!(current.same_identity(&saved.current));
    let mut vault = unlock_current(&saved.setup, &current);
    let selected = current
        .records
        .iter()
        .find(|record| {
            vault.body(record.metadata.id).unwrap().as_slice() == b"Public selected secure C1 body"
        })
        .unwrap();
    assert_ne!(selected.metadata.id, saved.selected.id);
    assert!(
        current
            .records
            .iter()
            .any(|record| vault.body(record.metadata.id).unwrap().as_slice()
                == b"Public current independently protected body")
    );
    let snapshots = after.conflict_snapshots();
    let original = snapshots
        .values()
        .find(|e| {
            e.secure
                && merge::provenance(e)
                    .is_some_and(|p| p.source_id == document().records[0].metadata.id)
                && e.fields.as_ref().unwrap().name == saved.original.fields.as_ref().unwrap().name
        })
        .unwrap();
    assert_ne!(original.id, saved.original.id);
    assert!(after.entry(original.id).unwrap().desired != *original);
    assert!(crate::primary::require_ready(saved.setup.temp.path()).is_ok());
}

#[test]
fn legacy_file_sources_restore_full_nested_graphs_and_resume_without_the_file_or_keys() {
    for backup in [false, true] {
        for queued in [false, true] {
            for point in [None, Some(1), Some(2), Some(3), Some(4), Some(7)] {
                let mut saved = saved(queued);
                let selection = legacy(&mut saved, if queued { 1 } else { 2 });
                let path = file(&saved, backup);
                let before = read_journal(&mut saved.setup).journal;
                let protected = capabilities(&saved.setup);
                let reviewed = review(&mut saved, selection, &path);
                let result = confirm(&mut saved.setup, reviewed, point);
                assert_eq!(result.is_ok(), point.is_none());
                std::fs::remove_file(path).unwrap();
                if point.is_some() {
                    saved.setup.store =
                        Store::load(saved.setup.temp.path(), saved.setup.backend.clone()).unwrap();
                    resume_restore(&mut saved.setup).unwrap();
                }
                assert_result(&mut saved, &before, &protected);
            }
        }
    }
}

#[test]
fn selected_file_changes_reject_authentication_preparation_and_confirmed_publication() {
    for phase in 0..4 {
        let mut saved = saved(false);
        let selection = legacy(&mut saved, 2);
        let path = file(&saved, false);
        let before = std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap();
        let checkpoint = std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap();
        let protected = capabilities(&saved.setup);
        let selected =
            restore::inspect_source_file(&mut saved.setup.store, &selection, &path).unwrap();
        if phase == 0 {
            let bytes = std::fs::read(&path).unwrap();
            crate::model::atomic_write(&path, &bytes).unwrap(); // same bytes, different inode
            assert!(
                selected
                    .authenticate(
                        &mut saved.setup.store,
                        &crypto::format_recovery(&[0x66; 16]),
                        true
                    )
                    .is_err()
            );
        } else {
            let source = selected
                .authenticate(
                    &mut saved.setup.store,
                    &crypto::format_recovery(&[0x66; 16]),
                    true,
                )
                .unwrap();
            let mut current = unlock_current(&saved.setup, &saved.current);
            if phase == 1 {
                std::fs::remove_file(&path).unwrap();
                assert!(
                    restore::prepare_foreign(
                        &mut saved.setup.store,
                        selection,
                        &mut current,
                        source
                    )
                    .is_err()
                );
            } else {
                let reviewed = restore::prepare_foreign(
                    &mut saved.setup.store,
                    selection,
                    &mut current,
                    source,
                )
                .unwrap();
                if phase == 2 {
                    crate::model::atomic_write(&path, b"Public changed file").unwrap();
                } else {
                    std::fs::remove_file(&path).unwrap();
                    symlink(saved.setup.temp.path().join("Vault/vault.json"), &path).unwrap();
                }
                assert!(confirm(&mut saved.setup, reviewed, None).is_err());
            }
        }
        assert!(std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap() == before);
        assert!(
            std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint
        );
        assert!(capabilities(&saved.setup) == protected);
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

#[test]
fn file_sources_refuse_unsafe_inputs_wrong_vaults_passwords_and_changed_history() {
    let mut saved = saved(false);
    let selection = legacy(&mut saved, 2);
    let path = file(&saved, false);
    let target = saved.setup.temp.path().join("public invalid source");
    for kind in 0..6 {
        match kind {
            0 => std::fs::write(&target, b"[]").unwrap(),
            1 => {
                let mut doc = document();
                doc.schema_version = 2;
                std::fs::write(&target, serde_json::to_vec(&doc).unwrap()).unwrap();
            }
            2 => {
                let handle = std::fs::File::create(&target).unwrap();
                handle
                    .set_len(crate::model::MAX_FILE_BYTES as u64 + 1)
                    .unwrap();
            }
            3 => symlink(&path, &target).unwrap(),
            4 => std::fs::create_dir(&target).unwrap(),
            _ => {
                let name = std::ffi::CString::new(target.as_os_str().as_encoded_bytes()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
            }
        }
        assert!(restore::inspect_source_file(&mut saved.setup.store, &selection, &target).is_err());
        if kind == 4 {
            std::fs::remove_dir(&target).unwrap();
        } else {
            std::fs::remove_file(&target).unwrap();
        }
    }
    let current = saved.setup.temp.path().join("Vault/vault.json");
    let wrong = restore::inspect_source_file(&mut saved.setup.store, &selection, &current).unwrap();
    let source = wrong
        .authenticate(&mut saved.setup.store, CURRENT_PASSPHRASE, false)
        .unwrap();
    let mut vault = unlock_current(&saved.setup, &saved.current);
    assert!(
        restore::prepare_foreign(
            &mut saved.setup.store,
            selection.clone(),
            &mut vault,
            source
        )
        .is_err()
    );
    let backup = file(&saved, true);
    let selected =
        restore::inspect_source_file(&mut saved.setup.store, &selection, &backup).unwrap();
    assert!(matches!(
        selected.authenticate(
            &mut saved.setup.store,
            "Public wrong backup password",
            false
        ),
        Err(restore::Failure::BackupAuthentication)
    ));
    let selected = restore::inspect_source_file(&mut saved.setup.store, &selection, &path).unwrap();
    saved
        .setup
        .store
        .transaction(|owner| {
            let before = owner.read(Slot::AccountReview)?.unwrap();
            let mut value = canonical::parse(&before).unwrap();
            let Value::Object(ref mut fields) = value else {
                unreachable!()
            };
            fields.insert(
                "generation".into(),
                Value::Int(fields["generation"].as_int().unwrap() + 1),
            );
            owner.replace(
                Slot::AccountReview,
                Some(&before),
                Some(&value.encode().unwrap()),
            )
        })
        .unwrap();
    assert!(
        selected
            .authenticate(
                &mut saved.setup.store,
                &crypto::format_recovery(&[0x66; 16]),
                true
            )
            .is_err()
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

#[test]
fn retained_header_scope_cannot_be_replaced_by_an_unrelated_external_vault() {
    let mut saved = saved(false);
    let selection = history::inspect(&mut saved.setup.store).unwrap().switches[0]
        .selection
        .clone();
    let current = saved.setup.temp.path().join("Vault/vault.json");
    assert!(restore::inspect_source_file(&mut saved.setup.store, &selection, &current).is_err());
}
