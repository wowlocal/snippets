//! Real encryption/checkpoint/primary and a strict fictional CAS server.
//! No network, keyring, PAM, host account, or live support directory.
use super::*;
use crate::{
    clock::Hlc,
    cloud::{Binding, RecordVersion, ServerRecord},
    crypto::RootKey,
    inbound::Feed,
    journal::Scope,
    model::{self, Library, Snippet},
};
use std::{cell::Cell, fs};
use uuid::Uuid;
const SALT: [u8; 32] = [0x66; 32];
#[path = "sender_secure_tests.rs"]
mod secure;
fn key() -> RootKey {
    RootKey::from_bytes(&[0x55; 32]).unwrap()
}
fn scope() -> Scope {
    Scope {
        membership: Binding::from_checkpoint([0x11; 32]),
        dataset: Binding::from_checkpoint([0x22; 32]),
    }
}
fn feed() -> Feed {
    Feed::new(Uuid::from_u128(3), 1).unwrap()
}
fn envelope(id: u128, body: &str, wall: u64) -> Envelope {
    let mut s = Snippet::new("Public sender fixture", body);
    s.id = Uuid::from_u128(id);
    s.created_at = 0.0;
    s.updated_at = 1.0;
    Envelope::plain(&s, Hlc::foreign(wall), "22222222".into()).unwrap()
}
fn install(library: &Library, envelopes: &[Envelope]) {
    let snippets = envelopes
        .iter()
        .map(|e| e.snippet().unwrap().unwrap())
        .collect::<Vec<_>>();
    model::atomic_write(
        &library.path(),
        &model::encode_library(&snippets, false).unwrap(),
    )
    .unwrap();
}
fn owner<'a>(
    library: &'a Library,
    key: &'a RootKey,
    scope: &'a Scope,
    guard: &'a dyn Fn() -> Result<()>,
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
fn server_record(wire: &WireRecord, version: &cloud::RecordVersion) -> ServerRecord {
    let mut value = serde_json::to_value(wire).unwrap();
    value["recordVersion"] = serde_json::to_value(version).unwrap();
    serde_json::from_value(value).unwrap()
}
struct Server {
    scope: Scope,
    feed: Feed,
    role: Role,
    records: BTreeMap<Uuid, (WireRecord, RecordVersion)>,
    submitted: Vec<Vec<Offer>>,
    sequence: u64,
    preflights: usize,
    lose_response: bool,
    reject: Option<Uuid>,
    scope_at: Option<usize>,
    role_at: Option<usize>,
    feed_at: Option<usize>,
    corrupt_reply: bool,
}
impl Server {
    fn new() -> Self {
        Self {
            scope: scope(),
            feed: feed(),
            role: Role::Owner,
            records: BTreeMap::new(),
            submitted: vec![],
            sequence: 0,
            preflights: 0,
            lose_response: false,
            reject: None,
            scope_at: None,
            role_at: None,
            feed_at: None,
            corrupt_reply: false,
        }
    }
    fn put(&mut self, wire: WireRecord) -> RecordVersion {
        self.sequence += 1;
        let version = RecordVersion::from_checkpoint(format!(
            "public-fixture-record-version-{:016}",
            self.sequence
        ))
        .unwrap();
        self.records.insert(wire.id, (wire, version.clone()));
        version
    }
    fn body(&self, id: Uuid) -> String {
        String::from_utf8(
            self.records[&id]
                .0
                .open(&key(), &SALT)
                .unwrap()
                .fields
                .unwrap()
                .content
                .to_vec(),
        )
        .unwrap()
    }
}
impl Remote for Server {
    fn preflight(&mut self) -> RemoteResult<SendObservation> {
        self.preflights += 1;
        if self.scope_at == Some(self.preflights) {
            self.scope.membership = Binding::from_checkpoint([0x99; 32]);
        }
        if self.role_at == Some(self.preflights) {
            self.role = Role::Reader;
        }
        if self.feed_at == Some(self.preflights) {
            self.feed = Feed::new(Uuid::from_u128(99), 1).unwrap();
        }
        Ok(SendObservation {
            observation: Observation {
                scope: self.scope.clone(),
                feed: self.feed.clone(),
            },
            role: self.role,
        })
    }
    fn submit(&mut self, offers: &[Offer]) -> RemoteResult<Reply> {
        assert_ne!(offers.len(), 0);
        assert!(offers.len() <= PAGE_LIMIT);
        assert!(self.role != Role::Reader);
        self.submitted.push(offers.to_vec());
        let mut outcomes = Vec::new();
        for offer in offers {
            if self.reject == Some(offer.record.id) {
                outcomes.push(Outcome::Rejected {
                    error_code: ErrorCode::RateLimited,
                    retry_after_seconds: Some(60),
                });
                continue;
            }
            let current = self.records.get(&offer.record.id);
            if current.map(|(_, v)| v) != offer.expected_record_version.as_ref() {
                let (wire, version) = current.expect("fixture missing authoritative occupant");
                outcomes.push(Outcome::Conflict {
                    authoritative_record: server_record(wire, version),
                });
            } else {
                let version = self.put(offer.record.clone());
                outcomes.push(Outcome::Accepted {
                    record_version: version,
                    revision: if self.corrupt_reply {
                        "invalid-public-revision".into()
                    } else {
                        offer.record.rev.clone()
                    },
                });
            }
        }
        if self.lose_response {
            self.lose_response = false;
            return Err(cloud::Failure::Network);
        }
        let partial = outcomes
            .iter()
            .any(|o| !matches!(o, Outcome::Accepted { .. }));
        Ok(Reply {
            observation: Observation {
                scope: self.scope.clone(),
                feed: self.feed.clone(),
            },
            outcomes,
            partial,
        })
    }
}

#[test]
fn automatic_revocation_retains_inflight_receipts_and_resumes_without_resubmitting() {
    struct CancelAfterSubmit {
        server: Server,
        control: std::sync::Arc<crate::auto_sync::Control>,
        cancel: bool,
    }
    impl Remote for CancelAfterSubmit {
        fn preflight(&mut self) -> RemoteResult<SendObservation> {
            self.server.preflight()
        }
        fn submit(&mut self, offers: &[Offer]) -> RemoteResult<Reply> {
            let result = self.server.submit(offers)?;
            if self.cancel {
                self.control.pause();
                self.cancel = false;
            }
            Ok(result)
        }
    }
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[envelope(1, "Public cancelled automatic offer", 1)],
    );
    let deployment = crate::auth_store::Deployment::from_discovery(
        cloud::ServerURL::parse("https://sync.example").unwrap(),
        Uuid::from_u128(1),
    );
    let target = crate::auto_sync::Target::new(
        crate::key_store::KeyBinding::new(
            deployment.server().clone(),
            Uuid::from_u128(1),
            Uuid::from_u128(2),
            (scope().membership, scope().dataset),
            1,
        )
        .unwrap(),
        &deployment,
        "fictional-account",
    )
    .unwrap();
    crate::auto_sync::Preference::on(&library.root, &target).unwrap();
    let pref = crate::auto_sync::Preference::read(&library.root).unwrap();
    let control = crate::auto_sync::Control::new();
    let ticket = control.ticket(&library.root, pref).unwrap();
    let guard = || ticket.validate().map_err(|_| Failure::SessionChanged);
    let mut remote = CancelAfterSubmit {
        server: Server::new(),
        control: control.clone(),
        cancel: true,
    };
    assert!(matches!(
        owner(&library, &key(), &scope(), &guard).send(&mut remote, 1),
        Err(Failure::SessionChanged)
    ));
    let checkpoint = load(&library);
    let packet = checkpoint.journal.outbound.as_ref().unwrap();
    assert!(packet.receipts.is_some());
    assert!(packet.offers[0].wire == remote.server.submitted[0][0].record);
    assert!(checkpoint.journal.confirmed(Uuid::from_u128(1)).is_none());
    control.resume();
    let next = control.ticket(&library.root, pref).unwrap();
    let guard = || next.validate().map_err(|_| Failure::SessionChanged);
    assert_eq!(
        owner(&library, &key(), &scope(), &guard)
            .send(&mut remote, 1)
            .unwrap()
            .status,
        Status::Settled
    );
    assert_eq!(remote.server.submitted.len(), 1);
    assert!(load(&library).journal.outbound.is_none());
}
#[test]
fn local_create_and_edit_are_encrypted_and_confirmed_with_actual_cas_versions() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let original = envelope(1, "Public original local body", 1);
    install(&library, std::slice::from_ref(&original));
    let mut server = Server::new();
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 4)
        .unwrap();
    assert_eq!(progress.status, Status::Settled);
    assert_eq!(progress.accepted, 1);
    assert!(server.submitted[0][0].expected_record_version.is_none());
    let old = load(&library)
        .journal
        .confirmed(original.id)
        .unwrap()
        .record_version
        .clone();
    let edited = envelope(1, "Public newer local body", 2);
    install(&library, &[edited]);
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::Settled
    );
    assert!(server.submitted[1][0].expected_record_version == Some(old));
    assert_eq!(server.body(original.id), "Public newer local body");
    assert!(load(&library).journal.outbound.is_none());
    let bytes = fs::read(temp.path().join("Sync/journal.bin")).unwrap();
    for marker in ["Public newer local body", "public-fixture-record-version"] {
        assert!(!bytes.windows(marker.len()).any(|w| w == marker.as_bytes()));
    }
}

#[test]
fn lost_response_replays_identical_ciphertext_and_original_cas_then_confirms_exact_content() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[envelope(1, "Public retained original offer", 1)],
    );
    let mut server = Server::new();
    server.lose_response = true;
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(())).send(&mut server, 1),
        Err(Failure::Remote(cloud::Failure::Network))
    ));
    let original = &server.submitted[0][0];
    let persisted = load(&library);
    let retained = &persisted.journal.outbound.as_ref().unwrap().offers[0];
    assert!(retained.wire == original.record);
    assert!(retained.offered.record_version == original.expected_record_version);
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 1)
        .unwrap();
    assert_eq!(progress.status, Status::Settled);
    assert_eq!(progress.confirmed, 1);
    assert!(server.submitted[1][0].record == server.submitted[0][0].record);
    assert!(
        server.submitted[1][0].expected_record_version
            == server.submitted[0][0].expected_record_version
    );
    assert!(load(&library).journal.outbound.is_none());
}

#[test]
fn faults_before_and_after_all_five_checkpoint_phases_resume_without_duplicate_intent() {
    for number in 1..=5 {
        for after in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let library = Library::open(temp.path().into()).unwrap();
            install(&library, &[envelope(1, "Public send crash fixture", 1)]);
            let mut server = Server::new();
            let mut fault = Fault {
                saves: 0,
                save: Some((number, after)),
                after_primary: false,
            };
            assert!(matches!(
                owner(&library, &key(), &scope(), &|| Ok(())).send_inner(
                    &mut server,
                    1,
                    &mut fault
                ),
                Err(Failure::Journal(crate::journal::Failure::Storage))
            ));
            let original = load(&library).journal.outbound;
            let submitted = server.submitted.len();
            assert_eq!(
                owner(&library, &key(), &scope(), &|| Ok(()))
                    .send(&mut server, 4)
                    .unwrap()
                    .status,
                Status::Settled
            );
            assert_eq!(server.records.len(), 1);
            assert!(load(&library).journal.outbound.is_none());
            if let Some(packet) = original {
                if packet.receipts.is_some() {
                    assert_eq!(server.submitted.len(), submitted);
                } else {
                    assert!(server.submitted.last().unwrap()[0].record == packet.offers[0].wire);
                }
            }
        }
    }
}

#[test]
fn a_newer_local_edit_does_not_replace_an_ambiguous_original_offer() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[envelope(1, "Public original ambiguous body", 1)],
    );
    let mut server = Server::new();
    server.lose_response = true;
    assert!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .is_err()
    );
    let original = server.submitted[0][0].record.clone();
    let original_version = server.records[&Uuid::from_u128(1)].1.clone();
    install(
        &library,
        &[envelope(1, "Public edit after ambiguous send", 2)],
    );
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 4)
        .unwrap();
    assert_eq!(progress.status, Status::Settled);
    assert_eq!(progress.confirmed, 1);
    assert_eq!(progress.accepted, 1);
    assert!(server.submitted[1][0].record == original);
    assert!(server.submitted[2][0].expected_record_version == Some(original_version));
    assert_eq!(
        server.body(Uuid::from_u128(1)),
        "Public edit after ambiguous send"
    );
}

#[test]
fn partial_batch_keeps_successes_and_finishes_all_receipts_before_stopping_for_backoff() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[
            envelope(1, "Public accepted A", 1),
            envelope(2, "Public rate-limited B", 1),
            envelope(3, "Public accepted C", 1),
        ],
    );
    let mut server = Server::new();
    server.reject = Some(Uuid::from_u128(2));
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 4)
        .unwrap();
    assert!(matches!(
        progress.status,
        Status::ServerDeferred {
            code: ErrorCode::RateLimited,
            retry_after: Some(1..=60)
        }
    ));
    assert_eq!(progress.accepted, 2);
    assert_eq!(progress.rejected, 1);
    assert_eq!(server.submitted.len(), 1);
    let checkpoint = load(&library);
    assert!(checkpoint.journal.outbound.as_ref().unwrap().acknowledged());
    assert!(checkpoint.journal.confirmed(Uuid::from_u128(1)).is_some());
    assert!(checkpoint.journal.confirmed(Uuid::from_u128(3)).is_some());
    assert!(
        checkpoint
            .journal
            .entry(Uuid::from_u128(2))
            .unwrap()
            .offered
            .is_none()
    );
    server.reject = None;
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::ServerDeferred {
            code: ErrorCode::RateLimited,
            ..
        }
    ));
    assert_eq!(server.submitted.len(), 1);
    let mut checkpoint = load(&library);
    checkpoint.journal.outbound.as_mut().unwrap().received_at = Some(1);
    checkpoint.save(&library, &key(), &SALT).unwrap();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::Settled
    );
    assert_eq!(server.submitted[1].len(), 1);
}

#[test]
fn received_ack_is_saved_before_post_http_account_or_role_change() {
    for role_only in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let library = Library::open(temp.path().into()).unwrap();
        install(
            &library,
            &[envelope(1, "Public acknowledgement boundary", 1)],
        );
        let mut server = Server::new();
        if role_only {
            server.role_at = Some(2);
        } else {
            server.scope_at = Some(2);
        }
        let result = owner(&library, &key(), &scope(), &|| Ok(())).send(&mut server, 1);
        if role_only {
            assert_eq!(result.unwrap().status, Status::ReadOnly);
            assert!(
                load(&library)
                    .journal
                    .confirmed(Uuid::from_u128(1))
                    .is_some()
            );
        } else {
            assert!(matches!(result, Err(Failure::ScopeReview)));
            assert!(
                load(&library)
                    .journal
                    .outbound
                    .as_ref()
                    .unwrap()
                    .receipts
                    .is_some()
            );
            server.scope = scope();
            server.scope_at = None;
            assert_eq!(
                owner(&library, &key(), &scope(), &|| Ok(()))
                    .send(&mut server, 1)
                    .unwrap()
                    .status,
                Status::Settled
            );
            assert_eq!(server.submitted.len(), 1);
        }
    }
}

#[test]
fn stale_cas_conflict_merges_and_preserves_the_losing_body_before_uploading() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(&library, &[envelope(1, "Public local losing body", 1)]);
    let mut server = Server::new();
    server.put(
        WireRecord::seal(
            &envelope(1, "Public remote winning body", 2_000_000_000_000),
            &key(),
            &SALT,
        )
        .unwrap(),
    );
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 4)
        .unwrap();
    assert_eq!(progress.status, Status::Settled);
    assert_eq!(progress.conflicts, 1);
    let snippets = library.read().unwrap().0;
    assert_eq!(snippets.len(), 2);
    assert!(
        snippets
            .iter()
            .any(|s| s.content == "Public local losing body" && !s.is_enabled)
    );
    assert_eq!(server.records.len(), 2);
    // The preserved copy is sent before the post-copy source, in separate batches.
    assert_ne!(server.submitted[1][0].record.id, Uuid::from_u128(1));
    assert_eq!(server.submitted[2][0].record.id, Uuid::from_u128(1));
    assert!(!load(&library).journal.has_preservation_work());
}

#[test]
fn crash_between_conflict_primary_apply_and_receipt_advance_replays_preservation_evidence() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(&library, &[envelope(1, "Public conflict crash loser", 1)]);
    let mut server = Server::new();
    server.put(
        WireRecord::seal(
            &envelope(1, "Public conflict crash winner", 2_000_000_000_000),
            &key(),
            &SALT,
        )
        .unwrap(),
    );
    let mut fault = Fault {
        after_primary: true,
        ..Fault::default()
    };
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(())).send_inner(&mut server, 4, &mut fault),
        Err(Failure::Primary(primary::Failure::RecoveryRequired))
    ));
    let frozen = load(&library).journal.conflict_snapshots();
    assert_eq!(frozen.len(), 1);
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::Settled
    );
    assert_eq!(library.read().unwrap().0.len(), 2);
    assert_eq!(server.records.len(), 2);
    assert!(frozen.values().all(|copy| {
        server.records[&copy.id]
            .0
            .open(&key(), &SALT)
            .unwrap()
            .hash()
            .unwrap()
            == copy.hash().unwrap()
    }));
}

#[test]
fn missing_primary_file_is_review_and_never_remote_deletion() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(&library, &[envelope(1, "Public retained record", 1)]);
    let mut server = Server::new();
    owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 4)
        .unwrap();
    fs::remove_file(library.path()).unwrap();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::LocalReview
    );
    assert_eq!(server.submitted.len(), 1);
    assert_eq!(server.body(Uuid::from_u128(1)), "Public retained record");
    assert!(load(&library).journal.pending().unwrap().is_empty());
}

#[test]
fn read_only_role_and_expired_session_never_stage_or_send_requests() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[envelope(1, "Public unsent read-only record", 1)],
    );
    let mut server = Server::new();
    server.role = Role::Reader;
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::ReadOnly
    );
    assert!(server.submitted.is_empty());
    assert!(!temp.path().join("Sync").exists());
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Err(Failure::SessionChanged)).send(&mut server, 4),
        Err(Failure::SessionChanged)
    ));
    assert!(server.submitted.is_empty());
}

#[test]
fn invalid_revision_receipt_leaves_original_offer_replayable_without_false_confirmation() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[envelope(1, "Public invalid response fixture", 1)],
    );
    let mut server = Server::new();
    server.corrupt_reply = true;
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(())).send(&mut server, 4),
        Err(Failure::InvalidPage)
    ));
    let checkpoint = load(&library);
    assert!(checkpoint.journal.confirmed(Uuid::from_u128(1)).is_none());
    assert!(
        checkpoint
            .journal
            .outbound
            .as_ref()
            .unwrap()
            .receipts
            .is_none()
    );
    server.corrupt_reply = false;
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::Settled
    );
    assert!(server.submitted[0][0].record == server.submitted[1][0].record);
}

#[test]
fn local_edit_during_http_is_captured_after_ack_before_the_next_batch() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(&library, &[envelope(1, "Public first sent value", 1)]);
    let calls = Cell::new(0);
    let guard = || {
        calls.set(calls.get() + 1);
        if calls.get() == 6 {
            install(&library, &[envelope(1, "Public changed during send", 2)]);
        }
        Ok(())
    };
    let mut server = Server::new();
    assert_eq!(
        owner(&library, &key(), &scope(), &guard)
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::Settled
    );
    assert_eq!(server.submitted.len(), 2);
    assert_eq!(
        server.body(Uuid::from_u128(1)),
        "Public changed during send"
    );
}

#[test]
fn lost_post_copy_source_ack_requires_a_fresh_actual_ack_after_exact_conflict() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(&library, &[envelope(1, "Public source-ack loser", 1)]);
    let mut server = Server::new();
    server.put(
        WireRecord::seal(
            &envelope(1, "Public source-ack winner", 2_000_000_000_000),
            &key(),
            &SALT,
        )
        .unwrap(),
    );
    let send = |server: &mut Server| owner(&library, &key(), &scope(), &|| Ok(())).send(server, 1);
    assert_eq!(send(&mut server).unwrap().status, Status::MoreBatches); // conflict/preserve
    assert_eq!(send(&mut server).unwrap().status, Status::MoreBatches); // exact C0 ACK
    server.lose_response = true;
    assert!(matches!(
        send(&mut server),
        Err(Failure::Remote(cloud::Failure::Network))
    ));
    assert_eq!(send(&mut server).unwrap().status, Status::MoreBatches); // exact source fetch is insufficient
    assert!(load(&library).journal.has_preservation_work());
    assert!(server.submitted[2][0].record == server.submitted[3][0].record);
    assert!(
        server.submitted[2][0].expected_record_version
            == server.submitted[3][0].expected_record_version
    );
    assert_eq!(send(&mut server).unwrap().status, Status::Settled); // actual post-copy ACK
    assert!(!load(&library).journal.has_preservation_work());
    assert!(
        server.submitted[4][0].expected_record_version
            != server.submitted[3][0].expected_record_version
    );
}

#[test]
fn a_remote_edited_copy_neither_proves_c0_nor_gets_overwritten_to_create_that_proof() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[envelope(1, "Public copy-preservation loser", 1)],
    );
    let mut server = Server::new();
    server.put(
        WireRecord::seal(
            &envelope(1, "Public copy-preservation winner", 2_000_000_000_000),
            &key(),
            &SALT,
        )
        .unwrap(),
    );
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .unwrap()
            .status,
        Status::MoreBatches
    );
    let checkpoint = load(&library);
    let original = checkpoint
        .journal
        .conflict_snapshots()
        .into_values()
        .next()
        .unwrap();
    let mut edited = original.clone();
    edited.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public remote C1 edit".to_vec());
    server.put(WireRecord::seal(&edited, &key(), &SALT).unwrap());
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .unwrap()
            .status,
        Status::ConflictReview
    );
    assert_eq!(server.body(original.id), "Public remote C1 edit");
    assert!(load(&library).journal.confirmed(original.id).is_none());
    let submitted = server.submitted.len();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .unwrap()
            .status,
        Status::ConflictReview
    );
    assert_eq!(server.submitted.len(), submitted);
    assert_eq!(server.body(original.id), "Public remote C1 edit");
}

#[test]
fn bounded_batches_stage_ten_records_then_continue_remaining_intent() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &(1..=11)
            .map(|id| envelope(id, "Public bounded send", 1))
            .collect::<Vec<_>>(),
    );
    let mut server = Server::new();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .unwrap()
            .status,
        Status::MoreBatches
    );
    assert_eq!(server.submitted.len(), 1);
    assert_eq!(server.submitted[0].len(), 10);
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .unwrap()
            .status,
        Status::Settled
    );
    assert_eq!(server.submitted[1].len(), 1);
    assert_eq!(server.records.len(), 11);
}

impl receiver::Remote for Server {
    fn preflight(&mut self) -> RemoteResult<Observation> {
        Ok(Remote::preflight(self)?.observation)
    }
    fn fetch(&mut self, _: Option<&cloud::Cursor>) -> RemoteResult<receiver::FetchedPage> {
        panic!("fixture must never receive before a retained send is resolved")
    }
}

#[test]
fn a_retained_send_blocks_receive_while_an_incomplete_snapshot_blocks_new_send() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(&library, &[envelope(1, "Public ordering fixture", 1)]);
    let mut server = Server::new();
    server.lose_response = true;
    assert!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .is_err()
    );
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .receive(&mut server, 1)
            .unwrap()
            .status,
        receiver::Status::SendFirst
    );
    assert_eq!(server.submitted.len(), 1);
    owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 1)
        .unwrap();
    let mut checkpoint = load(&library);
    checkpoint.journal.inbox.select_feed(feed()).unwrap();
    checkpoint
        .journal
        .inbox
        .receive(
            &feed(),
            None,
            vec![],
            cloud::Cursor::from_checkpoint("public-snapshot-cursor".into()).unwrap(),
            true,
            false,
        )
        .unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let submitted = server.submitted.len();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .unwrap()
            .status,
        Status::ReceiveFirst
    );
    assert_eq!(server.submitted.len(), submitted);
}

fn queue_original_after_retained_send(library: &Library, server: &Server) {
    let mut checkpoint = load(library);
    checkpoint.journal.inbox.select_feed(feed()).unwrap();
    let (wire, version) = &server.records[&Uuid::from_u128(1)];
    checkpoint
        .journal
        .inbox
        .receive(
            &feed(),
            None,
            vec![crate::journal::Confirmed {
                envelope: wire.open(&key(), &SALT).unwrap(),
                record_version: version.clone(),
            }],
            cloud::Cursor::from_checkpoint("public-retained-send-snapshot".into()).unwrap(),
            true,
            false,
        )
        .unwrap();
    checkpoint.save(library, &key(), &SALT).unwrap();
}

#[test]
fn retained_receipts_finish_beside_an_incomplete_inbox_without_posting_new_intent() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let original = envelope(1, "Public retained receipt fixture", 1);
    install(&library, std::slice::from_ref(&original));
    let mut server = Server::new();
    server.scope_at = Some(2);
    let checkpoint_key = key();
    let expected_scope = scope();
    let owner = owner(&library, &checkpoint_key, &expected_scope, &|| Ok(()));
    // The accepted receipt is durable before the post-HTTP account halt.
    assert!(owner.send(&mut server, 1).is_err());
    server.scope = scope();
    server.scope_at = None;
    queue_original_after_retained_send(&library, &server);
    install(
        &library,
        &[original, envelope(2, "Public waiting local intent", 2)],
    );
    assert_eq!(
        owner.send(&mut server, 4).unwrap().status,
        Status::ReceiveFirst
    );
    assert_eq!(server.submitted.len(), 1);
    let saved = load(&library);
    assert!(saved.journal.outbound.is_none());
    assert!(saved.journal.confirmed(Uuid::from_u128(1)).is_some());
    assert!(saved.journal.inbox.next().is_some());
}

#[test]
fn an_ambiguous_original_packet_replays_before_the_inbox_but_cannot_create_a_new_batch() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let original = envelope(1, "Public ambiguous packet fixture", 1);
    install(&library, std::slice::from_ref(&original));
    let mut server = Server::new();
    server.lose_response = true;
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    assert!(owner.send(&mut server, 1).is_err());
    queue_original_after_retained_send(&library, &server);
    install(
        &library,
        &[original, envelope(2, "Public pending next batch", 2)],
    );
    assert_eq!(
        owner.send(&mut server, 4).unwrap().status,
        Status::ReceiveFirst
    );
    assert_eq!(server.submitted.len(), 2);
    assert!(server.submitted[0][0].record == server.submitted[1][0].record);
    assert!(
        server.submitted[0][0].expected_record_version
            == server.submitted[1][0].expected_record_version
    );
    assert!(load(&library).journal.outbound.is_none());
    assert!(load(&library).journal.inbox.next().is_some());
}

fn finish_empty_snapshot(library: &Library) {
    let mut checkpoint = load(library);
    checkpoint.journal.inbox.select_feed(feed()).unwrap();
    checkpoint
        .journal
        .inbox
        .receive(
            &feed(),
            None,
            vec![],
            cloud::Cursor::from_checkpoint("public-complete-before-rotation".into()).unwrap(),
            true,
            false,
        )
        .unwrap();
    checkpoint.journal.inbox.complete_page().unwrap();
    checkpoint
        .journal
        .inbox
        .finish_snapshot(std::iter::empty())
        .unwrap();
    checkpoint.save(library, &key(), &SALT).unwrap();
}

#[test]
fn a_rotated_applied_feed_fences_new_sends_until_receiving_finishes() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    finish_empty_snapshot(&library);
    install(&library, &[envelope(1, "Public feed-fenced edit", 1)]);
    let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    let mut server = Server::new();
    server.feed = Feed::new(Uuid::from_u128(99), 1).unwrap();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 4)
            .unwrap()
            .status,
        Status::ReceiveFirst
    );
    assert!(server.submitted.is_empty());
    assert_eq!(
        fs::read(library.root.join("Sync/journal.bin")).unwrap(),
        before
    );
}

#[test]
fn a_feed_rotation_between_batches_retains_the_remaining_intent_without_another_post() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    finish_empty_snapshot(&library);
    install(
        &library,
        &(1..=11)
            .map(|id| envelope(id, "Public mid-cycle feed fixture", 1))
            .collect::<Vec<_>>(),
    );
    let mut server = Server::new();
    server.feed_at = Some(3);
    let result = owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 4)
        .unwrap();
    assert_eq!(result.status, Status::ReceiveFirst);
    assert_eq!(result.accepted, 10);
    assert_eq!(server.submitted.len(), 1);
    assert_eq!(load(&library).journal.pending().unwrap().len(), 1);
}

#[test]
fn an_undecryptable_conflict_response_is_retained_without_applying_or_forgetting_it() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[envelope(1, "Public retained local plaintext", 1)],
    );
    let mut server = Server::new();
    let mut corrupt = WireRecord::seal(
        &envelope(1, "Public corrupt remote fixture", 2000),
        &key(),
        &SALT,
    )
    .unwrap();
    corrupt.blob[20] ^= 1;
    server.put(corrupt);
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(())).send(&mut server, 1),
        Err(Failure::InvalidPage)
    ));
    let checkpoint = load(&library);
    assert!(
        checkpoint
            .journal
            .outbound
            .as_ref()
            .unwrap()
            .receipts
            .is_some()
    );
    assert_eq!(checkpoint.journal.outbound.as_ref().unwrap().position, 0);
    assert!(checkpoint.journal.confirmed(Uuid::from_u128(1)).is_none());
    assert_eq!(
        library.read().unwrap().0[0].content,
        "Public retained local plaintext"
    );
    let submitted = server.submitted.len();
    assert!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .is_err()
    );
    assert_eq!(server.submitted.len(), submitted);
}

#[test]
fn key_epoch_survives_a_drained_outbound_packet_and_fences_primary_recovery() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(&library, &[envelope(1, "Public durable epoch fixture", 1)]);
    let mut server = Server::new();
    owner(&library, &key(), &scope(), &|| Ok(()))
        .send(&mut server, 1)
        .unwrap();
    let mut checkpoint = load(&library);
    assert_eq!(checkpoint.journal.key_epoch, Some(1));
    assert!(checkpoint.journal.outbound.is_none());
    assert!(checkpoint.journal.inbox.feed.is_none());
    checkpoint.journal.primary_epoch = Some([0x33; 16]);
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let mut marker = b"SPT1".to_vec();
    marker.extend_from_slice(&[0x33; 16]);
    fs::write(temp.path().join("Sync/primary.pending"), &marker).unwrap();
    let wire_key = key();
    let binding = scope();
    let mut changed = owner(&library, &wire_key, &binding, &|| Ok(()));
    changed.key_epoch = 2;
    server.feed.key_epoch = 2;
    let submitted = server.submitted.len();
    assert!(matches!(
        changed.send(&mut server, 1),
        Err(Failure::Primary(primary::Failure::RecoveryRequired))
    ));
    assert_eq!(
        fs::read(temp.path().join("Sync/primary.pending")).unwrap(),
        marker
    );
    assert_eq!(server.submitted.len(), submitted);
}

#[test]
fn corrupt_retained_ciphertext_is_never_resealed_or_sent_as_a_new_offer() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    install(
        &library,
        &[envelope(1, "Public retained ciphertext fixture", 1)],
    );
    let mut server = Server::new();
    server.lose_response = true;
    assert!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .send(&mut server, 1)
            .is_err()
    );
    let mut checkpoint = load(&library);
    checkpoint.journal.outbound.as_mut().unwrap().offers[0]
        .wire
        .blob[20] ^= 1;
    checkpoint.save(&library, &key(), &SALT).unwrap();
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(())).send(&mut server, 1),
        Err(Failure::InvalidPage)
    ));
    assert_eq!(server.submitted.len(), 1);
    assert!(
        load(&library)
            .journal
            .outbound
            .as_ref()
            .unwrap()
            .receipts
            .is_none()
    );
}
