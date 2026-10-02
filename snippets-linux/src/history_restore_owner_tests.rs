//! Actual saved owner receipts and full temporary files. No native keyring,
//! live PAM, server, application data or credentials are involved.
use super::*;
use crate::{
    key_store::{history, restoration as restore},
    primary,
    snapshot_review::tests::{envelope, write_primary},
};

#[path = "history_restore_deleted_tests.rs"]
mod deleted_participants;
#[path = "history_restore_foreign_tests.rs"]
mod foreign;

fn restored_setup() -> Setup {
    let mut s = setup();
    let reviewed = prepare(&mut s).unwrap();
    commit(&mut s, reviewed).unwrap();
    let library = Library::open(s.temp.path().into()).unwrap();
    write_primary(
        &library,
        &[
            envelope(1, "Public new current version", 8),
            envelope(2, "Public additional current record", 9),
        ],
    );
    s
}
fn review(s: &mut Setup) -> restore::Review {
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    restore::prepare(&mut s.store, selection, None).unwrap()
}
fn confirm(s: &mut Setup, review: restore::Review, fault: Option<u8>) -> restore::Result<()> {
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    restore::apply_with_fault(&mut s.store, review, permit, fault)
}
fn resume_restore(s: &mut Setup) -> restore::Result<()> {
    let (target, _) = restore::prepare_resume_authorization(&mut s.store, false)?;
    let (_gate, permit) = authorize(target);
    restore::resume(&mut s.store, permit)
}
fn read_journal(s: &mut Setup) -> Checkpoint {
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let library = Library::prepare(s.temp.path().into()).unwrap();
    Checkpoint::load(&library, &key, &salt, s.remote.pin.checkpoint_scope()).unwrap()
}
fn assert_restored(s: &mut Setup) {
    assert!(crate::primary::require_ready(s.temp.path()).is_ok());
    let library = Library::open(s.temp.path().into()).unwrap();
    let records = &library.snippets;
    assert!(
        records
            .iter()
            .any(|e| e.id == Uuid::from_u128(1) && e.content == "Public handover local entry")
    );
    assert!(
        records
            .iter()
            .any(|e| e.id == Uuid::from_u128(2) && e.content == "Public additional current record")
    );
    assert!(records.iter().any(|e| e.id != Uuid::from_u128(1)
        && e.content == "Public new current version"
        && !e.is_enabled));
    assert!(s.backend.memory.slot(Slot::HistoryRestore).is_some());
    assert!(crate::key_store::check_admission(&mut s.store, &s.remote.pin).is_ok());
}
fn capabilities(s: &Setup) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    [
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::CheckpointKey,
        Slot::AccountReview,
        Slot::PairingRecipient,
        Slot::SpaceCreation,
        Slot::KeyMutation,
        Slot::PairingCandidate,
        Slot::BootstrapCandidate,
    ]
    .into_iter()
    .map(|slot| s.backend.memory.slot(slot))
    .collect()
}

#[test]
fn restore_preserves_current_data_and_all_keys_without_importing_old_cloud_facts() {
    let mut s = restored_setup();
    let before = capabilities(&s);
    let journal = read_journal(&mut s).journal;
    let reviewed = review(&mut s);
    assert_eq!(reviewed.summary().restored_records, 1);
    assert_eq!(reviewed.summary().preserved_versions, 1);
    confirm(&mut s, reviewed, None).unwrap();
    assert_restored(&mut s);
    let after = read_journal(&mut s).journal;
    assert!(journal.preserves_transport_state(&after));
    assert!(capabilities(&s) == before);
    let protected = s.backend.memory.slot(Slot::HistoryRestore).unwrap();
    assert!(
        !protected
            .windows(b"Public new current version".len())
            .any(|w| w == b"Public new current version")
    );
    assert!(
        !protected
            .windows(b"Public handover local entry".len())
            .any(|w| w == b"Public handover local entry")
    );
    assert_eq!(
        std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
            .unwrap()
            .count(),
        4
    );
}

fn with_fixture<T>(
    s: &Setup,
    server: &mut crate::snapshot_review::tests::Server,
    run: impl FnOnce(&crate::receiver::Owner<'_>, &mut crate::snapshot_review::tests::Server) -> T,
) -> T {
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let library = Library::open(s.temp.path().into()).unwrap();
    let scope = s.remote.pin.checkpoint_scope();
    let wire_key = crate::snapshot_review::tests::key();
    let owner = crate::receiver::Owner {
        library: &library,
        scope: &scope,
        key_epoch: 2,
        checkpoint_key: &key,
        checkpoint_salt: &salt,
        wire_key: &wire_key,
        wire_salt: &crate::snapshot_review::tests::SALT,
        device: Some("11111111"),
        validate_session: &|| Ok(()),
    };
    run(&owner, server)
}
fn send_fixture(
    s: &Setup,
    server: &mut crate::snapshot_review::tests::Server,
    receive: bool,
) -> crate::sender::Progress {
    with_fixture(s, server, |owner, server| {
        if receive {
            assert_eq!(
                owner.receive(server, 2).unwrap().status,
                crate::receiver::Status::Current
            );
        }
        owner.send(server, 8).unwrap()
    })
}
fn nested_saved_setup(
    finish_current: bool,
) -> (
    Setup,
    crate::wire::Envelope,
    crate::wire::Envelope,
    crate::snapshot_review::tests::Server,
) {
    nested_saved_setup_with_generations(finish_current, 0)
}
fn nested_saved_setup_with_generations(
    finish_current: bool,
    archived_generations: usize,
) -> (
    Setup,
    crate::wire::Envelope,
    crate::wire::Envelope,
    crate::snapshot_review::tests::Server,
) {
    let mut s = setup();
    let library = Library::open(s.temp.path().into()).unwrap();
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let installed = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
    let mut checkpoint =
        Checkpoint::load(&library, &key, &salt, installed.binding.checkpoint_scope()).unwrap();
    let root = crate::merge::merge(
        None,
        Some(&envelope(1, "Public archived losing root", 1)),
        Some(&envelope(1, "Public archived selected root", 2)),
    )
    .unwrap();
    let source = root.survivor.unwrap();
    let c0 = root.conflict_copies[0].clone();
    let mut edit = c0.clone();
    edit.hlc = crate::clock::Hlc::foreign(20);
    edit.fields.as_mut().unwrap().content =
        Zeroizing::new(b"Public archived selected copy".to_vec());
    let child = crate::merge::merge(None, Some(&c0), Some(&edit)).unwrap();
    let c1 = child.survivor.unwrap();
    let d0 = child.conflict_copies[0].clone();
    let physical: std::collections::BTreeMap<_, _> = [&source, &c1, &d0]
        .into_iter()
        .map(|e| (e.id, e.clone()))
        .collect();
    write_primary(&library, &physical.values().cloned().collect::<Vec<_>>());
    checkpoint.journal.projected = physical.clone();
    checkpoint
        .journal
        .stage_conflict(&source, std::slice::from_ref(&c0))
        .unwrap();
    checkpoint
        .journal
        .stage_conflict(&c1, std::slice::from_ref(&d0))
        .unwrap();
    for e in physical.values() {
        checkpoint.journal.desire(e.clone()).unwrap();
    }
    // The archived pair includes a real old-scope ACK and an ambiguous C0 CAS.
    let offer = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&d0))
        .unwrap()
        .remove(0);
    checkpoint
        .journal
        .accept_offered(
            &offer,
            crate::snapshot_review::tests::version("public-archived-leaf-ack"),
        )
        .unwrap();
    checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&c0))
        .unwrap();
    checkpoint.save(&library, &key, &salt).unwrap();
    for n in 0..archived_generations {
        let physical = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
        let mut next = physical[&source.id].clone();
        next.hlc = crate::clock::Hlc::foreign(50 + n as u64);
        next.fields.as_mut().unwrap().content =
            Zeroizing::new(format!("Public archived queued version {n}").into_bytes());
        let outcome = crate::merge::merge(None, Some(&physical[&source.id]), Some(&next)).unwrap();
        let expected =
            primary::preservation_read_set(std::slice::from_ref(&outcome), &physical).unwrap();
        let prepared = primary::prepare(
            &library,
            &checkpoint.journal,
            "11111111",
            std::slice::from_ref(&outcome),
            &expected,
        )
        .unwrap();
        primary::commit(&library, &mut checkpoint, &key, &salt, prepared).unwrap();
        for e in outcome.survivor.into_iter().chain(outcome.conflict_copies) {
            checkpoint.journal.desire(e).unwrap();
        }
        checkpoint.save(&library, &key, &salt).unwrap();
    }
    let reviewed = prepare(&mut s).unwrap();
    commit(&mut s, reviewed).unwrap();
    // The archived encrypted generation keeps its old CAS/ACK. Test either a
    // finished current graph or a current graph with a lost leaf ACK.
    let mut server = crate::snapshot_review::tests::Server::new();
    server.scope = s.remote.pin.checkpoint_scope();
    server.feed = crate::inbound::Feed::new(Uuid::from_u128(9), 2).unwrap();
    if finish_current {
        let mut status = send_fixture(&s, &mut server, true).status;
        for _ in 0..3 {
            if status != crate::sender::Status::MoreBatches {
                break;
            }
            status = send_fixture(&s, &mut server, false).status;
        }
        assert_eq!(status, crate::sender::Status::Settled);
        assert!(read_journal(&mut s).journal.preservation_links().is_empty());
    } else {
        with_fixture(&s, &mut server, |owner, server| {
            assert_eq!(
                owner.receive(server, 2).unwrap().status,
                crate::receiver::Status::Current
            );
        });
        let mut current = read_journal(&mut s);
        let pending = current.journal.pending().unwrap();
        assert!(pending == vec![d0.clone()]);
        let offered = current.journal.mark_offered(&pending).unwrap().remove(0);
        let wire = crate::wire::WireRecord::seal(
            &offered.envelope,
            &crate::snapshot_review::tests::key(),
            &crate::snapshot_review::tests::SALT,
        )
        .unwrap();
        server.records.insert(
            wire.id,
            (
                wire.clone(),
                crate::snapshot_review::tests::version("lost-current-leaf-ACK"),
            ),
        );
        current.journal.outbound = Some(crate::outbound::Packet {
            key_epoch: 2,
            offers: vec![crate::outbound::Transmission {
                offered,
                wire,
                deletion_authorized: false,
            }],
            receipts: None,
            received_at: None,
            position: 0,
        });
        current.save(&library, &key, &salt).unwrap();
    }
    let mut later_root = source;
    later_root.hlc = crate::clock::Hlc::foreign(30);
    later_root.fields.as_mut().unwrap().content =
        Zeroizing::new(b"Public current root edit".to_vec());
    let mut later_copy = c1;
    later_copy.hlc = crate::clock::Hlc::foreign(31);
    later_copy.fields.as_mut().unwrap().content =
        Zeroizing::new(b"Public current copy edit".to_vec());
    let mut records =
        primary::current(&library, &read_journal(&mut s).journal, "11111111").unwrap();
    records.insert(later_root.id, later_root);
    records.insert(later_copy.id, later_copy);
    records.insert(d0.id, d0);
    write_primary(&library, &records.into_values().collect::<Vec<_>>());
    (s, c0, edit, server)
}

#[test]
fn protected_history_restores_all_archived_generations_beside_finished_or_inflight_current_work() {
    for finish_current in [true, false] {
        for fault in [None, Some(2), Some(7)] {
            let (mut s, _, _, mut server) = nested_saved_setup_with_generations(finish_current, 2);
            let before = read_journal(&mut s).journal;
            let previous_keys = capabilities(&s);
            let reviewed = review(&mut s);
            assert_eq!(reviewed.summary().restored_records, 5);
            assert_eq!(reviewed.summary().preserved_versions, 2);
            assert_eq!(confirm(&mut s, reviewed, fault).is_ok(), fault.is_none());
            if fault.is_some() {
                s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
                resume_restore(&mut s).unwrap();
            }
            let after = read_journal(&mut s).journal;
            assert!(before.preserves_transport_state(&after));
            assert!(capabilities(&s) == previous_keys);
            assert_eq!(
                Library::open(s.temp.path().into()).unwrap().snippets.len(),
                7
            );
            let start = server.submitted.len();
            let mut status = crate::sender::Status::MoreBatches;
            for _ in 0..6 {
                status = send_fixture(&s, &mut server, false).status;
                if status != crate::sender::Status::MoreBatches {
                    break;
                }
            }
            assert_eq!(status, crate::sender::Status::Settled);
            let roots: Vec<_> = server.submitted[start..]
                .iter()
                .flat_map(|batch| batch.iter())
                .filter(|(e, _)| e.id == Uuid::from_u128(1))
                .map(|(e, _)| e)
                .collect();
            let body_is = |e: &&crate::wire::Envelope, body: &[u8]| {
                e.fields.as_ref().unwrap().content.as_slice() == body
            };
            let first = roots
                .iter()
                .rposition(|e| body_is(e, b"Public archived selected root"))
                .unwrap();
            let second = roots
                .iter()
                .rposition(|e| body_is(e, b"Public archived queued version 0"))
                .unwrap();
            let last = roots
                .iter()
                .rposition(|e| body_is(e, b"Public archived queued version 1"))
                .unwrap();
            assert!(first < second && second < last);
            assert!(roots[last].hlc > roots[second].hlc);
            assert!(!read_journal(&mut s).journal.has_preservation_work());
        }
    }
}

#[test]
fn archived_generation_capacity_refusal_preserves_current_files_packet_and_all_capabilities() {
    let (mut s, _, _, _) = nested_saved_setup_with_generations(false, 4);
    let checkpoint_before = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
    let plain_before = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
    let previous_keys = capabilities(&s);
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    assert!(restore::prepare(&mut s.store, selection, None).is_err());
    assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint_before);
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == plain_before);
    assert!(capabilities(&s) == previous_keys);
    assert!(crate::primary::require_ready(s.temp.path()).is_ok());
}

#[test]
fn protected_history_restores_a_nested_c0_c1_group_without_importing_old_acknowledgements() {
    for fault in [None, Some(1), Some(2), Some(3), Some(7)] {
        let (mut s, original, selected, mut server) = nested_saved_setup(true);
        let before = capabilities(&s);
        let source = read_journal(&mut s).journal;
        let reviewed = review(&mut s);
        assert_eq!(reviewed.summary().restored_records, 3);
        assert_eq!(reviewed.summary().preserved_versions, 2);
        let result = confirm(&mut s, reviewed, fault);
        assert_eq!(result.is_ok(), fault.is_none());
        if fault.is_some() {
            s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
            resume_restore(&mut s).unwrap();
        }
        let checkpoint = read_journal(&mut s);
        assert!(source.preserves_transport_state(&checkpoint.journal));
        assert!(checkpoint.journal.conflict_snapshots()[&original.id] == original);
        let selected_now = &checkpoint.journal.entry(selected.id).unwrap().desired;
        assert!(
            selected_now.fields.as_ref().unwrap().content
                == selected.fields.as_ref().unwrap().content
        );
        assert!(selected_now.hlc > selected.hlc);
        assert!(selected_now != &original);
        assert!(
            checkpoint
                .journal
                .entry(selected.id)
                .unwrap()
                .offered
                .is_none()
        );
        assert!(capabilities(&s) == before);
        let physical = Library::open(s.temp.path().into()).unwrap().snippets;
        assert_eq!(physical.len(), 5);
        assert!(
            physical
                .iter()
                .any(|e| e.id == selected.id && e.content == "Public archived selected copy")
        );
        assert!(physical.iter().any(|e| e.id != selected.id
            && e.content == "Public current copy edit"
            && !e.is_enabled));
        // Neither archived/current C1 nor the archived leaf ACK releases C0.
        let pending = checkpoint.journal.pending().unwrap();
        assert!(
            !pending
                .iter()
                .any(|e| e.id == selected.id || e.id == Uuid::from_u128(1))
        );
        assert!(pending.len() >= 2);
        assert!(crate::primary::require_ready(s.temp.path()).is_ok());
        let start = server.submitted.len();
        assert_eq!(
            send_fixture(&s, &mut server, false).status,
            crate::sender::Status::Settled
        );
        let batches = &server.submitted[start..];
        let original_batch = batches
            .iter()
            .position(|batch| batch.iter().any(|(e, _)| e == &original))
            .unwrap();
        let parent_batch = batches
            .iter()
            .position(|batch| batch.iter().any(|(e, _)| e.id == Uuid::from_u128(1)))
            .unwrap();
        let edited_batch = batches
            .iter()
            .rposition(|batch| batch.iter().any(|(e, _)| e.id == selected.id))
            .unwrap();
        assert!(original_batch > 0 && original_batch < parent_batch && parent_batch < edited_batch);
        assert!(batches[original_batch].iter().all(|(_, cas)| cas.is_some()));
        assert!(!read_journal(&mut s).journal.has_preservation_work());
    }
}

#[test]
fn protected_history_overlaps_a_current_nested_graph_and_replays_the_original_lost_ack_packet() {
    for fault in [None, Some(1), Some(2), Some(3), Some(7)] {
        let (mut s, original, selected, mut server) = nested_saved_setup(false);
        let capabilities_before = capabilities(&s);
        let before = read_journal(&mut s).journal;
        let packet = before.outbound.clone().unwrap();
        let reviewed = review(&mut s);
        assert_eq!(reviewed.summary().restored_records, 3);
        assert_eq!(reviewed.summary().preserved_versions, 2);
        assert_eq!(confirm(&mut s, reviewed, fault).is_ok(), fault.is_none());
        if fault.is_some() {
            s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
            resume_restore(&mut s).unwrap();
        }
        let after = read_journal(&mut s).journal;
        assert!(before.preserves_transport_state(&after));
        assert!(after.outbound.as_ref() == Some(&packet));
        assert!(after.has_queued_generations());
        assert!(after.conflict_snapshots()[&original.id] == original);
        assert!(capabilities(&s) == capabilities_before);
        let physical = Library::open(s.temp.path().into()).unwrap().snippets;
        assert_eq!(physical.len(), 5);
        assert!(
            physical
                .iter()
                .any(|e| e.id == selected.id && e.content == "Public archived selected copy")
        );
        assert!(physical.iter().any(|e| e.id != selected.id
            && e.content == "Public current copy edit"
            && !e.is_enabled));
        let pending = after.pending().unwrap();
        assert!(pending == vec![packet.offers[0].offered.envelope.clone()]);
        assert!(crate::primary::require_ready(s.temp.path()).is_ok());
        let mut status = crate::sender::Status::MoreBatches;
        for _ in 0..4 {
            status = send_fixture(&s, &mut server, false).status;
            if status != crate::sender::Status::MoreBatches {
                break;
            }
        }
        assert_eq!(status, crate::sender::Status::Settled);
        assert!(
            server.submitted[0]
                == vec![(
                    packet.offers[0].offered.envelope.clone(),
                    packet.offers[0].offered.record_version.clone()
                )]
        );
        let parent_batches: Vec<_> = server
            .submitted
            .iter()
            .enumerate()
            .filter_map(|(n, batch)| {
                batch
                    .iter()
                    .any(|(e, _)| e.id == Uuid::from_u128(1))
                    .then_some(n)
            })
            .collect();
        assert!(parent_batches.len() >= 2 && parent_batches[0] < parent_batches[1]);
        assert!(!read_journal(&mut s).journal.has_preservation_work());
    }
}

#[test]
fn protected_history_restores_secure_nested_originals_with_borrowed_key_and_strict_cas_delivery() {
    secure_nested_restore(true, false);
}

#[test]
fn protected_history_queues_secure_originals_with_distinct_current_nonces_and_a_borrowed_key() {
    secure_nested_restore(false, false);
}

#[test]
fn protected_history_restores_archived_secure_generations_with_each_original_nonce_intact() {
    secure_nested_restore(true, true);
}

fn secure_nested_restore(finish_current: bool, archived_queue: bool) {
    let mut s = setup();
    let library = Library::open(s.temp.path().into()).unwrap();
    let doc = document();
    std::fs::create_dir(s.temp.path().join("Vault")).unwrap();
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &doc.encode().unwrap(),
    )
    .unwrap();
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let installed = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
    let mut checkpoint =
        Checkpoint::load(&library, &key, &salt, installed.binding.checkpoint_scope()).unwrap();
    let (outcomes, expected, original, selected, leaf) =
        crate::primary::tests::nested_secure_outcomes(&library, &checkpoint.journal, &doc);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let prepared = primary::prepare_authenticated(
        &library,
        &checkpoint.journal,
        "11111111",
        &outcomes,
        &expected,
        &crate::materializer::Keyring::new(&root, &doc).unwrap(),
    )
    .unwrap();
    primary::commit(&library, &mut checkpoint, &key, &salt, prepared).unwrap();
    for e in outcomes.iter().flat_map(|o| &o.conflict_copies) {
        checkpoint.journal.desire(e.clone()).unwrap();
    }
    for e in outcomes.iter().filter_map(|o| o.survivor.as_ref()) {
        checkpoint.journal.desire(e.clone()).unwrap();
    }
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&leaf))
        .unwrap()
        .remove(0);
    checkpoint
        .journal
        .accept_offered(
            &offered,
            crate::snapshot_review::tests::version("public-old-secure-leaf"),
        )
        .unwrap();
    checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&original))
        .unwrap();
    checkpoint.save(&library, &key, &salt).unwrap();
    let queued_original = if archived_queue {
        let physical = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
        let mut next = physical[&doc.records[0].metadata.id].clone();
        next.hlc = crate::clock::Hlc::foreign(0xffff_0000_0010);
        next.fields.as_mut().unwrap().name = "Public archived queued root title".into();
        let keys = crate::materializer::Keyring::new(&root, &doc).unwrap();
        let fresh = crate::materializer::Evidence::prepare(
            std::slice::from_ref(&next),
            &keys,
            &std::collections::BTreeMap::new(),
        )
        .unwrap()
        .copies()[&original.id]
            .clone();
        assert!(fresh != original);
        let outcome = crate::merge::Outcome {
            survivor: Some(next),
            conflict_copies: vec![fresh.clone()],
        };
        let expected =
            primary::preservation_read_set(std::slice::from_ref(&outcome), &physical).unwrap();
        let prepared = primary::prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            std::slice::from_ref(&outcome),
            &expected,
            &keys,
        )
        .unwrap();
        primary::commit(&library, &mut checkpoint, &key, &salt, prepared).unwrap();
        for target in primary::current(&library, &checkpoint.journal, "11111111")
            .unwrap()
            .values()
        {
            checkpoint.journal.desire(target.clone()).unwrap();
        }
        checkpoint.save(&library, &key, &salt).unwrap();
        Some(fresh)
    } else {
        None
    };
    let reviewed = prepare(&mut s).unwrap();
    commit(&mut s, reviewed).unwrap();
    let mut server = crate::snapshot_review::tests::Server::new();
    server.scope = s.remote.pin.checkpoint_scope();
    server.feed = crate::inbound::Feed::new(Uuid::from_u128(9), 2).unwrap();
    let current_original = if finish_current {
        let mut status = send_fixture(&s, &mut server, true).status;
        for _ in 0..3 {
            if status != crate::sender::Status::MoreBatches {
                break;
            }
            status = send_fixture(&s, &mut server, false).status;
        }
        assert_eq!(status, crate::sender::Status::Settled);
        assert!(!read_journal(&mut s).journal.has_preservation_work());
        None
    } else {
        with_fixture(&s, &mut server, |owner, server| {
            assert_eq!(
                owner.receive(server, 2).unwrap().status,
                crate::receiver::Status::Current
            );
        });
        let mut current = read_journal(&mut s);
        let data = current.journal.preservation_data();
        let sources: Vec<_> = data.values().map(|(e, _)| e.clone()).collect();
        let evidence = crate::materializer::Evidence::prepare(
            &sources,
            &crate::materializer::Keyring::new(&root, &doc).unwrap(),
            &std::collections::BTreeMap::new(),
        )
        .unwrap();
        let fresh_original = evidence.copies()[&original.id].clone();
        assert!(fresh_original != original);
        let mut independent = crate::journal::Journal::new(s.remote.pin.checkpoint_scope());
        independent.key_epoch = Some(2);
        independent.inbox = current.journal.inbox.clone();
        independent.projected = current.journal.projected.clone();
        for source in &sources {
            independent.stage_conflict(source, &[]).unwrap();
        }
        for copy in evidence.copies().values() {
            independent.freeze_authenticated_copy(copy).unwrap();
        }
        for target in current.journal.projected.values() {
            independent.desire(target.clone()).unwrap();
        }
        current.journal = independent;
        current.save(&library, &key, &salt).unwrap();
        Some(fresh_original)
    };
    let mut live = crate::vault::read_document(s.temp.path()).unwrap().unwrap();
    let copied = live
        .records
        .iter_mut()
        .find(|r| r.metadata.id == selected.id)
        .unwrap();
    let later = b"Public later nested secure copy body";
    copied.metadata.name = "Public later nested secure copy title".into();
    copied.metadata.updated_at += chrono::Duration::seconds(1);
    copied.sealed = crate::crypto::seal_record(
        later,
        &root,
        &doc.salt().unwrap(),
        &doc.kid,
        selected.id,
        false,
    )
    .unwrap();
    copied.content_hash = crate::crypto::content_hash(later, &root, &doc.salt().unwrap());
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &live.encode().unwrap(),
    )
    .unwrap();
    let mut vault = unlock(&s, &live);
    let before = read_journal(&mut s).journal;
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    let reviewed = restore::prepare(&mut s.store, selection, Some(&mut vault)).unwrap();
    assert_eq!(reviewed.summary().restored_records, 3);
    assert!(reviewed.summary().secure_records >= 2);
    assert!(confirm(&mut s, reviewed, Some(2)).is_err());
    drop(vault);
    s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
    resume_restore(&mut s).unwrap();
    let after = read_journal(&mut s).journal;
    assert!(before.preserves_transport_state(&after));
    if let Some(current_original) = &current_original {
        assert!(after.conflict_snapshots()[&original.id] == *current_original);
        assert!(after.has_queued_generations());
    } else {
        assert!(after.conflict_snapshots()[&original.id] == original); // Original nonce too.
    }
    let live = crate::vault::read_document(s.temp.path()).unwrap().unwrap();
    let mut vault = unlock(&s, &live);
    assert!(vault.body(selected.id).unwrap().as_slice() == b"Public selected secure C1 body");
    let retained = live
        .records
        .iter()
        .find(|r| r.metadata.id != selected.id)
        .unwrap();
    assert!(vault.body(retained.metadata.id).unwrap().as_slice() == later);
    vault.lock();
    let start = server.submitted.len();
    let mut status = crate::sender::Status::MoreBatches;
    for _ in 0..4 {
        status = send_fixture(&s, &mut server, false).status;
        if status != crate::sender::Status::MoreBatches {
            break;
        }
    }
    assert_eq!(status, crate::sender::Status::Settled);
    let batches = &server.submitted[start..];
    let original_batch = batches
        .iter()
        .position(|b| b.iter().any(|(e, _)| e == &original))
        .unwrap();
    let parent_batch = batches
        .iter()
        .rposition(|b| b.iter().any(|(e, _)| e.id == doc.records[0].metadata.id))
        .unwrap();
    let selected_batch = batches
        .iter()
        .rposition(|b| b.iter().any(|(e, _)| e.id == selected.id))
        .unwrap();
    assert!(original_batch > 0 && original_batch < parent_batch && parent_batch < selected_batch);
    if let Some(current_original) = current_original {
        let current_batch = batches
            .iter()
            .position(|b| b.iter().any(|(e, _)| e == &current_original))
            .unwrap();
        assert!(current_batch < original_batch);
        assert!(
            batches[original_batch]
                .iter()
                .filter(|(e, _)| e.id == original.id)
                .all(|(_, cas)| cas.is_some())
        );
    }
    if let Some(queued_original) = queued_original {
        let queued_batch = batches
            .iter()
            .position(|b| b.iter().any(|(e, _)| e == &queued_original))
            .unwrap();
        assert!(original_batch < queued_batch && queued_batch < selected_batch);
    }
    assert!(!read_journal(&mut s).journal.has_preservation_work());
}

#[test]
fn each_durable_boundary_can_finish_after_restart_with_a_fresh_exact_purpose() {
    for point in [0, 1, 2, 3, 4, 7] {
        let mut s = restored_setup();
        let before = capabilities(&s);
        let reviewed = review(&mut s);
        assert!(confirm(&mut s, reviewed, Some(point)).is_err());
        assert!(crate::key_store::check_admission(&mut s.store, &s.remote.pin).is_err());
        s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
        let (target, _) = restore::prepare_resume_authorization(&mut s.store, false).unwrap();
        assert_eq!(target.purpose(), Purpose::ResumeSavedChanges);
        let (_gate, permit) = authorize(target);
        restore::resume(&mut s.store, permit).unwrap();
        assert_restored(&mut s);
        assert!(capabilities(&s) == before);
    }
}

#[test]
fn lost_protected_write_replies_preserve_owned_data_and_allow_retry() {
    for step in 1..=2 {
        for after in [false, true] {
            let mut s = restored_setup();
            let reviewed = review(&mut s);
            let primary_before = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
            s.backend.arm(step, after);
            assert!(confirm(&mut s, reviewed, None).is_err());
            s.backend.arm(usize::MAX, false);
            s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
            if step == 1 && !after {
                assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
                assert!(
                    std::fs::read(s.temp.path().join("snippets.json")).unwrap() == primary_before
                );
                let reviewed = review(&mut s);
                confirm(&mut s, reviewed, None).unwrap();
            } else {
                resume_restore(&mut s).unwrap();
            }
            assert_restored(&mut s);
        }
    }
}

#[test]
fn stale_native_selection_and_primary_or_protected_frames_require_new_review() {
    for kind in 0..3 {
        let mut s = restored_setup();
        let reviewed = review(&mut s);
        let initial = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
        if kind == 0 {
            let library = Library::open(s.temp.path().into()).unwrap();
            write_primary(&library, &[envelope(1, "Public racing local version", 20)]);
        } else {
            s.store
                .transaction(|owner| {
                    let slot = if kind == 1 {
                        Slot::AccountReview
                    } else {
                        Slot::PairingCandidate
                    };
                    let before = owner.read(slot)?;
                    let changed = if kind == 1 {
                        let mut bytes = before.as_ref().unwrap().to_vec();
                        bytes.push(b' ');
                        bytes
                    } else {
                        b"Public later protected candidate".to_vec()
                    };
                    owner.replace(slot, before.as_deref().map(Vec::as_slice), Some(&changed))
                })
                .unwrap();
        }
        assert!(confirm(&mut s, reviewed, None).is_err());
        assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
        assert_eq!(
            std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
                .unwrap()
                .count(),
            2
        );
        if kind != 0 {
            assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == initial);
        }
    }
}

#[test]
fn unpublished_cancel_keeps_later_local_edits_and_published_restore_cannot_cancel() {
    for point in [0, 1, 7] {
        let mut s = restored_setup();
        let reviewed = review(&mut s);
        assert!(confirm(&mut s, reviewed, Some(point)).is_err());
        if point == 1 {
            assert!(restore::prepare_resume_authorization(&mut s.store, true).is_err());
            resume_restore(&mut s).unwrap();
            assert_restored(&mut s);
        } else {
            let late = envelope(1, "Public later edit kept on cancellation", 30);
            // Simulate a noncooperative writer / a pre-marker ordinary writer.
            let bytes =
                crate::model::encode_library(&[late.snippet().unwrap().unwrap()], false).unwrap();
            std::fs::write(s.temp.path().join("snippets.json"), &bytes).unwrap();
            let (target, _) = restore::prepare_resume_authorization(&mut s.store, true).unwrap();
            let (_gate, permit) = authorize(target);
            restore::cancel(&mut s.store, permit).unwrap();
            assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == bytes);
            assert!(crate::primary::require_ready(s.temp.path()).is_ok());
            assert!(crate::key_store::check_admission(&mut s.store, &s.remote.pin).is_ok());
        }
    }
}

#[test]
fn revoked_or_wrong_purpose_permit_cannot_publish_data_or_receipts() {
    for kind in 0..2 {
        let mut s = restored_setup();
        let reviewed = review(&mut s);
        let target = if kind == 0 {
            reviewed.authorization_target().unwrap()
        } else {
            Target::new(s.remote.pin.clone(), Purpose::SwitchLibrary, 1, [0x55; 32]).unwrap()
        };
        let (mut gate, permit) = authorize(target);
        if kind == 0 {
            gate.cancel();
        }
        assert!(restore::apply(&mut s.store, reviewed, permit).is_err());
        assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
        assert_eq!(
            std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
                .unwrap()
                .count(),
            2
        );
    }
}

#[test]
fn corrupted_retained_or_advanced_active_state_never_replays_frozen_restore() {
    for kind in 0..3 {
        let mut s = restored_setup();
        let reviewed = review(&mut s);
        assert!(confirm(&mut s, reviewed, Some(7)).is_err());
        if kind == 0 {
            let files = std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
                .unwrap()
                .map(|e| e.unwrap().path())
                .collect::<Vec<_>>();
            for path in files {
                let mut bytes = std::fs::read(&path).unwrap();
                bytes[100] ^= 1;
                std::fs::write(path, bytes).unwrap();
            }
        } else if kind == 1 {
            let mut current = read_journal(&mut s);
            current
                .journal
                .desire(envelope(3, "Public later journal intent", 22))
                .unwrap();
            let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
            let key = RootKey::from_bytes(&material[..32]).unwrap();
            let salt = material[32..].try_into().unwrap();
            let library = Library::prepare(s.temp.path().into()).unwrap();
            current.save(&library, &key, &salt).unwrap();
        } else {
            std::fs::write(
                s.temp.path().join("snippets.json"),
                b"Public invalid racing storage",
            )
            .unwrap();
        }
        let before = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
        assert!(resume_restore(&mut s).is_err());
        assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == before);
        assert!(s.backend.memory.slot(Slot::HistoryRestore).is_some());
    }
}

fn document() -> crate::vault::Document {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    crate::vault::Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap()
}
fn secure_setup() -> (Setup, crate::vault::Document) {
    let mut s = setup();
    let doc = document();
    std::fs::create_dir(s.temp.path().join("Vault")).unwrap();
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &doc.encode().unwrap(),
    )
    .unwrap();
    let reviewed = prepare(&mut s).unwrap();
    commit(&mut s, reviewed).unwrap();
    let mut live = doc.clone();
    let key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let salt = live.salt().unwrap();
    let id = live.records[0].metadata.id;
    live.records[0].metadata.name = "Public later secure title".into();
    live.records[0].metadata.updated_at += chrono::Duration::seconds(1);
    let body = b"Public later secure body";
    live.records[0].sealed =
        crate::crypto::seal_record(body, &key, &salt, &live.kid, id, false).unwrap();
    live.records[0].content_hash = crate::crypto::content_hash(body, &key, &salt);
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &live.encode().unwrap(),
    )
    .unwrap();
    (s, live)
}
fn unlock(s: &Setup, document: &crate::vault::Document) -> crate::vault::Vault {
    let library = Library::open(s.temp.path().into()).unwrap();
    let mut vault = crate::vault::Vault::open(&library).unwrap();
    let authentication = document.authenticate("Café public fixture", false).unwrap();
    vault
        .finish_authentication(authentication, vault.generation())
        .unwrap();
    vault
}

#[test]
fn secure_restore_authenticates_all_versions_and_reseals_current_copy_before_any_write() {
    let (mut s, live) = secure_setup();
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    let before = std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap();
    assert!(matches!(
        restore::prepare(&mut s.store, selection.clone(), None),
        Err(restore::Failure::Primary(
            crate::primary::Failure::VaultLocked
        ))
    ));
    assert!(std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap() == before);
    assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
    let mut vault = unlock(&s, &live);
    let reviewed = restore::prepare(&mut s.store, selection, Some(&mut vault)).unwrap();
    assert_eq!(reviewed.summary().secure_records, 1);
    assert_eq!(reviewed.summary().preserved_versions, 1);
    assert!(confirm(&mut s, reviewed, Some(2)).is_err());
    drop(vault);
    s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
    resume_restore(&mut s).unwrap();
    let after = crate::vault::read_document(s.temp.path()).unwrap().unwrap();
    let mut before_header = live.clone();
    before_header.records.clear();
    let mut after_header = after.clone();
    after_header.records.clear();
    assert!(before_header == after_header);
    assert_eq!(after.records.len(), 2);
    let mut vault = unlock(&s, &after);
    let id = document().records[0].metadata.id;
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    assert!(
        vault.body(id).unwrap().as_slice() == fixture["plaintext"].as_str().unwrap().as_bytes()
    );
    let copy = after
        .records
        .iter()
        .find(|record| record.metadata.id != id)
        .unwrap();
    assert!(!copy.metadata.is_enabled && copy.metadata.keyword.is_empty());
    assert!(vault.body(copy.metadata.id).unwrap().as_slice() == b"Public later secure body");
    assert!(crate::primary::require_ready(s.temp.path()).is_ok());
}

#[test]
fn changed_vault_salt_or_bad_current_seal_refuses_the_entire_restoration() {
    for kind in 0..2 {
        let (mut s, mut live) = secure_setup();
        if kind == 0 {
            live.vault_salt = crate::crypto::b64(&[0x55; 32]);
        } else {
            live.records[0].content_hash = "00000000000000000000000000000000".into();
        }
        crate::model::atomic_write(
            &s.temp.path().join("Vault/vault.json"),
            &live.encode().unwrap(),
        )
        .unwrap();
        let selection = history::inspect(&mut s.store).unwrap().switches[0]
            .selection
            .clone();
        let plain_before = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
        let sealed_before = std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap();
        let mut vault = unlock(&s, &live);
        assert!(restore::prepare(&mut s.store, selection, Some(&mut vault)).is_err());
        assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == plain_before);
        assert!(std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap() == sealed_before);
        assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
    }
}

#[test]
fn full_image_budget_is_checked_before_a_receipt_or_primary_publication() {
    let mut s = restored_setup();
    let reviewed = review(&mut s);
    let primary = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
    let checkpoint = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
    let directory = s.temp.path().join("Sync/Reviews");
    for index in 1..=30 {
        let path = directory.join(format!("{index:032x}.source"));
        crate::model::atomic_write(&path, b"Public retained image capacity fixture").unwrap();
    }
    assert!(matches!(
        confirm(&mut s, reviewed, None),
        Err(restore::Failure::History(
            crate::account_review::Failure::RetentionFull
        ))
    ));
    assert!(s.backend.memory.slot(Slot::HistoryRestore).is_none());
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == primary);
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
    assert_eq!(std::fs::read_dir(directory).unwrap().count(), 32);
}

#[test]
fn exhausted_receipt_generation_refuses_new_consent_before_images_or_primary_change() {
    let mut s = restored_setup();
    let reviewed = review(&mut s);
    confirm(&mut s, reviewed, None).unwrap();
    s.store
        .transaction(|owner| {
            let bytes = owner.read(Slot::HistoryRestore)?.unwrap();
            let mut value = canonical::parse(&bytes).unwrap();
            let Value::Object(ref mut fields) = value else {
                unreachable!()
            };
            fields.insert("generation".into(), Value::Int(i64::MAX));
            owner.replace(
                Slot::HistoryRestore,
                Some(&bytes),
                Some(&value.encode().unwrap()),
            )
        })
        .unwrap();
    let library = Library::open(s.temp.path().into()).unwrap();
    write_primary(&library, &[envelope(1, "Public next local version", 30)]);
    let before = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
    let receipt = s.backend.memory.slot(Slot::HistoryRestore).unwrap();
    let selection = history::inspect(&mut s.store).unwrap().switches[0]
        .selection
        .clone();
    assert!(matches!(
        restore::prepare(&mut s.store, selection, None),
        Err(restore::Failure::RetentionFull)
    ));
    assert!(s.backend.memory.slot(Slot::HistoryRestore).as_deref() == Some(&receipt));
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == before);
    assert_eq!(
        std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
            .unwrap()
            .count(),
        4
    );
}

#[test]
fn current_exact_offer_cas_and_feed_survive_a_real_owned_restoration() {
    let mut s = restored_setup();
    let mut current = read_journal(&mut s);
    let live = envelope(1, "Public new current version", 8);
    current
        .journal
        .record_confirmed(
            envelope(1, "Public current confirmed version", 6),
            crate::snapshot_review::tests::version("public-current-cas"),
        )
        .unwrap();
    current.journal.desire(live.clone()).unwrap();
    let offers = current
        .journal
        .mark_offered(std::slice::from_ref(&live))
        .unwrap();
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let library = Library::prepare(s.temp.path().into()).unwrap();
    current.save(&library, &key, &salt).unwrap();
    let before = current.journal.clone();
    let reviewed = review(&mut s);
    confirm(&mut s, reviewed, None).unwrap();
    let after = read_journal(&mut s).journal;
    assert!(before.preserves_transport_state(&after));
    assert!(after.entry(live.id).unwrap().offered.as_ref() == Some(&offers[0]));
    assert!(
        after
            .entry(live.id)
            .unwrap()
            .desired
            .fields
            .as_ref()
            .unwrap()
            .content
            .as_slice()
            == b"Public handover local entry"
    );
}

#[cfg(feature = "desktop")]
#[test]
fn lost_native_reply_keeps_durable_restore_ownership_without_a_volatile_quit_barrier() {
    use crate::account_worker::{Command, Failure as AccountFailure, Handle, Reply};
    for interrupted in [false, true] {
        let mut s = restored_setup();
        let reviewed = review(&mut s);
        let (_gate, permit) = authorize(reviewed.authorization_target().unwrap());
        let token = Uuid::new_v4();
        let mut reviewed = Some(reviewed);
        let worker = Handle::controlled(move |command| {
            let result = match command {
                Command::CommitRestoration {
                    token: actual,
                    permit,
                } => {
                    assert_eq!(actual, token);
                    restore::apply_with_fault(
                        &mut s.store,
                        reviewed.take().unwrap(),
                        permit,
                        if interrupted { Some(2) } else { None },
                    )
                    .map(|_| Reply::Restored {
                        failure: None,
                        cancelled: false,
                    })
                    .map_err(AccountFailure::from)
                }
                Command::InspectHistory => history::inspect(&mut s.store)
                    .map(Reply::History)
                    .map_err(AccountFailure::from),
                Command::PrepareRestorationResume(cancel) => {
                    restore::prepare_resume_review(&mut s.store, cancel)
                        .map(|review| Reply::RestorationReview {
                            token: None,
                            summary: review.summary,
                            target: review.target,
                            saved: review.saved,
                            current: review.current,
                            rekeyed: false,
                        })
                        .map_err(AccountFailure::from)
                }
                Command::FinishRestoration {
                    cancel: false,
                    permit,
                } => restore::resume(&mut s.store, permit)
                    .map(|_| {
                        assert_restored(&mut s);
                        Reply::Restored {
                            failure: None,
                            cancelled: false,
                        }
                    })
                    .map_err(AccountFailure::from),
                _ => Err(AccountFailure::InvalidState),
            };
            (result, false)
        });
        drop(
            worker
                .request(Command::CommitRestoration { token, permit })
                .unwrap(),
        );
        let Reply::History(saved) = worker
            .request(Command::InspectHistory)
            .unwrap()
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap()
            .unwrap()
        else {
            panic!("Expected safe restoration metadata")
        };
        assert_eq!(saved.restorations.len(), 1);
        assert_eq!(saved.restorations[0].needs_completion, interrupted);
        assert!(worker.can_quit() && !worker.retention_required());
        if interrupted {
            let Reply::RestorationReview { target, .. } = worker
                .request(Command::PrepareRestorationResume(false))
                .unwrap()
                .recv_timeout(std::time::Duration::from_secs(10))
                .unwrap()
                .unwrap()
            else {
                panic!("Expected exact completion purpose")
            };
            let (_fresh, permit) = authorize(target);
            let Reply::Restored { failure: None, .. } = worker
                .request(Command::FinishRestoration {
                    cancel: false,
                    permit,
                })
                .unwrap()
                .recv_timeout(std::time::Duration::from_secs(10))
                .unwrap()
                .unwrap()
            else {
                panic!("Expected completed retained restoration")
            };
        }
    }
}

#[test]
fn malformed_protected_restore_schema_fences_admission_and_history_without_touching_data() {
    for kind in 0..7 {
        let mut s = restored_setup();
        let reviewed = review(&mut s);
        confirm(&mut s, reviewed, None).unwrap();
        let primary = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
        let journal = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
        s.store
            .transaction(|owner| {
                let bytes = owner.read(Slot::HistoryRestore)?.unwrap();
                let mut value = canonical::parse(&bytes).unwrap();
                let Value::Object(ref mut fields) = value else {
                    unreachable!()
                };
                match kind {
                    0 => {
                        fields.insert("unexpected".into(), Value::Bool(true));
                    }
                    1 => {
                        fields.insert("schema".into(), Value::Int(2));
                    }
                    2 => {
                        fields.insert("generation".into(), Value::Int(-1));
                    }
                    3 => {
                        fields.insert("entries".into(), Value::Array(vec![]));
                    }
                    _ => {
                        let Value::Array(ref mut entries) = *fields.get_mut("entries").unwrap()
                        else {
                            unreachable!()
                        };
                        if kind == 4 {
                            entries.push(entries[0].clone());
                        } else {
                            let Value::Object(ref mut entry) = entries[0] else {
                                unreachable!()
                            };
                            entry.insert(
                                if kind == 5 { "phase" } else { "nonce" }.into(),
                                Value::text(if kind == 5 { "unknown" } else { "AA==" }),
                            );
                        }
                    }
                }
                owner.replace(
                    Slot::HistoryRestore,
                    Some(&bytes),
                    Some(&value.encode().unwrap()),
                )
            })
            .unwrap();
        assert!(crate::key_store::check_admission(&mut s.store, &s.remote.pin).is_err());
        assert!(history::inspect(&mut s.store).is_err());
        assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == primary);
        assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == journal);
    }
}
