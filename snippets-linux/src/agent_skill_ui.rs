//! Settings › General › "Agent Skill" and "Agent Rules": the same model as the Mac's
//! Settings › Integrations and `snippets-cli skill status`, from `crate::agent_skill`.
//!
//! Changes apply at once, as elsewhere in GNOME settings. A foreign `SKILL.md` is shown and
//! never replaced; a remembered folder that has gone is shown and only removable.

use super::*;
use crate::agent_skill::{self, Environment, Place, PlaceState, PlaceStatus};

pub(super) struct AgentSkillControls {
    window: adw::PreferencesWindow,
    skills: adw::PreferencesGroup,
    rows: RefCell<Vec<gtk::Widget>>,
    rules: adw::ActionRow,
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

        let rules_group = adw::PreferencesGroup::builder()
            .title("Agent Rules")
            .build();
        let rules = adw::ActionRow::builder()
            .use_markup(false)
            .title("Rules for agents")
            .build();
        let edit = gtk::Button::builder()
            .label("Edit")
            .valign(gtk::Align::Center)
            .build();
        let open_folder = gtk::Button::builder()
            .label("Open Folder")
            .valign(gtk::Align::Center)
            .build();
        rules.add_suffix(&edit);
        rules.add_suffix(&open_folder);
        rules_group.add(&rules);

        page.add(&skills);
        page.add(&rules_group);

        let this = Rc::new(Self {
            window: window.clone(),
            skills,
            rows: RefCell::new(Vec::new()),
            rules,
        });

        let weak = Rc::downgrade(&this);
        add_folder.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                glib::spawn_future_local(async move { this.add_folder().await });
            }
        });
        let weak = Rc::downgrade(&this);
        edit.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.open_rules(false);
            }
        });
        let weak = Rc::downgrade(&this);
        open_folder.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.open_rules(true);
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
        let rules = environment.display(&status.rules_path);
        self.rules.set_subtitle(&if status.rules_are_custom {
            rules
        } else {
            format!("{rules} (not created yet: the defaults apply)")
        });
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

    /// Creates the rules file from the defaults if needed, then opens it (or its folder)
    /// with the desktop's default application.
    fn open_rules(&self, folder: bool) {
        let Some(environment) = Environment::current() else {
            return;
        };
        if let Err(error) = agent_skill::create_rules_file(&environment) {
            self.toast(&format!("Could not create the rules file: {error}"));
            return;
        }
        let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(environment.rules_path())));
        let window = self.window.clone();
        let report = move |result: Result<(), glib::Error>| {
            if let Err(error) = result {
                window.add_toast(adw::Toast::new(&format!(
                    "Could not open the rules file: {}",
                    error.message()
                )));
            }
        };
        if folder {
            launcher.open_containing_folder(Some(&self.window), gio::Cancellable::NONE, report);
        } else {
            launcher.launch(Some(&self.window), gio::Cancellable::NONE, report);
        }
    }
}
