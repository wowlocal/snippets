//! Real positional receipts, original nonces/CAS and full encrypted redo.
//! Only fictional data and isolated files; no network, PAM or keyring.
use super::*;

fn queue_copy_deleted(library: &Library, server: &mut Server, copy: &Envelope) -> Envelope {
    let deleted = copy
        .tombstone(
            crate::clock::Hlc::foreign(0xffff_ffff_ff10),
            "22222222".into(),
            true,
        )
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
                record_version: server.records[&copy.id].1.clone(),
            }],
            cursor("public-copy-deletion"),
            false,
            false,
        )
        .unwrap();
    checkpoint.save(library, &key(), &SALT).unwrap();
    deleted
}
fn finish_reviewed(library: &Library, server: &mut Server) {
    let key = key();
    let scope = scope();
    let owner = owner(library, &key, &scope, &|| Ok(()));
    for _ in 0..20 {
        match owner.send(server, 1).unwrap().status {
            sender::Status::Settled => return,
            sender::Status::MoreBatches => (),
            sender::Status::ReceiveFirst => {
                assert!(load(library).journal.inbox.has_pending_page());
                assert_eq!(
                    owner.receive(server, 1).unwrap().status,
                    receiver::Status::Current
                );
            }
            other => panic!("unexpected reviewed repair status: {other:?}"),
        }
    }
    panic!("reviewed conflict repair did not finish");
}

struct HoldRequest<'a>(&'a mut Server);
impl sender::Remote for HoldRequest<'_> {
    fn preflight(&mut self) -> receiver::RemoteResult<sender::SendObservation> {
        sender::Remote::preflight(self.0)
    }
    fn submit(&mut self, _: &[crate::cloud::Offer]) -> receiver::RemoteResult<sender::Reply> {
        // Model an uncertain request after the native sender has durably frozen
        // its bytes. The fixture makes no assertion about remote acceptance.
        Err(crate::cloud::Failure::Network)
    }
}

#[test]
fn remote_copy_deletion_reviews_keep_exact_source_packets_and_repair_with_actual_new_cas() {
    // 0: actual rejected C0 receipt; 1: inbox while C0 is ambiguous;
    // 2: inbox after C0 ACK, with the original source request still in flight.
    for phase in 0..3 {
        for absent in [false, true] {
            for choice in [Choice::Keep, Choice::Delete] {
                for fault in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
                    let (_temp, library, mut server, source, copy) = pending_conflict(phase == 2);
                    let mut checkpoint = load(&library);
                    let packet = checkpoint.journal.outbound.clone().unwrap();
                    let mut current =
                        primary::current(&library, &checkpoint.journal, "11111111").unwrap();
                    let mut edit = source.clone();
                    edit.hlc = crate::clock::Hlc::foreign(4500);
                    edit.fields.as_mut().unwrap().content = zeroize::Zeroizing::new(
                        b"Public newer winner beside deleted copy".to_vec(),
                    );
                    current.insert(edit.id, edit.clone());
                    write_primary(&library, &current.values().cloned().collect::<Vec<_>>());
                    checkpoint.journal.desire(edit.clone()).unwrap();
                    checkpoint.journal.projected.insert(edit.id, edit.clone());
                    checkpoint.save(&library, &key(), &SALT).unwrap();
                    if absent && phase != 0 {
                        current.remove(&copy.id);
                        write_primary(&library, &current.values().cloned().collect::<Vec<_>>());
                    }
                    let deleted = if phase == 0 {
                        let deleted = copy
                            .tombstone(
                                crate::clock::Hlc::foreign(0xffff_ffff_ff10),
                                "22222222".into(),
                                true,
                            )
                            .unwrap();
                        server.add(&deleted);
                        assert_eq!(
                            owner(&library, &key(), &scope(), &|| Ok(()))
                                .send(&mut server, 1)
                                .unwrap()
                                .status,
                            sender::Status::DeletionReview
                        );
                        deleted
                    } else {
                        queue_copy_deleted(&library, &mut server, &copy)
                    };
                    let remote_cas = server.records[&copy.id].1.clone();
                    if absent && phase == 0 {
                        current.remove(&copy.id);
                        write_primary(&library, &current.values().cloned().collect::<Vec<_>>());
                    }
                    let key = key();
                    let scope = scope();
                    let owner = owner(&library, &key, &scope, &|| Ok(()));
                    let review = owner.prepare_deletion_review(&mut server).unwrap();
                    assert_eq!(review.id, copy.id);
                    assert_eq!(review.summary().kind, Kind::CloudDeletion);
                    assert_eq!(review.repair.is_some(), phase == 2);
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
                    let saved = load(&library);
                    assert!(saved.journal.confirmed(copy.id).unwrap().envelope == deleted);
                    assert!(saved.journal.conflict_snapshots()[&copy.id] == copy);
                    if phase == 2 {
                        assert!(saved.journal.outbound.as_ref() == Some(&packet));
                    }
                    if phase == 1 {
                        assert!(saved.journal.outbound.is_none());
                    }
                    let start = server.submitted.len();
                    finish_reviewed(&library, &mut server);
                    let sent: Vec<_> = server.submitted[start..].iter().flatten().collect();
                    assert!(
                        sent.iter()
                            .any(|(e, cas)| *e == copy && *cas == Some(remote_cas.clone()))
                    );
                    if phase == 2 {
                        assert!(sent[0].0 == packet.offers[0].offered.envelope);
                        assert!(sent[0].1 == packet.offers[0].offered.record_version);
                        assert!(sent.iter().filter(|(e, _)| e.id == source.id).count() >= 2);
                    }
                    let final_copy = server.records[&copy.id].0.open(&key, &SALT).unwrap();
                    assert_eq!(final_copy.deleted, choice == Choice::Delete);
                    let final_source = server.records[&source.id].0.open(&key, &SALT).unwrap();
                    assert!(
                        final_source.fields.as_ref().unwrap().content
                            == edit.fields.as_ref().unwrap().content
                    );
                    assert!(
                        primary::current(&library, &load(&library).journal, "11111111")
                            .unwrap()
                            .get(&source.id)
                            == Some(&edit)
                    );
                    assert!(!load(&library).journal.has_preservation_work());
                }
            }
        }
    }
}

#[test]
fn an_incoming_deleted_original_cannot_overtake_its_retained_actual_acceptance_receipt() {
    let (_temp, library, mut server, _source, copy) = pending_conflict(false);
    let mut checkpoint = load(&library);
    let packet = checkpoint.journal.outbound.as_mut().unwrap();
    let offers: Vec<_> = packet
        .offers
        .iter()
        .map(|o| crate::cloud::Offer {
            record: o.wire.clone(),
            expected_record_version: o.offered.record_version.clone(),
        })
        .collect();
    <Server as sender::Remote>::submit(&mut server, &offers).unwrap();
    packet.receipts = Some(vec![crate::outbound::Receipt::Accepted(
        server.records[&copy.id].1.clone(),
    )]);
    packet.received_at = Some(1);
    checkpoint.save(&library, &key(), &SALT).unwrap();
    queue_copy_deleted(&library, &mut server, &copy);
    let saved = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    assert_eq!(
        owner.prepare_deletion_review(&mut server).err(),
        Some(Failure::SendPending)
    );
    assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == saved);
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::ReceiveFirst
    );
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    assert!(review.repair.is_some());
    owner
        .decide_deletion_review(&mut server, review, Choice::Keep)
        .unwrap();
    finish_reviewed(&library, &mut server);
    assert!(!server.records[&copy.id].0.deleted);
    assert!(!load(&library).journal.has_preservation_work());
}

#[test]
fn receiving_a_deleted_prerequisite_requires_review_even_beside_newer_or_absent_local_content() {
    for absent in [false, true] {
        let (_temp, library, mut server, _source, copy) = pending_conflict(false);
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        assert_eq!(
            owner.send(&mut server, 1).unwrap().status,
            sender::Status::MoreBatches
        );
        let mut checkpoint = load(&library);
        assert!(checkpoint.journal.outbound.is_none());
        let mut current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
        let mut later = copy.clone();
        later.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff20);
        later.fields.as_mut().unwrap().content =
            zeroize::Zeroizing::new(b"Public newer local C1".to_vec());
        current.insert(copy.id, later.clone());
        checkpoint.journal.desire(later.clone()).unwrap();
        checkpoint.journal.projected = current.clone();
        checkpoint.save(&library, &key, &SALT).unwrap();
        if absent {
            current.remove(&copy.id);
        }
        write_primary(&library, &current.into_values().collect::<Vec<_>>());
        queue_copy_deleted(&library, &mut server, &copy);
        let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        assert_eq!(
            owner.receive(&mut server, 1).unwrap().status,
            receiver::Status::DeletionReview
        );
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == before);
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        owner
            .decide_deletion_review(&mut server, review, Choice::Keep)
            .unwrap();
        finish_reviewed(&library, &mut server);
        let final_copy = server.records[&copy.id].0.open(&key, &SALT).unwrap();
        assert!(
            final_copy.fields.as_ref().unwrap().content == later.fields.as_ref().unwrap().content
        );
        assert!(!load(&library).journal.has_preservation_work());
    }
}

#[test]
fn reviewing_one_deleted_prerequisite_retains_every_unrelated_offer_in_the_ambiguous_packet() {
    let (_temp, library, mut server, _source, copy) = pending_conflict(false);
    let mut checkpoint = load(&library);
    let mut current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
    let unrelated = envelope(2, "Public unrelated ambiguous edit", 6000);
    current.insert(unrelated.id, unrelated.clone());
    write_primary(&library, &current.into_values().collect::<Vec<_>>());
    checkpoint.journal.desire(unrelated.clone()).unwrap();
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&unrelated))
        .unwrap()
        .remove(0);
    let transmission = crate::outbound::Transmission {
        wire: crate::wire::WireRecord::seal(&unrelated, &key(), &SALT).unwrap(),
        offered,
        deletion_authorized: false,
    };
    checkpoint
        .journal
        .outbound
        .as_mut()
        .unwrap()
        .offers
        .push(transmission.clone());
    checkpoint.save(&library, &key(), &SALT).unwrap();
    queue_copy_deleted(&library, &mut server, &copy);
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    owner
        .decide_deletion_review(&mut server, review, Choice::Keep)
        .unwrap();
    let saved = load(&library);
    let packet = saved.journal.outbound.as_ref().unwrap();
    assert!(packet.offers == vec![transmission.clone()]);
    assert!(packet.receipts.is_none() && packet.position == 0);
    let start = server.submitted.len();
    finish_reviewed(&library, &mut server);
    assert!(server.submitted[start][0].0 == unrelated);
    assert!(server.submitted[start][0].1 == transmission.offered.record_version);
    assert!(!load(&library).journal.has_preservation_work());
}

#[test]
fn repairing_a_deleted_copy_does_not_resurrect_a_reviewed_deleted_source_or_lose_its_permission() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, source, copy) = pending_conflict(false);
        let current = primary::current(&library, &load(&library).journal, "11111111").unwrap();
        write_primary(
            &library,
            &current
                .values()
                .filter(|e| e.id != source.id)
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
        assert_eq!(
            owner.send(&mut server, 1).unwrap().status,
            sender::Status::MoreBatches
        );
        let mut checkpoint = load(&library);
        let tombstone = checkpoint
            .journal
            .pending()
            .unwrap()
            .into_iter()
            .find(|e| e.id == source.id)
            .unwrap();
        assert!(tombstone.deleted && checkpoint.journal.deletion_approved(&tombstone).unwrap());
        let offered = checkpoint
            .journal
            .mark_offered(std::slice::from_ref(&tombstone))
            .unwrap()
            .remove(0);
        let packet = crate::outbound::Packet {
            key_epoch: 1,
            offers: vec![crate::outbound::Transmission {
                wire: crate::wire::WireRecord::seal(&tombstone, &key, &SALT).unwrap(),
                offered,
                deletion_authorized: true,
            }],
            receipts: None,
            received_at: None,
            position: 0,
        };
        checkpoint.journal.outbound = Some(packet.clone());
        checkpoint.save(&library, &key, &SALT).unwrap();
        queue_copy_deleted(&library, &mut server, &copy);
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert!(review.repair.is_some());
        owner
            .decide_deletion_review(&mut server, review, choice)
            .unwrap();
        assert!(load(&library).journal.outbound.as_ref() == Some(&packet));
        finish_reviewed(&library, &mut server);
        assert!(server.records[&source.id].0.deleted);
        assert!(
            server
                .submitted
                .iter()
                .flatten()
                .filter(|(e, _)| e.id == source.id)
                .all(|(e, _)| e.deleted)
        );
        assert_eq!(server.records[&copy.id].0.deleted, choice == Choice::Delete);
        assert!(!load(&library).journal.has_preservation_work());
        assert!(load(&library).journal.deletion_approvals.is_empty());
    }
}

#[test]
fn secure_remote_copy_repair_authenticates_both_decisions_and_redoes_without_the_borrowed_key() {
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
            write_vault(&library, &retained);
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            assert_eq!(
                owner.send(&mut server, 1).unwrap().status,
                sender::Status::MoreBatches
            );
            assert!(owner.send(&mut HoldRequest(&mut server), 1).is_err());
            let packet = load(&library).journal.outbound.unwrap();
            assert_eq!(packet.offers.len(), 1);
            assert_eq!(packet.offers[0].wire.id, source.id);
            assert!(!merge::has_unresolved(Some(
                &packet.offers[0].offered.envelope
            )));
            let mut absent = retained.clone();
            absent.records.retain(|r| r.metadata.id != original.id);
            write_vault(&library, &absent);
            queue_copy_deleted(&library, &mut server, &original);
            let actual_cas = server.records[&original.id].1.clone();
            let plain_before = fs::read(library.path()).unwrap();
            let vault_before = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let checkpoint_before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert!(review.repair.is_some());
            let summary = review.summary();
            assert!(summary.keep_requires_vault && summary.delete_requires_vault);
            assert_eq!(
                owner
                    .decide_deletion_review(&mut server, review, choice)
                    .err(),
                Some(Failure::VaultLocked)
            );
            assert!(fs::read(library.path()).unwrap() == plain_before);
            assert!(fs::read(library.root.join("Vault/vault.json")).unwrap() == vault_before);
            assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == checkpoint_before);
            assert!(!library.root.join("Sync/primary.pending").exists());
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            let mut vault = unlock_vault(&library);
            let result = owner.decide_deletion_authenticated(
                &mut server,
                review,
                choice,
                Some(&mut vault),
                fault,
            );
            drop(vault);
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
                            Some(&mut vault),
                        )
                        .unwrap();
                }
            } else {
                result.unwrap();
            }
            assert!(load(&library).journal.outbound.as_ref() == Some(&packet));
            assert!(load(&library).journal.conflict_snapshots()[&original.id] == original);
            let start = server.submitted.len();
            finish_reviewed(&library, &mut server);
            let sent: Vec<_> = server.submitted[start..].iter().flatten().collect();
            assert!(sent[0].0 == packet.offers[0].offered.envelope);
            assert!(sent[0].1 == packet.offers[0].offered.record_version);
            assert!(
                sent.iter()
                    .any(|(e, cas)| *e == original && *cas == Some(actual_cas.clone()))
            );
            assert!(sent.iter().filter(|(e, _)| e.id == source.id).count() >= 2);
            let mut actual = crate::vault::read_document(&library.root).unwrap().unwrap();
            assert_eq!(
                server.records[&original.id].0.deleted,
                choice == Choice::Delete
            );
            if choice == Choice::Keep {
                assert!(actual.records[0].sealed == retained.records[0].sealed);
            } else {
                assert!(actual.records.is_empty());
            }
            actual.records.clear();
            let mut header = retained;
            header.records.clear();
            assert!(actual == header);
            assert!(!load(&library).journal.has_preservation_work());
            assert!(load(&library).journal.deletion_approvals.is_empty());
        }
    }
}

#[test]
fn a_full_preservation_queue_refuses_remote_repair_without_publishing_consent_or_primary_files() {
    let (_temp, library, mut server, source, copy) = pending_conflict(true);
    let mut checkpoint = load(&library);
    let current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
    let frame = checkpoint
        .journal
        .preservation_generations(copy.id)
        .unwrap()
        .remove(0);
    let release = checkpoint.journal.release_targets(&current).unwrap();
    for n in 1..=8 {
        checkpoint
            .journal
            .stage_restoration_generation([n; 16], &frame, &release)
            .unwrap();
    }
    checkpoint.save(&library, &key(), &SALT).unwrap();
    queue_copy_deleted(&library, &mut server, &copy);
    let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    let primary_before = fs::read(library.path()).unwrap();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    assert!(review.repair.is_some());
    assert_eq!(
        owner
            .decide_deletion_review(&mut server, review, Choice::Delete)
            .err(),
        Some(Failure::Data(receiver::Failure::Primary(
            primary::Failure::RecoveryRequired
        )))
    );
    assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == before);
    assert!(fs::read(library.path()).unwrap() == primary_before);
    assert!(!library.root.join("Sync/primary.pending").exists());
    assert!(load(&library).journal.deletion_approvals.is_empty());
    assert!(
        load(&library).journal.outbound.as_ref().unwrap().offers[0]
            .wire
            .id
            == source.id
    );
}

#[test]
fn an_ordinary_remote_repair_authenticates_secure_evidence_in_later_connected_generations() {
    for damaged in [false, true] {
        for choice in [Choice::Keep, Choice::Delete] {
            let SecureConflict {
                _temp,
                library,
                mut server,
                source,
                retained,
                ..
            } = secure_conflict();
            write_vault(&library, &retained);
            let mut checkpoint = load(&library);
            let mut secure_frame = checkpoint
                .journal
                .preservation_generations(source.id)
                .unwrap()
                .remove(0);
            if damaged {
                let copy = &mut secure_frame.sources[0].1[0];
                copy.extensions.insert(
                    "vaultContentHash".into(),
                    crate::canonical::Value::text("00".repeat(16)),
                );
                secure_frame.targets.insert(copy.id, copy.clone());
            }
            let plain = merge::merge(
                None,
                Some(&envelope(
                    source.id.as_u128(),
                    "Public earlier ordinary loser",
                    1000,
                )),
                Some(&envelope(
                    source.id.as_u128(),
                    "Public earlier ordinary winner",
                    2000,
                )),
            )
            .unwrap();
            let earlier = plain.survivor.unwrap();
            let copy = plain.conflict_copies[0].clone();
            let mut current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
            current.insert(copy.id, copy.clone());
            write_primary(&library, &current.values().cloned().collect::<Vec<_>>());
            let mut journal = Journal::new(scope());
            journal.key_epoch = Some(1);
            journal.inbox = checkpoint.journal.inbox.clone();
            journal.projected = current.clone();
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
            journal
                .stage_conflict(&earlier, std::slice::from_ref(&copy))
                .unwrap();
            journal.desire(earlier.clone()).unwrap();
            server.add(&copy);
            journal
                .record_confirmed(copy.clone(), server.records[&copy.id].1.clone())
                .unwrap();
            let offered = journal
                .mark_offered(std::slice::from_ref(&earlier))
                .unwrap()
                .remove(0);
            journal.outbound = Some(crate::outbound::Packet {
                key_epoch: 1,
                offers: vec![crate::outbound::Transmission {
                    wire: crate::wire::WireRecord::seal(&earlier, &key(), &SALT).unwrap(),
                    offered,
                    deletion_authorized: false,
                }],
                receipts: None,
                received_at: None,
                position: 0,
            });
            let release = journal.release_targets(&current).unwrap();
            journal
                .stage_restoration_generation([17; 16], &secure_frame, &release)
                .unwrap();
            for e in current.values() {
                journal.desire(e.clone()).unwrap();
            }
            checkpoint.journal = journal;
            checkpoint.save(&library, &key(), &SALT).unwrap();
            queue_copy_deleted(&library, &mut server, &copy);
            let before_plain = fs::read(library.path()).unwrap();
            let before_vault = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let before_checkpoint = fs::read(library.root.join("Sync/journal.bin")).unwrap();
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            let summary = review.summary();
            assert!(
                !summary.secure && summary.keep_requires_vault && summary.delete_requires_vault
            );
            assert_eq!(
                owner
                    .decide_deletion_review(&mut server, review, choice)
                    .err(),
                Some(Failure::VaultLocked)
            );
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            let mut vault = unlock_vault(&library);
            let result = owner.decide_deletion_review_with_vault(
                &mut server,
                review,
                choice,
                Some(&mut vault),
            );
            drop(vault);
            if damaged {
                assert!(result.is_err());
                assert!(fs::read(library.path()).unwrap() == before_plain);
                assert!(fs::read(library.root.join("Vault/vault.json")).unwrap() == before_vault);
                assert!(
                    fs::read(library.root.join("Sync/journal.bin")).unwrap() == before_checkpoint
                );
                assert!(!library.root.join("Sync/primary.pending").exists());
                assert!(server.submitted.is_empty());
            } else {
                result.unwrap();
                finish_reviewed(&library, &mut server);
                assert_eq!(server.records[&copy.id].0.deleted, choice == Choice::Delete);
                assert!(!load(&library).journal.has_preservation_work());
            }
        }
    }
}
