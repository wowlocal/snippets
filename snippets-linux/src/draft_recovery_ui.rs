//! Explicit old/current vault authentication. Workers return ciphertext only.
use super::*;
use crate::desktop::SessionWitness;
use gtk::glib::translate::ToGlibPtr;
use std::{
    ffi::CStr,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::SystemTime,
};
const EXPIRED: Error =
    Error("Draft recovery expired or was cancelled. The original encrypted draft is retained.");
#[derive(Clone)]
pub(super) struct Authorization {
    cancelled: Arc<AtomicBool>,
    witness: SessionWitness,
    epoch: u64,
    started: Duration,
    wall: SystemTime,
}

impl Authorization {
    fn new(witness: SessionWitness) -> Result<Self> {
        let (state, epoch) = witness.snapshot();
        if state != SessionState::Unlocked {
            return Err(EXPIRED);
        }
        Ok(Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            witness,
            epoch,
            started: crate::clock::uptime().ok_or(EXPIRED)?,
            wall: SystemTime::now(),
        })
    }
    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub(super) fn validate(&self) -> Result<()> {
        let now = crate::clock::uptime().ok_or(EXPIRED)?;
        self.validate_at(now, SystemTime::now())
    }
    fn validate_at(&self, now: Duration, wall: SystemTime) -> Result<()> {
        let wall = wall.duration_since(self.wall).map_err(|_| EXPIRED)?;
        if self.cancelled.load(Ordering::Acquire)
            || now < self.started
            || now - self.started >= Duration::from_secs(120)
            || wall >= Duration::from_secs(120)
            || self.witness.snapshot() != (SessionState::Unlocked, self.epoch)
        {
            return Err(EXPIRED);
        }
        Ok(())
    }
}
fn take_secret(entry: &gtk::PasswordEntry) -> Result<Zeroizing<String>> {
    let result = unsafe {
        let pointer =
            gtk::ffi::gtk_editable_get_text(entry.upcast_ref::<gtk::Editable>().to_glib_none().0);
        let bytes = CStr::from_ptr(pointer).to_bytes();
        if bytes.len() > 4096 {
            Err(Error("Vault credentials must be within the 4 KiB limit."))
        } else {
            std::str::from_utf8(bytes)
                .map(|value| Zeroizing::new(value.to_owned()))
                .map_err(|_| EXPIRED)
        }
    };
    entry.set_text("");
    result
}
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
    pass: bool,
    recovery: bool,
) -> (gtk::PasswordEntry, gtk::CheckButton) {
    fields.append(&label(title));
    let input = gtk::PasswordEntry::builder()
        .show_peek_icon(false)
        .hexpand(true)
        .build();
    input.update_property(&[gtk::accessible::Property::Label(title)]);
    let mode = gtk::CheckButton::with_label("Use recovery key");
    mode.set_active(!pass);
    mode.set_sensitive(pass && recovery);
    fields.append(&input);
    fields.append(&mode);
    (input, mode)
}
impl Workspace {
    pub(super) fn cancel_draft_recovery(&self) {
        if let Some((authorization, _)) = self.draft_authorization.borrow_mut().take() {
            authorization.cancel();
            self.generation.set(self.generation.get().wrapping_add(1));
        }
        let dialog = self.draft_dialog.borrow_mut().take();
        if let Some((dialog, entries)) = dialog {
            for entry in entries {
                entry.set_text("");
            }
            dialog.force_close();
        }
    }
    pub fn prepare_quit(&self) -> bool {
        self.cancel_draft_recovery();
        !self.draft_worker.get()
    }
    pub(super) fn recover_draft(self: &Rc<Self>) {
        if self.busy.get() || !self.desktop_allowed() || !self.editor.is_foreign() {
            return;
        }
        self.busy.set(true);
        self.update();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = this.draft_recovery_dialog().await;
            this.cancel_draft_recovery();
            this.draft_worker.set(false);
            this.busy.set(false);
            this.update();
            if let Err(error) = result {
                this.toast(&error.to_string());
            }
        });
    }
    async fn draft_recovery_dialog(self: &Rc<Self>) -> Result<()> {
        let metadata = self.draft_metadata().ok_or(EXPIRED)?;
        let request = self.editor.prepare_recovery(metadata.clone())?;
        let source_pass = request.source_has_passphrase();
        let source_recovery = request.source_has_recovery();
        let target_pass = request.target_has_passphrase();
        let target_recovery = request.target_has_recovery();
        if !(source_pass || source_recovery) || !(target_pass || target_recovery) {
            return Err(Error(
                "Both vaults need a passphrase or recovery key to recover this draft.",
            ));
        }
        let authorization = Authorization::new(self.desktop.as_ref().ok_or(EXPIRED)?.witness())?;
        let generation = self.generation.get();
        let desktop_epoch = self.desktop_epoch();
        *self.draft_authorization.borrow_mut() =
            Some((authorization.clone(), self.vault.borrow().generation()));
        let dialog = adw::AlertDialog::builder().heading("Recover Previous Vault Draft")
            .body("Authenticate the previous and current vaults to keep this unsaved content as a new encrypted draft. Existing entries stay intact. Review its metadata and choose Save afterward; a duplicate keyword must be changed before saving.").build();
        let fields = gtk::Box::new(gtk::Orientation::Vertical, 12);
        let (source, old_mode) = credential(
            &fields,
            "Previous vault passphrase or recovery key",
            source_pass,
            source_recovery,
        );
        let (target, new_mode) = credential(
            &fields,
            "Current vault passphrase or recovery key",
            target_pass,
            target_recovery,
        );
        dialog.set_extra_child(Some(&fields));
        dialog.add_responses(&[("cancel", "Cancel"), ("recover", "Recover Draft")]);
        dialog.set_close_response("cancel");
        dialog.set_default_response(Some("cancel"));
        dialog.set_response_enabled("recover", false);
        for input in [&source, &target] {
            let weak = dialog.downgrade();
            let first = source.downgrade();
            let second = target.downgrade();
            input.connect_changed(move |_| {
                if let (Some(dialog), Some(first), Some(second)) =
                    (weak.upgrade(), first.upgrade(), second.upgrade())
                {
                    dialog.set_response_enabled("recover", usable(&first) && usable(&second));
                }
            });
        }
        *self.draft_dialog.borrow_mut() =
            Some((dialog.clone(), vec![source.clone(), target.clone()]));
        let choice = dialog.choose_future(Some(&self.window)).await;
        self.draft_dialog.borrow_mut().take();
        let source_secret = take_secret(&source);
        let target_secret = take_secret(&target);
        if choice != "recover" {
            return Ok(());
        }
        let source_secret = source_secret?;
        let target_secret = target_secret?;
        authorization.validate()?;
        if generation != self.generation.get()
            || desktop_epoch != self.desktop_epoch()
            || !self.window.is_active()
            || !self.window.is_visible()
        {
            return Err(EXPIRED);
        }
        self.draft_worker.set(true);
        self.status.set_label("Recovering the encrypted draft…");
        let guard = authorization.clone();
        let source_recovery = old_mode.is_active();
        let target_recovery = new_mode.is_active();
        let prepared = worker(move || {
            request.authenticate(
                &source_secret,
                source_recovery,
                &target_secret,
                target_recovery,
                &|| guard.validate(),
            )
        })
        .await?;
        self.draft_worker.set(false);
        authorization.validate()?;
        if generation != self.generation.get()
            || desktop_epoch != self.desktop_epoch()
            || !self.window.is_active()
            || !self.window.is_visible()
            || self.draft_metadata().as_ref() != Some(&metadata)
        {
            return Err(EXPIRED);
        }
        self.editor.finish_recovery(prepared)?;
        let recovered = self.editor.metadata().ok_or(EXPIRED)?;
        self.selected.set(Some(recovered.id));
        self.populate(&recovered);
        self.dirty.set(false);
        self.reveal.set_active(false);
        self.status
            .set_label("Recovered encrypted draft · review metadata and choose Save.");
        self.refresh();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_authorization_requires_a_fresh_unlocked_epoch_and_permanent_cancellation() {
        let locked = SessionWitness::test(SessionState::Locked, 1);
        assert!(Authorization::new(locked).is_err());
        let witness = SessionWitness::test(SessionState::Unlocked, 1);
        let first = Authorization::new(witness.clone()).unwrap();
        first.validate().unwrap();
        witness.test_observe(SessionState::Locked);
        witness.test_observe(SessionState::Unlocked);
        assert!(first.validate().is_err());
        let second = Authorization::new(witness.clone()).unwrap();
        let worker = second.clone();
        second.cancel();
        witness.test_observe(SessionState::Unlocked);
        assert!(worker.validate().is_err());
    }
    #[test]
    fn recovery_deadlines_reject_elapsed_wall_monotonic_and_backwards_clocks() {
        let witness = SessionWitness::test(SessionState::Unlocked, 1);
        let auth = Authorization::new(witness).unwrap();
        assert!(
            auth.validate_at(auth.started + Duration::from_secs(120), auth.wall)
                .is_err()
        );
        assert!(
            auth.validate_at(auth.started, auth.wall + Duration::from_secs(120))
                .is_err()
        );
        assert!(
            auth.validate_at(auth.started, auth.wall - Duration::from_secs(60))
                .is_err()
        );
        let mut backwards = auth.clone();
        backwards.started += Duration::from_secs(60);
        assert!(backwards.validate_at(auth.started, auth.wall).is_err());
    }
    #[test]
    #[ignore = "requires a graphical display; fictional fields only, no keys/keyring/PAM/clipboard/network"]
    fn native_recovery_cancellation_clears_both_credentials_and_uses_bounded_borrowed_input() {
        adw::init().expect("graphical display");
        let root = tempfile::tempdir().unwrap();
        let library = Library::open(root.path().into()).unwrap();
        let app = adw::Application::builder()
            .application_id("com.khm.snippets.linux.DraftRecoverySmoke")
            .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
            .build();
        app.register(None::<&gtk::gio::Cancellable>).unwrap();
        let workspace = Workspace::new(&app, &library).unwrap();
        workspace.window.present();
        let fields = gtk::Box::new(gtk::Orientation::Vertical, 12);
        let (source, source_mode) =
            credential(&fields, "Public previous vault fixture", false, true);
        let (target, _) = credential(&fields, "Public current vault fixture", true, true);
        assert!(source_mode.is_active() && !source_mode.is_sensitive());
        source.set_text(&"x".repeat(4097));
        assert!(!usable(&source));
        assert!(take_secret(&source).is_err() && source.text().is_empty());
        source.set_text("Public previous passphrase");
        assert!(usable(&source));
        assert_eq!(
            take_secret(&source).unwrap().as_str(),
            "Public previous passphrase"
        );
        assert!(source.text().is_empty());
        let dialog = adw::AlertDialog::builder()
            .heading("Public recovery fixture")
            .extra_child(&fields)
            .build();
        dialog.add_responses(&[("cancel", "Cancel")]);
        dialog.set_close_response("cancel");
        dialog.present(Some(&workspace.window));
        source.set_text("Public previous passphrase");
        target.set_text("Public current passphrase");
        let auth = Authorization::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap();
        *workspace.draft_authorization.borrow_mut() =
            Some((auth.clone(), workspace.vault.borrow().generation()));
        *workspace.draft_dialog.borrow_mut() = Some((dialog, vec![source.clone(), target.clone()]));
        workspace.cancel_draft_recovery();
        assert!(source.text().is_empty() && target.text().is_empty());
        assert!(auth.validate().is_err() && workspace.draft_dialog.borrow().is_none());
        assert!(workspace.prepare_quit());
        assert!(!root.path().join("Vault").exists() && !root.path().join("Sync").exists());
        workspace.window.close();
    }
}
