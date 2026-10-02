//! Separate old/current vault credentials; fresh local authorization follows
//! ciphertext preparation. Neither vault authentication authorizes a write.
use super::*;
use crate::account_worker::restoration_task::{
    Authentication, Credential, Credentials, Methods, MultipleAuthentication, MultipleCredentials,
    Preparation,
};
use crate::local_auth;

fn usable(entry: &gtk::PasswordEntry) -> bool {
    let length = unsafe {
        CStr::from_ptr(gtk::ffi::gtk_editable_get_text(
            entry.upcast_ref::<gtk::Editable>().to_glib_none().0,
        ))
        .to_bytes()
        .len()
    };
    (1..=4096).contains(&length)
}
fn credential(
    fields: &gtk::Box,
    title: &str,
    methods: Methods,
) -> (gtk::PasswordEntry, gtk::CheckButton) {
    fields.append(&label(title));
    let input = gtk::PasswordEntry::builder()
        .show_peek_icon(false)
        .hexpand(true)
        .build();
    input.update_property(&[gtk::accessible::Property::Label(title)]);
    let mode = gtk::CheckButton::with_label("Use recovery key");
    mode.set_active(!methods.passphrase);
    mode.set_sensitive(methods.passphrase && methods.recovery);
    mode.set_visible(methods.recovery);
    fields.append(&input);
    fields.append(&mode);
    (input, mode)
}
struct Fields {
    content: gtk::Box,
    current: gtk::PasswordEntry,
    current_mode: gtk::CheckButton,
    previous: gtk::PasswordEntry,
    previous_mode: gtk::CheckButton,
    use_previous: gtk::CheckButton,
}
impl Fields {
    fn new(methods: Authentication) -> Self {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
        let (current, current_mode) = credential(
            &content,
            "Current vault passphrase or recovery key",
            methods.current,
        );
        let use_previous = gtk::CheckButton::with_label("Saved changes use a previous vault");
        let previous_available = methods.previous.is_some_and(Methods::available);
        use_previous.set_sensitive(previous_available);
        use_previous.set_visible(previous_available);
        use_previous.set_active(previous_available && methods.previous_suggested);
        content.append(&use_previous);
        let previous_fields = gtk::Box::new(gtk::Orientation::Vertical, 10);
        let (previous, previous_mode) = credential(
            &previous_fields,
            if methods.previous_backup {
                "Previous vault backup password"
            } else {
                "Previous vault passphrase or recovery key"
            },
            methods.previous.unwrap_or(Methods {
                passphrase: false,
                recovery: false,
            }),
        );
        previous_fields.set_visible(use_previous.is_active());
        content.append(&previous_fields);
        if !previous_available {
            content.append(&label(
                "Choose the previous vault.json file or an encrypted backup to unlock changes from a different vault.",
            ));
        }
        let weak = previous_fields.downgrade();
        let secret = previous.downgrade();
        use_previous.connect_toggled(move |toggle| {
            if let Some(fields) = weak.upgrade() {
                fields.set_visible(toggle.is_active());
            }
            if !toggle.is_active()
                && let Some(secret) = secret.upgrade()
            {
                secret.set_text("");
            }
        });
        Self {
            content,
            current,
            current_mode,
            previous,
            previous_mode,
            use_previous,
        }
    }
    fn bind(&self, dialog: &adw::AlertDialog) {
        dialog.set_response_enabled("unlock", false);
        for input in [&self.current, &self.previous] {
            let update = self.updater(dialog);
            input.connect_changed(move |_| update());
        }
        let update = self.updater(dialog);
        self.use_previous.connect_toggled(move |_| update());
    }
    fn updater(&self, dialog: &adw::AlertDialog) -> impl Fn() + use<> {
        let dialog = dialog.downgrade();
        let current = self.current.downgrade();
        let previous = self.previous.downgrade();
        let mode = self.use_previous.downgrade();
        move || {
            if let (Some(dialog), Some(current), Some(previous), Some(mode)) = (
                dialog.upgrade(),
                current.upgrade(),
                previous.upgrade(),
                mode.upgrade(),
            ) {
                dialog.set_response_enabled(
                    "unlock",
                    usable(&current) && (!mode.is_active() || usable(&previous)),
                );
            }
        }
    }
    fn take(&self) -> Result<Credentials> {
        // Clear both inputs even if the first input is oversized or invalid.
        let current = secret(&self.current);
        let previous = secret(&self.previous);
        Ok(Credentials {
            current: Credential {
                value: current?,
                recovery: self.current_mode.is_active(),
            },
            previous: if self.use_previous.is_active() {
                Some(Credential {
                    value: previous?,
                    recovery: self.previous_mode.is_active(),
                })
            } else {
                None
            },
        })
    }
}

enum CredentialChoice {
    Cancel,
    Verify(Credentials),
    File,
    Files,
}
struct MultipleFields {
    base: Fields,
    files: Vec<(gtk::PasswordEntry, gtk::CheckButton)>,
}
impl MultipleFields {
    fn new(methods: MultipleAuthentication, paths: &[std::path::PathBuf]) -> Self {
        let base = Fields::new(methods.base);
        base.use_previous
            .set_label(Some("Also unlock the vault retained in recovery history"));
        base.use_previous.set_active(false);
        if methods.files.len() == 8 {
            base.use_previous.set_sensitive(false);
        }
        let files = methods
            .files
            .into_iter()
            .enumerate()
            .map(|(index, methods)| {
                let name = paths
                    .get(index)
                    .and_then(|path| path.file_name())
                    .map(|name| name.to_string_lossy())
                    .unwrap_or_default();
                credential(
                    &base.content,
                    &format!(
                        "Vault file {}: {} — {}",
                        index + 1,
                        name,
                        if methods.backup {
                            "backup password"
                        } else {
                            "passphrase or recovery key"
                        }
                    ),
                    methods.methods,
                )
            })
            .collect();
        Self { base, files }
    }
    fn passwords(&self) -> Vec<gtk::PasswordEntry> {
        [&self.base.current, &self.base.previous]
            .into_iter()
            .chain(self.files.iter().map(|(input, _)| input))
            .cloned()
            .collect()
    }
    fn bind(&self, dialog: &adw::AlertDialog) {
        dialog.set_response_enabled("unlock", false);
        for input in self.passwords() {
            let update = self.updater(dialog);
            input.connect_changed(move |_| update());
        }
        let update = self.updater(dialog);
        self.base.use_previous.connect_toggled(move |_| update());
    }
    fn updater(&self, dialog: &adw::AlertDialog) -> impl Fn() + use<> {
        let dialog = dialog.downgrade();
        let current = self.base.current.downgrade();
        let previous = self.base.previous.downgrade();
        let retained = self.base.use_previous.downgrade();
        let files = self
            .files
            .iter()
            .map(|(input, _)| input.downgrade())
            .collect::<Vec<_>>();
        move || {
            if let (Some(dialog), Some(current), Some(previous), Some(retained)) = (
                dialog.upgrade(),
                current.upgrade(),
                previous.upgrade(),
                retained.upgrade(),
            ) {
                dialog.set_response_enabled(
                    "unlock",
                    usable(&current)
                        && (!retained.is_active() || usable(&previous))
                        && files
                            .iter()
                            .all(|input| input.upgrade().is_some_and(|input| usable(&input)))
                        && files.len() + usize::from(retained.is_active()) <= 8,
                );
            }
        }
    }
    fn take(&self) -> Result<MultipleCredentials> {
        let base = self.base.take();
        // Read and clear every input before returning any validation error.
        let files = self
            .files
            .iter()
            .map(|(input, mode)| {
                secret(input).map(|value| Credential {
                    value,
                    recovery: mode.is_active(),
                })
            })
            .collect::<Vec<_>>();
        let base = base?;
        Ok(MultipleCredentials {
            current: base.current,
            retained: base.previous,
            files: files.into_iter().collect::<Result<_>>()?,
        })
    }
}

impl AccountWindow {
    async fn restoration_credentials(
        &self,
        methods: Authentication,
        generation: u64,
        preparation: &Preparation,
    ) -> Result<CredentialChoice> {
        preparation.validate()?;
        if generation != self.generation.get() || !self.window.is_active() {
            return Ok(CredentialChoice::Cancel);
        }
        let fields = Fields::new(methods);
        let dialog = adw::AlertDialog::builder()
            .heading("Unlock the Vaults for Restoration")
            .body("Verify the saved secure changes with their vault password or recovery key. When the previous vault is selected, its changes will be encrypted in the current vault. Review the result before applying it.")
            .extra_child(&fields.content)
            .build();
        dialog.add_responses(&[
            ("back", "Cancel"),
            ("file", "Choose Previous Vault File…"),
            ("files", "Choose Several Vault Files…"),
            ("unlock", "Verify Saved Changes"),
        ]);
        dialog.set_default_response(Some("back"));
        dialog.set_close_response("back");
        fields.bind(&dialog);
        *self.restoration_dialog.borrow_mut() = Some((
            dialog.clone(),
            vec![fields.current.clone(), fields.previous.clone()],
        ));
        let response = dialog.choose_future(Some(&self.window)).await;
        self.restoration_dialog.borrow_mut().take();
        let credentials = fields.take();
        if generation != self.generation.get() || !self.window.is_active() {
            return Ok(CredentialChoice::Cancel);
        }
        preparation.validate()?;
        if response == "file" {
            return Ok(CredentialChoice::File);
        }
        if response == "files" {
            return Ok(CredentialChoice::Files);
        }
        if response != "unlock" {
            return Ok(CredentialChoice::Cancel);
        }
        credentials.map(CredentialChoice::Verify)
    }
    async fn previous_vault_file(&self, generation: u64) -> Result<Option<std::path::PathBuf>> {
        Ok(self
            .previous_vault_files(generation, false)
            .await?
            .and_then(|files| files.into_iter().next()))
    }
    async fn previous_vault_files(
        &self,
        generation: u64,
        multiple: bool,
    ) -> Result<Option<Vec<std::path::PathBuf>>> {
        // A portal is allowed to take focus only during this key-free phase.
        self.gate.borrow_mut().cancel();
        if let Some(preparation) = self.restoration_preparation.borrow_mut().take() {
            preparation.cancel();
        }
        let guard = self.new_restoration_preparation()?;
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Previous vault or encrypted backup"));
        filter.add_pattern("*.json");
        filter.add_pattern("*.snippetsbackup");
        let dialog = gtk::FileDialog::builder()
            .title("Choose Previous Vault File")
            .default_filter(&filter)
            .build();
        let cancellation = gtk::gio::Cancellable::new();
        *self.restoration_file_choice.borrow_mut() = Some((cancellation.clone(), guard.clone()));
        let (send, receive) = mpsc::sync_channel(1);
        if multiple {
            dialog.open_multiple(Some(&self.window), Some(&cancellation), move |result| {
                let files = result.ok().and_then(|files| {
                    (0..files.n_items())
                        .map(|index| files.item(index).and_downcast::<gtk::gio::File>())
                        .collect::<Option<Vec<_>>>()
                });
                let _ = send.send(files);
            });
        } else {
            dialog.open(Some(&self.window), Some(&cancellation), move |result| {
                let _ = send.send(result.ok().map(|file| vec![file]));
            });
        }
        let choice = loop {
            match receive.try_recv() {
                Ok(result) => break result,
                Err(mpsc::TryRecvError::Disconnected) => break None,
                Err(mpsc::TryRecvError::Empty) => {
                    if generation != self.generation.get() || guard.validate().is_err() {
                        cancellation.cancel();
                    }
                    glib::timeout_future(Duration::from_millis(30)).await;
                }
            }
        };
        // Portal completion may precede the restored focus notification.
        for _ in 0..10 {
            if self.window.is_active()
                || generation != self.generation.get()
                || guard.validate().is_err()
            {
                break;
            }
            glib::timeout_future(Duration::from_millis(30)).await;
        }
        self.restoration_file_choice.borrow_mut().take();
        if generation != self.generation.get() || !self.window.is_active() {
            return Ok(None);
        }
        guard.validate()?;
        let Some(files) = choice else {
            return Ok(None);
        };
        if files.is_empty() || files.len() > 8 {
            return Err(Failure::InvalidState);
        }
        files
            .into_iter()
            .map(|file| {
                file.path()
                    .ok_or(Failure::Restoration(restoration::Failure::SourceFile))
            })
            .collect::<Result<Vec<_>>>()
            .map(Some)
    }
    async fn multiple_vault_credentials(
        &self,
        methods: MultipleAuthentication,
        paths: &[std::path::PathBuf],
        generation: u64,
        preparation: &Preparation,
    ) -> Result<Option<MultipleCredentials>> {
        preparation.validate()?;
        if generation != self.generation.get() || !self.window.is_active() {
            return Ok(None);
        }
        let fields = MultipleFields::new(methods, paths);
        let inputs = gtk::ScrolledWindow::builder()
            .child(&fields.base.content)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .min_content_height(240)
            .max_content_height(420)
            .propagate_natural_height(true)
            .build();
        let dialog = adw::AlertDialog::builder()
            .heading("Unlock the Saved Vaults")
            .body("Unlock every vault used by the saved changes. You can also use the vault retained in recovery history; leave that option off if you selected the same vault as a file. All restored secure changes will use the current vault. Review the result before applying it.")
            .extra_child(&inputs).build();
        dialog.add_responses(&[("back", "Cancel"), ("unlock", "Verify All Saved Changes")]);
        dialog.set_default_response(Some("back"));
        dialog.set_close_response("back");
        fields.bind(&dialog);
        *self.restoration_dialog.borrow_mut() = Some((dialog.clone(), fields.passwords()));
        let response = dialog.choose_future(Some(&self.window)).await;
        self.restoration_dialog.borrow_mut().take();
        let credentials = fields.take();
        if response != "unlock" || generation != self.generation.get() || !self.window.is_active() {
            return Ok(None);
        }
        preparation.validate()?;
        credentials.map(Some)
    }
    fn new_restoration_preparation(&self) -> Result<Preparation> {
        Preparation::new(
            self.desktop
                .as_ref()
                .ok_or(Failure::Authentication(
                    local_auth::Failure::DesktopUnavailable,
                ))?
                .witness(),
        )
    }
    pub(super) fn restore_saved(
        self: &Rc<Self>,
        selection: Option<restoration::Selection>,
        cancel: bool,
    ) {
        if self.busy.get() {
            return;
        }
        self.cancel_sensitive();
        let mut preparation = if selection.is_some() {
            let prepared = self.new_restoration_preparation();
            match prepared {
                Ok(preparation) => {
                    *self.restoration_preparation.borrow_mut() = Some(preparation.clone());
                    Some(preparation)
                }
                Err(failure) => {
                    self.failure(failure);
                    return;
                }
            }
        } else {
            None
        };
        self.busy(true);
        self.status.set_label("Checking the saved restoration…");
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = async {
                let reply = if let Some(selection) = selection {
                    let initial = preparation.as_ref().ok_or(Failure::InvalidState)?.clone();
                    let first = this.execute(Command::PrepareRestoration {
                        selection: selection.clone(), credentials: None,
                        preparation: initial, source_file: None,
                    }).await?;
                    if let Reply::RestorationAuthentication(mut methods) = first {
                        let mut selected_file = None;
                        loop {
                            let guard = preparation.as_ref().ok_or(Failure::InvalidState)?;
                            match this.restoration_credentials(methods, generation, guard).await? {
                                CredentialChoice::Cancel => return Ok(None),
                                CredentialChoice::Verify(credentials) => {
                                    this.status.set_label("Verifying the saved secure changes…");
                                    let source_file = if credentials.previous.is_some() { selected_file } else { None };
                                    break this.execute(Command::PrepareRestoration {
                                        selection, credentials: Some(credentials),
                                        preparation: guard.clone(), source_file,
                                    }).await?;
                                }
                                CredentialChoice::File => {
                                    let Some(path) = this.previous_vault_file(generation).await? else { return Ok(None); };
                                    let fresh = this.new_restoration_preparation()?;
                                    *this.restoration_preparation.borrow_mut() = Some(fresh.clone());
                                    preparation = Some(fresh.clone());
                                    let Reply::RestorationFile {token, methods: next} = this.execute(Command::InspectRestorationFile {
                                        selection: selection.clone(), path, preparation: fresh,
                                    }).await? else { return Err(Failure::InvalidState); };
                                    selected_file = Some(token);
                                    methods = next;
                                }
                                CredentialChoice::Files => {
                                    let Some(paths) = this.previous_vault_files(generation, true).await? else { return Ok(None); };
                                    let fresh = this.new_restoration_preparation()?;
                                    *this.restoration_preparation.borrow_mut() = Some(fresh.clone());
                                    preparation = Some(fresh.clone());
                                    let Reply::RestorationFiles { token, methods } = this.execute(Command::InspectRestorationFiles {
                                        selection: selection.clone(), paths: paths.clone(), preparation: fresh.clone(),
                                    }).await? else { return Err(Failure::InvalidState); };
                                    let Some(credentials) = this.multiple_vault_credentials(methods, &paths, generation, &fresh).await? else { return Ok(None); };
                                    this.status.set_label("Verifying all saved vaults and secure changes…");
                                    break this.execute(Command::PrepareMultipleRestoration {
                                        selection, credentials, preparation: fresh, source_files: token,
                                    }).await?;
                                }
                            }
                        }
                    } else { first }
                } else { this.execute(Command::PrepareRestorationResume(cancel)).await? };
                let Reply::RestorationReview { token, summary, target, saved, current, rekeyed } = reply else { return Err(Failure::InvalidState); };
                if generation != this.generation.get() || !this.window.is_active() { return Ok(None); }
                if let Some(preparation) = &preparation { preparation.validate()?; }
                let dialog = adw::AlertDialog::builder()
                    .heading(if cancel { "Cancel the Saved Restoration?" } else if token.is_some() { "Restore the Saved Changes?" } else { "Finish the Saved Restoration?" })
                    .body(format!("Saved library: {}\n{} · key version {}\n\nCurrent library: {}\n{} · key version {}\n\n{} saved records · {} preserved current versions · {} secure records\n\n{}{}", saved.server().for_secure_storage(), saved.id(), saved.epoch(), current.server().for_secure_storage(), current.id(), current.epoch(), summary.restored_records, summary.preserved_versions, summary.secure_records,
                        if rekeyed { "Saved secure changes will use the current vault's encryption.\n\n" } else { "" },
                        if cancel { "Cancel before the file update begins. Current edits and saved states will be kept." }
                        else { "Apply the reviewed changes locally and keep current versions. Saved pending versions will also synchronize in their recorded order. Previous keys remain saved. Reconnect and select a library afterward to verify access before syncing." })).build();
                dialog.add_responses(&[("back", "Keep Current State"), ("proceed", if cancel { "Cancel Restoration" } else { "Restore Changes" })]);
                dialog.set_default_response(Some("back")); dialog.set_close_response("back");
                *this.snapshot_dialog.borrow_mut() = Some(dialog.clone());
                let response = dialog.choose_future(Some(&this.window)).await;
                this.snapshot_dialog.borrow_mut().take();
                if response != "proceed" || generation != this.generation.get() || !this.window.is_active() { return Ok(None); }
                let permit = this.authorize_target(target, generation).await?;
                if let Some(preparation) = &preparation { preparation.validate()?; }
                let command = if let Some(token) = token { Command::CommitRestoration {token, permit} }
                    else { Command::FinishRestoration {cancel, permit} };
                this.execute(command).await.map(Some)
            }.await;
            if let Some(preparation) = this.restoration_preparation.borrow_mut().take() {
                preparation.cancel();
            }
            this.busy(false);
            if generation != this.generation.get() {
                return;
            }
            match result {
                Ok(Some(reply)) => this.apply(reply),
                Ok(None) => this
                    .status
                    .set_label("Restoration review closed. Current changes are kept."),
                Err(failure) => this.failure(failure),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::SessionWitness;
    #[test]
    #[ignore = "requires a graphical display; fictional credentials and synthetic worker, no keyring/PAM/clipboard/network"]
    fn native_previous_current_inputs_are_independent_bounded_and_cleared_on_cancel() {
        adw::init().expect("graphical display");
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.RestorationVaultsSmoke")
            .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application
            .register(None::<&gtk::gio::Cancellable>)
            .unwrap();
        let parent = adw::ApplicationWindow::builder()
            .application(&application)
            .build();
        let window =
            AccountWindow::with_worker(&application, &parent, Handle::fixture(), None).unwrap();
        let fields = Fields::new(Authentication {
            current: Methods {
                passphrase: false,
                recovery: true,
            },
            previous: Some(Methods {
                passphrase: true,
                recovery: true,
            }),
            previous_suggested: true,
            previous_backup: false,
        });
        assert!(fields.current_mode.is_active() && !fields.current_mode.is_sensitive());
        assert!(!fields.previous_mode.is_active() && fields.previous_mode.is_sensitive());
        let dialog = adw::AlertDialog::builder()
            .heading("Public restoration fixture")
            .extra_child(&fields.content)
            .build();
        dialog.add_responses(&[("back", "Cancel"), ("unlock", "Verify Saved Changes")]);
        dialog.set_close_response("back");
        fields.bind(&dialog);
        fields.current.set_text("Public current recovery key");
        fields.previous.set_text("Public previous passphrase");
        let credentials = fields.take().unwrap();
        assert!(credentials.current.recovery && !credentials.previous.as_ref().unwrap().recovery);
        assert_eq!(
            credentials.current.value.as_str(),
            "Public current recovery key"
        );
        assert_eq!(
            credentials.previous.unwrap().value.as_str(),
            "Public previous passphrase"
        );
        assert!(fields.current.text().is_empty() && fields.previous.text().is_empty());
        fields.previous.set_text("Public secret to hide");
        fields.use_previous.set_active(false);
        assert!(fields.previous.text().is_empty());
        fields.use_previous.set_active(true);
        fields.current.set_text(&"x".repeat(4097));
        fields.previous.set_text("Public previous passphrase");
        assert!(!usable(&fields.current));
        assert!(fields.take().is_err());
        assert!(fields.current.text().is_empty() && fields.previous.text().is_empty());
        fields.current.set_text("Public cancelled current secret");
        fields.previous.set_text("Public cancelled source secret");
        let preparation =
            Preparation::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap();
        *window.restoration_preparation.borrow_mut() = Some(preparation.clone());
        *window.restoration_dialog.borrow_mut() = Some((
            dialog,
            vec![fields.current.clone(), fields.previous.clone()],
        ));
        window.cancel_sensitive();
        assert!(fields.current.text().is_empty() && fields.previous.text().is_empty());
        assert!(preparation.validate().is_err() && window.restoration_dialog.borrow().is_none());
        assert!(window.restoration_preparation.borrow().is_none() && window.worker.prepare_quit());
        let backup = Fields::new(Authentication {
            current: Methods {
                passphrase: true,
                recovery: false,
            },
            previous: Some(Methods {
                passphrase: true,
                recovery: false,
            }),
            previous_suggested: true,
            previous_backup: true,
        });
        assert!(!backup.previous_mode.is_active() && !backup.previous_mode.is_visible());
        backup.current.set_text("Public current vault password");
        backup.previous.set_text("Public previous backup password");
        let values = backup.take().unwrap();
        assert!(!values.current.recovery && !values.previous.unwrap().recovery);
        assert!(backup.current.text().is_empty() && backup.previous.text().is_empty());
        let picker = gtk::gio::Cancellable::new();
        let guard = Preparation::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap();
        *window.restoration_file_choice.borrow_mut() = Some((picker.clone(), guard.clone()));
        window.cancel_sensitive();
        assert!(picker.is_cancelled() && guard.validate().is_err());
        assert!(window.restoration_file_choice.borrow().is_none());
        let multiple = MultipleFields::new(
            MultipleAuthentication {
                base: Authentication {
                    current: Methods {
                        passphrase: true,
                        recovery: true,
                    },
                    previous: Some(Methods {
                        passphrase: true,
                        recovery: true,
                    }),
                    previous_suggested: true,
                    previous_backup: false,
                },
                files: vec![
                    crate::account_worker::restoration_task::FileMethods {
                        methods: Methods {
                            passphrase: true,
                            recovery: false,
                        },
                        backup: true,
                    },
                    crate::account_worker::restoration_task::FileMethods {
                        methods: Methods {
                            passphrase: true,
                            recovery: true,
                        },
                        backup: false,
                    },
                ],
            },
            &[],
        );
        let dialog = adw::AlertDialog::new(Some("Public multi-vault fixture"), None);
        dialog.add_responses(&[("unlock", "Verify")]);
        multiple.bind(&dialog);
        multiple.base.current.set_text("Public current password");
        multiple.files[0].0.set_text("Public backup password");
        assert!(!dialog.is_response_enabled("unlock"));
        multiple.files[1].0.set_text("Public extra recovery key");
        multiple.files[1].1.set_active(true);
        assert!(dialog.is_response_enabled("unlock") && !multiple.files[0].1.is_visible());
        multiple.base.use_previous.set_active(true);
        assert!(!dialog.is_response_enabled("unlock"));
        multiple
            .base
            .previous
            .set_text("Public retained-vault password");
        assert!(dialog.is_response_enabled("unlock"));
        let values = multiple.take().unwrap();
        assert!(
            values.retained.is_some()
                && values.files.len() == 2
                && values.files[1].recovery
                && !values.files[0].recovery
        );
        assert!(
            multiple
                .passwords()
                .iter()
                .all(|input| input.text().is_empty())
        );
        for input in multiple.passwords() {
            input.set_text("Public cancellation secret");
        }
        *window.restoration_dialog.borrow_mut() = Some((dialog.clone(), multiple.passwords()));
        window.cancel_sensitive();
        assert!(
            multiple
                .passwords()
                .iter()
                .all(|input| input.text().is_empty())
        );
        for input in multiple.passwords() {
            input.set_text("Public valid secret");
        }
        multiple.files[0].0.set_text(&"x".repeat(4097));
        assert!(
            multiple.take().is_err()
                && multiple
                    .passwords()
                    .iter()
                    .all(|input| input.text().is_empty())
        );
        window.window.close();
        parent.close();
    }
}
