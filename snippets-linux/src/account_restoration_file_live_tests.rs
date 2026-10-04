//! Real GTK fallback chooser, selected-file authority and public fixtures.
use super::*;

#[derive(Clone, Copy)]
pub(in crate::account_ui::live_tests) enum Kind {
    VaultJson,
    EncryptedBackup,
}
pub(super) struct Input {
    path: PathBuf,
    kind: Kind,
    bytes: Zeroizing<Vec<u8>>,
}
impl Input {
    pub(super) fn new(root: &Path, kind: Kind, source: &Document) -> Self {
        let (name, bytes) = match kind {
            Kind::VaultJson => ("public previous vault.json", source.encode().unwrap()),
            Kind::EncryptedBackup => {
                let fixture: serde_json::Value =
                    serde_json::from_str(include_str!("../tests/fixtures/backup-v1.json")).unwrap();
                (
                    "public previous vault.snippetsbackup",
                    serde_json::to_vec(&fixture["container"]).unwrap(),
                )
            }
        };
        let path = root.parent().unwrap().join(name);
        assert!(!path.exists());
        model::atomic_write(&path, &bytes).unwrap();
        Self {
            path,
            kind,
            bytes: Zeroizing::new(bytes),
        }
    }
    pub(super) fn backup(&self) -> bool {
        matches!(self.kind, Kind::EncryptedBackup)
    }
    pub(super) fn passphrase<'a>(&self, source: &'a str) -> &'a str {
        if self.backup() {
            "Café public backup fixture"
        } else {
            source
        }
    }
    pub(super) fn change(&self) {
        let mut changed = self.bytes.clone();
        changed.push(b' ');
        model::atomic_write(&self.path, &changed).unwrap();
    }
    pub(super) fn restore(&self) {
        model::atomic_write(&self.path, &self.bytes).unwrap();
    }
}
impl Drop for Input {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            assert!(fs::read(&self.path).unwrap().as_slice() == self.bytes.as_slice());
        }
        fs::remove_file(&self.path).unwrap();
    }
}

// FileDialog really falls back to GTK on this private bus. We operate its
// mapped widgets, never manufacture a callback result or a SourceFile ticket.
#[allow(deprecated)]
fn chooser(window: &AccountWindow) -> gtk::FileChooserDialog {
    let found = RefCell::new(None);
    until("native previous-vault file chooser did not map", || {
        let matching = gtk::Window::list_toplevels()
            .into_iter()
            .filter_map(|window| window.downcast::<gtk::FileChooserDialog>().ok())
            .filter(|dialog| {
                dialog.title().as_deref() == Some("Choose Previous Vault File")
                    && dialog.is_mapped()
            })
            .collect::<Vec<_>>();
        assert!(matching.len() <= 1);
        *found.borrow_mut() = matching.into_iter().next();
        found.borrow().as_ref().is_some_and(|d| d.is_active())
    });
    let dialog = found.into_inner().unwrap();
    assert!(dialog.transient_for().as_ref() == Some(window.window.upcast_ref()));
    assert!(dialog.action() == gtk::FileChooserAction::Open && !dialog.selects_multiple());
    assert!(window.restoration_file_choice.borrow().is_some());
    assert!(
        window.restoration_preparation.borrow().is_none()
            && window.password_dialog.borrow().is_none()
    );
    dialog
}
#[allow(deprecated)]
fn respond(chooser: &gtk::FileChooserDialog, response: gtk::ResponseType) {
    let button = chooser
        .widget_for_response(response)
        .unwrap()
        .downcast::<gtk::Button>()
        .unwrap();
    until(
        "native chooser response button did not become usable",
        || chooser.is_active() && button.is_mapped() && button.is_sensitive(),
    );
    button.emit_clicked();
}
#[allow(deprecated)]
pub(super) fn select(
    window: &Rc<AccountWindow>,
    dialog: &adw::AlertDialog,
    old_entries: &[gtk::PasswordEntry],
    input: &Input,
) -> (adw::AlertDialog, Vec<gtk::PasswordEntry>) {
    press(dialog.upcast_ref(), "Choose Previous Vault File…");
    let selected = chooser(window);
    assert!(old_entries.iter().all(|e| e.text().is_empty()));
    let file = gtk::gio::File::for_path(&input.path);
    selected.set_file(&file).unwrap();
    until(
        "native chooser did not select the owned public source",
        || selected.file().and_then(|file| file.path()).as_ref() == Some(&input.path),
    );
    respond(&selected, gtk::ResponseType::Accept);
    until("native selected-file credentials did not map", || {
        window
            .restoration_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e[0].is_mapped())
    });
    assert!(
        !selected.is_mapped()
            && window.restoration_file_choice.borrow().is_none()
            && window.window.is_active()
    );
    let (dialog, entries) = window.restoration_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Unlock the Vaults for Restoration"));
    assert!(
        dialog.default_response().as_deref() == Some("back")
            && dialog.close_response() == "back"
            && !dialog.is_response_enabled("unlock")
    );
    assert!(entries.len() == 2 && entries.iter().all(|e| e.text().is_empty()));
    assert!(toggles(&dialog, "Saved changes use a previous vault")[0].is_active());
    let modes = toggles(&dialog, "Use recovery key");
    assert!(modes.len() == 2 && modes[1].is_visible() != input.backup());
    (dialog, entries)
}
pub(super) fn cancel(window: &Rc<AccountWindow>, current: &str, source: &str) {
    let (dialog, entries) = credentials(window, true, None);
    entries[0].set_text(current);
    entries[1].set_text(source);
    press(dialog.upcast_ref(), "Choose Previous Vault File…");
    let selected = chooser(window);
    assert!(entries.iter().all(|e| e.text().is_empty()));
    respond(&selected, gtk::ResponseType::Cancel);
    finished(window, &entries);
    assert!(window.restoration_file_choice.borrow().is_none());
    refocus(window);
}
