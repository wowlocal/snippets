//! Current nested C1, including intent held only in the actual native journal.
use super::*;

fn run(delete: bool, journal_only: bool) {
    let root = isolated_root();
    let fixture = server::Fixture::new();
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    parent.set_title(Some("Public Native Nested Carrier Acceptance"));
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    connect_keys(&window, &fixture);
    let installed = slot(&root, Slot::LibraryKey).unwrap();
    let (key, salt) = wire_material(&root);
    let independent: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&independent["document"]).unwrap()).unwrap();
    document.records[0].hlc = Some(Hlc::parse("100000000000-0000-11111111").unwrap());
    let source = document.records[0].metadata.id;
    let losing = projected(&document, source);
    let vault_key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let winner_body = b"Public nested source winner";
    edit(&mut document, source, winner_body, &vault_key);
    document.records[0].hlc = Some(Hlc::foreign(0xffff_0000_0000));
    let winner = projected(&document, source);
    let raw = crate::merge::merge(None, Some(&losing), Some(&winner))
        .unwrap()
        .survivor
        .unwrap();
    // This is a legitimate primary copy, not an injected journal original.
    // The native worker must authenticate/freeze its own immutable C0 later.
    let initial = {
        let keys = crate::materializer::Keyring::new(&vault_key, &document).unwrap();
        crate::materializer::Evidence::prepare(
            std::slice::from_ref(&raw),
            &keys,
            &std::collections::BTreeMap::new(),
        )
        .unwrap()
    };
    let initial_child = initial.copies().values().next().unwrap().clone();
    let child_id = initial_child.id;
    document.records[0] = crate::projection::vault_record(&raw, None, &document.kid)
        .unwrap()
        .unwrap();
    document.records.push(
        crate::projection::vault_record(&initial_child, None, &document.kid)
            .unwrap()
            .unwrap(),
    );
    let child_body = b"Public separately edited nested C1";
    edit(&mut document, child_id, child_body, &vault_key);
    document
        .records
        .iter_mut()
        .find(|r| r.metadata.id == child_id)
        .unwrap()
        .hlc = Some(Hlc::foreign(0xffff_1000_0000));
    let child_winner = projected(&document, child_id);
    let child = crate::merge::merge(None, Some(&initial_child), Some(&child_winner))
        .unwrap()
        .survivor
        .unwrap();
    let grandchild = crate::merge::secure_variants(&child)
        .unwrap()
        .remove(0)
        .copy_id;
    *document
        .records
        .iter_mut()
        .find(|r| r.metadata.id == child_id)
        .unwrap() = crate::projection::vault_record(&child, None, &document.kid)
        .unwrap()
        .unwrap();
    document = Document::decode(&document.encode().unwrap()).unwrap();
    let unrelated = model::Snippet::new(
        "Public nested unrelated",
        "Public nested unrelated ordinary body",
    );
    model::Library::open(root.clone())
        .unwrap()
        .save(unrelated.clone(), None)
        .unwrap();
    fs::create_dir(root.join("Vault")).unwrap();
    fs::set_permissions(root.join("Vault"), fs::Permissions::from_mode(0o700)).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    action(&window, "Receive Cloud Changes");
    action(&window, "Send Local Changes");
    assert!(
        window.status.label()
            == "An encrypted conflict needs preservation before its source or later edits can be sent."
    );
    let captured = snapshot::checkpoint(&root);
    assert!(captured.journal.preservation_original(child_id).is_none());
    assert!(captured.journal.preservation_original(grandchild).is_none());
    let captured_child = &captured.journal.entry(child_id).unwrap().desired;
    let installation: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("device.json")).unwrap()).unwrap();
    assert!(installation["deviceID"].as_str() == Some(captured_child.origin.as_str()));
    let child_fields = projected(&document, child_id).fields;
    let source_fields = projected(&document, source).fields;
    // Native projection assigns this installation's origin and logical clock.
    // Compute the exact serialized primary projection using that admitted local
    // device; the fixture's synthetic device cannot predict its first HLC.
    let expected = crate::projection::current(
        &[],
        Some(&document),
        &captured_child.origin,
        &Default::default(),
        &Default::default(),
    )
    .unwrap();
    assert!(*captured_child == expected[&child_id]);
    assert!(captured_child.fields == child_fields);
    assert!(uploaded_has(&fixture, &unrelated, &key, &salt));
    assert!(fixture.state.lock().unwrap().record(source).is_none());
    assert!(fixture.state.lock().unwrap().record(child_id).is_none());
    if journal_only {
        // Simulate a legitimate external primary removal after the native owner
        // captured C1. Its actual journal intent remains the authority to review.
        document.records.retain(|r| r.metadata.id != child_id);
        model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    }
    let marker = winner
        .tombstone(Hlc::foreign(0xffff_ff00_0000), "22222222".into(), true)
        .unwrap();
    let source_version = {
        let mut state = fixture.state.lock().unwrap();
        state.put(WireRecord::seal(&marker, &key, &salt).unwrap());
        state.version(source).unwrap()
    };
    action(&window, "Receive Cloud Changes");
    assert!(
        window.status.label()
            == "A cloud deletion needs review. The saved page is retained and your local snippet is preserved."
    );
    let before = primary(&root);
    let counts = data_counts(&fixture);
    let packets = fixture.state.lock().unwrap().submitted.clone();
    let dialog = review(&window);
    assert!(dialog.body().contains("Conflict originals to preserve: 2."));
    assert!(dialog.body().contains(if journal_only {
        "Restore 2 missing conflict originals"
    } else {
        "Restore 1 missing conflict originals"
    }));
    press(dialog.upcast_ref(), "Cancel");
    wait_work(&window);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (dialog, entry) = credentials(&window, delete, false);
    entry.set_text("Public cancelled nested credential");
    press(dialog.upcast_ref(), "Cancel");
    password_done(&window, &entry);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (_dialog, entry) = credentials(&window, delete, false);
    entry.set_text("Public focus-revoked nested credential");
    parent.present();
    until(
        "nested credential focus cancellation did not finish",
        || parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get(),
    );
    assert!(entry.text().is_empty());
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    window.window.present();
    until("nested review window did not regain focus", || {
        window.window.is_active()
    });
    verify(
        &window,
        delete,
        "Public incorrect nested passphrase",
        false,
        false,
    );
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    assert!(fixture.state.lock().unwrap().submitted == packets);
    let recovery = crypto::format_recovery(&[0x66; 16]);
    verify(
        &window,
        delete,
        if delete {
            &recovery
        } else {
            independent["passphrase"].as_str().unwrap()
        },
        false,
        delete,
    );
    assert!(window.status.label().starts_with(if delete {
        "Cloud deletion applied locally."
    } else {
        "Local version kept."
    }));
    assert!(data_counts(&fixture) == counts);
    let decided = snapshot::checkpoint(&root);
    let c0 = decided
        .journal
        .preservation_original(child_id)
        .unwrap()
        .clone();
    let d0 = decided
        .journal
        .preservation_original(grandchild)
        .unwrap()
        .clone();
    let saved = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(saved.records.len() == if delete { 2 } else { 3 });
    let selected = saved
        .records
        .iter()
        .find(|r| r.metadata.id == child_id)
        .unwrap();
    assert!(
        selected.sealed.text().as_bytes()
            == child_winner.fields.as_ref().unwrap().content.as_slice()
    );
    assert!(body(&saved, child_id, &vault_key).as_slice() == child_body);
    assert!(
        body(&saved, grandchild, &vault_key).as_slice()
            == independent["plaintext"].as_str().unwrap().as_bytes()
    );
    assert!(
        !saved
            .records
            .iter()
            .find(|r| r.metadata.id == grandchild)
            .unwrap()
            .metadata
            .is_enabled
    );
    assert!(c0.fields.as_ref().unwrap().content != child_winner.fields.as_ref().unwrap().content);
    assert!(
        d0.fields.as_ref().unwrap().content.as_slice()
            == saved
                .records
                .iter()
                .find(|r| r.metadata.id == grandchild)
                .unwrap()
                .sealed
                .text()
                .as_bytes()
    );
    assert!(decided.journal.inbox.next().is_some());
    assert!(!decided.journal.deletion_approvals.contains_key(&child_id));
    assert!(!decided.journal.deletion_approvals.contains_key(&grandchild));
    no_session_key(&root, child_id);
    action(&window, "Receive Cloud Changes");
    action(&window, "Send Local Changes");
    action(&window, "Sync Now");
    assert!(window.status.label() == CURRENT);
    assert!(local_has(&root, &unrelated));
    let final_source = uploaded(&fixture, source, &key, &salt);
    assert!(final_source.deleted == delete);
    if !delete {
        // Explicit Keep is a new local edit: only updatedAt and its logical
        // clock change. All other metadata and the sealed winner remain exact.
        let sent_fields = final_source.fields.as_ref().unwrap();
        let mut retained_fields = source_fields.unwrap();
        retained_fields.updated_at = sent_fields.updated_at;
        assert!(retained_fields == *sent_fields);
        let saved_fields = projected(&saved, source).fields.unwrap();
        assert!((sent_fields.updated_at - saved_fields.updated_at).abs() < 0.002);
        assert!(body(&saved, source, &vault_key).as_slice() == winner_body);
    }
    let final_child = uploaded(&fixture, child_id, &key, &salt);
    assert!(
        final_child.fields == child_fields && !crate::merge::has_unresolved(Some(&final_child))
    );
    assert!(uploaded(&fixture, grandchild, &key, &salt) == d0);
    let final_document = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(
        final_document
            .records
            .iter()
            .find(|r| r.metadata.id == child_id)
            .unwrap()
            .sealed
            == selected.sealed
    );
    {
        let state = fixture.state.lock().unwrap();
        assert!(state.submitted[..packets.len()] == packets);
        let sent: Vec<_> = state
            .submitted
            .iter()
            .flat_map(|packet| packet.iter())
            .map(|(wire, cas)| (wire.open(&key, &salt).unwrap(), cas))
            .collect();
        let d = sent.iter().position(|(e, _)| *e == d0).unwrap();
        let c = sent.iter().rposition(|(e, _)| *e == c0).unwrap();
        let p = sent.iter().rposition(|(e, _)| e.id == source).unwrap();
        let selected_position = sent
            .iter()
            .rposition(|(e, _)| e.id == child_id && e.fields == child_fields)
            .unwrap();
        assert!(d < c && c < p && c < selected_position);
        assert!(sent[p].1.as_deref() == Some(source_version.as_str()));
        let copy_acks = state
            .acknowledgements
            .iter()
            .filter(|(id, _)| *id == child_id)
            .collect::<Vec<_>>();
        assert!(copy_acks.len() >= 2);
        assert!(sent[selected_position].1.as_ref() == Some(&copy_acks[copy_acks.len() - 2].1));
        assert!(
            sent.iter()
                .filter(|(e, _)| e.id == grandchild)
                .all(|(e, _)| *e == d0)
        );
    }
    let after = snapshot::checkpoint(&root);
    assert!(!after.journal.has_preservation_work() && after.journal.deletion_approvals.is_empty());
    assert!(
        slot(&root, Slot::LibraryKey).is_some_and(|value| value.as_slice() == installed.as_slice())
    );
    assert!(
        slot(&root, Slot::AutomaticSync).is_none() && !root.join("automatic-sync.json").exists()
    );
    for name in ["snippets.json", "Vault/vault.json", "Sync/journal.bin"] {
        let bytes = fs::read(root.join(name)).unwrap();
        for plaintext in [
            winner_body.as_slice(),
            child_body.as_slice(),
            independent["plaintext"].as_str().unwrap().as_bytes(),
        ] {
            assert!(!bytes.windows(plaintext.len()).any(|part| part == plaintext));
        }
    }
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    pause_quit(&window);
    drop(stop);
    parent.destroy();
    app.quit();
}

#[test]
#[ignore = "explicit native nested current Keep acceptance; invoke tests/account-live.sh with --nested-review-keep"]
fn live_nested_current_keep() {
    run(false, false);
}
#[test]
#[ignore = "explicit native nested current Delete acceptance; invoke tests/account-live.sh with --nested-review-delete"]
fn live_nested_current_delete() {
    run(true, false);
}
#[test]
#[ignore = "explicit native nested journal-only Keep acceptance; invoke tests/account-live.sh with --nested-journal-keep"]
fn live_nested_journal_keep() {
    run(false, true);
}
#[test]
#[ignore = "explicit native nested journal-only Delete acceptance; invoke tests/account-live.sh with --nested-journal-delete"]
fn live_nested_journal_delete() {
    run(true, true);
}
