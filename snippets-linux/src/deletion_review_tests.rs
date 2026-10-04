//! Public fictional records and isolated files; actual crypto, CAS and WAL.
use super::*;
use crate::{
    crypto::RootKey,
    journal::{Confirmed, Scope},
    model::Library,
    sender,
    snapshot_review::tests::{SALT, Server, cursor, envelope, feed, key, scope, write_primary},
};
use std::{cell::Cell, fs};
#[path = "deletion_current_tests.rs"]
mod current_recovery;
#[path = "deletion_missing_tests.rs"]
mod missing_originals;
#[path = "deletion_preservation_tests.rs"]
mod preservation;
#[path = "deletion_source_tests.rs"]
mod source_recovery;
fn owner<'a>(
    library: &'a Library,
    key: &'a RootKey,
    scope: &'a Scope,
    guard: &'a dyn Fn() -> receiver::Result<()>,
) -> Owner<'a> {
    Owner {
        library,
        scope,
        key_epoch: 1,
        checkpoint_key: key,
        checkpoint_salt: &SALT,
        wire_key: key,
        wire_salt: &SALT,
        device: Some("11111111"),
        vault_keys: None,
        validate_session: guard,
    }
}
fn load(library: &Library) -> Checkpoint {
    Checkpoint::load(library, &key(), &SALT, scope()).unwrap()
}
fn setup() -> (tempfile::TempDir, Library, Server) {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let records = [
        envelope(1, "Public deletion body", 1000),
        envelope(2, "Public unrelated body", 2000),
    ];
    write_primary(&library, &records);
    let mut server = Server::new();
    let mut checkpoint = load(&library);
    checkpoint.journal.key_epoch = Some(1);
    for e in records {
        server.add(&e);
        checkpoint.journal.projected.insert(e.id, e.clone());
        checkpoint
            .journal
            .record_confirmed(e.clone(), server.records[&e.id].1.clone())
            .unwrap();
    }
    checkpoint.journal.inbox.select_feed(feed(3)).unwrap();
    let all = checkpoint.journal.agreed_envelopes();
    checkpoint
        .journal
        .inbox
        .receive(
            &feed(3),
            None,
            all.keys()
                .map(|id| checkpoint.journal.confirmed(*id).unwrap().clone())
                .collect(),
            cursor("baseline"),
            true,
            false,
        )
        .unwrap();
    while checkpoint.journal.inbox.next().is_some() {
        checkpoint.journal.inbox.acknowledge_record().unwrap();
    }
    checkpoint.journal.inbox.complete_page().unwrap();
    checkpoint
        .journal
        .inbox
        .finish_snapshot(all.keys().copied())
        .unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    (temp, library, server)
}
fn remove_one(library: &Library) {
    write_primary(library, &[envelope(2, "Public unrelated body", 2000)]);
}
fn queue_delete(library: &Library, server: &mut Server) -> Envelope {
    queue_delete_for(library, server, Uuid::from_u128(1))
}
fn queue_delete_for(library: &Library, server: &mut Server, id: Uuid) -> Envelope {
    queue_delete_at(library, server, id, 5000)
}
fn queue_delete_at(library: &Library, server: &mut Server, id: Uuid, wall: u64) -> Envelope {
    let old = load(library)
        .journal
        .confirmed(id)
        .unwrap()
        .envelope
        .clone();
    let deleted = old
        .tombstone(crate::clock::Hlc::foreign(wall), "22222222".into(), true)
        .unwrap();
    server.add(&deleted);
    let mut checkpoint = load(library);
    let requested = checkpoint.journal.inbox.cursor().cloned();
    checkpoint
        .journal
        .inbox
        .receive(
            &feed(3),
            requested.as_ref(),
            vec![Confirmed {
                envelope: deleted.clone(),
                record_version: server.records[&deleted.id].1.clone(),
            }],
            cursor("delete"),
            false,
            false,
        )
        .unwrap();
    checkpoint.save(library, &key(), &SALT).unwrap();
    deleted
}

fn secure_setup() -> (
    tempfile::TempDir,
    Library,
    Server,
    crate::vault::Document,
    Envelope,
) {
    let (temp, library, mut server) = setup();
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let document =
        crate::vault::Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    fs::create_dir(library.root.join("Vault")).unwrap();
    write_vault(&library, &document);
    let mut checkpoint = load(&library);
    let secure = primary::current(&library, &checkpoint.journal, "11111111")
        .unwrap()
        .remove(&document.records[0].metadata.id)
        .unwrap();
    server.add(&secure);
    checkpoint
        .journal
        .projected
        .insert(secure.id, secure.clone());
    checkpoint
        .journal
        .record_confirmed(secure.clone(), server.records[&secure.id].1.clone())
        .unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    (temp, library, server, document, secure)
}
fn write_vault(library: &Library, document: &crate::vault::Document) {
    crate::model::atomic_write(
        &library.root.join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
}

#[test]
fn a_locked_compatible_vault_restores_the_exact_seal_without_replacing_key_material() {
    let (_temp, library, mut server, mut document, original) = secure_setup();
    let before = document.clone();
    document.records.clear();
    write_vault(&library, &document);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    assert!(review.summary().secure && review.summary().can_keep);
    owner
        .decide_deletion_review(&mut server, review, Choice::Delete)
        .unwrap();
    assert!(
        load(&library)
            .journal
            .deletion_approved(&load(&library).journal.entry(original.id).unwrap().desired)
            .unwrap()
    );
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Keep)
        .unwrap();
    owner.send(&mut server, 4).unwrap();
    let mut restored = crate::vault::read_document(&library.root).unwrap().unwrap();
    assert!(restored.records[0].sealed == before.records[0].sealed);
    assert_eq!(restored.records[0].metadata.id, original.id);
    assert!(server.submitted.iter().flatten().all(|(e, _)| !e.deleted));
    let mut key_material = before;
    key_material.records.clear();
    restored.records.clear();
    assert!(restored == key_material);
}

#[test]
fn cloud_delete_review_of_a_locked_vault_changes_only_the_decided_record() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, document, original) = secure_setup();
        queue_delete_for(&library, &mut server, original.id);
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        assert_eq!(
            owner.receive(&mut server, 1).unwrap().status,
            receiver::Status::DeletionReview
        );
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        owner
            .decide_deletion_review(&mut server, review, choice)
            .unwrap();
        assert_eq!(
            owner.receive(&mut server, 1).unwrap().status,
            receiver::Status::Current
        );
        assert_eq!(
            owner.send(&mut server, 4).unwrap().status,
            sender::Status::Settled
        );
        let mut actual = crate::vault::read_document(&library.root).unwrap().unwrap();
        if choice == Choice::Keep {
            assert!(actual.records[0].sealed == document.records[0].sealed);
            assert!(!server.records[&original.id].0.deleted);
        } else {
            assert!(actual.records.is_empty());
            assert!(server.submitted.is_empty());
        }
        let mut expected = document;
        expected.records.clear();
        actual.records.clear();
        assert!(actual == expected);
        assert_eq!(library.read().unwrap().0.len(), 2);
    }
}

#[test]
fn an_explicit_keep_observes_the_reviewed_cloud_delete_clock_even_when_it_is_in_the_future() {
    let (_temp, library, mut server) = setup();
    let remote = queue_delete_at(&library, &mut server, Uuid::from_u128(1), 0xffff_ffff_ff00);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Keep)
        .unwrap();
    let restored = load(&library)
        .journal
        .entry(remote.id)
        .unwrap()
        .desired
        .clone();
    assert!(restored.hlc > remote.hlc);
    assert_eq!(
        owner.receive(&mut server, 1).unwrap().status,
        receiver::Status::Current
    );
    assert_eq!(
        owner.send(&mut server, 4).unwrap().status,
        sender::Status::Settled
    );
    assert!(!server.records[&remote.id].0.deleted);
}

#[test]
fn a_missing_or_foreign_vault_cannot_be_recreated_by_deletion_review() {
    for missing in [false, true] {
        let (_temp, library, mut server, mut document, _) = secure_setup();
        document.records.clear();
        if missing {
            fs::remove_file(library.root.join("Vault/vault.json")).unwrap();
        } else {
            document.kid = "fictional-foreign-vault".into();
            write_vault(&library, &document);
        }
        let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        if missing {
            assert_eq!(
                owner.prepare_deletion_review(&mut server).err(),
                Some(Failure::MissingFile)
            );
        } else {
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(
                owner
                    .decide_deletion_review(&mut server, review, Choice::Keep)
                    .err(),
                Some(Failure::IncompatibleVault)
            );
            assert!(crate::vault::read_document(&library.root).unwrap().unwrap() == document);
        }
        assert_eq!(
            fs::read(library.root.join("Sync/journal.bin")).unwrap(),
            before
        );
        assert!(server.submitted.is_empty());
        assert!(!library.root.join("Sync/primary.pending").exists());
    }
}

#[test]
fn cancelling_a_local_absence_review_does_not_stamp_or_send_a_delete() {
    let (_temp, library, mut server) = setup();
    remove_one(&library);
    let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    let review = owner(&library, &key(), &scope(), &|| Ok(()))
        .prepare_deletion_review(&mut server)
        .unwrap();
    assert_eq!(review.summary().kind, Kind::LocalAbsence);
    assert!(review.summary().can_keep);
    drop(review);
    assert_eq!(
        fs::read(library.root.join("Sync/journal.bin")).unwrap(),
        before
    );
    assert!(server.submitted.is_empty());
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .unwrap()
            .status,
        sender::Status::LocalReview
    );
}

#[test]
fn a_confirmed_local_absence_is_a_durable_exact_hash_tombstone_using_original_cas() {
    let (_temp, library, mut server) = setup();
    remove_one(&library);
    let old = load(&library)
        .journal
        .confirmed(Uuid::from_u128(1))
        .unwrap()
        .clone();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Delete)
        .unwrap();
    let resumed = load(&library);
    let target = resumed
        .journal
        .entry(old.envelope.id)
        .unwrap()
        .desired
        .clone();
    assert!(target.deleted && resumed.journal.deletion_approved(&target).unwrap());
    assert!(target.hlc > old.envelope.hlc);
    assert!(target.extensions.contains_key("userDeletion.v1"));
    assert_eq!(library.read().unwrap().0.len(), 1);
    assert!(server.submitted.is_empty());
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::Settled
    );
    assert_eq!(server.submitted.len(), 1);
    assert!(server.submitted[0][0].0.deleted);
    assert!(server.submitted[0][0].1.as_ref() == Some(&old.record_version));
    assert!(load(&library).journal.deletion_approvals.is_empty());
}

#[test]
fn restoring_a_missing_record_keeps_its_uuid_and_body_and_does_not_send_a_delete() {
    let (_temp, library, mut server) = setup();
    remove_one(&library);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Keep)
        .unwrap();
    let restored = library
        .read()
        .unwrap()
        .0
        .into_iter()
        .find(|s| s.id == Uuid::from_u128(1))
        .unwrap();
    assert_eq!(restored.content, "Public deletion body");
    owner.send(&mut server, 1).unwrap();
    assert!(server.submitted.iter().flatten().all(|(e, _)| !e.deleted));
}

#[test]
fn a_cloud_delete_marker_does_not_grant_local_consent_and_delete_confirmation_is_atomic() {
    let (_temp, library, mut server) = setup();
    let remote = queue_delete(&library, &mut server);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    assert_eq!(
        owner.receive(&mut server, 1).unwrap().status,
        receiver::Status::DeletionReview
    );
    assert_eq!(library.read().unwrap().0.len(), 2);
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    assert_eq!(review.summary().kind, Kind::CloudDeletion);
    owner
        .decide_deletion_review(&mut server, review, Choice::Delete)
        .unwrap();
    assert_eq!(library.read().unwrap().0.len(), 1);
    let checkpoint = load(&library);
    assert!(checkpoint.journal.confirmed(remote.id).unwrap().envelope == remote);
    assert!(checkpoint.journal.inbox.next().is_none());
    assert!(checkpoint.journal.deletion_approvals.is_empty());
    assert_eq!(
        owner.receive(&mut server, 1).unwrap().status,
        receiver::Status::Current
    );
    assert!(server.submitted.is_empty());
}

#[test]
fn keeping_the_local_version_of_a_cloud_deleted_record_posts_with_the_delete_receipt_cas() {
    let (_temp, library, mut server) = setup();
    let remote = queue_delete(&library, &mut server);
    let delete_version = server.records[&remote.id].1.clone();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Keep)
        .unwrap();
    assert_eq!(library.read().unwrap().0.len(), 2);
    assert_eq!(
        owner.receive(&mut server, 1).unwrap().status,
        receiver::Status::Current
    );
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::Settled
    );
    assert!(!server.submitted[0][0].0.deleted);
    assert!(server.submitted[0][0].1.as_ref() == Some(&delete_version));
}

#[test]
fn a_missing_whole_file_or_a_changed_record_cannot_be_confirmed_as_a_deletion() {
    let (_temp, library, mut server) = setup();
    fs::remove_file(library.root.join("snippets.json")).unwrap();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    assert_eq!(
        owner.prepare_deletion_review(&mut server).err(),
        Some(Failure::MissingFile)
    );
    assert!(server.submitted.is_empty());
    remove_one(&library);
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    write_primary(
        &library,
        &[
            envelope(1, "Public newer edit", 7000),
            envelope(2, "Public unrelated body", 2000),
        ],
    );
    let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    assert_eq!(
        owner
            .decide_deletion_review(&mut server, review, Choice::Delete)
            .err(),
        Some(Failure::Changed)
    );
    assert_eq!(
        fs::read(library.root.join("Sync/journal.bin")).unwrap(),
        before
    );
    assert_eq!(library.read().unwrap().0.len(), 2);
}

#[test]
fn a_new_remote_edit_survives_a_previously_confirmed_local_delete() {
    let (_temp, library, mut server) = setup();
    remove_one(&library);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Delete)
        .unwrap();
    server.add(&envelope(1, "Public newer remote body", 8000));
    owner.send(&mut server, 4).unwrap();
    let kept = library
        .read()
        .unwrap()
        .0
        .into_iter()
        .find(|s| s.id == Uuid::from_u128(1))
        .unwrap();
    assert_eq!(kept.content, "Public newer remote body");
    assert!(load(&library).journal.deletion_approvals.is_empty());
    assert!(!server.records[&Uuid::from_u128(1)].0.deleted);
}

#[test]
fn all_five_wal_interruptions_recover_the_exact_decision_and_record_receipt() {
    for phase in 0..5 {
        let (_temp, library, mut server) = setup();
        let remote = queue_delete(&library, &mut server);
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert!(
            owner
                .decide_deletion_inner(&mut server, review, Choice::Delete, Some(phase))
                .is_err()
        );
        let checkpoint = primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
        assert_eq!(
            library.read().unwrap().0.len(),
            if phase == 0 { 2 } else { 1 }
        );
        if phase == 0 {
            assert!(checkpoint.journal.inbox.next().is_some());
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            owner
                .decide_deletion_review(&mut server, review, Choice::Delete)
                .unwrap();
        } else {
            assert!(checkpoint.journal.inbox.next().is_none());
            assert!(checkpoint.journal.confirmed(remote.id).unwrap().envelope == remote);
        }
        assert!(!library.root.join("Sync/primary.pending").exists());
    }
}

#[test]
fn session_scope_and_epoch_changes_leave_the_original_files_and_checkpoint() {
    for changed in 0..3 {
        let (_temp, library, mut server) = setup();
        remove_one(&library);
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
        let review = owner(&library, &key, &scope, &guard)
            .prepare_deletion_review(&mut server)
            .unwrap();
        let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let mut resumed = owner(&library, &key, &scope, &guard);
        match changed {
            0 => valid.set(false),
            1 => server.scope.membership = crate::cloud::Binding::from_checkpoint([0x99; 32]),
            _ => {
                server.feed.key_epoch = 2;
                resumed.key_epoch = 2;
            }
        }
        assert!(
            resumed
                .decide_deletion_review(&mut server, review, Choice::Delete)
                .is_err()
        );
        assert_eq!(
            fs::read(library.root.join("Sync/journal.bin")).unwrap(),
            before
        );
        assert!(!library.root.join("Sync/primary.pending").exists());
    }
}

#[test]
fn a_restored_record_survives_replay_of_an_already_authorized_lost_delete_response() {
    struct LostReply<'a> {
        server: &'a mut Server,
    }
    impl sender::Remote for LostReply<'_> {
        fn preflight(&mut self) -> receiver::RemoteResult<sender::SendObservation> {
            sender::Remote::preflight(self.server)
        }
        fn submit(
            &mut self,
            offers: &[crate::cloud::Offer],
        ) -> receiver::RemoteResult<sender::Reply> {
            sender::Remote::submit(self.server, offers)?;
            Err(crate::cloud::Failure::Network)
        }
    }
    let (_temp, library, mut server) = setup();
    remove_one(&library);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Delete)
        .unwrap();
    assert!(
        owner
            .send(
                &mut LostReply {
                    server: &mut server
                },
                1
            )
            .is_err()
    );
    let old_packet = load(&library).journal.outbound.unwrap();
    assert!(old_packet.offers[0].deletion_authorized);
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Keep)
        .unwrap();
    let restored = load(&library);
    assert!(restored.journal.deletion_approvals.is_empty());
    assert!(restored.journal.outbound.as_ref().unwrap().offers[0] == old_packet.offers[0]);
    assert_eq!(
        owner.send(&mut server, 4).unwrap().status,
        sender::Status::Settled
    );
    assert_eq!(server.submitted.len(), 3);
    assert!(server.submitted[0] == server.submitted[1]);
    assert!(!server.submitted[2][0].0.deleted);
    assert_eq!(library.read().unwrap().0.len(), 2);
    assert!(!server.records[&Uuid::from_u128(1)].0.deleted);
}

#[test]
fn an_unapproved_prepared_legacy_delete_can_be_withdrawn_without_posting_it() {
    use crate::outbound::{Packet, Transmission};
    let (_temp, library, mut server) = setup();
    let mut checkpoint = load(&library);
    let live = checkpoint
        .journal
        .confirmed(Uuid::from_u128(1))
        .unwrap()
        .envelope
        .clone();
    let deleted = live
        .tombstone(crate::clock::Hlc::foreign(5000), "22222222".into(), true)
        .unwrap();
    checkpoint.journal.desire(deleted.clone()).unwrap();
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&deleted))
        .unwrap()
        .remove(0);
    checkpoint.journal.outbound = Some(Packet {
        key_epoch: 1,
        offers: vec![Transmission {
            offered,
            wire: crate::wire::WireRecord::seal(&deleted, &key(), &SALT).unwrap(),
            deletion_authorized: false,
        }],
        receipts: None,
        received_at: None,
        position: 0,
    });
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Keep)
        .unwrap();
    assert!(load(&library).journal.outbound.is_none());
    assert_eq!(
        owner.send(&mut server, 4).unwrap().status,
        sender::Status::Settled
    );
    assert!(server.submitted.iter().flatten().all(|(e, _)| !e.deleted));
}

#[test]
fn a_retained_cas_conflict_delete_can_be_applied_without_another_post() {
    let (_temp, library, mut server) = setup();
    // An explicit missing-snapshot resume retains the old merge ancestor while
    // invalidating old CAS; a deletion racing with reupload needs local review.
    server.records.clear();
    let mut checkpoint = load(&library);
    checkpoint.journal.inbox.restart_snapshot().unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    assert_eq!(
        owner.receive(&mut server, 1).unwrap().status,
        receiver::Status::SnapshotReview
    );
    let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
    owner
        .resume_missing_snapshot_review(&mut server, review)
        .unwrap();
    owner.receive(&mut server, 1).unwrap();
    let original = envelope(1, "Public deletion body", 1000);
    let deleted = original
        .tombstone(crate::clock::Hlc::foreign(5000), "22222222".into(), true)
        .unwrap();
    server.add(&deleted);
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::DeletionReview
    );
    let posted = server.submitted.len();
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    assert_eq!(review.summary().kind, Kind::CloudDeletion);
    owner
        .decide_deletion_review(&mut server, review, Choice::Delete)
        .unwrap();
    assert_eq!(library.read().unwrap().0.len(), 1);
    owner.send(&mut server, 4).unwrap();
    assert_eq!(server.submitted.len(), posted);
}

#[test]
fn missing_original_evidence_and_changed_checkpoints_cannot_be_bypassed_by_confirmation() {
    let (_temp, library, mut server, mut document, losing) = secure_setup();
    let source = envelope(
        losing.id.as_u128(),
        "Public conflict winner",
        0xffff_ffff_ff00,
    );
    let merged = merge::merge(None, Some(&losing), Some(&source)).unwrap();
    assert!(
        !merge::secure_variants(merged.survivor.as_ref().unwrap())
            .unwrap()
            .is_empty()
    );
    let mut checkpoint = load(&library);
    checkpoint
        .journal
        .stage_conflict(merged.survivor.as_ref().unwrap(), &[])
        .unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    document.records.clear();
    write_vault(&library, &document);
    {
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let before = load(&library);
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert_eq!(review.summary().preserved_source_versions, 1);
        assert_eq!(
            owner
                .decide_deletion_review(&mut server, review, Choice::Delete)
                .err(),
            Some(Failure::VaultLocked)
        );
        assert!(load(&library).same_snapshot(&before));
    }
    let (_temp, library, mut server) = setup();
    remove_one(&library);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    load(&library).save(&library, &key, &SALT).unwrap();
    assert_eq!(
        owner
            .decide_deletion_review(&mut server, review, Choice::Delete)
            .err(),
        Some(Failure::Changed)
    );
}

fn pending_conflict(
    source_in_flight: bool,
) -> (tempfile::TempDir, Library, Server, Envelope, Envelope) {
    let (temp, library, mut server) = setup();
    let mut checkpoint = load(&library);
    let current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
    let old = &current[&Uuid::from_u128(1)];
    let winner = envelope(1, "Public reviewed conflict winner", 3000);
    let outcome = merge::merge(None, Some(old), Some(&winner)).unwrap();
    let source = outcome.survivor.clone().unwrap();
    let copy = outcome.conflict_copies[0].clone();
    let expected =
        primary::preservation_read_set(std::slice::from_ref(&outcome), &current).unwrap();
    let prepared = primary::prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome],
        &expected,
    )
    .unwrap();
    primary::commit(&library, &mut checkpoint, &key(), &SALT, prepared).unwrap();
    if source_in_flight {
        assert_eq!(
            owner(&library, &key(), &scope(), &|| Ok(()))
                .send(&mut server, 1)
                .unwrap()
                .status,
            sender::Status::MoreBatches
        );
        checkpoint = load(&library);
    }
    let initial = if source_in_flight { &source } else { &copy };
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(initial))
        .unwrap()
        .remove(0);
    checkpoint.journal.outbound = Some(crate::outbound::Packet {
        key_epoch: 1,
        offers: vec![crate::outbound::Transmission {
            wire: crate::wire::WireRecord::seal(initial, &key(), &SALT).unwrap(),
            offered,
            deletion_authorized: false,
        }],
        receipts: None,
        received_at: None,
        position: 0,
    });
    checkpoint.save(&library, &key(), &SALT).unwrap();
    (temp, library, server, source, copy)
}

fn finish_sends(library: &Library, server: &mut Server) {
    for _ in 0..12 {
        match owner(library, &key(), &scope(), &|| Ok(()))
            .send(server, 1)
            .unwrap()
            .status
        {
            sender::Status::Settled => return,
            sender::Status::MoreBatches => (),
            other => panic!("unexpected recovery status: {other:?}"),
        }
    }
    panic!("reviewed conflict did not finish");
}

#[test]
fn materialized_conflict_absence_decisions_preserve_exact_offers_and_recover_every_wal_phase() {
    for source_in_flight in [false, true] {
        for delete_source in [false, true] {
            for choice in [Choice::Keep, Choice::Delete] {
                for fault in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
                    let (_temp, library, mut server, source, copy) =
                        pending_conflict(source_in_flight);
                    let selected = if delete_source { &source } else { &copy };
                    let mut checkpoint = load(&library);
                    let packet = checkpoint.journal.outbound.clone().unwrap();
                    let before =
                        primary::current(&library, &checkpoint.journal, "11111111").unwrap();
                    let retained: Vec<_> = before
                        .values()
                        .filter(|e| e.id != selected.id)
                        .cloned()
                        .collect();
                    write_primary(&library, &retained);
                    let key = key();
                    let scope = scope();
                    let owner = owner(&library, &key, &scope, &|| Ok(()));
                    let review = owner.prepare_deletion_review(&mut server).unwrap();
                    assert_eq!(review.summary().kind, Kind::LocalAbsence);
                    assert_eq!(review.id, selected.id);
                    let result = owner.decide_deletion_inner(&mut server, review, choice, fault);
                    if fault.is_some() {
                        assert!(result.is_err());
                        primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
                        if fault == Some(0) {
                            let review = owner.prepare_deletion_review(&mut server).unwrap();
                            owner
                                .decide_deletion_review(&mut server, review, choice)
                                .unwrap();
                        }
                    } else {
                        result.unwrap();
                    }
                    checkpoint = load(&library);
                    assert!(checkpoint.journal.outbound.as_ref() == Some(&packet));
                    assert!(checkpoint.journal.retains_offer(&packet.offers[0].offered));
                    let start = server.submitted.len();
                    for step in 0..12 {
                        let status = owner.send(&mut server, 1).unwrap().status;
                        if status == sender::Status::Settled {
                            break;
                        }
                        let state = load(&library);
                        assert_eq!(
                            status,
                            sender::Status::MoreBatches,
                            "source_in_flight={source_in_flight}, delete_source={delete_source}, choice={choice:?}, fault={fault:?}, step={step}, pending={}, frames={}, source_deleted={}, copy_confirmed={}",
                            state.journal.pending().unwrap().len(),
                            state.journal.restoration_generations().unwrap().len(),
                            state.journal.confirmed(source.id).unwrap().envelope.deleted,
                            state.journal.confirmed(copy.id).is_some()
                        );
                    }
                    let sent: Vec<_> = server.submitted[start..].iter().flatten().collect();
                    assert!(sent[0].0 == packet.offers[0].offered.envelope);
                    assert!(sent[0].1 == packet.offers[0].offered.record_version);
                    let actual =
                        primary::current(&library, &load(&library).journal, "11111111").unwrap();
                    for (id, old) in &before {
                        if *id != selected.id {
                            assert!(actual.get(id) == Some(old));
                        }
                    }
                    assert_eq!(actual.contains_key(&selected.id), choice == Choice::Keep);
                    assert_eq!(
                        server.records[&selected.id].0.deleted,
                        choice == Choice::Delete
                    );
                    if choice == Choice::Delete && delete_source && !source_in_flight {
                        assert!(
                            sent.iter()
                                .filter(|(e, _)| e.id == source.id)
                                .all(|(e, _)| e.deleted)
                        );
                    }
                    assert!(!load(&library).journal.has_preservation_work());
                }
            }
        }
    }
}

#[test]
fn reviewed_conflict_absence_keeps_a_lost_original_ack_ambiguous_until_actual_replay() {
    for source_in_flight in [false, true] {
        let (_temp, library, mut server, source, copy) = pending_conflict(source_in_flight);
        let before = load(&library);
        let packet = before.journal.outbound.clone().unwrap();
        server.add(&packet.offers[0].offered.envelope);
        let current = primary::current(&library, &before.journal, "11111111").unwrap();
        write_primary(
            &library,
            &current
                .values()
                .filter(|e| e.id != copy.id)
                .cloned()
                .collect::<Vec<_>>(),
        );
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        owner
            .decide_deletion_review(&mut server, review, Choice::Delete)
            .unwrap();
        let saved = load(&library);
        assert!(saved.journal.outbound.as_ref() == Some(&packet));
        // Native confirmation adds exactly one permission; all server facts,
        // original dependency evidence and ambiguous packets stay unchanged.
        let mut with_permission = before.journal.clone();
        assert_eq!(saved.journal.deletion_approvals.len(), 1);
        with_permission.deletion_approvals = saved.journal.deletion_approvals.clone();
        assert!(with_permission.preserves_transport_state(&saved.journal));
        finish_sends(&library, &mut server);
        assert!(server.records[&copy.id].0.deleted);
        assert!(!server.records[&source.id].0.deleted);
        assert!(!load(&library).journal.has_preservation_work());
    }
}

#[test]
fn keeping_a_queued_conflict_deletion_cancels_only_unsent_tombstones_before_every_wal_phase() {
    for source_in_flight in [false, true] {
        for delete_source in [false, true] {
            for fault in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
                let (_temp, library, mut server, source, copy) = pending_conflict(source_in_flight);
                let selected = if delete_source { &source } else { &copy };
                let before = load(&library);
                let packet = before.journal.outbound.clone().unwrap();
                let current = primary::current(&library, &before.journal, "11111111").unwrap();
                write_primary(
                    &library,
                    &current
                        .values()
                        .filter(|e| e.id != selected.id)
                        .cloned()
                        .collect::<Vec<_>>(),
                );
                let key = key();
                let scope = scope();
                let owner = owner(&library, &key, &scope, &|| Ok(()));
                let review = owner.prepare_deletion_review(&mut server).unwrap();
                owner
                    .decide_deletion_review(&mut server, review, Choice::Delete)
                    .unwrap();
                let review = owner.prepare_deletion_review(&mut server).unwrap();
                assert_eq!(review.id, selected.id);
                assert_eq!(review.summary().kind, Kind::PendingDeletion);
                let result = owner.decide_deletion_inner(&mut server, review, Choice::Keep, fault);
                if fault.is_some() {
                    assert!(result.is_err());
                    primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
                    if fault == Some(0) {
                        let review = owner.prepare_deletion_review(&mut server).unwrap();
                        owner
                            .decide_deletion_review(&mut server, review, Choice::Keep)
                            .unwrap();
                    }
                } else {
                    result.unwrap();
                }
                assert!(load(&library).journal.outbound.as_ref() == Some(&packet));
                let start = server.submitted.len();
                finish_sends(&library, &mut server);
                assert!(
                    server.submitted[start..]
                        .iter()
                        .flatten()
                        .all(|(e, _)| !e.deleted)
                );
                assert!(!server.records[&selected.id].0.deleted);
                assert!(
                    primary::current(&library, &load(&library).journal, "11111111")
                        .unwrap()
                        .contains_key(&selected.id)
                );
                assert!(!load(&library).journal.has_preservation_work());
            }
        }
    }
}

#[test]
fn keeping_an_ambiguous_conflict_deletion_retains_consent_bytes_cas_and_the_real_source_ack() {
    for delete_source in [false, true] {
        let (_temp, library, mut server, source, copy) = pending_conflict(false);
        let selected = if delete_source { &source } else { &copy };
        let before = load(&library);
        let current = primary::current(&library, &before.journal, "11111111").unwrap();
        write_primary(
            &library,
            &current
                .values()
                .filter(|e| e.id != selected.id)
                .cloned()
                .collect::<Vec<_>>(),
        );
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        owner
            .decide_deletion_review(&mut server, review, Choice::Delete)
            .unwrap();
        for _ in 0..4 {
            if load(&library)
                .journal
                .pending()
                .unwrap()
                .iter()
                .any(|e| e.id == selected.id && e.deleted)
            {
                break;
            }
            assert_eq!(
                owner.send(&mut server, 1).unwrap().status,
                sender::Status::MoreBatches
            );
        }
        let mut checkpoint = load(&library);
        let deleted = checkpoint
            .journal
            .pending()
            .unwrap()
            .into_iter()
            .find(|e| e.id == selected.id && e.deleted)
            .unwrap();
        assert!(checkpoint.journal.deletion_approved(&deleted).unwrap());
        let offered = checkpoint
            .journal
            .mark_offered(std::slice::from_ref(&deleted))
            .unwrap()
            .remove(0);
        let packet = crate::outbound::Packet {
            key_epoch: 1,
            offers: vec![crate::outbound::Transmission {
                wire: crate::wire::WireRecord::seal(&deleted, &key, &SALT).unwrap(),
                offered,
                deletion_authorized: true,
            }],
            receipts: None,
            received_at: None,
            position: 0,
        };
        checkpoint.journal.outbound = Some(packet.clone());
        checkpoint.save(&library, &key, &SALT).unwrap();
        server.add(&deleted); // Real server acceptance, with the reply lost locally.
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        owner
            .decide_deletion_review(&mut server, review, Choice::Keep)
            .unwrap();
        assert!(load(&library).journal.outbound.as_ref() == Some(&packet));
        let start = server.submitted.len();
        let restored = primary::current(&library, &load(&library).journal, "11111111").unwrap()
            [&selected.id]
            .clone();
        for _ in 0..12 {
            let status = owner.send(&mut server, 1).unwrap().status;
            assert!(
                primary::current(&library, &load(&library).journal, "11111111")
                    .unwrap()
                    .get(&selected.id)
                    == Some(&restored)
            );
            if status == sender::Status::Settled {
                break;
            }
            assert_eq!(
                status,
                sender::Status::MoreBatches,
                "delete_source={delete_source}"
            );
        }
        let sent: Vec<_> = server.submitted[start..].iter().flatten().collect();
        assert!(sent[0].0 == deleted);
        assert!(sent[0].1 == packet.offers[0].offered.record_version);
        if delete_source {
            assert!(sent[1].0 == deleted);
            assert!(sent[1].1 != sent[0].1);
        }
        assert!(!server.records[&selected.id].0.deleted);
        assert!(!load(&library).journal.has_preservation_work());
    }
}

struct SecureConflict {
    _temp: tempfile::TempDir,
    library: Library,
    server: Server,
    source: Envelope,
    original: Envelope,
    retained: crate::vault::Document,
}
fn unlock_vault(library: &Library) -> crate::vault::Vault {
    let mut vault = crate::vault::Vault::open(library).unwrap();
    let authentication = vault
        .document
        .as_ref()
        .unwrap()
        .authenticate("Café public fixture", false)
        .unwrap();
    vault
        .finish_authentication(authentication, vault.generation())
        .unwrap();
    vault
}
fn secure_conflict() -> SecureConflict {
    let (temp, library, server, _document, secure) = secure_setup();
    let mut checkpoint = load(&library);
    let current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
    let winner = envelope(
        secure.id.as_u128(),
        "Public winner beside protected copy",
        0xffff_ffff_ff00,
    );
    let outcome = merge::merge(None, Some(&secure), Some(&winner)).unwrap();
    let source = outcome.survivor.clone().unwrap();
    assert!(!merge::secure_variants(&source).unwrap().is_empty());
    let expected =
        primary::preservation_read_set(std::slice::from_ref(&outcome), &current).unwrap();
    let mut vault = unlock_vault(&library);
    let prepared = vault
        .prepare_sync_apply(
            &library,
            &checkpoint.journal,
            "11111111",
            &[outcome],
            &expected,
        )
        .unwrap();
    primary::commit(&library, &mut checkpoint, &key(), &SALT, prepared).unwrap();
    let original = checkpoint
        .journal
        .conflict_snapshots()
        .into_values()
        .find(|e| e.secure)
        .unwrap();
    vault.reload().unwrap();
    let old = vault
        .document
        .as_ref()
        .unwrap()
        .records
        .iter()
        .find(|r| r.metadata.id == original.id)
        .unwrap()
        .clone();
    vault
        .save(
            &library,
            old.metadata.clone(),
            b"Public changed protected conflict copy",
            Some(&old),
        )
        .unwrap();
    let current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
    assert!(
        current[&original.id].fields.as_ref().unwrap().content
            != original.fields.as_ref().unwrap().content
    );
    for e in current.values() {
        checkpoint.journal.desire(e.clone()).unwrap();
    }
    checkpoint.journal.projected = current;
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&original))
        .unwrap()
        .remove(0);
    checkpoint.journal.outbound = Some(crate::outbound::Packet {
        key_epoch: 1,
        offers: vec![crate::outbound::Transmission {
            wire: crate::wire::WireRecord::seal(&original, &key(), &SALT).unwrap(),
            offered,
            deletion_authorized: false,
        }],
        receipts: None,
        received_at: None,
        position: 0,
    });
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let retained = crate::vault::read_document(&library.root).unwrap().unwrap();
    let mut absent = retained.clone();
    absent.records.retain(|r| r.metadata.id != original.id);
    write_vault(&library, &absent);
    SecureConflict {
        _temp: temp,
        library,
        server,
        source,
        original,
        retained,
    }
}

#[test]
fn secure_conflict_copy_restore_authenticates_the_latest_seal_and_keeps_original_nonce_offers_and_wal()
 {
    for choice in [Choice::Keep, Choice::Delete] {
        for fault in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
            let SecureConflict {
                _temp,
                library,
                mut server,
                source,
                original,
                retained,
            } = secure_conflict();
            let before = load(&library);
            let packet = before.journal.outbound.clone().unwrap();
            let plain_before = fs::read(library.path()).unwrap();
            let vault_before = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let checkpoint_before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, original.id);
            assert!(
                review.summary().secure
                    && review.summary().keep_requires_vault
                    && review.summary().can_keep
            );
            if choice == Choice::Keep {
                assert_eq!(
                    owner
                        .decide_deletion_review(&mut server, review, choice)
                        .err(),
                    Some(Failure::VaultLocked)
                );
                assert!(fs::read(library.path()).unwrap() == plain_before);
                assert!(fs::read(library.root.join("Vault/vault.json")).unwrap() == vault_before);
                assert!(
                    fs::read(library.root.join("Sync/journal.bin")).unwrap() == checkpoint_before
                );
            }
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            let mut vault = unlock_vault(&library);
            let result = owner.decide_deletion_authenticated(
                &mut server,
                review,
                choice,
                if choice == Choice::Keep {
                    Some(&mut vault)
                } else {
                    None
                },
                fault,
            );
            drop(vault); // Encrypted redo owns the plan; no live key is retained.
            if fault.is_some() {
                assert!(result.is_err());
                primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
                if fault == Some(0) {
                    let review = owner.prepare_deletion_review(&mut server).unwrap();
                    let mut vault = unlock_vault(&library);
                    owner
                        .decide_deletion_review_with_vault(
                            &mut server,
                            review,
                            choice,
                            if choice == Choice::Keep {
                                Some(&mut vault)
                            } else {
                                None
                            },
                        )
                        .unwrap();
                }
            } else {
                result.unwrap();
            }
            assert!(load(&library).journal.outbound.as_ref() == Some(&packet));
            assert!(load(&library).journal.conflict_snapshots()[&original.id] == original);
            finish_sends(&library, &mut server);
            let mut actual = crate::vault::read_document(&library.root).unwrap().unwrap();
            if choice == Choice::Keep {
                assert!(actual.records[0].sealed == retained.records[0].sealed);
                assert!(actual.records[0].metadata.id == original.id);
                assert!(!server.records[&original.id].0.deleted);
            } else {
                assert!(actual.records.is_empty());
                assert!(server.records[&original.id].0.deleted);
            }
            actual.records.clear();
            let mut header = retained;
            header.records.clear();
            assert!(actual == header);
            assert!(!server.records[&source.id].0.deleted);
            assert!(!load(&library).journal.has_preservation_work());
            assert!(server.submitted.iter().flatten().next().unwrap().0 == original);
        }
    }
}

#[test]
fn a_valid_later_secure_copy_cannot_bypass_damaged_cipher_hash_or_vault_identity_in_its_original() {
    for damage in 0..3 {
        let SecureConflict {
            _temp,
            library,
            mut server,
            source,
            original,
            ..
        } = secure_conflict();
        let mut bad = original.clone();
        match damage {
            0 => {
                let fields = bad.fields.as_mut().unwrap();
                let parts: Vec<_> = std::str::from_utf8(&fields.content)
                    .unwrap()
                    .split('.')
                    .collect();
                let mut cipher = crate::crypto::unb64(parts[2]).unwrap();
                cipher[0] ^= 1;
                fields.content = zeroize::Zeroizing::new(
                    format!("{}.{}.{}", parts[0], parts[1], crate::crypto::b64(&cipher))
                        .into_bytes(),
                );
            }
            1 => {
                bad.extensions.insert(
                    "vaultContentHash".into(),
                    crate::canonical::Value::text("00".repeat(16)),
                );
            }
            _ => {
                bad.extensions.insert(
                    "vaultKID".into(),
                    crate::canonical::Value::text("public-foreign-vault"),
                );
            }
        }
        let mut checkpoint = load(&library);
        let mut journal = Journal::new(scope());
        journal.key_epoch = Some(1);
        journal.projected = checkpoint.journal.projected().clone();
        journal.inbox = checkpoint.journal.inbox.clone();
        journal.stage_conflict(&source, &[]).unwrap();
        // Simulate malformed saved evidence at the lowest fixture boundary.
        // The native owner must authenticate it despite the valid later C1.
        journal.freeze_authenticated_copy(&bad).unwrap();
        for e in checkpoint.journal.agreed_envelopes().values() {
            journal
                .record_confirmed(
                    e.clone(),
                    checkpoint
                        .journal
                        .confirmed(e.id)
                        .unwrap()
                        .record_version
                        .clone(),
                )
                .unwrap();
        }
        for e in checkpoint.journal.projected().values() {
            journal.desire(e.clone()).unwrap();
        }
        let offered = journal
            .mark_offered(std::slice::from_ref(&bad))
            .unwrap()
            .remove(0);
        journal.outbound = Some(crate::outbound::Packet {
            key_epoch: 1,
            offers: vec![crate::outbound::Transmission {
                wire: crate::wire::WireRecord::seal(&bad, &key(), &SALT).unwrap(),
                offered,
                deletion_authorized: false,
            }],
            receipts: None,
            received_at: None,
            position: 0,
        });
        checkpoint.journal = journal;
        checkpoint.save(&library, &key(), &SALT).unwrap();
        let before_plain = fs::read(library.path()).unwrap();
        let before_vault = fs::read(library.root.join("Vault/vault.json")).unwrap();
        let before_checkpoint = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert_eq!(review.id, original.id);
        let mut vault = unlock_vault(&library);
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
        assert!(fs::read(library.path()).unwrap() == before_plain);
        assert!(fs::read(library.root.join("Vault/vault.json")).unwrap() == before_vault);
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == before_checkpoint);
        assert!(!library.root.join("Sync/primary.pending").exists());
        assert!(server.submitted.is_empty());
    }
}

#[test]
fn restoring_a_queued_secure_copy_deletion_keeps_the_latest_nonce_and_cancels_only_unsent_deletion()
{
    for lost_copy_ack in [false, true] {
        let SecureConflict {
            _temp,
            library,
            mut server,
            original,
            retained,
            ..
        } = secure_conflict();
        let packet = load(&library).journal.outbound.clone().unwrap();
        if lost_copy_ack {
            server.add(&original);
        }
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        owner
            .decide_deletion_review(&mut server, review, Choice::Delete)
            .unwrap();
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert_eq!(review.summary().kind, Kind::PendingDeletion);
        assert!(review.summary().keep_requires_vault);
        let mut vault = unlock_vault(&library);
        owner
            .decide_deletion_review_with_vault(&mut server, review, Choice::Keep, Some(&mut vault))
            .unwrap();
        drop(vault);
        assert!(load(&library).journal.outbound.as_ref() == Some(&packet));
        finish_sends(&library, &mut server);
        assert!(server.submitted.iter().flatten().all(|(e, _)| !e.deleted));
        let actual = crate::vault::read_document(&library.root).unwrap().unwrap();
        assert!(actual.records[0].sealed == retained.records[0].sealed);
        assert!(actual.records[0].metadata.id == original.id);
        assert!(!load(&library).journal.has_preservation_work());
    }
}
