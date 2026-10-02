//! Fault checkpoints and CLI access use temporary directories and public data.
use super::*;
use crate::{
    clock::Hlc,
    cloud::Binding,
    vault::{self, Vault},
};
use std::os::unix::fs::symlink;
fn scope() -> Scope {
    Scope {
        membership: Binding::from_checkpoint([0x33; 32]),
        dataset: Binding::from_checkpoint([0x44; 32]),
    }
}
fn key() -> RootKey {
    RootKey::from_bytes(&[0x99; 32]).unwrap()
}
const SALT: [u8; 32] = [0xaa; 32];
fn snippet(id: u128, body: &str) -> Snippet {
    let mut s = Snippet::new("Public primary fixture", body);
    s.id = Uuid::from_u128(id);
    s.created_at = 0.0;
    s.updated_at = 1.0;
    s
}
fn envelope(s: &Snippet, wall: u64) -> Envelope {
    Envelope::plain(s, Hlc::foreign(wall), "22222222".into()).unwrap()
}
fn vault_fixture() -> Document {
    let f: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    Document::decode(&serde_json::to_vec(&f["document"]).unwrap()).unwrap()
}
fn install_vault(root: &Path, document: &Document) {
    fs::create_dir(root.join("Vault")).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
}
fn actual(library: &Library, journal: &Journal) -> BTreeMap<Uuid, Envelope> {
    let snippets = library.read().unwrap().0;
    let vault = vault::read_document(&library.root).unwrap();
    projection::current(
        &snippets,
        vault.as_ref(),
        "11111111",
        journal.projected(),
        &journal.projection_knowledge(),
    )
    .unwrap()
}
fn outcome(envelope: Envelope) -> Outcome {
    Outcome {
        survivor: Some(envelope),
        conflict_copies: vec![],
    }
}

#[test]
fn restored_history_authenticates_every_original_before_an_ordinary_final_edit_can_apply() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let document = vault_fixture();
    install_vault(temp.path(), &document);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = Keyring::new(&root, &document).unwrap();
    let journal = Journal::new(scope());
    let (merged, mut expected, copy_id) = secure_to_plain_conflict(&library, &journal, &document);
    let source = merged.survivor.unwrap();
    let c0 = Evidence::prepare(std::slice::from_ref(&source), &keys, &BTreeMap::new())
        .unwrap()
        .copies()[&copy_id]
        .clone();
    expected.insert(copy_id, None);
    let latest = envelope(&snippet(99, "Public final ordinary edit"), 100);
    expected.insert(latest.id, None);
    let history = crate::journal::RestorationGeneration {
        targets: BTreeMap::from([(source.id, source.clone()), (c0.id, c0.clone())]),
        sources: vec![(source, vec![c0])],
    };
    let plain_before = model::read_regular(&library.path()).unwrap();
    let vault_before = fs::read(temp.path().join("Vault/vault.json")).unwrap();
    for damage in 0..3 {
        let mut bad = history.clone();
        let original = &mut bad.sources[0].1[0];
        match damage {
            0 => original.fields.as_mut().unwrap().content.push(b'x'),
            1 => {
                original.extensions.insert(
                    "vaultContentHash".into(),
                    crate::canonical::Value::text("0".repeat(64)),
                );
            }
            _ => {
                original.extensions.insert(
                    "vaultKID".into(),
                    crate::canonical::Value::text("Public foreign vault"),
                );
            }
        }
        assert!(
            prepare_restoration(
                &library,
                &journal,
                "11111111",
                &[outcome(latest.clone())],
                &expected,
                Some(&keys),
                &[bad]
            )
            .is_err()
        );
        assert!(model::read_regular(&library.path()).unwrap() == plain_before);
        assert!(fs::read(temp.path().join("Vault/vault.json")).unwrap() == vault_before);
        assert!(!temp.path().join("Sync").exists());
    }
    assert!(matches!(
        prepare_restoration(
            &library,
            &journal,
            "11111111",
            &[outcome(latest.clone())],
            &expected,
            None,
            std::slice::from_ref(&history)
        ),
        Err(Failure::VaultLocked)
    ));
    let prepared = prepare_restoration(
        &library,
        &journal,
        "11111111",
        &[outcome(latest)],
        &expected,
        Some(&keys),
        &[history],
    )
    .unwrap();
    assert_eq!(prepared.history.len(), 1);
}

#[test]
fn recoverable_startup_never_reads_or_edits_mixed_primary_files() {
    let temp = tempfile::tempdir().unwrap();
    let mut library = Library::open(temp.path().into()).unwrap();
    library
        .save(snippet(1, "Public cached entry"), None)
        .unwrap();
    write_marker(&library, &[0x55; 16]).unwrap();
    model::atomic_write(&library.path(), b"public malformed mixed primary").unwrap();
    fs::create_dir(temp.path().join("Vault")).unwrap();
    let vault_path = temp.path().join("Vault/vault.json");
    model::atomic_write(&vault_path, b"public malformed mixed vault").unwrap();
    let marker_before = fs::read(temp.path().join("Sync").join(MARKER)).unwrap();
    assert!(Library::open(temp.path().into()).is_err());
    let (mut unread, readiness) = Library::open_recoverable(temp.path().into()).unwrap();
    assert_eq!(readiness, Readiness::RecoveryRequired);
    assert!(unread.snippets.is_empty());
    assert!(unread.read().is_err());
    assert!(unread.catalogue().is_err());
    assert!(unread.secure_metadata().is_err());
    assert!(unread.reload_catalogue().is_err());
    assert!(
        unread
            .save(snippet(2, "Public attempted edit"), None)
            .is_err()
    );
    assert!(unread.import(b"[]").is_err());
    unread.undo(false).unwrap(); // An empty undo stack has no operation to apply.
    assert!(library.undo(false).is_err());
    assert!(Vault::open(&unread).is_err());
    assert!(fs::read(unread.path()).unwrap() == b"public malformed mixed primary");
    assert!(fs::read(vault_path).unwrap() == b"public malformed mixed vault");
    assert!(fs::read(temp.path().join("Sync").join(MARKER)).unwrap() == marker_before);
    assert!(!temp.path().join("Sync/journal.bin").exists());
}

#[test]
fn recoverable_startup_rejects_unsafe_roots_and_fences_without_touching_targets() {
    for kind in 0..10 {
        let temp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let sentinel = outside.path().join("sentinel");
        fs::write(&sentinel, b"public startup sentinel").unwrap();
        let root = temp.path().join("library");
        match kind {
            0 => symlink(outside.path(), &root).unwrap(),
            1 => fs::write(&root, b"public invalid root").unwrap(),
            _ => {
                fs::create_dir(&root).unwrap();
                let sync = root.join("Sync");
                match kind {
                    2 => symlink(outside.path(), &sync).unwrap(),
                    3 => fs::write(&sync, b"public invalid sync directory").unwrap(),
                    9 => symlink(&sentinel, root.join("library.lock")).unwrap(),
                    _ => {
                        fs::create_dir(&sync).unwrap();
                        let marker = sync.join(MARKER);
                        match kind {
                            4 => symlink(&sentinel, &marker).unwrap(),
                            5 => fs::create_dir(&marker).unwrap(),
                            6 => fs::write(&marker, b"invalid").unwrap(),
                            7 => fs::write(&marker, [0u8; 21]).unwrap(),
                            _ => {
                                use std::os::unix::ffi::OsStrExt;
                                let path =
                                    std::ffi::CString::new(marker.as_os_str().as_bytes()).unwrap();
                                assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
                            }
                        }
                    }
                }
            }
        }
        assert!(Library::open_recoverable(root).is_err());
        assert!(fs::read(&sentinel).unwrap() == b"public startup sentinel");
        assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 1);
    }
}

#[test]
fn recovered_catalogue_validates_both_files_before_replacing_cached_entries() {
    let temp = tempfile::tempdir().unwrap();
    let (mut library, readiness) = Library::open_recoverable(temp.path().into()).unwrap();
    assert_eq!(readiness, Readiness::Ready);
    assert!(!library.path().exists());
    assert!(!temp.path().join("Sync").exists());
    assert!(!temp.path().join("Vault").exists());
    library
        .save(snippet(1, "Public old cached body"), None)
        .unwrap();
    let before = library.snippets.clone();
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[snippet(2, "Public new body")], false).unwrap(),
    )
    .unwrap();
    fs::create_dir(temp.path().join("Vault")).unwrap();
    model::atomic_write(
        &temp.path().join("Vault/vault.json"),
        b"public invalid vault",
    )
    .unwrap();
    assert!(library.reload_catalogue().is_err());
    assert!(library.snippets == before);
    assert!(Library::open_recoverable(temp.path().into()).is_err());
    model::atomic_write(
        &temp.path().join("Vault/vault.json"),
        &vault_fixture().encode().unwrap(),
    )
    .unwrap();
    assert!(library.reload_catalogue().unwrap());
    assert!(library.snippets == vec![snippet(2, "Public new body")]);
    assert!(!library.reload_catalogue().unwrap());
}

#[test]
fn concurrent_public_readers_wait_for_both_primary_replacements() {
    use std::{sync::mpsc, thread, time::Duration};
    let temp = tempfile::tempdir().unwrap();
    let mut library = Library::open(temp.path().into()).unwrap();
    library.save(snippet(1, "Before apply"), None).unwrap();
    let mut document = vault_fixture();
    install_vault(temp.path(), &document);
    let guard = library.lock().unwrap();
    write_marker(&library, &[0x55; 16]).unwrap();
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[snippet(2, "After apply")], false).unwrap(),
    )
    .unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let readers: Vec<_> = (0..4)
        .map(|kind| {
            let root = temp.path().to_path_buf();
            let started = started_tx.clone();
            let done = done_tx.clone();
            thread::spawn(move || {
                let reader = Library::prepare(root.clone()).unwrap();
                started.send(()).unwrap();
                match kind {
                    0 => assert!(reader.read().unwrap().0 == vec![snippet(2, "After apply")]),
                    1 => assert_eq!(
                        vault::read_document(&root).unwrap().unwrap().records[0]
                            .metadata
                            .name,
                        "Public post-apply vault"
                    ),
                    2 => {
                        let (plain, secure) = reader.catalogue().unwrap();
                        assert!(plain == vec![snippet(2, "After apply")]);
                        assert_eq!(secure[0].name, "Public post-apply vault");
                    }
                    _ => {
                        let (library, readiness) = Library::open_recoverable(root).unwrap();
                        assert_eq!(readiness, Readiness::Ready);
                        assert!(library.snippets == vec![snippet(2, "After apply")]);
                        assert_eq!(
                            library.secure_metadata().unwrap()[0].name,
                            "Public post-apply vault"
                        );
                    }
                }
                done.send(()).unwrap();
            })
        })
        .collect();
    drop(started_tx);
    drop(done_tx);
    for _ in 0..4 {
        started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    }
    assert!(matches!(
        done_rx.recv_timeout(Duration::from_millis(100)),
        Err(mpsc::RecvTimeoutError::Timeout)
    ));
    document.records[0].metadata.name = "Public post-apply vault".into();
    model::atomic_write(
        &temp.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    remove_marker(temp.path()).unwrap();
    drop(guard);
    for reader in readers {
        reader.join().unwrap();
    }
    for _ in 0..4 {
        done_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    }
    // A cached editor still has its old CAS ancestor, but catalogue reads must
    // not combine that stale ordinary file with fresh secure metadata.
    assert_eq!(library.snippets[0].id, Uuid::from_u128(1));
    assert_eq!(library.catalogue().unwrap().0[0].id, Uuid::from_u128(2));
}

#[test]
fn ordinary_apply_keeps_unrelated_records_and_round_trips_exact_wire_knowledge() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let source = snippet(1, "Original");
    let unrelated = snippet(2, "Unrelated edit");
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[source.clone(), unrelated.clone()], false).unwrap(),
    )
    .unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let view = actual(&library, &checkpoint.journal);
    let mut edited = source.clone();
    edited.content = "Remote merged body".into();
    let mut incoming = envelope(&edited, 100);
    incoming
        .extensions
        .insert("future".into(), crate::canonical::Value::Float(1.0));
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(incoming.clone())],
        &BTreeMap::from([(source.id, Some(view[&source.id].clone()))]),
    )
    .unwrap();
    commit(&library, &mut checkpoint, &key(), &SALT, plan).unwrap();
    let checkpoint = recover(temp.path(), &key(), &SALT, scope()).unwrap();
    let loaded = Library::open(temp.path().into()).unwrap();
    assert!(loaded.get(unrelated.id) == Some(unrelated));
    let projected = actual(&loaded, &checkpoint.journal);
    assert!(projected[&source.id].encode().unwrap() == incoming.encode().unwrap());
    assert!(!loaded.root.join("Sync").join(MARKER).exists());
}

#[test]
fn touched_record_cas_retries_while_other_writers_are_preserved() {
    let temp = tempfile::tempdir().unwrap();
    let mut library = Library::open(temp.path().into()).unwrap();
    let source = snippet(1, "Original");
    library.save(source.clone(), None).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let before = actual(&library, &checkpoint.journal);
    let mut edited = library.get(source.id).unwrap();
    edited.content = "Concurrent local edit".into();
    library
        .save(edited, library.get(source.id).as_ref())
        .unwrap();
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(envelope(&snippet(1, "Remote"), 100))],
        &BTreeMap::from([(source.id, Some(before[&source.id].clone()))]),
    )
    .unwrap();
    assert!(plan.changed_ids.is_empty() && plan.retry_ids.contains(&source.id));
    commit(&library, &mut checkpoint, &key(), &SALT, plan).unwrap();
    assert_eq!(
        library.read().unwrap().0[0].content,
        "Concurrent local edit"
    );
    assert!(!library.root.join("Sync").exists());
}

#[test]
fn a_writer_after_preparation_cannot_be_overwritten_by_full_file_images() {
    let temp = tempfile::tempdir().unwrap();
    let mut library = Library::open(temp.path().into()).unwrap();
    library.save(snippet(1, "Original"), None).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let before = actual(&library, &checkpoint.journal);
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(envelope(&snippet(1, "Remote"), 100))],
        &BTreeMap::from([(
            Uuid::from_u128(1),
            Some(before[&Uuid::from_u128(1)].clone()),
        )]),
    )
    .unwrap();
    library
        .save(snippet(2, "Concurrent unrelated record"), None)
        .unwrap();
    assert!(commit(&library, &mut checkpoint, &key(), &SALT, plan) == Err(Failure::StalePrimary));
    assert_eq!(library.read().unwrap().0.len(), 2);
    assert!(!library.root.join("Sync").exists());
}

#[test]
fn every_crash_phase_in_promotion_recovers_without_exposing_mixed_store_state() {
    for phase in 0..=4 {
        let temp = tempfile::tempdir().unwrap();
        let library = Library::open(temp.path().into()).unwrap();
        let full_vault = vault_fixture();
        let id = full_vault.records[0].metadata.id;
        let mut empty_vault = full_vault.clone();
        empty_vault.records.clear();
        install_vault(temp.path(), &empty_vault);
        let mut plain = snippet(1, "Public pre-promotion body");
        plain.id = id;
        model::atomic_write(
            &library.path(),
            &model::encode_library(&[plain], false).unwrap(),
        )
        .unwrap();
        let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
        let before = actual(&library, &checkpoint.journal);
        let incoming = projection::current(
            &[],
            Some(&full_vault),
            "11111111",
            &BTreeMap::new(),
            &BTreeMap::new(),
        )
        .unwrap()[&id]
            .clone();
        let plan = prepare(
            &library,
            &checkpoint.journal,
            "11111111",
            &[outcome(incoming.clone())],
            &BTreeMap::from([(id, Some(before[&id].clone()))]),
        )
        .unwrap();
        assert!(
            commit_with_fault(&library, &mut checkpoint, &key(), &SALT, plan, Some(phase))
                == Err(Failure::RecoveryRequired)
        );
        assert!(library.read().is_err());
        assert!(Vault::open(&library).is_err());
        let (mut reopened, readiness) = Library::open_recoverable(temp.path().into()).unwrap();
        assert_eq!(readiness, Readiness::RecoveryRequired);
        assert!(reopened.snippets.is_empty());
        assert!(reopened.reload_catalogue().is_err());
        let before_plain = fs::read(library.path()).unwrap();
        let before_vault = fs::read(temp.path().join("Vault/vault.json")).unwrap();
        let before_journal = fs::read(temp.path().join("Sync/journal.bin")).unwrap();
        let wrong_key = RootKey::from_bytes(&[0x12; 32]).unwrap();
        assert!(recover(temp.path(), &wrong_key, &SALT, scope()).is_err());
        let mut wrong_scope = scope();
        wrong_scope.dataset = Binding::from_checkpoint([0x12; 32]);
        assert!(recover(temp.path(), &key(), &SALT, wrong_scope).is_err());
        assert!(fs::read(library.path()).unwrap() == before_plain);
        assert!(fs::read(temp.path().join("Vault/vault.json")).unwrap() == before_vault);
        assert!(fs::read(temp.path().join("Sync/journal.bin")).unwrap() == before_journal);
        assert_eq!(reopened.readiness().unwrap(), Readiness::RecoveryRequired);
        let checkpoint = recover(temp.path(), &key(), &SALT, scope()).unwrap();
        assert_eq!(reopened.readiness().unwrap(), Readiness::Ready);
        reopened.reload_catalogue().unwrap();
        let library = reopened;
        if phase == 0 {
            assert!(library.get(id).is_some());
            assert!(
                vault::read_document(temp.path())
                    .unwrap()
                    .unwrap()
                    .records
                    .is_empty()
            );
        } else {
            assert!(library.get(id).is_none());
            assert_eq!(
                vault::read_document(temp.path())
                    .unwrap()
                    .unwrap()
                    .records
                    .len(),
                1
            );
            assert!(
                actual(&library, &checkpoint.journal)[&id].encode().unwrap()
                    == incoming.encode().unwrap()
            );
        }
        assert!(!library.root.join("Sync").join(MARKER).exists());
        recover(temp.path(), &key(), &SALT, scope()).unwrap();
    }
}

#[test]
fn ordinary_conflict_copies_are_staged_before_primary_and_survive_interrupted_apply() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let source = snippet(1, "Ancestor");
    model::atomic_write(
        &library.path(),
        &model::encode_library(std::slice::from_ref(&source), false).unwrap(),
    )
    .unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let before = actual(&library, &checkpoint.journal);
    let merge = merge::merge(
        None,
        Some(&envelope(&snippet(1, "Local losing version"), 2)),
        Some(&envelope(&snippet(1, "Remote winning version"), 3)),
    )
    .unwrap();
    let copy = merge.conflict_copies[0].clone();
    let expected = BTreeMap::from([
        (source.id, Some(before[&source.id].clone())),
        (copy.id, None),
    ]);
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[merge],
        &expected,
    )
    .unwrap();
    assert!(commit_with_fault(&library, &mut checkpoint, &key(), &SALT, plan, Some(1)).is_err());
    let checkpoint = recover(temp.path(), &key(), &SALT, scope()).unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let snippets = library.read().unwrap().0;
    assert_eq!(snippets.len(), 2);
    assert!(snippets.iter().any(|s| s.content == "Local losing version"));
    assert!(
        snippets
            .iter()
            .any(|s| s.content == "Remote winning version")
    );
    assert!(checkpoint.journal.pending().unwrap() == vec![copy]);
}

#[test]
fn key_scope_failure_or_unrecognized_post_crash_edit_never_clears_the_fence() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let incoming = envelope(&snippet(1, "Remote"), 100);
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(incoming.clone())],
        &BTreeMap::from([(incoming.id, None)]),
    )
    .unwrap();
    assert!(commit_with_fault(&library, &mut checkpoint, &key(), &SALT, plan, Some(1)).is_err());
    let wrong = RootKey::from_bytes(&[0xbb; 32]).unwrap();
    assert!(recover(temp.path(), &wrong, &SALT, scope()).is_err());
    let other = Scope {
        membership: scope().membership,
        dataset: Binding::from_checkpoint([0xcc; 32]),
    };
    assert!(recover(temp.path(), &key(), &SALT, other).is_err());
    assert!(library.root.join("Sync").join(MARKER).exists());
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[snippet(1, "External unrecognized edit")], false).unwrap(),
    )
    .unwrap();
    assert!(matches!(
        recover(temp.path(), &key(), &SALT, scope()),
        Err(Failure::StalePrimary)
    ));
    assert!(library.root.join("Sync").join(MARKER).exists());
    let raw = model::read_regular(&library.path()).unwrap().unwrap();
    assert_eq!(
        model::decode_library(&raw, false).unwrap()[0].content,
        "External unrecognized edit"
    );
}

#[test]
fn locked_secure_conflicts_and_foreign_records_defer_whole_preservation_units() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let document = vault_fixture();
    install_vault(temp.path(), &document);
    let checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let view = actual(&library, &checkpoint.journal);
    let mut secure = view[&document.records[0].metadata.id].clone();
    let mut later = secure.clone();
    later.hlc = Hlc::foreign(0xffff_0000_0000);
    later.fields.as_mut().unwrap().content = zeroize::Zeroizing::new(
        crate::crypto::seal_record(
            b"Fictional other body",
            &RootKey::from_bytes(&[0x11; 32]).unwrap(),
            &document.salt().unwrap(),
            &document.kid,
            later.id,
            false,
        )
        .unwrap()
        .text()
        .as_bytes()
        .to_vec(),
    );
    later.extensions.insert(
        "vaultContentHash".into(),
        crate::canonical::Value::text("ab".repeat(16)),
    );
    let merged = merge::merge(None, Some(&secure), Some(&later)).unwrap();
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[merged],
        &BTreeMap::from([(secure.id, Some(secure.clone()))]),
    )
    .unwrap();
    assert!(plan.changed_ids.is_empty() && plan.deferred_ids.contains(&secure.id));
    secure.extensions.insert(
        "vaultKID".into(),
        crate::canonical::Value::text("foreign-vault"),
    );
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(secure.clone())],
        &BTreeMap::from([(secure.id, Some(view[&secure.id].clone()))]),
    )
    .unwrap();
    assert!(plan.changed_ids.is_empty() && plan.incompatible_ids.contains(&secure.id));
}

fn secure_to_plain_conflict(
    library: &Library,
    journal: &Journal,
    document: &Document,
) -> (Outcome, ReadSet, Uuid) {
    let current = actual(library, journal);
    let secure = current[&document.records[0].metadata.id].clone();
    let mut winner = secure.clone();
    winner.secure = false;
    winner.hlc = Hlc::foreign(0xffff_0000_0000);
    winner.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public plain winner".to_vec());
    winner.extensions.clear();
    let merged = merge::merge(None, Some(&secure), Some(&winner)).unwrap();
    let copy_id = merge::secure_variants(merged.survivor.as_ref().unwrap()).unwrap()[0].copy_id;
    let expected = BTreeMap::from([
        (secure.id, Some(secure)),
        (copy_id, current.get(&copy_id).cloned()),
    ]);
    (merged, expected, copy_id)
}

#[test]
fn authenticated_secure_copy_is_durable_before_plain_representation_replaces_source() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let document = vault_fixture();
    install_vault(temp.path(), &document);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = Keyring::new(&root, &document).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let (merged, expected, copy_id) =
        secure_to_plain_conflict(&library, &checkpoint.journal, &document);
    let source = merged.survivor.as_ref().unwrap().clone();
    let plan = prepare_authenticated(
        &library,
        &checkpoint.journal,
        "11111111",
        &[merged],
        &expected,
        &keys,
    )
    .unwrap();
    assert!(plan.changed_ids == BTreeSet::from([source.id, copy_id]));
    commit(&library, &mut checkpoint, &key(), &SALT, plan).unwrap();
    let checkpoint = recover(temp.path(), &key(), &SALT, scope()).unwrap();
    let copy = checkpoint.journal.conflict_snapshots()[&copy_id].clone();
    assert!(checkpoint.journal.pending().unwrap() == vec![copy.clone()]);
    let current = actual(&library, &checkpoint.journal);
    assert!(!current[&source.id].secure && merge::has_unresolved(Some(&current[&source.id])));
    assert!(current[&copy_id] == copy);
    materializer::validate_evidence(&copy, &merge::secure_variants(&source).unwrap()[0], &keys)
        .unwrap();
    let vault = vault::read_document(temp.path()).unwrap().unwrap();
    assert_eq!(vault.records.len(), 1);
    assert_eq!(vault.records[0].metadata.id, copy_id);
    assert!(vault.same_identity(&document));
}

#[test]
fn authenticated_copy_and_carrier_redo_together_at_every_interrupted_phase() {
    for phase in 0..5 {
        let temp = tempfile::tempdir().unwrap();
        let library = Library::open(temp.path().into()).unwrap();
        let document = vault_fixture();
        install_vault(temp.path(), &document);
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let keys = Keyring::new(&root, &document).unwrap();
        let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
        let (merged, expected, copy_id) =
            secure_to_plain_conflict(&library, &checkpoint.journal, &document);
        let source_id = merged.survivor.as_ref().unwrap().id;
        let plan = prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            &[merged],
            &expected,
            &keys,
        )
        .unwrap();
        assert!(
            commit_with_fault(&library, &mut checkpoint, &key(), &SALT, plan, Some(phase)).is_err()
        );
        assert!(library.catalogue().is_err());
        let checkpoint = recover(temp.path(), &key(), &SALT, scope()).unwrap();
        let current = actual(&library, &checkpoint.journal);
        if phase == 0 {
            assert!(current[&source_id].secure && !current.contains_key(&copy_id));
        } else {
            assert!(!current[&source_id].secure && current[&copy_id].secure);
            let c0 = checkpoint.journal.conflict_snapshots()[&copy_id].clone();
            assert!(current[&copy_id] == c0);
            materializer::authenticate(&c0, &keys, true).unwrap();
        }
    }
}

#[test]
fn authenticated_c1_stays_primary_while_original_c0_remains_the_only_pending_offer() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut document = vault_fixture();
    install_vault(temp.path(), &document);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let (merged, mut expected, copy_id) =
        secure_to_plain_conflict(&library, &checkpoint.journal, &document);
    let source = merged.survivor.as_ref().unwrap().clone();
    let c0 = Evidence::prepare(
        std::slice::from_ref(&source),
        &Keyring::new(&root, &document).unwrap(),
        &BTreeMap::new(),
    )
    .unwrap()
    .copies()[&copy_id]
        .clone();
    checkpoint.journal.stage_conflict(&source, &[]).unwrap();
    checkpoint.journal.freeze_authenticated_copy(&c0).unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let mut c1 = c0.clone();
    c1.hlc = Hlc::foreign(0xffff_0000_0001);
    c1.fields.as_mut().unwrap().name = "Public local copy edit".into();
    c1.fields.as_mut().unwrap().content = zeroize::Zeroizing::new(
        crypto::seal_record(
            b"Public edited copy body",
            &root,
            &document.salt().unwrap(),
            &document.kid,
            copy_id,
            false,
        )
        .unwrap()
        .text()
        .as_bytes()
        .to_vec(),
    );
    c1.extensions.insert(
        "vaultContentHash".into(),
        crate::canonical::Value::text(crypto::content_hash(
            b"Public edited copy body",
            &root,
            &document.salt().unwrap(),
        )),
    );
    document.records.push(
        projection::vault_record(&c1, None, &document.kid)
            .unwrap()
            .unwrap(),
    );
    model::atomic_write(
        &temp.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let current = actual(&library, &checkpoint.journal);
    expected.insert(source.id, Some(current[&source.id].clone()));
    expected.insert(copy_id, Some(current[&copy_id].clone()));
    let plan = prepare_authenticated(
        &library,
        &checkpoint.journal,
        "11111111",
        &[merged],
        &expected,
        &Keyring::new(&root, &document).unwrap(),
    )
    .unwrap();
    assert!(plan.retry_ids.is_empty() && plan.deferred_ids.is_empty());
    commit(&library, &mut checkpoint, &key(), &SALT, plan).unwrap();
    let mut checkpoint = recover(temp.path(), &key(), &SALT, scope()).unwrap();
    assert!(actual(&library, &checkpoint.journal)[&copy_id] == current[&copy_id]);
    assert!(checkpoint.journal.conflict_snapshots()[&copy_id] == c0);
    assert!(checkpoint.journal.entry(copy_id).unwrap().desired == current[&copy_id]);
    assert!(checkpoint.journal.pending().unwrap() == vec![c0.clone()]);
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&c0))
        .unwrap()
        .remove(0);
    checkpoint
        .journal
        .accept_offered(
            &offered,
            crate::cloud::RecordVersion::from_checkpoint(
                "public-fictional-server-generation-copy-ack".into(),
            )
            .unwrap(),
        )
        .unwrap();
    let current = actual(&library, &checkpoint.journal);
    let resolution = checkpoint
        .journal
        .carrier_resolutions(&current)
        .unwrap()
        .remove(0);
    let resolved = resolution.resolved.clone();
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(resolved.clone())],
        &BTreeMap::from([(resolved.id, Some(current[&resolved.id].clone()))]),
    )
    .unwrap();
    commit(&library, &mut checkpoint, &key(), &SALT, plan).unwrap();
    checkpoint.journal.desire(resolved.clone()).unwrap();
    let primary = actual(&library, &checkpoint.journal);
    checkpoint.journal.reconcile_dependencies(&primary).unwrap();
    assert!(checkpoint.journal.pending().unwrap() == vec![resolved.clone()]);
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&resolved))
        .unwrap()
        .remove(0);
    checkpoint
        .journal
        .accept_offered(
            &offered,
            crate::cloud::RecordVersion::from_checkpoint(
                "public-fictional-server-generation-source-ack".into(),
            )
            .unwrap(),
        )
        .unwrap();
    checkpoint.journal.reconcile_dependencies(&primary).unwrap();
    assert!(checkpoint.journal.pending().unwrap() == vec![primary[&copy_id].clone()]);
    assert!(primary[&copy_id].fields.as_ref().unwrap().name == "Public local copy edit");
}

#[test]
fn implicit_copy_readset_race_never_applies_half_of_a_secure_preservation_unit() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut document = vault_fixture();
    install_vault(temp.path(), &document);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let (merged, expected, copy_id) =
        secure_to_plain_conflict(&library, &checkpoint.journal, &document);
    let source = merged.survivor.as_ref().unwrap();
    let proof = Evidence::prepare(
        std::slice::from_ref(source),
        &Keyring::new(&root, &document).unwrap(),
        &BTreeMap::new(),
    )
    .unwrap();
    document.records.push(
        projection::vault_record(&proof.copies()[&copy_id], None, &document.kid)
            .unwrap()
            .unwrap(),
    );
    model::atomic_write(
        &temp.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let plan = prepare_authenticated(
        &library,
        &checkpoint.journal,
        "11111111",
        std::slice::from_ref(&merged),
        &expected,
        &Keyring::new(&root, &document).unwrap(),
    )
    .unwrap();
    assert!(plan.changed_ids.is_empty() && plan.retry_ids == BTreeSet::from([source.id, copy_id]));
    let mut incomplete = expected.clone();
    incomplete.remove(&copy_id);
    assert!(matches!(
        prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            &[merged],
            &incomplete,
            &Keyring::new(&root, &document).unwrap()
        ),
        Err(Failure::InvalidState)
    ));
    assert!(!library.path().exists() && !library.root.join("Sync").exists());
}

#[test]
fn wrong_key_or_changed_root_material_refuses_secure_apply_without_creating_sync_files() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let document = vault_fixture();
    install_vault(temp.path(), &document);
    let checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let (merged, expected, _) = secure_to_plain_conflict(&library, &checkpoint.journal, &document);
    let wrong = RootKey::from_bytes(&[0x88; 32]).unwrap();
    assert!(matches!(
        prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            std::slice::from_ref(&merged),
            &expected,
            &Keyring::new(&wrong, &document).unwrap()
        ),
        Err(Failure::InvalidState)
    ));
    let mut changed = document.clone();
    changed.wrap_pass = changed.wrap_recovery.clone();
    model::atomic_write(
        &temp.path().join("Vault/vault.json"),
        &changed.encode().unwrap(),
    )
    .unwrap();
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    assert!(matches!(
        prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            &[merged],
            &expected,
            &Keyring::new(&root, &document).unwrap()
        ),
        Err(Failure::IncompatibleVault)
    ));
    assert!(!library.path().exists() && !library.root.join("Sync").exists());
}

#[test]
fn stale_checkpoint_cannot_publish_an_orphan_marker_or_change_primary() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut a = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let mut b = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let e = envelope(&snippet(1, "Remote"), 1);
    let plan = prepare(
        &library,
        &b.journal,
        "11111111",
        &[outcome(e.clone())],
        &BTreeMap::from([(e.id, None)]),
    )
    .unwrap();
    a.save(&library, &key(), &SALT).unwrap();
    assert!(commit(&library, &mut b, &key(), &SALT, plan).is_err());
    assert!(!library.root.join("Sync").join(MARKER).exists());
    assert!(!library.path().exists());
}

#[test]
fn linked_vault_or_malformed_marker_never_changes_external_files() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let outside = tempfile::tempdir().unwrap();
    symlink(outside.path(), temp.path().join("Vault")).unwrap();
    let checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    assert!(
        prepare(
            &library,
            &checkpoint.journal,
            "11111111",
            &[],
            &BTreeMap::new()
        )
        .is_err()
    );
    fs::remove_file(temp.path().join("Vault")).unwrap();
    fs::create_dir(temp.path().join("Sync")).unwrap();
    model::atomic_write(&temp.path().join("Sync").join(MARKER), b"invalid").unwrap();
    assert!(recover(temp.path(), &key(), &SALT, scope()).is_err());
    assert!(fs::read_dir(outside.path()).unwrap().next().is_none());
}

#[test]
fn actual_process_exit_between_replacements_is_recovered_without_rust_destructors() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let full = vault_fixture();
    let id = full.records[0].metadata.id;
    let mut empty = full.clone();
    empty.records.clear();
    install_vault(temp.path(), &empty);
    let mut old = snippet(1, "Public process-crash fixture");
    old.id = id;
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[old], false).unwrap(),
    )
    .unwrap();
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "primary::tests::process_crash_fixture",
            "--ignored",
            "--test-threads=1",
        ])
        .env("SNIPPETS_PRIMARY_CRASH_ROOT", temp.path())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(86));
    assert!(library.read().is_err());
    let checkpoint = recover(temp.path(), &key(), &SALT, scope()).unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    assert!(library.read().unwrap().0.is_empty());
    let document = vault::read_document(temp.path()).unwrap().unwrap();
    assert!(document.records[0].sealed == full.records[0].sealed);
    assert!(actual(&library, &checkpoint.journal)[&id].secure);
}

#[test]
#[ignore = "subprocess-only crash fixture; invoked by its isolated parent test"]
fn process_crash_fixture() {
    let root = std::env::var_os("SNIPPETS_PRIMARY_CRASH_ROOT").expect("isolated fixture root");
    let library = Library::open(root.into()).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let full = vault_fixture();
    let id = full.records[0].metadata.id;
    let view = actual(&library, &checkpoint.journal);
    let incoming = projection::current(
        &[],
        Some(&full),
        "11111111",
        &BTreeMap::new(),
        &BTreeMap::new(),
    )
    .unwrap()[&id]
        .clone();
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(incoming)],
        &BTreeMap::from([(id, Some(view[&id].clone()))]),
    )
    .unwrap();
    assert!(commit_with_fault(&library, &mut checkpoint, &key(), &SALT, plan, Some(2)).is_err());
    std::process::exit(86);
}

#[test]
fn restored_older_authenticated_checkpoint_cannot_authorize_marker_cleanup() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let old = model::read_regular_bounded(
        &temp.path().join("Sync/journal.bin"),
        crypto::MAX_CHECKPOINT_BYTES + 32,
    )
    .unwrap()
    .unwrap();
    let e = envelope(&snippet(1, "Public new post-image"), 100);
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(e.clone())],
        &BTreeMap::from([(e.id, None)]),
    )
    .unwrap();
    assert!(commit_with_fault(&library, &mut checkpoint, &key(), &SALT, plan, Some(2)).is_err());
    model::atomic_write(&temp.path().join("Sync/journal.bin"), &old).unwrap();
    assert!(matches!(
        recover(temp.path(), &key(), &SALT, scope()),
        Err(Failure::RecoveryRequired)
    ));
    assert!(temp.path().join("Sync").join(MARKER).exists());
    assert!(library.read().is_err());
}

#[test]
fn generated_conflict_id_refuses_an_unrelated_record_and_preserves_an_edited_copy() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let source = snippet(1, "Local losing body");
    let merged = merge::merge(
        None,
        Some(&envelope(&source, 1)),
        Some(&envelope(&snippet(1, "Other body"), 2)),
    )
    .unwrap();
    let copy = merged.conflict_copies[0].clone();
    let mut occupant = snippet(2, "Unrelated existing body");
    occupant.id = copy.id;
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[source.clone(), occupant], false).unwrap(),
    )
    .unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let view = actual(&library, &checkpoint.journal);
    let expected = BTreeMap::from([
        (source.id, Some(view[&source.id].clone())),
        (copy.id, Some(view[&copy.id].clone())),
    ]);
    assert!(matches!(
        prepare(
            &library,
            &checkpoint.journal,
            "11111111",
            std::slice::from_ref(&merged),
            &expected
        ),
        Err(Failure::ReservedCollision)
    ));
    let mut edited_copy = copy.snippet().unwrap().unwrap();
    edited_copy.content = "Edited legitimate copy".into();
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[source.clone(), edited_copy], false).unwrap(),
    )
    .unwrap();
    checkpoint.journal.projected.insert(copy.id, copy.clone());
    let view = actual(&library, &checkpoint.journal);
    let expected = BTreeMap::from([
        (source.id, Some(view[&source.id].clone())),
        (copy.id, Some(view[&copy.id].clone())),
    ]);
    let prepared = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[merged],
        &expected,
    )
    .unwrap();
    assert!(prepared.deferred_ids.is_empty() && prepared.changed_ids.contains(&copy.id));
    commit(&library, &mut checkpoint, &key(), &SALT, prepared).unwrap();
    let checkpoint = recover(temp.path(), &key(), &SALT, scope()).unwrap();
    assert!(checkpoint.journal.conflict_snapshots()[&copy.id] == copy);
    assert!(checkpoint.journal.pending().unwrap() == vec![copy.clone()]);
    assert!(checkpoint.journal.entry(copy.id).unwrap().desired == view[&copy.id]);
    assert_eq!(
        library
            .read()
            .unwrap()
            .0
            .iter()
            .find(|s| s.id == copy.id)
            .unwrap()
            .content,
        "Edited legitimate copy"
    );
}

fn nested_outcomes() -> (Vec<Outcome>, Envelope, Envelope, Envelope, Envelope) {
    let root = merge::merge(
        None,
        Some(&envelope(&snippet(1, "Public original losing version"), 1)),
        Some(&envelope(&snippet(1, "Public selected root"), 2)),
    )
    .unwrap();
    let source = root.survivor.as_ref().unwrap().clone();
    let c0 = root.conflict_copies[0].clone();
    let mut c1 = c0.clone();
    c1.hlc = Hlc::foreign(20);
    c1.fields.as_mut().unwrap().content = Zeroizing::new(b"Public selected copy edit".to_vec());
    let child = merge::merge(None, Some(&c0), Some(&c1)).unwrap();
    let c1 = child.survivor.as_ref().unwrap().clone();
    let d0 = child.conflict_copies[0].clone();
    (vec![root, child], source, c0, c1, d0)
}

#[test]
fn nested_batch_keeps_original_evidence_and_selected_copy_in_either_order_after_redo() {
    for reverse in [false, true] {
        for fault in [None, Some(1), Some(2)] {
            let temp = tempfile::tempdir().unwrap();
            let library = Library::open(temp.path().into()).unwrap();
            let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
            let (mut outcomes, source, c0, c1, d0) = nested_outcomes();
            if reverse {
                outcomes.reverse();
            }
            let expected = BTreeMap::from([(source.id, None), (c1.id, None), (d0.id, None)]);
            let plan = prepare(
                &library,
                &checkpoint.journal,
                "11111111",
                &outcomes,
                &expected,
            )
            .unwrap();
            assert!(plan.changed_ids == expected.keys().copied().collect());
            let result = commit_with_fault(&library, &mut checkpoint, &key(), &SALT, plan, fault);
            assert_eq!(result.is_ok(), fault.is_none());
            let recovered = recover(temp.path(), &key(), &SALT, scope()).unwrap();
            let physical = actual(&library, &recovered.journal);
            assert!(
                physical[&source.id] == source && physical[&c1.id] == c1 && physical[&d0.id] == d0
            );
            assert!(recovered.journal.conflict_snapshots()[&c0.id] == c0);
            assert!(recovered.journal.pending().unwrap() == vec![d0]);
        }
    }
}

#[test]
fn a_nested_member_race_defers_the_entire_component_but_allows_independent_records() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let (mut outcomes, source, c0, c1, d0) = nested_outcomes();
    checkpoint.journal.projected.insert(d0.id, d0.clone());
    let independent = envelope(&snippet(2, "Public independent record"), 30);
    outcomes.push(outcome(independent.clone()));
    let mut changed = d0.clone();
    changed.hlc = Hlc::foreign(40);
    changed.fields.as_mut().unwrap().name = "Public racing edit".into();
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[changed.snippet().unwrap().unwrap()], false).unwrap(),
    )
    .unwrap();
    let expected = BTreeMap::from([
        (source.id, None),
        (c0.id, None),
        (d0.id, None),
        (independent.id, None),
    ]);
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &outcomes,
        &expected,
    )
    .unwrap();
    assert!(plan.changed_ids == BTreeSet::from([independent.id]));
    assert!(plan.retry_ids == BTreeSet::from([source.id, c1.id, d0.id]));
    assert!(plan.dependencies.is_empty() && plan.held.is_empty());
    let mut incomplete = expected.clone();
    incomplete.remove(&d0.id);
    assert!(
        prepare(
            &library,
            &checkpoint.journal,
            "11111111",
            &outcomes,
            &incomplete
        )
        .is_err()
    );
}

pub(crate) fn nested_secure_outcomes(
    library: &Library,
    journal: &Journal,
    document: &Document,
) -> (Vec<Outcome>, ReadSet, Envelope, Envelope, Envelope) {
    let (mut parent, mut expected, id) = secure_to_plain_conflict(library, journal, document);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let c0 = Evidence::prepare(
        std::slice::from_ref(parent.survivor.as_ref().unwrap()),
        &Keyring::new(&root, document).unwrap(),
        &BTreeMap::new(),
    )
    .unwrap()
    .copies()[&id]
        .clone();
    let mut c1 = c0.clone();
    c1.hlc = Hlc::foreign(0xffff_0000_0002);
    c1.fields.as_mut().unwrap().name = "Public selected nested secure copy".into();
    let body = b"Public selected secure C1 body";
    c1.fields.as_mut().unwrap().content = Zeroizing::new(
        crypto::seal_record(
            body,
            &root,
            &document.salt().unwrap(),
            &document.kid,
            id,
            false,
        )
        .unwrap()
        .text()
        .as_bytes()
        .to_vec(),
    );
    c1.extensions.insert(
        "vaultContentHash".into(),
        crate::canonical::Value::text(crypto::content_hash(body, &root, &document.salt().unwrap())),
    );
    let mut lower = c0.clone();
    lower.hlc = Hlc::foreign(0xffff_0000_0001);
    lower.secure = false;
    lower.fields.as_mut().unwrap().content =
        Zeroizing::new(b"Public nested ordinary loser".to_vec());
    lower
        .extensions
        .retain(|key, _| key == merge::COPY_PROVENANCE);
    let child = merge::merge(None, Some(&lower), Some(&c1)).unwrap();
    let c1 = child.survivor.as_ref().unwrap().clone();
    let d0 = child.conflict_copies[0].clone();
    parent.conflict_copies.push(c0.clone());
    expected.insert(d0.id, None);
    (vec![parent, child], expected, c0, c1, d0)
}

#[test]
fn secure_c0_and_explicit_nested_c1_borrow_one_vault_key_and_redo_without_resealing_c0() {
    for reverse in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let library = Library::open(temp.path().into()).unwrap();
        let document = vault_fixture();
        install_vault(temp.path(), &document);
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
        let (mut outcomes, expected, c0, c1, d0) =
            nested_secure_outcomes(&library, &checkpoint.journal, &document);
        if reverse {
            outcomes.reverse();
        }
        let prepared = prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            &outcomes,
            &expected,
            &Keyring::new(&root, &document).unwrap(),
        )
        .unwrap();
        assert!(prepared.deferred_ids.is_empty() && prepared.retry_ids.is_empty());
        assert!(
            commit_with_fault(&library, &mut checkpoint, &key(), &SALT, prepared, Some(2)).is_err()
        );
        let recovered = recover(temp.path(), &key(), &SALT, scope()).unwrap();
        let physical = actual(&library, &recovered.journal);
        assert!(physical[&c1.id] == c1);
        assert!(recovered.journal.conflict_snapshots()[&c0.id] == c0);
        assert!(recovered.journal.pending().unwrap() == vec![d0]);
        let mut vault = Vault::open(&library).unwrap();
        let document = vault::read_document(temp.path()).unwrap().unwrap();
        vault
            .finish_authentication(
                document.authenticate("Café public fixture", false).unwrap(),
                vault.generation(),
            )
            .unwrap();
        assert!(vault.body(c1.id).unwrap().as_slice() == b"Public selected secure C1 body");
    }
}

#[test]
fn secure_original_c0_is_authenticated_even_when_an_explicit_c1_shadows_its_uuid() {
    for metadata in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let library = Library::open(temp.path().into()).unwrap();
        let document = vault_fixture();
        install_vault(temp.path(), &document);
        let checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
        let (mut outcomes, expected, _, _, _) =
            nested_secure_outcomes(&library, &checkpoint.journal, &document);
        let original = &mut outcomes[0].conflict_copies[0];
        if metadata {
            original.fields.as_mut().unwrap().name =
                "Public validly sealed but edited C1 metadata".into();
        } else {
            original.fields.as_mut().unwrap().content =
                Zeroizing::new(b"invalid-public-ciphertext".to_vec());
        }
        let before = fs::read(temp.path().join("Vault/vault.json")).unwrap();
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        assert!(
            prepare_authenticated(
                &library,
                &checkpoint.journal,
                "11111111",
                &outcomes,
                &expected,
                &Keyring::new(&root, &document).unwrap()
            )
            .is_err()
        );
        assert!(fs::read(temp.path().join("Vault/vault.json")).unwrap() == before);
        assert!(!library.path().exists() && !temp.path().join("Sync").exists());
    }
}

#[test]
fn implicit_copy_preserves_newer_reviewed_intent_and_does_not_resurrect_a_reviewed_absence() {
    for absent in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let library = Library::open(temp.path().into()).unwrap();
        let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
        let (outcomes, source, c0, mut c1, _) = nested_outcomes();
        c1.fields.as_mut().unwrap().content =
            Zeroizing::new(b"Public visible copy version".to_vec());
        let mut held = c1.clone();
        held.hlc = Hlc::foreign(30);
        held.fields.as_mut().unwrap().content =
            Zeroizing::new(b"Public newer reviewed copy intent".to_vec());
        let mut current = BTreeMap::new();
        if absent {
            held = held
                .tombstone(Hlc::foreign(40), "22222222".into(), true)
                .unwrap();
        } else {
            current.insert(c1.id, c1.clone());
            model::atomic_write(
                &library.path(),
                &model::encode_library(&[c1.snippet().unwrap().unwrap()], false).unwrap(),
            )
            .unwrap();
            checkpoint.journal.projected = current.clone();
        }
        checkpoint.journal.desire(held.clone()).unwrap();
        checkpoint
            .journal
            .resume_scope(
                &current,
                scope(),
                crate::inbound::Feed::new(Uuid::from_u128(55), 1).unwrap(),
            )
            .unwrap();
        let view = actual(&library, &checkpoint.journal);
        let expected = BTreeMap::from([(source.id, None), (c0.id, view.get(&c0.id).cloned())]);
        let prepared = prepare(
            &library,
            &checkpoint.journal,
            "11111111",
            &outcomes[..1],
            &expected,
        )
        .unwrap();
        if absent {
            assert!(prepared.changed_ids.is_empty());
            assert!(prepared.deferred_ids == BTreeSet::from([source.id, c0.id]));
        } else {
            commit(&library, &mut checkpoint, &key(), &SALT, prepared).unwrap();
            assert!(checkpoint.journal.entry(c0.id).unwrap().desired == held);
            assert!(actual(&library, &checkpoint.journal)[&c1.id] == c1);
            assert!(checkpoint.journal.pending().unwrap() == vec![c0]);
        }
    }
}

#[test]
fn primary_redo_cannot_replace_vault_key_material() {
    let before = vault_fixture();
    let mut after = before.clone();
    after.kid = "Different vault".into();
    let intent = Intent {
        nonce: [0x11; 16],
        before_plain: None,
        after_plain: None,
        before_vault: Some(Zeroizing::new(before.encode().unwrap())),
        after_vault: Some(Zeroizing::new(after.encode().unwrap())),
    };
    assert!(intent.validate().is_err());
}

#[test]
fn preexisting_keyword_collisions_and_disabled_merge_losers_remain_representable() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut a = snippet(1, "Existing A");
    let mut b = snippet(2, "Existing B");
    a.keyword = "same".into();
    b.keyword = "SAME".into();
    model::atomic_write(
        &library.path(),
        &model::encode_library(&[a, b], false).unwrap(),
    )
    .unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let mut c = snippet(3, "Disabled new merge loser");
    c.keyword = "same".into();
    c.is_enabled = false;
    let e = envelope(&c, 100);
    let plan = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(e.clone())],
        &BTreeMap::from([(e.id, None)]),
    )
    .unwrap();
    commit(&library, &mut checkpoint, &key(), &SALT, plan).unwrap();
    let current = library.read().unwrap().0;
    assert!(current[0].is_enabled && current[1].is_enabled && !current[2].is_enabled);
    assert_eq!(current[2].keyword, "same");
    let mut unsafe_new = snippet(4, "Unarbitrated new collision");
    unsafe_new.keyword = "same".into();
    let e = envelope(&unsafe_new, 101);
    assert!(matches!(
        prepare(
            &library,
            &checkpoint.journal,
            "11111111",
            &[outcome(e.clone())],
            &BTreeMap::from([(e.id, None)])
        ),
        Err(Failure::InvalidState)
    ));
}
