//! Explicit saved-record verification; no cached reveal key or body enters GTK.
use super::*;
use crate::vault::legacy_repair::{Authorization, Request};
const EXPIRED: Error = Error(
    "Secure metadata repair expired or the selected entry changed. Re-read it before trying again.",
);
fn review_dialog(
    pass: bool,
    recovery: bool,
) -> (adw::AlertDialog, gtk::PasswordEntry, gtk::CheckButton) {
    let dialog = adw::AlertDialog::builder().heading("Repair This Legacy Secure Entry?")
        .body("Verify this saved entry with its vault passphrase or recovery key to restore missing integrity metadata. The encrypted content, name, keyword and tags stay the same. This verification does not unlock the editor.").build();
    dialog.set_body_use_markup(false);
    let fields = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let entry = gtk::PasswordEntry::builder()
        .show_peek_icon(false)
        .hexpand(true)
        .build();
    entry.update_property(&[gtk::accessible::Property::Label(
        "Vault passphrase or recovery key",
    )]);
    let mode = gtk::CheckButton::with_label("Use recovery key");
    mode.set_active(!pass);
    mode.set_sensitive(pass && recovery);
    fields.append(&entry);
    fields.append(&mode);
    dialog.set_extra_child(Some(&fields));
    dialog.add_responses(&[("cancel", "Cancel"), ("repair", "Verify and Repair")]);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.set_response_enabled("repair", false);
    let weak = dialog.downgrade();
    entry.connect_changed(move |entry| {
        if let Some(dialog) = weak.upgrade() {
            dialog.set_response_enabled("repair", draft_recovery::usable(entry));
        }
    });
    (dialog, entry, mode)
}
impl Workspace {
    pub(super) fn cancel_legacy_repair(&self) {
        let authorization = self.repair_authorization.borrow_mut().take();
        if let Some(authorization) = authorization {
            authorization.cancel();
            self.generation.set(self.generation.get().wrapping_add(1));
        }
        let dialog = self.repair_dialog.borrow_mut().take();
        if let Some((dialog, entry)) = dialog {
            entry.set_text("");
            dialog.force_close();
        }
    }
    fn repair_ready(&self, generation: u64, id: Uuid, authorization: &Authorization) -> Result<()> {
        authorization.validate()?;
        if generation != self.generation.get()
            || self.selected.get() != Some(id)
            || self.is_dirty()
            || !self.window.is_active()
            || !self.window.is_visible()
        {
            return Err(EXPIRED);
        }
        Ok(())
    }
    pub(super) fn repair_legacy(self: &Rc<Self>) {
        if self.busy.get() || self.is_dirty() || !self.desktop_allowed() || !self.window.is_active()
        {
            return;
        }
        let Some(record) = self
            .selected
            .get()
            .and_then(|id| self.vault.borrow().record(id))
        else {
            return;
        };
        if !record.content_hash.is_empty() {
            return;
        }
        let Some(document) = self.vault.borrow().document.clone() else {
            return;
        };
        let pass = document.wrap_pass.is_some();
        let recovery = document.wrap_recovery.is_some();
        if !pass && !recovery {
            self.toast("This vault needs a passphrase or recovery wrap before its legacy entries can be verified.");
            return;
        }
        let authorization = match self
            .desktop
            .as_ref()
            .ok_or(EXPIRED)
            .and_then(|monitor| Authorization::new(monitor.witness()))
        {
            Ok(authorization) => authorization,
            Err(error) => {
                self.toast(error.0);
                return;
            }
        };
        self.cancel_insertion();
        self.cancel_draft_recovery();
        self.reveal.set_active(false);
        let generation = self.generation.get();
        let id = record.metadata.id;
        *self.repair_authorization.borrow_mut() = Some(authorization.clone());
        self.busy.set(true);
        self.repair_worker.set(true);
        self.update();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result: Result<()> = async {
                let root = this.library.root.clone();
                let checked = authorization.clone();
                let request =
                    worker(move || Request::capture(root, document, record, checked)).await?;
                this.repair_worker.set(false);
                this.repair_ready(generation, id, &authorization)?;
                let (dialog, entry, mode) = review_dialog(pass, recovery);
                *this.repair_dialog.borrow_mut() = Some((dialog.clone(), entry.clone()));
                let response = dialog.choose_future(Some(&this.window)).await;
                this.repair_dialog.borrow_mut().take();
                let credential = draft_recovery::take_secret(&entry);
                if response != "repair" {
                    return Ok(());
                }
                let credential = credential?;
                this.repair_ready(generation, id, &authorization)?;
                this.repair_worker.set(true);
                this.status.set_label("Verifying saved secure metadata…");
                let use_recovery = mode.is_active();
                let prepared =
                    worker(move || request.authenticate(&credential, use_recovery)).await?;
                this.repair_ready(generation, id, &authorization)?;
                let receipt = worker(move || prepared.commit()).await?;
                this.repair_worker.set(false);
                // A published atomic replacement is still an outcome if focus
                // changed just after rename. Do not adopt a stale current draft.
                if this.repair_ready(generation, id, &authorization).is_ok() {
                    this.editor.accept_legacy_repair(&receipt)?;
                }
                this.vault.borrow_mut().reload()?;
                this.refresh();
                this.toast("Saved secure metadata repaired. The encrypted content was kept.");
                Ok(())
            }
            .await;
            this.repair_worker.set(false);
            this.cancel_legacy_repair();
            this.busy.set(false);
            this.update();
            if let Err(error) = result {
                this.toast(error.0);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; review dialog with fictional credentials only"]
    fn native_legacy_repair_review_cancels_by_default_and_bounds_credentials() {
        adw::init().expect("graphical display");
        let (dialog, entry, mode) = review_dialog(true, true);
        assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
        assert_eq!(dialog.close_response(), "cancel");
        assert!(!dialog.is_body_use_markup());
        assert!(!dialog.is_response_enabled("repair") && !entry.shows_peek_icon());
        assert!(!mode.is_active() && mode.is_sensitive());
        entry.set_text("Public fictional credential");
        assert!(dialog.is_response_enabled("repair"));
        draft_recovery::take_secret(&entry).unwrap();
        assert!(entry.text().is_empty());
        entry.set_text(&"X".repeat(4097));
        assert!(!dialog.is_response_enabled("repair"));
        assert!(draft_recovery::take_secret(&entry).is_err() && entry.text().is_empty());
        let (_, _, mode) = review_dialog(false, true);
        assert!(mode.is_active() && !mode.is_sensitive());
    }
}
