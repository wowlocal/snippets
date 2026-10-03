//! Native deletion of acknowledged C0 while a real source rejection is retained.
use super::*;

pub(super) fn run(
    window: &Rc<AccountWindow>,
    root: &Path,
    fixture: &server::Fixture,
    key: &RootKey,
    salt: &[u8; 32],
    source: uuid::Uuid,
    original: &Envelope,
) -> (bool, String) {
    let before = snapshot::checkpoint(root);
    let initial = crate::vault::read_document(root).unwrap().unwrap();
    let source_deleted = !initial
        .records
        .iter()
        .any(|record| record.metadata.id == source);
    let copy_deleted = !source_deleted;
    fixture.state.lock().unwrap().reject_once = Some(source);
    action(window, "Send Local Changes");
    assert!(
        window.status.label()
            == "The server postponed some changes. Confirmed changes are saved; try sending the remaining edits later."
    );
    assert!(uploaded(fixture, original.id, key, salt) == *original);
    let saved = crate::vault::read_document(root).unwrap().unwrap();
    // The real C0 acknowledgement permits exact carrier cleanup. Establish the
    // post-ACK image while checking every body, metadata record and vault header.
    assert!(saved.records.len() == initial.records.len());
    for record in &saved.records {
        let old = initial
            .records
            .iter()
            .find(|old| old.metadata.id == record.metadata.id)
            .unwrap();
        assert!(record.metadata == old.metadata && record.sealed == old.sealed);
    }
    let mut header = initial.clone();
    header.records.clear();
    let mut current_header = saved.clone();
    current_header.records.clear();
    assert!(header == current_header);
    if !source_deleted {
        assert!(!crate::merge::has_unresolved(Some(&projected(
            &saved, source
        ))));
    }
    let deferred = snapshot::checkpoint(root);
    let source_packet = deferred.journal.outbound.as_ref().unwrap().clone();
    assert!(
        source_packet.receipts.is_some() && source_packet.position == source_packet.offers.len()
    );
    assert!(source_packet.offers.len() == 1 && source_packet.offers[0].wire.id == source);
    let marker = original
        .tombstone(Hlc::foreign(0xffff_ff80_0000), "22222222".into(), true)
        .unwrap();
    let version = {
        let mut state = fixture.state.lock().unwrap();
        state.put(WireRecord::seal(&marker, key, salt).unwrap());
        state.version(original.id).unwrap()
    };
    action(window, "Receive Cloud Changes");
    assert!(
        window.status.label()
            == "A cloud deletion needs review. The saved page is retained and your local snippet is preserved."
    );
    assert!(crate::vault::read_document(root).unwrap().unwrap() == saved);
    let held = snapshot::checkpoint(root);
    let packet = held.journal.outbound.as_ref().unwrap();
    assert!(*packet == source_packet);
    assert!(held.journal.inbox.next().unwrap().envelope == marker);
    assert!(held.journal.preservation_original(original.id) == Some(original));
    assert!(
        held.journal.deletion_approvals.get(&source)
            == before.journal.deletion_approvals.get(&source)
    );
    if source_deleted {
        assert!(held.journal.known_absence(source));
        assert!(held.journal.entry(source).is_none());
        let deleted = &held.journal.confirmed(source).unwrap().envelope;
        assert!(deleted.deleted);
        assert!(held.journal.deletion_approved(deleted).unwrap());
    }
    let primary_before = primary(root);
    let counts = data_counts(fixture);
    let packets = fixture.state.lock().unwrap().submitted.clone();
    choice(window, "Cancel");
    assert!(primary(root) == primary_before && data_counts(fixture) == counts);
    let (dialog, entry) = credentials(window, copy_deleted, false);
    entry.set_text("Public cancelled prerequisite credential");
    press(dialog.upcast_ref(), "Cancel");
    password_done(window, &entry);
    assert!(primary(root) == primary_before && data_counts(fixture) == counts);
    verify(
        window,
        copy_deleted,
        "Public incorrect prerequisite passphrase",
        false,
        false,
    );
    assert!(primary(root) == primary_before && data_counts(fixture) == counts);
    assert!(fixture.state.lock().unwrap().submitted == packets);
    // The second decision owns a fresh dialog/key. The earlier source decision
    // cannot lend its authorization or grant this copy's deletion permission.
    verify(
        window,
        copy_deleted,
        &crypto::format_recovery(&[0x66; 16]),
        false,
        true,
    );
    assert!(window.status.label().starts_with(if copy_deleted {
        "Cloud deletion applied locally."
    } else {
        "Local version kept."
    }));
    assert!(data_counts(fixture) == counts);
    let decided = snapshot::checkpoint(root);
    assert!(decided.journal.preservation_original(original.id) == Some(original));
    assert!(decided.journal.outbound.as_ref() == Some(&source_packet));
    assert!(
        decided.journal.deletion_approvals.get(&source)
            == before.journal.deletion_approvals.get(&source)
    );
    let actual = crate::vault::read_document(root).unwrap().unwrap();
    assert!(
        actual
            .records
            .iter()
            .any(|record| record.metadata.id == source)
            != source_deleted
    );
    assert!(
        actual
            .records
            .iter()
            .any(|record| record.metadata.id == original.id)
            != copy_deleted
    );
    if !source_deleted {
        assert!(
            actual
                .records
                .iter()
                .find(|record| record.metadata.id == source)
                .unwrap()
                .sealed
                == saved
                    .records
                    .iter()
                    .find(|record| record.metadata.id == source)
                    .unwrap()
                    .sealed
        );
    }
    if !copy_deleted {
        assert!(
            actual
                .records
                .iter()
                .find(|record| record.metadata.id == original.id)
                .unwrap()
                .sealed
                == saved
                    .records
                    .iter()
                    .find(|record| record.metadata.id == original.id)
                    .unwrap()
                    .sealed
        );
    }
    (copy_deleted, version)
}
