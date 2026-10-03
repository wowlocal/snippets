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
    fixture_with_corruption(unstaged, remote, false)
}

fn fixture_with_corruption(
    unstaged: bool,
    remote: bool,
    corrupt: bool,
) -> (
    tempfile::TempDir,
    Library,
    Server,
    crate::vault::Document,
    Envelope,
    Uuid,
) {
    let (temp, library, mut server, document, source, id) =
        missing_originals::missing_original(corrupt);
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

fn edit_secure(original: &Envelope, document: &crate::vault::Document, body: &[u8]) -> Envelope {
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let mut selected = original.clone();
    selected.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff30);
    selected.fields.as_mut().unwrap().content = zeroize::Zeroizing::new(
        crate::crypto::seal_record(
            body,
            &root,
            &document.salt().unwrap(),
            &document.kid,
            selected.id,
            false,
        )
        .unwrap()
        .text()
        .as_bytes()
        .to_vec(),
    );
    selected.extensions.insert(
        "vaultContentHash".into(),
        crate::canonical::Value::text(crate::crypto::content_hash(
            body,
            &root,
            &document.salt().unwrap(),
        )),
    );
    selected
}

fn freeze_original(library: &Library, document: &crate::vault::Document, id: Uuid) -> Envelope {
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = crate::materializer::Keyring::new(&root, document).unwrap();
    let mut checkpoint = load(library);
    checkpoint.journal = checkpoint
        .journal
        .materialize_preservation(id, &keys)
        .unwrap();
    let original = checkpoint
        .journal
        .preservation_original(id)
        .unwrap()
        .clone();
    checkpoint.save(library, &key(), &SALT).unwrap();
    original
}

fn save_child(
    library: &Library,
    document: &mut crate::vault::Document,
    selected: &Envelope,
    present: bool,
) {
    document.records.clear();
    if present {
        document.records.push(
            crate::projection::vault_record(selected, None, &document.kid)
                .unwrap()
                .unwrap(),
        );
    }
    write_vault(library, document);
    let mut checkpoint = load(library);
    checkpoint
        .journal
        .projected
        .insert(selected.id, selected.clone());
    checkpoint.journal.desire(selected.clone()).unwrap();
    checkpoint.save(library, &key(), &SALT).unwrap();
}

#[test]
fn current_source_review_keeps_edited_secure_c1_beside_its_frozen_original_c0() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, mut document, source, id) = fixture(false, true);
        let c0 = freeze_original(&library, &document, id);
        let c1 = edit_secure(&c0, &document, b"Public current companion secure C1");
        save_child(&library, &mut document, &c1, true);
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert_eq!(review.summary().restored_conflict_copies, 0);
        let mut vault = unlock_vault(&library);
        owner
            .decide_deletion_review_with_vault(&mut server, review, choice, Some(&mut vault))
            .unwrap();
        drop(vault);
        let after = load(&library);
        assert!(after.journal.preservation_original(id) == Some(&c0));
        assert!(primary::current(&library, &after.journal, "11111111").unwrap()[&id] == c1);
        missing_originals::finish(&owner, &library, &mut server);
        let sent: Vec<_> = server
            .submitted
            .iter()
            .flatten()
            .filter(|(e, _)| e.id == id)
            .collect();
        assert!(sent.first().unwrap().0 == c0);
        assert!(sent.last().unwrap().0 == c1);
        assert_eq!(
            server.records[&source.id].0.deleted,
            choice == Choice::Delete
        );
        assert!(
            primary::current(&library, &load(&library).journal, "11111111").unwrap()[&id] == c1
        );
    }
}

#[test]
fn nested_current_sources_restore_missing_child_intent_and_preserve_every_original() {
    for present in [false, true] {
        for choice in [Choice::Keep, Choice::Delete] {
            for fault in [None, Some(2)] {
                let (_temp, library, mut server, mut document, source, id) = fixture(false, true);
                let c0 = freeze_original(&library, &document, id);
                let c1 = edit_secure(&c0, &document, b"Public nested secure current child C1");
                let child = merge::merge(None, Some(&c0), Some(&c1))
                    .unwrap()
                    .survivor
                    .unwrap();
                let grandchild = merge::secure_variants(&child).unwrap().remove(0).copy_id;
                save_child(&library, &mut document, &child, present);
                let key = key();
                let scope = scope();
                let owner = owner(&library, &key, &scope, &|| Ok(()));
                let review = owner.prepare_deletion_review(&mut server).unwrap();
                assert_eq!(review.id, source.id);
                assert_eq!(review.summary().preserved_conflict_copies, 2);
                assert_eq!(
                    review.summary().restored_conflict_copies,
                    if present { 1 } else { 2 }
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
                    "present {present}, choice {choice:?}, fault {fault:?}"
                );
                if fault.is_some() {
                    primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
                }
                let after = load(&library);
                assert!(after.journal.preservation_original(id) == Some(&c0));
                let d0 = after
                    .journal
                    .preservation_original(grandchild)
                    .unwrap()
                    .clone();
                let current = primary::current(&library, &after.journal, "11111111").unwrap();
                assert!(current[&id] == child && current[&grandchild] == d0);
                missing_originals::finish(&owner, &library, &mut server);
                let sent: Vec<_> = server.submitted.iter().flatten().map(|(e, _)| e).collect();
                let d = sent.iter().position(|e| **e == d0).unwrap();
                // The earlier active generation still owns its first C0 send.
                // The new nested generation must acknowledge D0 before its
                // own subsequent C0 delivery and selected child release.
                let c = sent.iter().rposition(|e| **e == c0).unwrap();
                assert!(d < c);
                let final_child = primary::current(&library, &load(&library).journal, "11111111")
                    .unwrap()
                    .remove(&id)
                    .unwrap();
                assert!(final_child.fields == child.fields);
                assert!(!merge::has_unresolved(Some(&final_child)));
                assert_eq!(
                    server.records[&source.id].0.deleted,
                    choice == Choice::Delete
                );
            }
        }
    }
}

#[test]
fn an_unoffered_earlier_source_cannot_release_a_new_deletion_before_new_originals() {
    for remote in [false, true] {
        let (_temp, library, mut server, document, source, _) =
            missing_originals::missing_original(false);
        let mut checkpoint = load(&library);
        let losing = edit_secure(
            &checkpoint.journal.confirmed(source.id).unwrap().envelope,
            &document,
            b"Public later raw source losing version before deletion",
        );
        let selected = envelope(
            source.id.as_u128(),
            "Public later raw source winner before deletion",
            0xffff_ffff_ff50,
        );
        let current = merge::merge(None, Some(&losing), Some(&selected))
            .unwrap()
            .survivor
            .unwrap();
        let mut records = library.read().unwrap().0;
        records.retain(|record| record.id != source.id);
        if remote {
            records.push(current.snippet().unwrap().unwrap());
        }
        crate::model::atomic_write(
            &library.path(),
            &crate::model::encode_library(&records, false).unwrap(),
        )
        .unwrap();
        checkpoint
            .journal
            .projected
            .insert(current.id, current.clone());
        checkpoint.journal.desire(current).unwrap();
        checkpoint.save(&library, &key(), &SALT).unwrap();
        if remote {
            queue_delete_at(&library, &mut server, source.id, 0xffff_ffff_ff80);
        }
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert_eq!(review.id, source.id);
        let mut vault = unlock_vault(&library);
        owner
            .decide_deletion_review_with_vault(
                &mut server,
                review,
                Choice::Delete,
                Some(&mut vault),
            )
            .unwrap();
        drop(vault);
        let originals: Vec<_> = load(&library)
            .journal
            .restoration_generations()
            .unwrap()
            .iter()
            .flat_map(|frame| frame.sources.iter().flat_map(|(_, copies)| copies.clone()))
            .collect();
        assert!(originals.len() >= 3);
        missing_originals::finish(&owner, &library, &mut server);
        let sent: Vec<_> = server.submitted.iter().flatten().map(|(e, _)| e).collect();
        let deletion = sent
            .iter()
            .position(|e| e.id == source.id && e.deleted)
            .unwrap();
        for original in originals {
            let saved = sent.iter().position(|e| **e == original).unwrap();
            assert!(
                saved < deletion,
                "remote {remote}, original position {saved}, deletion position {deletion}"
            );
        }
    }
}

#[test]
fn a_current_source_review_cannot_approve_a_missing_childs_independent_deletion() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, document, source, id) = fixture(false, true);
        let c0 = freeze_original(&library, &document, id);
        let deleted = c0
            .tombstone(
                crate::clock::Hlc::foreign(0xffff_ffff_ff40),
                "11111111".into(),
                true,
            )
            .unwrap();
        let mut checkpoint = load(&library);
        checkpoint.journal.desire(deleted).unwrap();
        checkpoint.save(&library, &key(), &SALT).unwrap();
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        // Inspect the parent's own review independently of prerequisite routing;
        // its decision boundary must still refuse another record's consent.
        let review = owner
            .prepare_deletion_review_inner(&mut server, false)
            .unwrap();
        assert_eq!(review.id, source.id);
        let before = load(&library);
        let plain = fs::read(library.path()).unwrap();
        let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
        let mut vault = unlock_vault(&library);
        assert_eq!(
            owner
                .decide_deletion_review_with_vault(&mut server, review, choice, Some(&mut vault))
                .err(),
            Some(Failure::PreservationRequired)
        );
        assert!(load(&library).same_snapshot(&before));
        assert!(
            plain == fs::read(library.path()).unwrap()
                && sealed == fs::read(library.root.join("Vault/vault.json")).unwrap()
        );
        assert!(server.submitted.is_empty());
    }
}

#[test]
fn independently_deleted_child_is_reviewed_before_its_parent_and_both_choices_finish() {
    for child_choice in [Choice::Keep, Choice::Delete] {
        for parent_choice in [Choice::Keep, Choice::Delete] {
            let (_temp, library, mut server, document, source, id) = fixture(false, true);
            let c0 = freeze_original(&library, &document, id);
            let deleted = c0
                .tombstone(
                    crate::clock::Hlc::foreign(0xffff_ffff_ff40),
                    "11111111".into(),
                    true,
                )
                .unwrap();
            let mut checkpoint = load(&library);
            checkpoint.journal.desire(deleted.clone()).unwrap();
            checkpoint.save(&library, &key(), &SALT).unwrap();
            let before = load(&library);
            let plain = fs::read(library.path()).unwrap();
            let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, id);
            assert!(
                review.summary().prerequisite && review.summary().kind == Kind::PendingDeletion
            );
            assert!(load(&library).same_snapshot(&before));
            assert!(
                plain == fs::read(library.path()).unwrap()
                    && sealed == fs::read(library.root.join("Vault/vault.json")).unwrap()
            );
            let mut vault = unlock_vault(&library);
            owner
                .decide_deletion_review_with_vault(
                    &mut server,
                    review,
                    child_choice,
                    Some(&mut vault),
                )
                .unwrap();
            let child_decided = load(&library);
            vault.reload().unwrap();
            assert!(child_decided.journal.inbox.next() == before.journal.inbox.next());
            assert!(
                !child_decided
                    .journal
                    .deletion_approvals
                    .contains_key(&source.id)
            );
            assert!(child_decided.journal.preservation_original(id) == Some(&c0));
            if child_choice == Choice::Delete {
                assert!(child_decided.journal.deletion_approved(&deleted).unwrap());
                assert!(child_decided.journal.known_absence(id));
            } else {
                assert!(
                    vault.record(id).unwrap().sealed.text().as_bytes()
                        == c0.fields.as_ref().unwrap().content.as_slice()
                );
                assert!(!child_decided.journal.known_absence(id));
            }
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, source.id);
            assert!(!review.summary().prerequisite);
            owner
                .decide_deletion_review_with_vault(
                    &mut server,
                    review,
                    parent_choice,
                    Some(&mut vault),
                )
                .unwrap();
            drop(vault);
            missing_originals::finish(&owner, &library, &mut server);
            assert_eq!(
                server.records[&source.id].0.deleted,
                parent_choice == Choice::Delete
            );
            assert_eq!(
                server.records[&id].0.deleted,
                child_choice == Choice::Delete
            );
            let sent: Vec<_> = server.submitted.iter().flatten().map(|(e, _)| e).collect();
            let original = sent.iter().position(|e| **e == c0).unwrap();
            let parent = sent.iter().position(|e| e.id == source.id).unwrap();
            assert!(original < parent);
            if child_choice == Choice::Delete {
                assert!(
                    sent.iter()
                        .position(|e| **e == deleted)
                        .is_some_and(|position| original < position)
                );
            }
            assert!(load(&library).journal.deletion_approvals.is_empty());
        }
    }
}

fn deleted_child() -> (
    tempfile::TempDir,
    Library,
    Server,
    Envelope,
    Envelope,
    Envelope,
) {
    let (temp, library, server, document, source, id) = fixture(false, true);
    let original = freeze_original(&library, &document, id);
    let deleted = original
        .tombstone(
            crate::clock::Hlc::foreign(0xffff_ffff_ff40),
            "11111111".into(),
            true,
        )
        .unwrap();
    let mut checkpoint = load(&library);
    checkpoint.journal.desire(deleted.clone()).unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    (temp, library, server, source, original, deleted)
}

#[test]
fn prerequisite_child_decision_recovers_each_wal_phase_without_consuming_the_parent() {
    for choice in [Choice::Keep, Choice::Delete] {
        for fault in 0..5 {
            let (_temp, library, mut server, source, original, deleted) = deleted_child();
            let before = load(&library);
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, original.id);
            let mut vault = unlock_vault(&library);
            assert!(
                owner
                    .decide_deletion_authenticated(
                        &mut server,
                        review,
                        choice,
                        Some(&mut vault),
                        Some(fault)
                    )
                    .is_err()
            );
            primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
            if fault == 0 {
                let review = owner.prepare_deletion_review(&mut server).unwrap();
                assert_eq!(review.id, original.id);
                owner
                    .decide_deletion_review_with_vault(
                        &mut server,
                        review,
                        choice,
                        Some(&mut vault),
                    )
                    .unwrap();
            }
            let decided = load(&library);
            assert!(
                decided.journal.inbox == before.journal.inbox
                    && decided.journal.outbound == before.journal.outbound
            );
            assert!(!decided.journal.deletion_approvals.contains_key(&source.id));
            assert!(decided.journal.preservation_original(original.id) == Some(&original));
            if choice == Choice::Delete {
                assert!(decided.journal.deletion_approved(&deleted).unwrap());
            }
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, source.id);
            owner
                .decide_deletion_review_with_vault(
                    &mut server,
                    review,
                    Choice::Keep,
                    Some(&mut vault),
                )
                .unwrap();
            drop(vault);
            missing_originals::finish(&owner, &library, &mut server);
            assert!(!server.records[&source.id].0.deleted);
            assert_eq!(
                server.records[&original.id].0.deleted,
                choice == Choice::Delete
            );
            assert!(load(&library).journal.deletion_approvals.is_empty());
        }
    }
}

#[test]
fn changed_prerequisite_scope_feed_primary_checkpoint_or_session_cannot_publish() {
    for change in 0..6 {
        let (_temp, library, mut server, source, original, _deleted) = deleted_child();
        let key = key();
        let scope = scope();
        let valid = Cell::new(true);
        let guard = || {
            if valid.get() {
                Ok(())
            } else {
                Err(receiver::Failure::SessionChanged)
            }
        };
        let owner = owner(&library, &key, &scope, &guard);
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert!(review.id == original.id && review.summary().prerequisite);
        let mut vault = unlock_vault(&library);
        match change {
            0 => valid.set(false),
            1 => server.scope.membership = crate::cloud::Binding::from_checkpoint([0x99; 32]),
            2 => server.feed = feed(4),
            3 => {
                let mut records = library.read().unwrap().0;
                records[0].content = "Public later unrelated edit".into();
                crate::model::atomic_write(
                    &library.path(),
                    &crate::model::encode_library(&records, false).unwrap(),
                )
                .unwrap();
            }
            4 => {
                let mut checkpoint = load(&library);
                let mut changed = source.clone();
                changed.fields.as_mut().unwrap().name = "Public changed pending source".into();
                checkpoint.journal.desire(changed).unwrap();
                checkpoint.save(&library, &key, &SALT).unwrap();
            }
            _ => vault.lock(),
        }
        let before = load(&library);
        let plain = fs::read(library.path()).unwrap();
        let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
        assert!(
            owner
                .decide_deletion_review_with_vault(
                    &mut server,
                    review,
                    Choice::Keep,
                    Some(&mut vault)
                )
                .is_err()
        );
        assert!(load(&library).same_snapshot(&before));
        assert!(
            plain == fs::read(library.path()).unwrap()
                && sealed == fs::read(library.root.join("Vault/vault.json")).unwrap()
        );
        assert!(!library.root.join("Sync/primary.pending").exists() && server.submitted.is_empty());
    }
}

#[test]
fn an_unmaterialized_deleted_child_requires_authentication_before_either_decision() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, document, source, id) = fixture(false, true);
        let mut deleted = source.clone();
        deleted.id = id;
        deleted.secure = true;
        deleted.deleted = true;
        deleted.fields = None;
        deleted.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff40);
        deleted.extensions = std::collections::BTreeMap::from([(
            "vaultKID".into(),
            crate::canonical::Value::text(document.kid.clone()),
        )]);
        let mut checkpoint = load(&library);
        checkpoint.journal.desire(deleted.clone()).unwrap();
        checkpoint.save(&library, &key(), &SALT).unwrap();
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert!(review.id == id && review.summary().prerequisite && review.summary().can_keep);
        assert!(review.summary().keep_requires_vault && review.summary().delete_requires_vault);
        let before = load(&library);
        assert_eq!(
            owner
                .decide_deletion_review(&mut server, review, choice)
                .err(),
            Some(Failure::VaultLocked)
        );
        assert!(load(&library).same_snapshot(&before));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        let mut vault = unlock_vault(&library);
        owner
            .decide_deletion_review_with_vault(&mut server, review, choice, Some(&mut vault))
            .unwrap();
        let original = load(&library)
            .journal
            .preservation_original(id)
            .unwrap()
            .clone();
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert_eq!(review.id, source.id);
        owner
            .decide_deletion_review_with_vault(&mut server, review, Choice::Keep, Some(&mut vault))
            .unwrap();
        drop(vault);
        missing_originals::finish(&owner, &library, &mut server);
        assert_eq!(server.records[&id].0.deleted, choice == Choice::Delete);
        assert!(!server.records[&source.id].0.deleted);
        assert!(
            server
                .submitted
                .iter()
                .flatten()
                .any(|(e, _)| *e == original)
        );
        assert!(load(&library).journal.deletion_approvals.is_empty());
    }
}

#[test]
fn a_child_edited_after_restore_keeps_its_latest_physical_c1_when_the_parent_is_deleted() {
    let (_temp, library, mut server, source, original, _deleted) = deleted_child();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let mut vault = unlock_vault(&library);
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review_with_vault(&mut server, review, Choice::Keep, Some(&mut vault))
        .unwrap();
    vault.reload().unwrap();
    let before = vault.record(original.id).unwrap();
    vault
        .save(
            &library,
            before.metadata.clone(),
            b"Public newer physical child C1 after restore",
            Some(&before),
        )
        .unwrap();
    let current = primary::current(&library, &load(&library).journal, "11111111")
        .unwrap()
        .remove(&original.id)
        .unwrap();
    assert!(current.fields.as_ref().unwrap().content != original.fields.as_ref().unwrap().content);
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    assert_eq!(review.id, source.id);
    owner
        .decide_deletion_review_with_vault(&mut server, review, Choice::Delete, Some(&mut vault))
        .unwrap();
    assert!(
        primary::current(&library, &load(&library).journal, "11111111").unwrap()[&original.id]
            .fields
            .as_ref()
            .unwrap()
            .content
            == current.fields.as_ref().unwrap().content
    );
    drop(vault);
    missing_originals::finish(&owner, &library, &mut server);
    let child = server.records[&original.id].0.open(&key, &SALT).unwrap();
    assert!(child.fields.as_ref().unwrap().content == current.fields.as_ref().unwrap().content);
    assert!(server.records[&source.id].0.deleted && !child.deleted);
    assert!(
        server
            .submitted
            .iter()
            .flatten()
            .any(|(e, _)| *e == original)
    );
}

fn raw_deleted_child(
    remote: bool,
    corrupt: bool,
) -> (tempfile::TempDir, Library, Server, Envelope, Envelope) {
    let (temp, library, server, document, source, id) =
        fixture_with_corruption(true, remote, corrupt);
    let mut deleted = source.clone();
    deleted.id = id;
    deleted.secure = true;
    deleted.deleted = true;
    deleted.fields = None;
    deleted.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff40);
    deleted.extensions = std::collections::BTreeMap::from([(
        "vaultKID".into(),
        crate::canonical::Value::text(document.kid.clone()),
    )]);
    let mut checkpoint = load(&library);
    assert!(
        checkpoint
            .journal
            .preservation_generations(source.id)
            .unwrap()
            .is_empty()
    );
    checkpoint.journal.desire(deleted.clone()).unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    (temp, library, server, source, deleted)
}

#[test]
fn raw_prerequisite_children_can_be_restored_or_deleted_before_either_parent_decision() {
    for remote in [false, true] {
        for child_choice in [Choice::Keep, Choice::Delete] {
            for parent_choice in [Choice::Keep, Choice::Delete] {
                let (_temp, library, mut server, source, deleted) =
                    raw_deleted_child(remote, false);
                let id = deleted.id;
                let before = load(&library);
                let plain = fs::read(library.path()).unwrap();
                let key = key();
                let scope = scope();
                let owner = owner(&library, &key, &scope, &|| Ok(()));
                let review = owner.prepare_deletion_review(&mut server).unwrap();
                assert_eq!(review.id, id);
                assert!(review.summary().prerequisite && review.summary().can_keep);
                assert!(
                    review.summary().keep_requires_vault && review.summary().delete_requires_vault
                );
                assert!(load(&library).same_snapshot(&before));
                let mut vault = unlock_vault(&library);
                owner
                    .decide_deletion_review_with_vault(
                        &mut server,
                        review,
                        child_choice,
                        Some(&mut vault),
                    )
                    .unwrap();
                let after = load(&library);
                assert!(
                    after.journal.inbox == before.journal.inbox
                        && after.journal.outbound == before.journal.outbound
                );
                assert!(!after.journal.deletion_approvals.contains_key(&source.id));
                assert!(fs::read(library.path()).unwrap() == plain);
                let original = after.journal.preservation_original(id).unwrap().clone();
                let review = owner.prepare_deletion_review(&mut server).unwrap();
                assert_eq!(review.id, source.id);
                owner
                    .decide_deletion_review_with_vault(
                        &mut server,
                        review,
                        parent_choice,
                        Some(&mut vault),
                    )
                    .unwrap();
                drop(vault);
                missing_originals::finish(&owner, &library, &mut server);
                assert_eq!(
                    server.records[&id].0.deleted,
                    child_choice == Choice::Delete
                );
                assert_eq!(
                    server.records[&source.id].0.deleted,
                    parent_choice == Choice::Delete
                );
                let sent: Vec<_> = server.submitted.iter().flatten().map(|(e, _)| e).collect();
                let original_position = sent.iter().position(|e| **e == original).unwrap();
                let parent_position = sent.iter().position(|e| e.id == source.id).unwrap();
                assert!(original_position < parent_position);
                assert!(load(&library).journal.deletion_approvals.is_empty());
            }
        }
    }
}

#[test]
fn raw_prerequisite_originals_and_decisions_survive_all_wal_phases_without_parent_consent() {
    for choice in [Choice::Keep, Choice::Delete] {
        for fault in 0..5 {
            let (_temp, library, mut server, source, deleted) = raw_deleted_child(true, false);
            let before = load(&library);
            let plain = fs::read(library.path()).unwrap();
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            let mut vault = unlock_vault(&library);
            assert!(
                owner
                    .decide_deletion_authenticated(
                        &mut server,
                        review,
                        choice,
                        Some(&mut vault),
                        Some(fault)
                    )
                    .is_err()
            );
            drop(vault);
            primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
            let mut vault = unlock_vault(&library);
            if fault == 0 {
                // The authenticated pre-WAL baseline advances only its fence
                // nonce; the raw graph, intent and permissions stay unchanged.
                let mut recovered = load(&library).journal;
                assert!(recovered.primary_intent.is_none());
                recovered.primary_epoch = before.journal.primary_epoch;
                assert!(recovered == before.journal);
                let review = owner.prepare_deletion_review(&mut server).unwrap();
                assert!(review.id == deleted.id && review.summary().can_keep);
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
            assert!(fs::read(library.path()).unwrap() == plain);
            assert!(
                after.journal.inbox == before.journal.inbox
                    && after.journal.outbound == before.journal.outbound
            );
            assert!(!after.journal.deletion_approvals.contains_key(&source.id));
            let original = after
                .journal
                .preservation_original(deleted.id)
                .unwrap()
                .clone();
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, source.id);
            owner
                .decide_deletion_review_with_vault(
                    &mut server,
                    review,
                    Choice::Keep,
                    Some(&mut vault),
                )
                .unwrap();
            assert!(load(&library).journal.preservation_original(deleted.id) == Some(&original));
            drop(vault);
            missing_originals::finish(&owner, &library, &mut server);
            assert_eq!(
                server.records[&deleted.id].0.deleted,
                choice == Choice::Delete
            );
            assert!(!server.records[&source.id].0.deleted);
            assert!(load(&library).journal.deletion_approvals.is_empty());
        }
    }
}

#[test]
fn raw_prerequisite_authentication_or_stale_review_failures_leave_no_original_or_permission() {
    for choice in [Choice::Keep, Choice::Delete] {
        for change in 0..8 {
            let (_temp, library, mut server, source, deleted) =
                raw_deleted_child(true, change == 1);
            let key = key();
            let scope = scope();
            let valid = Cell::new(true);
            let guard = || {
                if valid.get() {
                    Ok(())
                } else {
                    Err(receiver::Failure::SessionChanged)
                }
            };
            let owner = owner(&library, &key, &scope, &guard);
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert!(review.id == deleted.id && review.summary().can_keep);
            let mut vault = unlock_vault(&library);
            match change {
                2 => valid.set(false),
                3 => server.scope.membership = crate::cloud::Binding::from_checkpoint([0x99; 32]),
                4 => server.feed = feed(4),
                5 => {
                    let mut records = library.read().unwrap().0;
                    records[0].content = "Public changed primary during raw-child review".into();
                    crate::model::atomic_write(
                        &library.path(),
                        &crate::model::encode_library(&records, false).unwrap(),
                    )
                    .unwrap();
                }
                6 => {
                    let mut checkpoint = load(&library);
                    let mut changed = source.clone();
                    changed.fields.as_mut().unwrap().name =
                        "Public changed raw carrier intent".into();
                    checkpoint.journal.desire(changed).unwrap();
                    checkpoint.save(&library, &key, &SALT).unwrap();
                }
                7 => vault.lock(),
                _ => (),
            }
            let before = load(&library);
            let plain = fs::read(library.path()).unwrap();
            let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let result = if change == 0 {
                owner.decide_deletion_review(&mut server, review, choice)
            } else {
                owner.decide_deletion_review_with_vault(
                    &mut server,
                    review,
                    choice,
                    Some(&mut vault),
                )
            };
            assert!(result.is_err());
            assert!(load(&library).same_snapshot(&before));
            assert!(
                fs::read(library.path()).unwrap() == plain
                    && fs::read(library.root.join("Vault/vault.json")).unwrap() == sealed
            );
            assert!(
                load(&library)
                    .journal
                    .preservation_original(deleted.id)
                    .is_none()
            );
            assert!(
                !library.root.join("Sync/primary.pending").exists() && server.submitted.is_empty()
            );
        }
    }
}

#[test]
fn raw_prerequisite_materialization_keeps_an_ambiguous_earlier_source_packet_and_c0_exact() {
    for choice in [Choice::Keep, Choice::Delete] {
        for fault in [None, Some(2)] {
            let (_temp, library, mut server, mut document, source, id) =
                missing_originals::missing_original(false);
            let old_original = freeze_original(&library, &document, id);
            save_child(&library, &mut document, &old_original, true);
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            assert_eq!(
                owner.send(&mut server, 1).unwrap().status,
                sender::Status::MoreBatches
            );
            assert!(
                owner
                    .send(&mut missing_originals::LostReply(&mut server), 1)
                    .is_err()
            );
            let mut checkpoint = load(&library);
            let packet = checkpoint.journal.outbound.clone().unwrap();
            let losing = edit_secure(
                &checkpoint.journal.confirmed(source.id).unwrap().envelope,
                &document,
                b"Public new raw prerequisite beside an earlier lost reply",
            );
            let mut selected = envelope(
                source.id.as_u128(),
                "Public new raw parent winner",
                0xffff_ffff_ff50,
            );
            selected.fields.as_mut().unwrap().keyword = "".into();
            let current = merge::merge(None, Some(&losing), Some(&selected))
                .unwrap()
                .survivor
                .unwrap();
            let new_id = merge::secure_variants(&current).unwrap().remove(0).copy_id;
            assert_ne!(new_id, id);
            let mut deleted = current.clone();
            deleted.id = new_id;
            deleted.secure = true;
            deleted.deleted = true;
            deleted.fields = None;
            deleted.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff60);
            deleted.extensions = std::collections::BTreeMap::from([(
                "vaultKID".into(),
                crate::canonical::Value::text(document.kid.clone()),
            )]);
            checkpoint.journal.desire(current).unwrap();
            checkpoint.journal.desire(deleted.clone()).unwrap();
            let mut records = library.read().unwrap().0;
            records.retain(|record| record.id != source.id);
            crate::model::atomic_write(
                &library.path(),
                &crate::model::encode_library(&records, false).unwrap(),
            )
            .unwrap();
            checkpoint.save(&library, &key, &SALT).unwrap();
            let before = load(&library);
            let plain = fs::read(library.path()).unwrap();
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert!(
                review.id == new_id && review.summary().prerequisite && review.summary().can_keep
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
            assert_eq!(result.is_ok(), fault.is_none(), "{result:?}");
            if fault.is_some() {
                primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
            }
            let after = load(&library);
            assert!(fs::read(library.path()).unwrap() == plain);
            assert!(after.journal.outbound == Some(packet.clone()));
            assert!(after.journal.inbox == before.journal.inbox);
            assert!(before.journal.confirmed(id) == after.journal.confirmed(id));
            assert!(after.journal.preservation_original(id) == Some(&old_original));
            assert!(!after.journal.deletion_approvals.contains_key(&source.id));
            let new_original = after.journal.preservation_original(new_id).unwrap().clone();
            let mut vault = unlock_vault(&library);
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, source.id);
            owner
                .decide_deletion_review_with_vault(
                    &mut server,
                    review,
                    Choice::Delete,
                    Some(&mut vault),
                )
                .unwrap();
            drop(vault);
            assert!(load(&library).journal.outbound == Some(packet.clone()));
            assert!(load(&library).journal.preservation_original(new_id) == Some(&new_original));
            let start = server.submitted.len();
            missing_originals::finish(&owner, &library, &mut server);
            let sent: Vec<_> = server.submitted[start..].iter().flatten().collect();
            assert!(
                sent[0].0 == packet.offers[0].offered.envelope
                    && sent[0].1 == packet.offers[0].offered.record_version
            );
            assert!(sent.iter().any(|(e, _)| *e == new_original));
            assert_eq!(server.records[&new_id].0.deleted, choice == Choice::Delete);
            assert!(server.records[&source.id].0.deleted);
            assert!(load(&library).journal.deletion_approvals.is_empty());
        }
    }
}

#[test]
fn repairing_an_accepted_copy_preserves_new_current_carriers_on_it_and_its_parent() {
    for choice in [Choice::Keep, Choice::Delete] {
        for fault in [None, Some(2)] {
            let (_temp, library, mut server, mut document, source, id) =
                missing_originals::missing_original(false);
            let c0 = freeze_original(&library, &document, id);
            save_child(&library, &mut document, &c0, true);
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            assert_eq!(
                owner.send(&mut server, 1).unwrap().status,
                sender::Status::MoreBatches
            );
            let c1 = edit_secure(
                &c0,
                &document,
                b"Public accepted current secure child winner",
            );
            let child = merge::merge(None, Some(&c0), Some(&c1))
                .unwrap()
                .survivor
                .unwrap();
            let d_id = merge::secure_variants(&child).unwrap().remove(0).copy_id;
            save_child(&library, &mut document, &child, true);
            let mut checkpoint = load(&library);
            let losing = edit_secure(
                &checkpoint.journal.confirmed(source.id).unwrap().envelope,
                &document,
                b"Public new current parent secure loser",
            );
            let selected = envelope(
                source.id.as_u128(),
                "Public new current parent winner",
                0xffff_ffff_ff50,
            );
            let parent = merge::merge(None, Some(&losing), Some(&selected))
                .unwrap()
                .survivor
                .unwrap();
            let r_id = merge::secure_variants(&parent).unwrap().remove(0).copy_id;
            let mut records = library.read().unwrap().0;
            records.retain(|record| record.id != parent.id);
            records.push(parent.snippet().unwrap().unwrap());
            crate::model::atomic_write(
                &library.path(),
                &crate::model::encode_library(&records, false).unwrap(),
            )
            .unwrap();
            checkpoint
                .journal
                .projected
                .insert(parent.id, parent.clone());
            checkpoint.journal.desire(parent.clone()).unwrap();
            checkpoint.save(&library, &key, &SALT).unwrap();
            queue_delete_at(&library, &mut server, id, 0xffff_ffff_ff80);
            let before = load(&library);
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, id);
            assert_eq!(review.summary().preserved_conflict_copies, 2);
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
                "choice {choice:?}, fault {fault:?}, failure {:?}",
                result.as_ref().err()
            );
            if fault.is_some() {
                primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
            }
            let after = load(&library);
            assert!(before.journal.confirmed(source.id) == after.journal.confirmed(source.id));
            assert!(after.journal.preservation_original(id) == Some(&c0));
            let d0 = after.journal.preservation_original(d_id).unwrap().clone();
            let r0 = after.journal.preservation_original(r_id).unwrap().clone();
            let current = primary::current(&library, &after.journal, "11111111").unwrap();
            assert!(current[&d_id] == d0 && current[&r_id] == r0 && current[&parent.id] == parent);
            assert_eq!(current.contains_key(&id), choice == Choice::Keep);
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
            let role = |candidate| {
                if candidate == source.id {
                    "parent"
                } else if candidate == id {
                    "child"
                } else if candidate == d_id {
                    "D0"
                } else if candidate == r_id {
                    "R0"
                } else {
                    "other"
                }
            };
            let final_journal = load(&library).journal;
            let frames: Vec<_> = final_journal
                .restoration_generations()
                .unwrap()
                .iter()
                .map(|frame| {
                    frame
                        .targets
                        .values()
                        .map(|target| {
                            (
                                role(target.id),
                                target.deleted,
                                merge::has_unresolved(Some(target)),
                                final_journal.deletion_approved(target).unwrap(),
                            )
                        })
                        .collect::<Vec<_>>()
                })
                .collect();
            let sent: Vec<_> = server
                .submitted
                .iter()
                .flatten()
                .map(|(e, _)| (role(e.id), e.deleted))
                .collect();
            assert_eq!(
                status,
                sender::Status::Settled,
                "choice {choice:?}, fault {fault:?}, sent {sent:?}, frames {frames:?}"
            );
            assert!(!final_journal.has_preservation_work());
            assert_eq!(server.records[&id].0.deleted, choice == Choice::Delete);
            assert!(server.submitted.iter().flatten().any(|(e, _)| *e == d0));
            assert!(server.submitted.iter().flatten().any(|(e, _)| *e == r0));
            let final_parent = primary::current(&library, &load(&library).journal, "11111111")
                .unwrap()
                .remove(&parent.id)
                .unwrap();
            assert!(
                final_parent.fields == parent.fields && !merge::has_unresolved(Some(&final_parent))
            );
        }
    }
}

#[test]
fn current_group_authority_does_not_open_generic_raw_deletion_apis() {
    let (_temp, library, server, document, source, _) = fixture(false, true);
    let before = load(&library);
    let plain = fs::read(library.path()).unwrap();
    let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = crate::materializer::Keyring::new(&root, &document).unwrap();
    let group =
        primary::DeletionGroup::prepare(source.id, vec![source.clone()], &before.journal, &keys)
            .unwrap();
    let stamp = crate::clock::Hlc::foreign(0xffff_ffff_ff40);
    assert!(
        source
            .tombstone(stamp.clone(), "11111111".into(), true)
            .is_err()
    );
    let deleted = group.tombstone(&source, stamp).unwrap();
    let outcomes = [merge::Outcome {
        survivor: Some(deleted),
        conflict_copies: vec![],
    }];
    let current = primary::current(&library, &before.journal, "11111111").unwrap();
    let expected = primary::preservation_read_set(&outcomes, &current).unwrap();
    assert!(primary::prepare(&library, &before.journal, "11111111", &outcomes, &expected).is_err());
    assert!(
        primary::prepare_authenticated(
            &library,
            &before.journal,
            "11111111",
            &outcomes,
            &expected,
            &keys
        )
        .is_err()
    );
    assert!(load(&library).same_snapshot(&before));
    assert!(
        plain == fs::read(library.path()).unwrap()
            && sealed == fs::read(library.root.join("Vault/vault.json")).unwrap()
    );
    assert!(server.submitted.is_empty());
}

#[test]
fn valid_losing_carriers_cannot_authorize_a_damaged_current_secure_source_body() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, mut document, losing) = secure_setup();
        let selected = edit_secure(
            &losing,
            &document,
            b"Public damaged own secure source winner",
        );
        let mut source = merge::merge(None, Some(&losing), Some(&selected))
            .unwrap()
            .survivor
            .unwrap();
        source.extensions.insert(
            "vaultContentHash".into(),
            crate::canonical::Value::text("00".repeat(16)),
        );
        document.records = vec![
            crate::projection::vault_record(&source, None, &document.kid)
                .unwrap()
                .unwrap(),
        ];
        write_vault(&library, &document);
        let mut checkpoint = load(&library);
        checkpoint.journal.stage_conflict(&source, &[]).unwrap();
        checkpoint
            .journal
            .projected
            .insert(source.id, source.clone());
        checkpoint.journal.desire(source.clone()).unwrap();
        checkpoint.save(&library, &key(), &SALT).unwrap();
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let keys = crate::materializer::Keyring::new(&root, &document).unwrap();
        assert!(
            crate::materializer::Evidence::prepare(
                std::slice::from_ref(&source),
                &keys,
                &std::collections::BTreeMap::new()
            )
            .is_ok()
        );
        queue_delete_at(&library, &mut server, source.id, 0xffff_ffff_ff50);
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

#[test]
fn a_new_current_group_preserves_an_ambiguous_earlier_source_packet_and_originals() {
    for choice in [Choice::Keep, Choice::Delete] {
        for fault in [None, Some(2)] {
            let (_temp, library, mut server, mut document, source, id) =
                missing_originals::missing_original(false);
            let old_original = freeze_original(&library, &document, id);
            save_child(&library, &mut document, &old_original, true);
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            assert_eq!(
                owner.send(&mut server, 1).unwrap().status,
                sender::Status::MoreBatches
            );
            assert!(
                owner
                    .send(&mut missing_originals::LostReply(&mut server), 1)
                    .is_err()
            );
            let mut checkpoint = load(&library);
            let packet = checkpoint.journal.outbound.clone().unwrap();
            let accepted_source = packet.offers[0].offered.envelope.clone();
            let losing = edit_secure(
                &checkpoint.journal.confirmed(source.id).unwrap().envelope,
                &document,
                b"Public new current losing secure version",
            );
            let mut selected = envelope(
                source.id.as_u128(),
                "Public new current source winner",
                0xffff_ffff_ff50,
            );
            selected.fields.as_mut().unwrap().keyword = "".into();
            let current = merge::merge(None, Some(&losing), Some(&selected))
                .unwrap()
                .survivor
                .unwrap();
            let new_id = merge::secure_variants(&current).unwrap().remove(0).copy_id;
            assert_ne!(new_id, id);
            checkpoint.journal.desire(current).unwrap();
            let mut records = library.read().unwrap().0;
            records.retain(|record| record.id != source.id);
            crate::model::atomic_write(
                &library.path(),
                &crate::model::encode_library(&records, false).unwrap(),
            )
            .unwrap();
            checkpoint.save(&library, &key, &SALT).unwrap();
            let before = load(&library);
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, source.id);
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
                "choice {choice:?}, fault {fault:?}, failure {:?}",
                result.as_ref().err()
            );
            if fault.is_some() {
                primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
            }
            let after = load(&library);
            assert!(after.journal.outbound == Some(packet.clone()));
            assert!(before.journal.confirmed(id) == after.journal.confirmed(id));
            assert!(after.journal.preservation_original(id) == Some(&old_original));
            let new_original = after.journal.preservation_original(new_id).unwrap().clone();
            let start = server.submitted.len();
            missing_originals::finish(&owner, &library, &mut server);
            let sent: Vec<_> = server.submitted[start..].iter().flatten().collect();
            assert!(
                sent[0].0 == accepted_source
                    && sent[0].1 == packet.offers[0].offered.record_version
            );
            assert!(sent.iter().any(|(e, _)| *e == new_original));
            assert_eq!(
                server.records[&source.id].0.deleted,
                choice == Choice::Delete
            );
        }
    }
}

#[test]
fn confirmed_remote_deletion_still_needs_actual_current_group_source_receipt() {
    let (_temp, library, mut server, _, source, id) = fixture(true, true);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    let mut vault = unlock_vault(&library);
    owner
        .decide_deletion_review_with_vault(&mut server, review, Choice::Delete, Some(&mut vault))
        .unwrap();
    drop(vault);
    let before_send = load(&library);
    let deleted = &before_send.journal.confirmed(source.id).unwrap().envelope;
    let version = before_send
        .journal
        .confirmed(source.id)
        .unwrap()
        .record_version
        .clone();
    assert!(before_send.journal.deletion_approved(deleted).unwrap());
    assert!(before_send.journal.entry(source.id).is_none());
    assert!(
        before_send
            .journal
            .pending()
            .unwrap()
            .iter()
            .all(|e| e.id != source.id)
    );
    assert_eq!(
        owner.receive(&mut server, 1).unwrap().status,
        receiver::Status::Current
    );
    assert!(server.submitted.is_empty());
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::MoreBatches
    );
    assert_eq!(server.submitted.len(), 1);
    assert_eq!(server.submitted[0].len(), 1);
    assert_eq!(server.submitted[0][0].0.id, id);
    assert!(load(&library).journal.has_preservation_work());
    missing_originals::finish(&owner, &library, &mut server);
    assert_eq!(server.submitted.len(), 2);
    assert!(server.submitted[1][0].0 == *deleted);
    assert!(server.submitted[1][0].1.as_ref() == Some(&version));
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
