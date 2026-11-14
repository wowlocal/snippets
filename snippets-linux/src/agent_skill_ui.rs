//! Settings › General › "Agent Skill" and "Guide and Rules": the same model as the Mac's
//! Settings › Integrations and `snippets-cli skill status`, from `crate::agent_skill`.
//!
//! Changes apply at once, as elsewhere in GNOME settings. A foreign `SKILL.md` is shown and
//! never replaced; a remembered folder that has gone is shown and only removable.

use super::*;
use crate::agent_skill::{self, Environment, FileState, Files, Place, PlaceState, PlaceStatus};

pub(super) struct AgentSkillControls {
    window: adw::PreferencesWindow,
    skills: adw::PreferencesGroup,
    rows: RefCell<Vec<gtk::Widget>>,
    files: adw::ActionRow,
    reset: gtk::Button,
}

const INTRO: &str = "Teaches Claude Code, Codex and other coding agents to use snippets-cli. Rules are advice to agents; secure snippets still need your approval.";
/// A standing state on a row; "Not changed: …" is only the result of an action.
const FOREIGN: &str = "Another skill named snippets-cli is already here.";

impl AgentSkillControls {
    pub(super) fn new(window: &adw::PreferencesWindow, page: &adw::PreferencesPage) -> Rc<Self> {
        let skills = adw::PreferencesGroup::builder()
            .title("Agent Skill")
            .description(INTRO)
            .build();
        let add_folder = gtk::Button::builder()
            .label("Add Folder…")
            .valign(gtk::Align::Center)
            .css_classes(["flat"])
            .build();
        skills.set_header_suffix(Some(&add_folder));

        let files_group = adw::PreferencesGroup::builder()
            .title("Guide and Rules")
            .description("What agents read. Edit guide.md and rules.md in any editor; the read-only originals stay beside the app's data.")
            .build();
        let files = adw::ActionRow::builder()
            .use_markup(false)
            .title("guide.md and rules.md")
            .build();
        let open_folder = gtk::Button::builder()
            .label("Open Folder")
            .valign(gtk::Align::Center)
            .build();
        let reset = gtk::Button::builder()
            .label("Reset…")
            .valign(gtk::Align::Center)
            .build();
        files.add_suffix(&open_folder);
        files.add_suffix(&reset);
        files_group.add(&files);

        page.add(&skills);
        page.add(&files_group);

        let this = Rc::new(Self {
            window: window.clone(),
            skills,
            rows: RefCell::new(Vec::new()),
            files,
            reset: reset.clone(),
        });

        let weak = Rc::downgrade(&this);
        add_folder.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.add_folder().await });
            }
        });
        let weak = Rc::downgrade(&this);
        open_folder.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.open_folder();
            }
        });
        let weak = Rc::downgrade(&this);
        reset.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.reset().await });
            }
        });
        // The rules may have changed in an editor; bring the installed descriptions up to
        // date whenever Settings comes back to the front.
        let weak = Rc::downgrade(&this);
        window.connect_is_active_notify(move |window| {
            if window.is_active()
                && let Some(this) = weak.upgrade()
            {
                this.reload();
            }
        });
        this.reload();
        this
    }

    fn toast(&self, message: &str) {
        self.window.add_toast(adw::Toast::new(message));
    }

    pub(super) fn reload(self: &Rc<Self>) {
        let Some(environment) = Environment::current() else {
            self.toast("The home folder could not be found, so the agent skill is unavailable.");
            return;
        };
        if let Ok(places) = agent_skill::installed_places(&environment)
            && !places.is_empty()
        {
            // Writes nothing when the descriptions already match.
            let _ = agent_skill::install(&environment, &places);
        }
        for row in self.rows.borrow_mut().drain(..) {
            self.skills.remove(&row);
        }
        let status = match agent_skill::status(&environment) {
            Ok(status) => status,
            Err(error) => {
                self.toast(&format!("Could not read the agent skill status: {error}"));
                return;
            }
        };
        self.files
            .set_subtitle(&files_text(&environment, &status.files));
        self.reset.set_sensitive(!status.files.are_defaults());
        for place in status.places {
            let row = self.make_row(&environment, place);
            self.skills.add(&row);
            self.rows.borrow_mut().push(row);
        }
    }

    fn make_row(self: &Rc<Self>, environment: &Environment, status: PlaceStatus) -> gtk::Widget {
        let folder = environment.display(&status.skills_folder);
        match status.place.clone() {
            Place::Target(target) => {
                let row = adw::SwitchRow::builder()
                    .use_markup(false)
                    .title(target.display_name())
                    .subtitle(if status.state == PlaceState::Foreign {
                        format!("{folder} · {FOREIGN}")
                    } else {
                        folder
                    })
                    .active(status.state == PlaceState::Installed)
                    .sensitive(status.state != PlaceState::Foreign)
                    .build();
                let weak = Rc::downgrade(self);
                row.connect_active_notify(move |row| {
                    let Some(this) = weak.upgrade() else { return };
                    let place = Place::Target(target);
                    let install = row.is_active();
                    // Rebuilding removes this row; finish its signal first.
                    glib::idle_add_local_once(move || this.apply(&place, install));
                });
                row.upcast()
            }
            Place::Folder(path) => {
                let title = agent_skill::folder_title(&path);
                let row = adw::ActionRow::builder()
                    .use_markup(false)
                    .title(title)
                    .subtitle(match status.state {
                        PlaceState::Missing => format!("{folder} · Folder not found"),
                        PlaceState::Foreign => format!("{folder} · {FOREIGN}"),
                        PlaceState::Installed => folder,
                        PlaceState::NotInstalled => format!("{folder} · Not installed"),
                    })
                    .build();
                let icon = gtk::Image::from_icon_name(if status.state == PlaceState::Missing {
                    "dialog-warning-symbolic"
                } else {
                    "folder-symbolic"
                });
                row.add_prefix(&icon);
                let remove = gtk::Button::builder()
                    .icon_name("user-trash-symbolic")
                    .tooltip_text("Remove skill from this folder")
                    .valign(gtk::Align::Center)
                    .css_classes(["flat"])
                    .build();
                row.add_suffix(&remove);
                let weak = Rc::downgrade(self);
                remove.connect_clicked(move |_| {
                    if let Some(this) = weak.upgrade() {
                        let place = Place::Folder(path.clone());
                        glib::idle_add_local_once(move || this.apply(&place, false));
                    }
                });
                row.upcast()
            }
        }
    }

    fn apply(self: &Rc<Self>, place: &Place, install: bool) {
        let Some(environment) = Environment::current() else {
            return;
        };
        let places = std::slice::from_ref(place);
        let result = if install {
            agent_skill::install(&environment, places)
        } else {
            agent_skill::uninstall(&environment, places)
        };
        match result {
            Ok(changes) => {
                let outcome = changes.first().map(|c| c.outcome);
                match outcome {
                    Some(agent_skill::Outcome::Skipped) => {
                        self.toast("Not changed: another skill named snippets-cli is already here.")
                    }
                    Some(agent_skill::Outcome::Removed) => self.toast(&format!(
                        "Removed from {}.",
                        environment.display(&environment.skills_folder(place))
                    )),
                    Some(agent_skill::Outcome::Missing) => self.toast("That folder was not found."),
                    // A vanished folder: nothing to delete, but it leaves the list.
                    Some(agent_skill::Outcome::Absent) if matches!(place, Place::Folder(_)) => self
                        .toast(&format!(
                            "Removed {} from the list.",
                            environment.display(&environment.skills_folder(place))
                        )),
                    Some(agent_skill::Outcome::Wrote) => self
                        .toast("Installed. Restart running agent sessions to pick up the skill."),
                    _ => {}
                }
            }
            Err(error) => self.toast(&format!("Could not change the agent skill: {error}")),
        }
        self.reload();
    }

    async fn add_folder(self: Rc<Self>) {
        let dialog = gtk::FileDialog::builder()
            .title("Add Skills Folder")
            .accept_label("Add Folder")
            .build();
        let Ok(file) = dialog.select_folder_future(Some(&self.window)).await else {
            return;
        };
        let (Some(path), Some(environment)) = (file.path(), Environment::current()) else {
            return;
        };
        match agent_skill::resolve_folder(
            &path.to_string_lossy(),
            &environment.home,
            &environment,
            true,
        ) {
            Ok(place) => self.apply(&place, true),
            Err(error) => self.toast(&error.to_string()),
        }
    }

    /// Makes editable copies of the guide and rules if there are none yet, then shows them
    /// in the file manager, where the user opens them in any editor.
    fn open_folder(self: &Rc<Self>) {
        let Some(environment) = Environment::current() else {
            return;
        };
        if let Err(error) = agent_skill::create_editable_files(&environment) {
            self.toast(&format!("Could not create the guide and rules: {error}"));
            return;
        }
        let guide = environment.file_path(agent_skill::SkillFile::Guide);
        let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(guide)));
        let window = self.window.clone();
        launcher.open_containing_folder(
            Some(&self.window),
            gio::Cancellable::NONE,
            move |result| {
                if let Err(error) = result {
                    window.add_toast(adw::Toast::new(&format!(
                        "Could not open the folder: {}",
                        error.message()
                    )));
                }
            },
        );
        self.reload();
    }

    async fn reset(self: Rc<Self>) {
        let dialog = adw::AlertDialog::builder()
            .heading("Reset the agent guide and rules?")
            .body("Snippets puts the default guide.md and rules.md back. Your versions are kept beside them as guide.md.bak and rules.md.bak.")
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("reset", "Reset")]);
        dialog.set_response_appearance("reset", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        if dialog.choose_future(Some(&self.window)).await != "reset" {
            return;
        }
        let Some(environment) = Environment::current() else {
            return;
        };
        match agent_skill::reset_files(&environment) {
            Ok(backups) if backups.is_empty() => {
                self.toast("The guide and rules are the defaults.")
            }
            Ok(backups) => {
                let names: Vec<_> = backups
                    .iter()
                    .filter_map(|b| b.file_name().map(|n| n.to_string_lossy().into_owned()))
                    .collect();
                self.toast(&format!(
                    "Put the defaults back. Your versions are kept as {}.",
                    names.join(" and ")
                ));
            }
            Err(error) => self.toast(&format!("Could not reset the guide and rules: {error}")),
        }
        self.reload();
    }
}

/// "~/.config/snippets/agent-skill · Defaults", or which one was edited, or that the
/// defaults changed under an edited file.
fn files_text(environment: &Environment, files: &Files) -> String {
    let folder = environment.display(&files.folder);
    let changed: Vec<_> = [("guide", files.guide), ("rules", files.rules)]
        .into_iter()
        .filter(|(_, state)| *state != FileState::Default)
        .collect();
    if changed.is_empty() {
        return format!("{folder} · Defaults");
    }
    let names = changed
        .iter()
        .map(|(name, _)| *name)
        .collect::<Vec<_>>()
        .join(" and ");
    if changed
        .iter()
        .any(|(_, state)| *state == FileState::Outdated)
    {
        return format!(
            "{folder} · You edited the {names}; an update changed the defaults since. The originals are in {}.",
            environment.display(&files.originals_folder)
        );
    }
    format!("{folder} · You edited the {names}")
}
