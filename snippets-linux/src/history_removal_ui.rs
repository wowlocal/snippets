//! Native review before one fresh-purpose authorization. No cleanup runs from
//! inspection, cancellation, focus loss or an automatic synchronization tick.
use super::*;
use crate::key_store::capacity::{Section, Selection};
use crate::local_auth;
enum Action {
    History(Option<Selection>),
    Cleanup,
}

impl AccountWindow {
    pub(super) fn remove_saved_history(self: &Rc<Self>, selection: Option<Selection>) {
        self.review_history_removal(Action::History(selection));
    }
    pub(super) fn cleanup_recovery_files(self: &Rc<Self>) {
        self.review_history_removal(Action::Cleanup);
    }
    fn review_history_removal(self: &Rc<Self>, action: Action) {
        if self.busy.get() {
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = async {
                let preparation = this.new_restoration_preparation()?;
                *this.restoration_preparation.borrow_mut() = Some(preparation.clone());
                let reply = this.execute(match action {
                    Action::History(selection) => Command::PrepareHistoryRemoval { selection, preparation: preparation.clone() },
                    Action::Cleanup => Command::PrepareRecoveryFileCleanup(preparation.clone()),
                }).await?;
                if matches!(reply, Reply::NoUnusedRecoveryFiles) { return Ok(reply); }
                let Reply::HistoryRemovalReview { token,summary,target } = reply else { return Err(Failure::InvalidState); };
                preparation.validate()?;
                if generation != this.generation.get() || !this.window.is_active() { return Err(local_auth::Failure::Cancelled.into()); }
                let name = match summary.section { Section::Switches => "library switch", Section::Pairing => "key request", Section::FirstKeys => "first-key setup", Section::Restorations => "restoration", Section::Creations => "library creation receipt", Section::UnusedImages => "unused recovery files" };
                let resume = matches!(target.purpose(), Purpose::ResumeHistoryRemoval | Purpose::ResumeRecoveryFileCleanup);
                let libraries = summary.libraries.iter().map(|library| format!("{}\nLibrary {} · key version {}",library.server().for_secure_storage(),library.id(),library.epoch())).collect::<Vec<_>>().join("\n\n");
                let cleanup = summary.section == Section::UnusedImages;
                let body = if cleanup { format!("Current library\n{libraries}\n\nDiscard {} encrypted recovery files ({} KiB) that no validated saved history references. These can be left by an interrupted operation before its history entry was saved.\n\nTheir previous changes may have no other copy, and this computer may no longer have the old key needed to open them. Save any recovery files you still need before authorizing cleanup. Saved history, unfinished operations, current records and active keys are kept. Newly created files are not part of this review.", summary.encrypted_images, summary.encrypted_bytes.div_ceil(1024)) } else if summary.section == Section::Creations { format!(
                    "Saved {name} {}\n\n{libraries}\n\nThis removes one completed creation receipt from this computer and frees about {} KiB of protected history. It contains the original request identity and the metadata returned when the library was created.\n\nThe remote library, its records, current local files and active keys are kept. You can find the remote library again by reconnecting to the account that owns it. Unfinished creation and key requests cannot be removed here.", summary.entry,summary.protected_bytes.div_ceil(1024)) } else { format!(
                    "Saved {name} {}\n\n{libraries}\n\nThis removes one history entry, its saved keys and recovery capabilities, and {} encrypted recovery files ({} KiB). It frees about {} KiB of protected history.\n\nHistorical changes and keys in this entry may have no other copy. Save any recovery material you still need before removing it. Current library files and active keys are kept.", summary.entry,summary.encrypted_images,summary.encrypted_bytes.div_ceil(1024),summary.protected_bytes.div_ceil(1024))
                };
                let dialog = adw::AlertDialog::builder().heading(if cleanup && resume { "Finish Recovery File Cleanup?" } else if cleanup { "Discard Unused Recovery Files?" } else if resume {"Finish Saved History Removal?"} else if summary.section == Section::Creations {"Remove This Saved Receipt?"} else {"Remove This Saved Copy?"}).body(body).build();
                dialog.set_body_use_markup(false);
                dialog.add_responses(&[("cancel","Cancel"),("remove",if resume {"Authorize and Finish…"} else {"Authorize Removal…"})]);
                dialog.set_response_appearance("remove",adw::ResponseAppearance::Destructive); dialog.set_default_response(Some("cancel")); dialog.set_close_response("cancel");
                *this.restoration_dialog.borrow_mut() = Some((dialog.clone(),Vec::new()));
                let response = dialog.choose_future(Some(&this.window)).await;
                this.restoration_dialog.borrow_mut().take();
                preparation.validate()?;
                if response != "remove" || generation != this.generation.get() || !this.window.is_active() { return Err(local_auth::Failure::Cancelled.into()); }
                let permit = this.authorize_target(target,generation).await?;
                preparation.validate()?;
                this.execute(Command::CommitHistoryRemoval { token,permit }).await
            }.await;
            this.busy(false);
            if generation != this.generation.get() {
                return;
            }
            this.cancel_sensitive();
            match result {
                Ok(reply) => this.apply(reply),
                Err(failure) => this.failure(failure),
            }
        });
    }
}
