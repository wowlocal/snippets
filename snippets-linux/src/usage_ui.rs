//! Native local-learning controls; no snippet bodies or identifiers enter this view.
use super::*;
use crate::usage_store::Handle;

pub(super) struct Settings {
    pub window: adw::ApplicationWindow,
    overlay: adw::ToastOverlay,
    handle: Handle,
    ranking: gtk::CheckButton,
    memory: gtk::CheckButton,
    counts: gtk::Label,
    resets: Vec<gtk::Button>,
    updating: Cell<bool>,
    changed: Box<dyn Fn()>,
    dialog: RefCell<Option<adw::AlertDialog>>,
}
impl Settings {
    pub fn new(
        application: &adw::Application,
        handle: Handle,
        changed: impl Fn() + 'static,
    ) -> Rc<Self> {
        let window = adw::ApplicationWindow::builder()
            .application(application)
            .title("Suggestion Learning")
            .default_width(540)
            .default_height(430)
            .build();
        window.set_hide_on_close(true);
        let overlay = adw::ToastOverlay::new();
        window.set_content(Some(&overlay));
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 16);
        overlay.set_child(Some(&layout));
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Suggestion Learning",
            "Local to this computer",
        )));
        layout.append(&header);
        let content = gtk::Box::new(gtk::Orientation::Vertical, 16);
        content.set_margin_start(24);
        content.set_margin_end(24);
        content.set_margin_bottom(24);
        layout.append(&content);
        content.append(&label("The picker learns from successful copy, paste and expansion actions. Match quality and pins keep priority. The library list keeps its usual order.", ""));
        let ranking = gtk::CheckButton::with_label("Prefer frequently used snippets in the picker");
        let memory =
            gtk::CheckButton::with_label("Remember short search prefixes and chosen snippets");
        content.append(&ranking);
        content.append(&memory);
        content.append(&label("Turning prefix memory off erases those choices. Turning frequency ranking off keeps collecting usage counts. Counts and prefixes stay in private local files; they are excluded from sync, export and encrypted backups. Snippet bodies, names, tags and clipboard text are never stored in this history.", "dim-label"));
        let counts = label("Loading local learning…", "");
        content.append(&counts);
        let mut resets = Vec::new();
        for title in [
            "Reset Usage Counts…",
            "Forget Prefix Choices…",
            "Reset All Learning…",
        ] {
            let button = gtk::Button::with_label(title);
            content.append(&button);
            resets.push(button);
        }
        let this = Rc::new(Self {
            window,
            overlay,
            handle,
            ranking,
            memory,
            counts,
            resets,
            updating: Cell::new(false),
            changed: Box::new(changed),
            dialog: RefCell::new(None),
        });
        for toggle in [&this.ranking, &this.memory] {
            let weak = Rc::downgrade(&this);
            toggle.connect_toggled(move |_| {
                let Some(this) = weak.upgrade() else {
                    return;
                };
                if this.updating.get() {
                    return;
                }
                match this
                    .handle
                    .preferences(this.ranking.is_active(), this.memory.is_active())
                {
                    Ok(()) => (this.changed)(),
                    Err(error) => this.overlay.add_toast(adw::Toast::new(error.0)),
                }
                this.refresh();
            });
        }
        for (i, button) in this.resets.iter().enumerate() {
            let weak = Rc::downgrade(&this);
            button.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.reset(i != 1, i != 0);
                }
            });
        }
        let weak = Rc::downgrade(&this);
        this.window.connect_close_request(move |_| {
            if let Some(this) = weak.upgrade()
                && let Some(dialog) = this.dialog.borrow_mut().take()
            {
                dialog.force_close();
            }
            glib::Propagation::Proceed
        });
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            this.refresh();
            glib::ControlFlow::Continue
        });
        this.refresh();
        this
    }
    fn refresh(&self) {
        let status = self.handle.status();
        self.updating.set(true);
        self.ranking.set_active(status.ranking);
        self.memory.set_active(status.memory);
        self.updating.set(false);
        let available =
            status.ready && status.writable && !status.busy && self.dialog.borrow().is_none();
        self.ranking.set_sensitive(available);
        self.memory.set_sensitive(available);
        for button in &self.resets {
            button.set_sensitive(available);
        }
        self.counts.set_text(if let Some(error) = &status.error {
            error.0
        } else if !status.ready {
            "Loading local learning…"
        } else if status.busy {
            "Saving local learning settings…"
        } else {
            ""
        });
        if status.ready && !status.busy && status.error.is_none() {
            self.counts.set_text(&format!(
                "{} snippet usage records · {} remembered prefixes",
                status.records, status.prefixes
            ));
        }
    }
    fn reset(self: &Rc<Self>, records: bool, bindings: bool) {
        if self.dialog.borrow().is_some() {
            return;
        }
        let dialog = reset_dialog(records, bindings);
        *self.dialog.borrow_mut() = Some(dialog.clone());
        self.refresh();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let response = dialog.choose_future(Some(&this.window)).await;
            this.dialog.borrow_mut().take();
            if response == "reset" {
                match this.handle.reset(records, bindings) {
                    Ok(()) => (this.changed)(),
                    Err(error) => this.overlay.add_toast(adw::Toast::new(error.0)),
                }
            }
            this.refresh();
        });
    }
}
fn reset_dialog(records: bool, bindings: bool) -> adw::AlertDialog {
    let body = match (records, bindings) {
        (true, true) => {
            "Erase local usage counts and remembered prefix choices? Snippets remain in the library."
        }
        (true, false) => "Erase local usage counts? Remembered prefix choices and snippets remain.",
        _ => "Erase remembered prefix choices? Usage counts and snippets remain.",
    };
    let dialog = adw::AlertDialog::builder()
        .heading("Reset Local Learning?")
        .body(body)
        .build();
    dialog.add_responses(&[("cancel", "Cancel"), ("reset", "Reset")]);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.set_response_appearance("reset", adw::ResponseAppearance::Destructive);
    dialog.set_body_use_markup(false);
    dialog
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; temporary local usage files only"]
    fn native_learning_settings_keep_reset_cancelled_by_default_and_show_private_local_scope() {
        adw::init().expect("graphical display");
        let temporary = tempfile::tempdir().unwrap();
        let library = Library::open(temporary.path().join("Public learning fixture")).unwrap();
        let handle = Handle::start(library.root.clone());
        let start = std::time::Instant::now();
        while !handle.status().ready {
            assert!(start.elapsed() < Duration::from_secs(3));
            std::thread::sleep(Duration::from_millis(5));
        }
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.LearningSmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let settings = Settings::new(&application, handle, || {});
        settings.window.present();
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
        assert!(settings.window.is_realized());
        assert!(settings.ranking.is_active() && settings.memory.is_active());
        assert!(settings.ranking.is_sensitive() && settings.memory.is_sensitive());
        assert_eq!(
            settings.counts.text(),
            "0 snippet usage records · 0 remembered prefixes"
        );
        for (records, bindings) in [(true, true), (true, false), (false, true)] {
            let dialog = reset_dialog(records, bindings);
            assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
            assert_eq!(dialog.close_response(), "cancel");
            assert!(!dialog.is_body_use_markup());
        }
        assert!(!library.path().exists());
        assert!(!library.root.join("Sync").exists());
        settings.window.close();
        settings.window.destroy();
    }
}
