//! Native encrypted-backup export. Passwords are cleared on every response,
//! focus/visibility/desktop cancellation, and before worker handoff.
use crate::{
    backup::export::{Authorization, Snapshot},
    desktop::{SessionMonitor, SessionState},
    model::{Error, Library, Result},
};
use adw::prelude::*;
use gtk::{gio, glib};
use std::{
    cell::{Cell, RefCell},
    path::PathBuf,
    rc::Rc,
    sync::mpsc,
    time::Duration,
};
use zeroize::Zeroizing;
#[path = "backup_import_ui.rs"]
mod importing;

async fn worker<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    let (send, receive) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("snippets-backup".into())
        .spawn(move || {
            let _ = send.send(operation());
        })
        .map_err(|_| Error("The backup worker could not start."))?;
    loop {
        match receive.try_recv() {
            Ok(result) => return result,
            Err(mpsc::TryRecvError::Disconnected) => {
                return Err(Error("The backup worker stopped."));
            }
            Err(mpsc::TryRecvError::Empty) => glib::timeout_future(Duration::from_millis(30)).await,
        }
    }
}
pub struct Export {
    parent: adw::ApplicationWindow,
    root: PathBuf,
    monitor: Option<SessionMonitor>,
    busy: Cell<bool>,
    secret_worker: Cell<bool>,
    generation: Cell<u64>,
    passwords: RefCell<Option<(adw::AlertDialog, Vec<gtk::PasswordEntry>)>>,
    file: RefCell<Option<gio::Cancellable>>,
    authorization: RefCell<Option<Authorization>>,
}
struct Credentials {
    password: Zeroizing<String>,
    vault: Option<(Zeroizing<String>, bool)>,
}
impl Export {
    pub fn new(parent: &adw::ApplicationWindow, library: &Library) -> Rc<Self> {
        let this = Rc::new(Self {
            parent: parent.clone(),
            root: library.root.clone(),
            monitor: SessionMonitor::new(),
            busy: Cell::new(false),
            secret_worker: Cell::new(false),
            generation: Cell::new(0),
            passwords: RefCell::new(None),
            file: RefCell::new(None),
            authorization: RefCell::new(None),
        });
        let weak = Rc::downgrade(&this);
        parent.connect_is_active_notify(move |window| {
            if let Some(this) = weak.upgrade() {
                let sensitive =
                    this.passwords.borrow().is_some() || this.authorization.borrow().is_some();
                if !window.is_active() && sensitive {
                    this.cancel();
                }
            }
        });
        let weak = Rc::downgrade(&this);
        parent.connect_visible_notify(move |window| {
            if let Some(this) = weak.upgrade()
                && !window.is_visible()
            {
                this.cancel();
            }
        });
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let expired = this
                .authorization
                .borrow()
                .as_ref()
                .is_some_and(|a| a.validate().is_err());
            if expired {
                this.cancel();
            }
            glib::ControlFlow::Continue
        });
        this
    }
    fn cancel(&self) {
        self.generation.set(self.generation.get().wrapping_add(1));
        if let Some(authorization) = self.authorization.borrow_mut().take() {
            authorization.cancel();
        }
        let passwords = self.passwords.borrow_mut().take();
        if let Some((dialog, passwords)) = passwords {
            for entry in passwords {
                entry.set_text("");
            }
            dialog.force_close();
        }
        if let Some(file) = self.file.borrow_mut().take() {
            file.cancel();
        }
    }
    pub fn prepare_quit(&self) -> bool {
        self.cancel();
        !self.secret_worker.get()
    }
    pub fn start(self: &Rc<Self>, notify: impl Fn(Result<(usize, usize)>) + 'static) {
        if self.busy.replace(true) {
            return;
        }
        let this = self.clone();
        let generation = this.generation.get();
        glib::spawn_future_local(async move {
            let result = this.run(generation).await;
            this.secret_worker.set(false);
            this.busy.set(false);
            this.cancel();
            if let Some(result) = result {
                notify(result);
            }
        });
    }
    async fn run(&self, generation: u64) -> Option<Result<(usize, usize)>> {
        let dialog = gtk::FileDialog::builder()
            .title("Export Encrypted Backup")
            .initial_name("snippets.snippetsbackup")
            .build();
        let cancellation = gio::Cancellable::new();
        *self.file.borrow_mut() = Some(cancellation.clone());
        let (send, receive) = mpsc::sync_channel(1);
        dialog.save(Some(&self.parent), Some(&cancellation), move |result| {
            let _ = send.send(result);
        });
        let file = loop {
            match receive.try_recv() {
                Ok(Ok(file)) => break file,
                Ok(Err(_)) | Err(mpsc::TryRecvError::Disconnected) => {
                    self.file.borrow_mut().take();
                    return None;
                }
                Err(mpsc::TryRecvError::Empty) => {
                    glib::timeout_future(Duration::from_millis(30)).await
                }
            }
        };
        self.file.borrow_mut().take();
        if generation != self.generation.get() || !self.parent.is_active() {
            return None;
        }
        let Some(destination) = file.path() else {
            return Some(Err(Error("Choose a local backup destination.")));
        };
        let root = self.root.clone();
        let (library, snapshot) = match worker(move || {
            let library = Library::open(root)?;
            let snapshot = Snapshot::read(&library)?;
            Ok((library, snapshot))
        })
        .await
        {
            Ok(value) => value,
            Err(error) => return Some(Err(error)),
        };
        if generation != self.generation.get() || !self.parent.is_active() {
            return None;
        }
        let Some(monitor) = &self.monitor else {
            return Some(Err(Error(
                "An observable, unlocked desktop is required to export this backup.",
            )));
        };
        if monitor.snapshot().0 != SessionState::Unlocked {
            return Some(Err(Error(
                "Unlock the desktop before exporting this backup.",
            )));
        }
        let authorization = match Authorization::new(monitor.witness()) {
            Ok(value) => value,
            Err(error) => return Some(Err(error)),
        };
        *self.authorization.borrow_mut() = Some(authorization.clone());
        let credentials = match self
            .request_passwords(&snapshot, generation, &authorization)
            .await
        {
            Some(Ok(value)) => value,
            Some(Err(error)) => return Some(Err(error)),
            None => return None,
        };
        self.secret_worker.set(true);
        let result = worker(move || {
            snapshot.write_backup(
                &library,
                &destination,
                &credentials.password,
                credentials
                    .vault
                    .as_ref()
                    .map(|(text, recovery)| (text.as_str(), *recovery)),
                &|| authorization.validate(),
            )
        })
        .await;
        self.secret_worker.set(false);
        Some(result)
    }
    async fn request_passwords(
        &self,
        snapshot: &Snapshot,
        generation: u64,
        authorization: &Authorization,
    ) -> Option<Result<Credentials>> {
        let (ordinary, secure) = snapshot.counts();
        let dialog = adw::AlertDialog::builder().heading("Protect Your Encrypted Backup")
            .body(format!("This backup includes {ordinary} saved ordinary and {secure} saved secure snippets. Its password protects the complete file, including names, keywords and tags. Keep the password separately; unsaved drafts and account or sync credentials are not included.")).build();
        let fields = gtk::Box::new(gtk::Orientation::Vertical, 10);
        let password = gtk::PasswordEntry::builder()
            .placeholder_text("Backup password (at least 12 characters)")
            .show_peek_icon(false)
            .build();
        let confirmation = gtk::PasswordEntry::builder()
            .placeholder_text("Confirm backup password")
            .show_peek_icon(false)
            .build();
        fields.append(&password);
        fields.append(&confirmation);
        let credential = gtk::PasswordEntry::builder()
            .placeholder_text("Current vault passphrase or recovery key")
            .show_peek_icon(false)
            .build();
        let recovery = gtk::CheckButton::with_label("Use the vault recovery key");
        recovery.set_active(!snapshot.has_passphrase());
        if snapshot.needs_vault() {
            fields.append(&gtk::Label::new(Some(
                "Authenticate the current vault to include secure snippets.",
            )));
            fields.append(&credential);
            fields.append(&recovery);
        }
        dialog.set_extra_child(Some(&fields));
        dialog.add_responses(&[("cancel", "Cancel"), ("export", "Export Encrypted Backup")]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        *self.passwords.borrow_mut() = Some((
            dialog.clone(),
            vec![password.clone(), confirmation.clone(), credential.clone()],
        ));
        let response = dialog.choose_future(Some(&self.parent)).await;
        self.passwords.borrow_mut().take();
        let secret = Zeroizing::new(password.text().to_string());
        let confirmed = Zeroizing::new(confirmation.text().to_string());
        let vault_secret = Zeroizing::new(credential.text().to_string());
        password.set_text("");
        confirmation.set_text("");
        credential.set_text("");
        if response != "export"
            || generation != self.generation.get()
            || !self.parent.is_active()
            || authorization.validate().is_err()
        {
            return None;
        }
        if secret.chars().count() < 12 || secret.len() > 4096 {
            return Some(Err(Error(
                "Choose a backup password of at least 12 characters and no more than 4 KiB.",
            )));
        }
        if *secret != *confirmed {
            return Some(Err(Error("The backup passwords do not match.")));
        }
        drop(confirmed);
        let using_recovery = recovery.is_active();
        Some(Ok(Credentials {
            password: secret,
            vault: snapshot
                .needs_vault()
                .then_some((vault_secret, using_recovery)),
        }))
    }
}
impl Drop for Export {
    fn drop(&mut self) {
        self.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::SessionWitness;
    pub(super) fn settle_until(predicate: impl Fn() -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !predicate() {
            assert!(
                std::time::Instant::now() < deadline,
                "native backup fixture timed out"
            );
            while glib::MainContext::default().pending() {
                glib::MainContext::default().iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    pub(super) fn respond(dialog: &adw::AlertDialog, label: &str) {
        let mut pending = vec![dialog.clone().upcast::<gtk::Widget>()];
        while let Some(widget) = pending.pop() {
            if let Ok(button) = widget.clone().downcast::<gtk::Button>()
                && button.label().as_deref() == Some(label)
            {
                button.emit_clicked();
                return;
            }
            let mut child = widget.first_child();
            while let Some(widget) = child {
                child = widget.next_sibling();
                pending.push(widget);
            }
        }
        panic!("native backup response is unavailable");
    }
    #[test]
    #[ignore = "requires a graphical display; public isolated library and synthetic desktop witness, no keyring/PAM/network"]
    fn native_backup_password_fields_clear_on_cancel_and_confirm() {
        adw::init().expect("graphical display");
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.backup-fixture")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let parent = adw::ApplicationWindow::builder()
            .application(&application)
            .build();
        parent.present();
        settle_until(|| parent.is_active());
        let root = tempfile::tempdir().unwrap();
        let library = Library::open(root.path().into()).unwrap();
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        std::fs::create_dir(root.path().join("Vault")).unwrap();
        crate::model::atomic_write(
            &root.path().join("Vault/vault.json"),
            &serde_json::to_vec(&fixture["document"]).unwrap(),
        )
        .unwrap();
        let export = Rc::new(Export {
            parent: parent.clone(),
            root: library.root.clone(),
            monitor: None,
            busy: Cell::new(false),
            secret_worker: Cell::new(false),
            generation: Cell::new(0),
            passwords: RefCell::new(None),
            file: RefCell::new(None),
            authorization: RefCell::new(None),
        });
        for response in 0..3 {
            let snapshot = Snapshot::read(&library).unwrap();
            let authorization =
                Authorization::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap();
            *export.authorization.borrow_mut() = Some(authorization.clone());
            let generation = export.generation.get();
            let completed = Rc::new(RefCell::new(None));
            let result = completed.clone();
            let this = export.clone();
            glib::spawn_future_local(async move {
                *result.borrow_mut() = Some(
                    this.request_passwords(&snapshot, generation, &authorization)
                        .await,
                );
            });
            settle_until(|| export.passwords.borrow().is_some());
            let (dialog, fields) = export.passwords.borrow().as_ref().unwrap().clone();
            fields[0].set_text("Public backup password");
            fields[1].set_text("Public backup password");
            fields[2].set_text("Public vault credential");
            if response == 0 {
                export.cancel();
            } else if response == 1 {
                respond(&dialog, "Cancel");
            } else {
                respond(&dialog, "Export Encrypted Backup");
            }
            settle_until(|| completed.borrow().is_some());
            assert!(fields.iter().all(|field| field.text().is_empty()));
            let result = completed.borrow_mut().take().unwrap();
            if response != 2 {
                assert!(result.is_none());
            } else {
                let credentials = result.unwrap().unwrap();
                assert!(credentials.password.as_str() == "Public backup password");
                assert!(credentials.vault.unwrap().0.as_str() == "Public vault credential");
            }
        }
        export.cancel();
        parent.destroy();
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
    }
}
