//! Native global-shortcut settings; the primary process alone owns the listener.
use super::*;
use crate::global_shortcuts::{Action, BINDINGS, Handle, Preference, Status};
use std::path::PathBuf;
type ActivationHandler = dyn Fn(Action, Option<PasteTarget>, Option<String>);
pub(super) struct Service {
    root: PathBuf,
    worker: RefCell<Option<Handle>>,
    view: RefCell<Option<View>>,
    enabled: Cell<bool>,
    error: Cell<Option<&'static str>>,
    busy: Cell<bool>,
    loading: Cell<bool>,
    quitting: Cell<bool>,
    restart: Cell<bool>,
    activate: Box<ActivationHandler>,
}
struct View {
    window: adw::PreferencesWindow,
    enabled: adw::SwitchRow,
    status: adw::ActionRow,
    retry: gtk::Button,
}
impl Service {
    pub fn new(
        root: PathBuf,
        activate: impl Fn(Action, Option<PasteTarget>, Option<String>) + 'static,
    ) -> Rc<Self> {
        let preference = Preference::read(&root);
        let this = Rc::new(Self {
            root,
            worker: RefCell::new(None),
            view: RefCell::new(None),
            enabled: Cell::new(preference.as_ref().is_ok_and(|p| p.enabled)),
            error: Cell::new(preference.err().map(|e| e.0)),
            busy: Cell::new(false),
            loading: Cell::new(false),
            quitting: Cell::new(false),
            restart: Cell::new(false),
            activate: Box::new(activate),
        });
        this.start();
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_millis(50), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let events = this
                .worker
                .borrow()
                .as_ref()
                .map(|worker| {
                    std::iter::from_fn(|| worker.next())
                        .take(3)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            for event in events {
                if !this.quitting.get()
                    && !this.busy.get()
                    && this.enabled.get()
                    && event.valid()
                    && Preference::read(&this.root).is_ok_and(|p| p.enabled)
                {
                    (this.activate)(event.action, event.target, event.activation_token);
                }
            }
            if this.restart.get() && this.finished() && !this.busy.get() {
                this.worker.borrow_mut().take();
                this.restart.set(false);
                this.start();
            }
            this.refresh();
            glib::ControlFlow::Continue
        });
        this
    }
    fn finished(&self) -> bool {
        self.worker
            .borrow()
            .as_ref()
            .is_none_or(Handle::is_finished)
    }
    fn start(&self) {
        if !self.enabled.get() || self.quitting.get() || self.worker.borrow().is_some() {
            return;
        }
        match Handle::start(self.root.clone()) {
            Ok(worker) => *self.worker.borrow_mut() = Some(worker),
            Err(error) => self.error.set(Some(error.0)),
        }
    }
    fn stop(&self) {
        if let Some(worker) = self.worker.borrow().as_ref() {
            worker.stop();
        }
    }
    pub fn prepare_quit(&self) -> bool {
        self.quitting.set(true);
        self.restart.set(false);
        self.stop();
        self.refresh();
        !self.busy.get() && self.finished()
    }
    pub fn cancel_quit(&self) {
        if self.quitting.replace(false) {
            self.restart.set(self.enabled.get());
        }
        self.refresh();
    }
    fn change(self: &Rc<Self>, enabled: bool) {
        if self.quitting.get() || self.busy.replace(true) {
            return;
        }
        self.stop(); // Revoke queued work before waiting for a settings write.
        self.restart.set(false);
        let root = self.root.clone();
        self.refresh();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = gio::spawn_blocking(move || Preference::write(&root, enabled))
                .await
                .unwrap_or(Err(Error("Global shortcut settings could not be saved.")));
            match result {
                Ok(()) => {
                    this.enabled.set(enabled);
                    this.error.set(None);
                    this.restart.set(enabled);
                }
                Err(error) => {
                    this.error.set(Some(error.0));
                }
            }
            this.busy.set(false);
            this.refresh();
        });
    }
    pub fn present(self: &Rc<Self>, application: &adw::Application) {
        if !self.busy.get() && !self.quitting.get() {
            match Preference::read(&self.root) {
                Ok(preference) => {
                    if self.enabled.replace(preference.enabled) != preference.enabled {
                        self.stop();
                        self.restart.set(preference.enabled);
                        self.error.set(None);
                    }
                }
                Err(error) => {
                    self.stop();
                    self.error.set(Some(error.0));
                }
            }
        }
        if self.view.borrow().is_none() {
            let window = adw::PreferencesWindow::builder()
                .title("Global Keyboard Shortcuts")
                .default_width(760)
                .default_height(600)
                .search_enabled(true)
                .build();
            window.set_application(Some(application));
            window.set_hide_on_close(true);
            let page = adw::PreferencesPage::builder()
                .title("Keyboard Shortcuts")
                .icon_name("input-keyboard-symbolic")
                .build();
            let gnome = crate::desktop::environment() == crate::desktop::Environment::Gnome;
            let group = adw::PreferencesGroup::builder().title("Use Snippets from Other Applications")
                .description(if gnome { "Choose shortcuts in the GNOME system dialog. Snippets must be running." }
                    else { "Register actions with Hyprland, then choose unused keys in your desktop bindings. Snippets must be running." }).build();
            let enabled = adw::SwitchRow::builder()
                .title("Enable Global Shortcuts")
                .subtitle("Open Snippets, open its paste picker, or capture clipboard text.")
                .build();
            group.add(&enabled);
            let status = adw::ActionRow::builder()
                .title("Desktop Connection")
                .build();
            let retry = gtk::Button::with_label("Retry Connection");
            retry.set_valign(gtk::Align::Center);
            status.add_suffix(&retry);
            status.set_activatable_widget(Some(&retry));
            group.add(&status);
            page.add(&group);
            let setup = adw::PreferencesGroup::builder().title("Omarchy Binding Examples")
                .description("Check existing keys with omarchy menu keybindings --print. Edit ~/.config/hypr/bindings.lua and choose free combinations. Registration does not assign these keys automatically.").build();
            let code = gtk::TextView::builder()
                .editable(false)
                .cursor_visible(false)
                .monospace(true)
                .left_margin(12)
                .right_margin(12)
                .top_margin(12)
                .bottom_margin(12)
                .build();
            code.buffer().set_text(BINDINGS);
            let scroll = gtk::ScrolledWindow::builder()
                .child(&code)
                .min_content_height(150)
                .build();
            setup.add(&scroll);
            let row = adw::ActionRow::builder()
                .title("Copy Binding Examples")
                .subtitle(
                    "Adjust the keys, then reload Hyprland and check its configuration errors.",
                )
                .build();
            let copy = gtk::Button::with_label("Copy");
            copy.set_valign(gtk::Align::Center);
            row.add_suffix(&copy);
            row.set_activatable_widget(Some(&copy));
            setup.add(&row);
            if !gnome {
                page.add(&setup);
            }
            window.add(&page);
            let weak = Rc::downgrade(self);
            enabled.connect_active_notify(move |row| {
                if let Some(this) = weak.upgrade()
                    && !this.loading.get()
                {
                    this.change(row.is_active());
                }
            });
            let weak = Rc::downgrade(self);
            retry.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade()
                    && !this.busy.get()
                    && !this.quitting.get()
                {
                    if gnome
                        && this
                            .worker
                            .borrow()
                            .as_ref()
                            .is_some_and(Handle::can_configure)
                    {
                        if let Some(worker) = this.worker.borrow().as_ref() {
                            worker.configure();
                        }
                    } else {
                        this.stop();
                        this.error.set(None);
                        this.restart.set(true);
                    }
                }
            });
            copy.connect_clicked(move |button| {
                let _ = button
                    .clipboard()
                    .set_content(Some(&internal_clipboard_provider(BINDINGS)));
            });
            *self.view.borrow_mut() = Some(View {
                window,
                enabled,
                status,
                retry,
            });
        }
        self.refresh();
        self.view.borrow().as_ref().unwrap().window.present();
    }
    fn refresh(&self) {
        let view = self.view.borrow();
        let Some(view) = view.as_ref() else {
            return;
        };
        self.loading.set(true);
        view.enabled.set_active(self.enabled.get());
        view.enabled
            .set_sensitive(!self.busy.get() && !self.quitting.get());
        let status = if self.quitting.get() {
            Status::Stopping
        } else {
            self.worker
                .borrow()
                .as_ref()
                .map_or(Status::Off, Handle::status)
        };
        let gnome = crate::desktop::environment() == crate::desktop::Environment::Gnome;
        let configurable = self
            .worker
            .borrow()
            .as_ref()
            .is_some_and(Handle::can_configure);
        view.status.set_subtitle(if self.busy.get() { "Saving shortcut settings…" }
            else if let Some(error) = self.error.get() { error }
            else { match status {
                Status::Off => "Global shortcuts are off.",
                Status::Starting if gnome => "Waiting for GNOME shortcut setup…",
                Status::Starting => "Connecting to Hyprland…",
                Status::Registered if gnome && configurable => "Shortcuts are registered with GNOME. Use Change Keys to edit them.",
                Status::Registered if gnome => "Shortcuts are registered with GNOME. Edit them in the Snippets page in system Settings.",
                Status::Registered => "Actions are registered. Choose keys in your Omarchy bindings.",
                Status::Unavailable => "Registration failed. Check compositor support and duplicate shortcut registrations, then retry.",
                Status::Stopping => "Stopping global shortcuts…",
            }});
        view.retry.set_label(if gnome && configurable {
            "Change Keys…"
        } else {
            "Retry Connection"
        });
        view.retry.set_sensitive(
            self.enabled.get()
                && !self.busy.get()
                && !self.quitting.get()
                && (self.finished() || (gnome && configurable)),
        );
        view.window.set_sensitive(!self.quitting.get());
        self.loading.set(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; temporary preferences, no native listener, clipboard or input"]
    fn native_global_shortcuts_settings_default_off_and_save_before_quit() {
        adw::init().expect("graphical display");
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("Public absent library");
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.ShortcutsSmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let service = Service::new(root.clone(), |_, _, _| {
            panic!("no actions in the settings fixture")
        });
        assert!(service.worker.borrow().is_none());
        assert!(!root.exists());
        service.present(&application);
        assert!(
            service
                .view
                .borrow()
                .as_ref()
                .unwrap()
                .window
                .is_search_enabled()
        );
        assert!(!service.view.borrow().as_ref().unwrap().enabled.is_active());
        assert!(!root.exists());
        service.change(false);
        assert!(!service.prepare_quit());
        let start = std::time::Instant::now();
        while service.busy.get() {
            assert!(start.elapsed() < Duration::from_secs(3));
            while glib::MainContext::default().pending() {
                glib::MainContext::default().iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!Preference::read(&root).unwrap().enabled);
        assert!(service.prepare_quit());
        assert!(service.worker.borrow().is_none());
        service.view.borrow().as_ref().unwrap().window.destroy();
    }
}
