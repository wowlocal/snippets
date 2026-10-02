//! Temporary encrypted journals, public record fixtures and an isolated CAS peer.
use super::*;
use crate::{
    cloud::Binding,
    crypto::RootKey,
    journal::{Journal, ReviewAncestor},
    model::Library,
    receiver::{FetchedPage, Observation, RemoteResult},
    snapshot_review::tests::{self as fixtures, Server},
};
use std::{
    cell::Cell,
    collections::BTreeMap,
    os::unix::fs::{PermissionsExt, symlink},
};

fn target_scope() -> Scope {
    Scope {
        membership: Binding::from_checkpoint([0x77; 32]),
        dataset: Binding::from_checkpoint([0x88; 32]),
    }
}
fn previous() -> Previous {
    Previous {
        scope: fixtures::scope(),
        key_epoch: 1,
        key_material_changed: false,
    }
}
fn setup() -> (tempfile::TempDir, Library, Checkpoint) {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let record = fixtures::envelope(1, "Public local intent", 1);
    fixtures::write_primary(&library, std::slice::from_ref(&record));
    let mut source = Checkpoint::load(
        &library,
        &fixtures::key(),
        &fixtures::SALT,
        fixtures::scope(),
    )
    .unwrap();
    source.journal.key_epoch = Some(1);
    source.journal.projected.insert(record.id, record.clone());
    source
        .journal
        .record_confirmed(record, fixtures::version("old"))
        .unwrap();
    source
        .save(&library, &fixtures::key(), &fixtures::SALT)
        .unwrap();
    (temp, library, source)
}
fn owner<'a>(
    library: &'a Library,
    key: &'a RootKey,
    scope: &'a Scope,
    epoch: u64,
    guard: &'a dyn Fn() -> receiver::Result<()>,
) -> Owner<'a> {
    Owner {
        library,
        checkpoint_key: key,
        checkpoint_salt: &fixtures::SALT,
        scope,
        key_epoch: epoch,
        wire_key: key,
        wire_salt: &fixtures::SALT,
        device: Some("11111111"),
        vault_keys: None,
        validate_session: guard,
    }
}
fn remote() -> Server {
    let mut server = Server::new();
    server.scope = target_scope();
    server.feed = Feed::new(uuid::Uuid::from_u128(4), 2).unwrap();
    server
}
fn record_body(journal: &Journal, id: u128, body: &str) -> bool {
    journal
        .entry(uuid::Uuid::from_u128(id))
        .is_some_and(|e| e.desired.snippet().unwrap().unwrap().content == body)
}

#[test]
fn reviewed_scope_resets_server_facts_without_touching_primary_or_using_the_data_plane() {
    let (_temp, library, source) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let before = fs::read(library.path()).unwrap();
    let old_bytes = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    assert_eq!(
        review.summary(),
        Summary {
            local_records: 1,
            local_intents: 1,
            preservation_copies: 0,
            previous_confirmations: 1
        }
    );
    let receipt = review.receipt();
    assert!(!library.root.join("Sync/Reviews").exists());
    assert!(!owner.account_review_applied(&mut server, &receipt).unwrap());
    owner.resume_account_review(&mut server, review).unwrap();
    let saved = Checkpoint::load(&library, &key, &fixtures::SALT, scope.clone()).unwrap();
    assert!(saved.journal.agreed_envelopes().is_empty());
    assert!(saved.journal.outbound.is_none() && saved.journal.deletion_approvals.is_empty());
    assert!(saved.journal.inbox.applied_cursor.is_none());
    assert!(saved.journal.inbox.pending.is_none());
    assert_eq!(saved.journal.key_epoch, Some(2));
    assert!(saved.journal.inbox.feed.as_ref() == Some(&server.feed));
    assert!(record_body(&saved.journal, 1, "Public local intent"));
    let entry = saved.journal.entry(uuid::Uuid::from_u128(1)).unwrap();
    assert_eq!(entry.generation, 1);
    assert!(entry.offered.is_none());
    assert!(matches!(
        entry.review,
        ReviewAncestor::Reviewed {
            previous_merge: None,
            ..
        }
    ));
    assert!(fs::read(library.path()).unwrap() == before);
    assert!(server.fetched.is_empty() && server.submitted.is_empty());
    assert!(owner.account_review_applied(&mut server, &receipt).unwrap());
    let archive = archive_directory(&library, false).unwrap();
    assert!(fs::read(image_path(&archive, &receipt.nonce, "source")).unwrap() == old_bytes);
    let retained =
        Checkpoint::from_encrypted(old_bytes, &key, &fixtures::SALT, fixtures::scope()).unwrap();
    assert!(retained.journal == source.journal);
    assert_eq!(
        fs::metadata(archive).unwrap().permissions().mode() & 0o777,
        0o700
    );
}

#[test]
fn interrupted_commit_retains_exact_images_and_recognizes_only_the_published_generation() {
    for phase in 0..=4 {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = remote();
        let before = fs::read(library.path()).unwrap();
        let old = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let receipt = review.receipt();
        let frozen = review.target_image.clone();
        assert!(
            owner
                .resume_account_review_inner(&mut server, review, Some(phase))
                .is_err()
        );
        assert_eq!(
            owner.account_review_applied(&mut server, &receipt).unwrap(),
            phase == 4
        );
        assert!(
            fs::read(library.root.join("Sync/journal.bin")).unwrap()
                == if phase == 4 { frozen } else { old }
        );
        assert!(fs::read(library.path()).unwrap() == before);
        assert!(server.fetched.is_empty() && server.submitted.is_empty());
    }
}

#[test]
fn changed_primary_or_journal_invalidates_the_confirmation_before_archiving() {
    for change_journal in [false, true] {
        let (_temp, library, mut source) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = remote();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        if change_journal {
            source
                .journal
                .desire(fixtures::envelope(2, "Public late journal intent", 2))
                .unwrap();
            source.save(&library, &key, &fixtures::SALT).unwrap();
        } else {
            fixtures::write_primary(
                &library,
                &[fixtures::envelope(1, "Public late physical edit", 2)],
            );
        }
        let journal = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let physical = fs::read(library.path()).unwrap();
        assert_eq!(
            owner.resume_account_review(&mut server, review).err(),
            Some(Failure::Changed)
        );
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == journal);
        assert!(fs::read(library.path()).unwrap() == physical);
        assert!(!library.root.join("Sync/Reviews").exists());
    }
}

#[test]
fn missing_local_records_and_whole_primary_files_do_not_become_cross_scope_deletions() {
    for remove_file in [false, true] {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        if remove_file {
            fs::remove_file(library.path()).unwrap();
        } else {
            fixtures::write_primary(&library, &[]);
        }
        let old = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        assert_eq!(
            owner
                .prepare_account_review(&mut remote(), previous())
                .err(),
            Some(Failure::LocalAbsence)
        );
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == old);
        assert!(!library.root.join("Sync/Reviews").exists());
    }
}

#[test]
fn new_physical_intent_is_kept_beside_an_unchanged_journal_only_desire() {
    let (_temp, library, mut source) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    source
        .journal
        .desire(fixtures::envelope(1, "Public held journal-only body", 3))
        .unwrap();
    source.save(&library, &key, &fixtures::SALT).unwrap();
    fixtures::write_primary(
        &library,
        &[
            fixtures::envelope(1, "Public local intent", 1),
            fixtures::envelope(2, "Public fresh unsynced body", 4),
        ],
    );
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    owner.resume_account_review(&mut server, review).unwrap();
    let saved = Checkpoint::load(&library, &key, &fixtures::SALT, scope).unwrap();
    assert!(record_body(
        &saved.journal,
        1,
        "Public held journal-only body"
    ));
    assert!(record_body(&saved.journal, 2, "Public fresh unsynced body"));
    let current = primary::current(&library, &saved.journal, "11111111").unwrap();
    assert!(
        saved
            .journal
            .local_intent(
                uuid::Uuid::from_u128(1),
                current.get(&uuid::Uuid::from_u128(1))
            )
            .unwrap()
            == Some(
                &saved
                    .journal
                    .entry(uuid::Uuid::from_u128(1))
                    .unwrap()
                    .desired
            )
    );
}

#[test]
fn old_confirmed_tombstone_is_not_intent_to_delete_a_new_library_record() {
    let (_temp, library, mut source) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let deleted = fixtures::envelope(2, "Public prior deletion", 2)
        .tombstone(crate::clock::Hlc::foreign(3), "22222222".into(), true)
        .unwrap();
    source
        .journal
        .record_confirmed(deleted, fixtures::version("deleted-old"))
        .unwrap();
    source.save(&library, &key, &fixtures::SALT).unwrap();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    owner.resume_account_review(&mut server, review).unwrap();
    let saved = Checkpoint::load(&library, &key, &fixtures::SALT, scope).unwrap();
    assert!(saved.journal.entry(uuid::Uuid::from_u128(2)).is_none());
    assert!(saved.journal.confirmed(uuid::Uuid::from_u128(2)).is_none());
    assert!(!saved.journal.known_absence(uuid::Uuid::from_u128(2)));
}

#[test]
fn scope_epoch_session_and_checkpoint_admission_precede_malformed_primary_access() {
    for kind in 0..4 {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        model::atomic_write(&library.path(), b"public malformed admission fixture").unwrap();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = remote();
        let mut old = previous();
        if kind == 0 {
            server.scope = fixtures::scope();
        }
        if kind == 1 {
            server.feed = Feed::new(uuid::Uuid::from_u128(4), 3).unwrap();
        }
        if kind == 2 {
            old.scope.dataset = Binding::from_checkpoint([0x13; 32]);
        }
        if kind == 3 {
            old.key_epoch = 3;
        }
        assert!(owner.prepare_account_review(&mut server, old).is_err());
        assert!(fs::read(library.path()).unwrap() == b"public malformed admission fixture");
        assert!(!library.root.join("Sync/Reviews").exists());
    }
    let (_temp, library, _) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let owner = owner(&library, &key, &scope, 2, &|| {
        Err(receiver::Failure::SessionChanged)
    });
    assert_eq!(
        owner
            .prepare_account_review(&mut remote(), previous())
            .err(),
        Some(Failure::Data(receiver::Failure::SessionChanged))
    );
}

#[test]
fn confirmation_rechecks_scope_feed_epoch_session_and_checkpoint_key_before_writing() {
    for kind in 0..5 {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let valid = Cell::new(true);
        let guard = || {
            if valid.get() {
                Ok(())
            } else {
                Err(receiver::Failure::SessionChanged)
            }
        };
        let owner = owner(&library, &key, &scope, 2, &guard);
        let mut server = remote();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let old = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        match kind {
            0 => server.scope = fixtures::scope(),
            1 => server.feed = Feed::new(uuid::Uuid::from_u128(5), 2).unwrap(),
            2 => server.feed = Feed::new(uuid::Uuid::from_u128(4), 3).unwrap(),
            3 => valid.set(false),
            _ => (),
        }
        if kind == 4 {
            let wrong = RootKey::from_bytes(&[0x14; 32]).unwrap();
            assert!(
                self::owner(&library, &wrong, &scope, 2, &guard)
                    .resume_account_review(&mut server, review)
                    .is_err()
            );
        } else {
            assert!(owner.resume_account_review(&mut server, review).is_err());
        }
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == old);
        assert!(!library.root.join("Sync/Reviews").exists());
    }
}

#[test]
fn epoch_or_verified_material_changes_can_review_the_same_membership_and_dataset() {
    for changed_material in [false, true] {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = fixtures::scope();
        let epoch = if changed_material { 1 } else { 2 };
        let owner = owner(&library, &key, &scope, epoch, &|| Ok(()));
        let mut server = Server::new();
        server.feed = Feed::new(uuid::Uuid::from_u128(4), epoch).unwrap();
        let mut old = previous();
        old.key_material_changed = changed_material;
        let review = owner.prepare_account_review(&mut server, old).unwrap();
        let receipt = review.receipt();
        owner.resume_account_review(&mut server, review).unwrap();
        assert!(owner.account_review_applied(&mut server, &receipt).unwrap());
        assert!(
            Checkpoint::load(&library, &key, &fixtures::SALT, scope)
                .unwrap()
                .journal
                .agreed_envelopes()
                .is_empty()
        );
    }
}

#[test]
fn unchanged_owner_requires_no_reset_and_creates_no_archive() {
    let (_temp, library, _) = setup();
    let key = fixtures::key();
    let scope = fixtures::scope();
    let owner = owner(&library, &key, &scope, 1, &|| Ok(()));
    assert_eq!(
        owner
            .prepare_account_review(&mut Server::new(), previous())
            .err(),
        Some(Failure::Unavailable)
    );
    assert!(!library.root.join("Sync/Reviews").exists());
}

#[test]
fn unsafe_or_full_retention_does_not_replace_the_only_current_checkpoint() {
    for kind in 0..5 {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = remote();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let old = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let outside = tempfile::tempdir().unwrap();
        let directory = library.root.join("Sync/Reviews");
        if kind == 0 {
            symlink(outside.path(), &directory).unwrap();
        } else {
            fs::create_dir(&directory).unwrap();
            match kind {
                1 => {
                    symlink(
                        outside.path(),
                        image_path(&directory, &review.receipt.nonce, "source"),
                    )
                    .unwrap();
                }
                2 => {
                    fs::write(
                        image_path(&directory, &review.receipt.nonce, "source"),
                        b"public wrong retained ciphertext",
                    )
                    .unwrap();
                }
                3 => {
                    for id in 1..=MAX_REVIEW_FILES {
                        fs::write(
                            image_path(&directory, &[(id as u8) + 1; 16], "source"),
                            b"public capacity sentinel",
                        )
                        .unwrap();
                    }
                }
                _ => {
                    let name = format!("{}é{}", "a".repeat(31), "b".repeat(6));
                    assert_eq!(name.len(), 39);
                    fs::write(directory.join(name), b"public unicode sentinel").unwrap();
                }
            }
        }
        assert!(owner.resume_account_review(&mut server, review).is_err());
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == old);
        assert!(fs::read_dir(outside.path()).unwrap().next().is_none());
    }
}

#[test]
fn immutable_c0_is_required_again_before_source_and_a_held_c1_edit_in_the_new_scope() {
    let (_temp, library, mut checkpoint) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let merged = crate::merge::merge(
        None,
        Some(&fixtures::envelope(1, "Public losing body", 1000)),
        Some(&fixtures::envelope(1, "Public winning body", 2000)),
    )
    .unwrap();
    let source = merged.survivor.unwrap();
    let copy = merged.conflict_copies[0].clone();
    let mut later = copy.clone();
    later.hlc = crate::clock::Hlc::foreign(4000);
    later.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public retained later copy edit".to_vec());
    checkpoint.journal.projected =
        BTreeMap::from([(source.id, source.clone()), (copy.id, copy.clone())]);
    checkpoint
        .journal
        .stage_conflict(&source, std::slice::from_ref(&copy))
        .unwrap();
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&copy))
        .unwrap()
        .remove(0);
    checkpoint
        .journal
        .accept_offered(&offered, fixtures::version("old-C0"))
        .unwrap();
    checkpoint.journal.desire(source.clone()).unwrap();
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&source))
        .unwrap()
        .remove(0);
    checkpoint
        .journal
        .accept_offered(&offered, fixtures::version("old-source-after-C0"))
        .unwrap();
    checkpoint.journal.desire(later.clone()).unwrap();
    fixtures::write_primary(&library, &[source.clone(), copy.clone()]);
    checkpoint.save(&library, &key, &fixtures::SALT).unwrap();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    assert_eq!(review.summary().preservation_copies, 1);
    owner.resume_account_review(&mut server, review).unwrap();
    let mut saved = Checkpoint::load(&library, &key, &fixtures::SALT, scope.clone()).unwrap();
    assert!(saved.journal.conflict_snapshots().get(&copy.id) == Some(&copy));
    assert!(saved.journal.entry(copy.id).unwrap().desired == later);
    assert!(saved.journal.pending().unwrap() == vec![copy.clone()]);
    let copy_offer = saved
        .journal
        .mark_offered(std::slice::from_ref(&copy))
        .unwrap()
        .remove(0);
    assert!(copy_offer.record_version.is_none());
    saved
        .journal
        .accept_offered(&copy_offer, fixtures::version("new-C0"))
        .unwrap();
    assert!(saved.journal.pending().unwrap() == vec![source.clone()]);
    let source_offer = saved
        .journal
        .mark_offered(std::slice::from_ref(&source))
        .unwrap()
        .remove(0);
    assert!(source_offer.record_version.is_none());
    saved
        .journal
        .accept_offered(&source_offer, fixtures::version("new-source-after-C0"))
        .unwrap();
    saved
        .journal
        .reconcile_dependencies(&BTreeMap::from([(source.id, source), (copy.id, copy)]))
        .unwrap();
    assert!(saved.journal.pending().unwrap() == vec![later]);
}

#[test]
fn pending_receipt_and_inbound_page_are_retained_only_in_the_old_encrypted_image() {
    use crate::{
        journal::Confirmed,
        outbound::{Packet, Receipt as PacketReceipt, Transmission},
    };
    let (_temp, library, mut source) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let desired = fixtures::envelope(1, "Public newer local edit", 3);
    source.journal.desire(desired.clone()).unwrap();
    let offered = source
        .journal
        .mark_offered(std::slice::from_ref(&desired))
        .unwrap()
        .remove(0);
    let wire = crate::wire::WireRecord::seal(&desired, &key, &fixtures::SALT).unwrap();
    source.journal.outbound = Some(Packet {
        key_epoch: 1,
        offers: vec![Transmission {
            offered,
            wire: wire.clone(),
            deletion_authorized: false,
        }],
        receipts: Some(vec![PacketReceipt::Accepted(fixtures::version(
            "old-saved-ACK",
        ))]),
        received_at: Some(1),
        position: 0,
    });
    let old_feed = fixtures::feed(3);
    source.journal.inbox.select_feed(old_feed.clone()).unwrap();
    source
        .journal
        .inbox
        .receive(
            &old_feed,
            None,
            vec![Confirmed {
                envelope: fixtures::envelope(2, "Public old queued remote body", 5),
                record_version: fixtures::version("old-queued"),
            }],
            fixtures::cursor("old-retained"),
            true,
            false,
        )
        .unwrap();
    source.save(&library, &key, &fixtures::SALT).unwrap();
    let before = source.journal.clone();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    let receipt = review.receipt();
    owner.resume_account_review(&mut server, review).unwrap();
    let saved = Checkpoint::load(&library, &key, &fixtures::SALT, scope).unwrap();
    assert!(saved.journal.outbound.is_none() && saved.journal.inbox.pending.is_none());
    assert!(saved.journal.entry(uuid::Uuid::from_u128(2)).is_none());
    assert!(record_body(&saved.journal, 1, "Public newer local edit"));
    let archive = archive_directory(&library, false).unwrap();
    let retained = Checkpoint::from_encrypted(
        fs::read(image_path(&archive, &receipt.nonce, "source")).unwrap(),
        &key,
        &fixtures::SALT,
        fixtures::scope(),
    )
    .unwrap();
    assert!(retained.journal == before);
    assert!(retained.journal.outbound.unwrap().offers[0].wire == wire);
}

#[test]
fn receipt_encoding_is_closed_bounded_and_restarts_without_payloads_or_paths() {
    let (_temp, library, _) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    let receipt = review.receipt();
    let encoded = receipt.encode_secret().unwrap();
    assert_eq!(encoded.len(), 318);
    assert!(
        !encoded
            .windows(b"Public local intent".len())
            .any(|bytes| bytes == b"Public local intent")
    );
    let decoded = Receipt::decode_secret(library.root.clone(), &encoded).unwrap();
    assert!(decoded == receipt);
    for length in [0, 3, 100, 212, 317] {
        assert!(Receipt::decode_secret(library.root.clone(), &encoded[..length]).is_err());
    }
    for offset in [0, 68, 76, 141, 157, 165, 181, 189, 197, 205] {
        let mut invalid = encoded.clone();
        match offset {
            0 => invalid[0] = b'?',
            76 => invalid[76] = 2,
            68 | 157 => invalid[offset..offset + 8].fill(0),
            141 | 165 => invalid[offset..offset + 16].fill(0),
            _ => invalid[offset..offset + 8].copy_from_slice(&u64::MAX.to_be_bytes()),
        }
        assert!(Receipt::decode_secret(library.root.clone(), &invalid).is_err());
    }
    let mut trailing = encoded.to_vec();
    trailing.push(0);
    assert!(Receipt::decode_secret(library.root.clone(), &trailing).is_err());
    for offset in [213, 310] {
        let mut invalid = encoded.clone();
        invalid[offset] = 0xff;
        assert!(Receipt::decode_secret(library.root.clone(), &invalid).is_err());
    }
    owner.resume_account_review(&mut server, review).unwrap();
    assert!(owner.account_review_applied(&mut server, &decoded).unwrap());
}

#[test]
fn staged_images_resume_after_restart_without_resetting_twice() {
    for source_present in [false, true] {
        let (_temp, library, _) = setup();
        if !source_present {
            fs::remove_file(library.root.join("Sync/journal.bin")).unwrap();
        }
        let key = fixtures::key();
        let scope = target_scope();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = remote();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let receipt = Receipt::decode_secret(
            library.root.clone(),
            &review.receipt().encode_secret().unwrap(),
        )
        .unwrap();
        let old = fs::read(library.root.join("Sync/journal.bin")).ok();
        owner.stage_account_review(&mut server, &review).unwrap();
        assert!(fs::read(library.root.join("Sync/journal.bin")).ok() == old);
        drop(review);
        owner
            .continue_account_review(&mut server, &receipt)
            .unwrap();
        let target = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        assert!(owner.account_review_applied(&mut server, &receipt).unwrap());
        owner
            .continue_account_review(&mut server, &receipt)
            .unwrap();
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == target);
        assert!(server.fetched.is_empty() && server.submitted.is_empty());
    }
}

#[test]
fn staged_continuation_rechecks_complete_file_images_and_old_checkpoint() {
    for kind in 0..5 {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = remote();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let receipt = review.receipt();
        owner.stage_account_review(&mut server, &review).unwrap();
        match kind {
            0 => {
                let mut bytes = fs::read(library.path()).unwrap();
                bytes.push(b'\n');
                fs::write(library.path(), bytes).unwrap();
            }
            1 => {
                fs::remove_file(library.path()).unwrap();
            }
            2 => {
                fixtures::write_primary(
                    &library,
                    &[fixtures::envelope(1, "Public later local edit", 8)],
                );
            }
            3 => {
                let mut saved =
                    Checkpoint::load(&library, &key, &fixtures::SALT, fixtures::scope()).unwrap();
                saved
                    .journal
                    .desire(fixtures::envelope(2, "Public later journal intent", 8))
                    .unwrap();
                saved.save(&library, &key, &fixtures::SALT).unwrap();
            }
            _ => {
                server.feed = Feed::new(uuid::Uuid::from_u128(8), 2).unwrap();
            }
        }
        let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        assert!(
            owner
                .continue_account_review(&mut server, &receipt)
                .is_err()
        );
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == before);
    }
}

#[test]
fn published_continuation_accepts_feed_rotation_but_rejects_an_advanced_checkpoint() {
    let (_temp, library, _) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    let receipt = review.receipt();
    owner.stage_account_review(&mut server, &review).unwrap();
    owner
        .continue_account_review(&mut server, &receipt)
        .unwrap();
    let target = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    server.feed = Feed::new(uuid::Uuid::from_u128(8), 2).unwrap();
    owner
        .continue_account_review(&mut server, &receipt)
        .unwrap();
    assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == target);
    let mut saved = Checkpoint::load(&library, &key, &fixtures::SALT, scope.clone()).unwrap();
    saved
        .journal
        .desire(fixtures::envelope(2, "Public new-scope change", 8))
        .unwrap();
    saved.save(&library, &key, &fixtures::SALT).unwrap();
    let advanced = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    assert!(
        owner
            .continue_account_review(&mut server, &receipt)
            .is_err()
    );
    assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == advanced);
}

struct RacingRemote {
    server: Server,
    calls: usize,
    change_at: usize,
    kind: u8,
}
impl Remote for RacingRemote {
    fn preflight(&mut self) -> RemoteResult<Observation> {
        self.calls += 1;
        if self.calls == self.change_at {
            if self.kind == 0 {
                self.server.scope = fixtures::scope();
            } else {
                self.server.feed = Feed::new(uuid::Uuid::from_u128(6), 2).unwrap();
            }
        }
        receiver::Remote::preflight(&mut self.server)
    }
    fn fetch(&mut self, _: Option<&crate::cloud::Cursor>) -> RemoteResult<FetchedPage> {
        panic!("Account review cannot fetch records")
    }
}
#[test]
fn scope_or_feed_change_during_ticket_preparation_cannot_become_a_reviewed_target() {
    for kind in 0..2 {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut remote = RacingRemote {
            server: self::remote(),
            calls: 0,
            change_at: 2,
            kind,
        };
        let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        assert!(
            owner
                .prepare_account_review(&mut remote, previous())
                .is_err()
        );
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == before);
        assert!(!library.root.join("Sync/Reviews").exists());
    }
}

#[test]
fn interrupted_epoch_only_review_does_not_mistake_the_old_epoch_for_corruption() {
    for phase in 0..=4 {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = fixtures::scope();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = Server::new();
        server.feed = Feed::new(uuid::Uuid::from_u128(4), 2).unwrap();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let receipt = review.receipt();
        assert!(
            owner
                .resume_account_review_inner(&mut server, review, Some(phase))
                .is_err()
        );
        assert_eq!(
            owner.account_review_applied(&mut server, &receipt).unwrap(),
            phase == 4
        );
    }
}

#[test]
fn deletion_intent_survives_but_its_old_scope_permission_does_not() {
    let (_temp, library, mut source) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let original = fixtures::envelope(1, "Public local intent", 1);
    let deletion = original
        .tombstone(crate::clock::Hlc::foreign(3), "22222222".into(), true)
        .unwrap();
    source.journal.desire(deletion.clone()).unwrap();
    source
        .journal
        .review_absence(deletion.id, Some(original.clone()))
        .unwrap();
    source
        .journal
        .approve_deletion(&deletion, Some(original))
        .unwrap();
    source
        .journal
        .projected
        .insert(deletion.id, deletion.clone());
    fixtures::write_primary(&library, &[]);
    source.save(&library, &key, &fixtures::SALT).unwrap();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    owner.resume_account_review(&mut server, review).unwrap();
    let saved = Checkpoint::load(&library, &key, &fixtures::SALT, scope).unwrap();
    assert!(saved.journal.entry(deletion.id).unwrap().desired == deletion);
    assert!(!saved.journal.deletion_approved(&deletion).unwrap());
    assert!(matches!(
        saved.journal.entry(deletion.id).unwrap().review,
        ReviewAncestor::Reviewed {
            primary: None,
            previous_merge: None
        }
    ));
    assert!(fs::read(library.path()).unwrap() == b"[]");
}

#[test]
fn an_external_primary_change_during_retention_cannot_pass_the_final_read_set_check() {
    let (_temp, library, _) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let armed = Cell::new(false);
    let guard = || {
        if armed.get() && library.root.join("Sync/Reviews").exists() {
            armed.set(false);
            fixtures::write_primary(
                &library,
                &[fixtures::envelope(1, "Public racing external edit", 9)],
            );
        }
        Ok(())
    };
    let owner = owner(&library, &key, &scope, 2, &guard);
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    let old = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    armed.set(true);
    assert_eq!(
        owner.resume_account_review(&mut server, review).err(),
        Some(Failure::Changed)
    );
    assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == old);
    assert!(
        Library::open(library.root.clone()).unwrap().snippets[0].content
            == "Public racing external edit"
    );
}

#[test]
fn session_lapse_around_publication_retains_the_facts_without_returning_success() {
    for after_publication in [false, true] {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let armed = Cell::new(false);
        let old = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let guard = || {
            if armed.get() && library.root.join("Sync/Reviews").exists() {
                let published = fs::read(library.root.join("Sync/journal.bin")).unwrap() != old;
                if published == after_publication {
                    return Err(receiver::Failure::SessionChanged);
                }
            }
            Ok(())
        };
        let owner = owner(&library, &key, &scope, 2, &guard);
        let mut server = remote();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let receipt = review.receipt();
        armed.set(true);
        assert_eq!(
            owner.resume_account_review(&mut server, review).err(),
            Some(Failure::Data(receiver::Failure::SessionChanged))
        );
        assert_eq!(
            self::owner(&library, &key, &scope, 2, &|| Ok(()))
                .account_review_applied(&mut server, &receipt)
                .unwrap(),
            after_publication
        );
    }
}

#[test]
fn completion_requires_both_authentic_images_the_exact_current_generation_and_a_ready_primary_fence()
 {
    for kind in 0..6 {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = remote();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let receipt = review.receipt();
        owner.resume_account_review(&mut server, review).unwrap();
        let directory = archive_directory(&library, false).unwrap();
        let path = image_path(
            &directory,
            &receipt.nonce,
            if kind == 0 { "source" } else { "target" },
        );
        match kind {
            0 | 1 => {
                let mut bytes = fs::read(&path).unwrap();
                let last = bytes.len() - 1;
                bytes[last] ^= 1;
                fs::write(&path, bytes).unwrap();
            }
            2 => {
                let mut changed =
                    Checkpoint::load(&library, &key, &fixtures::SALT, scope.clone()).unwrap();
                changed
                    .journal
                    .desire(fixtures::envelope(2, "Public newer admitted journal", 8))
                    .unwrap();
                changed.save(&library, &key, &fixtures::SALT).unwrap();
            }
            3 => {
                let mut marker = b"SPT1".to_vec();
                marker.extend_from_slice(&[0x55; 16]);
                model::atomic_write(&library.root.join("Sync/primary.pending"), &marker).unwrap();
            }
            4 => {
                fs::remove_file(image_path(&directory, &receipt.nonce, "source")).unwrap();
            }
            _ => {
                let outside = tempfile::tempdir().unwrap();
                fs::remove_file(&path).unwrap();
                symlink(outside.path(), &path).unwrap();
            }
        }
        let result = owner.account_review_applied(&mut server, &receipt);
        if kind == 2 {
            assert!(!result.unwrap());
        } else {
            assert!(result.is_err());
        }
        assert!(server.fetched.is_empty() && server.submitted.is_empty());
    }
}

#[test]
fn review_tickets_and_receipts_cannot_be_borrowed_by_another_root_or_key_owner() {
    let (_temp, library, _) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    let receipt = review.receipt();
    let other = tempfile::tempdir().unwrap();
    let other_library = Library::prepare(other.path().into()).unwrap();
    let other_owner = self::owner(&other_library, &key, &scope, 2, &|| Ok(()));
    assert_eq!(
        other_owner.resume_account_review(&mut server, review).err(),
        Some(Failure::Data(receiver::Failure::ScopeReview))
    );
    assert_eq!(
        other_owner
            .account_review_applied(&mut server, &receipt)
            .err(),
        Some(Failure::Data(receiver::Failure::ScopeReview))
    );
    assert!(!other.path().join("Sync").exists());
}

#[test]
fn a_fresh_target_snapshot_and_cas_preserve_both_bodies_instead_of_using_an_old_scope_ancestor() {
    let (_temp, library, _) = setup();
    let key = fixtures::key();
    let scope = target_scope();
    let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
    let mut server = remote();
    let cloud = fixtures::envelope(1, "Public new cloud occupant", 100);
    server.add(&cloud);
    let new_version = server.records[&cloud.id].1.clone();
    let review = owner
        .prepare_account_review(&mut server, previous())
        .unwrap();
    owner.resume_account_review(&mut server, review).unwrap();
    owner.receive(&mut server, 4).unwrap();
    let sent = owner.send(&mut server, 4).unwrap();
    assert_eq!(sent.status, crate::sender::Status::Settled);
    assert!(server.fetched == vec![None]);
    assert!(
        server
            .submitted
            .iter()
            .flatten()
            .any(|(e, v)| e.id == cloud.id && v.as_ref() == Some(&new_version))
    );
    assert!(
        server
            .submitted
            .iter()
            .flatten()
            .all(|(_, v)| v.as_ref() != Some(&fixtures::version("old")))
    );
    let actual = Library::open(library.root.clone()).unwrap().snippets;
    assert_eq!(actual.len(), 2);
    assert!(
        actual
            .iter()
            .any(|s| s.content == "Public local intent" && !s.is_enabled)
    );
    assert!(
        actual
            .iter()
            .any(|s| s.content == "Public new cloud occupant")
    );
    let saved = Checkpoint::load(&library, &key, &fixtures::SALT, scope).unwrap();
    assert!(saved.journal.pending().unwrap().is_empty());
    assert!(saved.journal.conflict_snapshots().is_empty());
}

#[test]
fn fresh_vault_wrapping_is_part_of_the_confirmed_primary_generation() {
    for restart in [false, true] {
        let (_temp, library, _) = setup();
        let key = fixtures::key();
        let scope = target_scope();
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        let document =
            crate::vault::Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap())
                .unwrap();
        fs::create_dir(library.root.join("Vault")).unwrap();
        let path = library.root.join("Vault/vault.json");
        model::atomic_write(&path, &document.encode().unwrap()).unwrap();
        let owner = owner(&library, &key, &scope, 2, &|| Ok(()));
        let mut server = remote();
        let review = owner
            .prepare_account_review(&mut server, previous())
            .unwrap();
        let receipt = review.receipt();
        if restart {
            owner.stage_account_review(&mut server, &review).unwrap();
        }
        // Whitespace changes leave metadata and records equal but change the complete
        // file image under review. No wrapping or ciphertext is printed on failure.
        let mut changed = document.encode().unwrap();
        changed.push(b'\n');
        model::atomic_write(&path, &changed).unwrap();
        let old = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        let result = if restart {
            owner.continue_account_review(&mut server, &receipt)
        } else {
            owner.resume_account_review(&mut server, review)
        };
        assert_eq!(result.err(), Some(Failure::Changed));
        assert!(fs::read(library.root.join("Sync/journal.bin")).unwrap() == old);
        assert!(fs::read(path).unwrap() == changed);
    }
}
