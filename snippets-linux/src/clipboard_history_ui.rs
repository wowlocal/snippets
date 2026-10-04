//! Explicit local history view and opt-in native Wayland collection.
use super::*;
use crate::{
    clipboard_history::{
        self as history, Entry, Preference,
        worker::{self, Command, Reply, Ticket},
    },
    desktop::{SessionMonitor, SessionState},
};
use std::path::PathBuf;
use zeroize::Zeroizing;

pub(super) struct Service {
    root: PathBuf,
    preference: RefCell<Preference>,
    preference_error: Cell<bool>,
    worker: worker::Handle,
    desktop: RefCell<Option<Rc<SessionMonitor>>>,
    collectors: RefCell<Vec<worker::CaptureHandle>>,
    monitor_error: Cell<Option<&'static str>>,
    monitor_ready: Cell<bool>,
    view_sequence: Cell<u64>,
    view_ticket: RefCell<Option<Ticket>>,
    window: RefCell<Option<Rc<HistoryWindow>>>,
    settings_busy: Cell<bool>,
    settings_epoch: Cell<Option<u64>>,
    dialog: RefCell<Option<adw::AlertDialog>>,
    create: Box<dyn Fn(&str)>,
}
struct HistoryWindow {
    window: adw::ApplicationWindow,
    status: gtk::Label,
    enable: gtk::Button,
    reset: gtk::Button,
    query: gtk::SearchEntry,
    rows: gtk::ListBox,
    preview: gtk::TextView,
    entries: RefCell<Vec<Entry>>,
    visible: RefCell<Vec<uuid::Uuid>>,
    selected: Cell<Option<uuid::Uuid>>,
    copy: gtk::Button,
    create: gtk::Button,
    delete: gtk::Button,
    more: gtk::Button,
    limit: Cell<usize>,
}
impl Service {
    pub fn new(root: PathBuf, create: impl Fn(&str) + 'static) -> model::Result<Rc<Self>> {
        let preference = Preference::read(&root);
        let failed = preference.is_err();
        let preference = preference.unwrap_or_default();
        let worker = worker::Handle::new(root.clone(), preference.clone())?;
        let this = Rc::new(Self {
            root,
            preference: RefCell::new(preference),
            preference_error: Cell::new(failed),
            worker,
            desktop: RefCell::new(None),
            collectors: RefCell::new(Vec::new()),
            monitor_error: Cell::new(None),
            monitor_ready: Cell::new(false),
            view_sequence: Cell::new(0),
            view_ticket: RefCell::new(None),
            window: RefCell::new(None),
            settings_busy: Cell::new(false),
            settings_epoch: Cell::new(None),
            dialog: RefCell::new(None),
            create: Box::new(create),
        });
        this.capture_connection();
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_millis(30), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            while let Ok(reply) = this.worker.receiver.try_recv() {
                this.reply(reply);
            }
            this.collectors
                .borrow_mut()
                .retain(|handle| !handle.finished());
            let allowed = this.view_allowed();
            if !allowed && this.worker.control.has_view() {
                this.scrub();
            } else if allowed && !this.worker.control.has_view() && !this.settings_busy.get() {
                this.load();
            }
            glib::ControlFlow::Continue
        });
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_secs(60), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if let Some(ticket) = this.ticket(false) {
                let _ = this.worker.send(Command::Maintain(ticket));
            }
            glib::ControlFlow::Continue
        });
        Ok(this)
    }
    fn monitor(&self) {
        if self.desktop.borrow().is_none() {
            *self.desktop.borrow_mut() = SessionMonitor::new().map(Rc::new);
        }
    }
    fn ticket(&self, view: bool) -> Option<Ticket> {
        self.desktop
            .borrow()
            .as_ref()
            .and_then(|monitor| self.worker.control.ticket(monitor.witness(), view).ok())
    }
    fn view_allowed(&self) -> bool {
        self.window
            .borrow()
            .as_ref()
            .is_some_and(|window| window.window.is_active() && window.window.is_visible())
            && self
                .desktop
                .borrow()
                .as_ref()
                .is_some_and(|monitor| monitor.snapshot().0 == SessionState::Unlocked)
    }
    fn status(&self, text: &str) {
        if let Some(window) = self.window.borrow().as_ref() {
            window.status.set_text(text);
        }
    }
    fn stop_capture(&self) {
        self.monitor_ready.set(false);
        for handle in self.collectors.borrow().iter() {
            handle.stop();
        }
    }
    fn capture_connection(&self) {
        self.stop_capture();
        self.monitor_error.set(None);
        if !self.preference.borrow().enabled || self.preference_error.get() {
            return;
        }
        self.monitor();
        let Some(witness) = self
            .desktop
            .borrow()
            .as_ref()
            .map(|monitor| monitor.witness())
        else {
            self.monitor_error.set(Some(
                "Collection paused: an observable Hyprland session is required.",
            ));
            return;
        };
        match self.worker.start_capture(
            self.root.clone(),
            self.preference.borrow().clone(),
            witness,
        ) {
            Ok(handle) => self.collectors.borrow_mut().push(handle),
            Err(error) => {
                self.monitor_error.set(Some(error.0));
                self.status(error.0);
            }
        }
    }
    fn scrub(&self) {
        self.view_sequence
            .set(self.view_sequence.get().wrapping_add(1));
        self.view_ticket.borrow_mut().take();
        self.worker.control.viewing(false);
        let dialog = self.dialog.borrow_mut().take();
        if let Some(dialog) = dialog {
            dialog.force_close();
        }
        if let Some(window) = self.window.borrow().as_ref() {
            window.entries.borrow_mut().clear();
            window.visible.borrow_mut().clear();
            window.selected.set(None);
            window.query.set_text("");
            window.preview.buffer().set_text("");
            clear_rows(&window.rows);
            for button in [&window.copy, &window.create, &window.delete] {
                button.set_sensitive(false);
            }
            window
                .status
                .set_text("History hidden. Focus this window on an unlocked desktop to view it.");
        }
    }
    pub fn prepare_quit(&self) -> bool {
        self.scrub();
        self.stop_capture();
        self.worker.prepare_quit()
            && self
                .collectors
                .borrow()
                .iter()
                .all(worker::CaptureHandle::finished)
    }
    pub fn cancel_quit(&self) {
        self.worker.control.cancel_quit();
        self.worker
            .control
            .resume(self.preference.borrow().enabled && !self.preference_error.get());
        self.capture_connection();
    }
    fn load(&self) {
        if !self.view_allowed() {
            return;
        }
        self.worker.control.viewing(true);
        let Some(ticket) = self.ticket(true) else {
            return;
        };
        let sequence = self.view_sequence.get().wrapping_add(1);
        self.view_sequence.set(sequence);
        *self.view_ticket.borrow_mut() = Some(ticket.clone());
        if let Err(error) = self.worker.send(Command::View { sequence, ticket }) {
            self.status(error.0);
        }
    }
    fn reply(self: &Rc<Self>, reply: Reply) {
        match reply {
            Reply::Preference { epoch, result } => {
                if self.settings_epoch.get() != Some(epoch) {
                    return;
                }
                self.settings_epoch.set(None);
                self.settings_busy.set(false);
                match result {
                    Ok(preference) => {
                        *self.preference.borrow_mut() = preference;
                        self.preference_error.set(false);
                        self.capture_connection();
                        self.settings();
                        self.load();
                    }
                    Err(error) => {
                        self.preference_error.set(true);
                        self.stop_capture();
                        self.status(error.0);
                        self.settings();
                    }
                }
            }
            Reply::Monitor { epoch, result } => {
                if self.worker.control.capture_epoch() != Some(epoch) {
                    return;
                }
                self.monitor_ready.set(result.is_ok());
                if result == Err(worker::PREFERENCE_CHANGED) {
                    self.preference_error.set(true);
                    self.settings();
                }
                self.monitor_error.set(result.err().map(|error| error.0));
                self.status(
                    self.monitor_error
                        .get()
                        .unwrap_or("Collecting new text copies · retained locally for seven days."),
                );
            }
            Reply::Recorded(result) => match result {
                Ok(_) => {
                    if self.view_allowed() {
                        self.load();
                    }
                }
                Err(error) if error != history::CANCELLED => self.status(error.0),
                _ => (),
            },
            Reply::View { sequence, result } => {
                if sequence != self.view_sequence.get()
                    || !self.view_allowed()
                    || self
                        .view_ticket
                        .borrow()
                        .as_ref()
                        .is_none_or(|ticket| ticket.check().is_err())
                {
                    return;
                }
                match result {
                    Ok(entries) => {
                        if let Some(window) = self.window.borrow().as_ref() {
                            *window.entries.borrow_mut() = entries;
                            window.render();
                            window.status.set_text(if let Some(error) = self.monitor_error.get() { error }
                            else if self.preference.borrow().enabled && self.monitor_ready.get()
                                && self.worker.control.capture_epoch().is_some() {
                                "Collecting new text copies · retained locally for seven days."
                            } else if self.preference.borrow().enabled {
                                "Collection paused · retained history can still be viewed or deleted."
                            } else {
                                "Collection off · retained history can still be viewed or deleted."
                            });
                        }
                    }
                    Err(error) => self.status(error.0),
                }
            }
            Reply::Cleared { epoch, result } => {
                if self.settings_epoch.get() != Some(epoch) {
                    return;
                }
                self.settings_epoch.set(None);
                match result {
                    Ok(()) => {
                        self.settings_busy.set(false);
                        self.capture_connection();
                        self.settings();
                        self.load();
                    }
                    Err(error) => {
                        self.settings_busy.set(false);
                        self.settings();
                        self.status(error.0);
                    }
                }
            }
        }
    }
    fn settings(&self) {
        if let Some(window) = self.window.borrow().as_ref() {
            window
                .enable
                .set_label(if self.preference.borrow().enabled {
                    "Turn Off Collection"
                } else {
                    "Enable Clipboard History…"
                });
            window
                .enable
                .set_sensitive(!self.settings_busy.get() && !self.preference_error.get());
            window.reset.set_visible(self.preference_error.get());
        }
    }
    fn preference(self: &Rc<Self>, enabled: bool, apps: Vec<String>, reset: bool) {
        self.settings_busy.set(true);
        let epoch = self.worker.control.pause();
        self.stop_capture();
        self.settings_epoch.set(Some(epoch));
        self.scrub();
        self.settings();
        let command = if reset {
            Command::ResetPreference { epoch }
        } else {
            Command::Preference {
                epoch,
                enabled,
                apps,
            }
        };
        if let Err(error) = self.worker.send(command) {
            self.preference_error.set(true);
            self.settings_busy.set(false);
            self.settings();
            self.status(error.0);
        }
    }
    fn confirm(
        self: &Rc<Self>,
        heading: &str,
        body: &str,
        response: &str,
        action: impl FnOnce(Rc<Self>) + 'static,
    ) {
        if !self.view_allowed() {
            self.status("An observable, unlocked desktop is required.");
            return;
        }
        let Some(window) = self.window.borrow().clone() else {
            return;
        };
        let dialog = adw::AlertDialog::builder()
            .heading(heading)
            .body(body)
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("confirm", response)]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        *self.dialog.borrow_mut() = Some(dialog.clone());
        let this = self.clone();
        let generation = self.view_sequence.get();
        glib::spawn_future_local(async move {
            let response = dialog.choose_future(Some(&window.window)).await;
            this.dialog.borrow_mut().take();
            if response == "confirm"
                && this.view_allowed()
                && generation == this.view_sequence.get()
            {
                action(this);
            }
        });
    }
    pub fn present(self: &Rc<Self>, app: &adw::Application) {
        self.monitor();
        if self.window.borrow().is_none() {
            *self.window.borrow_mut() = Some(HistoryWindow::new(self, app));
        }
        self.settings();
        self.window.borrow().as_ref().unwrap().window.present();
        if self.preference_error.get() {
            self.status("History settings are unreadable. Reset settings to disable collection and keep retained data.");
        }
    }
    fn selected(&self) -> Option<Zeroizing<String>> {
        if !self.view_allowed() {
            return None;
        }
        let window = self.window.borrow().clone()?;
        let id = window.selected.get()?;
        window
            .entries
            .borrow()
            .iter()
            .find(|entry| entry.id == id)
            .map(|entry| Zeroizing::new(entry.text().into()))
    }
    fn copy(&self) {
        let Some(text) = self.selected() else {
            return;
        };
        let Some(display) = gdk::Display::default() else {
            return;
        };
        let provider = internal_clipboard_provider(&text);
        if display.clipboard().set_content(Some(&provider)).is_err() {
            self.status("The clipboard could not be updated.");
        } else {
            self.status("Copied literal history text.");
        }
    }
}
impl HistoryWindow {
    fn new(service: &Rc<Service>, app: &adw::Application) -> Rc<Self> {
        let window = adw::ApplicationWindow::builder()
            .application(app)
            .title("Clipboard History")
            .default_width(960)
            .default_height(680)
            .build();
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 12);
        window.set_content(Some(&layout));
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Clipboard History",
            "This computer only",
        )));
        layout.append(&header);
        let privacy = label(
            "Copied text can include passwords and other secrets. History is encrypted locally, never synced, and retained for seven days; at most 1,000 entries / 32 MiB. Sensitivity hints and app exclusions cannot detect every secret.",
            "",
        );
        privacy.set_wrap(true);
        privacy.set_margin_start(16);
        privacy.set_margin_end(16);
        layout.append(&privacy);
        let controls = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let enable = gtk::Button::with_label("Enable Clipboard History…");
        let exclusions = gtk::Button::with_label("App Exclusions…");
        let reset = gtk::Button::with_label("Reset History Settings…");
        let refresh = gtk::Button::with_label("Refresh");
        for widget in [&enable, &exclusions, &reset, &refresh] {
            controls.append(widget);
        }
        layout.append(&controls);
        let query = gtk::SearchEntry::builder()
            .placeholder_text("Search copied text")
            .build();
        layout.append(&query);
        let rows = gtk::ListBox::new();
        let preview = gtk::TextView::builder()
            .editable(false)
            .cursor_visible(false)
            .wrap_mode(gtk::WrapMode::WordChar)
            .left_margin(16)
            .right_margin(16)
            .build();
        preview.buffer().set_enable_undo(false);
        let pane = gtk::Paned::builder()
            .orientation(gtk::Orientation::Horizontal)
            .start_child(&scrolled(&rows))
            .end_child(&scrolled(&preview))
            .position(360)
            .vexpand(true)
            .build();
        layout.append(&pane);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let copy = gtk::Button::with_label("Copy");
        let create = gtk::Button::with_label("Create Ordinary Snippet…");
        let delete = gtk::Button::with_label("Delete Entry…");
        let clear = gtk::Button::with_label("Clear History…");
        let more = gtk::Button::with_label("Show More");
        for widget in [&copy, &create, &delete, &clear, &more] {
            actions.append(widget);
        }
        layout.append(&actions);
        let status = label("Collection off.", "dim-label");
        status.set_wrap(true);
        layout.append(&status);
        let this = Rc::new(Self {
            window,
            status,
            enable,
            reset,
            query,
            rows,
            preview,
            entries: RefCell::new(Vec::new()),
            visible: RefCell::new(Vec::new()),
            selected: Cell::new(None),
            copy,
            create,
            delete,
            more,
            limit: Cell::new(50),
        });
        let weak = Rc::downgrade(service);
        this.window.connect_is_active_notify(move |window| {
            if let Some(service) = weak.upgrade() {
                if window.is_active() {
                    service.load();
                } else {
                    service.scrub();
                }
            }
        });
        let weak = Rc::downgrade(service);
        this.window.connect_close_request(move |window| {
            if let Some(service) = weak.upgrade() {
                service.scrub();
            }
            window.set_visible(false);
            glib::Propagation::Stop
        });
        let weak = Rc::downgrade(&this);
        this.query.connect_search_changed(move |_| {
            if let Some(window) = weak.upgrade() {
                window.limit.set(50);
                window.render();
            }
        });
        let weak = Rc::downgrade(&this);
        this.more.connect_clicked(move |_| {
            if let Some(window) = weak.upgrade() {
                window
                    .limit
                    .set((window.limit.get() + 50).min(history::MAX_ENTRIES));
                window.render();
            }
        });
        let weak = Rc::downgrade(&this);
        this.rows.connect_row_selected(move |_, row| {
            if let Some(window) = weak.upgrade() {
                let id =
                    row.and_then(|row| window.visible.borrow().get(row.index() as usize).copied());
                window.selected.set(id);
                let entries = window.entries.borrow();
                let selected = id.and_then(|id| entries.iter().find(|entry| entry.id == id));
                window
                    .preview
                    .buffer()
                    .set_text(selected.map_or("", Entry::text));
                for button in [&window.copy, &window.create, &window.delete] {
                    button.set_sensitive(selected.is_some());
                }
            }
        });
        let weak = Rc::downgrade(service);
        this.copy.connect_clicked(move |_| {
            if let Some(service) = weak.upgrade() {
                service.copy();
            }
        });
        let weak = Rc::downgrade(service);
        this.enable.connect_clicked(move |_| {
            if let Some(service) = weak.upgrade() {
                let apps = service.preference.borrow().excluded_apps.clone();
                if service.preference.borrow().enabled { service.preference(false, apps, false); }
                else { service.confirm("Enable Clipboard History?", "Keep future text copies on this computer for seven days? They can contain passwords or other secrets. The history uses a separate system-keyring key and is never synced. App exclusions and sensitivity hints are best-effort.", "Enable", move |service| service.preference(true, apps, false)); }
            }
        });
        let weak = Rc::downgrade(service);
        this.reset.connect_clicked(move |_| { if let Some(service) = weak.upgrade() {
            service.confirm("Reset History Settings?", "Turn collection off and restore default app exclusions. Retained history stays intact.", "Reset Settings", |service| service.preference(false, vec![], true));
        } });
        let weak = Rc::downgrade(service);
        refresh.connect_clicked(move |_| {
            if let Some(service) = weak.upgrade() {
                service.load();
            }
        });
        let weak = Rc::downgrade(service);
        clear.connect_clicked(move |_| { if let Some(service) = weak.upgrade() {
            service.confirm("Clear Clipboard History?", "Delete all retained clipboard history on this computer. Snippets and the current clipboard stay intact.", "Clear History", |service| {
                let epoch = service.worker.control.pause(); service.stop_capture(); service.scrub(); service.settings_busy.set(true); service.settings();
                service.settings_epoch.set(Some(epoch));
                if let Err(error) = service.worker.send(Command::Clear { epoch }) { service.settings_busy.set(false); service.settings(); service.status(error.0); }
            });
        } });
        let weak = Rc::downgrade(service);
        this.delete.connect_clicked(move |_| { if let Some(service) = weak.upgrade() {
            let id = service.window.borrow().as_ref().and_then(|window| window.selected.get());
            if let Some(id) = id { service.confirm("Delete History Entry?", "Remove this retained copy from history. Snippets and the current clipboard stay intact.", "Delete Entry", move |service| {
                service.worker.control.viewing(true);
                let Some(ticket) = service.ticket(true) else { return; };
                let sequence = service.view_sequence.get().wrapping_add(1); service.view_sequence.set(sequence);
                *service.view_ticket.borrow_mut() = Some(ticket.clone());
                if let Err(error) = service.worker.send(Command::Delete { sequence, ticket, id }) { service.status(error.0); }
            }); }
        } });
        let weak = Rc::downgrade(service);
        this.create.connect_clicked(move |_| { if let Some(service) = weak.upgrade()
            && let Some(text) = service.selected() {
                service.confirm("Create Ordinary Snippet?", "Place the selected text in the ordinary snippet editor. Saved ordinary snippets can sync to your cloud library. Clipboard history itself stays local.", "Create Snippet", move |service| (service.create)(&text));
        } });
        let weak = Rc::downgrade(service);
        exclusions.connect_clicked(move |_| { if let Some(service) = weak.upgrade() {
            if !service.view_allowed() || service.settings_busy.get() { return; }
            let input = gtk::TextView::new();
            input.buffer().set_text(&service.preference.borrow().excluded_apps.join("\n"));
            input.set_size_request(400, 180);
            let dialog = adw::AlertDialog::builder().heading("App Exclusions")
                .body("Foreground Hyprland app classes to exclude, one per line. This hint cannot identify every clipboard source or secret.")
                .extra_child(&scrolled(&input)).build();
            dialog.add_responses(&[("cancel","Cancel"),("save","Save Exclusions")]);
            dialog.set_default_response(Some("cancel")); dialog.set_close_response("cancel");
            *service.dialog.borrow_mut() = Some(dialog.clone());
            let generation = service.view_sequence.get();
            let window = service.window.borrow().as_ref().unwrap().window.clone();
            glib::spawn_future_local(async move {
                let choice = dialog.choose_future(Some(&window)).await; service.dialog.borrow_mut().take();
                if choice != "save" || !service.view_allowed() || generation != service.view_sequence.get() { return; }
                let buffer = input.buffer();
                let apps = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).lines().map(String::from).collect();
                let enabled = service.preference.borrow().enabled;
                service.preference(enabled, apps, false);
            });
        } });
        this.render();
        this
    }
    fn render(&self) {
        self.selected.set(None);
        self.preview.buffer().set_text("");
        clear_rows(&self.rows);
        let entries = self.entries.borrow();
        let ids = history::search(self.query.text().as_str(), &entries);
        *self.visible.borrow_mut() = ids.iter().take(self.limit.get()).copied().collect();
        for id in self.visible.borrow().iter() {
            let Some(entry) = entries.iter().find(|entry| entry.id == *id) else {
                continue;
            };
            let preview = Zeroizing::new(entry.text().chars().take(180).collect::<String>());
            let text = label(&preview, "");
            text.set_ellipsize(gtk::pango::EllipsizeMode::End);
            text.set_margin_start(16);
            text.set_margin_end(16);
            text.set_margin_top(12);
            text.set_margin_bottom(12);
            self.rows.append(&text);
        }
        self.more.set_visible(ids.len() > self.limit.get());
        for button in [&self.copy, &self.create, &self.delete] {
            button.set_sensitive(false);
        }
    }
}

#[cfg(test)]
#[path = "clipboard_history_live_tests.rs"]
mod live_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a display; empty temporary history, no keyring/PAM/network/clipboard reads"]
    fn native_disabled_history_scrubs_without_touching_clipboard_or_keys() {
        adw::init().expect("graphical display");
        let root = tempfile::tempdir().unwrap();
        let service = Service::new(root.path().into(), |_| panic!("snippet creation")).unwrap();
        assert!(service.collectors.borrow().is_empty() && service.desktop.borrow().is_none());
        let app = adw::Application::builder()
            .application_id("com.khm.snippets.linux.HistorySmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        app.register(None::<&gio::Cancellable>).unwrap();
        service.present(&app);
        service.scrub();
        assert!(
            service
                .window
                .borrow()
                .as_ref()
                .unwrap()
                .entries
                .borrow()
                .is_empty()
        );
        assert!(
            !root.path().join("secret-owner.bin").exists()
                && !root.path().join("ClipboardHistory").exists()
        );
        service.window.borrow().as_ref().unwrap().window.close();
    }
}
