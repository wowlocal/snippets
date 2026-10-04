//! Authenticated encrypted images of a fictional historical client. Only own
//! stamp/hash metadata is absent; original v1 carriers and body seals stay exact.
use super::*;
use crate::account_review;

fn legacy_archive(saved: &mut Saved, mask: u8) {
    rewrite_archive(saved, |journal| journal.test_omit_vault_metadata(mask));
}
pub(super) fn rewrite_archive(saved: &mut Saved, mut transform: impl FnMut(&mut Journal)) {
    saved
        .setup
        .store
        .transaction_with::<_, restore::Failure>(|owner| {
            let before = owner.read(Slot::AccountReview)?.unwrap();
            let archive = handover::Archive::load(owner).unwrap();
            let entry = &archive.entries[0];
            let key = RootKey::from_bytes(&entry.checkpoint[..32]).unwrap();
            let salt = entry.checkpoint[32..].try_into().unwrap();
            let scope = entry.installed().unwrap().binding.checkpoint_scope();
            let directory = owner.root().join("Sync/Reviews");
            let mut receipt = entry.receipt.encode_secret().unwrap();
            for (kind, scope, hash_range) in [
                ("source", entry.receipt.previous().scope.clone(), 246..278),
                ("target", scope, 278..310),
            ] {
                let path =
                    account_review::image_path(&directory, &entry.receipt.transition_id(), kind);
                let bytes = account_review::read_image(&path).unwrap().unwrap();
                let mut checkpoint = Checkpoint::from_encrypted(bytes, &key, &salt, scope).unwrap();
                transform(&mut checkpoint.journal);
                let bytes = Checkpoint::seal_journal(&checkpoint.journal, &key, &salt).unwrap();
                crate::model::atomic_write(&path, &bytes).unwrap();
                receipt[hash_range].copy_from_slice(&Sha256::digest(&bytes));
            }
            // The fixture's protected declaration belongs to the same historical
            // client as both encrypted images. Runtime authentication/reset checks
            // remain unchanged and must accept or refuse this pair themselves.
            let mut value = crate::canonical::parse(&before).unwrap();
            let Value::Object(fields) = &mut value else {
                unreachable!()
            };
            let Value::Array(entries) = fields.get_mut("entries").unwrap() else {
                unreachable!()
            };
            let Value::Object(entry) = &mut entries[0] else {
                unreachable!()
            };
            entry.insert("receipt".into(), Value::text(STANDARD.encode(&receipt)));
            let generation = fields["generation"].as_int().unwrap() + 1;
            fields.insert("generation".into(), Value::Int(generation));
            owner.replace(
                Slot::AccountReview,
                Some(&before),
                Some(&value.encode().unwrap()),
            )?;
            Ok(())
        })
        .unwrap();
}

#[test]
fn legacy_owned_metadata_recovery_rekeys_every_ordered_frame_and_finishes_without_live_keys() {
    for mask in 1..=3 {
        for queued in [false, true] {
            for point in [None, Some(1), Some(2), Some(3), Some(4), Some(7)] {
                let mut saved = saved(queued);
                legacy_archive(&mut saved, mask);
                let before = read_journal(&mut saved.setup).journal;
                let protected = capabilities(&saved.setup);
                let selection = history::inspect(&mut saved.setup.store).unwrap().switches[0]
                    .selection
                    .clone();
                let mut current = unlock_current(&saved.setup, &saved.current);
                assert!(
                    restore::prepare(
                        &mut saved.setup.store,
                        selection.clone(),
                        Some(&mut current)
                    )
                    .is_err()
                );
                let source = restore::authenticate_source(
                    &mut saved.setup.store,
                    &selection,
                    &crypto::format_recovery(&[0x66; 16]),
                    true,
                )
                .unwrap();
                let review = restore::prepare_foreign(
                    &mut saved.setup.store,
                    selection,
                    &mut current,
                    source,
                )
                .unwrap();
                let result = confirm(&mut saved.setup, review, point);
                assert_eq!(result.is_ok(), point.is_none());
                drop(current);
                if point.is_some() {
                    saved.setup.store =
                        Store::load(saved.setup.temp.path(), saved.setup.backend.clone()).unwrap();
                    resume_restore(&mut saved.setup).unwrap();
                }
                let after = read_journal(&mut saved.setup).journal;
                assert!(
                    before.preserves_transport_state(&after) && before.outbound == after.outbound
                );
                assert!(capabilities(&saved.setup) == protected);
                let originals = after.conflict_snapshots();
                let original = originals
                    .values()
                    .find(|e| {
                        e.secure
                            && merge::provenance(e)
                                .is_some_and(|p| p.source_id == document().records[0].metadata.id)
                            && e.fields.as_ref().unwrap().name
                                == saved.original.fields.as_ref().unwrap().name
                    })
                    .unwrap();
                let nonces: std::collections::BTreeSet<_> = after
                    .restoration_generations()
                    .unwrap()
                    .iter()
                    .flat_map(|g| &g.sources)
                    .flat_map(|(_, copies)| copies)
                    .filter(|e| e.id == original.id)
                    .map(|e| e.hash().unwrap())
                    .collect();
                assert_eq!(nonces.len(), if queued { 2 } else { 1 });
                let current_doc = crate::vault::read_document(saved.setup.temp.path())
                    .unwrap()
                    .unwrap();
                assert!(current_doc.same_identity(&saved.current));
                let mut current = unlock_current(&saved.setup, &current_doc);
                let selected = after.entry(original.id).unwrap().desired.clone();
                assert!(
                    current.body(selected.id).unwrap().as_slice()
                        == b"Public selected secure C1 body"
                );
                let key = RootKey::from_bytes(&[0x44; 32]).unwrap();
                let keys = Keyring::new(&key, &current_doc).unwrap();
                crate::materializer::authenticate_generations(
                    &after.restoration_generations().unwrap(),
                    &keys,
                )
                .unwrap();
                current.lock();
                let mut status = crate::sender::Status::MoreBatches;
                for _ in 0..8 {
                    status = send_fixture(&saved.setup, &mut saved.server, false).status;
                    if status == crate::sender::Status::ReceiveFirst {
                        with_fixture(&saved.setup, &mut saved.server, |owner, server| {
                            assert_eq!(
                                owner.receive(server, 8).unwrap().status,
                                crate::receiver::Status::Current
                            );
                        });
                        status = crate::sender::Status::MoreBatches;
                    }
                    if status != crate::sender::Status::MoreBatches {
                        break;
                    }
                }
                assert_eq!(status, crate::sender::Status::Settled);
                let original_batch = saved
                    .server
                    .submitted
                    .iter()
                    .position(|batch| batch.iter().any(|(e, _)| e == original))
                    .unwrap();
                let selected_batch = saved
                    .server
                    .submitted
                    .iter()
                    .rposition(|batch| batch.iter().any(|(e, _)| e.id == selected.id))
                    .unwrap();
                assert!(original_batch < selected_batch);
                // Delivery clears an acknowledged nested carrier before C1 is
                // sent. Its selected body must remain exact after that cleanup.
                let delivered = saved.server.submitted[selected_batch]
                    .iter()
                    .find(|(e, _)| e.id == selected.id)
                    .unwrap()
                    .0
                    .clone();
                assert!(
                    delivered.fields.as_ref().unwrap().content
                        == selected.fields.as_ref().unwrap().content
                );
                crate::materializer::authenticate(&delivered, &keys, true).unwrap();
                assert!(
                    !read_journal(&mut saved.setup)
                        .journal
                        .has_preservation_work()
                );
            }
        }
    }
}
