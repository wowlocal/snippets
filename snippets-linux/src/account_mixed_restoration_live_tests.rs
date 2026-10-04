//! Native archive of a public legacy mixed-scope primary; whole GTK restoration.
use super::*;
use crate::wire::WireRecord;
use std::os::unix::fs::PermissionsExt;

const ADDITIONAL_ID: u128 = 9002;
const SOURCE_ONLY_ID: u128 = 9001;
const CURRENT_C: &[u8] = b"Public current additional secure body";
const NEWER_C: &[u8] = b"Public newer additional secure body after review";
const EXTRA_BODY: &[u8] = b"Public unrelated mixed secure retained body";

#[derive(Clone, Copy)]
pub(in crate::account_ui::live_tests) enum Mode {
    RetainedJson,
    FilesJson,
    FilesBackup,
}
pub(super) struct Inputs {
    mode: Mode,
    directory: PathBuf,
    paths: Vec<PathBuf>,
    bytes: Vec<Zeroizing<Vec<u8>>>,
    source: Document,
    archived: Record,
}
pub(super) struct Context<'a> {
    pub(super) native: RestorationContext<'a>,
    pub(super) archived: Record,
    pub(super) source_wire: WireRecord,
    pub(super) initial: Document,
}
impl Inputs {
    pub(super) fn new(root: &Path, mode: Mode, a: &Document) -> Self {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/restoration-additional-vault-v1.json"
        ))
        .unwrap();
        let source = Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
        assert!(source.kid == a.kid && source.salt().unwrap() != a.salt().unwrap());
        let archived = source
            .records
            .iter()
            .find(|r| r.metadata.id == uuid::Uuid::from_u128(ADDITIONAL_ID))
            .unwrap()
            .clone();
        let directory = root.parent().unwrap().join("public-vault-sources");
        assert!(!directory.exists());
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let mut names = Vec::new();
        if !matches!(mode, Mode::RetainedJson) {
            names.push(("public source A.json", a.encode().unwrap()));
        }
        names.push(if matches!(mode, Mode::FilesBackup) {
            (
                "public source C.snippetsbackup",
                serde_json::to_vec(&fixture["container"]).unwrap(),
            )
        } else {
            ("public source C.json", source.encode().unwrap())
        });
        let (paths, bytes) = names
            .into_iter()
            .map(|(name, bytes)| {
                let path = directory.join(name);
                model::atomic_write(&path, &bytes).unwrap();
                (path, Zeroizing::new(bytes))
            })
            .unzip();
        Self {
            mode,
            directory,
            paths,
            bytes,
            source,
            archived,
        }
    }
    pub(super) fn install_legacy_source(&self, root: &Path) {
        let mut legacy = document(root);
        legacy.records.push(self.archived.clone());
        assert!(
            crypto::open_record(
                &self.archived.sealed,
                &RootKey::from_bytes(&[0x11; 32]).unwrap(),
                &legacy.salt().unwrap(),
                &legacy.kid,
                self.archived.metadata.id,
                false
            )
            .is_err()
        );
        assert!(
            vault::body(
                &self.source,
                self.archived.metadata.id,
                &RootKey::from_bytes(&[0x77; 32]).unwrap()
            )
            .as_slice()
                == b"Public additional saved secure body"
        );
        write(root, &legacy);
        // No protected history is rewritten. The actual metadata-only switch
        // archives this public legacy primary using its production journal path.
    }
    pub(super) fn install_current(&self, root: &Path, current: &mut Document) {
        let mut record = self.archived.clone();
        let key = RootKey::from_bytes(&[0x44; 32]).unwrap();
        record.sealed = crypto::seal_record(
            b"Public independently protected current additional seed",
            &key,
            &current.salt().unwrap(),
            &current.kid,
            record.metadata.id,
            false,
        )
        .unwrap();
        record.content_hash = crypto::content_hash(
            b"Public independently protected current additional seed",
            &key,
            &current.salt().unwrap(),
        );
        record.hlc = Some(
            crate::clock::stamp(
                root,
                None,
                record.metadata.updated_at.timestamp_millis().max(0) as u64,
            )
            .unwrap(),
        );
        current.records.push(record);
    }
    fn retained(&self) -> bool {
        matches!(self.mode, Mode::RetainedJson)
    }
    fn source_password(&self) -> &'static str {
        if matches!(self.mode, Mode::FilesBackup) {
            "Café public additional backup fixture"
        } else {
            "Café public additional vault fixture"
        }
    }
    fn change(&self, index: usize) {
        let mut changed = self.bytes[index].clone();
        changed.push(b' ');
        model::atomic_write(&self.paths[index], &changed).unwrap();
    }
    fn restore(&self, index: usize) {
        model::atomic_write(&self.paths[index], &self.bytes[index]).unwrap();
    }
}
impl Drop for Inputs {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            assert!(
                self.paths
                    .iter()
                    .zip(&self.bytes)
                    .all(|(p, b)| fs::read(p).unwrap().as_slice() == b.as_slice())
            );
        }
        fs::remove_dir_all(&self.directory).unwrap();
    }
}
fn walk(root: &gtk::Widget) -> Vec<gtk::Widget> {
    let mut pending = vec![root.clone()];
    let mut result = Vec::new();
    while let Some(widget) = pending.pop() {
        let mut child = widget.first_child();
        while let Some(w) = child {
            child = w.next_sibling();
            pending.push(w);
        }
        result.push(widget);
    }
    result
}
#[allow(deprecated)]
fn selected_paths(chooser: &gtk::FileChooserDialog) -> std::collections::BTreeSet<PathBuf> {
    let files = chooser.files();
    (0..files.n_items())
        .map(|i| {
            files
                .item(i)
                .and_downcast::<gtk::gio::File>()
                .unwrap()
                .path()
                .unwrap()
        })
        .collect()
}
#[allow(deprecated)]
fn select_all_visible(chooser: &gtk::FileChooserDialog) {
    for widget in walk(chooser.upcast_ref())
        .into_iter()
        .filter(|w| w.is_mapped())
    {
        if let Some(view) = widget.downcast_ref::<gtk::ColumnView>()
            && let Some(model) = view.model()
        {
            model.select_all();
        } else if let Some(view) = widget.downcast_ref::<gtk::ListView>()
            && let Some(model) = view.model()
        {
            model.select_all();
        } else if let Some(view) = widget.downcast_ref::<gtk::TreeView>()
            && view.selection().mode() == gtk::SelectionMode::Multiple
        {
            view.selection().select_all();
        }
    }
}
impl Inputs {
    #[allow(deprecated)]
    fn credentials(
        &self,
        window: &Rc<AccountWindow>,
    ) -> (adw::AlertDialog, Vec<gtk::PasswordEntry>) {
        let (first, old) = credentials(window, true, None);
        old[0].set_text("Café public current vault fixture");
        old[1].set_text("Café public fixture");
        super::super::portal::expect(true, Some(&self.paths));
        press(first.upcast_ref(), "Choose Several Vault Files…");
        if super::super::portal::enabled() {
            let portal = crate::portal_live_tests::chooser("Choose Previous Vault File");
            assert!(old.iter().all(|e| e.text().is_empty()));
            assert!(
                window.restoration_file_choice.borrow().is_some()
                    && window.restoration_preparation.borrow().is_none()
                    && window.password_dialog.borrow().is_none()
            );
            portal.select_multiple(&self.paths);
        } else {
            let chooser = files::chooser(window, true);
            assert!(old.iter().all(|e| e.text().is_empty()));
            let expected = self
                .paths
                .iter()
                .cloned()
                .collect::<std::collections::BTreeSet<_>>();
            if self.paths.len() == 1 {
                chooser
                    .set_file(&gtk::gio::File::for_path(&self.paths[0]))
                    .unwrap();
            } else {
                assert!(fs::read_dir(&self.directory).unwrap().count() == self.paths.len());
                chooser
                    .set_current_folder(Some(&gtk::gio::File::for_path(&self.directory)))
                    .unwrap();
                until(
                    "multiple chooser did not enter the owned two-file directory",
                    || {
                        chooser.current_folder().and_then(|f| f.path()).as_ref()
                            == Some(&self.directory)
                    },
                );
            }
            until(
                "native multiple chooser did not select exactly the public sources",
                || {
                    if self.paths.len() > 1 {
                        select_all_visible(&chooser);
                    }
                    selected_paths(&chooser) == expected
                },
            );
            files::respond(&chooser, gtk::ResponseType::Accept);
        }
        until("native multiple-vault credentials did not map", || {
            window
                .restoration_dialog
                .borrow()
                .as_ref()
                .is_some_and(|(d, e)| d.is_mapped() && e[0].is_mapped())
        });
        let (dialog, entries) = window.restoration_dialog.borrow().clone().unwrap();
        assert!(dialog.heading().as_deref() == Some("Unlock the Saved Vaults"));
        assert!(
            entries.len() == self.paths.len() + 2
                && entries
                    .iter()
                    .all(|e| e.text().is_empty() && !e.shows_peek_icon())
        );
        assert!(
            dialog.default_response().as_deref() == Some("back")
                && dialog.close_response() == "back"
                && !dialog.is_response_enabled("unlock")
        );
        let retained = toggles(
            &dialog,
            "Also unlock the vault retained in recovery history",
        );
        assert!(retained.len() == 1 && !retained[0].is_active() && retained[0].is_sensitive());
        retained[0].set_active(self.retained());
        assert!(window.restoration_file_choice.borrow().is_none() && window.window.is_active());
        (dialog, entries)
    }
    fn fill(&self, dialog: &adw::AlertDialog, entries: &[gtk::PasswordEntry], recovery: bool) {
        let modes = toggles(dialog, "Use recovery key");
        assert!(modes.len() == entries.len());
        let current_recovery = crypto::format_recovery(&[0x99; 16]);
        let additional_recovery = crypto::format_recovery(&[0xC3; 16]);
        modes[0].set_active(recovery);
        entries[0].set_text(if recovery {
            &current_recovery
        } else {
            "Café public current vault fixture"
        });
        let old = crypto::format_recovery(&[0x66; 16]);
        if self.retained() {
            modes[1].set_active(true);
            entries[1].set_text(&old);
        } else {
            modes[2].set_active(true);
            entries[2].set_text(&old);
        }
        let index = entries.len() - 1;
        let source_recovery = !recovery && !matches!(self.mode, Mode::FilesBackup);
        assert!(modes[index].is_visible() != matches!(self.mode, Mode::FilesBackup));
        modes[index].set_active(source_recovery);
        entries[index].set_text(if source_recovery {
            &additional_recovery
        } else {
            self.source_password()
        });
    }
    fn reviewed(&self, window: &Rc<AccountWindow>, recovery: bool) -> adw::AlertDialog {
        let (dialog, entries) = self.credentials(window);
        self.fill(&dialog, &entries, recovery);
        press(dialog.upcast_ref(), "Verify All Saved Changes");
        until_for(
            "native mixed-vault whole review did not map",
            Duration::from_secs(60),
            || {
                window
                    .snapshot_dialog
                    .borrow()
                    .as_ref()
                    .is_some_and(|d| d.is_mapped())
            },
        );
        let review = window.snapshot_dialog.borrow().clone().unwrap();
        assert!(
            entries.iter().all(|e| e.text().is_empty())
                && window.restoration_dialog.borrow().is_none()
        );
        assert!(review.heading().as_deref() == Some("Restore the Saved Changes?"));
        assert!(
            review
                .body()
                .contains("3 saved records · 3 preserved current versions · 2 secure records")
        );
        assert!(
            review
                .body()
                .contains("Saved secure changes will use the current vault's encryption.")
        );
        assert!(
            review.default_response().as_deref() == Some("back")
                && review.close_response() == "back"
        );
        review
    }
    fn password(
        &self,
        window: &Rc<AccountWindow>,
        recovery: bool,
    ) -> (adw::AlertDialog, gtk::PasswordEntry) {
        let review = self.reviewed(window, recovery);
        press(review.upcast_ref(), "Restore Changes");
        until("native mixed-vault purpose-bound PAM did not map", || {
            window
                .password_dialog
                .borrow()
                .as_ref()
                .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
        });
        let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
        assert!(
            dialog.heading().as_deref() == Some("Authorize Saved Changes Restoration")
                && dialog.default_response().as_deref() == Some("cancel")
                && dialog.close_response() == "cancel"
                && !entry.shows_peek_icon()
        );
        (dialog, entry)
    }
    pub(super) fn run(&self, context: Context<'_>) {
        let Context {
            native,
            archived,
            source_wire,
            initial,
        } = context;
        let RestorationContext {
            window,
            app,
            parent,
            root,
            fixture,
            pam,
            ordinary,
        } = native;
        let key = RootKey::from_bytes(&[0x44; 32]).unwrap();
        let ids = [archived.metadata.id, self.archived.metadata.id];
        let (checkpoint, catalog) = switching::checkpoint_and_history(root);
        assert!(catalog.switches.len() == 3 && catalog.restorations.is_empty());
        assert!(
            ids.iter()
                .all(|id| checkpoint.journal.confirmed(*id).is_some())
                && checkpoint.journal.inbox.cursor().is_some()
        );
        assert!(
            fixture
                .state
                .lock()
                .unwrap()
                .record_in(uuid::Uuid::from_u128(200), ids[1])
                .is_none()
        );
        let mut edited = document(root);
        for (index, id) in ids.iter().enumerate() {
            vault::edit(
                &mut edited,
                *id,
                if index == 0 { LATER } else { CURRENT_C },
                &key,
            );
            let metadata = &mut edited
                .records
                .iter_mut()
                .find(|r| r.metadata.id == *id)
                .unwrap()
                .metadata;
            metadata.name = format!("Public current mixed secure {index}");
            metadata.keyword = format!("public-current-mixed-{index}");
            metadata.tags = vec![format!("public-current-mixed-tag-{index}")];
            metadata.is_pinned = true;
        }
        let mut extra = archived.clone();
        extra.metadata = crate::vault::Metadata::new();
        extra.metadata.name = "Public unrelated mixed secure record".into();
        extra.sealed = crypto::seal_record(
            EXTRA_BODY,
            &key,
            &edited.salt().unwrap(),
            &edited.kid,
            extra.metadata.id,
            false,
        )
        .unwrap();
        extra.content_hash = crypto::content_hash(EXTRA_BODY, &key, &edited.salt().unwrap());
        extra.hlc = Some(
            crate::clock::stamp(
                root,
                None,
                extra.metadata.updated_at.timestamp_millis().max(0) as u64,
            )
            .unwrap(),
        );
        let extra_id = extra.metadata.id;
        edited.records.push(extra);
        write(root, &Document::decode(&edited.encode().unwrap()).unwrap());
        let extra = document(root)
            .records
            .into_iter()
            .find(|r| r.metadata.id == extra_id)
            .unwrap();
        let mut library = model::Library::open(root.into()).unwrap();
        let ordinary_current = library
            .snippets
            .iter()
            .find(|s| s.id == ordinary.id)
            .unwrap()
            .clone();
        let mut changed = ordinary_current.clone();
        changed.content = "Public current ordinary restoration body".into();
        changed.name = "Public current mixed ordinary title".into();
        changed.keyword = "public-current-mixed-ordinary".into();
        changed.tags = vec!["public-current-mixed-ordinary-tag".into()];
        changed.is_pinned = true;
        library.save(changed, Some(&ordinary_current)).unwrap();
        let ordinary_current = library
            .snippets
            .iter()
            .find(|s| s.id == ordinary.id)
            .unwrap()
            .clone();
        let ordinary_extra = model::Snippet::new(
            "Public unrelated mixed ordinary",
            "Public unrelated mixed ordinary retained body",
        );
        library.save(ordinary_extra.clone(), None).unwrap();
        let ordinary_extra = library
            .snippets
            .into_iter()
            .find(|s| s.id == ordinary_extra.id)
            .unwrap();
        let before = creation::images(root);
        let protected = restoration_live::protected(root);
        let plane = || {
            let s = fixture.state.lock().unwrap();
            (s.fetches, s.batches, s.accepted)
        };
        let counts = plane();
        let unchanged = || {
            assert!(
                creation::images(root) == before
                    && restoration_live::protected(root) == protected
                    && slot(root, Slot::HistoryRestore).is_none()
                    && plane() == counts
            );
            for id in ids {
                vault::no_session_key(root, id);
            }
        };
        // The existing single-source path must not restore its ordinary/A half
        // when the independently sealed C participant is not authenticated.
        let (dialog, entries) = credentials(window, true, None);
        entries[0].set_text("Café public current vault fixture");
        entries[1].set_text("Café public fixture");
        press(dialog.upcast_ref(), "Verify Saved Changes");
        finished(window, &entries);
        unchanged();
        println!(
            "Native mixed archive required both actual source scopes; retained A alone refused the whole ordinary/A/C selection before receipt or writes."
        );
        let (first, old) = credentials(window, true, None);
        old[0].set_text("Café public current vault fixture");
        old[1].set_text("Café public fixture");
        super::super::portal::expect(true, None);
        press(first.upcast_ref(), "Choose Several Vault Files…");
        if super::super::portal::enabled() {
            let portal = crate::portal_live_tests::chooser("Choose Previous Vault File");
            assert!(old.iter().all(|e| e.text().is_empty()));
            portal.key("", "Escape");
        } else {
            let chooser = files::chooser(window, true);
            assert!(old.iter().all(|e| e.text().is_empty()));
            files::respond(&chooser, gtk::ResponseType::Cancel);
        }
        finished(window, &old);
        unchanged();
        refocus(window);
        for fault in 0..3 {
            let (dialog, entries) = self.credentials(window);
            self.fill(&dialog, &entries, false);
            if fault == 0 {
                entries[0].set_text("Public incorrect current vault password");
            } else if fault == 1 {
                entries
                    .last()
                    .unwrap()
                    .set_text("Public incorrect additional vault password");
            } else {
                toggles(
                    &dialog,
                    "Also unlock the vault retained in recovery history",
                )[0]
                .set_active(false);
                if !self.retained() {
                    entries[2].set_text("Public incorrect source A recovery key");
                }
            }
            press(dialog.upcast_ref(), "Verify All Saved Changes");
            finished(window, &entries);
            unchanged();
        }
        if !self.retained() {
            let (dialog, entries) = self.credentials(window);
            self.fill(&dialog, &entries, false);
            toggles(
                &dialog,
                "Also unlock the vault retained in recovery history",
            )[0]
            .set_active(true);
            toggles(&dialog, "Use recovery key")[1].set_active(true);
            entries[1].set_text(&crypto::format_recovery(&[0x66; 16]));
            press(dialog.upcast_ref(), "Verify All Saved Changes");
            finished(window, &entries);
            unchanged();
        }
        let (dialog, entries) = self.credentials(window);
        self.fill(&dialog, &entries, true);
        press(dialog.upcast_ref(), "Cancel");
        finished(window, &entries);
        unchanged();
        let (dialog, entries) = self.credentials(window);
        self.fill(&dialog, &entries, false);
        parent.present();
        until("mixed-source credential focus loss did not cancel", || {
            parent.is_active() && !window.busy.get()
        });
        finished(window, &entries);
        unchanged();
        refocus(window);
        let review = self.reviewed(window, true);
        press(review.upcast_ref(), "Keep Current State");
        finished(window, &[]);
        unchanged();
        let _review = self.reviewed(window, false);
        parent.present();
        until("mixed-source review focus loss did not cancel", || {
            parent.is_active() && !window.busy.get()
        });
        finished(window, &[]);
        unchanged();
        refocus(window);
        for (value, response) in [
            ("Public fictional password", "Cancel"),
            ("Public incorrect password", "Authorize"),
        ] {
            let (dialog, entry) = self.password(window, false);
            entry.set_text(value);
            press(dialog.upcast_ref(), response);
            finished(window, std::slice::from_ref(&entry));
            unchanged();
        }
        let (_dialog, entry) = self.password(window, true);
        entry.set_text("Public fictional password");
        parent.present();
        until("mixed-source PAM focus loss did not cancel", || {
            parent.is_active() && !window.busy.get()
        });
        finished(window, std::slice::from_ref(&entry));
        unchanged();
        refocus(window);
        println!(
            "Native multiple-source Cancel, wrong/incomplete credentials and vault/review/PAM focus refusals cleared all fields and preserved the complete current selection, protected frames and data plane."
        );
        for index in 0..self.paths.len() {
            let current_images = creation::images(root);
            let caps = restoration_live::protected(root);
            let data_plane = plane();
            let (dialog, entry) = self.password(window, false);
            self.change(index);
            entry.set_text("Public fictional password");
            press(dialog.upcast_ref(), "Authorize");
            finished(window, std::slice::from_ref(&entry));
            assert!(
                creation::images(root) == current_images
                    && restoration_live::protected(root) == caps
                    && plane() == data_plane
                    && slot(root, Slot::HistoryRestore).is_none()
            );
            self.restore(index);
            assert!(!window.sync.is_sensitive());
            reconnect(window, 2);
        }
        println!(
            "Every selected source file was individually changed after whole review; each refused before receipt or primary writes even with entered fresh PAM."
        );
        let (dialog, entry) = self.password(window, false);
        let mut newer = document(root);
        vault::edit(&mut newer, ids[0], NEWER, &key);
        vault::edit(&mut newer, ids[1], NEWER_C, &key);
        write(root, &Document::decode(&newer.encode().unwrap()).unwrap());
        let currents = ids.map(|id| {
            document(root)
                .records
                .into_iter()
                .find(|r| r.metadata.id == id)
                .unwrap()
        });
        let stale = creation::images(root);
        let caps = restoration_live::protected(root);
        let data_plane = plane();
        entry.set_text("Public fictional password");
        press(dialog.upcast_ref(), "Authorize");
        finished(window, std::slice::from_ref(&entry));
        assert!(
            creation::images(root) == stale
                && restoration_live::protected(root) == caps
                && plane() == data_plane
                && slot(root, Slot::HistoryRestore).is_none()
        );
        reconnect(window, 2);
        let (dialog, entry) = self.password(window, true);
        entry.set_text("Public fictional password");
        press(dialog.upcast_ref(), "Authorize");
        finished(window, std::slice::from_ref(&entry));
        assert!(
            window.status.label()
                == "Saved changes restored. Current versions and previous keys are kept. Reconnect and select a library before syncing."
                && !window.sync.is_sensitive()
                && !window.receive.is_sensitive()
                && !window.send.is_sensitive()
        );
        assert!(
            restoration_live::protected(root) == protected
                && slot(root, Slot::HistoryRestore).is_some()
        );
        let saved = [&archived, &self.archived];
        let source_fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        let bodies = [
            source_fixture["plaintext"].as_str().unwrap().as_bytes(),
            b"Public additional saved secure body".as_slice(),
        ];
        let copies = mixed_preserved(root, saved, &currents, &extra, &key, bodies);
        let ordinary_copy = ordinary_preserved(root, ordinary, &ordinary_current, &ordinary_extra);
        assert!(
            model::Library::open(root.into())
                .unwrap()
                .snippets
                .iter()
                .all(|s| s.id != uuid::Uuid::from_u128(9003))
        );
        let mut original_header = initial;
        original_header.records.clear();
        let mut header = document(root);
        header.records.clear();
        assert!(header == original_header);
        independent(root);
        let (restored, catalog) = switching::checkpoint_and_history(root);
        assert!(
            checkpoint
                .journal
                .preserves_transport_state(&restored.journal)
                && catalog.switches.len() == 3
                && catalog.restorations.len() == 1
        );
        let receipt = &catalog.restorations[0];
        assert!(
            receipt.phase == SwitchPhase::Completed
                && !receipt.needs_completion
                && receipt.summary.restored_records == 3
                && receipt.summary.preserved_versions == 3
                && receipt.summary.secure_records == 2
        );
        assert!(plane() == counts);
        let submitted = fixture.state.lock().unwrap().submitted.len();
        let completed = creation::images(root);
        until("mixed restoration worker did not drain", || {
            window.prepare_quit()
        });
        window.window.destroy();
        let reopened = make_window(app, parent, root, fixture, pam);
        let stop = Stop(reopened.clone());
        reconnect(&reopened, 2);
        assert!(
            creation::images(root) == completed && restoration_live::protected(root) == protected
        );
        assert!(
            mixed_preserved(root, saved, &currents, &extra, &key, bodies) == copies
                && ordinary_preserved(root, ordinary, &ordinary_current, &ordinary_extra)
                    == ordinary_copy
        );
        mixed_sync(&reopened, fixture);
        assert!(
            mixed_preserved(root, saved, &currents, &extra, &key, bodies) == copies
                && ordinary_preserved(root, ordinary, &ordinary_current, &ordinary_extra)
                    == ordinary_copy
        );
        let (wire_key, wire_salt) = wire_material(root);
        let doc = document(root);
        let s = fixture.state.lock().unwrap();
        for record in &doc.records {
            let decoded = s
                .record_in(uuid::Uuid::from_u128(201), record.metadata.id)
                .unwrap()
                .open(&wire_key, &wire_salt)
                .unwrap();
            assert!(
                decoded.secure
                    && !decoded.deleted
                    && decoded.fields.as_ref().unwrap().content.as_slice()
                        == record.sealed.text().as_bytes()
                    && decoded.extensions["vaultKID"].as_text().unwrap() == doc.kid
                    && decoded.extensions["vaultContentHash"].as_text().unwrap()
                        == record.content_hash
            );
        }
        let sent = s.submitted[submitted..]
            .iter()
            .flat_map(|b| b.iter().map(|(w, _)| w.id))
            .collect::<Vec<_>>();
        for (id, copy) in ids.iter().zip(&copies) {
            assert!(
                sent.iter().position(|i| i == &copy.metadata.id).unwrap()
                    < sent.iter().position(|i| i == id).unwrap()
            );
        }
        assert!(
            sent.iter().position(|i| i == &ordinary_copy.id).unwrap()
                < sent.iter().position(|i| i == &ordinary.id).unwrap()
        );
        for expected in [ordinary, &ordinary_copy, &ordinary_extra] {
            let decoded = s
                .record_in(uuid::Uuid::from_u128(201), expected.id)
                .unwrap()
                .open(&wire_key, &wire_salt)
                .unwrap();
            assert!(
                !decoded.secure
                    && !decoded.deleted
                    && decoded.fields.as_ref().unwrap().content.as_slice()
                        == expected.content.as_bytes()
            );
        }
        assert!(
            s.record_in(uuid::Uuid::from_u128(200), ids[0])
                .is_some_and(|w| w == source_wire)
                && s.record_in(uuid::Uuid::from_u128(200), ids[1]).is_none()
                && s.creation_counts() == (3, 2)
                && s.bootstrap_posts == 2
        );
        drop(s);
        let mut header = document(root);
        header.records.clear();
        assert!(header == original_header);
        independent(root);
        for id in ids {
            vault::no_session_key(root, id);
        }
        assert!(
            !root.join("automatic-sync.json").exists()
                && CloudClient::discover(fixture.server.clone()).is_err()
        );
        until("final mixed restoration worker did not drain", || {
            reopened.prepare_quit()
        });
        drop(stop);
        println!(
            "Native mixed-vault whole restoration passed: real third-switch archive, same KID/different source salts and keys, exact selected GTK files, independent credentials, source/primary binding, fresh PAM, both current versions, unrelated records, exact current wraps/CAS/feed, completed history and fresh-worker encrypted copy-before-source synchronization."
        );
    }
}

fn mixed_preserved(
    root: &Path,
    archived: [&Record; 2],
    currents: &[Record; 2],
    extra: &Record,
    key: &RootKey,
    bodies: [&[u8]; 2],
) -> [Record; 2] {
    let doc = document(root);
    assert!(
        doc.records.len() == 5
            && doc.records.iter().any(|r| r == extra)
            && doc
                .records
                .iter()
                .all(|r| r.metadata.id != uuid::Uuid::from_u128(SOURCE_ONLY_ID))
    );
    std::array::from_fn(|index| {
        let old = archived[index];
        let restored = doc
            .records
            .iter()
            .find(|r| r.metadata.id == old.metadata.id)
            .unwrap();
        assert!(
            restored.metadata.name == old.metadata.name
                && restored.metadata.keyword == old.metadata.keyword
                && restored.metadata.tags == old.metadata.tags
                && restored.sealed != old.sealed
                && vault::body(&doc, restored.metadata.id, key).as_slice() == bodies[index]
        );
        let expected = if index == 0 { NEWER } else { NEWER_C };
        let copy = doc
            .records
            .iter()
            .find(|r| {
                r.metadata.id != old.metadata.id
                    && vault::body(&doc, r.metadata.id, key).as_slice() == expected
            })
            .unwrap();
        assert!(
            !copy.metadata.is_enabled
                && !copy.metadata.is_pinned
                && copy.metadata.keyword.is_empty()
                && copy.metadata.name.contains(&currents[index].metadata.name)
                && copy.sealed != currents[index].sealed
        );
        assert!(
            copy.metadata
                .tags
                .iter()
                .any(|t| currents[index].metadata.tags.contains(t))
        );
        copy.clone()
    })
}
fn independent(root: &Path) {
    assert!(
        Process::new("python3")
            .arg(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/reference/restoration-multiple.py")
            )
            .arg("--verify")
            .arg(root.join("Vault/vault.json"))
            .status()
            .unwrap()
            .success()
    );
}
fn mixed_sync(window: &Rc<AccountWindow>, fixture: &server::Fixture) {
    let (dialog, entry) = vault::vault_dialog(window);
    entry.set_text("Café public current vault fixture");
    press(dialog.upcast_ref(), "Verify and Sync");
    let start = Instant::now();
    let next = Cell::new(Duration::from_secs(15));
    until_for(
        "native mixed restoration sync did not finish",
        Duration::from_secs(150),
        || {
            if start.elapsed() >= next.get() {
                let state = fixture.state.lock().unwrap();
                println!(
                    "Native mixed sync progress: elapsed_seconds={}, requests={}, fetches={}, batches={}, accepted={}, busy={}",
                    start.elapsed().as_secs(),
                    state.requests,
                    state.fetches,
                    state.batches,
                    state.accepted,
                    window.busy.get()
                );
                next.set(next.get() + Duration::from_secs(15));
            }
            !window.busy.get()
        },
    );
    assert!(entry.text().is_empty() && window.vault_sync_dialog.borrow().is_none());
    assert!(window.vault_sync_authorization.borrow().is_none() && window.status.label() == CURRENT);
}

#[test]
#[ignore = "explicit native mixed retained/JSON sources; invoke tests/account-live.sh --mixed-retained-restoration"]
fn live_mixed_retained_json_vault_history_restoration() {
    creation::run(creation::Followup::MixedRestoration(Mode::RetainedJson));
}
#[test]
#[ignore = "explicit native two-file JSON chooser; invoke tests/account-live.sh --mixed-files-restoration"]
fn live_mixed_json_files_vault_history_restoration() {
    creation::run(creation::Followup::MixedRestoration(Mode::FilesJson));
}
#[test]
#[ignore = "explicit native JSON/independent-backup chooser; invoke tests/account-live.sh --mixed-backup-restoration"]
fn live_mixed_json_backup_vault_history_restoration() {
    creation::run(creation::Followup::MixedRestoration(Mode::FilesBackup));
}
