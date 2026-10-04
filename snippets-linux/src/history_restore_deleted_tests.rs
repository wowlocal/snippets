//! Deleted/missing archive roles through actual protected receipts and redo.
use super::*;
use crate::{
    clock::Hlc,
    journal::{Journal, RestorationGeneration},
    merge,
    wire::Envelope,
};
use std::collections::BTreeMap;

fn old_checkpoint(s: &Setup, library: &Library) -> (Checkpoint, RootKey, [u8; 32]) {
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let installed = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
    let checkpoint =
        Checkpoint::load(library, &key, &salt, installed.binding.checkpoint_scope()).unwrap();
    (checkpoint, key, salt)
}
fn independent_current(s: &mut Setup, records: &[Envelope]) {
    let library = Library::open(s.temp.path().into()).unwrap();
    let mut checkpoint = read_journal(s);
    let epoch = checkpoint.journal.key_epoch;
    checkpoint.journal = Journal::new(checkpoint.journal.scope().clone());
    checkpoint.journal.key_epoch = epoch;
    checkpoint.journal.projected = records.iter().map(|e| (e.id, e.clone())).collect();
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    checkpoint
        .save(&library, &key, &material[32..].try_into().unwrap())
        .unwrap();
}
fn settle(s: &mut Setup) -> crate::snapshot_review::tests::Server {
    let mut server = crate::snapshot_review::tests::Server::new();
    server.scope = s.remote.pin.checkpoint_scope();
    server.feed = crate::inbound::Feed::new(Uuid::from_u128(9), 2).unwrap();
    let mut status = send_fixture(s, &mut server, true).status;
    for _ in 0..8 {
        if status != crate::sender::Status::MoreBatches {
            break;
        }
        status = send_fixture(s, &mut server, false).status;
    }
    assert_eq!(status, crate::sender::Status::Settled);
    assert!(!read_journal(s).journal.has_preservation_work());
    server
}
#[test]
fn deleted_ordinary_copy_restores_through_restart_and_new_cas_without_old_deletions() {
    for deleted_source in [false, true] {
        let mut s = setup();
        let library = Library::open(s.temp.path().into()).unwrap();
        let (mut checkpoint, key, salt) = old_checkpoint(&s, &library);
        let outcome = merge::merge(
            None,
            Some(&envelope(1, "Public archived loser", 1)),
            Some(&envelope(1, "Public archived parent", 2)),
        )
        .unwrap();
        let source = outcome.survivor.unwrap();
        let original = outcome.conflict_copies[0].clone();
        let deleted = if deleted_source { &source } else { &original }
            .tombstone(Hlc::foreign(30), "22222222".into(), true)
            .unwrap();
        checkpoint.journal = Journal::new(checkpoint.journal.scope().clone());
        checkpoint.journal.key_epoch = Some(1);
        checkpoint
            .journal
            .stage_conflict(
                if deleted_source { &deleted } else { &source },
                std::slice::from_ref(&original),
            )
            .unwrap();
        checkpoint.journal.desire(deleted.clone()).unwrap();
        if deleted_source {
            checkpoint
                .journal
                .review_absence(source.id, Some(source.clone()))
                .unwrap();
            checkpoint
                .journal
                .desire(
                    original
                        .tombstone(Hlc::foreign(31), "22222222".into(), true)
                        .unwrap(),
                )
                .unwrap();
        }
        checkpoint
            .journal
            .review_absence(original.id, Some(original.clone()))
            .unwrap();
        let records = if deleted_source {
            vec![]
        } else {
            vec![source.clone()]
        };
        write_primary(&library, &records);
        checkpoint.journal.projected = records.iter().map(|e| (e.id, e.clone())).collect();
        if deleted_source {
            // Ordered historical frames may contain the tombstone, but cannot
            // transmit its old permission or manufacture missing parent fields.
            checkpoint
                .journal
                .stage_restoration_generation(
                    [0x73; 16],
                    &RestorationGeneration {
                        targets: BTreeMap::from([
                            (deleted.id, deleted.clone()),
                            (original.id, original.clone()),
                        ]),
                        sources: vec![(deleted.clone(), vec![original.clone()])],
                    },
                    &BTreeMap::from([(deleted.id, deleted)]),
                )
                .unwrap();
        }
        checkpoint.save(&library, &key, &salt).unwrap();
        let reviewed = prepare(&mut s).unwrap();
        commit(&mut s, reviewed).unwrap();
        let parent = envelope(1, "Public current retained parent", 40);
        let extra = envelope(3, "Public unrelated current record", 41);
        write_primary(&library, &[parent.clone(), extra.clone()]);
        independent_current(&mut s, &[parent.clone(), extra.clone()]);
        let before = read_journal(&mut s).journal;
        let keys = capabilities(&s);
        let reviewed = review(&mut s);
        assert_eq!(
            reviewed.summary().restored_records,
            if deleted_source { 1 } else { 2 }
        );
        assert!(confirm(&mut s, reviewed, Some(2)).is_err());
        s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
        resume_restore(&mut s).unwrap();
        let after = read_journal(&mut s).journal;
        assert!(before.preserves_transport_state(&after) && capabilities(&s) == keys);
        assert!(after.deletion_approvals.is_empty());
        let actual = primary::current(&library, &after, "11111111").unwrap();
        assert!(
            actual[&original.id].fields.as_ref().unwrap().content
                == original.fields.as_ref().unwrap().content
        );
        assert!(actual[&extra.id] == extra);
        if deleted_source {
            assert!(actual[&parent.id] == parent);
        }
        let server = settle(&mut s);
        assert!(server.submitted.iter().flatten().all(|(e, _)| !e.deleted));
        if deleted_source {
            assert!(
                server
                    .submitted
                    .iter()
                    .flatten()
                    .filter(|(e, _)| e.id == parent.id)
                    .all(|(e, _)| e.fields.as_ref().unwrap().content
                        == parent.fields.as_ref().unwrap().content)
            );
        }
    }
}

fn missing_secure_setup(
    tombstone: bool,
    corrupt: bool,
    staged: bool,
    queued: bool,
) -> (Setup, crate::vault::Document, Envelope, Uuid) {
    let mut s = setup();
    let library = Library::open(s.temp.path().into()).unwrap();
    let mut doc = document();
    std::fs::create_dir(s.temp.path().join("Vault")).unwrap();
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &doc.encode().unwrap(),
    )
    .unwrap();
    let (mut checkpoint, key, salt) = old_checkpoint(&s, &library);
    let (outcomes, _, original, _, _) =
        crate::primary::tests::nested_secure_outcomes(&library, &checkpoint.journal, &doc);
    let mut source = outcomes[0].survivor.as_ref().unwrap().clone();
    if corrupt {
        let variant = merge::secure_variants(&source).unwrap().remove(0);
        let crate::canonical::Value::Object(carrier) =
            source.extensions.get_mut(&variant.extension_key).unwrap()
        else {
            panic!("Expected fixture carrier")
        };
        let crate::canonical::Value::Object(extensions) = carrier.get_mut("x").unwrap() else {
            panic!("Expected fixture fields")
        };
        extensions.insert(
            "vaultContentHash".into(),
            crate::canonical::Value::text("00000000000000000000000000000000"),
        );
        let mut snapshot = carrier.clone();
        snapshot.remove("copyID");
        let fingerprint =
            crate::wire::sha256(&crate::canonical::Value::Object(snapshot).encode().unwrap());
        carrier.insert(
            "copyID".into(),
            crate::canonical::Value::text(merge::copy_id(source.id, &fingerprint).to_string()),
        );
        let value = source.extensions.remove(&variant.extension_key).unwrap();
        source
            .extensions
            .insert(format!("{}{fingerprint}", merge::CONFLICT_V1_PREFIX), value);
    }
    // Keep the authenticated vault header, with no saved/materialized C0 file.
    doc.records.clear();
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &doc.encode().unwrap(),
    )
    .unwrap();
    write_primary(&library, std::slice::from_ref(&source));
    checkpoint.journal = Journal::new(checkpoint.journal.scope().clone());
    checkpoint.journal.key_epoch = Some(1);
    checkpoint.journal.projected = BTreeMap::from([(source.id, source.clone())]);
    if staged {
        checkpoint.journal.stage_conflict(&source, &[]).unwrap();
    }
    if queued {
        let mut next = source.clone();
        next.hlc = Hlc::foreign(0xffff_0000_0010);
        next.fields.as_mut().unwrap().name = "Public queued source title".into();
        checkpoint
            .journal
            .stage_restoration_generation(
                [0x74; 16],
                &RestorationGeneration {
                    targets: BTreeMap::from([
                        (next.id, next.clone()),
                        (
                            original.id,
                            original
                                .tombstone(Hlc::foreign(0xffff_0000_0005), "22222222".into(), true)
                                .unwrap(),
                        ),
                    ]),
                    sources: vec![(next.clone(), Vec::new())],
                },
                &checkpoint.journal.projected.clone(),
            )
            .unwrap();
        source = next;
        write_primary(&library, std::slice::from_ref(&source));
        checkpoint.journal.projected = BTreeMap::from([(source.id, source.clone())]);
    }
    checkpoint.journal.desire(source.clone()).unwrap();
    if tombstone {
        checkpoint
            .journal
            .desire(
                original
                    .tombstone(Hlc::foreign(0xffff_0000_0005), "22222222".into(), true)
                    .unwrap(),
            )
            .unwrap();
    }
    assert!(checkpoint.journal.conflict_snapshots().is_empty());
    checkpoint.save(&library, &key, &salt).unwrap();
    let reviewed = prepare(&mut s).unwrap();
    commit(&mut s, reviewed).unwrap();
    independent_current(&mut s, std::slice::from_ref(&source));
    (s, doc, source, original.id)
}

#[test]
fn missing_or_deleted_secure_original_is_authenticated_once_and_frozen_before_restart() {
    for (tombstone, staged, queued) in [
        (false, false, false),
        (true, false, false),
        (false, true, false),
        (true, true, false),
        (true, true, true),
    ] {
        let (mut s, doc, source, id) = missing_secure_setup(tombstone, false, staged, queued);
        let selection = history::inspect(&mut s.store).unwrap().switches[0]
            .selection
            .clone();
        assert!(matches!(
            restore::prepare(&mut s.store, selection.clone(), None),
            Err(restore::Failure::Primary(primary::Failure::VaultLocked))
        ));
        let before = read_journal(&mut s).journal;
        let mut vault = unlock(&s, &doc);
        let reviewed = restore::prepare(&mut s.store, selection, Some(&mut vault)).unwrap();
        assert_eq!(reviewed.summary().restored_records, 2);
        assert_eq!(reviewed.summary().added_records, 1);
        assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
        assert!(confirm(&mut s, reviewed, Some(2)).is_err());
        drop(vault);
        s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
        resume_restore(&mut s).unwrap();
        let after = read_journal(&mut s).journal;
        assert!(before.preserves_transport_state(&after) && after.deletion_approvals.is_empty());
        let original = after.conflict_snapshots()[&id].clone();
        let live = crate::vault::read_document(s.temp.path()).unwrap().unwrap();
        let frozen_target = live
            .records
            .iter()
            .find(|r| r.metadata.id == id)
            .unwrap()
            .sealed
            .text()
            .as_bytes()
            .to_vec();
        let mut vault = unlock(&s, &live);
        let variant = merge::secure_variants(&source).unwrap().remove(0);
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let body = crate::crypto::open_record(
            &crate::crypto::Sealed::parse(
                std::str::from_utf8(&variant.fields.content).unwrap().into(),
            )
            .unwrap(),
            &root,
            &doc.salt().unwrap(),
            &doc.kid,
            source.id,
            false,
        )
        .unwrap();
        assert!(vault.body(id).unwrap() == body);
        vault.lock();
        let server = settle(&mut s);
        let batches = &server.submitted;
        let c0 = batches
            .iter()
            .position(|b| b.iter().any(|(e, _)| e == &original))
            .unwrap();
        let parent = batches
            .iter()
            .position(|b| b.iter().any(|(e, _)| e.id == source.id))
            .unwrap();
        let final_copy = batches
            .iter()
            .rposition(|b| b.iter().any(|(e, _)| e.id == id))
            .unwrap();
        assert!(c0 < parent && parent < final_copy);
        assert!(batches.iter().flatten().all(|(e, _)| !e.deleted));
        let nonces: std::collections::BTreeSet<_> = batches
            .iter()
            .flatten()
            .filter(|(e, _)| e.id == id)
            .map(|(e, _)| e.fields.as_ref().unwrap().content.to_vec())
            .collect();
        assert_eq!(nonces.len(), if queued { 2 } else { 1 });
        let after = crate::vault::read_document(s.temp.path()).unwrap().unwrap();
        assert!(
            after
                .records
                .iter()
                .find(|r| r.metadata.id == id)
                .unwrap()
                .sealed
                .text()
                .as_bytes()
                == frozen_target.as_slice()
        );
    }
}

#[test]
fn damaged_missing_original_carrier_refuses_before_any_primary_write_or_receipt() {
    let (mut s, doc, _, _) = missing_secure_setup(false, true, true, false);
    let plain = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
    let sealed = std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap();
    let before = read_journal(&mut s).journal;
    let keys = capabilities(&s);
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    let mut vault = unlock(&s, &doc);
    assert!(restore::prepare(&mut s.store, selection, Some(&mut vault)).is_err());
    assert!(plain == std::fs::read(s.temp.path().join("snippets.json")).unwrap());
    assert!(sealed == std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap());
    assert!(read_journal(&mut s).journal == before && capabilities(&s) == keys);
    assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
}

#[test]
fn restoration_keeps_a_current_ambiguous_deletion_packet_ahead_of_the_new_live_copy() {
    let (mut s, doc, source, id) = missing_secure_setup(false, false, true, false);
    let library = Library::open(s.temp.path().into()).unwrap();
    let mut server = crate::snapshot_review::tests::Server::new();
    server.scope = s.remote.pin.checkpoint_scope();
    let feed = crate::inbound::Feed::new(Uuid::from_u128(9), 2).unwrap();
    server.feed = feed.clone();
    with_fixture(&s, &mut server, |owner, server| {
        assert_eq!(
            owner.receive(server, 2).unwrap().status,
            crate::receiver::Status::Current
        );
    });
    let mut current = read_journal(&mut s);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let proof = crate::materializer::Evidence::prepare(
        std::slice::from_ref(&source),
        &crate::materializer::Keyring::new(&root, &doc).unwrap(),
        &BTreeMap::new(),
    )
    .unwrap();
    let original = &proof.copies()[&id];
    let deleted = original
        .tombstone(Hlc::foreign(0xffff_0000_0020), "22222222".into(), true)
        .unwrap();
    let version = crate::snapshot_review::tests::version("public-before-current-deletion");
    current
        .journal
        .record_confirmed(original.clone(), version)
        .unwrap();
    current.journal.desire(deleted.clone()).unwrap();
    current
        .journal
        .review_absence(id, Some(original.clone()))
        .unwrap();
    current.journal.projected.insert(id, deleted.clone());
    current
        .journal
        .approve_deletion(&deleted, Some(original.clone()))
        .unwrap();
    current.journal.inbox.select_feed(feed.clone()).unwrap();
    let offered = current
        .journal
        .mark_offered(std::slice::from_ref(&deleted))
        .unwrap()
        .remove(0);
    let wire = crate::wire::WireRecord::seal(
        &deleted,
        &crate::snapshot_review::tests::key(),
        &crate::snapshot_review::tests::SALT,
    )
    .unwrap();
    current.journal.outbound = Some(crate::outbound::Packet {
        key_epoch: 2,
        offers: vec![crate::outbound::Transmission {
            offered,
            wire: wire.clone(),
            deletion_authorized: true,
        }],
        receipts: None,
        received_at: None,
        position: 0,
    });
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    current
        .save(&library, &key, &material[32..].try_into().unwrap())
        .unwrap();
    let before = current.journal.clone();
    let mut vault = unlock(&s, &doc);
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    let reviewed = restore::prepare(&mut s.store, selection, Some(&mut vault)).unwrap();
    confirm(&mut s, reviewed, None).unwrap();
    vault.lock();
    let after = read_journal(&mut s).journal;
    assert!(before.preserves_transport_state(&after));
    assert!(
        after.outbound == before.outbound
            && after.entry(id).unwrap().offered == before.entry(id).unwrap().offered
    );
    // The server already accepted this exact packet before its reply was lost.
    server.records.insert(
        id,
        (
            wire,
            crate::snapshot_review::tests::version("public-lost-current-deletion-ack"),
        ),
    );
    let mut status = crate::sender::Status::MoreBatches;
    for _ in 0..8 {
        status = send_fixture(&s, &mut server, false).status;
        if status != crate::sender::Status::MoreBatches {
            break;
        }
    }
    assert_eq!(status, crate::sender::Status::Settled);
    assert!(server.submitted[0][0].0 == deleted);
    assert_eq!(
        server
            .submitted
            .iter()
            .flatten()
            .filter(|(e, _)| e.deleted)
            .count(),
        1
    );
    assert!(
        server
            .submitted
            .last()
            .unwrap()
            .iter()
            .any(|(e, cas)| e.id == id && !e.deleted && cas.is_some())
    );
    assert!(
        crate::vault::read_document(s.temp.path())
            .unwrap()
            .unwrap()
            .records
            .iter()
            .any(|r| r.metadata.id == id)
    );
}

#[test]
fn missing_archived_secure_original_preserves_the_current_edited_copy_as_a_new_secure_child() {
    let (mut s, mut doc, source, id) = missing_secure_setup(true, false, true, false);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let proof = crate::materializer::Evidence::prepare(
        std::slice::from_ref(&source),
        &crate::materializer::Keyring::new(&root, &doc).unwrap(),
        &BTreeMap::new(),
    )
    .unwrap();
    let mut edited = proof.copies()[&id].clone();
    edited.hlc = Hlc::foreign(0xffff_0000_0020);
    let body = b"Public later current secure copy body";
    edited.fields.as_mut().unwrap().name = "Public later current secure copy title".into();
    edited.fields.as_mut().unwrap().content = Zeroizing::new(
        crate::crypto::seal_record(body, &root, &doc.salt().unwrap(), &doc.kid, id, false)
            .unwrap()
            .text()
            .as_bytes()
            .to_vec(),
    );
    edited.extensions.insert(
        "vaultContentHash".into(),
        crate::canonical::Value::text(crate::crypto::content_hash(
            body,
            &root,
            &doc.salt().unwrap(),
        )),
    );
    doc.records = vec![
        crate::projection::vault_record(&edited, None, &doc.kid)
            .unwrap()
            .unwrap(),
    ];
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &doc.encode().unwrap(),
    )
    .unwrap();
    independent_current(&mut s, &[source, edited.clone()]);
    let before = read_journal(&mut s).journal;
    let mut vault = unlock(&s, &doc);
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    let reviewed = restore::prepare(&mut s.store, selection, Some(&mut vault)).unwrap();
    assert_eq!(reviewed.summary().preserved_versions, 1);
    confirm(&mut s, reviewed, None).unwrap();
    let after = read_journal(&mut s).journal;
    assert!(before.preserves_transport_state(&after));
    let live = crate::vault::read_document(s.temp.path()).unwrap().unwrap();
    assert_eq!(live.records.len(), 2);
    let mut vault = unlock(&s, &live);
    assert!(vault.body(id).unwrap().as_slice() != body);
    let child = live.records.iter().find(|r| r.metadata.id != id).unwrap();
    assert!(vault.body(child.metadata.id).unwrap().as_slice() == body);
    assert!(!child.metadata.is_enabled && child.metadata.keyword.is_empty());
    vault.lock();
    let server = settle(&mut s);
    let child_batch = server
        .submitted
        .iter()
        .position(|b| b.iter().any(|(e, _)| e.id == child.metadata.id))
        .unwrap();
    let original_batch = server
        .submitted
        .iter()
        .position(|b| b.iter().any(|(e, _)| e == &after.conflict_snapshots()[&id]))
        .unwrap();
    assert!(child_batch < original_batch);
}

#[test]
fn an_unrelated_occupant_of_the_missing_original_uuid_refuses_the_whole_review() {
    let (mut s, doc, source, id) = missing_secure_setup(true, false, true, false);
    let library = Library::open(s.temp.path().into()).unwrap();
    let mut unrelated = envelope(5, "Public unrelated UUID occupant", 40);
    unrelated.id = id;
    write_primary(&library, &[source.clone(), unrelated.clone()]);
    independent_current(&mut s, &[source, unrelated]);
    let plain = std::fs::read(library.path()).unwrap();
    let sealed = std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap();
    let before = read_journal(&mut s).journal;
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    let mut vault = unlock(&s, &doc);
    assert!(matches!(
        restore::prepare(&mut s.store, selection, Some(&mut vault)),
        Err(restore::Failure::Primary(
            primary::Failure::ReservedCollision
        ))
    ));
    assert!(plain == std::fs::read(library.path()).unwrap());
    assert!(sealed == std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap());
    assert!(
        read_journal(&mut s).journal == before
            && s.backend.memory.slot(Slot::HistoryRestore).is_none()
    );
}
