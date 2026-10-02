//! Public fictional data only. Real AEAD/checkpoint/primary code, no sockets,
//! Secret Service, PAM, host account or user support directory.
use super::*;
use crate::{
    clock::Hlc,
    cloud::Binding,
    model::Snippet,
    wire::{Envelope, WireRecord},
};
use std::{cell::Cell, collections::VecDeque, fs};
use uuid::Uuid;

const SALT: [u8; 32] = [0x66; 32];
fn key() -> RootKey {
    RootKey::from_bytes(&[0x55; 32]).unwrap()
}
fn scope() -> Scope {
    Scope {
        membership: Binding::from_checkpoint([0x11; 32]),
        dataset: Binding::from_checkpoint([0x22; 32]),
    }
}
fn feed(epoch: u128) -> Feed {
    Feed::new(Uuid::from_u128(epoch), 1).unwrap()
}
fn cursor(label: &str) -> Cursor {
    Cursor::from_checkpoint(format!("public-fixture-cursor-{label}")).unwrap()
}
fn envelope(id: u128, body: &str, wall: u64) -> Envelope {
    let mut s = Snippet::new("Public receiver fixture", body);
    s.id = Uuid::from_u128(id);
    s.created_at = 0.0;
    s.updated_at = 1.0;
    Envelope::plain(&s, Hlc::foreign(wall), "22222222".into()).unwrap()
}
fn record(e: &Envelope, version: &str) -> ServerRecord {
    let wire = WireRecord::seal(e, &key(), &SALT).unwrap();
    let mut value = serde_json::to_value(wire).unwrap();
    value["recordVersion"] = format!("public-fixture-record-version-{version:0>16}").into();
    serde_json::from_value(value).unwrap()
}
fn page(records: Vec<ServerRecord>, label: &str, snapshot: bool, more: bool) -> FetchedPage {
    FetchedPage {
        observation: Observation {
            scope: scope(),
            feed: feed(3),
        },
        records,
        cursor: cursor(label),
        full_snapshot: snapshot,
        has_more: more,
    }
}
struct RemoteFixture {
    scope: Scope,
    feed: Feed,
    replies: VecDeque<RemoteResult<FetchedPage>>,
    requested: Vec<Option<Cursor>>,
    preflights: usize,
    change_scope_at: Option<usize>,
    change_feed_at: Option<usize>,
    change_key_at: Option<usize>,
}
impl RemoteFixture {
    fn new(pages: Vec<FetchedPage>) -> Self {
        Self {
            scope: scope(),
            feed: feed(3),
            replies: pages.into_iter().map(Ok).collect(),
            requested: vec![],
            preflights: 0,
            change_scope_at: None,
            change_feed_at: None,
            change_key_at: None,
        }
    }
}
impl Remote for RemoteFixture {
    fn preflight(&mut self) -> RemoteResult<Observation> {
        self.preflights += 1;
        if self.change_scope_at == Some(self.preflights) {
            self.scope.membership = Binding::from_checkpoint([0x99; 32]);
        }
        if self.change_feed_at == Some(self.preflights) {
            self.feed = feed(4);
        }
        if self.change_key_at == Some(self.preflights) {
            self.feed.key_epoch = 2;
        }
        Ok(Observation {
            scope: self.scope.clone(),
            feed: self.feed.clone(),
        })
    }
    fn fetch(&mut self, cursor: Option<&Cursor>) -> RemoteResult<FetchedPage> {
        self.requested.push(cursor.cloned());
        self.replies
            .pop_front()
            .expect("fixture has no unexpected requests")
    }
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
        validate_session: guard,
    }
}
fn load(library: &Library) -> Checkpoint {
    Checkpoint::load(library, &key(), &SALT, scope()).unwrap()
}
fn body(library: &Library, id: u128) -> String {
    library
        .read()
        .unwrap()
        .0
        .into_iter()
        .find(|s| s.id == Uuid::from_u128(id))
        .unwrap()
        .content
}
fn receive_page(
    library: &Library,
    records: Vec<ServerRecord>,
    label: &str,
    full: bool,
    more: bool,
) -> Progress {
    let mut remote = RemoteFixture::new(vec![page(records, label, full, more)]);
    owner(library, &key(), &scope(), &|| Ok(()))
        .receive(&mut remote, 1)
        .unwrap()
}

#[test]
fn empty_install_receives_ordinary_records_without_creating_a_vault() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let progress = receive_page(
        &library,
        vec![record(&envelope(1, "Public remote body", 1000), "one")],
        "one",
        true,
        false,
    );
    assert_eq!(
        progress,
        Progress {
            status: Status::Current,
            received_records: 1,
            applied_records: 1,
            completed_pages: 1
        }
    );
    assert_eq!(body(&library, 1), "Public remote body");
    let checkpoint = load(&library);
    assert!(checkpoint.journal.entry(Uuid::from_u128(1)).is_none());
    assert!(checkpoint.journal.inbox.pending.is_none());
    assert!(checkpoint.journal.inbox.snapshot.is_none());
    assert!(checkpoint.journal.inbox.fetched_cursor == Some(cursor("one")));
    assert!(checkpoint.journal.inbox.applied_cursor == Some(cursor("one")));
    assert!(!temp.path().join("Vault").exists());
    let encrypted = fs::read(temp.path().join("Sync/journal.bin")).unwrap();
    for marker in [
        "Public remote body",
        "public-fixture-cursor",
        "public-fixture-record-version",
    ] {
        assert!(
            !encrypted
                .windows(marker.len())
                .any(|w| w == marker.as_bytes())
        );
    }
}

#[test]
fn delta_keeps_duplicate_record_generations_in_server_order() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    receive_page(
        &library,
        vec![record(&envelope(1, "Original public body", 1000), "one")],
        "one",
        true,
        false,
    );
    let progress = receive_page(
        &library,
        vec![
            record(&envelope(1, "Intermediate public body", 2000), "two"),
            record(&envelope(1, "Newest public body", 3000), "three"),
        ],
        "three",
        false,
        false,
    );
    assert_eq!(progress.applied_records, 2);
    assert_eq!(body(&library, 1), "Newest public body");
    assert!(
        load(&library)
            .journal
            .confirmed(Uuid::from_u128(1))
            .unwrap()
            .envelope
            == envelope(1, "Newest public body", 3000)
    );
}

#[test]
fn faults_on_both_sides_of_every_inbox_save_resume_from_durable_state() {
    for number in 1..=4 {
        for after in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let library = Library::open(temp.path().into()).unwrap();
            let e = envelope(1, "Public crash fixture", 1000);
            let mut remote =
                RemoteFixture::new(vec![page(vec![record(&e, "one")], "one", true, false)]);
            let mut fault = Fault {
                saves: 0,
                save: Some((number, after)),
                primary: false,
            };
            assert!(matches!(
                owner(&library, &key(), &scope(), &|| Ok(())).receive_inner(
                    &mut remote,
                    1,
                    &mut fault
                ),
                Err(Failure::Journal(journal::Failure::Storage))
            ));
            let before = load(&library);
            let queued = before.journal.inbox.has_pending_page();
            let mut retry = if before.journal.inbox.cursor().is_some() {
                // Once the page is durably fetched, a retry drains it without HTTP;
                // an already completed page continues with a delta, never snapshot.
                RemoteFixture::new(if queued {
                    vec![]
                } else {
                    vec![page(vec![], "one", false, false)]
                })
            } else {
                RemoteFixture::new(vec![page(vec![record(&e, "one")], "one", true, false)])
            };
            let progress = owner(&library, &key(), &scope(), &|| Ok(()))
                .receive(&mut retry, 1)
                .unwrap();
            assert_eq!(progress.status, Status::Current);
            assert_eq!(body(&library, 1), "Public crash fixture");
            assert_eq!(library.read().unwrap().0.len(), 1);
            assert!(load(&library).journal.inbox.pending.is_none());
            if queued {
                assert!(retry.requested.is_empty());
            }
        }
    }
}

#[test]
fn crash_after_primary_apply_replays_without_losing_the_conflict_copy() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut s = envelope(1, "Local losing public body", 1)
        .snippet()
        .unwrap()
        .unwrap();
    s.updated_at = 0.001;
    crate::model::atomic_write(
        &library.path(),
        &crate::model::encode_library(&[s], false).unwrap(),
    )
    .unwrap();
    let remote_e = envelope(1, "Remote winning public body", 2_000_000_000_000);
    let mut remote = RemoteFixture::new(vec![page(
        vec![record(&remote_e, "one")],
        "one",
        true,
        false,
    )]);
    let mut fault = Fault {
        primary: true,
        ..Fault::default()
    };
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(())).receive_inner(&mut remote, 1, &mut fault),
        Err(Failure::Primary(primary::Failure::RecoveryRequired))
    ));
    assert_eq!(library.read().unwrap().0.len(), 2);
    let frozen_before = load(&library).journal.conflict_snapshots();
    assert_eq!(frozen_before.len(), 1);
    let mut retry = RemoteFixture::new(vec![]);
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .receive(&mut retry, 1)
        .unwrap();
    assert_eq!(progress.status, Status::Current);
    let snippets = library.read().unwrap().0;
    assert_eq!(snippets.len(), 2);
    assert!(
        snippets
            .iter()
            .any(|s| s.content == "Local losing public body" && !s.is_enabled)
    );
    assert_eq!(body(&library, 1), "Remote winning public body");
    assert!(load(&library).journal.conflict_snapshots() == frozen_before);
    assert!(retry.requested.is_empty());
}

#[test]
fn incomplete_snapshot_does_not_treat_a_later_page_record_as_missing() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let a = envelope(1, "Public A", 1000);
    let b = envelope(2, "Public B", 1000);
    receive_page(
        &library,
        vec![record(&a, "a"), record(&b, "b")],
        "old",
        true,
        false,
    );
    let mut checkpoint = load(&library);
    checkpoint.journal.inbox.restart_snapshot().unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let first = receive_page(
        &library,
        vec![record(&a, "a")],
        "snapshot-page-one",
        true,
        true,
    );
    assert_eq!(first.status, Status::MorePages);
    assert_eq!(library.read().unwrap().0.len(), 2);
    assert!(!load(&library).journal.inbox.needs_review());
    let second = receive_page(
        &library,
        vec![record(&b, "b")],
        "snapshot-page-two",
        true,
        false,
    );
    assert_eq!(second.status, Status::Current);
    assert!(load(&library).journal.inbox.snapshot.is_none());
}

#[test]
fn complete_snapshot_missing_a_confirmed_record_sticks_in_review_without_deleting() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    receive_page(
        &library,
        vec![record(&envelope(1, "Public preserved body", 1000), "one")],
        "one",
        true,
        false,
    );
    let mut checkpoint = load(&library);
    checkpoint.journal.inbox.restart_snapshot().unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    assert_eq!(
        receive_page(&library, vec![], "empty-snapshot", true, false).status,
        Status::SnapshotReview
    );
    assert_eq!(body(&library, 1), "Public preserved body");
    let mut remote = RemoteFixture::new(vec![]);
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .receive(&mut remote, 1)
            .unwrap()
            .status,
        Status::SnapshotReview
    );
    assert!(remote.requested.is_empty());
    assert!(load(&library).journal.inbox.needs_review());
}

#[test]
fn snapshot_duplicate_identity_rejects_the_whole_page_without_cursor_advance() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let e = envelope(1, "Public unique record", 1000);
    receive_page(&library, vec![record(&e, "one")], "one", true, true);
    let mut remote = RemoteFixture::new(vec![page(
        vec![
            record(&e, "duplicate"),
            record(&envelope(2, "Public second record", 2000), "two"),
        ],
        "two",
        true,
        false,
    )]);
    let before = fs::read(temp.path().join("Sync/journal.bin")).unwrap();
    assert!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .receive(&mut remote, 1)
            .is_err()
    );
    assert_eq!(
        fs::read(temp.path().join("Sync/journal.bin")).unwrap(),
        before
    );
    assert_eq!(library.read().unwrap().0.len(), 1);
}

#[test]
fn corrupt_wire_member_leaves_the_complete_page_unpublished() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let valid = record(&envelope(1, "Public valid body", 1000), "one");
    let mut corrupt =
        serde_json::to_value(record(&envelope(2, "Public corrupt body", 1000), "two")).unwrap();
    corrupt["id"] = Uuid::from_u128(3).to_string().into();
    let corrupt = serde_json::from_value(corrupt).unwrap();
    let mut remote = RemoteFixture::new(vec![page(vec![valid, corrupt], "two", true, false)]);
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(())).receive(&mut remote, 1),
        Err(Failure::InvalidPage)
    ));
    assert!(library.read().unwrap().0.is_empty());
    assert!(load(&library).journal.inbox.cursor().is_none());
    assert_eq!(load(&library).journal.inbox.received, 0);
}

#[test]
fn account_and_key_epoch_changes_around_http_halt_before_any_primary_apply() {
    for key_change in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let library = Library::open(temp.path().into()).unwrap();
        let mut remote = RemoteFixture::new(vec![page(
            vec![record(&envelope(1, "Public rejected body", 1000), "one")],
            "one",
            true,
            false,
        )]);
        if key_change {
            remote.change_key_at = Some(2);
        } else {
            remote.change_scope_at = Some(2);
        }
        assert!(matches!(
            owner(&library, &key(), &scope(), &|| Ok(())).receive(&mut remote, 1),
            Err(Failure::ScopeReview)
        ));
        assert!(library.read().unwrap().0.is_empty());
        assert!(load(&library).journal.inbox.cursor().is_none());
    }
}

#[test]
fn foreign_checkpoint_halts_before_fetch_or_primary_read() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut checkpoint = load(&library);
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let before = fs::read(temp.path().join("Sync/journal.bin")).unwrap();
    let mut other = scope();
    other.dataset = Binding::from_checkpoint([0x99; 32]);
    let mut remote = RemoteFixture::new(vec![]);
    remote.scope = other.clone();
    // An invalid primary file would fail if admission read it before scope.
    fs::write(library.path(), b"invalid public primary fixture").unwrap();
    assert!(matches!(
        owner(&library, &key(), &other, &|| Ok(())).receive(&mut remote, 1),
        Err(Failure::Primary(primary::Failure::RecoveryRequired))
    ));
    assert!(remote.requested.is_empty());
    assert_eq!(
        fs::read(temp.path().join("Sync/journal.bin")).unwrap(),
        before
    );
}

#[test]
fn changed_feed_response_is_discarded_and_next_cycle_starts_a_snapshot() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut remote = RemoteFixture::new(vec![page(
        vec![record(&envelope(1, "Public old feed body", 1000), "one")],
        "old",
        true,
        false,
    )]);
    remote.change_feed_at = Some(2);
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .receive(&mut remote, 1)
        .unwrap();
    assert_eq!(progress.status, Status::MorePages);
    assert!(library.read().unwrap().0.is_empty());
    assert!(load(&library).journal.inbox.cursor().is_none());
    assert!(load(&library).journal.inbox.feed == Some(feed(4)));
    let mut new_page = page(
        vec![record(&envelope(1, "Public new feed body", 2000), "one")],
        "new",
        true,
        false,
    );
    new_page.observation.feed = feed(4);
    let mut remote = RemoteFixture::new(vec![new_page]);
    remote.feed = feed(4);
    assert_eq!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .receive(&mut remote, 1)
            .unwrap()
            .status,
        Status::Current
    );
    assert!(remote.requested[0].is_none());
    assert_eq!(body(&library, 1), "Public new feed body");
}

#[test]
fn queued_old_feed_drains_before_cursor_reset_and_never_claims_current() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut remote = RemoteFixture::new(vec![page(
        vec![record(
            &envelope(1, "Public retained old page", 1000),
            "one",
        )],
        "old",
        true,
        false,
    )]);
    let mut fault = Fault {
        saves: 0,
        save: Some((2, true)),
        primary: false,
    };
    assert!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .receive_inner(&mut remote, 1, &mut fault)
            .is_err()
    );
    let mut remote = RemoteFixture::new(vec![]);
    remote.feed = feed(4);
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .receive(&mut remote, 1)
        .unwrap();
    assert_eq!(progress.status, Status::MorePages);
    assert_eq!(body(&library, 1), "Public retained old page");
    assert!(remote.requested.is_empty());
    assert!(load(&library).journal.inbox.cursor().is_none());
    assert!(load(&library).journal.inbox.feed == Some(feed(4)));
}

#[test]
fn cursor_invalid_restarts_only_the_feed_without_touching_local_or_offered_intent() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    receive_page(
        &library,
        vec![record(&envelope(1, "Public confirmed body", 1000), "one")],
        "one",
        true,
        false,
    );
    let mut checkpoint = load(&library);
    let local = envelope(2, "Public immutable offer", 2000);
    checkpoint.journal.desire(local.clone()).unwrap();
    checkpoint
        .journal
        .mark_offered(std::slice::from_ref(&local))
        .unwrap();
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let original = checkpoint.journal.entry(local.id).unwrap().clone();
    let mut remote = RemoteFixture::new(vec![]);
    remote.replies.push_back(Err(cloud::Failure::Server {
        code: cloud::ErrorCode::CursorInvalid,
        retry_after: None,
    }));
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .receive(&mut remote, 1)
        .unwrap();
    assert_eq!(progress.status, Status::MorePages);
    assert_eq!(remote.requested.len(), 1);
    let checkpoint = load(&library);
    assert!(checkpoint.journal.entry(local.id) == Some(&original));
    assert!(checkpoint.journal.confirmed(Uuid::from_u128(1)).is_some());
    assert!(checkpoint.journal.inbox.cursor().is_none());
    assert_eq!(body(&library, 1), "Public confirmed body");
}

#[test]
fn a_local_primary_deletion_is_not_resurrected_by_the_receiver() {
    let temp = tempfile::tempdir().unwrap();
    let mut library = Library::open(temp.path().into()).unwrap();
    receive_page(
        &library,
        vec![record(&envelope(1, "Public original body", 1000), "one")],
        "one",
        true,
        false,
    );
    library.reload().unwrap();
    library
        .delete(&library.get(Uuid::from_u128(1)).unwrap())
        .unwrap();
    assert_eq!(
        receive_page(
            &library,
            vec![record(&envelope(1, "Public later body", 2000), "two")],
            "two",
            false,
            false
        )
        .status,
        Status::LocalReview
    );
    assert!(library.read().unwrap().0.is_empty());
    let checkpoint = load(&library);
    assert!(checkpoint.journal.inbox.has_pending_page());
    assert!(checkpoint.journal.inbox.applied_cursor == Some(cursor("one")));
    assert!(checkpoint.journal.inbox.fetched_cursor == Some(cursor("two")));
}

#[test]
fn remote_tombstone_stays_queued_until_deletion_review_exists() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    receive_page(
        &library,
        vec![record(
            &envelope(1, "Public retained live body", 1000),
            "one",
        )],
        "one",
        true,
        false,
    );
    let mut tombstone = envelope(1, "", 2000);
    tombstone.deleted = true;
    tombstone.fields = None;
    assert_eq!(
        receive_page(
            &library,
            vec![record(&tombstone, "two")],
            "two",
            false,
            false
        )
        .status,
        Status::DeletionReview
    );
    assert_eq!(body(&library, 1), "Public retained live body");
    assert!(load(&library).journal.inbox.has_pending_page());
}

#[test]
fn legacy_secure_echo_receives_while_locked_and_keeps_exact_remote_cas_generation() {
    for missing_hash in [false, true] {
        let temporary = tempfile::tempdir().unwrap();
        let library = Library::open(temporary.path().into()).unwrap();
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        let mut document =
            crate::vault::Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap())
                .unwrap();
        document.records[0].hlc = Some(Hlc::parse("100000000000-0000-11111111").unwrap());
        if missing_hash {
            document.records[0].content_hash.clear();
        }
        fs::create_dir(temporary.path().join("Vault")).unwrap();
        let before = document.encode().unwrap();
        crate::model::atomic_write(&temporary.path().join("Vault/vault.json"), &before).unwrap();
        let mut incoming = crate::projection::current(
            &[],
            Some(&document),
            "11111111",
            &std::collections::BTreeMap::new(),
            &std::collections::BTreeMap::new(),
        )
        .unwrap()
        .into_values()
        .next()
        .unwrap();
        incoming.extensions.remove("vaultKID");
        let original = incoming.encode().unwrap();
        let remote = record(&incoming, "legacy");
        let version = record(&incoming, "legacy").into_parts().1;
        let progress = receive_page(&library, vec![remote], "legacy", true, false);
        assert_eq!(progress.status, Status::Current);
        assert_eq!(progress.applied_records, 1);
        assert_eq!(
            fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
            before
        );
        let checkpoint = load(&library);
        let confirmed = checkpoint.journal.confirmed(incoming.id).unwrap();
        assert!(confirmed.envelope.encode().unwrap() == original);
        assert!(confirmed.record_version == version);
        assert!(!checkpoint.journal.inbox.has_pending_page());
        assert!(checkpoint.journal.inbox.applied_cursor == Some(cursor("legacy")));
        assert_eq!(checkpoint.journal.pending().unwrap().len(), 1);
        let desired = checkpoint.journal.pending().unwrap().remove(0);
        assert_eq!(
            desired.extensions["vaultKID"].as_text().unwrap(),
            document.kid
        );
        assert_eq!(
            desired.fields.as_ref().unwrap().content,
            incoming.fields.as_ref().unwrap().content
        );
        assert!(library.read().unwrap().0.is_empty());
    }
}

#[test]
fn secure_record_without_local_vault_remains_pending_without_creating_keys() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut secure = envelope(1, "snip1.invalid-public-sealed-fixture", 1000);
    secure.secure = true;
    assert_eq!(
        receive_page(&library, vec![record(&secure, "one")], "one", true, false).status,
        Status::VaultLocked
    );
    assert!(!temp.path().join("Vault").exists());
    assert!(library.read().unwrap().0.is_empty());
    assert!(load(&library).journal.inbox.next().is_some());
}

#[test]
fn expired_local_session_stops_before_any_remote_request() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut remote = RemoteFixture::new(vec![]);
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Err(Failure::SessionChanged)).receive(&mut remote, 1),
        Err(Failure::SessionChanged)
    ));
    assert_eq!(remote.preflights, 0);
    assert!(remote.requested.is_empty());
    assert!(!temp.path().join("Sync").exists());
}

#[test]
fn local_session_change_after_fetch_prevents_cursor_and_primary_application() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let calls = Cell::new(0);
    let guard = || {
        calls.set(calls.get() + 1);
        if calls.get() == 5 {
            Err(Failure::SessionChanged)
        } else {
            Ok(())
        }
    };
    let mut remote = RemoteFixture::new(vec![page(
        vec![record(&envelope(1, "Public refused body", 1000), "one")],
        "one",
        true,
        false,
    )]);
    assert!(matches!(
        owner(&library, &key(), &scope(), &guard).receive(&mut remote, 1),
        Err(Failure::SessionChanged)
    ));
    assert_eq!(remote.requested.len(), 1);
    assert!(library.read().unwrap().0.is_empty());
    assert!(load(&library).journal.inbox.cursor().is_none());
}

#[test]
fn native_receive_reserves_the_installation_clock_only_after_scope_admission() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let wire_key = key();
    let binding = scope();
    let mut receiver = owner(&library, &wire_key, &binding, &|| Ok(()));
    receiver.device = None;
    let mut remote = RemoteFixture::new(vec![]);
    remote.scope.dataset = Binding::from_checkpoint([0x99; 32]);
    assert!(matches!(
        receiver.receive(&mut remote, 1),
        Err(Failure::ScopeReview)
    ));
    assert!(!temp.path().join("device.json").exists());
    let mut remote = RemoteFixture::new(vec![page(
        vec![record(&envelope(1, "Public native receive", 1000), "one")],
        "one",
        true,
        false,
    )]);
    assert_eq!(
        receiver.receive(&mut remote, 1).unwrap().status,
        Status::Current
    );
    assert!(temp.path().join("device.json").is_file());
    assert_eq!(body(&library, 1), "Public native receive");
}

#[test]
fn checkpoint_key_epoch_is_checked_before_a_primary_recovery_marker_can_be_removed() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut checkpoint = load(&library);
    let mut old = feed(3);
    old.key_epoch = 2;
    checkpoint.journal.inbox.select_feed(old).unwrap();
    checkpoint.journal.primary_epoch = Some([0x33; 16]);
    checkpoint.save(&library, &key(), &SALT).unwrap();
    let mut marker = b"SPT1".to_vec();
    marker.extend_from_slice(&[0x33; 16]);
    fs::write(temp.path().join("Sync/primary.pending"), &marker).unwrap();
    let before = fs::read(temp.path().join("Sync/journal.bin")).unwrap();
    let mut remote = RemoteFixture::new(vec![]);
    assert!(matches!(
        owner(&library, &key(), &scope(), &|| Ok(())).receive(&mut remote, 1),
        Err(Failure::Primary(primary::Failure::RecoveryRequired))
    ));
    assert_eq!(
        fs::read(temp.path().join("Sync/primary.pending")).unwrap(),
        marker
    );
    assert_eq!(
        fs::read(temp.path().join("Sync/journal.bin")).unwrap(),
        before
    );
    assert!(remote.requested.is_empty());
}

#[test]
fn partial_delta_restart_continues_the_next_generation_without_fetching_or_coalescing() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    receive_page(
        &library,
        vec![record(&envelope(1, "Public original", 1000), "one")],
        "one",
        true,
        false,
    );
    let mut remote = RemoteFixture::new(vec![page(
        vec![
            record(&envelope(1, "Public middle", 2000), "two"),
            record(&envelope(1, "Public final", 3000), "three"),
        ],
        "three",
        false,
        false,
    )]);
    let mut fault = Fault {
        saves: 0,
        save: Some((2, true)),
        primary: false,
    };
    assert!(
        owner(&library, &key(), &scope(), &|| Ok(()))
            .receive_inner(&mut remote, 1, &mut fault)
            .is_err()
    );
    assert_eq!(body(&library, 1), "Public middle");
    let checkpoint = load(&library);
    assert_eq!(
        checkpoint.journal.inbox.pending.as_ref().unwrap().position,
        1
    );
    assert!(checkpoint.journal.inbox.fetched_cursor == Some(cursor("three")));
    assert!(checkpoint.journal.inbox.applied_cursor == Some(cursor("one")));
    let mut retry = RemoteFixture::new(vec![]);
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .receive(&mut retry, 1)
        .unwrap();
    assert_eq!(progress.applied_records, 1);
    assert_eq!(progress.status, Status::Current);
    assert_eq!(body(&library, 1), "Public final");
    assert!(retry.requested.is_empty());
    assert!(load(&library).journal.inbox.applied_cursor == Some(cursor("three")));
}

#[test]
fn page_budget_retains_the_full_snapshot_boundary_for_the_next_cycle() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut remote = RemoteFixture::new(vec![
        page(
            vec![record(&envelope(1, "Public page one", 1000), "one")],
            "one",
            true,
            true,
        ),
        page(
            vec![record(&envelope(2, "Public page two", 1000), "two")],
            "two",
            true,
            false,
        ),
    ]);
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .receive(&mut remote, 1)
        .unwrap();
    assert_eq!(progress.status, Status::MorePages);
    assert_eq!(remote.requested.len(), 1);
    assert!(load(&library).journal.inbox.snapshot.as_ref().unwrap().open);
    let progress = owner(&library, &key(), &scope(), &|| Ok(()))
        .receive(&mut remote, 1)
        .unwrap();
    assert_eq!(progress.status, Status::Current);
    assert!(remote.requested[1] == Some(cursor("one")));
    assert_eq!(library.read().unwrap().0.len(), 2);
}

#[test]
fn primary_race_after_prepare_preserves_the_local_edit_and_queued_remote_generation() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let calls = Cell::new(0);
    let guard = || {
        calls.set(calls.get() + 1);
        if calls.get() == 9 {
            let local = envelope(1, "Public concurrent local edit", 2000)
                .snippet()
                .unwrap()
                .unwrap();
            crate::model::atomic_write(
                &library.path(),
                &crate::model::encode_library(&[local], false).unwrap(),
            )
            .unwrap();
        }
        Ok(())
    };
    let mut remote = RemoteFixture::new(vec![page(
        vec![record(
            &envelope(1, "Public saved remote generation", 1000),
            "one",
        )],
        "one",
        true,
        false,
    )]);
    let progress = owner(&library, &key(), &scope(), &guard)
        .receive(&mut remote, 1)
        .unwrap();
    assert_eq!(progress.status, Status::PrimaryChanged);
    assert_eq!(progress.applied_records, 0);
    assert_eq!(body(&library, 1), "Public concurrent local edit");
    let checkpoint = load(&library);
    assert!(checkpoint.journal.inbox.next().is_some());
    assert!(checkpoint.journal.confirmed(Uuid::from_u128(1)).is_none());
    assert!(checkpoint.journal.inbox.applied_cursor.is_none());
}
