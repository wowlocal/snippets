//! Explicit current-vault verification; only methods and closed progress reach GTK.
use super::*;
use crate::account_worker::vault_sync::{Authorization, Methods};

fn dialog(methods: Methods) -> (adw::AlertDialog, gtk::PasswordEntry, gtk::CheckButton) {
    let dialog = adw::AlertDialog::builder().heading("Verify Vault and Continue Sync?")
        .body("Enter the current vault passphrase or recovery key to verify incoming encrypted records and preserve secure conflicts during this synchronization. This does not unlock the editor. Saved account, library-switch and deletion reviews still apply.").build();
    dialog.set_body_use_markup(false);
    let fields = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let entry = gtk::PasswordEntry::builder()
        .show_peek_icon(false)
        .hexpand(true)
        .build();
    entry.update_property(&[gtk::accessible::Property::Label(
        "Current vault passphrase or recovery key",
    )]);
    let mode = gtk::CheckButton::with_label("Use recovery key");
    mode.set_active(!methods.passphrase);
    mode.set_sensitive(methods.passphrase && methods.recovery);
    mode.set_visible(methods.recovery);
    fields.append(&entry);
    fields.append(&mode);
    dialog.set_extra_child(Some(&fields));
    dialog.add_responses(&[("cancel", "Cancel"), ("sync", "Verify and Sync")]);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.set_response_enabled("sync", false);
    let weak = dialog.downgrade();
    entry.connect_changed(move |entry| {
        let usable = unsafe {
            let pointer = gtk::ffi::gtk_editable_get_text(
                entry.upcast_ref::<gtk::Editable>().to_glib_none().0,
            );
            let bytes = CStr::from_ptr(pointer).to_bytes();
            (1..=4096).contains(&bytes.len())
        };
        if let Some(dialog) = weak.upgrade() {
            dialog.set_response_enabled("sync", usable);
        }
    });
    (dialog, entry, mode)
}
impl AccountWindow {
    pub(super) fn cancel_vault_sync(&self) {
        let authorization = self.vault_sync_authorization.borrow_mut().take();
        if let Some(authorization) = authorization {
            authorization.cancel();
        }
        let dialog = self.vault_sync_dialog.borrow_mut().take();
        if let Some((dialog, entry)) = dialog {
            entry.set_text("");
            dialog.force_close();
        }
    }
    fn vault_sync_ready(&self, generation: u64, authorization: &Authorization) -> Result<()> {
        authorization.validate()?;
        if self.generation.get() != generation
            || !self.window.is_active()
            || !self.window.is_visible()
        {
            return Err(crate::local_auth::Failure::Cancelled.into());
        }
        Ok(())
    }
    pub(super) fn verify_vault_sync(self: &Rc<Self>) {
        if self.busy.get()
            || !self.window.is_active()
            || !self.window.is_visible()
            || !self.sync.is_sensitive()
        {
            return;
        }
        let authorization = match self
            .desktop
            .as_ref()
            .ok_or(Failure::InvalidState)
            .and_then(|monitor| Authorization::new(monitor.witness()))
        {
            Ok(value) => value,
            Err(failure) => {
                self.failure(failure);
                return;
            }
        };
        self.cancel_sensitive();
        let generation = self.generation.get();
        *self.vault_sync_authorization.borrow_mut() = Some(authorization.clone());
        self.busy(true);
        self.status
            .set_label("Preparing current vault verification…");
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result: Result<Option<Reply>> = async {
                let Reply::VaultSync { token, methods } = this
                    .execute(Command::PrepareVaultSync(authorization.clone()))
                    .await?
                else {
                    return Err(Failure::InvalidState);
                };
                this.vault_sync_ready(generation, &authorization)?;
                let (dialog, entry, mode) = dialog(methods);
                *this.vault_sync_dialog.borrow_mut() = Some((dialog.clone(), entry.clone()));
                let response = dialog.choose_future(Some(&this.window)).await;
                this.vault_sync_dialog.borrow_mut().take();
                let credential = secret(&entry);
                if response != "sync" {
                    return Ok(None);
                }
                this.vault_sync_ready(generation, &authorization)?;
                this.status
                    .set_label("Verifying vault and continuing synchronization…");
                let reply = this
                    .execute(Command::ContinueVaultSync {
                        token,
                        credential: credential?,
                        recovery: mode.is_active(),
                    })
                    .await?;
                Ok(Some(reply))
            }
            .await;
            // Resume saved automatic scheduling only after the worker has
            // relinquished this request and any secret-owning cycle.
            let _ = this.execute(Command::CancelVaultSync).await;
            this.cancel_vault_sync();
            this.busy(false);
            match result {
                Ok(Some(reply)) if this.generation.get() == generation => this.apply(reply),
                Ok(Some(_)) => this.status.set_label("Vault verification ended. Saved synchronization changes are kept; review the current status before retrying."),
                Ok(None) => this.status.set_label("Vault verification cancelled."),
                Err(failure) => this.failure(failure),
            }
        });
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; public credentials and dialog only, no account/keyring/PAM/network"]
    fn native_vault_sync_dialog_cancels_by_default_and_bounds_both_credential_methods() {
        adw::init().expect("graphical display");
        for (passphrase, recovery) in [(true, false), (false, true), (true, true)] {
            let (dialog, entry, mode) = dialog(Methods {
                passphrase,
                recovery,
            });
            assert!(!dialog.is_body_use_markup());
            assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
            assert_eq!(dialog.close_response(), "cancel");
            assert!(!dialog.is_response_enabled("sync"));
            assert!(!entry.shows_peek_icon());
            assert_eq!(mode.is_visible(), recovery);
            assert_eq!(mode.is_active(), !passphrase);
            assert_eq!(mode.is_sensitive(), passphrase && recovery);
            entry.set_text("Public credential fixture");
            assert!(dialog.is_response_enabled("sync"));
            entry.set_text(&"X".repeat(4097));
            assert!(!dialog.is_response_enabled("sync"));
            entry.set_text("Public fixture again");
            assert!(secret(&entry).is_ok());
            assert!(entry.text().is_empty());
            assert!(!dialog.is_response_enabled("sync"));
        }
    }
}
