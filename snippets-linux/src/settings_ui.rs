//! Searchable native preferences. Each secret-owning action keeps its original gate.
use super::*;
use crate::desktop_settings::{CloseAction, Preferences, Registration, Snapshot};
use std::path::PathBuf;
pub(super) struct Settings {
    pub window: adw::PreferencesWindow,
    root: PathBuf,
    registration: Option<Registration>,
    snapshot: RefCell<Option<Snapshot>>,
    executable: Option<PathBuf>,
    startup: adw::SwitchRow,
    installation: gtk::Button,
    installation_row: adw::ActionRow,
    close: adw::ComboRow,
    close_action: Cell<CloseAction>,
    status: adw::ActionRow,
    error: Cell<Option<&'static str>>,
    busy: Cell<bool>,
    loading: Cell<bool>,
    quitting: Cell<bool>,
    diagnostics: Rc<diagnostic_controls::Controls>,
}
type SettingsLink = (&'static str, &'static str, &'static str);
type SettingsPage = (&'static str, &'static str, &'static [SettingsLink]);
const PAGES: &[SettingsPage] = &[
    (
        "Library",
        "document-edit-symbolic",
        &[
            (
                "Secure Snippets",
                "Vault, passwords, recovery and protected editor",
                "secure",
            ),
            (
                "Cloud Sync & Recovery",
                "Account, synchronization, pairing and library recovery",
                "account",
            ),
        ],
    ),
    (
        "Input & Clipboard",
        "input-keyboard-symbolic",
        &[
            (
                "Global Keyboard Shortcuts",
                "Open, paste picker and capture from other applications",
                "shortcuts",
            ),
            (
                "Inline Expansion",
                "Keywords, caret suggestions and keyboard selection",
                "inline",
            ),
            (
                "Suggestion Learning",
                "Local ranking, prefix memory and independent resets",
                "usage",
            ),
            (
                "Clipboard History",
                "Encrypted local history, collection and exclusions",
                "history",
            ),
        ],
    ),
    (
        "Backups",
        "document-save-symbolic",
        &[
            (
                "Export Encrypted Backup",
                "Save a password-protected full library",
                "backup",
            ),
            (
                "Restore Encrypted Backup",
                "Import or resume an interrupted encrypted backup",
                "restore-backup",
            ),
        ],
    ),
];
impl Settings {
    pub fn new(
        application: &adw::Application,
        root: PathBuf,
        diagnostics: Option<std::sync::Arc<crate::diagnostics_service::Service>>,
    ) -> Rc<Self> {
        let registration = Registration::from_environment();
        let executable = std::env::current_exe().ok();
        Self::with_registration(application, root, registration, executable, diagnostics)
    }
    fn with_registration(
        application: &adw::Application,
        root: PathBuf,
        registration: Result<Registration, Error>,
        executable: Option<PathBuf>,
        diagnostics: Option<std::sync::Arc<crate::diagnostics_service::Service>>,
    ) -> Rc<Self> {
        let preference = Preferences::read(&root);
        let close_action = preference
            .as_ref()
            .map_or(CloseAction::Hide, |p| p.close_action);
        let mut failure = preference.err().map(|e| e.0);
        let (registration, snapshot) = match registration {
            Ok(registration) => {
                let snapshot = registration.read();
                if let Err(error) = &snapshot {
                    failure = Some(error.0)
                }
                (Some(registration), snapshot.ok())
            }
            Err(error) => {
                failure = Some(error.0);
                (None, None)
            }
        };
        let window = adw::PreferencesWindow::builder()
            .title("Settings")
            .default_width(620)
            .default_height(620)
            .search_enabled(true)
            .build();
        window.set_application(Some(application));
        window.set_hide_on_close(true);
        let general = adw::PreferencesPage::builder()
            .title("General")
            .icon_name("preferences-system-symbolic")
            .build();
        let group = adw::PreferencesGroup::builder()
            .title("Desktop")
            .description("Snippets can keep running after its library window closes.")
            .build();
        let startup = adw::SwitchRow::builder()
            .use_markup(false)
            .title("Launch at Login")
            .subtitle("Start Snippets in the background when you sign in.")
            .active(snapshot.as_ref().is_some_and(|s| s.enabled))
            .build();
        group.add(&startup);
        let installed = adw::ActionRow::builder()
            .use_markup(false)
            .title("Application Installation")
            .subtitle("Update login startup after moving or reinstalling Snippets.")
            .build();
        let installation = gtk::Button::with_label("Use This Installation");
        installation.set_valign(gtk::Align::Center);
        installed.add_suffix(&installation);
        installed.set_activatable_widget(Some(&installation));
        group.add(&installed);
        let model = gtk::StringList::new(&["Hide and Keep Running", "Quit Snippets"]);
        let close = adw::ComboRow::builder()
            .use_markup(false)
            .title("When Library Window Closes")
            .subtitle("Quit waits for saved drafts and running operations.")
            .model(&model)
            .selected(u32::from(close_action == CloseAction::Quit))
            .build();
        group.add(&close);
        let status = adw::ActionRow::builder()
            .use_markup(false)
            .title("Desktop Settings")
            .build();
        status.set_subtitle("Settings are local to this device.");
        group.add(&status);
        general.add(&group);
        window.add(&general);
        for (title, icon, entries) in PAGES {
            let page = adw::PreferencesPage::builder()
                .title(*title)
                .icon_name(*icon)
                .build();
            let group = adw::PreferencesGroup::new();
            for (title, description, action) in *entries {
                let row = adw::ActionRow::builder().use_markup(false).build();
                // Set text after construction so title bindings see markup disabled.
                row.set_title(title);
                row.set_subtitle(description);
                let open = button("go-next-symbolic", title);
                open.set_valign(gtk::Align::Center);
                open.set_action_name(Some(&format!("app.{action}")));
                row.add_suffix(&open);
                row.set_activatable_widget(Some(&open));
                group.add(&row);
            }
            page.add(&group);
            window.add(&page);
        }
        let diagnostics = diagnostic_controls::Controls::new(&window, diagnostics);
        window.add(&diagnostics.page);
        let this = Rc::new(Self {
            window,
            root,
            registration,
            snapshot: RefCell::new(snapshot),
            executable,
            startup,
            installation,
            installation_row: installed,
            close,
            close_action: Cell::new(close_action),
            status,
            error: Cell::new(failure),
            busy: Cell::new(false),
            loading: Cell::new(false),
            quitting: Cell::new(false),
            diagnostics,
        });
        let weak = Rc::downgrade(&this);
        this.startup.connect_active_notify(move |row| {
            if let Some(this) = weak.upgrade()
                && !this.loading.get()
            {
                this.set_login(row.is_active())
            }
        });
        let weak = Rc::downgrade(&this);
        this.installation.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.set_login(true)
            }
        });
        let weak = Rc::downgrade(&this);
        this.close.connect_selected_notify(move |row| {
            if let Some(this) = weak.upgrade()
                && !this.loading.get()
            {
                this.set_close(if row.selected() == 1 {
                    CloseAction::Quit
                } else {
                    CloseAction::Hide
                })
            }
        });
        this.refresh();
        this
    }
    pub fn can_quit(&self) -> bool {
        !self.busy.get() && self.diagnostics.can_quit()
    }
    pub fn prepare_quit(&self) -> bool {
        self.quitting.set(true);
        self.diagnostics.prepare_quit();
        self.refresh();
        self.can_quit()
    }
    pub fn cancel_quit(&self) {
        self.quitting.set(false);
        self.diagnostics.cancel_quit();
        self.refresh();
    }
    pub fn present(self: &Rc<Self>) {
        if !self.busy.get() {
            self.error.set(None);
            match Preferences::read(&self.root) {
                Ok(p) => self.close_action.set(p.close_action),
                Err(e) => self.error.set(Some(e.0)),
            }
            if let Some(registration) = &self.registration {
                match registration.read() {
                    Ok(snapshot) => *self.snapshot.borrow_mut() = Some(snapshot),
                    Err(error) => {
                        self.snapshot.borrow_mut().take();
                        self.error.set(Some(error.0));
                    }
                }
            }
            self.refresh();
        }
        self.window.present();
        self.diagnostics.refresh();
    }
    fn refresh(&self) {
        self.window.set_sensitive(!self.quitting.get());
        self.loading.set(true);
        let snapshot = self.snapshot.borrow();
        self.startup
            .set_active(snapshot.as_ref().is_some_and(|s| s.enabled));
        self.startup.set_sensitive(
            !self.busy.get()
                && !self.quitting.get()
                && self.registration.is_some()
                && snapshot.is_some()
                && self.executable.is_some(),
        );
        self.close
            .set_selected(u32::from(self.close_action.get() == CloseAction::Quit));
        self.close
            .set_sensitive(!self.busy.get() && !self.quitting.get());
        let moved = snapshot
            .as_ref()
            .is_some_and(|s| s.enabled && s.executable != self.executable);
        self.installation_row.set_visible(moved);
        self.installation
            .set_sensitive(!self.busy.get() && !self.quitting.get() && self.executable.is_some());
        self.status.set_subtitle(if self.busy.get() {
            "Saving desktop settings…"
        } else if let Some(error) = self.error.get() {
            error
        } else if moved {
            "Login startup uses a different installation. Use This Installation to update it."
        } else if self.registration.is_none() || self.executable.is_none() {
            "Login startup is unavailable because the desktop or application path could not be read."
        } else if snapshot.is_none() {
            "The login entry could not be verified. Reopen Settings after reviewing it."
        } else {
            "Settings are local to this device."
        });
        self.loading.set(false);
    }
    fn set_login(self: &Rc<Self>, enabled: bool) {
        if self.quitting.get() || self.busy.replace(true) {
            return;
        }
        let Some((registration, before, executable)) = self
            .registration
            .clone()
            .zip(self.snapshot.borrow().as_ref().cloned())
            .zip(self.executable.clone())
            .map(|((r, s), p)| (r, s, p))
        else {
            self.busy.set(false);
            self.refresh();
            return;
        };
        self.refresh();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result =
                gio::spawn_blocking(move || registration.write(&before, &executable, enabled))
                    .await
                    .unwrap_or(Err(Error("Login settings could not be saved.")));
            match result {
                Ok(snapshot) => {
                    *this.snapshot.borrow_mut() = Some(snapshot);
                    this.error.set(None)
                }
                Err(error) => this.error.set(Some(error.0)),
            }
            this.busy.set(false);
            this.refresh();
        });
    }
    fn set_close(self: &Rc<Self>, action: CloseAction) {
        if self.quitting.get() || self.busy.replace(true) {
            return;
        }
        let root = self.root.clone();
        self.refresh();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = gio::spawn_blocking(move || Preferences::write(&root, action))
                .await
                .unwrap_or(Err(Error("Desktop settings could not be saved.")));
            match result {
                Ok(()) => {
                    this.close_action.set(action);
                    this.error.set(None)
                }
                Err(error) => this.error.set(Some(error.0)),
            }
            this.busy.set(false);
            this.refresh();
        });
    }
}
#[cfg(test)]
#[path = "login_startup_live_tests.rs"]
mod live_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; all settings and login files use temporary roots"]
    fn native_searchable_settings_use_temporary_registration_and_save_before_quit() {
        adw::init().expect("graphical display");
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("library");
        let _library = Library::prepare(root.clone()).unwrap();
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.SettingsSmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let config = temp.path().join("config");
        let settings = Settings::with_registration(
            &application,
            root.clone(),
            Registration::new(config.clone()),
            std::env::current_exe().ok(),
            None,
        );
        assert!(settings.window.is_search_enabled());
        assert!(!settings.startup.is_active());
        assert_eq!(settings.close.selected(), 0);
        assert!(!config.exists());
        settings.window.present();
        settings.set_login(true);
        assert!(!settings.can_quit());
        settle(&settings);
        assert!(settings.startup.is_active());
        assert!(
            Registration::new(config.clone())
                .unwrap()
                .read()
                .unwrap()
                .enabled
        );
        settings.set_close(CloseAction::Quit);
        assert!(!settings.can_quit());
        assert!(!settings.prepare_quit());
        settings.set_login(false); // Quit fences new writes while the accepted save completes.
        settle(&settings);
        assert!(Preferences::read(&root).unwrap().close_action == CloseAction::Quit);
        assert!(settings.startup.is_active());
        settings.cancel_quit();
        settings.set_login(false);
        settle(&settings);
        assert!(!Registration::new(config).unwrap().read().unwrap().enabled);
        settings.window.close();
        assert!(settings.can_quit());
        settings.window.destroy();
    }
    fn settle(settings: &Settings) {
        let start = std::time::Instant::now();
        while !settings.can_quit() {
            assert!(start.elapsed() < Duration::from_secs(3));
            while glib::MainContext::default().pending() {
                glib::MainContext::default().iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
