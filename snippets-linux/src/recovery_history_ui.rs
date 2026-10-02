//! Native presentation of ephemeral, validated recovery metadata only.
use crate::key_store::restoration::Selection;
use crate::{
    account_review::{ActiveImage, RetainedImages},
    key_store::{KitStatus, history::*, initial_candidate},
};
use adw::prelude::*;
use std::rc::Rc;

fn library(value: &SavedLibrary) -> String {
    format!(
        "{}\nLibrary {} · key version {}",
        value.server().for_secure_storage(),
        value.id(),
        value.epoch()
    )
}
fn recovery(status: KitStatus) -> &'static str {
    match status {
        KitStatus::None => "No recovery presentation retained",
        KitStatus::AwaitingPresentation => "Recovery copy waiting to be saved",
        KitStatus::VerifiedCurrent => "Recovery copy verified when saved",
        KitStatus::Replaced => "Recovery copy was replaced when last checked",
    }
}
fn key(value: &SavedKey) -> String {
    format!(
        "{}\n{}{}",
        library(&value.library),
        recovery(value.recovery),
        if value.active { " · current key" } else { "" }
    )
}
fn row(group: &adw::PreferencesGroup, title: &str, subtitle: &str) {
    let row = adw::ActionRow::builder()
        .title(title)
        .subtitle(subtitle)
        .build();
    row.set_use_markup(false);
    row.set_subtitle_lines(0);
    group.add(&row);
}
fn group(panel: &gtk::Box, title: &str, count: usize, bytes: usize) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title(title)
        .description(format!(
            "{count} of {MAX_ENTRIES} saved entries · {} KiB of 128 KiB",
            bytes.div_ceil(1024)
        ))
        .build();
    panel.append(&group);
    group
}
pub(super) fn content(
    history: &Catalog,
    restore: Rc<dyn Fn(Selection)>,
    finish: Rc<dyn Fn(bool)>,
) -> gtk::Box {
    let layout = gtk::Box::new(gtk::Orientation::Vertical, 0);
    layout.append(&adw::HeaderBar::new());
    let panel = gtk::Box::new(gtk::Orientation::Vertical, 20);
    panel.set_margin_start(20);
    panel.set_margin_end(20);
    panel.set_margin_top(16);
    panel.set_margin_bottom(24);
    let intro = gtk::Label::new(Some(
        "Previous keys and recovery states are kept on this computer. Saved metadata reflects the last local receipt. Reconnect and select a library in Account & Recovery to verify current access and start a fresh review.",
    ));
    intro.set_wrap(true);
    intro.set_xalign(0.0);
    panel.append(&intro);
    let current = adw::PreferencesGroup::builder()
        .title("Current Library Key")
        .build();
    panel.append(&current);
    row(
        &current,
        if history.active.is_some() {
            "Key stored on this computer"
        } else {
            "No current library key"
        },
        &history
            .active
            .as_ref()
            .map(library)
            .unwrap_or_else(|| "Connect to an account to set up or receive a key.".into()),
    );
    let switches = group(
        &panel,
        "Saved Library Switches",
        history.switches.len(),
        history.usage.switches,
    );
    if history.switches.is_empty() {
        row(
            &switches,
            "No saved switches",
            "Confirmed library switches keep their previous keys and recovery states here.",
        );
    }
    for (index, saved) in history.switches.iter().enumerate().rev() {
        row(
            &switches,
            &format!(
                "Switch {} · {}",
                index + 1,
                match saved.phase {
                    SwitchPhase::Pending => "needs finishing",
                    SwitchPhase::Completed => "finished locally",
                    SwitchPhase::Cancelled => "cancelled",
                }
            ),
            &format!(
                "Previous key\n{}\n\nReviewed key\n{}",
                key(&saved.source),
                key(&saved.target)
            ),
        );
        row(
            &switches,
            "Saved Local Changes",
            &format!(
                "{} local records · {} retained changes · {} conflict copies · {} previous confirmations",
                saved.summary.local_records,
                saved.summary.local_intents,
                saved.summary.preservation_copies,
                saved.summary.previous_confirmations
            ),
        );
        row(
            &switches,
            "Previous Recovery Capabilities",
            &format!(
                "Pairing request: {} · library creation: {} · signed action: {}",
                if saved.previous.pairing {
                    "kept"
                } else {
                    "none"
                },
                if saved.previous.creation {
                    "kept"
                } else {
                    "none"
                },
                if saved.previous.signed_action {
                    "kept"
                } else {
                    "none"
                }
            ),
        );
        row(
            &switches,
            "Encrypted Recovery States",
            match saved.images {
                RetainedImages::Verified { active } => match active {
                    ActiveImage::Source => {
                        "Both saved states verified. The previous journal is still current."
                    }
                    ActiveImage::Target => {
                        "Both saved states verified. The reviewed journal is current."
                    }
                    ActiveImage::Other => {
                        "Both saved states verified. The current journal differs from both saved states."
                    }
                    ActiveImage::Missing => {
                        "Both saved states verified. The current journal is missing."
                    }
                    ActiveImage::Unreadable => {
                        "Both saved states verified. The current journal cannot be read safely."
                    }
                },
                RetainedImages::Missing => {
                    "A saved recovery state is missing. Keys remain in protected storage."
                }
                RetainedImages::Invalid => {
                    "Saved recovery states could not be authenticated. Keys remain in protected storage."
                }
                RetainedImages::Unreadable => {
                    "Saved recovery states cannot be read safely. Keys remain in protected storage."
                }
            },
        );
        if saved.phase != SwitchPhase::Pending
            && matches!(saved.images, RetainedImages::Verified { .. })
        {
            let action = adw::ActionRow::builder()
                .title("Restore Saved Local Changes")
                .subtitle("Review the saved changes and keep current versions before restoring.")
                .build();
            action.set_use_markup(false);
            let button = gtk::Button::with_label("Review…");
            button.set_valign(gtk::Align::Center);
            let restore = restore.clone();
            let selection = saved.selection.clone();
            button.connect_clicked(move |_| restore(selection.clone()));
            action.add_suffix(&button);
            switches.add(&action);
        }
    }
    let restores = group(
        &panel,
        "Saved Restorations",
        history.restorations.len(),
        history.usage.restorations,
    );
    if history.restorations.is_empty() {
        row(
            &restores,
            "No saved restorations",
            "Restoring saved changes keeps current versions and a recovery receipt here.",
        );
    }
    for (index, saved) in history.restorations.iter().enumerate().rev() {
        row(
            &restores,
            &format!(
                "Restoration {} · {}",
                index + 1,
                match saved.phase {
                    SwitchPhase::Pending => "needs finishing",
                    SwitchPhase::Completed => "finished locally",
                    SwitchPhase::Cancelled => "cancelled",
                }
            ),
            &format!(
                "{}\n{} restored records · {} preserved versions",
                library(&saved.library),
                saved.summary.restored_records,
                saved.summary.preserved_versions
            ),
        );
        if saved.needs_completion {
            let actions = adw::ActionRow::builder()
                .title("Complete Saved Restoration")
                .build();
            actions.set_use_markup(false);
            for (cancel, label) in [(false, "Finish…"), (true, "Cancel…")] {
                if cancel && saved.phase != SwitchPhase::Pending {
                    continue;
                }
                let button = gtk::Button::with_label(label);
                button.set_valign(gtk::Align::Center);
                let finish = finish.clone();
                button.connect_clicked(move |_| finish(cancel));
                actions.add_suffix(&button);
            }
            restores.add(&actions);
        }
    }
    let pairing = group(
        &panel,
        "Library Key Requests",
        history.pairing.len(),
        history.usage.pairing,
    );
    if history.pairing.is_empty() {
        row(
            &pairing,
            "No saved key requests",
            "Request a library key from a trusted device after selecting its library.",
        );
    }
    for (index, saved) in history.pairing.iter().enumerate().rev() {
        row(
            &pairing,
            &format!(
                "Request {} · {}",
                index + 1,
                match saved.phase {
                    PairingPhase::Creating => "creation needs checking",
                    PairingPhase::Waiting => "waiting for approval",
                    PairingPhase::Claimed => "received key needs review",
                    PairingPhase::Ready => "received key kept",
                    PairingPhase::Cancelling => "cancellation needs finishing",
                    PairingPhase::Cancelled => "cancelled",
                }
            ),
            &library(&saved.library),
        );
    }
    let first = group(
        &panel,
        "First Library Keys",
        history.first_keys.len(),
        history.usage.first_keys,
    );
    if history.first_keys.is_empty() {
        row(
            &first,
            "No saved first-key setups",
            "An empty library's first keys are retained here before setup starts.",
        );
    }
    for (index, saved) in history.first_keys.iter().enumerate().rev() {
        row(
            &first,
            &format!(
                "Setup {} · {}",
                index + 1,
                match saved.phase {
                    initial_candidate::Status::Prepared => "prepared",
                    initial_candidate::Status::Sent => "server result needs checking",
                    initial_candidate::Status::Ready { .. } => "key kept for review",
                    initial_candidate::Status::Lost => "another device initialized the library",
                }
            ),
            &key(&saved.key),
        );
    }
    layout.append(
        &gtk::ScrolledWindow::builder()
            .child(&panel)
            .vexpand(true)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .build(),
    );
    layout
}
