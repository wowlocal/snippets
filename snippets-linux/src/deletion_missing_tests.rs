//! Actual encrypted WAL and strict positional CAS; fictional fixtures only.
use super::*;

pub(super) fn missing_original(
    corrupt: bool,
) -> (
    tempfile::TempDir,
    Library,
    Server,
    crate::vault::Document,
    Envelope,
    Uuid,
) {
    let (temp, library, server, mut doc, mut losing) = secure_setup();
    if corrupt {
        losing.extensions.insert(
            "vaultContentHash".into(),
            crate::canonical::Value::text("00000000000000000000000000000000"),
        );
    }
    let source = envelope(
        losing.id.as_u128(),
        "Public winner with unmaterialized original",
        0xffff_ffff_ff00,
    );
    let source = merge::merge(None, Some(&losing), Some(&source))
        .unwrap()
        .survivor
        .unwrap();
    let id = merge::secure_variants(&source).unwrap().remove(0).copy_id;
    let mut checkpoint = load(&library);
    checkpoint.journal.stage_conflict(&source, &[]).unwrap();
    checkpoint.journal.desire(source.clone()).unwrap();
    checkpoint
        .journal
        .projected
        .insert(source.id, source.clone());
    let mut plain = library.read().unwrap().0;
    plain.push(source.snippet().unwrap().unwrap());
    crate::model::atomic_write(
        &library.path(),
        &crate::model::encode_library(&plain, false).unwrap(),
    )
    .unwrap();
    doc.records.clear();
    write_vault(&library, &doc);
    checkpoint.save(&library, &key(), &SALT).unwrap();
    assert!(load(&library).journal.preservation_original(id).is_none());
    (temp, library, server, doc, source, id)
}
pub(super) fn finish(owner: &Owner<'_>, library: &Library, server: &mut Server) {
    let mut status = sender::Status::MoreBatches;
    for _ in 0..12 {
        status = owner.send(server, 2).unwrap().status;
        if status == sender::Status::ReceiveFirst {
            assert_eq!(
                owner.receive(server, 1).unwrap().status,
                receiver::Status::Current
            );
            status = sender::Status::MoreBatches;
            continue;
        }
        if status != sender::Status::MoreBatches {
            break;
        }
    }
    assert_eq!(status, sender::Status::Settled);
    assert!(!load(library).journal.has_preservation_work());
}
pub(super) struct LostReply<'a>(pub(super) &'a mut Server);
impl sender::Remote for LostReply<'_> {
    fn preflight(&mut self) -> receiver::RemoteResult<sender::SendObservation> {
        <Server as sender::Remote>::preflight(self.0)
    }
    fn submit(&mut self, offers: &[crate::cloud::Offer]) -> receiver::RemoteResult<sender::Reply> {
        <Server as sender::Remote>::submit(self.0, offers)?;
        Err(crate::cloud::Failure::Network)
    }
}
#[test]
fn absent_unmaterialized_secure_copy_is_reviewable_and_survives_every_published_wal_boundary() {
    for choice in [Choice::Keep, Choice::Delete] {
        for fault in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
            let (_temp, library, mut server, _, source, id) = missing_original(false);
            let key = key();
            let scope = scope();
            let owner = owner(&library, &key, &scope, &|| Ok(()));
            let before = load(&library);
            let plain = fs::read(library.path()).unwrap();
            let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let review = owner.prepare_deletion_review(&mut server).unwrap();
            assert!(review.id == id && review.materialize && review.live.is_none());
            let summary = review.summary();
            assert!(
                summary.can_keep
                    && summary.secure
                    && summary.keep_requires_vault
                    && summary.delete_requires_vault
            );
            assert_eq!(
                owner
                    .decide_deletion_review(&mut server, review, choice)
                    .err(),
                Some(Failure::VaultLocked)
            );
            assert!(load(&library).same_snapshot(&before));
            assert!(
                plain == fs::read(library.path()).unwrap()
                    && sealed == fs::read(library.root.join("Vault/vault.json")).unwrap()
            );
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
                before.journal.inbox == after.journal.inbox
                    && before.journal.outbound == after.journal.outbound
            );
            for id in before.journal.agreed_envelopes().keys() {
                assert!(before.journal.confirmed(*id) == after.journal.confirmed(*id));
            }
            assert!(
                before.journal.preservation_data()[&source.id].0
                    == after.journal.preservation_data()[&source.id].0
            );
            let original = after.journal.preservation_original(id).unwrap().clone();
            assert_eq!(summary.name, original.fields.as_ref().unwrap().name);
            let data = primary::current(&library, &after.journal, "11111111").unwrap();
            assert_eq!(data.contains_key(&id), choice == Choice::Keep);
            if choice == Choice::Keep {
                assert!(
                    data[&id].fields.as_ref().unwrap().content
                        == original.fields.as_ref().unwrap().content
                );
            }
            finish(&owner, &library, &mut server);
            let copies: Vec<_> = server
                .submitted
                .iter()
                .flatten()
                .filter(|(e, _)| e.id == id)
                .collect();
            assert!(copies[0].0 == original);
            assert_eq!(server.records[&id].0.deleted, choice == Choice::Delete);
            assert!(!merge::has_unresolved(Some(
                &server.records[&source.id].0.open(&key, &SALT).unwrap()
            )));
        }
    }
}

fn incoming_delete(library: &Library, server: &mut Server, source: &Envelope, id: Uuid) {
    let mut deleted = source.clone();
    deleted.id = id;
    deleted.secure = true;
    deleted.deleted = true;
    deleted.fields = None;
    deleted.extensions = std::collections::BTreeMap::from([(
        "vaultKID".into(),
        merge::secure_variants(source)
            .unwrap()
            .remove(0)
            .source_extensions["vaultKID"]
            .clone(),
    )]);
    deleted.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff10);
    server.add(&deleted);
    let mut checkpoint = load(library);
    let cursor = checkpoint.journal.inbox.cursor().cloned();
    checkpoint
        .journal
        .inbox
        .receive(
            &feed(3),
            cursor.as_ref(),
            vec![Confirmed {
                envelope: deleted,
                record_version: server.records[&id].1.clone(),
            }],
            crate::snapshot_review::tests::cursor("public-missing-original-deletion"),
            false,
            false,
        )
        .unwrap();
    checkpoint.save(library, &key(), &SALT).unwrap();
}
#[test]
fn remote_deletion_of_a_never_materialized_original_uses_the_reviewed_actual_cas() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, _, source, id) = missing_original(false);
        incoming_delete(&library, &mut server, &source, id);
        let cas = server.records[&id].1.clone();
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert!(
            review.id == id
                && review.summary().kind == Kind::CloudDeletion
                && review.summary().can_keep
        );
        let mut vault = unlock_vault(&library);
        owner
            .decide_deletion_review_with_vault(&mut server, review, choice, Some(&mut vault))
            .unwrap();
        vault.lock();
        let original = load(&library)
            .journal
            .preservation_original(id)
            .unwrap()
            .clone();
        finish(&owner, &library, &mut server);
        let copies: Vec<_> = server
            .submitted
            .iter()
            .flatten()
            .filter(|(e, _)| e.id == id)
            .collect();
        assert!(copies[0].0 == original && copies[0].1 == Some(cas));
        assert_eq!(server.records[&id].0.deleted, choice == Choice::Delete);
    }
}

#[test]
fn invalid_missing_original_keyed_hash_refuses_both_decisions_without_file_or_journal_changes() {
    for choice in [Choice::Keep, Choice::Delete] {
        let (_temp, library, mut server, _, _, _) = missing_original(true);
        let plain = fs::read(library.path()).unwrap();
        let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
        let before = load(&library);
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        let mut vault = unlock_vault(&library);
        assert!(
            owner
                .decide_deletion_review_with_vault(&mut server, review, choice, Some(&mut vault))
                .is_err()
        );
        assert!(
            plain == fs::read(library.path()).unwrap()
                && sealed == fs::read(library.root.join("Vault/vault.json")).unwrap()
        );
        assert!(load(&library).same_snapshot(&before));
        assert!(server.submitted.is_empty());
    }
}

#[test]
fn unrelated_reserved_occupant_cannot_be_relabelled_as_a_missing_original() {
    let (_temp, library, mut server, _, source, id) = missing_original(false);
    let mut unrelated = envelope(5, "Public unrelated reserved occupant", 100);
    unrelated.id = id;
    let mut plain = library.read().unwrap().0;
    plain.push(unrelated.snippet().unwrap().unwrap());
    crate::model::atomic_write(
        &library.path(),
        &crate::model::encode_library(&plain, false).unwrap(),
    )
    .unwrap();
    incoming_delete(&library, &mut server, &source, id);
    let before = load(&library);
    let primary = fs::read(library.path()).unwrap();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .prepare_deletion_review(&mut server)
            .err(),
        Some(Failure::Data(receiver::Failure::Primary(
            primary::Failure::ReservedCollision
        )))
    );
    assert!(load(&library).same_snapshot(&before) && primary == fs::read(library.path()).unwrap());
}

#[test]
fn queued_missing_original_materializes_beside_the_exact_inflight_source_and_retained_nonce() {
    for fault in [None, Some(2)] {
        let (_temp, library, mut server, mut doc, source, id) = missing_original(false);
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let keys = crate::materializer::Keyring::new(&root, &doc).unwrap();
        let mut checkpoint = load(&library);
        checkpoint.journal = checkpoint
            .journal
            .materialize_preservation(id, &keys)
            .unwrap();
        let retained = checkpoint
            .journal
            .preservation_original(id)
            .unwrap()
            .clone();
        checkpoint.journal.projected.insert(id, retained.clone());
        checkpoint.journal.desire(retained.clone()).unwrap();
        doc.records = vec![
            crate::projection::vault_record(&retained, None, &doc.kid)
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
        assert!(owner.send(&mut LostReply(&mut server), 1).is_err());
        checkpoint = load(&library);
        let packet = checkpoint.journal.outbound.clone().unwrap();
        let parent = packet.offers[0].offered.envelope.clone();
        assert_eq!(parent.id, source.id);
        let mut queued = source.clone();
        queued.hlc = crate::clock::Hlc::foreign(0xffff_ffff_ff20);
        queued.fields.as_mut().unwrap().name = "Public later queued source title".into();
        let current = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
        let old_targets = checkpoint.journal.release_targets(&current).unwrap();
        checkpoint
            .journal
            .stage_restoration_generation(
                [0x77; 16],
                &crate::journal::RestorationGeneration {
                    targets: std::collections::BTreeMap::from([
                        (source.id, queued.clone()),
                        (id, retained.clone()),
                    ]),
                    sources: vec![(queued.clone(), Vec::new())],
                },
                &old_targets,
            )
            .unwrap();
        checkpoint.journal.desire(queued.clone()).unwrap();
        checkpoint
            .journal
            .projected
            .insert(source.id, queued.clone());
        let mut current = current;
        current.insert(source.id, queued);
        write_primary(&library, &current.into_values().collect::<Vec<_>>());
        doc.records.clear();
        write_vault(&library, &doc);
        checkpoint.save(&library, &key, &SALT).unwrap();
        let before = load(&library);
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        assert!(review.id == id && review.materialize);
        let mut vault = unlock_vault(&library);
        let result = owner.decide_deletion_authenticated(
            &mut server,
            review,
            Choice::Keep,
            Some(&mut vault),
            fault,
        );
        vault.lock();
        assert_eq!(result.is_ok(), fault.is_none());
        if fault.is_some() {
            primary::recover(&library.root, &key, &SALT, scope.clone()).unwrap();
        }
        let after = load(&library);
        assert!(after.journal.outbound == Some(packet.clone()));
        assert!(after.journal.confirmed(id) == before.journal.confirmed(id));
        assert!(after.journal.preservation_original(id) == Some(&retained));
        let frames = after.journal.preservation_generations(id).unwrap();
        let prior_frames = before.journal.preservation_generations(id).unwrap();
        assert!(frames[1].targets == prior_frames[1].targets);
        let fresh = frames[1]
            .sources
            .iter()
            .flat_map(|(_, copies)| copies)
            .find(|e| e.id == id)
            .unwrap()
            .clone();
        assert!(fresh != retained);
        let start = server.submitted.len();
        finish(&owner, &library, &mut server);
        let sent: Vec<_> = server.submitted[start..].iter().flatten().collect();
        assert!(sent[0].0 == parent && sent[0].1 == packet.offers[0].offered.record_version);
        assert!(sent.iter().any(|(e, cas)| *e == fresh && cas.is_some()));
        assert!(!server.records[&id].0.deleted);
        assert!(
            crate::vault::read_document(&library.root)
                .unwrap()
                .unwrap()
                .records
                .iter()
                .find(|r| r.metadata.id == id)
                .unwrap()
                .sealed
                .text()
                .as_bytes()
                == retained.fields.as_ref().unwrap().content.as_slice()
        );
    }
}

#[test]
fn changed_checkpoint_primary_or_vault_identity_refuses_materialization_without_overwriting_the_race()
 {
    for change in 0..3 {
        let (_temp, library, mut server, mut doc, _, _) = missing_original(false);
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_deletion_review(&mut server).unwrap();
        if change == 0 {
            load(&library).save(&library, &key, &SALT).unwrap();
        } else if change == 1 {
            let mut records = library.read().unwrap().0;
            records[0].content = "Public later independent primary edit".into();
            crate::model::atomic_write(
                &library.path(),
                &crate::model::encode_library(&records, false).unwrap(),
            )
            .unwrap();
        } else {
            doc.vault_salt = crate::crypto::b64(&[0x44; 32]);
            write_vault(&library, &doc);
        }
        let before = load(&library);
        let plain = fs::read(library.path()).unwrap();
        let sealed = fs::read(library.root.join("Vault/vault.json")).unwrap();
        let mut vault = unlock_vault(&library);
        assert_eq!(
            owner
                .decide_deletion_review_with_vault(
                    &mut server,
                    review,
                    Choice::Keep,
                    Some(&mut vault)
                )
                .err(),
            Some(Failure::Changed)
        );
        assert!(load(&library).same_snapshot(&before));
        assert!(
            plain == fs::read(library.path()).unwrap()
                && sealed == fs::read(library.root.join("Vault/vault.json")).unwrap()
        );
        assert!(server.submitted.is_empty());
    }
}
