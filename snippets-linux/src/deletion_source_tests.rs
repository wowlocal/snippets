//! Reviewed current-source decisions; fictional vault, actual WAL and strict CAS.
use super::*;

fn absent_source(
    secure_winner: bool,
    corrupt: bool,
) -> (tempfile::TempDir, Library, Server, Envelope, Envelope, Uuid) {
    let (temp, library, server, mut document, mut losing) = secure_setup();
    if corrupt {
        losing.extensions.insert(
            "vaultContentHash".into(),
            crate::canonical::Value::text("00000000000000000000000000000000"),
        );
    }
    let winner = if secure_winner {
        let mut winner = losing.clone();
        winner.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff00);
        let material = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let body = b"Public independently retained secure source winner";
        let sealed = crate::crypto::seal_record(
            body,
            &material,
            &document.salt().unwrap(),
            &document.kid,
            winner.id,
            false,
        )
        .unwrap();
        winner.fields.as_mut().unwrap().content =
            zeroize::Zeroizing::new(sealed.text().as_bytes().to_vec());
        winner.extensions.insert(
            "vaultContentHash".into(),
            crate::canonical::Value::text(crate::crypto::content_hash(
                body,
                &material,
                &document.salt().unwrap(),
            )),
        );
        winner
    } else {
        envelope(
            losing.id.as_u128(),
            "Public held source winner",
            0xffff_ffff_ff00,
        )
    };
    let held = merge::merge(None, Some(&losing), Some(&winner))
        .unwrap()
        .survivor
        .unwrap();
    let copy_id = merge::secure_variants(&held).unwrap().remove(0).copy_id;
    let mut checkpoint = load(&library);
    checkpoint.journal.stage_conflict(&held, &[]).unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    document.records.clear();
    write_vault(&library, &document);
    (temp, library, server, losing, held, copy_id)
}

#[test]
fn source_absence_preserves_the_held_winner_and_originals_for_both_decisions_and_every_wal_phase() {
    for secure_winner in [false, true] {
        for choice in [Choice::Keep, Choice::Delete] {
            for fault in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
                let (_temp, library, mut server, local, held, original_id) =
                    absent_source(secure_winner, false);
                let key = key();
                let scope = scope();
                let owner = owner(&library, &key, &scope, &|| Ok(()));
                let before = load(&library);
                let review = owner.prepare_deletion_review(&mut server).unwrap();
                assert!(review.id == local.id && review.materialize);
                assert!(review.live.as_ref() == Some(&local));
                assert_eq!(review.summary().preserved_source_versions, 1);
                assert_eq!(review.summary().restored_conflict_copies, 1);
                assert!(
                    review.summary().keep_requires_vault && review.summary().delete_requires_vault
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
                assert_eq!(result.is_ok(), fault.is_none());
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
                assert!(before.journal.agreed_envelopes() == after.journal.agreed_envelopes());
                assert!(
                    before.journal.outbound == after.journal.outbound
                        && before.journal.inbox == after.journal.inbox
                );
                assert!(after.journal.preservation_data()[&held.id].0 == held);
                let original = after
                    .journal
                    .preservation_original(original_id)
                    .unwrap()
                    .clone();
                let current = primary::current(&library, &after.journal, "11111111").unwrap();
                assert_eq!(current.contains_key(&local.id), choice == Choice::Keep);
                if choice == Choice::Keep {
                    assert!(
                        current[&local.id].fields.as_ref().unwrap().content
                            == local.fields.as_ref().unwrap().content
                    );
                }
                let preserved = current
                    .values()
                    .find(|e| {
                        merge::provenance(e).is_some_and(|p| p.source_id == held.id)
                            && e.id != original_id
                    })
                    .unwrap();
                assert!(
                    !preserved.fields.as_ref().unwrap().is_enabled
                        && preserved.fields.as_ref().unwrap().keyword.is_empty()
                );
                assert_eq!(preserved.secure, secure_winner);
                if secure_winner {
                    let document = crate::vault::read_document(&library.root).unwrap().unwrap();
                    let material = RootKey::from_bytes(&[0x11; 32]).unwrap();
                    let seal = crate::crypto::Sealed::parse(
                        String::from_utf8(preserved.fields.as_ref().unwrap().content.to_vec())
                            .unwrap(),
                    )
                    .unwrap();
                    let body = crate::crypto::open_record(
                        &seal,
                        &material,
                        &document.salt().unwrap(),
                        &document.kid,
                        preserved.id,
                        false,
                    )
                    .unwrap();
                    assert_eq!(
                        body.as_slice(),
                        b"Public independently retained secure source winner"
                    );
                    assert!(
                        preserved.fields.as_ref().unwrap().content
                            != held.fields.as_ref().unwrap().content
                    );
                } else {
                    assert!(
                        preserved.fields.as_ref().unwrap().content
                            == held.fields.as_ref().unwrap().content
                    );
                }
                let preserved_id = preserved.id;
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
                let frames = load(&library)
                    .journal
                    .preservation_generations(held.id)
                    .unwrap();
                let shapes: Vec<_> = frames
                    .iter()
                    .map(|f| {
                        (
                            f.targets.len(),
                            f.sources
                                .iter()
                                .map(|(s, c)| {
                                    (s.secure, s.deleted, merge::has_unresolved(Some(s)), c.len())
                                })
                                .collect::<Vec<_>>(),
                        )
                    })
                    .collect();
                assert_eq!(
                    status,
                    sender::Status::Settled,
                    "secure winner {secure_winner}, choice {choice:?}, fault {fault:?}, frames {shapes:?}, submitted batches {}",
                    server.submitted.len()
                );
                assert_eq!(
                    server.records[&local.id].0.deleted,
                    choice == Choice::Delete
                );
                let sent: Vec<_> = server
                    .submitted
                    .iter()
                    .flatten()
                    .map(|(envelope, _)| envelope.clone())
                    .collect();
                assert!(sent.iter().find(|e| e.id == original_id).unwrap() == &original);
                assert!(
                    sent.iter().position(|e| e.id == original_id).unwrap()
                        < sent.iter().position(|e| e.id == local.id).unwrap()
                );
                assert!(server.records.contains_key(&preserved_id));
                assert!(!merge::has_unresolved(Some(
                    &server.records[&local.id].0.open(&key, &SALT).unwrap()
                )));
            }
        }
    }
}

#[test]
fn source_original_and_new_companion_collisions_refuse_before_review_changes_any_data() {
    for extra in [false, true] {
        let (_temp, library, mut server, _, held, original_id) = absent_source(false, false);
        let copy_id = if extra {
            merge::plain_copy(&held).unwrap().id
        } else {
            original_id
        };
        let mut unrelated = envelope(9, "Public reserved source companion occupant", 10);
        unrelated.id = copy_id;
        let mut records = library.read().unwrap().0;
        records.push(unrelated.snippet().unwrap().unwrap());
        crate::model::atomic_write(
            &library.path(),
            &crate::model::encode_library(&records, false).unwrap(),
        )
        .unwrap();
        let before = load(&library);
        let plain = fs::read(library.path()).unwrap();
        let vault = fs::read(library.root.join("Vault/vault.json")).unwrap();
        assert_eq!(
            owner(&library, &key(), &scope(), &|| Ok(()))
                .prepare_deletion_review(&mut server)
                .err(),
            Some(Failure::Data(receiver::Failure::Primary(
                primary::Failure::ReservedCollision
            )))
        );
        assert!(load(&library).same_snapshot(&before));
        assert!(
            plain == fs::read(library.path()).unwrap()
                && vault == fs::read(library.root.join("Vault/vault.json")).unwrap()
        );
    }
}

#[test]
fn invalid_source_carrier_and_a_changed_source_review_refuse_without_partial_materialization() {
    for corrupt in [false, true] {
        for choice in [Choice::Keep, Choice::Delete] {
            let (_temp, library, mut server, _, _, _) = absent_source(true, corrupt);
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            if !corrupt {
                load(&library).save(&library, &key, &SALT).unwrap();
            }
            let before = load(&library);
            let plain = fs::read(library.path()).unwrap();
            let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let mut vault = unlock_vault(&library);
            assert!(
                owner
                    .decide_deletion_review_with_vault(
                        &mut server,
                        review,
                        choice,
                        Some(&mut vault)
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
    }
}

#[test]
fn a_source_with_retained_carriers_requires_the_matching_vault_before_any_change() {
    let (_temp, library, mut server, _, held, _) = absent_source(false, false);
    let mut checkpoint = load(&library);
    checkpoint.journal.projected.insert(held.id, held.clone());
    checkpoint.journal.desire(held.clone()).unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let before = load(&library);
    let plain = fs::read(library.path()).unwrap();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_deletion_review(&mut server).unwrap();
    assert_eq!(review.summary().preserved_conflict_copies, 1);
    assert_eq!(
        owner
            .decide_deletion_review(&mut server, review, Choice::Delete)
            .err(),
        Some(Failure::VaultLocked)
    );
    assert!(load(&library).same_snapshot(&before) && plain == fs::read(library.path()).unwrap());
    assert!(server.submitted.is_empty());
}

#[test]
fn an_edited_source_companion_keeps_c1_while_its_original_c0_synchronizes_first() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, local, held, _) = absent_source(false, false);
        let original = merge::plain_copy(&held).unwrap();
        let mut edited = original.clone();
        edited.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff30);
        edited.fields.as_mut().unwrap().content =
            zeroize::Zeroizing::new(b"Public later companion C1".to_vec());
        let mut records = library.read().unwrap().0;
        records.push(edited.snippet().unwrap().unwrap());
        crate::model::atomic_write(
            &library.path(),
            &crate::model::encode_library(&records, false).unwrap(),
        )
        .unwrap();
        let mut checkpoint = load(&library);
        checkpoint
            .journal
            .projected
            .insert(original.id, original.clone());
        checkpoint.save(&library, &key(), &SALT).unwrap();
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        let mut vault = unlock_vault(&library);
        owner
            .decide_deletion_review_with_vault(&mut server, review, choice, Some(&mut vault))
            .unwrap();
        drop(vault);
        let after = load(&library);
        let current = primary::current(&library, &after.journal, "11111111").unwrap();
        assert!(
            current[&edited.id].fields.as_ref().unwrap().content
                == edited.fields.as_ref().unwrap().content
        );
        missing_originals::finish(&owner, &library, &mut server);
        let versions: Vec<_> = server
            .submitted
            .iter()
            .flatten()
            .filter(|(e, _)| e.id == edited.id)
            .map(|(e, _)| e)
            .collect();
        assert!(
            versions.first().unwrap().fields.as_ref().unwrap().content
                == original.fields.as_ref().unwrap().content
        );
        assert!(
            versions.last().unwrap().fields.as_ref().unwrap().content
                == edited.fields.as_ref().unwrap().content
        );
        assert_eq!(
            server.records[&local.id].0.deleted,
            choice == Choice::Delete
        );
        assert!(
            primary::current(&library, &load(&library).journal, "11111111").unwrap()[&edited.id]
                .fields
                .as_ref()
                .unwrap()
                .content
                == edited.fields.as_ref().unwrap().content
        );
    }
}

#[test]
fn a_source_decision_materializes_queued_originals_beside_an_exact_lost_reply_packet() {
    for choice in [Choice::Keep, Choice::Delete] {
        for fault in [None, Some(2)] {
            let (_temp, library, mut server, mut doc, source, id) =
                missing_originals::missing_original(false);
            let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
            let keys = crate::materializer::Keyring::new(&root, &doc).unwrap();
            let mut checkpoint = load(&library);
            checkpoint.journal = checkpoint
                .journal
                .materialize_preservation(id, &keys)
                .unwrap();
            let original = checkpoint
                .journal
                .preservation_original(id)
                .unwrap()
                .clone();
            checkpoint.journal.projected.insert(id, original.clone());
            checkpoint.journal.desire(original.clone()).unwrap();
            doc.records = vec![
                crate::projection::vault_record(&original, None, &doc.kid)
                    .unwrap()
                    .unwrap(),
            ];
            write_vault(&library, &doc);
            checkpoint.save(&library, &key(), &SALT).unwrap();
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
            checkpoint = load(&library);
            let packet = checkpoint.journal.outbound.clone().unwrap();
            let parent = packet.offers[0].offered.envelope.clone();
            let mut queued = source.clone();
            queued.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff20);
            queued.fields.as_mut().unwrap().name =
                "Public separately retained queued source".into();
            let current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
            let targets = checkpoint.journal.release_targets(&current).unwrap();
            checkpoint
                .journal
                .stage_restoration_generation(
                    [0x65; 16],
                    &crate::journal::RestorationGeneration {
                        targets: std::collections::BTreeMap::from([
                            (source.id, queued.clone()),
                            (id, original.clone()),
                        ]),
                        sources: vec![(queued, vec![])],
                    },
                    &targets,
                )
                .unwrap();
            let mut records = library.read().unwrap().0;
            records.retain(|record| record.id != source.id);
            crate::model::atomic_write(
                &library.path(),
                &crate::model::encode_library(&records, false).unwrap(),
            )
            .unwrap();
            checkpoint.save(&library, &key, &SALT).unwrap();
            let before = load(&library);
            let old_frames = before.journal.preservation_generations(source.id).unwrap();
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert_eq!(review.id, source.id);
            assert_eq!(review.summary().preserved_source_versions, 1);
            assert_eq!(review.summary().restored_conflict_copies, 0);
            let mut vault = unlock_vault(&library);
            let result = owner.decide_deletion_authenticated(
                &mut server,
                review,
                choice,
                Some(&mut vault),
                fault,
            );
            drop(vault);
            assert_eq!(result.is_ok(), fault.is_none());
            if fault.is_some() {
                primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
            }
            let after = load(&library);
            assert!(after.journal.outbound == Some(packet.clone()));
            assert!(after.journal.confirmed(id) == before.journal.confirmed(id));
            assert!(after.journal.preservation_original(id) == Some(&original));
            let frames = after.journal.preservation_generations(source.id).unwrap();
            assert!(frames[1].targets == old_frames[1].targets);
            let new_original = frames[1].sources[0]
                .1
                .iter()
                .find(|e| e.id == id)
                .unwrap()
                .clone();
            assert!(new_original != original);
            let start = server.submitted.len();
            missing_originals::finish(&owner, &library, &mut server);
            let sent: Vec<_> = server.submitted[start..].iter().flatten().collect();
            assert!(sent[0].0 == parent && sent[0].1 == packet.offers[0].offered.record_version);
            assert!(
                sent.iter()
                    .any(|(e, cas)| *e == new_original && cas.is_some())
            );
            assert_eq!(
                server.records[&source.id].0.deleted,
                choice == Choice::Delete
            );
        }
    }
}
