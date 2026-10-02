//! Current v1 carrier units: actual authenticated originals, WAL and positional CAS.
use super::*;

fn fixture(
    unstaged: bool,
    remote: bool,
) -> (
    tempfile::TempDir,
    Library,
    Server,
    crate::vault::Document,
    Envelope,
    Uuid,
) {
    let (temp, library, mut server, document, source, id) =
        missing_originals::missing_original(false);
    if unstaged {
        let mut checkpoint = load(&library);
        let old = &checkpoint.journal;
        let mut next = Journal::new(scope());
        next.key_epoch = Some(1);
        next.inbox = old.inbox.clone();
        next.projected = old.projected().clone();
        for e in old.agreed_envelopes().values() {
            next.record_confirmed(
                e.clone(),
                old.confirmed(e.id).unwrap().record_version.clone(),
            )
            .unwrap();
        }
        next.desire(source.clone()).unwrap();
        checkpoint.journal = next;
        checkpoint.save(&library, &key(), &SALT).unwrap();
    }
    if remote {
        queue_delete_at(&library, &mut server, source.id, 0xffff_ffff_ff10);
    } else {
        let mut records = library.read().unwrap().0;
        records.retain(|record| record.id != source.id);
        crate::model::atomic_write(
            &library.path(),
            &crate::model::encode_library(&records, false).unwrap(),
        )
        .unwrap();
    }
    (temp, library, server, document, source, id)
}

#[test]
fn current_carrier_decisions_freeze_originals_and_finish_all_published_wal_phases() {
    for unstaged in [false, true] {
        for remote in [false, true] {
            for choice in [Choice::Keep, Choice::Delete] {
                for fault in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
                    let (_temp, library, mut server, _, source, id) = fixture(unstaged, remote);
                    let key = key();
                    let scope = scope();
                    let owner = owner(&library, &key, &scope, &|| Ok(()));
                    let before = load(&library);
                    let review = owner.prepare_deletion_review(&mut server).unwrap();
                    assert_eq!(review.id, source.id);
                    assert_eq!(review.summary().preserved_conflict_copies, 1);
                    assert_eq!(review.summary().restored_conflict_copies, 1);
                    assert!(
                        review.summary().keep_requires_vault
                            && review.summary().delete_requires_vault
                    );
                    let mut vault = unlock_vault(&library);
                    let result = owner.decide_deletion_authenticated(
                        &mut server,
                        review,
                        choice,
                        Some(&mut vault),
                        fault,
                    );
                    drop(vault);
                    assert_eq!(
                        result.is_ok(),
                        fault.is_none(),
                        "unstaged {unstaged}, remote {remote}, choice {choice:?}, fault {fault:?}"
                    );
                    if fault.is_some() {
                        primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
                    }
                    if fault == Some(0) {
                        assert!(
                            before
                                .journal
                                .preserves_transport_state(&load(&library).journal)
                        );
                        let review = owner.prepare_deletion_review(&mut server).unwrap();
                        let mut vault = unlock_vault(&library);
                        owner
                            .decide_deletion_review_with_vault(
                                &mut server,
                                review,
                                choice,
                                Some(&mut vault),
                            )
                            .unwrap();
                    }
                    let after = load(&library);
                    let original = after.journal.preservation_original(id).unwrap().clone();
                    let current = primary::current(&library, &after.journal, "11111111").unwrap();
                    assert!(
                        current[&id].fields.as_ref().unwrap().content
                            == original.fields.as_ref().unwrap().content
                    );
                    assert_eq!(current.contains_key(&source.id), choice == Choice::Keep);
                    if choice == Choice::Delete && !remote {
                        let deleted = &after.journal.entry(source.id).unwrap().desired;
                        assert!(after.journal.deletion_approved(deleted).unwrap());
                        assert!(
                            deleted.extensions["userDeletion.v1"]
                                == crate::canonical::Value::Array(vec![
                                    crate::canonical::Value::text(source.hash().unwrap())
                                ])
                        );
                    }
                    let mut status = sender::Status::MoreBatches;
                    for _ in 0..20 {
                        status = owner.send(&mut server, 2).unwrap().status;
                        if status == sender::Status::ReceiveFirst {
                            owner.receive(&mut server, 1).unwrap();
                            continue;
                        }
                        if status != sender::Status::MoreBatches {
                            break;
                        }
                    }
                    assert_eq!(
                        status,
                        sender::Status::Settled,
                        "unstaged {unstaged}, remote {remote}, choice {choice:?}, fault {fault:?}, submitted {}",
                        server.submitted.len()
                    );
                    assert!(!load(&library).journal.has_preservation_work());
                    let sent: Vec<_> = server.submitted.iter().flatten().map(|(e, _)| e).collect();
                    assert!(sent.iter().find(|e| e.id == id).unwrap() == &&original);
                    assert!(
                        sent.iter().position(|e| e.id == id).unwrap()
                            < sent.iter().position(|e| e.id == source.id).unwrap()
                    );
                    assert_eq!(
                        server.records[&source.id].0.deleted,
                        choice == Choice::Delete
                    );
                    assert!(!merge::has_unresolved(Some(
                        &server.records[&source.id].0.open(&key, &SALT).unwrap()
                    )));
                    if remote {
                        assert!(load(&library).journal.inbox.next().is_none());
                    }
                }
            }
        }
    }
}

#[test]
fn current_carrier_review_refuses_unknown_versions_reserved_occupants_and_stale_files() {
    for change in 0..3 {
        let (_temp, library, mut server, _, mut source, id) = fixture(false, true);
        if change == 0 {
            source.extensions.insert(
                format!("{}v9.{}", merge::CONFLICT_PREFIX, "a".repeat(64)),
                crate::canonical::Value::text("public future carrier"),
            );
            let mut checkpoint = load(&library);
            checkpoint
                .journal
                .projected
                .insert(source.id, source.clone());
            checkpoint.journal.desire(source).unwrap();
            checkpoint.save(&library, &key(), &SALT).unwrap();
        } else if change == 1 {
            let mut unrelated = envelope(99, "Public reserved current-carrier occupant", 1);
            unrelated.id = id;
            let mut records = library.read().unwrap().0;
            records.push(unrelated.snippet().unwrap().unwrap());
            crate::model::atomic_write(
                &library.path(),
                &crate::model::encode_library(&records, false).unwrap(),
            )
            .unwrap();
        }
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        if change < 2 {
            let before = load(&library);
            let plain = fs::read(library.path()).unwrap();
            assert!(owner.prepare_deletion_review(&mut server).is_err());
            assert!(
                load(&library).same_snapshot(&before) && plain == fs::read(library.path()).unwrap()
            );
        } else {
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            let mut records = library.read().unwrap().0;
            records[0].content = "Public later unrelated current file edit".into();
            crate::model::atomic_write(
                &library.path(),
                &crate::model::encode_library(&records, false).unwrap(),
            )
            .unwrap();
            let before = load(&library);
            let plain = fs::read(library.path()).unwrap();
            let mut vault = unlock_vault(&library);
            assert_eq!(
                owner
                    .decide_deletion_review_with_vault(
                        &mut server,
                        review,
                        Choice::Delete,
                        Some(&mut vault)
                    )
                    .err(),
                Some(Failure::Changed)
            );
            assert!(
                load(&library).same_snapshot(&before) && plain == fs::read(library.path()).unwrap()
            );
        }
        assert!(server.submitted.is_empty());
    }
}

#[test]
fn damaged_current_carriers_refuse_both_decisions_without_partial_originals_or_consent() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, _, source, _) = missing_originals::missing_original(true);
        queue_delete_at(&library, &mut server, source.id, 0xffff_ffff_ff10);
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        let before = load(&library);
        let plain = fs::read(library.path()).unwrap();
        let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
        let mut vault = unlock_vault(&library);
        assert!(
            owner
                .decide_deletion_review_with_vault(&mut server, review, choice, Some(&mut vault))
                .is_err()
        );
        assert!(load(&library).same_snapshot(&before));
        assert!(
            plain == fs::read(library.path()).unwrap()
                && sealed == fs::read(library.root.join("Vault/vault.json")).unwrap()
        );
        assert!(server.submitted.is_empty());
    }
}
