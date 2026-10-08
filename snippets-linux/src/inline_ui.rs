//! Opt-in ordinary expansion settings. GTK receives only closed worker status.
use super::*;
use crate::{
    desktop::SessionMonitor,
    inline_expansion::worker::{Handle, Preference, Status},
};
use std::path::PathBuf;
pub(super) struct Service {
    root: PathBuf,
    usage: Option<crate::usage_store::Handle>,
    enabled: Cell<bool>,
    suggestions: Cell<bool>,
    error: Cell<Option<&'static str>>,
    status: Cell<Status>,
    monitor: RefCell<Option<SessionMonitor>>,
    worker: RefCell<Option<Handle>>,
    window: RefCell<Option<Rc<Settings>>>,
    dialog: RefCell<Option<adw::AlertDialog>>,
    busy: Cell<bool>,
    quitting: Cell<bool>,
    restart_pending: Cell<bool>,
}
struct Settings {
    window: adw::ApplicationWindow,
    status: gtk::Label,
    toggle: gtk::Button,
    suggestions: gtk::Button,
    retry: gtk::Button,
}
impl Service {
    pub fn new(root: PathBuf, usage: Option<crate::usage_store::Handle>) -> Rc<Self> {
        let preference = Preference::read(&root);
        let this = Rc::new(Self {
            root,
            usage,
            enabled: Cell::new(preference.as_ref().is_ok_and(|value| value.enabled)),
            suggestions: Cell::new(preference.as_ref().is_ok_and(|value| value.suggestions)),
            error: Cell::new(preference.err().map(|error| error.0)),
            status: Cell::new(Status::WaitingForUnlock),
            monitor: RefCell::new(None),
            worker: RefCell::new(None),
            window: RefCell::new(None),
            dialog: RefCell::new(None),
            busy: Cell::new(false),
            quitting: Cell::new(false),
            restart_pending: Cell::new(false),
        });
        this.start();
        let weak = Rc::downgrade(&this);
        let mut ticks = 0u32;
        glib::timeout_add_local(Duration::from_millis(50), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if let Some(worker) = this.worker.borrow().as_ref() {
                while let Ok(status) = worker.receiver.try_recv() {
                    this.status.set(status);
                }
                if worker.finished()
                    && !matches!(this.status.get(), Status::Stopped | Status::Unavailable)
                {
                    this.status.set(Status::Unavailable);
                }
            }
            ticks = ticks.wrapping_add(1);
            if ticks.is_multiple_of(20) {
                match Preference::read(&this.root) {
                    Ok(preference) if !preference.enabled => {
                        this.enabled.set(false);
                        this.suggestions.set(preference.suggestions);
                        this.restart_pending.set(false);
                        this.stop();
                    }
                    Ok(preference) => {
                        if this.enabled.get()
                            && this.suggestions.replace(preference.suggestions)
                                != preference.suggestions
                        {
                            this.stop();
                            this.restart_pending.set(true);
                        }
                    }
                    Err(error) => {
                        this.error.set(Some(error.0));
                        this.enabled.set(false);
                        this.restart_pending.set(false);
                        this.stop();
                    }
                }
            }
            if !this.enabled.get() && this.worker.borrow().as_ref().is_none_or(Handle::finished) {
                this.worker.borrow_mut().take();
                this.monitor.borrow_mut().take();
            }
            if this.restart_pending.get()
                && this.enabled.get()
                && !this.quitting.get()
                && this.worker.borrow().as_ref().is_none_or(Handle::finished)
            {
                this.worker.borrow_mut().take();
                this.restart_pending.set(false);
                this.start();
            }
            this.refresh();
            glib::ControlFlow::Continue
        });
        this
    }
    pub fn configure(
        &self,
        command: crate::control::ExpansionCommand,
    ) -> std::result::Result<crate::control::ExpansionSettings, crate::control::Status> {
        use crate::control::{ExpansionCommand as Command, ExpansionSettings, ExpansionState};
        if self.quitting.get()
            || (command != Command::Status && (self.busy.get() || self.dialog.borrow().is_some()))
        {
            return Err(crate::control::Status::Refused);
        }
        if command == Command::Disable {
            // Revocation is immediate, even when persistence fails.
            self.disable();
            if self.error.get().is_some() {
                return Err(crate::control::Status::Error);
            }
        } else if command != Command::Status {
            let before = Preference::read(&self.root).map_err(|_| crate::control::Status::Error)?;
            let result = match command {
                Command::Enable if !before.enabled => {
                    Preference::enable_with_suggestions(&self.root)
                }
                Command::Enable | Command::Retry => Ok(()),
                Command::Disable => Preference::write(&self.root, false),
                Command::EnableSuggestions if !before.enabled => {
                    return Err(crate::control::Status::Refused);
                }
                Command::EnableSuggestions => Preference::write_suggestions(&self.root, true),
                Command::DisableSuggestions => Preference::write_suggestions(&self.root, false),
                Command::Status => unreachable!(),
            };
            result.map_err(|_| crate::control::Status::Error)?;
            let after = Preference::read(&self.root).map_err(|_| crate::control::Status::Error)?;
            let changed =
                self.enabled.get() != after.enabled || self.suggestions.get() != after.suggestions;
            self.enabled.set(after.enabled);
            self.suggestions.set(after.suggestions);
            self.error.set(None);
            if changed || command == Command::Retry {
                self.stop();
                self.restart_pending.set(after.enabled);
                if self.worker.borrow().as_ref().is_none_or(Handle::finished) {
                    self.worker.borrow_mut().take();
                    self.restart_pending.set(false);
                    self.start();
                }
            }
            self.refresh();
        }
        let state = if !self.enabled.get() {
            ExpansionState::Disabled
        } else if self.restart_pending.get() {
            ExpansionState::Starting
        } else {
            match self.status.get() {
                Status::WaitingForUnlock => ExpansionState::WaitingForUnlock,
                Status::WaitingForField => ExpansionState::WaitingForField,
                Status::Listening => ExpansionState::Listening,
                Status::Stopped => ExpansionState::Stopped,
                Status::Unavailable => ExpansionState::Unavailable,
                Status::WaitingForFcitx => ExpansionState::WaitingForFcitx,
            }
        };
        Ok(ExpansionSettings {
            enabled: self.enabled.get(),
            suggestions: self.suggestions.get(),
            state,
        })
    }
    fn start(&self) {
        if !self.enabled.get()
            || self.error.get().is_some()
            || self.quitting.get()
            || self.worker.borrow().is_some()
        {
            return;
        }
        if self.monitor.borrow().is_none() {
            *self.monitor.borrow_mut() = SessionMonitor::new();
        }
        let Some(witness) = self.monitor.borrow().as_ref().map(SessionMonitor::witness) else {
            self.status.set(Status::Unavailable);
            return;
        };
        match Handle::start_with_usage(self.root.clone(), witness, self.usage.clone()) {
            Ok(worker) => {
                *self.worker.borrow_mut() = Some(worker);
                self.status.set(Status::WaitingForUnlock);
            }
            Err(error) => {
                self.error.set(Some(error.0));
                self.status.set(Status::Unavailable);
            }
        }
    }
    fn stop(&self) {
        if let Some(worker) = self.worker.borrow().as_ref() {
            worker.stop();
        }
    }
    fn close_confirmation(&self) {
        let dialog = self.dialog.borrow_mut().take();
        if let Some(dialog) = dialog {
            dialog.force_close();
        }
    }
    pub fn prepare_quit(&self) -> bool {
        self.quitting.set(true);
        self.restart_pending.set(false);
        self.close_confirmation();
        self.stop();
        self.worker.borrow().as_ref().is_none_or(Handle::finished)
    }
    pub fn cancel_quit(&self) {
        self.quitting.set(false);
        self.stop();
        // Reconnect only after the cancelled worker has completely released its seat.
        self.status.set(Status::Stopped);
        self.restart_pending.set(self.enabled.get());
        self.refresh();
    }
    fn refresh(&self) {
        let Some(settings) = self.window.borrow().clone() else {
            return;
        };
        settings
            .status
            .set_text(self.error.get().unwrap_or(if self.enabled.get() {
                self.status.get().text()
            } else {
                "Inline expansion is disabled. No text-field observer is running."
            }));
        settings.toggle.set_label(if self.enabled.get() {
            "Disable Expansion"
        } else {
            "Enable Expansion…"
        });
        settings
            .toggle
            .set_sensitive(!self.busy.get() && !self.quitting.get());
        settings.retry.set_visible(self.enabled.get());
        settings.suggestions.set_label(if self.suggestions.get() {
            "Disable Suggestions"
        } else {
            "Enable Suggestions…"
        });
        settings
            .suggestions
            .set_sensitive(self.enabled.get() && !self.busy.get() && !self.quitting.get());
        settings.retry.set_sensitive(
            !self.busy.get()
                && !self.quitting.get()
                && self.worker.borrow().as_ref().is_none_or(Handle::finished),
        );
    }
    fn disable(&self) {
        self.enabled.set(false);
        self.restart_pending.set(false);
        self.stop(); // Revoke before any disk operation.
        self.error.set(
            Preference::write(&self.root, false)
                .err()
                .map(|_| "Expansion is stopped for this session, but the disabled setting could not be saved. It may restart when Snippets next opens."),
        );
        self.refresh();
    }
    fn enable(self: &Rc<Self>) {
        if self.quitting.get() || self.busy.replace(true) {
            return;
        }
        let Some(settings) = self.window.borrow().clone() else {
            self.busy.set(false);
            return;
        };
        let dialog = enable_dialog();
        *self.dialog.borrow_mut() = Some(dialog.clone());
        self.refresh();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let response = dialog.choose_future(Some(&settings.window)).await;
            this.dialog.borrow_mut().take();
            let result =
                if response == "enable" && settings.window.is_active() && !this.quitting.get() {
                    Preference::enable_with_suggestions(&this.root)
                } else {
                    this.busy.set(false);
                    this.refresh();
                    return;
                };
            match result {
                Ok(()) => {
                    this.error.set(None);
                    this.enabled.set(true);
                    this.suggestions.set(true);
                    this.restart_pending.set(true);
                }
                Err(error) => this.error.set(Some(error.0)),
            }
            this.busy.set(false);
            this.refresh();
        });
    }
    fn disable_suggestions(&self) {
        self.suggestions.set(false);
        self.stop();
        self.restart_pending.set(true);
        self.error.set(Preference::write_suggestions(&self.root, false).err().map(|_| "Suggestions are stopped for this session, but the setting could not be saved. Retry after checking the settings file."));
        self.refresh();
    }
    fn enable_suggestions(self: &Rc<Self>) {
        if !self.enabled.get() || self.quitting.get() || self.busy.replace(true) {
            return;
        }
        let Some(settings) = self.window.borrow().clone() else {
            self.busy.set(false);
            return;
        };
        let dialog = suggestions_dialog();
        *self.dialog.borrow_mut() = Some(dialog.clone());
        self.refresh();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let response = dialog.choose_future(Some(&settings.window)).await;
            this.dialog.borrow_mut().take();
            if response == "enable"
                && settings.window.is_active()
                && !this.quitting.get()
                && this.enabled.get()
            {
                let result = Preference::read(&this.root).and_then(|preference| {
                    if !preference.enabled {
                        return Err(crate::model::Error("Enable expansion first."));
                    }
                    Preference::write_suggestions(&this.root, true)
                });
                match result {
                    Ok(()) => {
                        this.stop();
                        this.error.set(None);
                        this.suggestions.set(true);
                        this.restart_pending.set(true);
                    }
                    Err(error) => this.error.set(Some(error.0)),
                }
            }
            this.busy.set(false);
            this.refresh();
        });
    }
    pub fn present(self: &Rc<Self>, application: &adw::Application) {
        if let Some(settings) = self.window.borrow().clone() {
            settings.window.present();
            self.refresh();
            return;
        }
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 16);
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Inline Expansion",
            "Ordinary snippets",
        )));
        layout.append(&header);
        let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
        content.set_margin_start(20);
        content.set_margin_end(20);
        content.set_margin_top(20);
        content.set_margin_bottom(20);
        let description = label(
            "Type \\keyword to replace a unique enabled ordinary keyword in a compatible text field. Secure snippets use the picker's separate authenticated insertion.",
            "",
        );
        description.set_wrap(true);
        content.append(&description);
        let status = label("", "dim-label");
        status.set_wrap(true);
        content.append(&status);
        let toggle = gtk::Button::with_label("Enable Expansion…");
        content.append(&toggle);
        let suggestions = gtk::Button::with_label("Enable Suggestions…");
        content.append(&suggestions);
        let retry = gtk::Button::with_label("Retry Connection");
        content.append(&retry);
        layout.append(&content);
        let window = adw::ApplicationWindow::builder()
            .application(application)
            .title("Inline Expansion")
            .default_width(480)
            .content(&layout)
            .build();
        window.set_hide_on_close(true);
        let settings = Rc::new(Settings {
            window: window.clone(),
            status,
            toggle,
            suggestions,
            retry,
        });
        let weak = Rc::downgrade(self);
        settings.toggle.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                if this.enabled.get() {
                    this.disable();
                } else {
                    this.enable();
                }
            }
        });
        let weak = Rc::downgrade(self);
        settings.suggestions.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                if this.suggestions.get() {
                    this.disable_suggestions();
                } else {
                    this.enable_suggestions();
                }
            }
        });
        let weak = Rc::downgrade(self);
        settings.retry.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade()
                && this.worker.borrow().as_ref().is_none_or(Handle::finished)
            {
                this.restart_pending.set(false);
                this.worker.borrow_mut().take();
                this.error.set(None);
                this.start();
                this.refresh();
            }
        });
        let weak = Rc::downgrade(self);
        window.connect_is_active_notify(move |window| {
            if !window.is_active()
                && let Some(this) = weak.upgrade()
            {
                this.close_confirmation();
            }
        });
        let weak = Rc::downgrade(self);
        window.connect_close_request(move |_| {
            if let Some(this) = weak.upgrade() {
                this.close_confirmation();
            }
            glib::Propagation::Proceed
        });
        *self.window.borrow_mut() = Some(settings);
        self.refresh();
        window.present();
    }
}
fn enable_dialog() -> adw::AlertDialog {
    let dialog = adw::AlertDialog::builder().heading("Enable Inline Expansion?")
        .body("Typing \\ opens ordinary snippet names and keywords at the text cursor. Use ↑/↓ or Ctrl+N/P to select, Return or Tab to insert, and Escape to dismiss. Snippets processes the query you type after \\ through Fcitx. A {clipboard} placeholder reads the current text clipboard only when requested by that snippet. Secure snippets, password and sensitive fields are excluded.").build();
    dialog.add_responses(&[("cancel", "Cancel"), ("enable", "Enable Expansion")]);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.set_body_use_markup(false);
    dialog
}
fn suggestions_dialog() -> adw::AlertDialog {
    let dialog = adw::AlertDialog::builder().heading("Enable Inline Suggestions?")
        .body("Typing \\ opens ordinary snippet names and keywords at the text cursor through Fcitx. Use ↑/↓ or Ctrl+N/P to select, Return or Tab to insert, and Escape to dismiss. Secure snippets, password and sensitive fields are excluded.").build();
    dialog.add_responses(&[("cancel", "Cancel"), ("enable", "Enable Suggestions")]);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.set_body_use_markup(false);
    dialog
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; temporary disabled library only"]
    fn native_inline_settings_start_disabled_and_cancel_on_close() {
        adw::init().expect("graphical display");
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("Public absent library");
        let service = Service::new(root.clone(), None);
        assert!(
            !service.enabled.get()
                && !service.suggestions.get()
                && service.worker.borrow().is_none()
                && service.monitor.borrow().is_none()
        );
        assert!(!root.exists());
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.InlineSmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        service.present(&application);
        let settings = service.window.borrow().clone().unwrap();
        assert_eq!(
            settings.toggle.label().as_deref(),
            Some("Enable Expansion…")
        );
        assert!(!settings.retry.is_visible());
        assert!(!settings.suggestions.is_sensitive());
        assert_eq!(
            suggestions_dialog().default_response().as_deref(),
            Some("cancel")
        );
        assert_eq!(
            enable_dialog().default_response().as_deref(),
            Some("cancel")
        );
        service.enable();
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
        settings.window.close();
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
        assert!(service.prepare_quit());
        service.cancel_quit();
        assert!(
            !service.enabled.get()
                && service.worker.borrow().is_none()
                && service.monitor.borrow().is_none()
        );
        assert!(!root.exists());
        settings.window.destroy();
    }
}
