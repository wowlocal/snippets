//! Native ordinary-editor keyword assistance and a deliberately opened preview.
use super::*;
use crate::editor_assistance::{self as assistance, Body, Summary};
use zeroize::Zeroizing;

const CANCELLED: Error = Error("Preview was cancelled. Open it again to refresh.");
pub(super) struct Assistance {
    pub row: gtk::Box,
    pub preview_button: gtk::MenuButton,
    chips: gtk::FlowBox,
    warning: gtk::Label,
    popover: gtk::Popover,
    preview_text: gtk::Label,
    rendered: RefCell<Option<Summary>>,
    update: RefCell<Option<glib::SourceId>>,
    serial: Cell<u64>,
    task: RefCell<Option<glib::JoinHandle<()>>>,
    monitor: RefCell<Option<desktop::SessionMonitor>>,
    preview_epoch: Cell<Option<u64>>,
}
impl Assistance {
    pub fn new() -> Rc<Self> {
        let row = gtk::Box::new(gtk::Orientation::Vertical, 4);
        let chips = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .homogeneous(false)
            .row_spacing(4)
            .column_spacing(4)
            .min_children_per_line(1)
            .max_children_per_line(4)
            .build();
        row.append(&chips);
        let warning = gtk::Label::builder()
            .wrap(true)
            .xalign(0.0)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .max_width_chars(60)
            .build();
        warning.add_css_class("warning");
        row.append(&warning);
        row.set_visible(false);
        let preview_text = gtk::Label::builder()
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .selectable(true)
            .xalign(0.0)
            .yalign(0.0)
            .max_width_chars(58)
            .width_chars(38)
            .build();
        let scroll = gtk::ScrolledWindow::builder()
            .child(&preview_text)
            .min_content_width(320)
            .max_content_height(240)
            .propagate_natural_height(true)
            .build();
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        content.set_margin_start(12);
        content.set_margin_end(12);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.append(&label("RESOLVED PREVIEW", "caption"));
        content.append(&scroll);
        content.append(&label(
            "A snapshot; Copy resolves the placeholders again.",
            "dim-label",
        ));
        let popover = gtk::Popover::builder().child(&content).build();
        let preview_button = gtk::MenuButton::builder()
            .label("Preview…")
            .popover(&popover)
            .sensitive(false)
            .tooltip_text("Preview date, time and clipboard placeholders")
            .build();
        Rc::new(Self {
            row,
            preview_button,
            chips,
            warning,
            popover,
            preview_text,
            rendered: RefCell::new(None),
            update: RefCell::new(None),
            serial: Cell::new(0),
            task: RefCell::new(None),
            monitor: RefCell::new(None),
            preview_epoch: Cell::new(None),
        })
    }
    pub fn attach(self: &Rc<Self>, main: &Rc<MainWindow>) {
        let weak = Rc::downgrade(main);
        self.popover.connect_show(move |_| {
            if let Some(main) = weak.upgrade() {
                main.assistance.open_preview(&main);
            }
        });
        let weak = Rc::downgrade(self);
        self.popover.connect_closed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.scrub();
            }
        });
        let weak = Rc::downgrade(main);
        main.window.connect_is_active_notify(move |window| {
            if !window.is_active()
                && let Some(main) = weak.upgrade()
            {
                main.assistance.invalidate();
            }
        });
        let weak = Rc::downgrade(main);
        main.window.connect_visible_notify(move |window| {
            if !window.is_visible()
                && let Some(main) = weak.upgrade()
            {
                main.assistance.invalidate();
            }
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(main);
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            let Some(main) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if key == gdk::Key::Tab
                && !modifiers.intersects(
                    gdk::ModifierType::SHIFT_MASK
                        | gdk::ModifierType::CONTROL_MASK
                        | gdk::ModifierType::ALT_MASK
                        | gdk::ModifierType::SUPER_MASK
                        | gdk::ModifierType::META_MASK,
                )
                && main.keyword.selection_bounds().is_none()
                && main.keyword.position() == main.keyword.text().chars().count() as i32
                && main.assistance.complete(&main)
            {
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        main.keyword.add_controller(keys);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if let Some(epoch) = this.preview_epoch.get()
                && !this.monitor.borrow().as_ref().is_some_and(|monitor| {
                    monitor.snapshot() == (desktop::SessionState::Unlocked, epoch)
                })
            {
                this.invalidate();
            }
            glib::ControlFlow::Continue
        });
    }
    fn catalogue(main: &MainWindow) -> model::Result<Vec<Snippet>> {
        let app = main.app.upgrade().ok_or(CANCELLED)?;
        if app.recovery_required.get() || main.read_failed.get() || app.usage_quitting.get() {
            return Err(CANCELLED);
        }
        let id = main
            .current
            .borrow()
            .as_ref()
            .map(|s| s.id)
            .ok_or(CANCELLED)?;
        let (ordinary, secure) = app.library.borrow().try_catalogue()?;
        if secure.iter().any(|s| s.id == id) {
            return Err(CANCELLED);
        }
        Ok(ordinary
            .into_iter()
            .chain(secure.iter().map(|s| s.shell()))
            .collect())
    }
    fn summary(main: &MainWindow, catalogue: &[Snippet]) -> Option<Summary> {
        let id = main.current.borrow().as_ref()?.id;
        let end = main
            .buffer
            .iter_at_line(1)
            .unwrap_or_else(|| main.buffer.end_iter());
        let first_line = main.buffer.text(&main.buffer.start_iter(), &end, true);
        Some(assistance::summarize(
            id,
            &main.name.text(),
            &main.keyword.text(),
            main.enabled.is_active(),
            Body::OrdinaryFirstLine(&first_line),
            catalogue,
        ))
    }
    pub fn queue(self: &Rc<Self>, main: &Rc<MainWindow>) {
        self.invalidate();
        if let Some(source) = self.update.borrow_mut().take() {
            source.remove();
        }
        let weak = Rc::downgrade(main);
        *self.update.borrow_mut() = Some(glib::timeout_add_local_once(
            Duration::from_millis(120),
            move || {
                if let Some(main) = weak.upgrade() {
                    main.assistance.update.borrow_mut().take();
                    main.assistance.refresh(&main);
                }
            },
        ));
    }
    pub fn refresh(&self, main: &MainWindow) {
        let summary = Self::catalogue(main)
            .ok()
            .and_then(|library| Self::summary(main, &library));
        self.preview_button.set_sensitive(summary.is_some());
        if self.rendered.borrow().as_ref() == summary.as_ref() {
            return;
        }
        while let Some(child) = self.chips.first_child() {
            self.chips.remove(&child);
        }
        self.warning.set_label("");
        self.row.set_visible(false);
        if let Some(summary) = summary.as_ref() {
            for suggestion in &summary.suggestions {
                let button = gtk::Button::with_label(&format!("\\{suggestion}"));
                button.add_css_class("flat");
                button.set_tooltip_text(Some("Use this keyword"));
                let suggestion = suggestion.clone();
                let weak = main.app.clone();
                button.connect_clicked(move |_| {
                    if let Some(app) = weak.upgrade()
                        && let Some(main) = app.main.borrow().as_ref()
                    {
                        main.assistance.apply_suggestion(main, &suggestion);
                    }
                });
                self.chips.insert(&button, -1);
            }
            if !summary.references.is_empty() {
                self.chips.insert(&label("Existing", "dim-label"), -1);
                for keyword in &summary.references {
                    let reference = gtk::Label::builder()
                        .label(format!("\\{keyword}"))
                        .ellipsize(gtk::pango::EllipsizeMode::End)
                        .max_width_chars(24)
                        .build();
                    reference.add_css_class("dim-label");
                    reference.set_tooltip_text(Some(
                        "Already belongs to another entry. Tab completes an unambiguous prefix.",
                    ));
                    self.chips.insert(&reference, -1);
                }
            }
            let mut messages = Vec::new();
            let warnings = &summary.warnings;
            if warnings.duplicates > 0 {
                messages.push(
                    "This keyword already belongs to another entry; it cannot be saved.".into(),
                );
            }
            if warnings.unsupported_trigger {
                messages.push("Inline expansion needs at most 120 single-character letters, digits or punctuation.".into());
            }
            if warnings.disabled {
                messages
                    .push("Disabled entries do not appear in the picker or expand inline.".into());
            }
            if warnings.blocked_by_longer > 0 {
                messages.push(format!(
                    "{} longer keyword(s) prevent this trigger from expanding automatically.",
                    warnings.blocked_by_longer
                ));
            }
            if warnings.blocks_shorter > 0 {
                messages.push(format!(
                    "This trigger stops {} shorter keyword(s) from expanding automatically.",
                    warnings.blocks_shorter
                ));
            }
            self.warning.set_label(&messages.join(" "));
            self.warning.set_visible(!messages.is_empty());
            self.row.set_visible(
                !summary.suggestions.is_empty()
                    || !summary.references.is_empty()
                    || !messages.is_empty(),
            );
        } else {
            self.invalidate();
        }
        *self.rendered.borrow_mut() = summary;
    }
    fn apply_suggestion(&self, main: &MainWindow, suggestion: &str) {
        let fresh = Self::catalogue(main)
            .ok()
            .and_then(|library| Self::summary(main, &library));
        if fresh.is_some_and(|summary| summary.suggestions.iter().any(|s| s == suggestion)) {
            main.keyword.set_text(suggestion);
            main.keyword.set_position(-1);
            main.keyword.grab_focus();
        } else {
            main.toast("Keywords changed. Review the current suggestions.");
            self.refresh(main);
        }
    }
    fn complete(&self, main: &MainWindow) -> bool {
        let Ok(library) = Self::catalogue(main) else {
            return false;
        };
        let Some(id) = main.current.borrow().as_ref().map(|s| s.id) else {
            return false;
        };
        let keys = library
            .into_iter()
            .filter(|s| s.id != id)
            .map(|s| s.keyword)
            .collect::<Vec<_>>();
        let Some(completion) = assistance::tab_completion(&main.keyword.text(), &keys) else {
            return false;
        };
        main.keyword.set_text(&completion);
        main.keyword.set_position(-1);
        true
    }
    fn scrub(&self) {
        self.serial.set(self.serial.get().wrapping_add(1));
        self.preview_epoch.set(None);
        self.preview_text.set_label("");
        if let Some(task) = self.task.borrow_mut().take() {
            task.abort();
        }
        self.monitor.borrow_mut().take();
    }
    pub fn invalidate(&self) {
        self.scrub();
        self.popover.popdown();
    }
    fn validate(&self, main: &MainWindow, serial: u64, epoch: Option<u64>) -> model::Result<()> {
        if self.serial.get() != serial
            || !self.popover.is_visible()
            || !main.window.is_active()
            || !main.window.is_visible()
        {
            return Err(CANCELLED);
        }
        if let Some(epoch) = epoch
            && !self.monitor.borrow().as_ref().is_some_and(|monitor| {
                monitor.snapshot() == (desktop::SessionState::Unlocked, epoch)
            })
        {
            return Err(CANCELLED);
        }
        Self::catalogue(main).map(|_| ())
    }
    fn open_preview(self: &Rc<Self>, main: &Rc<MainWindow>) {
        self.scrub();
        if Self::catalogue(main).is_err() {
            self.preview_text.set_label(CANCELLED.0);
            return;
        }
        let Some(draft) = main.draft() else {
            return;
        };
        let serial = self.serial.get();
        if !draft.content.contains("{clipboard}") {
            let result = placeholders::preview_at(&draft.content, "", chrono::Local::now());
            self.preview_text.set_label(if result.has_placeholder {
                &result.text
            } else {
                "No resolvable placeholders in this entry."
            });
            return;
        }
        self.preview_text.set_label("Reading a clipboard snapshot…");
        *self.monitor.borrow_mut() = desktop::SessionMonitor::new();
        let weak = Rc::downgrade(main);
        let task = glib::MainContext::default().spawn_local(async move {
            let Some(main) = weak.upgrade() else {
                return;
            };
            let this = &main.assistance;
            let result: model::Result<_> = async {
                let start = std::time::Instant::now();
                let epoch = loop {
                    this.validate(&main, serial, None)?;
                    if let Some((desktop::SessionState::Unlocked, epoch)) =
                        this.monitor.borrow().as_ref().map(|m| m.snapshot())
                    {
                        break epoch;
                    }
                    if start.elapsed() > Duration::from_secs(2) {
                        return Err(Error(
                            "Unlock the desktop before previewing clipboard text.",
                        ));
                    }
                    glib::timeout_future(Duration::from_millis(30)).await;
                };
                this.preview_epoch.set(Some(epoch));
                let clipboard = main.window.clipboard();
                let text = if clipboard.formats().contains_type(String::static_type()) {
                    crate::sensitive_clipboard::read(&clipboard, || {
                        this.validate(&main, serial, Some(epoch))
                    })
                    .await?
                } else {
                    Zeroizing::new(String::new())
                };
                this.validate(&main, serial, Some(epoch))?;
                Ok(placeholders::preview_at(
                    &draft.content,
                    &text,
                    chrono::Local::now(),
                ))
            }
            .await;
            if this.serial.get() != serial {
                return;
            }
            // A superseded read never clears the newer handle. Release our own
            // handle before a callback can close or replace this view.
            this.task.borrow_mut().take();
            match result {
                Ok(result)
                    if this
                        .validate(&main, serial, this.preview_epoch.get())
                        .is_ok() =>
                {
                    this.preview_text.set_label(&result.text);
                }
                Err(error) => this.preview_text.set_label(error.0),
                _ => this.invalidate(),
            }
        });
        *self.task.borrow_mut() = Some(task);
    }
}
impl Drop for Assistance {
    fn drop(&mut self) {
        if let Some(source) = self.update.get_mut().take() {
            source.remove();
        }
        if let Some(task) = self.task.get_mut().take() {
            task.abort();
        }
        self.preview_text.set_label("");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires an available graphical display; public temporary library, no clipboard or input writes"]
    fn native_editor_assistance_lifecycle() {
        adw::init().expect("graphical display");
        let directory = tempfile::tempdir().unwrap();
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.EditorAssistanceSmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let app = Rc::new(App {
            application,
            library: RefCell::new(Library::open(directory.path().into()).unwrap()),
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
            usage: RefCell::new(None),
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
        app.actions();
        let main = app.main();
        main.window.present();
        main.new_entry("Best regards\n{date:yyyy-MM-dd}");
        main.name.set_text("Signature Block");
        main.assistance.refresh(&main);
        let summary = main.assistance.rendered.borrow().clone().unwrap();
        assert_eq!(summary.suggestions, ["sign", "sig", "sb"]);
        // A saved concurrent keyword invalidates the visible suggestion before
        // its click can enter the field. The ordinary draft survives unchanged.
        let mut external = Library::open(directory.path().into()).unwrap();
        let mut reserved = Snippet::new("Public existing", "Public body");
        reserved.keyword = "sign-long".into();
        external.save(reserved, None).unwrap();
        main.assistance.apply_suggestion(&main, "sign");
        assert!(main.keyword.text().is_empty());
        assert!(
            main.assistance
                .rendered
                .borrow()
                .as_ref()
                .unwrap()
                .suggestions
                .contains(&"sb".into())
        );
        main.assistance.apply_suggestion(&main, "sb");
        assert_eq!(main.keyword.text(), "sb");
        assert!(main.dirty.get() && main.save());
        main.keyword.set_text("sig");
        assert!(main.assistance.complete(&main));
        assert_eq!(main.keyword.text(), "sign-");
        main.assistance.refresh(&main);
        assert_eq!(
            main.assistance
                .rendered
                .borrow()
                .as_ref()
                .unwrap()
                .warnings
                .blocked_by_longer,
            1
        );
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !main.window.is_active()
            || !main.assistance.preview_button.is_mapped()
            || main.assistance.preview_button.width() == 0
        {
            assert!(
                std::time::Instant::now() < deadline,
                "Preview needs its visible, allocated button in the active fixture window."
            );
            while glib::MainContext::default().pending() {
                glib::MainContext::default().iteration(false);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        main.assistance.popover.popup();
        assert!(!main.assistance.preview_text.label().is_empty());
        main.buffer.insert_at_cursor(" ordinary change");
        assert!(main.assistance.preview_text.label().is_empty());
        assert!(main.assistance.task.borrow().is_none());
        main.assistance.popover.popup();
        main.assistance.open_preview(&main);
        assert!(!main.assistance.preview_text.label().is_empty());
        main.show(None, None);
        assert!(main.assistance.preview_text.label().is_empty());
        assert!(!main.assistance.preview_button.is_sensitive());
        assert!(!main.assistance.row.is_visible());
        main.window.destroy();
    }
}
