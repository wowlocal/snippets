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
fn remove_button(
    group: &adw::PreferencesGroup,
    selection: &Option<crate::key_store::capacity::Selection>,
    remove: &Rc<dyn Fn(Option<crate::key_store::capacity::Selection>)>,
    pending: bool,
) {
    if pending {
        return;
    }
    let Some(selection) = selection else {
        return;
    };
    let action = adw::ActionRow::builder()
        .title("Remove Saved Copy")
        .subtitle("Review the saved entry and any recovery files to discard.")
        .build();
    let button = gtk::Button::with_label("Review Removal…");
    button.set_valign(gtk::Align::Center);
    let selection = selection.clone();
    let remove = remove.clone();
    button.connect_clicked(move |_| remove(Some(selection.clone())));
    action.add_suffix(&button);
    group.add(&action);
}
pub(super) fn content(
    history: &Catalog,
    restore: Rc<dyn Fn(Selection)>,
    finish: Rc<dyn Fn(bool)>,
    remove: Rc<dyn Fn(Option<crate::key_store::capacity::Selection>)>,
    cleanup: Rc<dyn Fn()>,
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
    if history.maintenance.is_some() {
        let unused = history.maintenance.as_ref().is_some_and(|summary| {
            summary.section == crate::key_store::capacity::Section::UnusedImages
        });
        let pending = adw::PreferencesGroup::builder().title(if unused { "Recovery File Cleanup Needs Finishing" } else { "History Removal Needs Finishing" }).description("A reviewed removal was saved. Finish it before changing library keys or restoring saved changes.").build();
        let action = adw::ActionRow::builder()
            .title(if unused {
                "Finish Recovery File Cleanup"
            } else {
                "Finish Saved Removal"
            })
            .build();
        let button = gtk::Button::with_label("Review and Finish…");
        let remove = remove.clone();
        button.connect_clicked(move |_| remove(None));
        action.add_suffix(&button);
        pending.add(&action);
        panel.append(&pending);
    }
    if history.maintenance.is_none() && history.active.is_some() && !history.creations_unavailable {
        let unused = adw::PreferencesGroup::builder().title("Unused Recovery Files").description("Interrupted operations can leave encrypted files outside saved history. Review them before deciding whether to discard them.").build();
        let action = adw::ActionRow::builder()
            .title("Review Unused Recovery Files")
            .subtitle("Saved history and unfinished operations stay protected.")
            .build();
        let button = gtk::Button::with_label("Review Cleanup…");
        button.connect_clicked(move |_| cleanup());
        action.add_suffix(&button);
        unused.add(&action);
        panel.append(&unused);
    }
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
        remove_button(
            &switches,
            &saved.removal,
            &remove,
            history.maintenance.is_some(),
        );
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
            && history.maintenance.is_none()
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
        remove_button(
            &restores,
            &saved.removal,
            &remove,
            history.maintenance.is_some(),
        );
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
        if saved.needs_completion && history.maintenance.is_none() {
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
    let creations = group(
        &panel,
        "Library Creation Receipts",
        history.creations.len(),
        history.usage.creations,
    );
    creations.set_description(Some(&format!(
        "{} of {MAX_ENTRIES} saved entries · {} KiB of 64 KiB",
        history.creations.len(),
        history.usage.creations.div_ceil(1024)
    )));
    if history.creations_unavailable {
        creations.set_description(Some(&format!(
            "Protected history retained · {} KiB of 64 KiB",
            history.usage.creations.div_ceil(1024)
        )));
        row(
            &creations,
            "Saved creation history cannot be read",
            "The protected copy is kept. It cannot be removed until its format and ownership are understood.",
        );
    } else if history.creations.is_empty() {
        row(
            &creations,
            "No saved creations",
            "Creating a library keeps its original request until the result is known.",
        );
    }
    for (index, saved) in history.creations.iter().enumerate().rev() {
        let mut detail = saved.library.as_ref().map(library).unwrap_or_else(|| {
            "The original request is retained. Reconnect to its account in Account & Recovery to check the result.".into()
        });
        if let Some(source) = &saved.source {
            detail.push_str(&format!("\n\nCreated beside:\n{}", library(source)));
        }
        if saved.phase == CreationPhase::Created && saved.removal.is_none() {
            detail.push_str(
                "\n\nKept while needed by current library admission or unfinished key setup.",
            );
        }
        row(
            &creations,
            &format!(
                "Creation {} · {}",
                index + 1,
                match saved.phase {
                    CreationPhase::Requested => "result needs checking",
                    CreationPhase::Created => "library created",
                }
            ),
            &detail,
        );
        remove_button(
            &creations,
            &saved.removal,
            &remove,
            history.maintenance.is_some(),
        );
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
        remove_button(
            &pairing,
            &saved.removal,
            &remove,
            history.maintenance.is_some(),
        );
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
        remove_button(
            &first,
            &saved.removal,
            &remove,
            history.maintenance.is_some(),
        );
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        cloud::{Binding, ServerURL},
        key_store::{
            KeyBinding,
            capacity::{Section, Summary},
        },
    };
    use std::cell::Cell;
    fn button(widget: &gtk::Widget, label: &str) -> Option<gtk::Button> {
        if let Some(button) = widget.downcast_ref::<gtk::Button>()
            && button.label().as_deref() == Some(label)
        {
            return Some(button.clone());
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            if let Some(button) = button(&widget, label) {
                return Some(button);
            }
            child = widget.next_sibling();
        }
        None
    }
    #[test]
    #[ignore = "explicit native history removal/cleanup on public private-keyring/private-PAM fixtures; invoke tests/account-live.sh --history-maintenance"]
    fn native_history_cleanup_controls_respect_saved_consent_and_empty_key_state() {
        if std::env::var_os("SNIPPETS_HISTORY_INSPECT_ONLY").is_some() {
            crate::account_ui::live_tests::history_maintenance::run();
            return;
        }
        adw::init().expect("graphical display");
        let mut history = Catalog::default();
        let calls = Rc::new(Cell::new(0));
        let cleanup: Rc<dyn Fn()> = {
            let calls = calls.clone();
            Rc::new(move || calls.set(calls.get() + 1))
        };
        let content_for = |history: &Catalog| {
            content(
                history,
                Rc::new(|_| {}),
                Rc::new(|_| {}),
                Rc::new(|_| {}),
                cleanup.clone(),
            )
        };
        let panel = content_for(&history);
        assert!(button(panel.upcast_ref(), "Review Cleanup…").is_none());
        let binding = KeyBinding::new(
            ServerURL::parse("https://public.example.test").unwrap(),
            uuid::Uuid::from_u128(1),
            uuid::Uuid::from_u128(2),
            (
                Binding::from_checkpoint([3; 32]),
                Binding::from_checkpoint([4; 32]),
            ),
            1,
        )
        .unwrap();
        history.active = Some(SavedLibrary::new(&binding));
        let panel = content_for(&history);
        button(panel.upcast_ref(), "Review Cleanup…")
            .unwrap()
            .emit_clicked();
        assert_eq!(calls.get(), 1);
        history.creations_unavailable = true;
        let panel = content_for(&history);
        assert!(button(panel.upcast_ref(), "Review Cleanup…").is_none());
        history.creations_unavailable = false;
        history.maintenance = Some(Summary {
            libraries: vec![SavedLibrary::new(&binding)],
            section: Section::UnusedImages,
            entry: 0,
            protected_bytes: 0,
            encrypted_images: 1,
            encrypted_bytes: 32,
        });
        let panel = content_for(&history);
        assert!(button(panel.upcast_ref(), "Review Cleanup…").is_none());
        assert!(button(panel.upcast_ref(), "Review and Finish…").is_some());
        crate::account_ui::live_tests::history_maintenance::run();
    }
}
