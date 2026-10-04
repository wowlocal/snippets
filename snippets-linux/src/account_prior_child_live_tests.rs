//! A real cloud copy tombstone received before its raw owner appears locally.
use super::*;
#[path = "account_raw_child_live_tests.rs"]
mod raw_child;

fn run(child_delete: bool, parent_delete: bool) {
    let root = isolated_root();
    let fixture = server::Fixture::new();
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    parent.set_title(Some("Public Native Prior Child Acceptance"));
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    connect_keys(&window, &fixture);
    let unrelated = model::Snippet::new(
        "Public prior-child unrelated",
        "Public prior-child ordinary body",
    );
    model::Library::open(root.clone())
        .unwrap()
        .save(unrelated.clone(), None)
        .unwrap();
    let (key, salt) = wire_material(&root);
    let independent: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&independent["document"]).unwrap()).unwrap();
    let source = document.records[0].metadata.id;
    let losing = projected(&document, source);
    let vault_key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    edit(
        &mut document,
        source,
        b"Public prior-child source winner",
        &vault_key,
    );
    let winner = projected(&document, source);
    let raw = crate::merge::merge(None, Some(&losing), Some(&winner))
        .unwrap()
        .survivor
        .unwrap();
    let child_id = crate::merge::secure_variants(&raw)
        .unwrap()
        .remove(0)
        .copy_id;
    let prior_copy = {
        let keys = crate::materializer::Keyring::new(&vault_key, &document).unwrap();
        crate::materializer::Evidence::prepare(
            std::slice::from_ref(&raw),
            &keys,
            &std::collections::BTreeMap::new(),
        )
        .unwrap()
        .copies()[&child_id]
            .clone()
    };
    let raw_record = crate::projection::vault_record(&raw, None, &document.kid)
        .unwrap()
        .unwrap();
    document.records.clear();
    fs::create_dir(root.join("Vault")).unwrap();
    fs::set_permissions(root.join("Vault"), fs::Permissions::from_mode(0o700)).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    let child_marker = prior_copy
        .tombstone(Hlc::foreign(0xffff_ff00_0000), "22222222".into(), true)
        .unwrap();
    let child_version = {
        let mut state = fixture.state.lock().unwrap();
        state.put(WireRecord::seal(&child_marker, &key, &salt).unwrap());
        state.version(child_id).unwrap()
    };
    action(&window, "Receive Cloud Changes");
    assert!(window.status.label() == "Cloud changes received. Local changes have not been sent.");
    let prior = snapshot::checkpoint(&root);
    assert!(prior.journal.confirmed(child_id).unwrap().envelope == child_marker);
    assert!(prior.journal.known_absence(child_id));
    assert!(prior.journal.deletion_approvals.is_empty());
    document.records.push(raw_record);
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    action(&window, "Send Local Changes");
    assert!(
        window.status.label()
            == "An encrypted conflict needs preservation before its source or later edits can be sent."
    );
    let captured = snapshot::checkpoint(&root);
    assert!(captured.journal.preservation_original(child_id).is_none());
    assert!(uploaded_has(&fixture, &unrelated, &key, &salt));
    let marker = winner
        .tombstone(Hlc::foreign(0xffff_ff80_0000), "22222222".into(), true)
        .unwrap();
    let parent_version = {
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
    let dialog = review(&window);
    assert!(
        dialog.body().contains(
            "Review this snippet first so another pending conflict decision can continue."
        )
    );
    press(dialog.upcast_ref(), "Cancel");
    wait_work(&window);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (dialog, entry) = credentials(&window, child_delete, false);
    entry.set_text("Public cancelled prior-child credential");
    press(dialog.upcast_ref(), "Cancel");
    password_done(&window, &entry);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (_dialog, entry) = credentials(&window, child_delete, false);
    entry.set_text("Public revoked prior-child credential");
    parent.present();
    until(
        "prior-child credential focus cancellation did not finish",
        || parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get(),
    );
    assert!(entry.text().is_empty());
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    window.window.present();
    until("prior-child window did not regain focus", || {
        window.window.is_active()
    });
    verify(
        &window,
        child_delete,
        "Public incorrect prior-child credential",
        false,
        false,
    );
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let held = snapshot::checkpoint(&root);
    verify(
        &window,
        child_delete,
        &crypto::format_recovery(&[0x66; 16]),
        false,
        true,
    );
    assert!(window.status.label().starts_with(if child_delete {
        "Cloud deletion applied locally."
    } else {
        "Local version kept."
    }));
    assert!(data_counts(&fixture) == counts);
    let child_decided = snapshot::checkpoint(&root);
    assert!(child_decided.journal.inbox == held.journal.inbox);
    assert!(child_decided.journal.outbound == held.journal.outbound);
    assert!(child_decided.journal.confirmed(child_id) == held.journal.confirmed(child_id));
    assert!(
        !child_decided
            .journal
            .deletion_approvals
            .contains_key(&source)
    );
    assert!(
        child_decided
            .journal
            .deletion_approved(&child_marker)
            .unwrap()
            == child_delete
    );
    let original = child_decided
        .journal
        .preservation_original(child_id)
        .unwrap()
        .clone();
    let saved = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(saved.records.iter().any(|r| r.metadata.id == child_id) != child_delete);
    assert!(
        saved
            .records
            .iter()
            .find(|r| r.metadata.id == source)
            .unwrap()
            .sealed
            == document.records[0].sealed
    );
    if !child_delete {
        assert!(
            body(&saved, child_id, &vault_key).as_slice()
                == independent["plaintext"].as_str().unwrap().as_bytes()
        );
        assert!(
            saved
                .records
                .iter()
                .find(|r| r.metadata.id == child_id)
                .unwrap()
                .sealed
                .text()
                .as_bytes()
                == original.fields.as_ref().unwrap().content.as_slice()
        );
    }
    let parent_dialog = review(&window);
    assert!(
        !parent_dialog
            .body()
            .contains("Your choice applies only to this snippet.")
    );
    press(parent_dialog.upcast_ref(), "Cancel");
    wait_work(&window);
    let before_parent = primary(&root);
    verify(
        &window,
        parent_delete,
        "Public incorrect parent credential",
        false,
        false,
    );
    assert!(primary(&root) == before_parent && data_counts(&fixture) == counts);
    verify(
        &window,
        parent_delete,
        &crypto::format_recovery(&[0x66; 16]),
        false,
        true,
    );
    assert!(window.status.label().starts_with(if parent_delete {
        "Cloud deletion applied locally."
    } else {
        "Local version kept."
    }));
    assert!(data_counts(&fixture) == counts);
    assert!(
        snapshot::checkpoint(&root)
            .journal
            .preservation_original(child_id)
            == Some(&original)
    );
    no_session_key(&root, child_id);
    action(&window, "Receive Cloud Changes");
    assert!(
        !root.join("Sync/primary.pending").exists(),
        "prior-child receive left a WAL"
    );
    action(&window, "Send Local Changes");
    assert!(
        !root.join("Sync/primary.pending").exists(),
        "prior-child send left a WAL"
    );
    action(&window, "Sync Now");
    assert!(
        !root.join("Sync/primary.pending").exists(),
        "prior-child sync left a WAL"
    );
    if window.status.label() == LOCKED {
        assert!(child_delete);
        let held_bytes = primary(&root);
        let held_counts = data_counts(&fixture);
        let (dialog, entry) = super::super::super::vault_dialog(&window);
        entry.set_text("Public cancelled prior-child sync credential");
        press(dialog.upcast_ref(), "Cancel");
        super::super::super::finished(&window, &entry);
        assert!(primary(&root) == held_bytes && data_counts(&fixture) == held_counts);
        super::super::super::credential(
            &window,
            "Public incorrect prior-child sync credential",
            false,
        );
        assert!(primary(&root) == held_bytes && data_counts(&fixture) == held_counts);
        super::super::super::credential(&window, &crypto::format_recovery(&[0x66; 16]), true);
    }
    let settled = snapshot::checkpoint(&root);
    let pending: Vec<_> = settled
        .journal
        .pending()
        .unwrap()
        .iter()
        .map(|e| {
            (
                e.id == child_id,
                e.id == source,
                e.deleted,
                settled.journal.deletion_approved(e).unwrap(),
            )
        })
        .collect();
    let incoming = settled.journal.inbox.next().map(|record| {
        let e = &record.envelope;
        (
            e.id == child_id,
            e.id == source,
            e.deleted,
            e == &child_marker,
            e == &marker,
            settled.journal.deletion_approved(e).unwrap(),
            settled.journal.local_intent(e.id, None).unwrap() == Some(e),
        )
    });
    assert!(
        window.status.label() == CURRENT,
        "child_delete={child_delete}, parent_delete={parent_delete}, pending={pending:?}, incoming={incoming:?}, preservation={}, cloud_review={}, send_review={}, preservation_required={}, receive_vault={}, send_vault={}, verify_vault={}, more_work={}, local_review={}, conflict_review={}",
        settled.journal.has_preservation_work(),
        window.status.label()
            == "A cloud deletion needs review. Your local snippet and the incoming page are preserved.",
        window.status.label() == "A saved deletion needs review. Your local intent is preserved.",
        window.status.label()
            == "A conflict needs preservation before its source or later edits can synchronize.",
        window.status.label()
            == "An encrypted record or conflict needs your vault before synchronization can continue.",
        window.status.label()
            == "An encrypted conflict needs your vault before synchronization can continue.",
        window.status.label() == "Verify the current vault to continue synchronization.",
        window.status.label()
            == "Some synchronization work remains. Choose Sync Now again to continue.",
        window.status.label()
            == "A missing local snippet needs review before synchronization can continue.",
        window.status.label()
            == "A conflict copy or retained request needs review. Local data and the server response are preserved."
    );
    assert!(local_has(&root, &unrelated));
    assert!(uploaded(&fixture, child_id, &key, &salt).deleted == child_delete);
    assert!(uploaded(&fixture, source, &key, &salt).deleted == parent_delete);
    let settled_document = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(
        settled_document
            .records
            .iter()
            .any(|r| r.metadata.id == source)
            != parent_delete
    );
    assert!(
        settled_document
            .records
            .iter()
            .any(|r| r.metadata.id == child_id)
            != child_delete
    );
    if !parent_delete {
        assert!(
            body(&settled_document, source, &vault_key).as_slice()
                == b"Public prior-child source winner"
        );
    }
    if !child_delete {
        assert!(
            body(&settled_document, child_id, &vault_key).as_slice()
                == independent["plaintext"].as_str().unwrap().as_bytes()
        );
    }
    {
        let state = fixture.state.lock().unwrap();
        let offers: Vec<_> = state.submitted.iter().flatten().collect();
        let original_position = offers
            .iter()
            .position(|(wire, expected)| {
                wire.id == child_id
                    && expected.as_deref() == Some(child_version.as_str())
                    && wire.open(&key, &salt).unwrap() == original
            })
            .unwrap();
        let source_position = offers
            .iter()
            .position(|(wire, expected)| {
                wire.id == source && expected.as_deref() == Some(parent_version.as_str())
            })
            .unwrap();
        assert!(original_position < source_position);
        if child_delete {
            let deletion_position = offers
                .iter()
                .rposition(|(wire, _)| {
                    wire.id == child_id && wire.open(&key, &salt).unwrap().deleted
                })
                .unwrap();
            assert!(original_position < deletion_position);
        }
    }
    let final_checkpoint = snapshot::checkpoint(&root);
    assert!(!final_checkpoint.journal.has_preservation_work());
    assert!(final_checkpoint.journal.deletion_approvals.is_empty());
    assert!(
        slot(&root, Slot::AutomaticSync).is_none() && !root.join("automatic-sync.json").exists()
    );
    pause_quit(&window);
    drop(stop);
    parent.destroy();
    app.quit();
}

#[test]
#[ignore = "explicit native prior cloud-child Keep/parent Keep acceptance"]
fn live_prior_child_keep_parent_keep() {
    if raw_child::entrypoint(false) {
        return;
    }
    raw_child::process(false);
    run(false, false);
}
#[test]
#[ignore = "explicit native prior cloud-child Keep/parent Delete acceptance"]
fn live_prior_child_keep_parent_delete() {
    run(false, true);
}
#[test]
#[ignore = "explicit native prior cloud-child Delete/parent Keep acceptance"]
fn live_prior_child_delete_parent_keep() {
    if raw_child::entrypoint(true) {
        return;
    }
    raw_child::process(true);
    run(true, false);
}
#[test]
#[ignore = "explicit native prior cloud-child Delete/parent Delete acceptance"]
fn live_prior_child_delete_parent_delete() {
    run(true, true);
}
