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
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Automatic)
            .vexpand(true)
            .child(&content)
            .build();
        layout.append(&scroll);
        let explanation = label(
            "The picker learns from successful copy, paste and expansion actions. Match quality and pins keep priority. The library list keeps its usual order.",
            "",
        );
        explanation.set_wrap(true);
        content.append(&explanation);
        let ranking = gtk::CheckButton::with_label("Prefer frequently used snippets in the picker");
        let memory =
            gtk::CheckButton::with_label("Remember short search prefixes and chosen snippets");
        content.append(&ranking);
        content.append(&memory);
        let privacy = label(
            "Turning prefix memory off erases those choices. Turning frequency ranking off keeps collecting usage counts. Counts and prefixes stay in private local files; they are excluded from sync, export and encrypted backups. Snippet bodies, names, tags and clipboard text are never stored in this history.",
            "dim-label",
        );
        privacy.set_wrap(true);
        content.append(&privacy);
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
    // libadwaita's compact heading changes its measured height when `short`
    // toggles. Invalidate the children too: resizing only the outer contents
    // can retain an incompatible height in the message area's GTK cache.
    let short = Cell::new(dialog.has_css_class("short"));
    dialog.connect_css_classes_notify(move |dialog| {
        let next = dialog.has_css_class("short");
        if short.replace(next) == next {
            return;
        }
        let mut pending = dialog.first_child().into_iter().collect::<Vec<_>>();
        while let Some(widget) = pending.pop() {
            if let Some(child) = widget.first_child() {
                pending.push(child);
            }
            if let Some(sibling) = widget.next_sibling() {
                pending.push(sibling);
            }
            widget.queue_resize();
        }
    });
    dialog
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt, path::Path, time::Instant};
    use uuid::Uuid;

    fn until(done: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !done() {
            assert!(
                Instant::now() < deadline,
                "The native learning operation timed out."
            );
            while glib::MainContext::default().pending() {
                glib::MainContext::default().iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    fn flush(handle: &Handle) {
        let reply = handle.flush();
        until(|| match reply.try_recv() {
            Ok(result) => {
                result.unwrap();
                true
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => false,
            Err(_) => panic!("The owned learning worker stopped before its flush."),
        });
        let status = handle.status();
        assert!(status.ready && status.writable && !status.busy && status.error.is_none());
    }
    fn available(settings: &Settings, records: usize, prefixes: usize) {
        until(|| {
            let status = settings.handle.status();
            assert!(status.error.is_none());
            !status.busy
                && status.records == records
                && status.prefixes == prefixes
                && settings.counts.text()
                    == format!("{records} snippet usage records · {prefixes} remembered prefixes")
                && settings.ranking.is_sensitive()
                && settings.memory.is_sensitive()
                && settings.resets.iter().all(|button| button.is_sensitive())
        });
    }
    fn respond(settings: &Settings, label: &str, body: &str) {
        until(|| {
            settings
                .dialog
                .borrow()
                .as_ref()
                .is_some_and(|dialog| dialog.is_mapped())
        });
        let dialog = settings.dialog.borrow().as_ref().unwrap().clone();
        assert_eq!(dialog.heading().as_deref(), Some("Reset Local Learning?"));
        assert_eq!(dialog.body(), body);
        assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
        assert_eq!(dialog.close_response(), "cancel");
        assert!(!dialog.is_body_use_markup());
        assert!(!settings.ranking.is_sensitive() && !settings.memory.is_sensitive());
        assert!(settings.resets.iter().all(|button| !button.is_sensitive()));
        let mut pending = vec![dialog.upcast::<gtk::Widget>()];
        let mut matches = Vec::new();
        while let Some(widget) = pending.pop() {
            if let Ok(button) = widget.clone().downcast::<gtk::Button>()
                && button.label().as_deref() == Some(label)
            {
                matches.push(button);
            }
            let mut child = widget.first_child();
            while let Some(widget) = child {
                child = widget.next_sibling();
                pending.push(widget);
            }
        }
        assert_eq!(matches.len(), 1);
        until(|| matches[0].is_mapped() && settings.window.is_active());
        assert!(matches[0].is_sensitive());
        matches[0].emit_clicked();
        until(|| settings.dialog.borrow().is_none());
    }
    fn picker(app: &Rc<App>, preferred: Uuid, other: Uuid) -> Rc<Picker> {
        app.open_picker(None);
        let picker = app.picker.borrow().as_ref().unwrap().clone();
        until(|| picker.window.is_active() && picker.query.is_mapped());
        picker.query.set_text("re");
        let expected = [Uuid::from_u128(3), Uuid::from_u128(4), preferred, other];
        until(|| {
            picker
                .snippets
                .borrow()
                .iter()
                .map(|s| s.id)
                .collect::<Vec<_>>()
                == expected
        });
        assert_eq!(picker.rows.selected_row().unwrap().index(), 0);
        assert!(
            picker.query.is_focus()
                || gtk::prelude::RootExt::focus(&picker.window)
                    .is_some_and(|w| w.is_ancestor(&picker.query))
        );
        for index in 0..4 {
            assert!(picker.rows.row_at_index(index).is_some());
        }
        assert!(picker.rows.row_at_index(4).is_none());
        picker
    }
    fn workers_finished() -> bool {
        fs::read_dir("/proc/self/task").unwrap().all(|entry| {
            fs::read(entry.unwrap().path().join("comm"))
                .map_or(true, |name| name.trim_ascii() != b"snippets-usage")
        })
    }

    #[test]
    #[ignore = "requires the unlocked desktop; private bus and public local usage/library files, no clipboard/keyring/PAM/network"]
    fn native_learning_settings_picker_order_and_independent_resets() {
        assert!(
            std::env::var_os("SNIPPETS_LEARNING_LIVE").as_deref()
                == Some(std::ffi::OsStr::new("public-private-roots"))
        );
        assert!(crate::desktop::session_state() == crate::desktop::SessionState::Unlocked);
        adw::init().expect("graphical display");
        let temporary = tempfile::Builder::new()
            .prefix("snippets-learning-live.")
            .tempdir()
            .unwrap();
        let mut library = Library::open(temporary.path().join("Public learning fixture")).unwrap();
        let a = Uuid::from_u128(1);
        let b = Uuid::from_u128(2);
        for (id, name, keyword, pinned) in [
            (a, "Public Alpha", "reply", false),
            (b, "Public Beta", "refund", false),
            (Uuid::from_u128(3), "Public Exact", "re", false),
            (Uuid::from_u128(4), "Public Pin", "request", true),
        ] {
            let mut snippet = Snippet::new(name, "Public learning body preservation sentinel");
            snippet.id = id;
            snippet.keyword = keyword.into();
            snippet.is_pinned = pinned;
            snippet.created_at = id.as_u128() as f64;
            snippet.updated_at = snippet.created_at;
            library.save(snippet, None).unwrap();
        }
        let root = library.root.clone();
        let primary = fs::read(library.path()).unwrap();
        let handle = Handle::start(library.root.clone());
        until(|| handle.status().ready);
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.LearningSmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let app = Rc::new(App {
            application,
            library: RefCell::new(library),
            recovery_required: Cell::new(false),
            main: RefCell::new(None),
            picker: RefCell::new(None),
            secure: RefCell::new(None),
            hold: RefCell::new(None),
            account: RefCell::new(None),
            account_worker: RefCell::new(None),
            backup: RefCell::new(None),
            history: RefCell::new(None),
            inline: RefCell::new(None),
            control: RefCell::new(None),
            usage: RefCell::new(Some(handle.clone())),
            usage_settings: RefCell::new(None),
            settings: RefCell::new(None),
            diagnostics: RefCell::new(None),
            tray: RefCell::new(None),
            shortcuts: RefCell::new(None),
            quit_pending: Cell::new(false),
            quit_retry: RefCell::new(None),
            usage_quitting: Cell::new(false),
            copy_serial: Cell::new(0),
            css: gtk::CssProvider::new(),
            last_theme: RefCell::new(String::new()),
        });
        // Public pre-existing learning notifications, not a claim of physical copy/paste delivery.
        app.learn(a, crate::usage::Event::Paste, Some("re"));
        app.learn(b, crate::usage::Event::Copy, None);
        flush(&handle);
        let frozen = picker(&app, a, b);
        app.learn(b, crate::usage::Event::Paste, Some("re"));
        flush(&handle);
        let changes = Rc::new(RefCell::new(String::new()));
        let notify = changes.clone();
        frozen
            .query
            .connect_search_changed(move |query| *notify.borrow_mut() = query.text().to_string());
        frozen.query.set_text("r");
        until(|| changes.borrow().as_str() == "r");
        frozen.query.set_text("re");
        until(|| changes.borrow().as_str() == "re");
        assert_eq!(
            frozen
                .snippets
                .borrow()
                .iter()
                .map(|s| s.id)
                .collect::<Vec<_>>(),
            [Uuid::from_u128(3), Uuid::from_u128(4), a, b]
        );
        let current = picker(&app, b, a);
        app.open_usage();
        let settings = app.usage_settings.borrow().as_ref().unwrap().clone();
        until(|| {
            settings.window.is_active() && settings.resets.iter().all(|button| button.is_mapped())
        });
        available(&settings, 2, 1);
        assert!(settings.ranking.is_active() && settings.memory.is_active());
        let usage_path = root.join("Usage/usage.json");
        let original_usage = fs::read(&usage_path).unwrap();
        settings.resets[0].emit_clicked();
        respond(
            &settings,
            "Cancel",
            "Erase local usage counts? Remembered prefix choices and snippets remain.",
        );
        available(&settings, 2, 1);
        assert!(fs::read(&usage_path).unwrap() == original_usage);
        assert!(app.picker.borrow().is_some() && current.window.is_visible());
        settings.resets[0].emit_clicked();
        respond(
            &settings,
            "Reset",
            "Erase local usage counts? Remembered prefix choices and snippets remain.",
        );
        flush(&handle);
        available(&settings, 0, 1);
        assert!(app.picker.borrow().is_none() && !current.window.is_visible());
        app.learn(a, crate::usage::Event::Paste, None);
        flush(&handle);
        let remembered = picker(&app, b, a);
        settings.window.present();
        until(|| settings.window.is_active());
        available(&settings, 1, 1);
        settings.resets[1].emit_clicked();
        respond(
            &settings,
            "Reset",
            "Erase remembered prefix choices? Usage counts and snippets remain.",
        );
        flush(&handle);
        available(&settings, 1, 0);
        assert!(app.picker.borrow().is_none() && !remembered.window.is_visible());
        let frequent = picker(&app, a, b);
        settings.window.present();
        until(|| settings.window.is_active());
        settings.ranking.set_active(false);
        flush(&handle);
        available(&settings, 1, 0);
        assert!(app.picker.borrow().is_none() && !frequent.window.is_visible());
        assert!(!settings.ranking.is_active());
        app.learn(a, crate::usage::Event::Copy, None);
        app.learn(b, crate::usage::Event::Expansion, Some("re"));
        flush(&handle);
        available(&settings, 2, 1);
        let memory_only = picker(&app, b, a);
        settings.window.present();
        until(|| settings.window.is_active());
        settings.memory.set_active(false);
        flush(&handle);
        available(&settings, 2, 0);
        assert!(app.picker.borrow().is_none() && !memory_only.window.is_visible());
        let unranked = picker(&app, b, a);
        settings.window.present();
        until(|| settings.window.is_active());
        settings.ranking.set_active(true);
        flush(&handle);
        available(&settings, 2, 0);
        assert!(app.picker.borrow().is_none() && !unranked.window.is_visible());
        let ranked = picker(&app, a, b);
        let data: serde_json::Value =
            serde_json::from_slice(&fs::read(&usage_path).unwrap()).unwrap();
        assert_eq!(data["w"][a.to_string()]["n"], 2);
        assert_eq!(data["w"][b.to_string()]["n"], 1);
        settings.window.present();
        until(|| settings.window.is_active());
        settings.resets[2].emit_clicked();
        respond(
            &settings,
            "Reset",
            "Erase local usage counts and remembered prefix choices? Snippets remain in the library.",
        );
        flush(&handle);
        available(&settings, 0, 0);
        assert!(app.picker.borrow().is_none() && !ranked.window.is_visible());
        settings.ranking.set_active(false);
        flush(&handle);
        available(&settings, 0, 0);
        println!(
            "Mapped picker preserves its frozen order, exact-match/pin priority and learned correction; independent native resets and toggles preserve library data."
        );
        settings.window.close();
        settings.window.destroy();
        app.usage_settings.borrow_mut().take();
        drop(settings);
        app.usage.borrow_mut().take();
        drop(handle);
        until(workers_finished);
        let reopened = Handle::start(root.clone());
        until(|| reopened.status().ready);
        *app.usage.borrow_mut() = Some(reopened.clone());
        app.open_usage();
        let settings = app.usage_settings.borrow().as_ref().unwrap().clone();
        until(|| settings.window.is_active() && settings.ranking.is_mapped());
        available(&settings, 0, 0);
        assert!(!settings.ranking.is_active() && !settings.memory.is_active());
        flush(&reopened);
        let default = picker(&app, b, a);
        default.window.close();
        app.picker.borrow_mut().take();
        assert!(fs::read(app.library.borrow().path()).unwrap() == primary);
        for name in ["Vault", "Sync", "Diagnostics"] {
            assert!(!root.join(name).exists());
        }
        assert_eq!(
            fs::metadata(root.join("Usage"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        for name in ["usage.json", "preferences.json", "usage.lock"] {
            let path = root.join("Usage").join(name);
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            if Path::new(name)
                .extension()
                .is_some_and(|extension| extension == "json")
            {
                let text = fs::read_to_string(path).unwrap();
                assert!(
                    !text.contains("Public") && !text.contains("reply") && !text.contains("refund")
                );
            }
        }
        settings.window.close();
        settings.window.destroy();
        app.usage_settings.borrow_mut().take();
        drop(settings);
        app.usage.borrow_mut().take();
        drop(reopened);
        until(workers_finished);
        println!(
            "Native settings and reset markers survive a fresh worker; private usage files contain no fixture bodies/names/keywords; no clipboard or account was used."
        );
    }
}
