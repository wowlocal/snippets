//! Fictional CAS, pagination and control-plane observations around actual wire,
//! checkpoint, merge and primary recovery. No HTTP, keyring, PAM or user files.
use super::*;
use crate::{
    cloud::{self, Cursor, Offer, RecordVersion, Role, ServerRecord},
    crypto::RootKey,
    journal::Scope,
    model::Library,
    receiver::{FetchedPage, Observation, RemoteResult},
    snapshot_review::tests::{SALT, Server, cursor, envelope, feed, key, scope, write_primary},
    wire::Envelope,
};
use std::{cell::Cell, collections::BTreeMap, fs};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Call {
    Fetch,
    Submit,
}
enum Position {
    Snapshot {
        remaining: Vec<ServerRecord>,
        known: BTreeMap<Uuid, RecordVersion>,
    },
    Delta(BTreeMap<Uuid, RecordVersion>),
}
struct Peer {
    server: Server,
    role: Role,
    positions: BTreeMap<String, Position>,
    generation: usize,
    preflights: usize,
    calls: Vec<Call>,
    wire_posts: Vec<Vec<(crate::wire::WireRecord, Option<RecordVersion>)>>,
    lose_reply: bool,
    reject: Option<Uuid>,
    add_after_post: Option<Envelope>,
    fail_fetch_after_post: bool,
    rotate_at: Option<usize>,
    reader_at: Option<usize>,
    scope_at: Option<usize>,
    edit_at: Option<(usize, std::path::PathBuf, Vec<Envelope>)>,
}
impl Peer {
    fn new() -> Self {
        Self {
            server: Server::new(),
            role: Role::Writer,
            positions: BTreeMap::new(),
            generation: 0,
            preflights: 0,
            calls: vec![],
            wire_posts: vec![],
            lose_reply: false,
            reject: None,
            add_after_post: None,
            fail_fetch_after_post: false,
            rotate_at: None,
            reader_at: None,
            scope_at: None,
            edit_at: None,
        }
    }
    fn observation(&mut self) -> Observation {
        self.preflights += 1;
        if self.rotate_at == Some(self.preflights) {
            self.server.feed = feed(44);
            self.positions.clear();
        }
        if self.reader_at == Some(self.preflights) {
            self.role = Role::Reader;
        }
        if self.scope_at == Some(self.preflights) {
            self.server.scope.membership = cloud::Binding::from_checkpoint([0x99; 32]);
        }
        if self
            .edit_at
            .as_ref()
            .is_some_and(|(at, _, _)| *at == self.preflights)
        {
            let (_, root, rows) = self.edit_at.take().unwrap();
            let library = Library::prepare(root).unwrap();
            write_primary(&library, &rows);
        }
        Observation {
            scope: self.server.scope.clone(),
            feed: self.server.feed.clone(),
        }
    }
    fn known(&self) -> BTreeMap<Uuid, RecordVersion> {
        self.server
            .records
            .iter()
            .map(|(id, (_, v))| (*id, v.clone()))
            .collect()
    }
    fn rows(&self) -> Vec<ServerRecord> {
        self.server
            .records
            .values()
            .map(|(wire, v)| {
                let mut value = serde_json::to_value(wire).unwrap();
                value["recordVersion"] = v.for_checkpoint().into();
                serde_json::from_value(value).unwrap()
            })
            .collect()
    }
}
impl receiver::Remote for Peer {
    fn preflight(&mut self) -> RemoteResult<Observation> {
        Ok(self.observation())
    }
    fn fetch(&mut self, requested: Option<&Cursor>) -> RemoteResult<FetchedPage> {
        self.calls.push(Call::Fetch);
        if self.fail_fetch_after_post && !self.server.submitted.is_empty() {
            self.fail_fetch_after_post = false;
            return Err(cloud::Failure::Network);
        }
        let (mut rows, mut known, full_snapshot) = match requested {
            None => (self.rows(), self.known(), true),
            Some(c) => match self
                .positions
                .remove(c.for_checkpoint())
                .expect("issued fixture cursor")
            {
                Position::Snapshot { remaining, known } => (remaining, known, true),
                Position::Delta(known) => {
                    let rows = self
                        .rows()
                        .into_iter()
                        .filter(|r| {
                            let id = r.clone().into_parts().0.id;
                            let (_, version) = self.server.records.get(&id).unwrap();
                            known.get(&id) != Some(version)
                        })
                        .collect();
                    (rows, known, false)
                }
            },
        };
        let remaining = rows.split_off(rows.len().min(crate::inbound::PAGE_LIMIT));
        let has_more = !remaining.is_empty();
        if !full_snapshot {
            for row in &rows {
                let id = row.clone().into_parts().0.id;
                let (_, version) = &self.server.records[&id];
                known.insert(id, version.clone());
            }
        }
        self.generation += 1;
        let next = cursor(&format!("bidirectional-{}", self.generation));
        self.positions.insert(
            next.for_checkpoint().into(),
            if full_snapshot && has_more {
                Position::Snapshot { remaining, known }
            } else {
                Position::Delta(known)
            },
        );
        Ok(FetchedPage {
            observation: Observation {
                scope: self.server.scope.clone(),
                feed: self.server.feed.clone(),
            },
            records: rows,
            cursor: next,
            full_snapshot,
            has_more,
        })
    }
}
impl sender::Remote for Peer {
    fn preflight(&mut self) -> RemoteResult<sender::SendObservation> {
        let observation = self.observation();
        Ok(sender::SendObservation {
            observation,
            role: self.role,
        })
    }
    fn submit(&mut self, offers: &[Offer]) -> RemoteResult<sender::Reply> {
        self.calls.push(Call::Submit);
        self.wire_posts.push(
            offers
                .iter()
                .map(|o| (o.record.clone(), o.expected_record_version.clone()))
                .collect(),
        );
        assert!(self.role != Role::Reader);
        if self.reject.is_some() {
            assert_eq!(offers.len(), 1);
            assert_eq!(Some(offers[0].record.id), self.reject);
            return Ok(sender::Reply {
                observation: self.observation(),
                partial: true,
                outcomes: vec![cloud::Outcome::Rejected {
                    error_code: cloud::ErrorCode::RateLimited,
                    retry_after_seconds: Some(60),
                }],
            });
        }
        let reply = sender::Remote::submit(&mut self.server, offers)?;
        if let Some(e) = self.add_after_post.take() {
            self.server.add(&e);
        }
        if std::mem::take(&mut self.lose_reply) {
            return Err(cloud::Failure::Network);
        }
        Ok(reply)
    }
}
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
fn setup() -> (tempfile::TempDir, Library, Peer) {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    (temp, library, Peer::new())
}
fn load(library: &Library) -> Checkpoint {
    Checkpoint::load(library, &key(), &SALT, scope()).unwrap()
}
fn run(library: &Library, peer: &mut Peer, limits: Limits) -> receiver::Result<Progress> {
    owner(library, &key(), &scope(), &|| Ok(())).synchronize(peer, limits)
}

#[test]
fn a_borrowed_current_vault_key_continues_a_saved_page_then_sends_and_checks_the_final_feed() {
    let (temporary, library, mut peer) = setup();
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        crate::vault::Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    document.records[0].hlc = Some(crate::clock::Hlc::parse("100000000000-0000-11111111").unwrap());
    let mut incoming = crate::projection::current(
        &[],
        Some(&document),
        "11111111",
        &BTreeMap::new(),
        &BTreeMap::new(),
    )
    .unwrap()
    .into_values()
    .next()
    .unwrap();
    incoming.extensions.remove("vaultKID");
    document.records.clear();
    fs::create_dir(temporary.path().join("Vault")).unwrap();
    crate::model::atomic_write(
        &temporary.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    write_primary(
        &library,
        &[envelope(1, "Public local authenticated sync fixture", 1000)],
    );
    peer.server.add(&incoming);
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Receiving(receiver::Status::VaultLocked)
    );
    assert_eq!(peer.calls, vec![Call::Fetch]);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = crate::materializer::Keyring::new(&root, &document).unwrap();
    let wire_key = key();
    let binding = scope();
    let mut authenticated = owner(&library, &wire_key, &binding, &|| Ok(()));
    authenticated.vault_keys = Some(&keys);
    let result = authenticated
        .synchronize(&mut peer, Limits::DEFAULT)
        .unwrap();
    assert_eq!(result.status, Status::Current);
    // The verified unstamped import projects a separate stamped local revision.
    assert_eq!(result.accepted, 2);
    assert_eq!(peer.calls, vec![Call::Fetch, Call::Submit, Call::Fetch]);
    assert_eq!(peer.server.records.len(), 2);
    assert!(load(&library).journal.outbound.is_none());
    let saved = crate::vault::read_document(temporary.path())
        .unwrap()
        .unwrap();
    assert_eq!(
        saved.records[0].sealed.text().as_bytes(),
        incoming.fields.as_ref().unwrap().content.as_slice()
    );
    assert!(keys.matches(&saved));
}

#[test]
fn a_fresh_empty_install_finishes_both_directions_without_a_post_or_sample_content() {
    let (_temp, library, mut peer) = setup();
    let result = run(&library, &mut peer, Limits::DEFAULT).unwrap();
    assert_eq!(result.status, Status::Current);
    assert_eq!(result.batches, 0);
    assert!(library.read().unwrap().0.is_empty());
    assert_eq!(peer.calls, vec![Call::Fetch]);
    assert!(load(&library).journal.pending().unwrap().is_empty());
}
#[test]
fn one_action_receives_sends_and_checks_the_post_send_feed_before_claiming_current() {
    let (_temp, library, mut peer) = setup();
    peer.server
        .add(&envelope(2, "Public remote sync fixture", 1000));
    write_primary(&library, &[envelope(1, "Public local sync fixture", 1000)]);
    peer.add_after_post = Some(envelope(3, "Public edit during upload", 2000));
    let result = run(&library, &mut peer, Limits::DEFAULT).unwrap();
    assert_eq!(result.status, Status::Current);
    assert_eq!(result.accepted, 1);
    assert_eq!(peer.calls, vec![Call::Fetch, Call::Submit, Call::Fetch]);
    assert_eq!(library.read().unwrap().0.len(), 3);
    assert_eq!(peer.server.records.len(), 3);
    assert!(load(&library).journal.outbound.is_none());
}
#[test]
fn page_exhaustion_retains_the_snapshot_and_never_sends_before_its_last_page() {
    let (_temp, library, mut peer) = setup();
    for id in 2..=22 {
        peer.server
            .add(&envelope(id, "Public paged remote fixture", 1000));
    }
    write_primary(&library, &[envelope(1, "Public paged local fixture", 1000)]);
    let result = run(
        &library,
        &mut peer,
        Limits {
            receive: 1,
            send: 4,
        },
    )
    .unwrap();
    assert_eq!(result.status, Status::MoreWork(Direction::Receive));
    assert_eq!(result.receive_attempts, 1);
    assert_eq!(result.completed_pages, 1);
    assert_eq!(result.batches, 0);
    assert_eq!(peer.calls, vec![Call::Fetch]);
    assert!(load(&library).journal.inbox.snapshot.is_some());
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Current
    );
    assert_eq!(library.read().unwrap().0.len(), 22);
    assert_eq!(peer.calls.iter().position(|c| *c == Call::Submit), Some(3));
}
#[test]
fn batch_exhaustion_retains_remaining_local_intent_and_resumes_without_duplicate_uploads() {
    let (_temp, library, mut peer) = setup();
    let rows = (1..=21)
        .map(|id| envelope(id, "Public batched local fixture", 1000))
        .collect::<Vec<_>>();
    write_primary(&library, &rows);
    let result = run(
        &library,
        &mut peer,
        Limits {
            receive: 4,
            send: 1,
        },
    )
    .unwrap();
    assert_eq!(result.status, Status::MoreWork(Direction::Send));
    assert_eq!(result.accepted, 10);
    assert_eq!(peer.server.records.len(), 10);
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Current
    );
    assert_eq!(peer.server.submitted.len(), 3);
    assert_eq!(peer.server.records.len(), 21);
}
#[test]
fn lost_upload_response_replays_the_exact_offer_before_fetching_and_keeps_the_new_edit() {
    let (_temp, library, mut peer) = setup();
    write_primary(&library, &[envelope(1, "Public original sync offer", 1000)]);
    peer.lose_reply = true;
    assert!(matches!(
        run(&library, &mut peer, Limits::DEFAULT),
        Err(receiver::Failure::Remote(cloud::Failure::Network))
    ));
    let original = load(&library).journal.outbound.unwrap().offers[0].clone();
    write_primary(&library, &[envelope(1, "Public newer sync edit", 2000)]);
    let result = run(&library, &mut peer, Limits::DEFAULT).unwrap();
    assert_eq!(result.status, Status::Current);
    assert!(peer.server.submitted[0] == peer.server.submitted[1]);
    assert!(peer.wire_posts[0] == peer.wire_posts[1]);
    assert!(peer.wire_posts[1][0].0 == original.wire);
    assert!(peer.wire_posts[1][0].1 == original.offered.record_version);
    assert!(
        peer.server.submitted[1][0].0.hash().unwrap() == original.offered.envelope.hash().unwrap()
    );
    assert_eq!(
        peer.calls,
        vec![
            Call::Fetch,
            Call::Submit,
            Call::Submit,
            Call::Submit,
            Call::Fetch
        ]
    );
    assert_eq!(
        library.read().unwrap().0[0].content,
        "Public newer sync edit"
    );
}
#[test]
fn a_fetch_failure_after_successful_upload_is_not_a_success_and_restart_keeps_the_ack() {
    let (_temp, library, mut peer) = setup();
    write_primary(
        &library,
        &[envelope(1, "Public acknowledged sync fixture", 1000)],
    );
    peer.fail_fetch_after_post = true;
    assert!(matches!(
        run(&library, &mut peer, Limits::DEFAULT),
        Err(receiver::Failure::Remote(cloud::Failure::Network))
    ));
    assert!(
        load(&library)
            .journal
            .confirmed(Uuid::from_u128(1))
            .is_some()
    );
    assert!(load(&library).journal.outbound.is_none());
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Current
    );
    assert_eq!(peer.server.submitted.len(), 1);
}
#[test]
fn read_only_membership_receives_cloud_changes_and_keeps_unsent_local_edits() {
    let (_temp, library, mut peer) = setup();
    write_primary(
        &library,
        &[envelope(1, "Public read-only local edit", 1000)],
    );
    peer.server
        .add(&envelope(2, "Public read-only remote edit", 1000));
    peer.role = Role::Reader;
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Sending(sender::Status::ReadOnly)
    );
    assert_eq!(library.read().unwrap().0.len(), 2);
    assert!(!peer.calls.contains(&Call::Submit));
}

#[test]
fn a_role_downgrade_after_an_ack_still_receives_post_send_changes_without_another_write() {
    let (_temp, library, mut peer) = setup();
    write_primary(
        &library,
        &[envelope(1, "Public acknowledged before role change", 1000)],
    );
    peer.reader_at = Some(5);
    peer.add_after_post = Some(envelope(2, "Public post-send read-only change", 2000));
    let result = run(&library, &mut peer, Limits::DEFAULT).unwrap();
    assert_eq!(result.status, Status::Sending(sender::Status::ReadOnly));
    assert_eq!(result.accepted, 1);
    assert_eq!(peer.calls, vec![Call::Fetch, Call::Submit, Call::Fetch]);
    assert_eq!(library.read().unwrap().0.len(), 2);
    assert!(load(&library).journal.outbound.is_none());
}

#[test]
fn read_only_membership_cannot_replay_an_ambiguous_offer_or_bypass_it_by_fetching() {
    let (_temp, library, mut peer) = setup();
    write_primary(
        &library,
        &[envelope(1, "Public ambiguous role-change fixture", 1000)],
    );
    peer.lose_reply = true;
    assert!(run(&library, &mut peer, Limits::DEFAULT).is_err());
    let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
    peer.role = Role::Reader;
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Sending(sender::Status::ReadOnly)
    );
    assert_eq!(peer.calls, vec![Call::Fetch, Call::Submit]);
    assert_eq!(
        fs::read(library.root.join("Sync/journal.bin")).unwrap(),
        before
    );
}
#[test]
fn server_backoff_does_not_starve_receiving_and_does_not_repeat_mutations_in_one_action() {
    let (_temp, library, mut peer) = setup();
    write_primary(
        &library,
        &[envelope(1, "Public rate-limited local edit", 1000)],
    );
    peer.reject = Some(Uuid::from_u128(1));
    let result = run(&library, &mut peer, Limits::DEFAULT).unwrap();
    assert_eq!(
        result.status,
        Status::Sending(sender::Status::ServerDeferred {
            code: cloud::ErrorCode::RateLimited,
            retry_after: Some(60)
        })
    );
    assert_eq!(peer.calls, vec![Call::Fetch, Call::Submit, Call::Fetch]);
    assert_eq!(result.rejected, 1);
    assert!(
        load(&library)
            .journal
            .outbound
            .as_ref()
            .unwrap()
            .acknowledged()
    );
    peer.server
        .add(&envelope(2, "Public received during backoff", 1000));
    let result = run(&library, &mut peer, Limits::DEFAULT).unwrap();
    assert!(matches!(
        result.status,
        Status::Sending(sender::Status::ServerDeferred { .. })
    ));
    assert_eq!(peer.calls.iter().filter(|c| **c == Call::Submit).count(), 1);
    assert_eq!(library.read().unwrap().0.len(), 2);
}
#[test]
fn a_local_edit_at_the_final_check_cannot_be_reported_as_current_without_uploading_it() {
    let (_temp, library, mut peer) = setup();
    peer.server
        .add(&envelope(1, "Public before final check", 1000));
    peer.edit_at = Some((
        3,
        library.root.clone(),
        vec![envelope(1, "Public edit at final check", 2000)],
    ));
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Current
    );
    assert_eq!(peer.server.submitted.len(), 1);
    assert_eq!(
        library.read().unwrap().0[0].content,
        "Public edit at final check"
    );
}
#[test]
fn a_feed_rotation_at_the_final_check_requires_a_new_snapshot_before_upload() {
    let (_temp, library, mut peer) = setup();
    peer.rotate_at = Some(3);
    write_primary(
        &library,
        &[envelope(1, "Public rotated-feed local fixture", 1000)],
    );
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Current
    );
    assert_eq!(&peer.calls[..3], &[Call::Fetch, Call::Fetch, Call::Submit]);
    assert!(load(&library).journal.inbox.feed == Some(feed(44)));
}

#[test]
fn a_scope_change_at_the_final_check_preserves_admitted_receipts_and_never_claims_current() {
    let (_temp, library, mut peer) = setup();
    peer.server
        .add(&envelope(2, "Public admitted pre-boundary fixture", 1000));
    write_primary(&library, &[envelope(1, "Public held boundary edit", 1000)]);
    peer.scope_at = Some(3);
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).err(),
        Some(receiver::Failure::ScopeReview)
    );
    assert_eq!(peer.calls, vec![Call::Fetch]);
    assert!(
        load(&library)
            .journal
            .confirmed(Uuid::from_u128(2))
            .is_some()
    );
    assert_eq!(library.read().unwrap().0.len(), 2);
}
#[test]
fn checkpoint_scope_epoch_and_session_admission_fail_before_data_plane_access() {
    for boundary in 0..4 {
        let (_temp, library, mut peer) = setup();
        let mut checkpoint = load(&library);
        checkpoint.journal.key_epoch = Some(if boundary == 1 { 2 } else { 1 });
        if boundary == 3 {
            checkpoint.journal = crate::journal::Journal::new(Scope {
                membership: cloud::Binding::from_checkpoint([0x99; 32]),
                dataset: scope().dataset,
            });
            crate::model::atomic_write(
                &library.root.join("snippets.json"),
                b"public-invalid-primary-fixture",
            )
            .unwrap();
        }
        checkpoint.save(&library, &key(), &SALT).unwrap();
        let before = fs::read(library.root.join("Sync/journal.bin")).unwrap();
        if boundary == 0 {
            peer.scope_at = Some(1);
        }
        let valid = Cell::new(boundary != 2);
        let guard = || {
            if valid.get() {
                Ok(())
            } else {
                Err(receiver::Failure::SessionChanged)
            }
        };
        assert!(
            owner(&library, &key(), &scope(), &guard)
                .synchronize(&mut peer, Limits::DEFAULT)
                .is_err()
        );
        assert!(peer.calls.is_empty());
        assert_eq!(
            fs::read(library.root.join("Sync/journal.bin")).unwrap(),
            before
        );
    }
}

#[test]
fn local_absence_stays_review_required_instead_of_becoming_an_implicit_tombstone() {
    let (_temp, library, mut peer) = setup();
    peer.server
        .add(&envelope(1, "Public missing-local sync fixture", 1000));
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Current
    );
    write_primary(&library, &[]);
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Sending(sender::Status::LocalReview)
    );
    assert!(peer.server.submitted.is_empty());
    assert!(!peer.server.records[&Uuid::from_u128(1)].0.deleted);
}

#[test]
fn remote_deletion_remains_queued_for_native_review_with_the_local_body_intact() {
    let (_temp, library, mut peer) = setup();
    let live = envelope(1, "Public cloud-deletion sync fixture", 1000);
    peer.server.add(&live);
    run(&library, &mut peer, Limits::DEFAULT).unwrap();
    let deleted = live
        .tombstone(crate::clock::Hlc::foreign(5000), "22222222".into(), true)
        .unwrap();
    peer.server.add(&deleted);
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Receiving(receiver::Status::DeletionReview)
    );
    assert_eq!(library.read().unwrap().0.len(), 1);
    assert!(load(&library).journal.inbox.next().is_some());
    assert!(peer.server.submitted.is_empty());
}

#[test]
fn complete_snapshot_absence_halts_the_whole_cycle_and_preserves_local_records() {
    let (_temp, library, mut peer) = setup();
    peer.server
        .add(&envelope(1, "Public missing-snapshot sync fixture", 1000));
    run(&library, &mut peer, Limits::DEFAULT).unwrap();
    peer.server.records.clear();
    let mut checkpoint = load(&library);
    checkpoint.journal.inbox.restart_snapshot().unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    assert_eq!(
        run(&library, &mut peer, Limits::DEFAULT).unwrap().status,
        Status::Receiving(receiver::Status::SnapshotReview)
    );
    assert_eq!(library.read().unwrap().0.len(), 1);
    assert!(peer.server.submitted.is_empty());
}

#[test]
fn a_body_conflict_is_preserved_and_acknowledged_before_its_source_in_one_cycle() {
    let (_temp, library, mut peer) = setup();
    write_primary(&library, &[envelope(1, "Public losing sync body", 1000)]);
    peer.server
        .add(&envelope(1, "Public winning sync body", 2_000_000_000_000));
    let result = run(&library, &mut peer, Limits::DEFAULT).unwrap();
    assert_eq!(result.status, Status::Current);
    assert_eq!(peer.server.submitted.len(), 2);
    assert!(peer.server.submitted[0][0].0.id != Uuid::from_u128(1));
    assert_eq!(peer.server.submitted[1][0].0.id, Uuid::from_u128(1));
    let saved = load(&library);
    assert!(!saved.journal.has_preservation_work());
    assert!(saved.journal.pending().unwrap().is_empty());
    let rows = library.read().unwrap().0;
    assert!(
        rows.iter()
            .any(|s| s.id == Uuid::from_u128(1) && s.content == "Public winning sync body")
    );
    assert!(rows.iter().any(|s| s.id != Uuid::from_u128(1)
        && s.content == "Public losing sync body"
        && !s.is_enabled));
}
#[test]
fn invalid_budgets_fail_without_touching_files_or_a_remote() {
    for limits in [
        Limits {
            receive: 0,
            send: 1,
        },
        Limits {
            receive: 1,
            send: 0,
        },
        Limits {
            receive: 9,
            send: 1,
        },
        Limits {
            receive: 1,
            send: 9,
        },
    ] {
        let (_temp, library, mut peer) = setup();
        assert_eq!(
            run(&library, &mut peer, limits).err(),
            Some(receiver::Failure::InvalidPage)
        );
        assert_eq!(peer.preflights, 0);
        assert!(!library.root.join("Sync").exists());
        assert!(!library.root.join("device.json").exists());
    }
}
