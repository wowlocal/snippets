//! Mapped protected history selection, local restoration and explicit cloud reconnect.
use super::*;
use crate::key_store::history::SwitchPhase;

pub(super) fn protected(root: &Path) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    [
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::CheckpointKey,
        Slot::PairingRecipient,
        Slot::SpaceCreation,
        Slot::KeyMutation,
        Slot::AccountReview,
        Slot::PairingCandidate,
        Slot::BootstrapCandidate,
    ]
    .into_iter()
    .map(|slot_name| slot(root, slot_name))
    .collect()
}
fn reconnect(window: &Rc<AccountWindow>) {
    press(window.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(window);
    assert!(window.libraries.selected() == 0 && !window.sync.is_sensitive());
    window.libraries.set_selected(1);
    wait_work(window);
    assert!(window.sync.is_sensitive());
}
pub(super) fn selected_review(history: &adw::Dialog, title: &str) -> gtk::Button {
    let mut widgets = vec![history.clone().upcast::<gtk::Widget>()];
    let mut selected = false;
    while let Some(widget) = widgets.pop() {
        if let Some(row) = widget.downcast_ref::<adw::ActionRow>() {
            if row.title().starts_with("Switch ") {
                selected = row.title() == title;
            } else if selected && row.title() == "Restore Saved Local Changes" {
                return button(row.upcast_ref(), "Review…");
            }
        }
        let mut children = Vec::new();
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            children.push(widget);
        }
        widgets.extend(children.into_iter().rev());
    }
    panic!("selected native saved-switch review was unavailable");
}
fn review(window: &Rc<AccountWindow>) -> adw::AlertDialog {
    press(window.window.upcast_ref(), "Library Recovery History…");
    until("native restoration history did not map", || {
        window
            .history_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
    });
    let history = window.history_dialog.borrow().clone().unwrap();
    assert!(history.title() == "Library Recovery History");
    let selected = selected_review(&history, "Switch 1 · finished locally");
    until("selected native saved-switch review did not map", || {
        selected.is_mapped() && selected.is_sensitive()
    });
    selected.emit_clicked();
    until("native saved-changes review did not map", || {
        window
            .snapshot_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
    });
    assert!(window.history_dialog.borrow().is_none());
    let dialog = window.snapshot_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Restore the Saved Changes?"));
    assert!(
        dialog.default_response().as_deref() == Some("back") && dialog.close_response() == "back"
    );
    assert!(
        dialog
            .body()
            .contains("1 saved records · 1 preserved current versions · 0 secure records")
    );
    let body = dialog.body();
    let (saved_section, current_section) = body.split_once("\n\nCurrent library: ").unwrap();
    let saved = format!("{} · key version 1", uuid::Uuid::from_u128(201));
    let current = format!("{} · key version 1", uuid::Uuid::from_u128(200));
    assert!(saved_section.starts_with("Saved library: ") && saved_section.ends_with(&saved));
    assert!(
        current_section
            .lines()
            .nth(1)
            .is_some_and(|line| line == current)
    );
    assert!(
        dialog
            .body()
            .contains("Reconnect and select a library afterward")
    );
    dialog
}
fn password(window: &Rc<AccountWindow>) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let dialog = review(window);
    press(dialog.upcast_ref(), "Restore Changes");
    until("native restoration password did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Authorize Saved Changes Restoration"));
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}
#[track_caller]
fn finished(window: &AccountWindow, entry: Option<&gtk::PasswordEntry>) {
    until("native restoration operation did not finish", || {
        !window.busy.get()
    });
    assert!(
        window.history_dialog.borrow().is_none()
            && window.snapshot_dialog.borrow().is_none()
            && window.password_dialog.borrow().is_none()
    );
    assert!(window.restoration_preparation.borrow().is_none());
    if let Some(entry) = entry {
        assert!(entry.text().is_empty());
    }
}
fn saved(root: &Path, id: uuid::Uuid) -> model::Snippet {
    model::Library::open(root.into())
        .unwrap()
        .snippets
        .into_iter()
        .find(|s| s.id == id)
        .unwrap()
}
fn preserve(
    root: &Path,
    original: &model::Snippet,
    current: &model::Snippet,
    extra: &model::Snippet,
) -> model::Snippet {
    let library = model::Library::open(root.into()).unwrap();
    assert!(library.snippets.len() == 3);
    let restored = library
        .snippets
        .iter()
        .find(|s| s.id == original.id)
        .unwrap();
    assert!(
        restored.content == original.content
            && restored.name == original.name
            && restored.tags == original.tags
            && restored.keyword == original.keyword
    );
    assert!(library.snippets.iter().any(|s| s == extra));
    let copy = library
        .snippets
        .iter()
        .find(|s| s.id != original.id && s.id != extra.id)
        .unwrap();
    assert!(
        copy.content == current.content
            && copy.name.contains(&current.name)
            && copy.tags.iter().any(|tag| current.tags.contains(tag))
    );
    assert!(!copy.is_enabled && !copy.is_pinned && copy.keyword.is_empty());
    copy.clone()
}
#[test]
#[ignore = "explicit native history restoration GTK/HTTPS/private-keyring/private-PAM acceptance; invoke tests/account-live.sh with --restoration"]
fn live_saved_history_restoration_preserves_current_versions() {
    creation::run(creation::Followup::Restoration);
}
pub(super) fn run(
    window: &Rc<AccountWindow>,
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
    original: &model::Snippet,
) {
    reconnect(window);
    // Establish real current-scope CAS acceptance and a feed cursor before
    // local edits. Restoration must retain these instead of old archive facts.
    press(window.window.upcast_ref(), "Sync Now");
    wait_work(window);
    assert!(
        window.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    println!("Native restoration: current-library CAS and feed established.");
    let current = saved(root, original.id);
    let mut edited = current.clone();
    edited.content = "Public current restoration body".into();
    edited.name = "Public current restoration title".into();
    edited.keyword = "public-restoration-current".into();
    edited.tags = vec!["public-current-tag".into()];
    edited.is_pinned = true;
    let mut library = model::Library::open(root.into()).unwrap();
    library.save(edited, Some(&current)).unwrap();
    let current = saved(root, original.id);
    let extra = model::Snippet::new(
        "Public unrelated restoration entry",
        "Public unrelated retained body",
    );
    library.save(extra.clone(), None).unwrap();
    let extra = saved(root, extra.id);
    let before = creation::images(root);
    let keys = protected(root);
    let (checkpoint, catalog) = switching::checkpoint_and_history(root);
    assert!(catalog.switches.len() == 2 && catalog.restorations.is_empty());
    assert!(
        checkpoint
            .journal
            .agreed_envelopes()
            .contains_key(&original.id)
    );
    assert!(checkpoint.journal.inbox.cursor().is_some());
    assert!(slot(root, Slot::HistoryRestore).is_none());
    let data_counts = {
        let s = fixture.state.lock().unwrap();
        (s.fetches, s.batches, s.accepted)
    };
    let source_id = uuid::Uuid::from_u128(200);
    let target_id = uuid::Uuid::from_u128(201);
    let source_wire = fixture
        .state
        .lock()
        .unwrap()
        .record_in(source_id, original.id)
        .unwrap();
    let target_wire = fixture
        .state
        .lock()
        .unwrap()
        .record_in(target_id, original.id)
        .unwrap();
    let unchanged = || {
        assert!(creation::images(root) == before && protected(root) == keys);
        assert!(slot(root, Slot::HistoryRestore).is_none());
        assert!(saved(root, original.id) == current && saved(root, extra.id) == extra);
        let s = fixture.state.lock().unwrap();
        assert!((s.fetches, s.batches, s.accepted) == data_counts);
        assert!(
            s.record_in(source_id, original.id)
                .is_some_and(|v| v == source_wire)
        );
        assert!(
            s.record_in(target_id, original.id)
                .is_some_and(|v| v == target_wire)
        );
    };
    let dialog = review(window);
    press(dialog.upcast_ref(), "Keep Current State");
    finished(window, None);
    unchanged();
    println!("Native restoration: review Cancel preserved current state.");
    let _dialog = review(window);
    parent.present();
    until("restoration review focus loss did not cancel", || {
        parent.is_active() && window.snapshot_dialog.borrow().is_none() && !window.busy.get()
    });
    finished(window, None);
    unchanged();
    println!("Native restoration: review focus revocation preserved current state.");
    window.window.present();
    until("restoration did not regain focus", || {
        window.window.is_active()
    });
    for (value, response) in [
        ("Public fictional password", "Cancel"),
        ("Public incorrect password", "Authorize"),
    ] {
        let (dialog, entry) = password(window);
        entry.set_text(value);
        press(dialog.upcast_ref(), response);
        println!("Native restoration: waiting for private credential refusal.");
        finished(window, Some(&entry));
        unchanged();
    }
    let (_dialog, entry) = password(window);
    entry.set_text("Public fictional password");
    parent.present();
    until("restoration password focus loss did not cancel", || {
        parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get()
    });
    finished(window, Some(&entry));
    unchanged();
    println!("Native restoration: password refusals and focus revocation preserved current state.");
    window.window.present();
    until("restoration stale review did not regain focus", || {
        window.window.is_active()
    });
    let (dialog, entry) = password(window);
    let mut newer = current.clone();
    newer.content = "Public newer current body after review".into();
    model::Library::open(root.into())
        .unwrap()
        .save(newer, Some(&current))
        .unwrap();
    let newer = saved(root, original.id);
    let stale = creation::images(root);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    println!("Native restoration: waiting for stale-primary refusal.");
    finished(window, Some(&entry));
    assert!(
        creation::images(root) == stale
            && protected(root) == keys
            && slot(root, Slot::HistoryRestore).is_none()
    );
    assert!(saved(root, original.id) == newer && saved(root, extra.id) == extra);
    assert!(!window.sync.is_sensitive() && window.libraries.selected() == 0);
    assert!(!root.join("primary.pending").exists());
    println!("Native restoration: stale-primary consent refused before receipt.");
    reconnect(window);
    let before = creation::images(root);
    let (before_checkpoint, _) = switching::checkpoint_and_history(root);
    assert!(before_checkpoint.journal.agreed_envelopes() == checkpoint.journal.agreed_envelopes());
    let (dialog, entry) = password(window);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    println!("Native restoration: waiting for fresh-authorized local completion.");
    finished(window, Some(&entry));
    assert!(
        window.status.label()
            == "Saved changes restored. Current versions and previous keys are kept. Reconnect and select a library before syncing."
    );
    assert!(
        !window.sync.is_sensitive()
            && !window.receive.is_sensitive()
            && !window.send.is_sensitive()
            && window.libraries.selected() == 0
    );
    assert!(protected(root) == keys && slot(root, Slot::HistoryRestore).is_some());
    assert!(creation::images(root) != before);
    let copy = preserve(root, original, &newer, &extra);
    let (restored_checkpoint, catalog) = switching::checkpoint_and_history(root);
    assert!(catalog.switches.len() == 2 && catalog.restorations.len() == 1);
    let receipt = &catalog.restorations[0];
    assert!(
        receipt.phase == SwitchPhase::Completed
            && !receipt.needs_completion
            && receipt.library.id() == source_id
    );
    assert!(
        receipt.summary.restored_records == 1
            && receipt.summary.preserved_versions == 1
            && receipt.summary.secure_records == 0
    );
    assert!(
        restored_checkpoint.journal.agreed_envelopes()
            == before_checkpoint.journal.agreed_envelopes()
    );
    assert!(
        restored_checkpoint.journal.inbox == before_checkpoint.journal.inbox
            && restored_checkpoint.journal.outbound == before_checkpoint.journal.outbound
    );
    assert!(restored_checkpoint.journal.scope() == before_checkpoint.journal.scope());
    assert!(
        before_checkpoint
            .journal
            .preserves_transport_state(&restored_checkpoint.journal)
    );
    let submissions = {
        let s = fixture.state.lock().unwrap();
        assert!((s.fetches, s.batches, s.accepted) == data_counts);
        assert!(
            s.record_in(source_id, original.id)
                .is_some_and(|v| v == source_wire)
        );
        assert!(
            s.record_in(target_id, original.id)
                .is_some_and(|v| v == target_wire)
        );
        s.submitted.len()
    };
    let completed = creation::images(root);
    println!("Native restoration: completed receipt and current checkpoint facts verified.");
    until("restored history worker did not drain", || {
        window.prepare_quit()
    });
    window.window.destroy();
    let reopened = make_window(app, parent, root, fixture, pam);
    let stop = Stop(reopened.clone());
    reconnect(&reopened);
    assert!(creation::images(root) == completed && protected(root) == keys);
    let retained = preserve(root, original, &newer, &extra);
    assert!(retained == copy);
    let (_, catalog) = switching::checkpoint_and_history(root);
    assert!(
        catalog.restorations.len() == 1 && catalog.restorations[0].phase == SwitchPhase::Completed
    );
    let (wire_key, wire_salt) = wire_material(root);
    println!("Native restoration: reopened worker and explicit library admission verified.");
    let started = Instant::now();
    let sampled = Cell::new(false);
    press(reopened.window.upcast_ref(), "Sync Now");
    // One bounded cycle can include several dependency-ordered HTTPS/CAS
    // rounds. Observe the whole cycle separately from a single account command.
    until_for(
        "native restoration encrypted sync cycle did not finish",
        Duration::from_secs(45),
        || {
            if started.elapsed() >= Duration::from_secs(15) && !sampled.replace(true) {
                let s = fixture.state.lock().unwrap();
                println!(
                    "Native restoration: unfinished cycle at 15 seconds; fetches={}, batches={}, accepted={}.",
                    s.fetches, s.batches, s.accepted
                );
            }
            !reopened.busy.get()
        },
    );
    println!(
        "Native restoration: encrypted cycle finished in {} milliseconds.",
        started.elapsed().as_millis()
    );
    assert!(
        reopened.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    assert!(preserve(root, original, &newer, &extra) == copy);
    let s = fixture.state.lock().unwrap();
    for expected in [original, &copy, &extra] {
        let wire = s.record_in(source_id, expected.id).unwrap();
        let decoded = wire.open(&wire_key, &wire_salt).unwrap();
        assert!(
            decoded
                .fields
                .as_ref()
                .is_some_and(|fields| fields.content.as_slice() == expected.content.as_bytes())
        );
    }
    assert!(
        s.record_in(target_id, original.id)
            .is_some_and(|v| v == target_wire)
    );
    let sent = s.submitted[submissions..]
        .iter()
        .flat_map(|batch| batch.iter().map(|(wire, _)| wire.id))
        .collect::<Vec<_>>();
    let preserved = sent.iter().position(|id| *id == copy.id).unwrap();
    let source = sent.iter().position(|id| *id == original.id).unwrap();
    assert!(preserved < source);
    assert!(s.creation_counts() == (3, 2) && s.bootstrap_posts == 2);
    drop(s);
    assert!(!root.join("automatic-sync.json").exists());
    assert!(CloudClient::discover(fixture.server.clone()).is_err());
    until("final restored history worker did not drain", || {
        reopened.prepare_quit()
    });
    drop(stop);
    println!(
        "Native history restoration: mapped saved-state selection, review/password Cancel and focus revocation, wrong private-policy PAM refusal, stale-primary rejection before receipt, fresh-authorized restoration preserving current/unrelated records and current checkpoint facts, completed protected history, explicit reconnect and encrypted preservation-before-source CAS passed."
    );
}
