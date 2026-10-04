//! Import keeps authenticated plaintext and keys in one worker while GTK
//! receives a bounded summary and returns a one-use confirmation.
use super::*;
use crate::backup::import::Review;

struct Summary {
    counts: (usize, usize),
    needs_vault: bool,
    has_passphrase: bool,
    needs_new_passphrase: bool,
}
enum Reply {
    Review(Summary),
    Finished(Result<(usize, usize)>),
}
struct Apply {
    credential: Option<(Zeroizing<String>, bool)>,
    new_passphrase: Option<Zeroizing<String>>,
}
fn begin(
    root: PathBuf,
    path: PathBuf,
    password: Zeroizing<String>,
    authorization: Authorization,
) -> Result<(mpsc::Receiver<Reply>, mpsc::Sender<Apply>)> {
    let (send, receive) = mpsc::sync_channel(1);
    let (choose, choices) = mpsc::channel::<Apply>();
    std::thread::Builder::new()
        .name("snippets-backup-import".into())
        .spawn(move || {
            let result = (|| {
                authorization.validate()?;
                let data = crate::model::read_regular(&path)?
                    .ok_or(Error("The backup file is unavailable."))?;
                let opened = crate::backup::open(&data, &password)?;
                authorization.validate()?;
                let library = Library::open(root)?;
                let review = Review::prepare(&library, opened)?;
                authorization.validate()?;
                send.send(Reply::Review(Summary {
                    counts: review.counts(),
                    needs_vault: review.needs_vault(),
                    has_passphrase: review.has_passphrase(),
                    needs_new_passphrase: review.needs_new_passphrase(),
                }))
                .map_err(|_| Error("Backup import was cancelled."))?;
                let apply = loop {
                    authorization.validate()?;
                    match choices.recv_timeout(Duration::from_millis(50)) {
                        Ok(value) => break value,
                        Err(mpsc::RecvTimeoutError::Timeout) => (),
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            return Err(Error("Backup import was cancelled."));
                        }
                    }
                };
                review.commit(
                    &library,
                    &password,
                    apply
                        .credential
                        .as_ref()
                        .map(|(text, recovery)| (text.as_str(), *recovery)),
                    apply.new_passphrase.as_deref().map(|text| text.as_str()),
                    &|| authorization.validate(),
                )
            })();
            // The review and its recovered root key have already been dropped.
            drop(password);
            let _ = send.send(Reply::Finished(result));
        })
        .map_err(|_| Error("The backup import worker could not start."))?;
    Ok((receive, choose))
}
async fn reply(receive: &mpsc::Receiver<Reply>) -> Result<Reply> {
    loop {
        match receive.try_recv() {
            Ok(value) => return Ok(value),
            Err(mpsc::TryRecvError::Disconnected) => {
                return Err(Error("The backup import worker stopped."));
            }
            Err(mpsc::TryRecvError::Empty) => glib::timeout_future(Duration::from_millis(30)).await,
        }
    }
}
impl Export {
    pub fn start_import(
        self: &Rc<Self>,
        recovery: bool,
        notify: impl Fn(Result<Option<(usize, usize)>>) + 'static,
    ) {
        if self.busy.replace(true) {
            return;
        }
        let this = self.clone();
        let generation = this.generation.get();
        glib::spawn_future_local(async move {
            let result = this.run_import(generation, recovery).await;
            this.secret_worker.set(false);
            this.busy.set(false);
            this.cancel();
            if let Some(result) = result {
                notify(result);
            }
        });
    }
    async fn run_import(
        &self,
        generation: u64,
        recovery: bool,
    ) -> Option<Result<Option<(usize, usize)>>> {
        let path = if recovery {
            None
        } else {
            let filter = gtk::FileFilter::new();
            filter.set_name(Some("Snippets encrypted backups"));
            filter.add_pattern("*.snippetsbackup");
            let dialog = gtk::FileDialog::builder()
                .title("Restore Encrypted Backup")
                .default_filter(&filter)
                .build();
            let cancellation = gio::Cancellable::new();
            *self.file.borrow_mut() = Some(cancellation.clone());
            let (send, receive) = mpsc::sync_channel(1);
            dialog.open(Some(&self.parent), Some(&cancellation), move |result| {
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
            let Some(path) = file.path() else {
                return Some(Err(Error("Choose a local encrypted backup file.")));
            };
            #[cfg(test)]
            super::live_tests::assert_selection(&path);
            if !self.file_dialog_returned(generation).await {
                return None;
            }
            Some(path)
        };
        if generation != self.generation.get() || !self.parent.is_active() {
            return None;
        }
        let Some(monitor) = &self.monitor else {
            return Some(Err(Error(
                "An observable, unlocked desktop is required to restore this backup.",
            )));
        };
        let authorization = match Authorization::new(monitor.witness()) {
            Ok(value) => value,
            Err(error) => return Some(Err(error)),
        };
        *self.authorization.borrow_mut() = Some(authorization.clone());
        let password = self
            .restore_password(generation, &authorization, recovery)
            .await?;
        self.secret_worker.set(true);
        if recovery {
            let root = self.root.clone();
            return Some(
                worker(move || {
                    let library = Library::prepare(root)?;
                    crate::backup::import::recover(&library, &password, &|| {
                        authorization.validate()
                    })?;
                    Ok(None)
                })
                .await,
            );
        }
        let (receive, choose) =
            match begin(self.root.clone(), path?, password, authorization.clone()) {
                Ok(value) => value,
                Err(error) => return Some(Err(error)),
            };
        let first = match reply(&receive).await {
            Ok(value) => value,
            Err(error) => return Some(Err(error)),
        };
        let summary = match first {
            Reply::Review(value) => value,
            Reply::Finished(result) => return Some(result.map(Some)),
        };
        if let Some(apply) = self
            .restore_confirmation(&summary, generation, &authorization)
            .await
        {
            let _ = choose.send(apply);
        } else {
            // Cancel is a normal UI outcome. Revoke this generation too, so
            // the worker's cancellation reply cannot become an error toast.
            // Keep waiting below until it has released the recovered key.
            self.cancel();
        }
        drop(choose);
        // Keep the quit barrier until the worker has relinquished all secrets.
        match reply(&receive).await {
            Ok(Reply::Finished(result)) if generation == self.generation.get() => {
                Some(result.map(Some))
            }
            Ok(Reply::Finished(_)) => None,
            Ok(Reply::Review(_)) => Some(Err(Error(
                "The backup import worker returned an invalid response.",
            ))),
            Err(error) => Some(Err(error)),
        }
    }
    async fn restore_password(
        &self,
        generation: u64,
        authorization: &Authorization,
        recovery: bool,
    ) -> Option<Zeroizing<String>> {
        let dialog = adw::AlertDialog::builder()
            .heading(if recovery { "Resume Interrupted Backup Import" } else { "Open Encrypted Backup" })
            .body(if recovery {
                "Enter the password of the backup used for this interrupted import. This completes the previously confirmed changes to both library files. Entries stay hidden until recovery finishes."
            } else {
                "Enter the password used when this backup was created. The complete file is authenticated before you review and confirm the import."
            }).build();
        let password = gtk::PasswordEntry::builder()
            .placeholder_text("Backup password")
            .show_peek_icon(false)
            .build();
        dialog.set_extra_child(Some(&password));
        dialog.add_responses(&[
            ("cancel", "Cancel"),
            (
                "open",
                if recovery {
                    "Resume Import"
                } else {
                    "Open Backup"
                },
            ),
        ]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        dialog.set_response_enabled("open", false);
        let weak = dialog.downgrade();
        password.connect_changed(move |entry| {
            if let Some(dialog) = weak.upgrade() {
                dialog.set_response_enabled(
                    "open",
                    !entry.text().is_empty() && entry.text().len() <= 4096,
                );
            }
        });
        *self.passwords.borrow_mut() = Some((dialog.clone(), vec![password.clone()]));
        let response = dialog.choose_future(Some(&self.parent)).await;
        self.passwords.borrow_mut().take();
        let secret = Zeroizing::new(password.text().to_string());
        password.set_text("");
        if response != "open"
            || secret.is_empty()
            || secret.len() > 4096
            || generation != self.generation.get()
            || !self.parent.is_active()
            || authorization.validate().is_err()
        {
            return None;
        }
        Some(secret)
    }
    async fn restore_confirmation(
        &self,
        summary: &Summary,
        generation: u64,
        authorization: &Authorization,
    ) -> Option<Apply> {
        if generation != self.generation.get()
            || !self.parent.is_active()
            || authorization.validate().is_err()
        {
            return None;
        }
        let (ordinary, secure) = summary.counts;
        let dialog = adw::AlertDialog::builder().heading("Restore This Backup?")
            .body(format!("The authenticated backup contains {ordinary} ordinary and {secure} secure snippets. Matching ordinary entries are replaced by ID or keyword; secure entries match by ID. Other entries and unsaved secure drafts are kept. Existing vault unlock methods are preserved. Changes to both saved library files are recovered together if interrupted.")).build();
        let fields = gtk::Box::new(gtk::Orientation::Vertical, 10);
        let credential = gtk::PasswordEntry::builder()
            .placeholder_text("Current vault passphrase or recovery key")
            .show_peek_icon(false)
            .build();
        let recovery = gtk::CheckButton::with_label("Use the vault recovery key");
        let new_passphrase = gtk::PasswordEntry::builder()
            .placeholder_text("New local vault passphrase (at least 12 characters)")
            .show_peek_icon(false)
            .build();
        let confirmation = gtk::PasswordEntry::builder()
            .placeholder_text("Confirm new vault passphrase")
            .show_peek_icon(false)
            .build();
        recovery.set_active(!summary.has_passphrase);
        if summary.needs_vault {
            fields.append(&gtk::Label::new(Some(
                "Authenticate the current vault to import secure snippets.",
            )));
            fields.append(&credential);
            fields.append(&recovery);
            dialog.set_extra_child(Some(&fields));
        }
        if summary.needs_new_passphrase {
            fields.append(&gtk::Label::new(Some(
                "Create a local passphrase for the restored vault. Its original recovery key remains valid.",
            )));
            fields.append(&new_passphrase);
            fields.append(&confirmation);
            dialog.set_extra_child(Some(&fields));
        }
        dialog.add_responses(&[("cancel", "Cancel"), ("restore", "Restore Backup")]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        dialog.set_response_appearance("restore", adw::ResponseAppearance::Destructive);
        let weak_dialog = dialog.downgrade();
        let weak_credential = credential.downgrade();
        let weak_passphrase = new_passphrase.downgrade();
        let weak_confirmation = confirmation.downgrade();
        let needs_vault = summary.needs_vault;
        let needs_new = summary.needs_new_passphrase;
        let update = Rc::new(move || {
            if let (Some(dialog), Some(credential), Some(passphrase), Some(confirmation)) = (
                weak_dialog.upgrade(),
                weak_credential.upgrade(),
                weak_passphrase.upgrade(),
                weak_confirmation.upgrade(),
            ) {
                let local = passphrase.text();
                dialog.set_response_enabled(
                    "restore",
                    (!needs_vault
                        || !credential.text().is_empty() && credential.text().len() <= 4096)
                        && (!needs_new
                            || local.chars().count() >= 12
                                && local.len() <= 4096
                                && local == confirmation.text()),
                );
            }
        });
        update();
        for entry in [&credential, &new_passphrase, &confirmation] {
            let update = update.clone();
            entry.connect_changed(move |_| update());
        }
        *self.passwords.borrow_mut() = Some((
            dialog.clone(),
            vec![
                credential.clone(),
                new_passphrase.clone(),
                confirmation.clone(),
            ],
        ));
        let response = dialog.choose_future(Some(&self.parent)).await;
        self.passwords.borrow_mut().take();
        let secret = Zeroizing::new(credential.text().to_string());
        let new_secret = Zeroizing::new(new_passphrase.text().to_string());
        let confirmed = Zeroizing::new(confirmation.text().to_string());
        credential.set_text("");
        new_passphrase.set_text("");
        confirmation.set_text("");
        if response != "restore"
            || generation != self.generation.get()
            || !self.parent.is_active()
            || authorization.validate().is_err()
        {
            return None;
        }
        if summary.needs_new_passphrase
            && (new_secret.chars().count() < 12
                || new_secret.len() > 4096
                || *new_secret != *confirmed)
        {
            authorization.cancel();
            return None;
        }
        Some(Apply {
            credential: summary
                .needs_vault
                .then_some((secret, recovery.is_active())),
            new_passphrase: summary.needs_new_passphrase.then_some(new_secret),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::SessionWitness;
    fn fixture(secure: bool) -> (tempfile::TempDir, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let opened = {
            let fixture: serde_json::Value =
                serde_json::from_str(include_str!("../tests/fixtures/backup-v1.json")).unwrap();
            let path = root.path().join("public.snippetsbackup");
            std::fs::write(&path, serde_json::to_vec(&fixture["container"]).unwrap()).unwrap();
            crate::backup::open(&std::fs::read(path).unwrap(), "Café public backup fixture")
                .unwrap()
        };
        let library_root = root.path().join("library");
        let library = Library::open(library_root.clone()).unwrap();
        if secure {
            std::fs::DirBuilder::new()
                .create(library_root.join("Vault"))
                .unwrap();
            crate::model::atomic_write(
                &library_root.join("Vault/vault.json"),
                &opened.vault.as_ref().unwrap().encode().unwrap(),
            )
            .unwrap();
        }
        drop(library);
        (root, library_root)
    }
    struct Observation {
        stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }
    impl Drop for Observation {
        fn drop(&mut self) {
            self.stop.store(true, std::sync::atomic::Ordering::Release);
            self.thread.take().unwrap().join().unwrap();
        }
    }
    fn authorization() -> (Authorization, Observation) {
        let witness = SessionWitness::test(SessionState::Unlocked, 1);
        let observed = witness.clone();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stopped = stop.clone();
        let thread = std::thread::spawn(move || {
            while !stopped.load(std::sync::atomic::Ordering::Acquire) {
                observed.test_observe(SessionState::Unlocked);
                std::thread::sleep(Duration::from_millis(50));
            }
        });
        (
            Authorization::new(witness).unwrap(),
            Observation {
                stop,
                thread: Some(thread),
            },
        )
    }
    #[test]
    fn worker_owns_the_key_until_confirmation_and_cancellation_releases_without_publication() {
        let (root, library_root) = fixture(false);
        let path = root.path().join("public.snippetsbackup");
        let (token, _observation) = authorization();
        let (receive, choose) = begin(
            library_root.clone(),
            path,
            Zeroizing::new("Café public backup fixture".into()),
            token.clone(),
        )
        .unwrap();
        let summary = match receive.recv_timeout(Duration::from_secs(15)).unwrap() {
            Reply::Review(value) => value,
            Reply::Finished(Err(error)) => panic!("worker refused review: {error}"),
            Reply::Finished(Ok(_)) => panic!("worker applied before review"),
        };
        assert_eq!(summary.counts, (1, 1));
        assert!(!summary.needs_vault);
        assert!(!library_root.join("snippets.json").exists());
        assert!(!library_root.join("Vault").exists());
        token.cancel();
        drop(choose);
        assert!(matches!(
            receive.recv_timeout(Duration::from_secs(15)).unwrap(),
            Reply::Finished(Err(_))
        ));
        assert!(!library_root.join("Backups").exists());
    }
    #[test]
    fn confirmation_worker_restores_both_files_and_requires_fresh_current_vault_auth() {
        for current_vault in [false, true] {
            let (root, library_root) = fixture(current_vault);
            let (token, _observation) = authorization();
            let (receive, choose) = begin(
                library_root.clone(),
                root.path().join("public.snippetsbackup"),
                Zeroizing::new("Café public backup fixture".into()),
                token,
            )
            .unwrap();
            let summary = match receive.recv_timeout(Duration::from_secs(15)).unwrap() {
                Reply::Review(value) => value,
                Reply::Finished(Err(error)) => panic!("worker refused review: {error}"),
                Reply::Finished(Ok(_)) => panic!("worker applied before review"),
            };
            assert_eq!(summary.needs_vault, current_vault);
            assert_eq!(summary.needs_new_passphrase, !current_vault);
            choose
                .send(Apply {
                    credential: current_vault
                        .then(|| (crate::crypto::format_recovery(&[0x66; 16]), true)),
                    new_passphrase: (!current_vault)
                        .then(|| Zeroizing::new("Public restored vault passphrase".into())),
                })
                .unwrap_or_else(|_| panic!("worker confirmation"));
            assert!(matches!(
                receive.recv_timeout(Duration::from_secs(15)).unwrap(),
                Reply::Finished(Ok((1, 1)))
            ));
            let library = Library::open(library_root).unwrap();
            assert_eq!(library.snippets.len(), 1);
            assert_eq!(
                crate::vault::read_document(&library.root)
                    .unwrap()
                    .unwrap()
                    .records
                    .len(),
                1
            );
            assert!(!library.root.join("Sync").exists());
        }
    }
    #[test]
    #[ignore = "requires a graphical display; public credentials and synthetic desktop witness, no keyring/PAM/network"]
    fn native_restore_passwords_clear_on_cancel_and_confirm() {
        adw::init().expect("graphical display");
        use super::super::tests::{respond, settle_until};
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.restore-fixture")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let parent = adw::ApplicationWindow::builder()
            .application(&application)
            .build();
        parent.present();
        settle_until(|| parent.is_active());
        let export = Rc::new(Export {
            parent: parent.clone(),
            root: PathBuf::new(),
            monitor: None,
            busy: Cell::new(false),
            secret_worker: Cell::new(false),
            generation: Cell::new(0),
            passwords: RefCell::new(None),
            file: RefCell::new(None),
            authorization: RefCell::new(None),
        });
        for recovery in [false, true] {
            for response in 0..3 {
                let (token, _observation) = authorization();
                *export.authorization.borrow_mut() = Some(token.clone());
                let generation = export.generation.get();
                let completed = Rc::new(RefCell::new(None));
                let result = completed.clone();
                let this = export.clone();
                glib::spawn_future_local(async move {
                    *result.borrow_mut() =
                        Some(this.restore_password(generation, &token, recovery).await);
                });
                settle_until(|| export.passwords.borrow().is_some());
                let (dialog, fields) = export.passwords.borrow().as_ref().unwrap().clone();
                fields[0].set_text("Public backup password");
                if response == 0 {
                    export.cancel();
                } else {
                    respond(
                        &dialog,
                        if response == 1 {
                            "Cancel"
                        } else if recovery {
                            "Resume Import"
                        } else {
                            "Open Backup"
                        },
                    );
                }
                settle_until(|| completed.borrow().is_some());
                assert!(fields.iter().all(|field| field.text().is_empty()));
                let result = completed.borrow_mut().take().unwrap();
                assert_eq!(result.is_some(), response == 2);
                if let Some(password) = result {
                    assert!(password.as_str() == "Public backup password");
                }
            }
        }
        for needs_new in [false, true] {
            for response in 0..3 {
                let (token, _observation) = authorization();
                *export.authorization.borrow_mut() = Some(token.clone());
                let generation = export.generation.get();
                let completed = Rc::new(RefCell::new(None));
                let result = completed.clone();
                let this = export.clone();
                glib::spawn_future_local(async move {
                    let summary = Summary {
                        counts: (1, 1),
                        needs_vault: !needs_new,
                        has_passphrase: true,
                        needs_new_passphrase: needs_new,
                    };
                    *result.borrow_mut() = Some(
                        this.restore_confirmation(&summary, generation, &token)
                            .await,
                    );
                });
                settle_until(|| export.passwords.borrow().is_some());
                let (dialog, fields) = export.passwords.borrow().as_ref().unwrap().clone();
                fields[0].set_text("Public vault credential");
                fields[1].set_text("Public new vault passphrase");
                fields[2].set_text("Public new vault passphrase");
                if response == 0 {
                    export.cancel();
                } else {
                    respond(
                        &dialog,
                        if response == 1 {
                            "Cancel"
                        } else {
                            "Restore Backup"
                        },
                    );
                }
                settle_until(|| completed.borrow().is_some());
                assert!(fields.iter().all(|field| field.text().is_empty()));
                let result = completed.borrow_mut().take().unwrap();
                assert_eq!(result.is_some(), response == 2);
                if let Some(apply) = result {
                    if needs_new {
                        assert!(apply.credential.is_none());
                        assert!(
                            apply.new_passphrase.unwrap().as_str() == "Public new vault passphrase"
                        );
                    } else {
                        let (credential, recovery) = apply.credential.unwrap();
                        assert!(credential.as_str() == "Public vault credential");
                        assert!(!recovery);
                        assert!(apply.new_passphrase.is_none());
                    }
                }
            }
        }
        export.cancel();
        parent.destroy();
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
    }
}
