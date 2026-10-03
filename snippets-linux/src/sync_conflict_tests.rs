//! Cross-client concurrent-edit regressions through the real receiver, sender,
//! journal, projection and primary owner. The fixture server mirrors the Go store:
//! its delta feed returns every accepted generation in sequence order, and a CAS
//! conflict returns the authoritative row. Inputs are either the exact envelopes
//! recorded by the 2026-10-03 stateful audit (synthetic public bodies) or
//! synthetic Mac/Android writes with the same shapes. No HTTP, keyring or user data.
use super::*;
use crate::{
    clock::Hlc,
    cloud::{self, Cursor, Offer, RecordVersion, Role, ServerRecord},
    crypto::RootKey,
    inbound::Feed,
    journal::Scope,
    model::{self, Library, Snippet},
    receiver::{FetchedPage, Observation, RemoteResult},
    snapshot_review::tests::{SALT, cursor, feed, key, scope, version},
    wire::{Envelope, WireRecord},
};
use std::collections::BTreeMap;
use uuid::Uuid;

type Write = (Envelope, Option<Envelope>);

struct Log {
    scope: Scope,
    feed: Feed,
    changes: Vec<(WireRecord, RecordVersion)>,
    heads: BTreeMap<Uuid, (WireRecord, RecordVersion)>,
    submits: usize,
    fetches: usize,
    submitted: usize,
    /// Another device's CAS writes, applied immediately before this device's
    /// N-th submit or fetch reaches the server. A write whose expected head is no
    /// longer current is not reachable with those exact bytes and is dropped.
    before_submit: BTreeMap<usize, Vec<Write>>,
    before_fetch: BTreeMap<usize, Vec<Write>>,
    injected: usize,
    lose_reply_at: Option<usize>,
    edit_before_fetch: Option<(usize, std::path::PathBuf, Vec<Snippet>)>,
}
fn server_record(wire: &WireRecord, version: &RecordVersion) -> ServerRecord {
    let mut value = serde_json::to_value(wire).unwrap();
    value["recordVersion"] = version.for_checkpoint().into();
    serde_json::from_value(value).unwrap()
}
fn sequence(cursor: &Cursor) -> usize {
    cursor
        .for_checkpoint()
        .strip_prefix("public-fixture-cursor-seq-")
        .unwrap()
        .parse()
        .unwrap()
}
impl Log {
    fn new() -> Self {
        Self {
            scope: scope(),
            feed: feed(3),
            changes: vec![],
            heads: BTreeMap::new(),
            submits: 0,
            fetches: 0,
            submitted: 0,
            before_submit: BTreeMap::new(),
            before_fetch: BTreeMap::new(),
            injected: 0,
            lose_reply_at: None,
            edit_before_fetch: None,
        }
    }
    fn observation(&self) -> Observation {
        Observation {
            scope: self.scope.clone(),
            feed: self.feed.clone(),
        }
    }
    fn append(&mut self, wire: WireRecord) -> RecordVersion {
        let next = version(&format!("g{}", self.changes.len() + 1));
        self.changes.push((wire.clone(), next.clone()));
        self.heads.insert(wire.id, (wire, next.clone()));
        next
    }
    fn head(&self, id: Uuid) -> Option<Envelope> {
        self.heads
            .get(&id)
            .map(|(w, _)| w.open(&key(), &SALT).unwrap())
    }
    fn heads(&self) -> Vec<Envelope> {
        self.heads
            .values()
            .map(|(w, _)| w.open(&key(), &SALT).unwrap())
            .collect()
    }
    /// Another device's accepted CAS write.
    fn try_write(&mut self, e: &Envelope, expected: Option<&Envelope>) -> bool {
        let current = self.head(e.id).map(|h| h.hash().unwrap());
        if current != expected.map(|x| x.hash().unwrap()) {
            return false;
        }
        self.append(WireRecord::seal(e, &key(), &SALT).unwrap());
        true
    }
    fn write(&mut self, e: &Envelope, expected: Option<&Envelope>) {
        assert!(self.try_write(e, expected), "fixture CAS precondition");
    }
    fn inject(&mut self, writes: Vec<Write>) {
        for (e, expected) in writes {
            if self.try_write(&e, expected.as_ref()) {
                self.injected += 1;
            }
        }
    }
}
impl receiver::Remote for Log {
    fn preflight(&mut self) -> RemoteResult<Observation> {
        Ok(self.observation())
    }
    fn fetch(&mut self, requested: Option<&Cursor>) -> RemoteResult<FetchedPage> {
        self.fetches += 1;
        if let Some(writes) = self.before_fetch.remove(&self.fetches) {
            self.inject(writes);
        }
        if self
            .edit_before_fetch
            .as_ref()
            .is_some_and(|(at, _, _)| *at == self.fetches)
        {
            let (_, root, rows) = self.edit_before_fetch.take().unwrap();
            write_primary(&Library::open(root).unwrap(), &rows);
        }
        let high = self.changes.len();
        let (records, last, full_snapshot) = match requested {
            None => {
                assert!(self.heads.len() <= crate::inbound::PAGE_LIMIT);
                let rows = self
                    .heads
                    .values()
                    .map(|(w, v)| server_record(w, v))
                    .collect::<Vec<_>>();
                (rows, high, true)
            }
            Some(c) => {
                let after = sequence(c);
                let last = high.min(after + crate::inbound::PAGE_LIMIT);
                let rows = self.changes[after..last]
                    .iter()
                    .map(|(w, v)| server_record(w, v))
                    .collect();
                (rows, last, false)
            }
        };
        Ok(FetchedPage {
            observation: self.observation(),
            records,
            cursor: cursor(&format!("seq-{last}")),
            full_snapshot,
            has_more: last < high,
        })
    }
}
impl sender::Remote for Log {
    fn preflight(&mut self) -> RemoteResult<sender::SendObservation> {
        Ok(sender::SendObservation {
            observation: self.observation(),
            role: Role::Writer,
        })
    }
    fn submit(&mut self, offers: &[Offer]) -> RemoteResult<sender::Reply> {
        self.submits += 1;
        if let Some(writes) = self.before_submit.remove(&self.submits) {
            self.inject(writes);
        }
        let mut outcomes = vec![];
        for offer in offers {
            let occupant = self.heads.get(&offer.record.id).cloned();
            let matches = match (&occupant, &offer.expected_record_version) {
                (None, None) => true,
                (Some((_, v)), Some(expected)) => v == expected,
                _ => false,
            };
            if matches {
                self.submitted += 1;
                let next = self.append(offer.record.clone());
                outcomes.push(cloud::Outcome::Accepted {
                    record_version: next,
                    revision: offer.record.rev.clone(),
                });
            } else {
                let (wire, v) = occupant.expect("occupied CAS conflict");
                outcomes.push(cloud::Outcome::Conflict {
                    authoritative_record: server_record(&wire, &v),
                });
            }
        }
        if self.lose_reply_at == Some(self.submits) {
            return Err(cloud::Failure::Network);
        }
        let partial = outcomes
            .iter()
            .any(|o| !matches!(o, cloud::Outcome::Accepted { .. }));
        Ok(sender::Reply {
            observation: self.observation(),
            outcomes,
            partial,
        })
    }
}

const LINUX: &str = "a11d1701";
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
        device: Some(LINUX),
        vault_keys: None,
        validate_session: guard,
    }
}
/// The audit fixture's loop: bounded actions until the library is current.
fn sync_linux(library: &Library, log: &mut Log) {
    for _ in 0..12 {
        let progress = owner(library, &key(), &scope(), &|| Ok(()))
            .synchronize(log, Limits::DEFAULT)
            .unwrap();
        if progress.status == Status::Current {
            return;
        }
        assert!(
            matches!(progress.status, Status::MoreWork(_)),
            "unexpected bounded sync status: {:?}",
            progress.status
        );
    }
    panic!("Linux sync did not settle within the audit's bounded retries");
}
fn write_primary(library: &Library, snippets: &[Snippet]) {
    model::atomic_write(
        &library.root.join("snippets.json"),
        &model::encode_library(snippets, false).unwrap(),
    )
    .unwrap();
}
fn rows(library: &Library) -> Vec<Snippet> {
    library.read().unwrap().0
}
fn content(e: &Envelope) -> String {
    String::from_utf8(e.fields.as_ref().unwrap().content.to_vec()).unwrap()
}

const BODIES: [&str; 3] = [
    "audit-concurrent-macos",
    "audit-concurrent-android",
    "audit-concurrent-linux",
];
/// The audit's preservation contract, checked on both the Linux primary file and
/// the server heads: every concurrent body survives, exactly one copy is live,
/// and every generated copy is disabled and unreachable by keyword.
fn assert_preserved(library: &Library, log: &Log, race: Uuid) {
    let local = rows(library);
    for body in BODIES {
        assert!(
            local.iter().any(|s| s.content == body),
            "{body} is missing from the Linux library"
        );
        assert!(
            log.heads().iter().any(|e| !e.deleted && content(e) == body),
            "{body} is missing from the server"
        );
    }
    let live: Vec<_> = local
        .iter()
        .filter(|s| BODIES.contains(&s.content.as_str()) && s.is_enabled)
        .collect();
    assert_eq!(live.len(), 1, "exactly one live race body");
    assert_eq!(live[0].id, race);
    for copy in local
        .iter()
        .filter(|s| s.id != race && s.tags.iter().any(|t| t == "conflict"))
    {
        assert!(!copy.is_enabled && copy.keyword.is_empty());
    }
    let server: BTreeMap<_, _> = log.heads().into_iter().map(|e| (e.id, e)).collect();
    for s in &local {
        let remote = server.get(&s.id).expect("every local record is uploaded");
        assert_eq!(content(remote), s.content);
    }
    assert_eq!(server.len(), local.len());
    assert_no_lost_update(log, race);
}
/// A CAS write must incorporate the version it replaces. A body that was
/// replaced and later reappears on the same record means some write carried a
/// version it had never merged (A -> L -> A): every device fetching in between
/// was told to discard A.
fn assert_no_lost_update(log: &Log, id: Uuid) {
    let mut bodies: Vec<String> = vec![];
    for (wire, _) in &log.changes {
        let e = wire.open(&key(), &SALT).unwrap();
        if e.id == id && !e.deleted && bodies.last() != Some(&content(&e)) {
            bodies.push(content(&e));
        }
    }
    for (index, body) in bodies.iter().enumerate() {
        assert!(
            !bodies[index + 1..].contains(body),
            "{body} was overwritten without being merged and later restored"
        );
    }
}
/// Further exchange rounds must neither write nor mint another copy.
fn assert_quiescent(library: &Library, log: &mut Log) {
    let records = rows(library).len();
    let changes = log.changes.len();
    for _ in 0..3 {
        sync_linux(library, log);
    }
    assert_eq!(rows(library).len(), records);
    assert_eq!(
        log.changes.len(),
        changes,
        "an idle round wrote to the server"
    );
}

// ---- Exact envelopes from the audit's minimal three-client run --------------

struct Audit {
    changes: Vec<Envelope>,
}
impl Audit {
    fn minimal_three() -> Self {
        let value: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/audit-concurrent-v1.json"))
                .unwrap();
        let changes = value["minimalThree"]
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
            .map(|(index, change)| {
                assert_eq!(change["sequence"].as_u64(), Some(index as u64 + 1));
                Envelope::parse(change["envelope"].as_str().unwrap().as_bytes()).unwrap()
            })
            .collect();
        Self { changes }
    }
    /// Server change `sequence` (1-based) as recorded by the audit.
    fn at(&self, sequence: usize) -> Envelope {
        self.changes[sequence - 1].clone()
    }
    /// The sequences 6-8 are Android's single CAS batch over the Mac's 4-5.
    fn android_batch(&self) -> Vec<Write> {
        vec![
            (self.at(6), None),
            (self.at(7), Some(self.at(4))),
            (self.at(8), Some(self.at(5))),
        ]
    }
    /// Linux's offline edits, exactly as its primary file held them before replay.
    fn linux_edits(&self) -> Vec<Snippet> {
        let race = self.at(11).snippet().unwrap().unwrap();
        let mut fields = self.at(2).snippet().unwrap().unwrap();
        let edited = self.at(10).snippet().unwrap().unwrap();
        fields.content = edited.content;
        fields.updated_at = edited.updated_at;
        vec![race, fields, self.at(3).snippet().unwrap().unwrap()]
    }
    /// Seed, Linux's verified common ancestor, its offline edits and the Mac's
    /// accepted replay. The returned library has not yet synchronized its edits.
    fn prepared(&self) -> (tempfile::TempDir, Library, Log) {
        let temp = tempfile::tempdir().unwrap();
        let library = Library::open(temp.path().into()).unwrap();
        let mut log = Log::new();
        for sequence in 1..=3 {
            log.write(&self.at(sequence), None);
        }
        sync_linux(&library, &mut log);
        assert_eq!(rows(&library).len(), 3);
        write_primary(&library, &self.linux_edits());
        log.write(&self.at(4), Some(&self.at(1)));
        log.write(&self.at(5), Some(&self.at(2)));
        (temp, library, log)
    }
}

#[test]
fn audit_recorded_schedule_keeps_all_three_concurrent_bodies() {
    // Recorded schedule: Linux has received only the Mac's change when Android's
    // batch is accepted, just before Linux's first upload. On the unfixed sender
    // this reproduces the audit's server log byte-for-byte (revisions of changes
    // 9-14): the frozen pre-merge Linux body is re-offered under Android's CAS
    // version, and Linux's later merge of that echo drops Android's body.
    let audit = Audit::minimal_three();
    let (_temp, library, mut log) = audit.prepared();
    log.before_submit.insert(1, audit.android_batch());
    sync_linux(&library, &mut log);
    assert_eq!(log.injected, 3);
    let race = audit.at(1).id;
    assert_preserved(&library, &log, race);
    // Independent field changes from three devices merge on the shared record.
    let fields = log.head(audit.at(2).id).unwrap();
    let f = fields.fields.as_ref().unwrap();
    assert_eq!(f.name, "audit-name-macos");
    assert!(!f.is_enabled);
    assert_eq!(content(&fields), "audit-field-linux");
    assert_quiescent(&library, &mut log);
}

#[test]
fn audit_replay_keeps_every_body_when_android_races_each_linux_upload() {
    let audit = Audit::minimal_three();
    let mut reached = 0;
    // Android's batch lands before Linux's first fetch (Android published
    // first), or before one of Linux's uploads.
    for (on_submit, at) in [(false, 1), (true, 1), (true, 2), (true, 3), (false, 2)] {
        let (_temp, library, mut log) = audit.prepared();
        log.fetches = 0;
        if on_submit {
            log.before_submit.insert(at, audit.android_batch());
        } else {
            log.before_fetch.insert(at, audit.android_batch());
        }
        sync_linux(&library, &mut log);
        if log.injected < 3 {
            // These exact Android bytes could not have been accepted after
            // Linux had already replaced the record.
            continue;
        }
        reached += 1;
        assert_preserved(&library, &log, audit.at(1).id);
        assert_quiescent(&library, &mut log);
    }
    assert!(reached >= 2, "only {reached} interleavings were reachable");
}

#[test]
fn audit_replay_with_canonical_android_copies_converges_to_three_records_and_two_copies() {
    // With Android minting the canonical envelope copy of the Mac's version (the
    // bytes Linux minted as change 9), both devices preserve that body as one record.
    let audit = Audit::minimal_three();
    let batch = || {
        vec![
            (audit.at(9), None),
            (audit.at(7), Some(audit.at(4))),
            (audit.at(8), Some(audit.at(5))),
        ]
    };
    let mut reached = 0;
    for (on_submit, at) in [(false, 1), (true, 1), (true, 2), (true, 3), (false, 2)] {
        let (_temp, library, mut log) = audit.prepared();
        log.fetches = 0;
        if on_submit {
            log.before_submit.insert(at, batch());
        } else {
            log.before_fetch.insert(at, batch());
        }
        sync_linux(&library, &mut log);
        if log.injected < 3 {
            continue;
        }
        reached += 1;
        assert_preserved(&library, &log, audit.at(1).id);
        assert_eq!(rows(&library).len(), 5, "3 originals and 2 disabled copies");
        assert_quiescent(&library, &mut log);
    }
    assert!(reached >= 2, "only {reached} interleavings were reachable");
}

// ---- Synthetic three-way content conflicts in several send orders -----------

const T0: u64 = 1_790_000_000_000;
const RACE: u128 = 0xa11ce002_0000_4000_8000_000000000001;
fn swift_seconds(unix_ms: u64) -> f64 {
    unix_ms as f64 / 1000.0 - model::SWIFT_EPOCH
}
fn hlc(wall: u64, device: &str) -> Hlc {
    Hlc::parse(&format!("{wall:012x}-0000-{device}")).unwrap()
}
fn race(body: &str, updated: u64) -> Snippet {
    Snippet {
        id: Uuid::from_u128(RACE),
        name: "race".into(),
        keyword: "race".into(),
        content: body.into(),
        tags: vec!["audit".into()],
        is_enabled: true,
        is_pinned: false,
        created_at: swift_seconds(T0),
        updated_at: swift_seconds(updated),
    }
}
fn plain(snippet: &Snippet, wall: u64, device: &str) -> Envelope {
    Envelope::plain(snippet, hlc(wall, device), device.into()).unwrap()
}
/// Mac's projected edit, then Android's legacy-shaped merge (fresh HLC, no
/// provenance, snippet-level copy id) of its own edit over the Mac's.
fn foreign_writes(t_m: u64, t_a: u64, t_ar: u64) -> (Envelope, Vec<Write>) {
    let base = plain(&race("audit-original-race", T0), T0, "aaaaaaaa");
    let mac = plain(&race("audit-concurrent-macos", t_m), t_m, "aaaaaaaa");
    let mut copy = race("audit-concurrent-macos", t_m);
    copy.id = Uuid::new_v5(
        &Uuid::from_u128(RACE),
        format!("conflict|audit-concurrent-macos|{t_m}").as_bytes(),
    );
    copy.name = "race (conflict 2026-09-21 14:13 UTC)".into();
    copy.keyword.clear();
    copy.is_enabled = false;
    copy.tags = vec!["audit".into(), "conflict".into()];
    let android = plain(
        &race("audit-concurrent-android", t_a.max(t_m)),
        t_ar,
        "bbbbbbbb",
    );
    (
        base.clone(),
        vec![
            (mac.clone(), Some(base)),
            (plain(&copy, t_ar, "bbbbbbbb"), None),
            (android, Some(mac)),
        ],
    )
}

#[test]
fn three_way_content_conflict_keeps_every_body_across_clocks_and_send_orders() {
    let values = [T0 + 1_000, T0 + 2_000, T0 + 3_000, T0 + 4_000];
    let mut reached = 0;
    for t_l in values {
        for t_ar in values {
            for injection in [None, Some((true, 1)), Some((true, 2)), Some((false, 2))] {
                let (t_m, t_a) = (T0 + 500, T0 + 700);
                let temp = tempfile::tempdir().unwrap();
                let library = Library::open(temp.path().into()).unwrap();
                let mut log = Log::new();
                let (base, mut writes) = foreign_writes(t_m, t_a, t_ar);
                log.write(&base, None);
                sync_linux(&library, &mut log);
                write_primary(&library, &[race("audit-concurrent-linux", t_l)]);
                let (mac, expected) = writes.remove(0);
                log.write(&mac, expected.as_ref());
                log.fetches = 0;
                match injection {
                    None => log.inject(writes),
                    Some((true, at)) => {
                        log.before_submit.insert(at, writes);
                    }
                    Some((false, at)) => {
                        log.before_fetch.insert(at, writes);
                    }
                }
                sync_linux(&library, &mut log);
                if log.injected < 2 {
                    continue;
                }
                reached += 1;
                assert_preserved(&library, &log, Uuid::from_u128(RACE));
                assert_quiescent(&library, &mut log);
            }
        }
    }
    assert!(reached >= 40, "only {reached} schedules were reachable");
}

// ---- Own acknowledged writes and older generations in one delta page --------

#[test]
fn an_older_generation_before_this_devices_acknowledged_write_neither_rolls_back_nor_copies() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut log = Log::new();
    let base = plain(&race("Public original body", T0), T0, "aaaaaaaa");
    log.write(&base, None);
    sync_linux(&library, &mut log);
    write_primary(&library, &[race("Public first local body", T0 + 2_000)]);
    // Another device renames the record just before this device uploads, so the
    // CAS conflict is merged without a content conflict and the merged value is
    // accepted. The delta from the old cursor then holds the rename *and* the
    // acknowledged merge, and the user edits the body again before receiving.
    let mut renamed = race("Public original body", T0 + 1_000);
    renamed.name = "Public renamed race".into();
    log.before_submit.insert(
        1,
        vec![(plain(&renamed, T0 + 1_000, "aaaaaaaa"), Some(base))],
    );
    let mut later = race("Public second local body", T0 + 9_000);
    later.name = "Public renamed race".into();
    log.edit_before_fetch = Some((2, temp.path().into(), vec![later]));
    log.fetches = 0;
    sync_linux(&library, &mut log);
    let local = rows(&library);
    assert_eq!(local.len(), 1, "an older generation minted a conflict copy");
    assert_eq!(local[0].content, "Public second local body");
    assert_eq!(local[0].name, "Public renamed race");
    let head = log.head(Uuid::from_u128(RACE)).unwrap();
    assert_eq!(content(&head), "Public second local body");
    assert_eq!(head.fields.as_ref().unwrap().name, "Public renamed race");
    assert_quiescent(&library, &mut log);
}

// ---- Accepted-but-unacknowledged chain (P2) ---------------------------------

#[test]
fn accepted_but_unacknowledged_upload_then_a_later_remote_edit_creates_no_copy() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let mut log = Log::new();
    let base = plain(&race("Public original body", T0), T0, "aaaaaaaa");
    log.write(&base, None);
    sync_linux(&library, &mut log);
    // A: the server accepts the edit, the reply is lost and the process stops.
    write_primary(&library, &[race("Public crash body A", T0 + 1_000)]);
    log.lose_reply_at = Some(1);
    let lost = owner(&library, &key(), &scope(), &|| Ok(())).synchronize(&mut log, Limits::DEFAULT);
    assert!(matches!(
        lost,
        Err(receiver::Failure::Remote(cloud::Failure::Network))
    ));
    assert_eq!(log.submitted, 1);
    // Recovery of the same installation.
    sync_linux(&library, &mut log);
    assert_eq!(rows(&library).len(), 1);
    let accepted = log.head(Uuid::from_u128(RACE)).unwrap();
    assert_eq!(content(&accepted), "Public crash body A");
    // B received A, edited it and uploaded with A's version.
    let b = plain(
        &race("Public later body B", T0 + 5_000),
        T0 + 5_000,
        "bbbbbbbb",
    );
    log.write(&b, Some(&accepted));
    // A receives B: a sequential edit, not a conflict.
    sync_linux(&library, &mut log);
    let local = rows(&library);
    assert_eq!(
        local.len(),
        1,
        "an already-confirmed edit became a conflict copy"
    );
    assert_eq!(local[0].content, "Public later body B");
    assert_eq!(log.heads().len(), 1);
    assert_quiescent(&library, &mut log);
}
