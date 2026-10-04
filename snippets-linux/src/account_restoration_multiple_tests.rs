//! Production multi-source retention with temporary files and memory authorities.
use super::super::desktop_workflow::Observation;
use super::*;
use crate::account_worker::{Command, Reply, restoration_task as task};

fn credentials(retained: bool) -> task::MultipleCredentials {
    let a = || task::Credential {
        value: crypto::format_recovery(&[0x66; 16]),
        recovery: true,
    };
    task::MultipleCredentials {
        current: task::Credential {
            value: Zeroizing::new(CURRENT_PASSPHRASE.into()),
            recovery: false,
        },
        retained: retained.then(a),
        files: if retained { vec![] } else { vec![a()] }
            .into_iter()
            .chain([task::Credential {
                value: Zeroizing::new(EXTRA_PASSWORD.into()),
                recovery: false,
            }])
            .collect(),
    }
}
#[test]
fn native_multiple_vault_tickets_restore_retained_or_file_sources_and_finish_without_passwords() {
    for retained_header in [false, true] {
        for backup in [false, true] {
            for queued in [false, true] {
                for interrupted in [false, true] {
                    let (mut saved, file) = mixed(queued, backup);
                    let selection = selection(&mut saved);
                    let before = read_journal(&mut saved.setup).journal;
                    let protected = capabilities(&saved.setup);
                    let mut paths = if retained_header {
                        vec![]
                    } else {
                        vec![super::super::external_source::file(&saved, false)]
                    };
                    paths.push(file);
                    let (preparation, _observer) = Observation::start();
                    let mut retained = task::Retained::default();
                    let Reply::RestorationFiles { token, methods } = retained
                        .inspect_multiple(
                            &mut saved.setup.store,
                            &selection,
                            &paths,
                            preparation.clone(),
                        )
                        .unwrap()
                    else {
                        unreachable!()
                    };
                    assert_eq!(methods.files.len(), paths.len());
                    assert!(methods.files.last().unwrap().backup == backup);
                    assert!(!backup || !methods.files.last().unwrap().methods.recovery);
                    retained.keep_for(&Command::PrepareMultipleRestoration {
                        selection: selection.clone(),
                        credentials: credentials(retained_header),
                        preparation: preparation.clone(),
                        source_files: token,
                    });
                    let Reply::RestorationReview {
                        token: Some(review),
                        target,
                        rekeyed: true,
                        ..
                    } = retained
                        .prepare_multiple(
                            &mut saved.setup.store,
                            selection,
                            credentials(retained_header),
                            preparation,
                            token,
                        )
                        .unwrap()
                    else {
                        unreachable!()
                    };
                    let reviewed = retained.consume(review).unwrap();
                    assert!(retained.consume(review).is_err());
                    let (_gate, permit) = authorize(target);
                    assert_eq!(
                        restore::apply_with_fault(
                            &mut saved.setup.store,
                            reviewed,
                            permit,
                            interrupted.then_some(2)
                        )
                        .is_ok(),
                        !interrupted
                    );
                    for path in paths {
                        std::fs::remove_file(path).unwrap();
                    }
                    if interrupted {
                        saved.setup.store =
                            Store::load(saved.setup.temp.path(), saved.setup.backend.clone())
                                .unwrap();
                        resume_restore(&mut saved.setup).unwrap();
                    }
                    assert_result(&mut saved, &before, &protected, queued);
                }
            }
        }
    }
}
#[test]
fn failed_multi_source_preparation_consumes_the_entire_ticket_and_publishes_no_subset() {
    for case in 0..8 {
        let (mut saved, file) = mixed(false, false);
        let selection = selection(&mut saved);
        let before = read_journal(&mut saved.setup).journal;
        let protected = capabilities(&saved.setup);
        let original = std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap();
        let (preparation, _observer) = Observation::start();
        let mut retained = task::Retained::default();
        let paths = if case == 7 {
            vec![file.clone(), file.clone()]
        } else {
            vec![file.clone()]
        };
        let Reply::RestorationFiles { token, .. } = retained
            .inspect_multiple(
                &mut saved.setup.store,
                &selection,
                &paths,
                preparation.clone(),
            )
            .unwrap()
        else {
            unreachable!()
        };
        let mut values = credentials(true);
        let mut sent = token;
        match case {
            0 => sent = Uuid::from_u128(5),
            1 => values.files.clear(),
            2 => preparation.cancel(),
            3 => {
                let bytes = std::fs::read(&file).unwrap();
                crate::model::atomic_write(&file, &bytes).unwrap();
            }
            4 => {
                values.files[0].value = Zeroizing::new("Public wrong additional credential".into())
            }
            5 => values.retained = None,
            6 => retained.keep_for(&Command::InspectHistory),
            7 => values.files.push(task::Credential {
                value: Zeroizing::new(EXTRA_PASSWORD.into()),
                recovery: false,
            }),
            _ => unreachable!(),
        }
        assert!(
            retained
                .prepare_multiple(
                    &mut saved.setup.store,
                    selection.clone(),
                    values,
                    preparation.clone(),
                    sent
                )
                .is_err()
        );
        assert!(
            retained
                .prepare_multiple(
                    &mut saved.setup.store,
                    selection,
                    credentials(true),
                    preparation,
                    token
                )
                .is_err()
        );
        assert!(retained.consume(Uuid::from_u128(5)).is_err());
        assert!(
            before == read_journal(&mut saved.setup).journal
                && protected == capabilities(&saved.setup)
        );
        assert!(
            original == std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap()
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

#[test]
fn revocation_while_authenticating_a_later_source_drops_every_key_and_review() {
    struct Revoke {
        inner: super::super::super::super::Faults,
        preparation: task::Preparation,
        reads: usize,
    }
    impl Backend for Revoke {
        fn read(
            &mut self,
            namespace: &[u8; 16],
            slot: Slot,
        ) -> crate::secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
            if slot == Slot::AccountReview {
                self.reads += 1;
                // The retained source has completed both history checks. Revoke
                // as the next file starts its independently authenticated owner.
                if self.reads == 3 {
                    self.preparation.cancel();
                }
            }
            self.inner.read(namespace, slot)
        }
        fn write(
            &mut self,
            namespace: &[u8; 16],
            slot: Slot,
            value: &[u8],
        ) -> crate::secret_store::Result<()> {
            self.inner.write(namespace, slot, value)
        }
        fn delete(&mut self, namespace: &[u8; 16], slot: Slot) -> crate::secret_store::Result<()> {
            self.inner.delete(namespace, slot)
        }
    }
    let (mut saved, file) = mixed(false, false);
    let selection = selection(&mut saved);
    let before = read_journal(&mut saved.setup).journal;
    let protected = capabilities(&saved.setup);
    let (preparation, _observer) = Observation::start();
    let mut retained = task::Retained::default();
    let Reply::RestorationFiles { token, .. } = retained
        .inspect_multiple(
            &mut saved.setup.store,
            &selection,
            &[file],
            preparation.clone(),
        )
        .unwrap()
    else {
        unreachable!()
    };
    let mut store = Store::load(
        saved.setup.temp.path(),
        Revoke {
            inner: saved.setup.backend.clone(),
            preparation: preparation.clone(),
            reads: 0,
        },
    )
    .unwrap();
    assert!(matches!(
        retained.prepare_multiple(&mut store, selection, credentials(true), preparation, token),
        Err(crate::account_worker::Failure::Authentication(
            crate::local_auth::Failure::Cancelled
        ))
    ));
    assert!(retained.consume(Uuid::from_u128(5)).is_err());
    assert!(
        before == read_journal(&mut saved.setup).journal && protected == capabilities(&saved.setup)
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
