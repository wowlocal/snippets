//! Explicit destination review and fresh vault credentials. A focus transfer is
//! armed only after exact record admission; ordinary focus loss still cancels.
use super::*;
use crate::secure_insertion::{Authorization, wayland::Native};
#[path = "secure_insertion_clipboard.rs"]
mod clipboard;
fn review_dialog(
    application: &str,
    has_passphrase: bool,
    has_recovery: bool,
) -> (adw::AlertDialog, gtk::PasswordEntry, gtk::CheckButton) {
    let fields = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let entry = gtk::PasswordEntry::builder()
        .show_peek_icon(false)
        .hexpand(true)
        .build();
    entry.update_property(&[gtk::accessible::Property::Label(
        "Fresh vault credential for secure insertion",
    )]);
    let recovery = gtk::CheckButton::with_label("Use vault recovery key");
    recovery.set_active(!has_passphrase);
    recovery.set_sensitive(has_passphrase && has_recovery);
    fields.append(&label(
        "Authenticate this insertion with your vault passphrase or recovery key.",
    ));
    fields.append(&entry);
    fields.append(&recovery);
    let dialog = adw::AlertDialog::builder()
        .heading("Insert Saved Secure Text?")
        .body(format!("Destination: {application}\n\nThe saved text will be typed without using the clipboard. Line breaks and tabs are keyboard input and may trigger actions in the destination. Keep the original window focused until insertion finishes. A focus change or desktop lock stops further input when detected. A stopped insertion can leave a prefix; check the destination before trying again."))
        .extra_child(&fields)
        .build();
    dialog.set_body_use_markup(false);
    dialog.add_responses(&[("cancel", "Cancel"), ("insert", "Authenticate and Insert")]);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.set_response_enabled("insert", false);
    let changed = dialog.clone();
    entry.connect_changed(move |entry| {
        changed.set_response_enabled("insert", draft_recovery::usable(entry));
    });
    (dialog, entry, recovery)
}
impl Workspace {
    pub(super) fn cancel_insertion(&self) {
        if let Some(auth) = self.insertion_authorization.borrow_mut().take() {
            auth.cancel();
        }
        self.insertion_armed.set(false);
        if let Some((dialog, entry)) = self.insertion_dialog.borrow_mut().take() {
            entry.set_text("");
            dialog.force_close();
        }
    }
    pub fn present_for_insertion(&self, id: Uuid, target: desktop::PasteTarget) {
        self.present(Some(id));
        if self.selected.get() == Some(id) && target.is_fresh() {
            *self.insertion_target.borrow_mut() = Some(target);
        }
        self.update();
    }
    fn insertion_ready(&self, generation: u64, auth: &Authorization) -> Result<()> {
        auth.validate()?;
        if !self.window.is_active()
            || !self.window.is_visible()
            || self.generation.get() != generation
        {
            return Err(Error("Secure insertion expired or was cancelled."));
        }
        Ok(())
    }
    pub(super) fn insert_selected(self: &Rc<Self>) {
        if self.busy.get() || self.is_dirty() || !self.window.is_active() {
            return;
        }
        let Some(target) = self
            .insertion_target
            .borrow()
            .clone()
            .filter(|t| t.is_fresh())
        else {
            return;
        };
        let Some(id) = self.selected.get() else {
            return;
        };
        let Some(record) = self
            .vault
            .borrow()
            .record(id)
            .filter(|r| r.metadata.is_enabled)
        else {
            return;
        };
        let Some(document) = self.vault.borrow().document.clone() else {
            return;
        };
        let Some(monitor) = self.desktop.as_ref() else {
            return;
        };
        self.cancel_draft_recovery();
        self.cancel_insertion();
        let authorization = match Authorization::new(monitor.witness()) {
            Ok(auth) => auth,
            Err(error) => {
                self.toast(&error.to_string());
                return;
            }
        };
        *self.insertion_authorization.borrow_mut() = Some(authorization.clone());
        self.busy.set(true);
        self.insertion_worker.set(true);
        self.update();
        let generation = self.generation.get();
        let vault_generation = self.vault.borrow().generation();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result=async {
                let described=target.clone();
                let application=worker(move ||described.application_label().ok_or(Error("The original window is no longer available."))).await?;
                this.insertion_ready(generation,&authorization)?;
                if !target.is_fresh(){return Err(Error("Select the secure snippet from the picker again to refresh its destination."));}
                let (dialog,entry,recovery)=review_dialog(&application,document.wrap_pass.is_some(),document.wrap_recovery.is_some());
                *this.insertion_dialog.borrow_mut()=Some((dialog.clone(),entry.clone()));
                let response=dialog.choose_future(Some(&this.window)).await;
                this.insertion_dialog.borrow_mut().take();
                if response!="insert" {entry.set_text("");return Err(Error("Secure insertion was cancelled."));}
                let password=draft_recovery::take_secret(&entry)?;
                this.insertion_ready(generation,&authorization)?;
                let use_recovery=recovery.is_active();let checked=authorization.clone();
                let root=this.library.root.clone();
                let prepared=worker(move || {
                    checked.validate()?;
                    let authentication=document.authenticate(&password,use_recovery)?;
                    drop(password);
                    checked.validate()?;
                    Vault::prepare_saved_insertion(root,document,authentication,record,checked)
                }).await?;
                this.insertion_ready(generation,&authorization)?;
                if this.vault.borrow().generation()!=vault_generation {
                    return Err(Error("The vault changed during insertion authentication."));
                }
                let clipboard=if prepared.needs_clipboard(){
                    clipboard::read(&this.window.clipboard(),&authorization).await?
                }else{Zeroizing::new(String::new())};
                this.insertion_ready(generation,&authorization)?;
                if !target.is_fresh(){return Err(Error("The original destination expired. Open the picker again."));}
                this.reveal.set_active(false);this.editor.reveal(false);
                this.insertion_armed.set(true);
                this.window.set_visible(false);
                worker(move || {
                    authorization.validate()?;
                    if !target.is_fresh() || !target.focus(){return Err(Error("The original window could not receive secure input."));}
                    authorization.validate()?;
                    let mut native=Native::new(target);
                    prepared.deliver(&mut native,&clipboard)
                }).await
            }.await;
            this.insertion_worker.set(false);
            this.busy.set(false);
            this.cancel_insertion();
            this.insertion_target.borrow_mut().take();
            this.update();
            match result {
                Ok(_) => this
                    .status
                    .set_label("Secure input sent to the original window; check the destination."),
                Err(error) => {
                    if this.generation.get() == generation {
                        this.window.present();
                    }
                    this.toast(&error.to_string());
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; constructs only the review dialog and never sends input"]
    fn native_insertion_review_bounds_credentials_and_keeps_cancel_as_default() {
        adw::init().expect("graphical display");
        let (dialog, entry, recovery) = review_dialog("Public <destination>", true, true);
        assert!(!dialog.is_body_use_markup());
        assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
        assert_eq!(dialog.close_response(), "cancel");
        assert!(!dialog.is_response_enabled("insert"));
        assert!(!entry.shows_peek_icon());
        assert!(!recovery.is_active() && recovery.is_sensitive());
        entry.set_text("Public fictional credential");
        assert!(dialog.is_response_enabled("insert"));
        assert_eq!(
            &*draft_recovery::take_secret(&entry).unwrap(),
            "Public fictional credential"
        );
        assert!(!draft_recovery::usable(&entry) && !dialog.is_response_enabled("insert"));
        entry.set_text(&"X".repeat(4097));
        assert!(!dialog.is_response_enabled("insert"));
        assert!(draft_recovery::take_secret(&entry).is_err());
        assert!(!draft_recovery::usable(&entry));
        let (_, _, recovery) = review_dialog("Public recovery-only destination", false, true);
        assert!(recovery.is_active() && !recovery.is_sensitive());
    }
}
