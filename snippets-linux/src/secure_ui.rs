//! Native vault workspace. Expensive derivation is prepared on a worker; only
//! the GTK owner can install it after revalidating scope, generation and desktop.
use crate::{
    desktop::{self, SessionState},
    model::{Error, Library, Result},
    protected_editor::ProtectedEditor,
    vault::{Metadata, Vault},
};
use adw::prelude::*;
use gtk::glib;
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::mpsc,
    time::Duration,
};
use uuid::Uuid;
use zeroize::Zeroizing;
#[path = "draft_recovery_ui.rs"]
mod draft_recovery;
#[path = "secure_insertion_ui.rs"]
mod insertion;
#[path = "legacy_repair_ui.rs"]
mod legacy_repair;

async fn worker<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("snippets-vault".into())
        .spawn(move || {
            let _ = sender.send(operation());
        })
        .map_err(|_| Error("The authentication worker could not start."))?;
    loop {
        match receiver.try_recv() {
            Ok(result) => return result,
            Err(mpsc::TryRecvError::Disconnected) => {
                return Err(Error("The authentication worker stopped."));
            }
            Err(mpsc::TryRecvError::Empty) => glib::timeout_future(Duration::from_millis(30)).await,
        }
    }
}

fn label(text: &str) -> gtk::Label {
    let widget = gtk::Label::new(Some(text));
    widget.set_xalign(0.0);
    widget.set_wrap(true);
    widget
}
pub struct Workspace {
    pub window: adw::ApplicationWindow,
    library: Library,
    vault: Rc<RefCell<Vault>>,
    editor: Rc<ProtectedEditor>,
    overlay: adw::ToastOverlay,
    query: gtk::SearchEntry,
    rows: gtk::ListBox,
    visible: RefCell<Vec<Metadata>>,
    selected: Cell<Option<Uuid>>,
    name: gtk::Entry,
    keyword: gtk::Entry,
    tags: gtk::Entry,
    enabled: gtk::CheckButton,
    pin: gtk::CheckButton,
    status: gtk::Label,
    unlock: gtk::Button,
    reveal: gtk::ToggleButton,
    undo: gtk::Button,
    redo: gtk::Button,
    paste: gtk::Button,
    dirty: Cell<bool>,
    loading: Cell<bool>,
    busy: Cell<bool>,
    generation: Cell<u64>,
    reading_failed: Cell<bool>,
    desktop_was_allowed: Cell<bool>,
    desktop: Option<Rc<desktop::SessionMonitor>>,
    draft_recovery: gtk::Button,
    draft_dialog: RefCell<Option<(adw::AlertDialog, Vec<gtk::PasswordEntry>)>>,
    draft_authorization: RefCell<Option<(draft_recovery::Authorization, u64)>>,
    draft_worker: Cell<bool>,
    insert: gtk::Button,
    insertion_target: RefCell<Option<desktop::PasteTarget>>,
    insertion_authorization: RefCell<Option<crate::secure_insertion::Authorization>>,
    insertion_dialog: RefCell<Option<(adw::AlertDialog, gtk::PasswordEntry)>>,
    insertion_worker: Cell<bool>,
    insertion_armed: Cell<bool>,
    repair: gtk::Button,
    repair_authorization: RefCell<Option<crate::vault::legacy_repair::Authorization>>,
    repair_dialog: RefCell<Option<(adw::AlertDialog, gtk::PasswordEntry)>>,
    repair_worker: Cell<bool>,
    usage: RefCell<Option<crate::usage_store::Handle>>,
    selection_query: RefCell<Option<(Uuid, String)>>,
}
impl Workspace {
    pub fn attach_usage(&self, usage: Option<crate::usage_store::Handle>) {
        *self.usage.borrow_mut() = usage;
    }
    pub fn selection_query(&self, id: Uuid, query: &str) {
        *self.selection_query.borrow_mut() = crate::usage::prefix(query).map(|p| (id, p));
    }
    pub fn forget_selection_query(&self) {
        self.selection_query.borrow_mut().take();
    }
    pub fn new(application: &adw::Application, library: &Library) -> Result<Rc<Self>> {
        let vault = Rc::new(RefCell::new(Vault::open(library)?));
        let library = Library::open(library.root.clone())?;
        let window = adw::ApplicationWindow::builder()
            .application(application)
            .title("Secure Snippets")
            .default_width(1000)
            .default_height(720)
            .build();
        let overlay = adw::ToastOverlay::new();
        window.set_content(Some(&overlay));
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 0);
        overlay.set_child(Some(&layout));
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Secure Snippets",
            "Encrypted bodies · public metadata",
        )));
        let unlock = gtk::Button::with_label("Unlock");
        header.pack_start(&unlock);
        let lock = gtk::Button::with_label("Lock");
        header.pack_end(&lock);
        let new = gtk::Button::from_icon_name("list-add-symbolic");
        new.set_tooltip_text(Some("New secure snippet"));
        header.pack_start(&new);
        let recovery = gtk::Button::with_label("Recovery Key…");
        header.pack_end(&recovery);
        let change = gtk::Button::with_label("Change Passphrase…");
        header.pack_end(&change);
        let draft_recovery = gtk::Button::with_label("Recover Previous Draft…");
        draft_recovery.set_visible(false);
        header.pack_start(&draft_recovery);
        layout.append(&header);
        let paned = gtk::Paned::builder()
            .orientation(gtk::Orientation::Horizontal)
            .position(300)
            .vexpand(true)
            .build();
        layout.append(&paned);
        let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 12);
        sidebar.set_width_request(240);
        let query = gtk::SearchEntry::builder()
            .placeholder_text("Search secure metadata")
            .margin_top(16)
            .margin_start(16)
            .margin_end(16)
            .build();
        sidebar.append(&query);
        let rows = gtk::ListBox::new();
        rows.add_css_class("navigation-sidebar");
        sidebar.append(
            &gtk::ScrolledWindow::builder()
                .child(&rows)
                .vexpand(true)
                .hscrollbar_policy(gtk::PolicyType::Never)
                .build(),
        );
        let privacy =
            label("Names, keywords and tags are visible while locked. Bodies stay encrypted.");
        privacy.set_margin_start(16);
        privacy.set_margin_end(16);
        privacy.set_margin_bottom(16);
        sidebar.append(&privacy);
        paned.set_start_child(Some(&sidebar));
        let fields = gtk::Box::new(gtk::Orientation::Vertical, 12);
        fields.set_margin_start(24);
        fields.set_margin_end(24);
        fields.set_margin_top(24);
        fields.set_margin_bottom(24);
        paned.set_end_child(Some(&fields));
        let status = label("Unlock to create or edit protected content.");
        fields.append(&status);
        let name = gtk::Entry::builder().placeholder_text("Name").build();
        name.update_property(&[gtk::accessible::Property::Label("Secure snippet name")]);
        fields.append(&name);
        let keyword = gtk::Entry::builder().placeholder_text("Keyword").build();
        keyword.update_property(&[gtk::accessible::Property::Label("Secure snippet keyword")]);
        fields.append(&keyword);
        let tags = gtk::Entry::builder()
            .placeholder_text("Tags, separated by commas")
            .build();
        tags.update_property(&[gtk::accessible::Property::Label("Secure snippet tags")]);
        fields.append(&tags);
        let toggles = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let enabled = gtk::CheckButton::with_label("Enabled");
        let pin = gtk::CheckButton::with_label("Pinned");
        toggles.append(&enabled);
        toggles.append(&pin);
        fields.append(&toggles);
        let toolbar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let reveal = gtk::ToggleButton::with_label("Reveal to Edit");
        let undo = gtk::Button::from_icon_name("edit-undo-symbolic");
        undo.set_tooltip_text(Some("Undo protected body edit (Ctrl+Z)"));
        undo.update_property(&[gtk::accessible::Property::Label("Undo protected body edit")]);
        let redo = gtk::Button::from_icon_name("edit-redo-symbolic");
        redo.set_tooltip_text(Some("Redo protected body edit (Ctrl+Shift+Z)"));
        redo.update_property(&[gtk::accessible::Property::Label("Redo protected body edit")]);
        let paste = gtk::Button::from_icon_name("edit-paste-symbolic");
        paste.set_tooltip_text(Some("Paste into revealed protected body (Ctrl+V)"));
        paste.update_property(&[gtk::accessible::Property::Label(
            "Paste into protected body",
        )]);
        let insert = gtk::Button::with_label("Insert into Original Window…");
        insert.set_visible(false);
        insert.update_property(&[gtk::accessible::Property::Label(
            "Authenticate and insert the saved secure snippet into the original window",
        )]);
        let save = gtk::Button::with_label("Save");
        let repair = gtk::Button::with_label("Repair Legacy Entry…");
        repair.set_visible(false);
        let discard = gtk::Button::with_label("Discard / Reload");
        let delete = gtk::Button::from_icon_name("user-trash-symbolic");
        delete.set_tooltip_text(Some("Delete secure snippet"));
        for widget in [
            &reveal.clone().upcast::<gtk::Widget>(),
            &undo.clone().upcast(),
            &redo.clone().upcast(),
            &paste.clone().upcast(),
            &save.clone().upcast(),
            &discard.clone().upcast(),
            &delete.clone().upcast(),
            &insert.clone().upcast(),
            &repair.clone().upcast(),
        ] {
            toolbar.append(widget);
        }
        fields.append(&toolbar);
        let editor = ProtectedEditor::new(vault.clone());
        fields.append(&editor.area);
        fields.append(&label("Select with Shift+arrows or the mouse; Ctrl+A selects all. Ctrl+V pastes clipboard text into the revealed body. Ctrl+Z / Ctrl+Shift+Z undoes or redoes body edits. Reveal hides when this window loses focus. Protected content cannot be copied, dragged to another app or exported as plaintext."));
        let this = Rc::new(Self {
            window,
            library,
            vault,
            editor,
            overlay,
            query,
            rows,
            visible: RefCell::new(vec![]),
            selected: Cell::new(None),
            name,
            keyword,
            tags,
            enabled,
            pin,
            status,
            unlock,
            reveal,
            undo,
            redo,
            paste,
            dirty: Cell::new(false),
            loading: Cell::new(false),
            busy: Cell::new(false),
            generation: Cell::new(0),
            reading_failed: Cell::new(false),
            desktop_was_allowed: Cell::new(false),
            desktop: desktop::SessionMonitor::new().map(Rc::new),
            draft_recovery,
            draft_dialog: RefCell::new(None),
            draft_authorization: RefCell::new(None),
            draft_worker: Cell::new(false),
            insert,
            insertion_target: RefCell::new(None),
            insertion_authorization: RefCell::new(None),
            insertion_dialog: RefCell::new(None),
            insertion_worker: Cell::new(false),
            insertion_armed: Cell::new(false),
            repair,
            repair_authorization: RefCell::new(None),
            repair_dialog: RefCell::new(None),
            repair_worker: Cell::new(false),
            usage: RefCell::new(None),
            selection_query: RefCell::new(None),
        });
        this.editor
            .observe_desktop(this.desktop.as_ref().map(|monitor| monitor.witness()));
        let weak = Rc::downgrade(&this);
        this.query.connect_search_changed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.refresh();
            }
        });
        let weak = Rc::downgrade(&this);
        this.rows.connect_row_selected(move |_, row| {
            if let Some(this) = weak.upgrade()
                && !this.loading.get()
                && let Some(row) = row
            {
                let id = this
                    .visible
                    .borrow()
                    .get(row.index() as usize)
                    .map(|m| m.id);
                if id != this.selected.get() && this.save() {
                    this.cancel_insertion();
                    this.select(id);
                }
            }
        });
        for field in [&this.name, &this.keyword, &this.tags] {
            let weak = Rc::downgrade(&this);
            field.connect_changed(move |_| {
                if let Some(this) = weak.upgrade()
                    && !this.loading.get()
                {
                    this.dirty.set(true);
                    this.status.set_label("Unsaved encrypted draft");
                }
            });
        }
        for toggle in [&this.enabled, &this.pin] {
            let weak = Rc::downgrade(&this);
            toggle.connect_toggled(move |_| {
                if let Some(this) = weak.upgrade()
                    && !this.loading.get()
                {
                    this.dirty.set(true);
                }
            });
        }
        let weak = Rc::downgrade(&this);
        this.editor.on_changed(move |result| {
            if let Some(this) = weak.upgrade() {
                match result {
                    Ok(()) => {
                        this.status.set_label(if this.is_dirty() {
                            "Unsaved encrypted draft"
                        } else {
                            "No unsaved changes"
                        });
                    }
                    Err(error) => this.toast(&error.to_string()),
                }
                this.update();
            }
        });
        let weak = Rc::downgrade(&this);
        this.reveal.connect_toggled(move |toggle| {
            if let Some(this) = weak.upgrade() {
                this.editor.reveal(toggle.is_active());
                if toggle.is_active() {
                    this.editor.area.grab_focus();
                }
                this.update();
            }
        });
        for (button, redo) in [(&this.undo, false), (&this.redo, true)] {
            let weak = Rc::downgrade(&this);
            button.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.editor.undo(redo);
                }
            });
        }
        let weak = Rc::downgrade(&this);
        this.paste.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.editor.paste();
            }
        });
        let weak = Rc::downgrade(&this);
        this.unlock.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.authenticate(false);
            }
        });
        let weak = Rc::downgrade(&this);
        this.draft_recovery.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.recover_draft();
            }
        });
        let weak = Rc::downgrade(&this);
        this.insert.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.insert_selected();
            }
        });
        let weak = Rc::downgrade(&this);
        recovery.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.authenticate(true);
            }
        });
        let weak = Rc::downgrade(&this);
        change.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.change_passphrase();
            }
        });
        let weak = Rc::downgrade(&this);
        lock.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.lock();
            }
        });
        let weak = Rc::downgrade(&this);
        new.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.new_entry();
            }
        });
        let weak = Rc::downgrade(&this);
        save.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.save();
            }
        });
        let weak = Rc::downgrade(&this);
        discard.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.discard();
            }
        });
        let weak = Rc::downgrade(&this);
        delete.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.delete();
            }
        });
        let weak = Rc::downgrade(&this);
        this.repair.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.repair_legacy();
            }
        });
        let weak = Rc::downgrade(&this);
        this.window.connect_is_active_notify(move |window| {
            if let Some(this) = weak.upgrade() {
                if !window.is_active() {
                    this.cancel_draft_recovery();
                    this.cancel_legacy_repair();
                    if !this.insertion_armed.get() {
                        this.cancel_insertion();
                        this.generation.set(this.generation.get().wrapping_add(1));
                    }
                    this.reveal.set_active(false);
                    this.editor.reveal(false);
                }
                this.update();
            }
        });
        let weak = Rc::downgrade(&this);
        this.window.connect_close_request(move |window| {
            if let Some(this) = weak.upgrade() {
                this.lock();
                window.set_visible(false);
            }
            glib::Propagation::Stop
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(&this);
        keys.connect_key_pressed(move |_, key, _, mods| {
            if mods.contains(gtk::gdk::ModifierType::CONTROL_MASK)
                && let Some(this) = weak.upgrade()
            {
                match key.to_unicode().map(|c| c.to_ascii_lowercase()) {
                    Some('s') => {
                        this.save();
                        return glib::Propagation::Stop;
                    }
                    Some('n') => {
                        this.new_entry();
                        return glib::Propagation::Stop;
                    }
                    Some('l') => {
                        this.lock();
                        return glib::Propagation::Stop;
                    }
                    _ => (),
                }
            }
            glib::Propagation::Proceed
        });
        this.window.add_controller(keys);
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let expired = this.draft_authorization.borrow().as_ref().is_some_and(
                |(authorization, generation)| {
                    authorization.validate().is_err()
                        || this.vault.borrow().generation() != *generation
                },
            );
            if expired
                || (!this.window.is_active() || !this.window.is_visible())
                    && this.draft_authorization.borrow().is_some()
            {
                this.cancel_draft_recovery();
            }
            if this
                .insertion_authorization
                .borrow()
                .as_ref()
                .is_some_and(|authorization| authorization.validate().is_err())
            {
                this.cancel_insertion();
            }
            if this
                .repair_authorization
                .borrow()
                .as_ref()
                .is_some_and(|authorization| authorization.validate().is_err())
            {
                this.cancel_legacy_repair();
            }
            glib::ControlFlow::Continue
        });
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_millis(500), move || {
            if let Some(this) = weak.upgrade() {
                this.poll();
                glib::ControlFlow::Continue
            } else {
                glib::ControlFlow::Break
            }
        });
        this.refresh();
        this.update();
        Ok(this)
    }
    fn toast(&self, message: &str) {
        self.overlay.add_toast(adw::Toast::new(message));
    }
    pub fn lock(&self) {
        let was_unlocked = self.vault.borrow_mut().is_unlocked();
        self.cancel_legacy_repair();
        self.cancel_insertion();
        self.cancel_draft_recovery();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.vault.borrow_mut().lock();
        self.reveal.set_active(false);
        self.editor.allow(false);
        if was_unlocked {
            crate::diagnostics::record(crate::diagnostics::Event::Vault {
                operation: crate::diagnostics::VaultOperation::Lock,
                outcome: crate::diagnostics::Outcome::Succeeded,
                duration_ms: crate::diagnostics::Milliseconds::new(Duration::ZERO),
                failure: None,
            });
        }
        self.update();
    }
    pub(crate) fn session_unlocked(&self) -> bool {
        self.desktop_allowed() && self.vault.borrow_mut().is_unlocked()
    }
    fn desktop_allowed(&self) -> bool {
        self.desktop
            .as_ref()
            .is_some_and(|monitor| monitor.snapshot().0 == SessionState::Unlocked)
    }
    fn desktop_epoch(&self) -> u64 {
        self.desktop
            .as_ref()
            .map_or(0, |monitor| monitor.snapshot().1)
    }
    fn update(&self) {
        let unlocked = self.vault.borrow_mut().is_unlocked() && self.desktop_allowed();
        let foreign = self.editor.is_foreign();
        let editable = unlocked && !foreign && !self.busy.get();
        let legacy = self
            .selected
            .get()
            .and_then(|id| self.vault.borrow().record(id))
            .is_some_and(|record| record.content_hash.is_empty());
        self.repair.set_visible(legacy);
        self.repair.set_sensitive(
            legacy
                && !self.busy.get()
                && !self.is_dirty()
                && self.desktop_allowed()
                && self.window.is_active(),
        );
        let destination = self
            .insertion_target
            .borrow()
            .as_ref()
            .is_some_and(|t| t.is_fresh());
        self.insert.set_visible(destination);
        self.insert.set_sensitive(
            destination
                && !self.busy.get()
                && !self.is_dirty()
                && self.window.is_active()
                && self.desktop_allowed()
                && self.selected.get().is_some_and(|id| {
                    self.vault
                        .borrow()
                        .record(id)
                        .is_some_and(|r| r.metadata.is_enabled)
                }),
        );
        self.editor.allow(editable);
        self.undo
            .set_sensitive(editable && self.editor.can_undo(false));
        self.redo
            .set_sensitive(editable && self.editor.can_undo(true));
        self.paste
            .set_sensitive(editable && self.editor.can_paste());
        self.reveal
            .set_sensitive(editable && self.editor.metadata().is_some());
        self.draft_recovery.set_visible(foreign);
        self.draft_recovery
            .set_sensitive(unlocked && !self.busy.get());
        for widget in [
            &self.name.clone().upcast::<gtk::Widget>(),
            &self.keyword.clone().upcast(),
            &self.tags.clone().upcast(),
            &self.enabled.clone().upcast(),
            &self.pin.clone().upcast(),
        ] {
            widget.set_sensitive(editable && self.editor.metadata().is_some());
        }
        self.unlock
            .set_label(if self.vault.borrow().document.is_none() {
                "Set Up…"
            } else if unlocked {
                "Unlocked"
            } else {
                "Unlock…"
            });
        self.unlock.set_sensitive(!self.busy.get() && !unlocked);
        if !unlocked {
            self.reveal.set_active(false);
            self.status.set_label(if self.is_dirty() {
                "Locked · encrypted draft retained. Unlock to save or discard."
            } else {
                "Locked · unlock to edit protected content."
            });
        } else if foreign && !self.busy.get() {
            self.status.set_label("Previous vault draft retained. Choose Recover Previous Draft to keep it in the current vault, or Discard / Reload.");
        }
    }
    fn poll(&self) {
        let allowed = self.desktop_allowed();
        if !allowed && (self.desktop_was_allowed.get() || self.vault.borrow_mut().is_unlocked()) {
            self.lock();
        }
        self.desktop_was_allowed.set(allowed);
        let result = self.vault.borrow_mut().reload();
        match result {
            Ok(changed) => {
                self.reading_failed.set(false);
                if changed {
                    self.editor.cancel_paste();
                    self.cancel_insertion();
                    self.cancel_legacy_repair();
                    self.refresh();
                }
            }
            Err(error) => {
                self.editor.cancel_paste();
                self.cancel_insertion();
                self.cancel_legacy_repair();
                if !self.reading_failed.replace(true) {
                    self.toast(&error.to_string());
                }
            }
        }
        self.update();
        let cancelled = self.draft_authorization.borrow().as_ref().is_some_and(
            |(authorization, generation)| {
                authorization.validate().is_err() || self.vault.borrow().generation() != *generation
            },
        );
        if cancelled {
            self.cancel_draft_recovery();
        }
    }
    fn refresh(&self) {
        self.loading.set(true);
        while let Some(child) = self.rows.first_child() {
            self.rows.remove(&child);
        }
        let metadata = self
            .vault
            .borrow()
            .document
            .as_ref()
            .map(|d| d.metadata())
            .unwrap_or_default();
        let ids: Vec<_> = crate::model::search(
            &metadata.iter().map(|m| m.shell()).collect::<Vec<_>>(),
            &self.query.text(),
            &[],
            false,
            false,
        )
        .iter()
        .map(|s| s.id)
        .collect();
        let visible: Vec<_> = ids
            .iter()
            .filter_map(|id| metadata.iter().find(|m| &m.id == id).cloned())
            .collect();
        for (index, metadata) in visible.iter().enumerate() {
            let content = gtk::Box::new(gtk::Orientation::Vertical, 4);
            content.set_margin_start(16);
            content.set_margin_end(16);
            content.set_margin_top(12);
            content.set_margin_bottom(12);
            content.append(&label(&format!(
                "🔒 {}{}",
                if metadata.is_pinned { "★ " } else { "" },
                metadata.shell().display_name()
            )));
            content.append(&label(&metadata.keyword));
            self.rows.append(&content);
            if Some(metadata.id) == self.selected.get() {
                self.rows
                    .select_row(self.rows.row_at_index(index as i32).as_ref());
            }
        }
        *self.visible.borrow_mut() = visible;
        self.loading.set(false);
    }
    fn populate(&self, metadata: &Metadata) {
        self.loading.set(true);
        self.name.set_text(&metadata.name);
        self.keyword.set_text(&metadata.keyword);
        self.tags.set_text(&metadata.tags.join(", "));
        self.enabled.set_active(metadata.is_enabled);
        self.pin.set_active(metadata.is_pinned);
        self.loading.set(false);
    }
    fn select(&self, id: Option<Uuid>) {
        self.cancel_legacy_repair();
        self.selected.set(id);
        self.editor.discard();
        self.dirty.set(false);
        if let Some(id) = id {
            let record = self.vault.borrow().record(id);
            if let Some(record) = record {
                self.populate(&record.metadata);
                if self.vault.borrow_mut().is_unlocked()
                    && let Err(error) = self.editor.load(id)
                {
                    self.toast(&error.to_string());
                }
            }
        } else {
            self.populate(&Metadata::new());
        }
        self.update();
    }
    pub fn present(&self, id: Option<Uuid>) {
        self.selection_query.borrow_mut().take();
        self.cancel_insertion();
        self.insertion_target.borrow_mut().take();
        if id.is_some() && id != self.selected.get() && self.save() {
            self.select(id);
        }
        self.window.present();
        self.refresh();
    }
    pub fn is_dirty(&self) -> bool {
        self.dirty.get() || self.editor.is_dirty()
    }
    pub fn save(&self) -> bool {
        self.editor.cancel_paste();
        if self.draft_worker.get() || self.insertion_worker.get() || self.repair_worker.get() {
            self.toast("Wait for the secure operation to stop before saving.");
            return false;
        }
        if !self.is_dirty() {
            return true;
        }
        if !self.desktop_allowed() {
            self.toast("Unlock the desktop before saving Secure Snippets.");
            return false;
        }
        let Some(metadata) = self.draft_metadata() else {
            return false;
        };
        let started = std::time::Instant::now();
        let result = self.editor.save(&self.library, metadata);
        crate::diagnostics::record(crate::diagnostics::Event::Vault {
            operation: crate::diagnostics::VaultOperation::Save,
            outcome: if result.is_ok() {
                crate::diagnostics::Outcome::Succeeded
            } else {
                crate::diagnostics::Outcome::Failed
            },
            duration_ms: crate::diagnostics::Milliseconds::new(started.elapsed()),
            failure: result.as_ref().err().map(|_| {
                crate::diagnostics::Failure::classified(crate::diagnostics::Family::Vault)
            }),
        });
        match result {
            Ok(()) => {
                self.dirty.set(false);
                self.status.set_label("Saved encrypted locally");
                if let Some(metadata) = self.editor.metadata() {
                    self.populate(&metadata);
                }
                self.refresh();
                true
            }
            Err(error) => {
                self.toast(&error.to_string());
                false
            }
        }
    }
    fn draft_metadata(&self) -> Option<Metadata> {
        let mut metadata = self.editor.metadata()?;
        metadata.name = self.name.text().into();
        metadata.keyword = self.keyword.text().into();
        metadata.tags = self.tags.text().split(',').map(String::from).collect();
        metadata.is_enabled = self.enabled.is_active();
        metadata.is_pinned = self.pin.is_active();
        Some(metadata)
    }
    pub fn handle_action(self: &Rc<Self>, name: &str) -> bool {
        if !self.window.is_active() {
            return false;
        }
        match name { "new" => self.new_entry(), "save" => { self.save(); }, "search" => { self.query.grab_focus(); }, "undo" | "redo" => self.editor.undo(name == "redo"), "copy" | "capture" | "export" | "import" | "picker" => self.toast("Use the library window for this action. Protected bodies cannot be copied or exported as plaintext."), _ => return false }
        true
    }
    fn new_entry(self: &Rc<Self>) {
        if !self.save() {
            return;
        }
        if !self.vault.borrow_mut().is_unlocked() || !self.desktop_allowed() {
            self.authenticate(false);
            return;
        }
        match self.editor.create() {
            Ok(()) => {
                self.selected.set(self.editor.metadata().map(|m| m.id));
                self.populate(&self.editor.metadata().expect("created"));
                self.dirty.set(false);
                self.status
                    .set_label("New encrypted draft · Ctrl+S to save");
                self.update();
                self.name.grab_focus();
            }
            Err(error) => self.toast(&error.to_string()),
        }
    }
    fn discard(self: &Rc<Self>) {
        let this = self.clone();
        glib::spawn_future_local(async move {
            if this.is_dirty() {
                let dialog = adw::AlertDialog::builder()
                    .heading("Discard the encrypted draft?")
                    .body("Unsaved edits will be removed. The saved vault record will stay intact.")
                    .build();
                dialog.add_responses(&[("cancel", "Cancel"), ("discard", "Discard")]);
                dialog.set_close_response("cancel");
                if dialog.choose_future(Some(&this.window)).await != "discard" {
                    return;
                }
            }
            let id = this
                .selected
                .get()
                .filter(|id| this.vault.borrow().record(*id).is_some());
            this.select(id);
        });
    }
    fn delete(self: &Rc<Self>) {
        if self.busy.get() {
            self.toast("Wait for the secure operation to stop before deleting.");
            return;
        }
        if self.editor.metadata().is_none() {
            self.toast("Unlock and choose a saved secure snippet first.");
            return;
        }
        let this = self.clone();
        glib::spawn_future_local(async move {
            let dialog = adw::AlertDialog::builder()
                .heading("Delete this secure snippet?")
                .body(
                    "This permanently removes the saved encrypted entry. This action has no Undo.",
                )
                .build();
            dialog.add_responses(&[("cancel", "Cancel"), ("delete", "Delete")]);
            dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
            dialog.set_close_response("cancel");
            if dialog.choose_future(Some(&this.window)).await == "delete" && this.desktop_allowed()
            {
                let result = this.editor.delete(&this.library);
                match result {
                    Ok(()) => {
                        this.select(None);
                        this.refresh();
                    }
                    Err(error) => this.toast(&error.to_string()),
                }
            }
        });
    }
    fn authenticate(self: &Rc<Self>, recovery: bool) {
        if self.busy.replace(true) {
            return;
        }
        self.update();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let outcome = this.authentication_dialog(recovery).await;
            this.busy.set(false);
            this.update();
            if let Err(error) = outcome {
                this.toast(&error.to_string());
            }
        });
    }
    fn change_passphrase(self: &Rc<Self>) {
        if self.busy.replace(true) {
            return;
        }
        self.update();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = this.passphrase_dialog().await;
            this.busy.set(false);
            this.update();
            if let Err(error) = result {
                this.toast(&error.to_string());
            }
        });
    }
    async fn passphrase_dialog(&self) -> Result<()> {
        if !self.desktop_allowed() {
            return Err(Error("Unlock the desktop before changing the passphrase."));
        }
        self.vault.borrow_mut().reload()?;
        let document = self
            .vault
            .borrow()
            .document
            .clone()
            .ok_or(Error("Set up Secure Snippets first."))?;
        let request = self.generation.get();
        let generation = self.vault.borrow().generation();
        let epoch = self.desktop_epoch();
        let dialog = adw::AlertDialog::builder().heading("Change Vault Passphrase").body("Authenticate with the current passphrase or recovery key, then choose a new passphrase of at least 12 characters. The recovery key and encrypted bodies stay valid.").build();
        let fields = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let recovery = gtk::CheckButton::with_label("Authenticate with recovery key");
        recovery.set_active(document.wrap_pass.is_none());
        fields.append(&recovery);
        let credential = gtk::PasswordEntry::builder()
            .placeholder_text("Current passphrase or recovery key")
            .show_peek_icon(false)
            .build();
        fields.append(&credential);
        let passphrase = gtk::PasswordEntry::builder()
            .placeholder_text("New passphrase")
            .show_peek_icon(false)
            .build();
        fields.append(&passphrase);
        let confirmation = gtk::PasswordEntry::builder()
            .placeholder_text("Confirm new passphrase")
            .show_peek_icon(false)
            .build();
        fields.append(&confirmation);
        dialog.set_extra_child(Some(&fields));
        dialog.add_responses(&[("cancel", "Cancel"), ("change", "Change")]);
        dialog.set_close_response("cancel");
        let response = dialog.choose_future(Some(&self.window)).await;
        let old = Zeroizing::new(credential.text().to_string());
        let new = Zeroizing::new(passphrase.text().to_string());
        let confirm = Zeroizing::new(confirmation.text().to_string());
        credential.set_text("");
        passphrase.set_text("");
        confirmation.set_text("");
        if response != "change" {
            return Ok(());
        }
        if *new != *confirm {
            return Err(Error("The new passphrases do not match."));
        }
        if request != self.generation.get()
            || epoch != self.desktop_epoch()
            || !self.desktop_allowed()
        {
            return Err(Error(
                "Authentication expired. Try changing the passphrase again.",
            ));
        }
        let using_recovery = recovery.is_active();
        self.status.set_label("Changing passphrase…");
        let (authentication, prepared) =
            worker(move || document.prepare_passphrase_change(&old, using_recovery, &new)).await?;
        if request != self.generation.get()
            || epoch != self.desktop_epoch()
            || !self.desktop_allowed()
            || !self.window.is_active()
        {
            return Err(Error(
                "Authentication expired. Try changing the passphrase again.",
            ));
        }
        let mut vault = self.vault.borrow_mut();
        vault.finish_authentication(authentication, generation)?;
        let generation = vault.generation();
        let transition = vault.finish_passphrase(&self.library, prepared, generation)?;
        drop(vault);
        self.editor.rewrap(&transition)?;
        self.status.set_label("Passphrase changed");
        self.toast("Passphrase changed. Keep your recovery key offline.");
        Ok(())
    }
    async fn authentication_dialog(self: &Rc<Self>, recovery: bool) -> Result<()> {
        if !self.desktop_allowed() {
            return Err(Error(
                "Unlock the desktop before authenticating Secure Snippets.",
            ));
        }
        self.vault.borrow_mut().reload()?;
        let document = self.vault.borrow().document.clone();
        let request = self.generation.get();
        let generation = self.vault.borrow().generation();
        let desktop_epoch = self.desktop_epoch();
        let creating = document.is_none();
        if creating && recovery {
            return Err(Error("Set up Secure Snippets before using a recovery key."));
        }
        let dialog = adw::AlertDialog::builder().heading(if creating { "Set Up Secure Snippets" } else if recovery { "Unlock with Recovery Key" } else { "Unlock Secure Snippets" }).body(if creating { "Choose a passphrase of at least 12 characters. You will also receive a recovery key to record offline. Names, keywords and tags remain visible while locked." } else if recovery { "Enter the recovery key for this vault. It never enters the clipboard or command-line arguments." } else { "Enter this vault's passphrase. A vault from the Mac app may first require its recovery key." }).build();
        let entry = gtk::PasswordEntry::builder()
            .show_peek_icon(false)
            .hexpand(true)
            .build();
        entry.update_property(&[gtk::accessible::Property::Label(if recovery {
            "Recovery key"
        } else {
            "Passphrase"
        })]);
        let confirmation = gtk::PasswordEntry::builder()
            .show_peek_icon(false)
            .placeholder_text("Confirm passphrase")
            .build();
        let fields = gtk::Box::new(gtk::Orientation::Vertical, 8);
        fields.append(&entry);
        if creating {
            fields.append(&confirmation);
        }
        dialog.set_extra_child(Some(&fields));
        dialog.add_responses(&[
            ("cancel", "Cancel"),
            ("unlock", if creating { "Set Up" } else { "Unlock" }),
        ]);
        dialog.set_close_response("cancel");
        dialog.set_default_response(Some("unlock"));
        if dialog.choose_future(Some(&self.window)).await != "unlock" {
            entry.set_text("");
            confirmation.set_text("");
            return Ok(());
        }
        let secret = Zeroizing::new(entry.text().to_string());
        let confirm = Zeroizing::new(confirmation.text().to_string());
        entry.set_text("");
        confirmation.set_text("");
        if creating && *secret != *confirm {
            return Err(Error("The passphrases do not match."));
        }
        if request != self.generation.get()
            || desktop_epoch != self.desktop_epoch()
            || !self.desktop_allowed()
        {
            return Err(Error(
                "Authentication expired. Unlock Secure Snippets again.",
            ));
        }
        self.status.set_label("Authenticating…");
        if creating {
            let prepared = worker(move || Vault::prepare_create(&secret)).await?;
            if request != self.generation.get()
                || desktop_epoch != self.desktop_epoch()
                || !self.desktop_allowed()
                || !self.window.is_active()
            {
                return Err(Error(
                    "Authentication expired. Unlock Secure Snippets again.",
                ));
            }
            let recovery =
                self.vault
                    .borrow_mut()
                    .finish_create(&self.library, prepared, generation)?;
            self.show_recovery(recovery).await?;
        } else {
            let document = document.expect("existing vault");
            let authentication = worker(move || document.authenticate(&secret, recovery)).await?;
            if request != self.generation.get()
                || desktop_epoch != self.desktop_epoch()
                || !self.desktop_allowed()
                || !self.window.is_active()
            {
                return Err(Error(
                    "Authentication expired. Unlock Secure Snippets again.",
                ));
            }
            self.vault
                .borrow_mut()
                .finish_authentication(authentication, generation)?;
        }
        if self.editor.metadata().is_none()
            && let Some(id) = self.selected.get()
        {
            self.editor.load(id)?;
        }
        self.status.set_label(if self.is_dirty() {
            "Unsaved encrypted draft"
        } else {
            "Unlocked · choose a snippet or create one"
        });
        self.update();
        Ok(())
    }
    async fn show_recovery(&self, material: Zeroizing<String>) -> Result<()> {
        let editor = ProtectedEditor::new(self.vault.clone());
        editor.ephemeral(material.as_bytes())?;
        drop(material);
        let dialog = adw::AlertDialog::builder().heading("Record Your Recovery Key").body("Write this key down and keep it offline. It can unlock the vault if you forget the passphrase. This key is shown only during setup.").build();
        let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
        let reveal = gtk::ToggleButton::with_label("Reveal Recovery Key");
        content.append(&reveal);
        content.append(&editor.area);
        let recorded = gtk::CheckButton::with_label("I recorded this key offline");
        content.append(&recorded);
        let protected = editor.clone();
        let weak = self.window.downgrade();
        let monitor = self.desktop.clone();
        reveal.connect_toggled(move |button| {
            let allowed = weak.upgrade().is_some_and(|w| w.is_active())
                && monitor
                    .as_ref()
                    .is_some_and(|monitor| monitor.snapshot().0 == SessionState::Unlocked);
            protected.allow(allowed);
            protected.reveal(button.is_active());
        });
        let weak = dialog.downgrade();
        recorded.connect_toggled(move |check| {
            if let Some(dialog) = weak.upgrade() {
                dialog.set_response_enabled("done", check.is_active());
            }
        });
        let protected = editor.clone();
        let weak = reveal.downgrade();
        let handler = self.window.connect_is_active_notify(move |window| {
            if !window.is_active() {
                protected.allow(false);
                if let Some(reveal) = weak.upgrade() {
                    reveal.set_active(false);
                }
            }
        });
        let weak = Rc::downgrade(&editor);
        let vault = Rc::downgrade(&self.vault);
        let monitor = self.desktop.clone();
        let tick = glib::timeout_add_local(Duration::from_millis(500), move || {
            if let (Some(editor), Some(vault)) = (weak.upgrade(), vault.upgrade()) {
                editor.allow(
                    vault.borrow_mut().is_unlocked()
                        && monitor
                            .as_ref()
                            .is_some_and(|monitor| monitor.snapshot().0 == SessionState::Unlocked),
                );
                glib::ControlFlow::Continue
            } else {
                glib::ControlFlow::Break
            }
        });
        dialog.set_extra_child(Some(&content));
        dialog.add_responses(&[("close", "Close"), ("done", "Continue")]);
        dialog.set_response_enabled("done", false);
        dialog.set_close_response("close");
        dialog.choose_future(Some(&self.window)).await;
        tick.remove();
        self.window.disconnect(handler);
        editor.discard();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gtk::gio;
    #[test]
    #[ignore = "requires a graphical display; uses an isolated fictional vault and never sends compositor input"]
    fn native_secure_lifecycle() {
        adw::init().expect("graphical display");
        let directory = tempfile::tempdir().unwrap();
        let library = Library::open(directory.path().into()).unwrap();
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        std::fs::create_dir(directory.path().join("Vault")).unwrap();
        crate::model::atomic_write(
            &directory.path().join("Vault/vault.json"),
            &serde_json::to_vec(&fixture["document"]).unwrap(),
        )
        .unwrap();
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.SecureSmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let workspace = Workspace::new(&application, &library).unwrap();
        let id = workspace.vault.borrow().document.as_ref().unwrap().records[0]
            .metadata
            .id;
        workspace.present(Some(id));
        let context = glib::MainContext::default();
        while context.pending() {
            context.iteration(false);
        }
        assert!(!workspace.vault.borrow_mut().is_unlocked());
        assert!(workspace.editor.metadata().is_none() && !workspace.name.is_sensitive());
        assert!(
            workspace.visible.borrow().len() == 1 && workspace.name.text() == "Interop fixture"
        );
        let document = workspace.vault.borrow().document.clone().unwrap();
        // Exercise the real off-thread derivation, then the protected editor's
        // core path programmatically. Production focus/session gates stay closed.
        let authentication = context
            .block_on(worker(move || {
                document.authenticate("Café public fixture", false)
            }))
            .unwrap();
        let generation = workspace.vault.borrow().generation();
        workspace
            .vault
            .borrow_mut()
            .finish_authentication(authentication, generation)
            .unwrap();
        workspace.editor.load(id).unwrap();
        workspace.editor.fixture_edit("Fictional edit: ").unwrap();
        workspace
            .editor
            .save(&library, workspace.editor.metadata().unwrap())
            .unwrap();
        assert!(
            *workspace.vault.borrow_mut().body(id).unwrap()
                == "Fictional edit: Fictional secret 🦀\n".as_bytes()
        );
        assert!(!library.path().exists());
        workspace.editor.fixture_select_all().unwrap();
        assert!(!workspace.editor.is_dirty());
        workspace
            .editor
            .fixture_paste("Replacement public fixture 👩🏽‍💻\r\n")
            .unwrap();
        workspace.editor.fixture_undo(false).unwrap();
        assert!(!workspace.editor.is_dirty());
        workspace.editor.fixture_undo(true).unwrap();
        assert!(workspace.editor.is_dirty());
        workspace
            .editor
            .save(&library, workspace.editor.metadata().unwrap())
            .unwrap();
        assert!(
            workspace.vault.borrow_mut().body(id).unwrap().as_slice()
                == "Replacement public fixture 👩🏽‍💻\r\n".as_bytes()
        );
        workspace.editor.fixture_edit("Unsaved ").unwrap();
        workspace.lock();
        assert!(workspace.is_dirty() && workspace.editor.metadata().is_some());
        assert!(
            workspace
                .editor
                .save(&library, workspace.editor.metadata().unwrap())
                .is_err()
        );
        assert!(!workspace.reveal.is_active());
        workspace.query.set_text("Fictional secret");
        workspace.refresh();
        assert!(workspace.visible.borrow().is_empty());
        assert!(workspace.editor.area.first_child().is_none());
        assert!(!workspace.editor.area.is::<gtk::TextView>());
        workspace.editor.discard();
        workspace.window.destroy();
    }
}
