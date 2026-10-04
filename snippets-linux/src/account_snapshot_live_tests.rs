//! Mapped snapshot review reached through real cursor-invalid HTTPS responses.
use super::*;

pub(super) fn checkpoint(root: &Path) -> crate::journal::Checkpoint {
    let root = root.to_owned();
    let (sender, receiver) = mpsc::channel();
    let worker = thread::spawn(move || {
        let mut store = Store::load(&root, Native::new().unwrap()).unwrap();
        let checkpoint = store
            .transaction_with::<_, crate::secret_store::Failure>(|owner| {
                let binding = crate::key_store::installed_binding_locked(owner)
                    .unwrap()
                    .unwrap();
                let material = owner.checkpoint_material(false)?.unwrap();
                let key = RootKey::from_bytes(&material[..32]).unwrap();
                let salt = material[32..].try_into().unwrap();
                let library = model::Library::open(root.clone()).unwrap();
                Ok(crate::journal::Checkpoint::load(
                    &library,
                    &key,
                    &salt,
                    binding.checkpoint_scope(),
                )
                .unwrap())
            })
            .unwrap();
        sender.send(checkpoint).unwrap();
    });
    until(
        "native snapshot checkpoint inspection did not finish",
        || worker.is_finished(),
    );
    worker.join().unwrap();
    receiver.recv().unwrap()
}

fn review(window: &Rc<AccountWindow>) -> adw::AlertDialog {
    press(window.window.upcast_ref(), "Review Missing Cloud Records…");
    until("native missing-snapshot review did not map", || {
        window
            .snapshot_dialog
            .borrow()
            .as_ref()
            .is_some_and(|dialog| dialog.is_mapped())
    });
    let dialog = window.snapshot_dialog.borrow().clone().unwrap();
    assert!(window.busy.get());
    assert!(
        dialog.heading().as_deref() == Some("Keep Local Records and Resume?")
            && dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(dialog.body().contains("2 previously known records"));
    dialog
}
fn done(window: &Rc<AccountWindow>) {
    wait_work(window);
    assert!(window.snapshot_dialog.borrow().is_none());
}

pub(super) fn run(
    window: &Rc<AccountWindow>,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    key: &RootKey,
    salt: &[u8; 32],
) {
    let snippets = model::Library::open(root.into()).unwrap().snippets;
    assert!(snippets.len() == 1);
    let source = &snippets[0];
    let vault = crate::vault::read_document(root).unwrap().unwrap();
    assert!(vault.records.len() == 1 && !vault.records[0].metadata.is_enabled);
    let copy = &vault.records[0];
    let source_record = uploaded(fixture, source.id, key, salt);
    let copy_record = uploaded(fixture, copy.metadata.id, key, salt);
    let before = checkpoint(root);
    // The earlier real receipts have already confirmed both copy and source.
    // Their temporary original offers are retired; the live protected copy and
    // confirmed merge ancestors must still survive the snapshot reset.
    assert!(before.journal.conflict_snapshots().is_empty());
    let ancestors = before.journal.agreed_envelopes();
    assert!(ancestors.get(&copy.metadata.id) == Some(&copy_record));
    let primary_before = primary(root);
    let batches = fixture.state.lock().unwrap().batches;
    {
        let mut state = fixture.state.lock().unwrap();
        state.omit(source.id);
        state.omit(copy.metadata.id);
        state.invalidate_cursor = true;
    }
    action(window, "Receive Cloud Changes");
    assert!(
        fixture
            .state
            .lock()
            .unwrap()
            .fetched
            .last()
            .unwrap()
            .is_some()
    );
    assert!(primary(root)[..2] == primary_before[..2]);
    assert!(!window.review_snapshot.is_visible());
    action(window, "Receive Cloud Changes");
    assert!(fixture.state.lock().unwrap().fetched.last() == Some(&None));
    assert!(
        window.status.label()
            == "The complete cloud snapshot is missing previously confirmed records. Receiving is halted for review; local records are preserved."
    );
    assert!(window.review_snapshot.is_visible());
    assert!(primary(root)[..2] == primary_before[..2]);
    assert!(fixture.state.lock().unwrap().batches == batches);
    let halted = primary(root);
    assert!(checkpoint(root).journal.inbox.needs_review());
    let counts = data_counts(fixture);
    let dialog = review(window);
    press(dialog.upcast_ref(), "Cancel");
    done(window);
    assert!(
        window.status.label() == "Snapshot review cancelled. Local and cloud records are kept."
    );
    assert!(primary(root) == halted && data_counts(fixture) == counts);
    let _dialog = review(window);
    parent.present();
    until("native snapshot focus cancellation did not finish", || {
        parent.is_active() && window.snapshot_dialog.borrow().is_none() && !window.busy.get()
    });
    assert!(primary(root) == halted && data_counts(fixture) == counts);
    window.window.present();
    until("native snapshot window did not regain focus", || {
        window.window.is_active()
    });

    // A real external primary edit invalidates the drawn review. It cannot be
    // silently included in a decision prepared for an earlier complete image.
    let dialog = review(window);
    let mut changed = snippets.clone();
    changed[0].content = "Public edit after snapshot review".into();
    changed[0].updated_at += 1.0;
    model::atomic_write(
        &root.join("snippets.json"),
        &model::encode_library(&changed, false).unwrap(),
    )
    .unwrap();
    let edited = primary(root);
    press(dialog.upcast_ref(), "Keep Records and Resume");
    done(window);
    assert!(
        window.status.label()
            == "The local or cloud library changed. Review the missing records again."
    );
    assert!(primary(root) == edited && data_counts(fixture) == counts);
    model::atomic_write(&root.join("snippets.json"), &halted[0]).unwrap();
    assert!(primary(root) == halted);

    let dialog = review(window);
    press(dialog.upcast_ref(), "Keep Records and Resume");
    done(window);
    assert!(window.status.label().starts_with("Cloud review complete."));
    assert!(!window.review_snapshot.is_visible());
    let resumed = primary(root);
    assert!(resumed[..2] == halted[..2] && resumed[2] != halted[2]);
    assert!(data_counts(fixture) == counts);
    let reset = checkpoint(root);
    assert!(
        !reset.journal.inbox.needs_review()
            && reset.journal.inbox.cursor().is_none()
            && reset.journal.agreed_envelopes().is_empty()
            && reset.journal.outbound.is_none()
    );
    assert!(reset.journal.conflict_snapshots().is_empty());
    for (id, envelope) in &ancestors {
        assert!(reset.journal.merge_ancestor(*id) == Some(envelope));
    }
    action(window, "Send Local Changes");
    assert!(
        window.status.label()
            == "Finish receiving the saved cloud snapshot before sending local changes."
    );
    assert!(data_counts(fixture) == counts);
    action(window, "Receive Cloud Changes");
    assert!(fixture.state.lock().unwrap().fetched.last() == Some(&None));
    assert!(fixture.state.lock().unwrap().batches == batches);
    assert!(primary(root)[..2] == halted[..2]);
    action(window, "Send Local Changes");
    assert!(
        window.status.label()
            == "Local changes confirmed by the cloud. Receive Cloud Changes to check other devices."
    );
    {
        let state = fixture.state.lock().unwrap();
        assert!(state.batches == batches + 1);
        let offers = state.submitted.last().unwrap();
        assert!(offers.len() == 2);
        assert!(offers.iter().all(|(_, expected)| expected.is_none()));
    }
    assert!(uploaded(fixture, source.id, key, salt) == source_record);
    assert!(uploaded(fixture, copy.metadata.id, key, salt) == copy_record);
    assert!(crate::vault::read_document(root).unwrap().unwrap() == vault);
    assert!(local_has(root, source));
    action(window, "Sync Now");
    assert!(window.status.label() == CURRENT);
    assert!(fixture.state.lock().unwrap().batches == batches + 1);
    assert!(primary(root)[..2] == halted[..2]);
    no_session_key(root, copy.metadata.id);
}
