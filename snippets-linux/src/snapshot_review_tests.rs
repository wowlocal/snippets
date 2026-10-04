//! Isolated real encrypted checkpoint/primary/merge tests. The transport is a
//! positional CAS fixture; no account, keyring, PAM, network or user data.
use super::*;
use crate::{
    cloud::{self, Binding, Cursor, RecordVersion, ServerRecord},
    crypto::RootKey,
    inbound::Inbox,
    journal::{Journal, ReviewAncestor, Scope},
    merge,
    model::{self, Library, Snippet},
    receiver::{FetchedPage, RemoteResult},
    sender,
    wire::WireRecord,
};
use std::{cell::Cell, fs};

pub(crate) const SALT: [u8; 32] = [0x66; 32];
pub(crate) fn key() -> RootKey {
    RootKey::from_bytes(&[0x55; 32]).unwrap()
}
pub(crate) fn scope() -> Scope {
    Scope {
        membership: Binding::from_checkpoint([0x11; 32]),
        dataset: Binding::from_checkpoint([0x22; 32]),
    }
}
pub(crate) fn feed(epoch: u128) -> Feed {
    Feed::new(Uuid::from_u128(epoch), 1).unwrap()
}
pub(crate) fn version(label: &str) -> RecordVersion {
    RecordVersion::from_checkpoint(format!("public-fixture-record-version-{label:0>16}")).unwrap()
}
pub(crate) fn cursor(label: &str) -> Cursor {
    Cursor::from_checkpoint(format!("public-fixture-cursor-{label}")).unwrap()
}
pub(crate) fn envelope(id: u128, body: &str, wall: u64) -> Envelope {
    let mut snippet = Snippet::new("Public review fixture", body);
    snippet.id = Uuid::from_u128(id);
    snippet.created_at = 0.0;
    snippet.updated_at = 1.0;
    Envelope::plain(
        &snippet,
        crate::clock::Hlc::foreign(wall),
        "22222222".into(),
    )
    .unwrap()
}
pub(crate) fn write_primary(library: &Library, records: &[Envelope]) {
    let snippets = records
        .iter()
        .filter_map(|e| e.snippet().unwrap())
        .collect::<Vec<_>>();
    model::atomic_write(
        &library.root.join("snippets.json"),
        &model::encode_library(&snippets, false).unwrap(),
    )
    .unwrap();
}
fn server_record(wire: WireRecord, record_version: &RecordVersion) -> ServerRecord {
    let mut value = serde_json::to_value(wire).unwrap();
    value["recordVersion"] = record_version.for_checkpoint().into();
    serde_json::from_value(value).unwrap()
}
pub(crate) struct Server {
    pub(crate) scope: Scope,
    pub(crate) feed: Feed,
    pub(crate) records: BTreeMap<Uuid, (WireRecord, RecordVersion)>,
    pub(crate) fetched: Vec<Option<Cursor>>,
    pub(crate) submitted: Vec<Vec<(Envelope, Option<RecordVersion>)>>,
    generation: usize,
}
impl Server {
    pub(crate) fn new() -> Self {
        Self {
            scope: scope(),
            feed: feed(3),
            records: BTreeMap::new(),
            fetched: vec![],
            submitted: vec![],
            generation: 0,
        }
    }
    fn observation(&self) -> Observation {
        Observation {
            scope: self.scope.clone(),
            feed: self.feed.clone(),
        }
    }
    pub(crate) fn add(&mut self, e: &Envelope) {
        self.generation += 1;
        self.records.insert(
            e.id,
            (
                WireRecord::seal(e, &key(), &SALT).unwrap(),
                version(&self.generation.to_string()),
            ),
        );
    }
}
impl Remote for Server {
    fn preflight(&mut self) -> RemoteResult<Observation> {
        Ok(self.observation())
    }
    fn fetch(&mut self, requested: Option<&Cursor>) -> RemoteResult<FetchedPage> {
        self.fetched.push(requested.cloned());
        assert!(requested.is_none());
        Ok(FetchedPage {
            observation: self.observation(),
            records: self
                .records
                .values()
                .map(|(wire, version)| server_record(wire.clone(), version))
                .collect(),
            cursor: cursor("fresh"),
            full_snapshot: true,
            has_more: false,
        })
    }
}
impl sender::Remote for Server {
    fn preflight(&mut self) -> RemoteResult<sender::SendObservation> {
        Ok(sender::SendObservation {
            observation: self.observation(),
            role: cloud::Role::Writer,
        })
    }
    fn submit(&mut self, offers: &[cloud::Offer]) -> RemoteResult<sender::Reply> {
        self.submitted.push(
            offers
                .iter()
                .map(|o| {
                    (
                        o.record.open(&key(), &SALT).unwrap(),
                        o.expected_record_version.clone(),
                    )
                })
                .collect(),
        );
        let mut outcomes = vec![];
        for offer in offers {
            let occupant = self.records.get(&offer.record.id);
            let matches = match (occupant, &offer.expected_record_version) {
                (None, None) => true,
                (Some((_, version)), Some(expected)) => version == expected,
                _ => false,
            };
            if matches {
                self.generation += 1;
                let next = version(&self.generation.to_string());
                self.records
                    .insert(offer.record.id, (offer.record.clone(), next.clone()));
                outcomes.push(cloud::Outcome::Accepted {
                    record_version: next,
                    revision: offer.record.rev.clone(),
                });
            } else {
                let (wire, version) = occupant.expect("occupied CAS conflict");
                outcomes.push(cloud::Outcome::Conflict {
                    authoritative_record: server_record(wire.clone(), version),
                });
            }
        }
        let partial = outcomes
            .iter()
            .any(|outcome| !matches!(outcome, cloud::Outcome::Accepted { .. }));
        Ok(sender::Reply {
            observation: self.observation(),
            outcomes,
            partial,
        })
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
fn load(library: &Library) -> Checkpoint {
    Checkpoint::load(library, &key(), &SALT, scope()).unwrap()
}
fn halt(journal: &mut Journal, seen: &[Uuid]) {
    journal.key_epoch = Some(1);
    journal.inbox = Inbox::default();
    journal.inbox.select_feed(feed(3)).unwrap();
    let confirmed = seen
        .iter()
        .map(|id| journal.confirmed(*id).unwrap().clone())
        .collect::<Vec<_>>();
    journal
        .inbox
        .receive(&feed(3), None, confirmed, cursor("old"), true, false)
        .unwrap();
    while journal.inbox.next().is_some() {
        journal.inbox.acknowledge_record().unwrap();
    }
    journal.inbox.complete_page().unwrap();
    let known = journal.agreed_envelopes();
    journal
        .inbox
        .finish_snapshot(known.keys().copied())
        .unwrap();
    assert!(journal.inbox.needs_review());
}
fn setup() -> (tempfile::TempDir, Library) {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let records = [
        envelope(1, "Public retained one", 1000),
        envelope(2, "Public retained two", 2000),
    ];
    write_primary(&library, &records);
    let mut checkpoint = load(&library);
    for e in records {
        checkpoint.journal.projected.insert(e.id, e.clone());
        checkpoint
            .journal
            .record_confirmed(e, version("old"))
            .unwrap();
    }
    halt(&mut checkpoint.journal, &[Uuid::from_u128(1)]);
    checkpoint.save(&library, &key(), &SALT).unwrap();
    (temp, library)
}
fn saved(library: &Library) -> Vec<u8> {
    fs::read(library.root.join("Sync/journal.bin")).unwrap()
}

#[test]
fn inspection_and_cancellation_leave_the_halt_and_primary_unchanged() {
    let (_temp, library) = setup();
    let bytes = saved(&library);
    let primary = fs::read(library.root.join("snippets.json")).unwrap();
    let mut server = Server::new();
    let review = owner(&library, &key(), &scope(), &|| Ok(()))
        .prepare_missing_snapshot_review(&mut server)
        .unwrap();
    assert_eq!(
        review.summary(),
        Summary {
            local_records: 2,
            missing_records: 1,
            preservation_copies: 0
        }
    );
    drop(review);
    assert!(load(&library).journal.inbox.needs_review());
    assert_eq!(saved(&library), bytes);
    assert_eq!(
        fs::read(library.root.join("snippets.json")).unwrap(),
        primary
    );
    assert!(server.fetched.is_empty() && server.submitted.is_empty());
}

#[test]
fn confirmation_retains_primary_intent_and_merge_ancestors_but_clears_old_generations() {
    let (_temp, library) = setup();
    let primary = fs::read(library.root.join("snippets.json")).unwrap();
    let old = load(&library)
        .journal
        .confirmed(Uuid::from_u128(2))
        .unwrap()
        .envelope
        .clone();
    let mut server = Server::new();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
    owner
        .resume_missing_snapshot_review(&mut server, review)
        .unwrap();
    let checkpoint = load(&library);
    assert_eq!(checkpoint.journal.key_epoch, Some(1));
    assert!(!checkpoint.journal.inbox.needs_review());
    assert!(checkpoint.journal.inbox.cursor().is_none());
    assert!(checkpoint.journal.agreed_envelopes().is_empty());
    assert!(checkpoint.journal.outbound.is_none());
    assert!(checkpoint.journal.merge_ancestor(old.id) == Some(&old));
    for e in checkpoint.journal.pending().unwrap() {
        let entry = checkpoint.journal.entry(e.id).unwrap();
        assert_eq!(entry.generation, 1);
        assert!(entry.offered.is_none());
        assert!(matches!(
            entry.review,
            ReviewAncestor::Reviewed {
                primary: Some(_),
                previous_merge: Some(_)
            }
        ));
    }
    assert_eq!(
        fs::read(library.root.join("snippets.json")).unwrap(),
        primary
    );
    let bytes = saved(&library);
    for marker in [
        "Public retained",
        "public-fixture-record-version",
        "public-fixture-cursor",
    ] {
        assert!(!bytes.windows(marker.len()).any(|w| w == marker.as_bytes()));
    }
}

#[test]
fn after_restart_sending_waits_for_a_fresh_snapshot_then_uses_new_create_cas() {
    let (_temp, library) = setup();
    let mut server = Server::new();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
    owner
        .resume_missing_snapshot_review(&mut server, review)
        .unwrap();
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::ReceiveFirst
    );
    assert!(server.submitted.is_empty());
    assert_eq!(
        owner.receive(&mut server, 1).unwrap().status,
        receiver::Status::Current
    );
    assert!(server.fetched == vec![None]);
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::Settled
    );
    assert_eq!(server.submitted.len(), 1);
    assert!(server.submitted[0].iter().all(|(_, cas)| cas.is_none()));
    assert_eq!(library.read().unwrap().0.len(), 2);
}

#[test]
fn a_primary_edit_or_new_checkpoint_invalidates_the_exact_review() {
    for edit_primary in [false, true] {
        let (_temp, library) = setup();
        let mut server = Server::new();
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
        if edit_primary {
            write_primary(
                &library,
                &[
                    envelope(1, "Public later local edit", 4000),
                    envelope(2, "Public retained two", 2000),
                ],
            );
        } else {
            load(&library).save(&library, &key, &SALT).unwrap();
        }
        let bytes = saved(&library);
        let primary = fs::read(library.root.join("snippets.json")).unwrap();
        assert_eq!(
            owner
                .resume_missing_snapshot_review(&mut server, review)
                .err(),
            Some(Failure::Changed)
        );
        assert_eq!(saved(&library), bytes);
        assert_eq!(
            fs::read(library.root.join("snippets.json")).unwrap(),
            primary
        );
        assert!(load(&library).journal.inbox.needs_review());
    }
}

#[test]
fn changed_scope_key_epoch_or_session_fails_before_primary_recovery() {
    for change in 0..3 {
        let (_temp, library) = setup();
        let key = key();
        let scope = scope();
        let valid = Cell::new(true);
        let guard = || {
            if valid.get() {
                Ok(())
            } else {
                Err(receiver::Failure::SessionChanged)
            }
        };
        let mut server = Server::new();
        let review = owner(&library, &key, &scope, &guard)
            .prepare_missing_snapshot_review(&mut server)
            .unwrap();
        let bytes = saved(&library);
        fs::write(
            library.root.join("snippets.json"),
            b"public invalid primary fixture",
        )
        .unwrap();
        let marker = library.root.join("Sync/primary.pending");
        fs::write(&marker, b"public pending marker fixture").unwrap();
        let mut resumed = owner(&library, &key, &scope, &guard);
        match change {
            0 => server.scope.membership = Binding::from_checkpoint([0x99; 32]),
            1 => {
                resumed.key_epoch = 2;
                server.feed.key_epoch = 2;
            }
            _ => valid.set(false),
        }
        assert!(
            resumed
                .resume_missing_snapshot_review(&mut server, review)
                .is_err()
        );
        assert_eq!(saved(&library), bytes);
        assert_eq!(fs::read(marker).unwrap(), b"public pending marker fixture");
        assert!(server.fetched.is_empty() && server.submitted.is_empty());
    }
}

#[test]
fn wrong_checkpoint_key_and_rotated_feed_cannot_confirm_an_old_review() {
    for replace_key in [false, true] {
        let (_temp, library) = setup();
        let key = key();
        let scope = scope();
        let mut server = Server::new();
        let review = owner(&library, &key, &scope, &|| Ok(()))
            .prepare_missing_snapshot_review(&mut server)
            .unwrap();
        let bytes = saved(&library);
        let replacement = RootKey::from_bytes(&[0x77; 32]).unwrap();
        let mut resumed = owner(&library, &key, &scope, &|| Ok(()));
        if replace_key {
            resumed.checkpoint_key = &replacement;
        } else {
            server.feed = feed(4);
        }
        assert!(
            resumed
                .resume_missing_snapshot_review(&mut server, review)
                .is_err()
        );
        assert_eq!(saved(&library), bytes);
        assert!(load(&library).journal.inbox.needs_review());
    }
}

#[test]
fn a_missing_local_file_is_a_separate_review_and_never_a_mass_delete() {
    let (_temp, library) = setup();
    let bytes = saved(&library);
    fs::remove_file(library.root.join("snippets.json")).unwrap();
    let mut server = Server::new();
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .prepare_missing_snapshot_review(&mut server)
            .err(),
        Some(Failure::LocalAbsence)
    );
    assert_eq!(saved(&library), bytes);
    assert!(!library.root.join("snippets.json").exists());
    assert!(server.submitted.is_empty());
}

#[test]
fn checkpoint_faults_leave_either_the_old_halt_or_the_complete_resumed_state() {
    for after in [false, true] {
        let (_temp, library) = setup();
        let primary = fs::read(library.root.join("snippets.json")).unwrap();
        let key = key();
        let scope = scope();
        let owner = owner(&library, &key, &scope, &|| Ok(()));
        let mut server = Server::new();
        let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
        assert!(
            owner
                .resume_review_inner(&mut server, review, Some(after))
                .is_err()
        );
        let checkpoint = load(&library);
        assert_eq!(checkpoint.journal.inbox.needs_review(), !after);
        assert_eq!(
            fs::read(library.root.join("snippets.json")).unwrap(),
            primary
        );
        if after {
            assert_eq!(
                owner.prepare_missing_snapshot_review(&mut server).err(),
                Some(Failure::Unavailable)
            );
            assert_eq!(
                owner.send(&mut server, 1).unwrap().status,
                sender::Status::ReceiveFirst
            );
        } else {
            let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
            owner
                .resume_missing_snapshot_review(&mut server, review)
                .unwrap();
        }
    }
}

#[test]
fn old_merge_ancestor_preserves_independent_local_body_and_remote_metadata_edits() {
    let (_temp, library) = setup();
    write_primary(
        &library,
        &[
            envelope(1, "Public independent local body", 3000),
            envelope(2, "Public retained two", 2000),
        ],
    );
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let mut server = Server::new();
    let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
    owner
        .resume_missing_snapshot_review(&mut server, review)
        .unwrap();
    let mut remote = envelope(1, "Public retained one", 4000);
    remote.fields.as_mut().unwrap().is_pinned = true;
    server.add(&remote);
    assert_eq!(
        owner.receive(&mut server, 1).unwrap().status,
        receiver::Status::Current
    );
    let snippets = library.read().unwrap().0;
    assert_eq!(snippets.len(), 2);
    let kept = snippets
        .iter()
        .find(|s| s.id == Uuid::from_u128(1))
        .unwrap();
    assert_eq!(kept.content, "Public independent local body");
    assert!(kept.is_pinned);
    assert!(load(&library).journal.conflict_snapshots().is_empty());
}

#[test]
fn a_post_review_primary_edit_supersedes_a_retained_journal_only_desire() {
    let (_temp, library) = setup();
    let mut checkpoint = load(&library);
    checkpoint
        .journal
        .desire(envelope(1, "Public held journal edit", 5000))
        .unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let mut server = Server::new();
    let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
    owner
        .resume_missing_snapshot_review(&mut server, review)
        .unwrap();
    write_primary(
        &library,
        &[
            envelope(1, "Public newer physical edit", 6000),
            envelope(2, "Public retained two", 2000),
        ],
    );
    owner.receive(&mut server, 1).unwrap();
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::Settled
    );
    let (sent, _) = server.submitted[0]
        .iter()
        .find(|(e, _)| e.id == Uuid::from_u128(1))
        .unwrap();
    assert_eq!(
        sent.fields.as_ref().unwrap().content.as_slice(),
        b"Public newer physical edit"
    );
    let primary = library.read().unwrap().0;
    assert_eq!(
        primary
            .iter()
            .find(|s| s.id == Uuid::from_u128(1))
            .unwrap()
            .content,
        "Public newer physical edit"
    );
}

#[test]
fn immutable_copy_is_resent_before_source_and_later_journal_only_edit_after_review() {
    let (_temp, library) = setup();
    let loser = envelope(1, "Public losing body", 1000);
    let winner = envelope(1, "Public winning body", 2000);
    let merged = merge::merge(None, Some(&loser), Some(&winner)).unwrap();
    let source = merged.survivor.unwrap();
    let copy = merged.conflict_copies[0].clone();
    let mut edited = copy.clone();
    edited.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public later copy edit".to_vec());
    edited.hlc = crate::clock::Hlc::foreign(4000);
    let missing = envelope(2, "Public retained two", 2000);
    write_primary(&library, &[source.clone(), copy.clone(), missing]);
    let mut checkpoint = load(&library);
    checkpoint
        .journal
        .projected
        .insert(source.id, source.clone());
    checkpoint.journal.projected.insert(copy.id, copy.clone());
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
        .accept_offered(&offered, version("old-copy"))
        .unwrap();
    checkpoint.journal.desire(source.clone()).unwrap();
    let offered = checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&source))
        .unwrap()
        .remove(0);
    checkpoint
        .journal
        .accept_offered(&offered, version("old-source"))
        .unwrap();
    checkpoint.journal.desire(edited.clone()).unwrap();
    halt(&mut checkpoint.journal, &[source.id, copy.id]);
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let key = key();
    let scope = scope();
    let owner = owner(&library, &key, &scope, &|| Ok(()));
    let mut server = Server::new();
    let review = owner.prepare_missing_snapshot_review(&mut server).unwrap();
    assert_eq!(review.summary().preservation_copies, 1);
    owner
        .resume_missing_snapshot_review(&mut server, review)
        .unwrap();
    let resumed = load(&library);
    assert!(resumed.journal.conflict_snapshots().get(&copy.id) == Some(&copy));
    assert!(resumed.journal.entry(copy.id).unwrap().desired == edited);
    assert!(
        resumed
            .journal
            .pending()
            .unwrap()
            .iter()
            .any(|e| e == &copy)
    );
    assert!(
        !resumed
            .journal
            .pending()
            .unwrap()
            .iter()
            .any(|e| e.id == source.id)
    );
    owner.receive(&mut server, 1).unwrap();
    owner.send(&mut server, 1).unwrap();
    assert!(
        server.submitted[0]
            .iter()
            .any(|(e, cas)| e == &copy && cas.is_none())
    );
    assert!(!server.submitted[0].iter().any(|(e, _)| e.id == source.id));
    owner.send(&mut server, 1).unwrap();
    assert!(server.submitted[1].iter().any(|(e, _)| e.id == source.id));
    owner.send(&mut server, 1).unwrap();
    assert!(
        server.submitted[2]
            .iter()
            .any(|(e, cas)| e == &edited && cas.is_some())
    );
    assert_eq!(
        owner.send(&mut server, 1).unwrap().status,
        sender::Status::Settled
    );
    assert_eq!(server.submitted.len(), 3);
    let primary = library.read().unwrap().0;
    assert_eq!(
        primary.iter().find(|s| s.id == copy.id).unwrap().content,
        "Public later copy edit"
    );
}
