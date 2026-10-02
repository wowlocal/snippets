//! Full owner/WAL and strict CAS delivery between two fictional vault roots.
use super::*;
use crate::{
    canonical::Value,
    crypto,
    journal::Journal,
    materializer::{Evidence, Keyring},
    merge,
    vault::{Document, Record, Vault},
    wire::Envelope,
};
use std::collections::BTreeMap;
const CURRENT_PASSPHRASE: &str = "Public current vault passphrase";

#[cfg(feature = "desktop")]
#[path = "account_restoration_owner_tests.rs"]
mod desktop_workflow;

#[path = "history_restore_source_file_tests.rs"]
mod external_source;

#[path = "history_restore_legacy_tests.rs"]
mod legacy_metadata;

struct Saved {
    setup: Setup,
    current: Document,
    original: Envelope,
    selected: Envelope,
    server: crate::snapshot_review::tests::Server,
}
fn unlock_current(s: &Setup, doc: &Document) -> Vault {
    let library = Library::open(s.temp.path().into()).unwrap();
    let mut vault = Vault::open(&library).unwrap();
    vault
        .finish_authentication(
            doc.authenticate(CURRENT_PASSPHRASE, false).unwrap(),
            vault.generation(),
        )
        .unwrap();
    vault
}
fn saved(queued: bool) -> Saved {
    let mut s = setup();
    let library = Library::open(s.temp.path().into()).unwrap();
    let old = document();
    std::fs::create_dir(s.temp.path().join("Vault")).unwrap();
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &old.encode().unwrap(),
    )
    .unwrap();
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let checkpoint_key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let installed = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
    let mut checkpoint = Checkpoint::load(
        &library,
        &checkpoint_key,
        &salt,
        installed.binding.checkpoint_scope(),
    )
    .unwrap();
    let (mut outcomes, _, original, mut selected, _) =
        primary::tests::nested_secure_outcomes(&library, &checkpoint.journal, &old);
    let old_key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let old_keys = Keyring::new(&old_key, &old).unwrap();
    // An edited secure child carries a further secure loser. Neither its own
    // selected C1 nor its parent's C0 may be used as that grandchild's original.
    let mut losing = selected.clone();
    losing.hlc = crate::clock::Hlc::foreign(0xffff_0000_0001);
    let body = b"Public archived secure grandchild original";
    losing.fields.as_mut().unwrap().content = Zeroizing::new(
        crypto::seal_record(
            body,
            &old_key,
            &old.salt().unwrap(),
            &old.kid,
            losing.id,
            false,
        )
        .unwrap()
        .text()
        .as_bytes()
        .to_vec(),
    );
    losing.extensions.insert(
        "vaultContentHash".into(),
        Value::text(crypto::content_hash(body, &old_key, &old.salt().unwrap())),
    );
    selected = merge::merge(None, Some(&losing), Some(&selected))
        .unwrap()
        .survivor
        .unwrap();
    outcomes[1].survivor = Some(selected.clone());
    let physical = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
    let expected = primary::preservation_read_set(&outcomes, &physical).unwrap();
    let prepared = primary::prepare_authenticated(
        &library,
        &checkpoint.journal,
        "11111111",
        &outcomes,
        &expected,
        &old_keys,
    )
    .unwrap();
    primary::commit(&library, &mut checkpoint, &checkpoint_key, &salt, prepared).unwrap();
    for copy in outcomes.iter().flat_map(|outcome| &outcome.conflict_copies) {
        checkpoint.journal.desire(copy.clone()).unwrap();
    }
    for target in outcomes
        .iter()
        .filter_map(|outcome| outcome.survivor.as_ref())
    {
        checkpoint.journal.desire(target.clone()).unwrap();
    }
    // The archive carries a real old offer; restoration imports data only.
    checkpoint
        .journal
        .mark_offered(&checkpoint.journal.pending().unwrap())
        .unwrap();
    checkpoint.save(&library, &checkpoint_key, &salt).unwrap();
    if queued {
        let physical = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
        let mut later = physical[&old.records[0].metadata.id].clone();
        later.hlc = crate::clock::Hlc::foreign(0xffff_0000_0010);
        later.fields.as_mut().unwrap().name = "Public archived queued parent".into();
        let fresh = Evidence::prepare(std::slice::from_ref(&later), &old_keys, &BTreeMap::new())
            .unwrap()
            .copies()[&original.id]
            .clone();
        assert!(fresh != original);
        let outcome = merge::Outcome {
            survivor: Some(later),
            conflict_copies: vec![fresh],
        };
        let expected =
            primary::preservation_read_set(std::slice::from_ref(&outcome), &physical).unwrap();
        let prepared = primary::prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            std::slice::from_ref(&outcome),
            &expected,
            &old_keys,
        )
        .unwrap();
        primary::commit(&library, &mut checkpoint, &checkpoint_key, &salt, prepared).unwrap();
        for target in primary::current(&library, &checkpoint.journal, "11111111")
            .unwrap()
            .values()
        {
            checkpoint.journal.desire(target.clone()).unwrap();
        }
        assert!(
            checkpoint
                .journal
                .entry(selected.id)
                .unwrap()
                .desired
                .fields
                .as_ref()
                .unwrap()
                .content
                == selected.fields.as_ref().unwrap().content
        );
        checkpoint.save(&library, &checkpoint_key, &salt).unwrap();
    }
    let review = prepare(&mut s).unwrap();
    commit(&mut s, review).unwrap();

    let mut current = old.clone();
    current.kid = "Public replacement vault".into();
    current.vault_salt = crypto::b64(&[0x55; 32]);
    current.records.clear();
    let root = RootKey::from_bytes(&[0x44; 32]).unwrap();
    let (kdf, wrap) =
        crypto::wrap_passphrase_cost(&root, CURRENT_PASSPHRASE, &current.kid, 1).unwrap();
    current.kdf = kdf;
    current.wrap_pass = Some(wrap);
    current.wrap_recovery = None;
    current.wrap_cli = None;
    let mut metadata = old.records[0].metadata.clone();
    metadata.name = "Public current independent protected version".into();
    metadata.updated_at += chrono::Duration::seconds(1);
    let body = b"Public current independently protected body";
    current.records.push(Record {
        metadata,
        sealed: crypto::seal_record(
            body,
            &root,
            &current.salt().unwrap(),
            &current.kid,
            old.records[0].metadata.id,
            false,
        )
        .unwrap(),
        content_hash: crypto::content_hash(body, &root, &current.salt().unwrap()),
        hlc: Some(crate::clock::Hlc::foreign(30)),
        extra: BTreeMap::new(),
    });
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &current.encode().unwrap(),
    )
    .unwrap();
    write_primary(
        &library,
        &[
            envelope(1, "Public later current ordinary body", 30),
            envelope(2, "Public current lost reply", 31),
        ],
    );
    let mut checkpoint = read_journal(&mut s);
    let inbox = checkpoint.journal.inbox.clone();
    checkpoint.journal = Journal::new(s.remote.pin.checkpoint_scope());
    checkpoint.journal.key_epoch = Some(2);
    checkpoint.journal.inbox = inbox;
    let physical = primary::current(&library, &checkpoint.journal, "11111111").unwrap();
    checkpoint.journal.projected = physical.clone();
    for target in physical.values() {
        checkpoint.journal.desire(target.clone()).unwrap();
    }
    let mut server = crate::snapshot_review::tests::Server::new();
    server.scope = s.remote.pin.checkpoint_scope();
    server.feed = Feed::new(Uuid::from_u128(9), 2).unwrap();
    checkpoint.save(&library, &checkpoint_key, &salt).unwrap();
    // Normal delivery requires the target's initial snapshot before a packet
    // can be offered. Do not manufacture an impossible pre-snapshot offer.
    with_fixture(&s, &mut server, |owner, server| {
        assert_eq!(
            owner.receive(server, 2).unwrap().status,
            crate::receiver::Status::Current
        );
    });
    let mut checkpoint = read_journal(&mut s);
    let offer = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&physical[&Uuid::from_u128(2)]))
        .unwrap()
        .remove(0);
    let wire = crate::wire::WireRecord::seal(
        &offer.envelope,
        &crate::snapshot_review::tests::key(),
        &crate::snapshot_review::tests::SALT,
    )
    .unwrap();
    server.records.insert(
        wire.id,
        (
            wire.clone(),
            crate::snapshot_review::tests::version("Public current lost-reply acceptance"),
        ),
    );
    checkpoint.journal.outbound = Some(crate::outbound::Packet {
        key_epoch: 2,
        offers: vec![crate::outbound::Transmission {
            offered: offer,
            wire,
            deletion_authorized: false,
        }],
        receipts: None,
        received_at: None,
        position: 0,
    });
    checkpoint.save(&library, &checkpoint_key, &salt).unwrap();
    Saved {
        setup: s,
        current,
        original,
        selected,
        server,
    }
}
fn prepare_foreign(saved: &mut Saved) -> (restore::Review, Vault) {
    let selection = history::inspect(&mut saved.setup.store).unwrap().switches[0]
        .selection
        .clone();
    let source = restore::authenticate_source(
        &mut saved.setup.store,
        &selection,
        &crypto::format_recovery(&[0x66; 16]),
        true,
    )
    .unwrap();
    let mut current = unlock_current(&saved.setup, &saved.current);
    let review =
        restore::prepare_foreign(&mut saved.setup.store, selection, &mut current, source).unwrap();
    (review, current)
}

#[test]
fn foreign_restore_rekeys_nested_originals_and_selected_c1_beside_an_exact_current_lost_reply() {
    for queued in [false, true] {
        for point in [None, Some(1), Some(2), Some(3), Some(4), Some(7)] {
            let mut saved = saved(queued);
            let before = read_journal(&mut saved.setup).journal;
            let packet = before.outbound.clone().unwrap();
            let protected = capabilities(&saved.setup);
            let archived = saved
                .setup
                .backend
                .memory
                .slot(Slot::AccountReview)
                .unwrap();
            let (review, current) = prepare_foreign(&mut saved);
            assert!(review.summary().secure_records >= 2);
            let result = confirm(&mut saved.setup, review, point);
            assert_eq!(result.is_ok(), point.is_none());
            drop(current);
            if point.is_some() {
                saved.setup.store =
                    Store::load(saved.setup.temp.path(), saved.setup.backend.clone()).unwrap();
                resume_restore(&mut saved.setup).unwrap();
            }
            let after = read_journal(&mut saved.setup).journal;
            assert!(before.preserves_transport_state(&after));
            assert!(after.outbound.as_ref() == Some(&packet));
            assert!(
                saved
                    .setup
                    .backend
                    .memory
                    .slot(Slot::AccountReview)
                    .as_deref()
                    == Some(&archived)
            );
            assert!(capabilities(&saved.setup) == protected);
            let new_original = after
                .conflict_snapshots()
                .values()
                .find(|e| {
                    e.secure
                        && merge::provenance(e)
                            .is_some_and(|p| p.source_id == document().records[0].metadata.id)
                        && e.fields.as_ref().unwrap().name
                            == saved.original.fields.as_ref().unwrap().name
                })
                .unwrap()
                .clone();
            assert!(new_original.id != saved.original.id);
            let originals: std::collections::BTreeSet<_> = after
                .restoration_generations()
                .unwrap()
                .iter()
                .flat_map(|g| &g.sources)
                .flat_map(|(_, copies)| copies)
                .filter(|e| e.id == new_original.id)
                .map(|e| e.hash().unwrap())
                .collect();
            assert_eq!(originals.len(), if queued { 2 } else { 1 });
            let selected = after.entry(new_original.id).unwrap().desired.clone();
            assert!(selected.id != saved.selected.id && selected != new_original);
            let doc = crate::vault::read_document(saved.setup.temp.path())
                .unwrap()
                .unwrap();
            assert!(doc.same_identity(&saved.current));
            let mut vault = unlock_current(&saved.setup, &doc);
            assert!(
                vault.body(selected.id).unwrap().as_slice() == b"Public selected secure C1 body"
            );
            assert!(
                doc.records
                    .iter()
                    .any(|record| record.metadata.id != selected.id
                        && vault.body(record.metadata.id).unwrap().as_slice()
                            == b"Public current independently protected body")
            );
            vault.lock();
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
                .position(|batch| batch.iter().any(|(e, _)| e == &new_original))
                .unwrap();
            let selected_batch = saved
                .server
                .submitted
                .iter()
                .rposition(|batch| batch.iter().any(|(e, _)| e.id == selected.id))
                .unwrap();
            assert!(
                original_batch < selected_batch
                    && !read_journal(&mut saved.setup)
                        .journal
                        .has_preservation_work()
            );
        }
    }
}

#[test]
fn foreign_restore_requires_explicit_source_authentication_and_rejects_stale_source_selection() {
    let mut saved = saved(false);
    let selection = history::inspect(&mut saved.setup.store).unwrap().switches[0]
        .selection
        .clone();
    let before = std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap();
    let checkpoint = std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap();
    let mut vault = unlock_current(&saved.setup, &saved.current);
    assert!(restore::prepare(&mut saved.setup.store, selection.clone(), Some(&mut vault)).is_err());
    assert!(
        restore::authenticate_source(
            &mut saved.setup.store,
            &selection,
            "Public wrong source recovery",
            true
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
    let mut stale = selection.clone();
    stale.transition[0] ^= 1;
    assert!(matches!(
        restore::prepare_foreign(&mut saved.setup.store, stale, &mut vault, source),
        Err(restore::Failure::Changed)
    ));
    assert!(std::fs::read(saved.setup.temp.path().join("Vault/vault.json")).unwrap() == before);
    assert!(std::fs::read(saved.setup.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
    assert!(
        saved
            .setup
            .backend
            .memory
            .slot(Slot::HistoryRestore)
            .is_none()
    );
}
