//! The production vault-preparation boundary on a serialized synthetic worker.
//! Real temporary WAL/files and protected memory slots; no host keyring or PAM.
use super::*;
use crate::{
    account_worker::{Command, Failure as WorkerFailure, Handle, Reply, restoration_task as task},
    desktop::{SessionState, SessionWitness},
    local_auth::Purpose,
};

fn lease() -> task::Preparation {
    task::Preparation::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap()
}
struct Observation {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Observation {
    fn start() -> (task::Preparation, Self) {
        let witness = SessionWitness::test(SessionState::Unlocked, 1);
        let preparation = task::Preparation::new(witness.clone()).unwrap();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let ending = stop.clone();
        let thread = std::thread::spawn(move || {
            while !ending.load(std::sync::atomic::Ordering::Acquire) {
                // Match a running desktop observer. This refreshes its observation
                // only; the preparation's original wall/uptime deadlines stay fixed.
                witness.test_observe(SessionState::Unlocked);
                std::thread::park_timeout(std::time::Duration::from_millis(100));
            }
        });
        (
            preparation,
            Self {
                stop,
                thread: Some(thread),
            },
        )
    }
}
impl Drop for Observation {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Release);
        if let Some(thread) = self.thread.take() {
            thread.thread().unpark();
            thread.join().unwrap();
        }
    }
}
fn credentials() -> task::Credentials {
    task::Credentials {
        current: task::Credential {
            value: Zeroizing::new(CURRENT_PASSPHRASE.into()),
            recovery: false,
        },
        previous: Some(task::Credential {
            value: crypto::format_recovery(&[0x66; 16]),
            recovery: true,
        }),
    }
}
fn token(reviewed: &task::Reviewed) -> (Uuid, crate::local_auth::Target) {
    let Reply::RestorationReview {
        token: Some(token),
        target,
        rekeyed: true,
        ..
    } = reviewed.reply().unwrap()
    else {
        panic!("Expected a ciphertext foreign-vault review")
    };
    assert_eq!(target.purpose(), Purpose::RestoreSavedChanges);
    (token, target)
}
fn assert_result(saved: &mut Saved, before: &Journal, protected: &[Option<Zeroizing<Vec<u8>>>]) {
    let after = read_journal(&mut saved.setup).journal;
    assert!(before.preserves_transport_state(&after));
    assert!(after.outbound == before.outbound);
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
    assert!(crate::primary::require_ready(saved.setup.temp.path()).is_ok());
}

fn marked_file(saved: &Saved, backup: bool) -> (std::path::PathBuf, [Uuid; 2]) {
    let path = saved.setup.temp.path().join(if backup {
        "public selected backup with unrelated records.snippetsbackup"
    } else {
        "public selected vault with unrelated records.json"
    });
    let mut source = document();
    let key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let mut secure = source.records[0].clone();
    secure.metadata.id = Uuid::from_u128(7001);
    secure.metadata.name = "Public source-only secure record".into();
    secure.metadata.keyword = "public-source-only-secure".into();
    let body = b"Public unrelated source body which must never be imported";
    secure.sealed = crypto::seal_record(
        body,
        &key,
        &source.salt().unwrap(),
        &source.kid,
        secure.metadata.id,
        false,
    )
    .unwrap();
    secure.content_hash = crypto::content_hash(body, &key, &source.salt().unwrap());
    let mut ordinary = crate::model::Snippet::new(
        "Public source-only ordinary record",
        "Public unrelated ordinary backup body",
    );
    ordinary.id = Uuid::from_u128(7002);
    ordinary.keyword = "public-source-only-ordinary".into();
    let ids = [secure.metadata.id, ordinary.id];
    source.records.push(secure);
    let bytes = if backup {
        crate::backup::seal(
            &[ordinary],
            Some((&source, &key)),
            "Café public backup fixture",
        )
        .unwrap()
    } else {
        source.encode().unwrap()
    };
    crate::model::atomic_write(&path, &bytes).unwrap();
    (path, ids)
}
fn assert_not_imported(saved: &Saved, unimported: Option<[Uuid; 2]>) {
    if let Some(ids) = unimported {
        let vault = crate::vault::read_document(saved.setup.temp.path())
            .unwrap()
            .unwrap();
        assert!(
            vault
                .records
                .iter()
                .all(|record| !ids.contains(&record.metadata.id))
        );
        let ordinary = Library::open(saved.setup.temp.path().into()).unwrap();
        assert!(
            ordinary
                .snippets
                .iter()
                .all(|record| !ids.contains(&record.id))
        );
    }
}

#[test]
fn native_worker_prepares_two_vaults_and_finishes_a_lost_reply_with_no_live_vault_owner() {
    for external in [None, Some(false), Some(true)] {
        for queued in [false, true] {
            for interrupted in [false, true] {
                let mut saved = saved(queued);
                let selection = if external.is_some() {
                    external_source::legacy(&mut saved, if queued { 1 } else { 2 })
                } else {
                    history::inspect(&mut saved.setup.store).unwrap().switches[0]
                        .selection
                        .clone()
                };
                let source_file = external.map(|backup| marked_file(&saved, backup));
                let unimported = source_file.as_ref().map(|(_, ids)| *ids);
                let before = read_journal(&mut saved.setup).journal;
                let protected = capabilities(&saved.setup);
                let path = saved.setup.temp.path().to_path_buf();
                let original_vault = std::fs::read(path.join("Vault/vault.json")).unwrap();
                let original_checkpoint = std::fs::read(path.join("Sync/journal.bin")).unwrap();
                let mut retained = task::Retained::default();
                let worker = Handle::controlled(move |command| {
                    retained.keep_for(&command);
                    let result = (|| match command {
                        Command::PrepareRestoration {
                            selection,
                            credentials,
                            preparation,
                            source_file,
                        } => retained.prepare(
                            &mut saved.setup.store,
                            selection,
                            credentials,
                            preparation,
                            source_file,
                        ),
                        Command::InspectRestorationFile {
                            selection,
                            path,
                            preparation,
                        } => {
                            retained.inspect(&mut saved.setup.store, &selection, &path, preparation)
                        }
                        Command::CommitRestoration { token, permit } => {
                            let review = retained.consume(token)?;
                            assert!(retained.consume(token).is_err());
                            let result = restore::apply_with_fault(
                                &mut saved.setup.store,
                                review,
                                permit,
                                interrupted.then_some(2),
                            );
                            if result.is_ok() {
                                assert_result(&mut saved, &before, &protected);
                                assert_not_imported(&saved, unimported);
                            }
                            Ok(Reply::Restored {
                                failure: result.err().map(WorkerFailure::from),
                                cancelled: false,
                            })
                        }
                        Command::InspectHistory => history::inspect(&mut saved.setup.store)
                            .map(Reply::History)
                            .map_err(WorkerFailure::from),
                        Command::PrepareRestorationResume(cancel) => {
                            assert!(retained.consume(Uuid::from_u128(12)).is_err());
                            let review =
                                restore::prepare_resume_review(&mut saved.setup.store, cancel)?;
                            Ok(Reply::RestorationReview {
                                token: None,
                                summary: review.summary,
                                target: review.target,
                                saved: review.saved,
                                current: review.current,
                                rekeyed: false,
                            })
                        }
                        Command::FinishRestoration {
                            cancel: false,
                            permit,
                        } => {
                            saved.setup.store =
                                Store::load(saved.setup.temp.path(), saved.setup.backend.clone())
                                    .unwrap();
                            restore::resume(&mut saved.setup.store, permit)?;
                            assert_result(&mut saved, &before, &protected);
                            assert_not_imported(&saved, unimported);
                            Ok(Reply::Restored {
                                failure: None,
                                cancelled: false,
                            })
                        }
                        _ => Err(WorkerFailure::InvalidState),
                    })();
                    (result, false)
                });
                let (mut preparation, mut _observation) = Observation::start();
                let Reply::RestorationAuthentication(methods) = worker
                    .request(Command::PrepareRestoration {
                        selection: selection.clone(),
                        credentials: None,
                        source_file: None,
                        preparation: preparation.clone(),
                    })
                    .unwrap()
                    .recv_timeout(std::time::Duration::from_secs(10))
                    .unwrap()
                    .unwrap()
                else {
                    panic!("Expected body-free vault authentication methods")
                };
                assert!(methods.current.passphrase && !methods.current.recovery);
                let source_token = if let Some((path, _)) = &source_file {
                    assert!(methods.previous.is_none());
                    // The native chooser discards the previous password preparation.
                    preparation.cancel();
                    let (fresh, observed) = Observation::start();
                    preparation = fresh;
                    _observation = observed;
                    let Reply::RestorationFile { token, methods } = worker
                        .request(Command::InspectRestorationFile {
                            selection: selection.clone(),
                            path: path.clone(),
                            preparation: preparation.clone(),
                        })
                        .unwrap()
                        .recv_timeout(std::time::Duration::from_secs(10))
                        .unwrap()
                        .unwrap()
                    else {
                        panic!("Expected selected-file methods")
                    };
                    assert!(methods.previous_suggested);
                    assert_eq!(methods.previous_backup, external == Some(true));
                    assert_eq!(
                        methods.previous,
                        Some(task::Methods {
                            passphrase: true,
                            recovery: external == Some(false)
                        })
                    );
                    Some(token)
                } else {
                    assert!(
                        methods.previous.unwrap().passphrase && methods.previous.unwrap().recovery
                    );
                    assert!(methods.previous_suggested);
                    None
                };
                let mut access = credentials();
                if external == Some(true) {
                    access.previous = Some(task::Credential {
                        value: Zeroizing::new("Café public backup fixture".into()),
                        recovery: false,
                    });
                }
                let Reply::RestorationReview {
                    token: Some(token),
                    target,
                    rekeyed: true,
                    summary,
                    ..
                } = worker
                    .request(Command::PrepareRestoration {
                        selection,
                        credentials: Some(access),
                        source_file: source_token,
                        preparation,
                    })
                    .unwrap()
                    .recv_timeout(std::time::Duration::from_secs(10))
                    .unwrap()
                    .unwrap()
                else {
                    panic!("Expected reviewed foreign-vault restoration")
                };
                assert!(summary.secure_records >= 2);
                assert_eq!(target.purpose(), Purpose::RestoreSavedChanges);
                assert!(std::fs::read(path.join("Vault/vault.json")).unwrap() == original_vault);
                assert!(
                    std::fs::read(path.join("Sync/journal.bin")).unwrap() == original_checkpoint
                );
                let (_gate, permit) = authorize(target);
                drop(
                    worker
                        .request(Command::CommitRestoration { token, permit })
                        .unwrap(),
                );
                let Reply::History(history) = worker
                    .request(Command::InspectHistory)
                    .unwrap()
                    .recv_timeout(std::time::Duration::from_secs(10))
                    .unwrap()
                    .unwrap()
                else {
                    panic!("Expected retained receipt")
                };
                if let Some((path, _)) = source_file {
                    std::fs::remove_file(path).unwrap();
                }
                assert_eq!(history.restorations.len(), 1);
                assert_eq!(history.restorations[0].needs_completion, interrupted);
                if interrupted {
                    let Reply::RestorationReview {
                        token: None,
                        target,
                        ..
                    } = worker
                        .request(Command::PrepareRestorationResume(false))
                        .unwrap()
                        .recv_timeout(std::time::Duration::from_secs(10))
                        .unwrap()
                        .unwrap()
                    else {
                        panic!("Expected key-free completion")
                    };
                    assert_eq!(target.purpose(), Purpose::ResumeSavedChanges);
                    let (_gate, permit) = authorize(target);
                    assert!(matches!(
                        worker
                            .request(Command::FinishRestoration {
                                cancel: false,
                                permit
                            })
                            .unwrap()
                            .recv_timeout(std::time::Duration::from_secs(10))
                            .unwrap()
                            .unwrap(),
                        Reply::Restored { failure: None, .. }
                    ));
                }
                assert!(worker.can_quit() && !worker.retention_required());
            }
        }
    }
}

#[test]
fn native_vault_preparation_rejects_wrong_credentials_stale_selection_and_revoked_reviews() {
    let mut saved = saved(false);
    let selection = history::inspect(&mut saved.setup.store).unwrap().switches[0]
        .selection
        .clone();
    let vault = std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap();
    let checkpoint = std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap();
    let protected = capabilities(&saved.setup);
    for kind in 0..7 {
        let mut credentials = credentials();
        let mut selected = selection.clone();
        let preparation = lease();
        match kind {
            0 => credentials.current.value = Zeroizing::new("Public wrong current password".into()),
            1 => {
                credentials.previous.as_mut().unwrap().value =
                    Zeroizing::new("Public wrong source recovery".into())
            }
            2 => credentials.previous = None,
            3 => credentials.current.value = "x".repeat(4097).into(),
            4 => selected.transition[0] ^= 1,
            5 => preparation.cancel(),
            _ => credentials.previous.as_mut().unwrap().value = "x".repeat(4097).into(),
        }
        let result = task::prepare(
            &mut saved.setup.store,
            selected,
            Some(credentials),
            preparation,
        );
        assert!(result.is_err(), "Refusal case {kind}");
        if kind == 1 {
            assert!(matches!(
                result,
                Err(WorkerFailure::PreviousVaultAuthentication)
            ));
        }
    }
    for wrong_token in [false, true] {
        let preparation = lease();
        let task::Outcome::Reviewed(reviewed) = task::prepare(
            &mut saved.setup.store,
            selection.clone(),
            Some(credentials()),
            preparation.clone(),
        )
        .unwrap() else {
            panic!("Expected encrypted review")
        };
        let (token, _) = token(&reviewed);
        if wrong_token {
            assert!(reviewed.consume(Uuid::from_u128(12)).is_err());
        } else {
            preparation.cancel();
            assert!(reviewed.consume(token).is_err());
        }
    }
    assert!(std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap() == vault);
    assert!(std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
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

#[test]
fn selected_source_file_tokens_bind_history_files_and_preparation_before_a_review() {
    for backup in [false, true] {
        let mut saved = saved(false);
        let selection = external_source::legacy(&mut saved, 2);
        let path = external_source::file(&saved, backup);
        let checkpoint = std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap();
        let protected = capabilities(&saved.setup);
        let vault = std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap();
        for refusal in 0..4 {
            let (preparation, _observation) = Observation::start();
            let (selected, methods) = task::SelectedFile::inspect(
                &mut saved.setup.store,
                &selection,
                &path,
                preparation.clone(),
            )
            .unwrap();
            assert!(methods.previous_suggested);
            assert_eq!(methods.previous_backup, backup);
            assert_eq!(
                methods.previous,
                Some(task::Methods {
                    passphrase: true,
                    recovery: !backup,
                })
            );
            let mut token = selected.token();
            let mut selection = selection.clone();
            match refusal {
                0 => token = Uuid::from_u128(12),
                1 => selection.transition[0] ^= 1,
                2 => preparation.cancel(),
                _ => {
                    let bytes = std::fs::read(&path).unwrap();
                    crate::model::atomic_write(&path, &bytes).unwrap();
                }
            }
            assert!(
                selected
                    .consume(&mut saved.setup.store, token, &selection)
                    .is_err()
            );
        }
        let (preparation, _observation) = Observation::start();
        let (selected, _) = task::SelectedFile::inspect(
            &mut saved.setup.store,
            &selection,
            &path,
            preparation.clone(),
        )
        .unwrap();
        let token = selected.token();
        let source = selected
            .consume(&mut saved.setup.store, token, &selection)
            .unwrap();
        let mut access = credentials();
        if backup {
            access.previous = Some(task::Credential {
                value: Zeroizing::new("Café public backup fixture".into()),
                recovery: false,
            });
        }
        let task::Outcome::Reviewed(reviewed) = task::prepare_with_file(
            &mut saved.setup.store,
            selection,
            Some(access),
            preparation,
            Some(source),
        )
        .unwrap() else {
            panic!("Expected encrypted review from the explicitly selected source file")
        };
        let (token, _) = self::token(&reviewed);
        drop(reviewed.consume(token).unwrap());
        assert!(std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap() == vault);
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
fn selected_file_inspection_revoked_during_method_probe_cannot_return_a_ticket() {
    struct Revoke {
        inner: super::super::super::Faults,
        preparation: task::Preparation,
        reads: usize,
    }
    impl Backend for Revoke {
        fn read(
            &mut self,
            ns: &[u8; 16],
            slot: Slot,
        ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
            if slot == Slot::AccountReview {
                self.reads += 1;
                // Two exact-history reads inspect the file. The third obtains
                // the native method hints after the earlier cancellation check.
                if self.reads == 3 {
                    self.preparation.cancel();
                }
            }
            self.inner.read(ns, slot)
        }
        fn write(&mut self, ns: &[u8; 16], slot: Slot, value: &[u8]) -> secret_store::Result<()> {
            self.inner.write(ns, slot, value)
        }
        fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
            self.inner.delete(ns, slot)
        }
    }
    let mut saved = saved(false);
    let selection = external_source::legacy(&mut saved, 2);
    let path = external_source::file(&saved, false);
    let checkpoint = std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap();
    let protected = capabilities(&saved.setup);
    let (preparation, _observation) = Observation::start();
    let mut store = Store::load(
        saved.setup.temp.path(),
        Revoke {
            inner: saved.setup.backend.clone(),
            preparation: preparation.clone(),
            reads: 0,
        },
    )
    .unwrap();
    let mut retained = task::Retained::default();
    assert!(matches!(
        retained.inspect(&mut store, &selection, &path, preparation),
        Err(WorkerFailure::Authentication(
            crate::local_auth::Failure::Cancelled
        ))
    ));
    assert!(std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
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

#[test]
fn retained_file_tickets_are_single_use_after_failed_attempts_and_unrelated_commands() {
    let mut saved = saved(false);
    let selection = external_source::legacy(&mut saved, 2);
    let path = external_source::file(&saved, false);
    let vault = std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap();
    let checkpoint = std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap();
    let protected = capabilities(&saved.setup);
    let mut retained = task::Retained::default();
    for refusal in 0..7 {
        let (preparation, _observation) = Observation::start();
        let Reply::RestorationFile { token, .. } = retained
            .inspect(
                &mut saved.setup.store,
                &selection,
                &path,
                preparation.clone(),
            )
            .unwrap()
        else {
            panic!("Expected file token")
        };
        let original_token = token;
        let mut request_token = token;
        let mut selected = selection.clone();
        let mut access = credentials();
        match refusal {
            0 => request_token = Uuid::from_u128(12),
            1 => selected.transition[0] ^= 1,
            2 => preparation.cancel(),
            3 => {
                let bytes = std::fs::read(&path).unwrap();
                crate::model::atomic_write(&path, &bytes).unwrap();
            }
            4 => retained.keep_for(&Command::InspectHistory),
            5 => {
                let Reply::RestorationFile {
                    token: replacement, ..
                } = retained
                    .inspect(
                        &mut saved.setup.store,
                        &selection,
                        &path,
                        preparation.clone(),
                    )
                    .unwrap()
                else {
                    panic!("Expected replacement file token")
                };
                assert_ne!(replacement, original_token);
            }
            _ => {
                access.current.value = Zeroizing::new("Public wrong current vault password".into())
            }
        }
        assert!(
            retained
                .prepare(
                    &mut saved.setup.store,
                    selected,
                    Some(access),
                    preparation,
                    Some(request_token)
                )
                .is_err(),
            "Refusal {refusal}"
        );
        let (fresh, _observation) = Observation::start();
        assert!(matches!(
            retained.prepare(
                &mut saved.setup.store,
                selection.clone(),
                Some(credentials()),
                fresh,
                Some(original_token)
            ),
            Err(WorkerFailure::InvalidState)
        ));
    }
    assert!(std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap() == vault);
    assert!(std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
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

#[test]
fn native_source_authentication_revoked_during_a_protected_read_cannot_publish_a_review() {
    struct Revoke {
        inner: super::super::super::Faults,
        preparation: task::Preparation,
        fired: bool,
    }
    impl Backend for Revoke {
        fn read(
            &mut self,
            ns: &[u8; 16],
            slot: Slot,
        ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
            if slot == Slot::AccountReview && !self.fired {
                self.fired = true;
                self.preparation.cancel();
            }
            self.inner.read(ns, slot)
        }
        fn write(&mut self, ns: &[u8; 16], slot: Slot, value: &[u8]) -> secret_store::Result<()> {
            self.inner.write(ns, slot, value)
        }
        fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
            self.inner.delete(ns, slot)
        }
    }
    let mut saved = saved(false);
    let selection = history::inspect(&mut saved.setup.store).unwrap().switches[0]
        .selection
        .clone();
    let checkpoint = std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap();
    let preparation = lease();
    let mut store = Store::load(
        saved.setup.temp.path(),
        Revoke {
            inner: saved.setup.backend.clone(),
            preparation: preparation.clone(),
            fired: false,
        },
    )
    .unwrap();
    assert!(matches!(
        task::prepare(&mut store, selection, Some(credentials()), preparation),
        Err(WorkerFailure::Authentication(
            crate::local_auth::Failure::Cancelled
        ))
    ));
    assert!(std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
    assert!(
        saved
            .setup
            .backend
            .memory
            .slot(Slot::HistoryRestore)
            .is_none()
    );
}
