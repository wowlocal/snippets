//! A secure body never enters a GtkTextBuffer, native selection, GTK undo stack, or the
//! accessible text interface. Retained editor state consists only of ciphertext.
//! Cairo/Pango and the compositor necessarily see transient revealed pixels;
//! this is not screenshot prevention or a claim about third-party memory erasure.
use crate::protected_edit::{self, Edit, Selection};
use crate::{
    model::{Error, Library, Result},
    vault::{EncryptedDraft, Metadata, Vault},
};
use gtk::{gdk, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

fn body_layout(area: &gtk::DrawingArea, text: &str, width: i32) -> gtk::pango::Layout {
    let layout = area.create_pango_layout(Some(text));
    layout.set_font_description(Some(&gtk::pango::FontDescription::from_string(
        "monospace 12",
    )));
    layout.set_width((width - 32).max(1) * gtk::pango::SCALE);
    layout.set_wrap(gtk::pango::WrapMode::WordChar);
    layout
}

fn draw_selection(
    cr: &gtk::cairo::Context,
    layout: &gtk::pango::Layout,
    selection: Selection,
    text: &str,
    offset: f64,
    color: &gdk::RGBA,
) {
    let range = selection.range();
    if range.is_empty() {
        return;
    }
    let scale = f64::from(gtk::pango::SCALE);
    cr.set_source_rgba(
        color.red().into(),
        color.green().into(),
        color.blue().into(),
        0.25,
    );
    let mut iter = layout.iter();
    loop {
        if let Some(line) = iter.line_readonly() {
            let start = line.start_index().max(0) as usize;
            let end = start + line.length().max(0) as usize;
            let (_, rect) = iter.line_extents();
            let first = range.start.max(start);
            let last = range.end.min(end);
            if first < last {
                for span in line.x_ranges(first as i32, last as i32).as_chunks::<2>().0 {
                    cr.rectangle(
                        16.0 + f64::from(span[0]) / scale,
                        16.0 - offset + f64::from(rect.y()) / scale,
                        f64::from(span[1] - span[0]) / scale,
                        f64::from(rect.height()) / scale,
                    );
                }
            }
            if range.start <= end
                && end < range.end
                && text
                    .as_bytes()
                    .get(end)
                    .is_some_and(|byte| matches!(byte, b'\r' | b'\n'))
            {
                let caret = layout.cursor_pos(end as i32).0;
                cr.rectangle(
                    16.0 + f64::from(caret.x()) / scale,
                    16.0 - offset + f64::from(rect.y()) / scale,
                    8.0,
                    f64::from(rect.height()) / scale,
                );
            }
        }
        if !iter.next_line() {
            break;
        }
    }
    let _ = cr.fill();
}

type ChangeCallback = Box<dyn Fn(Result<()>)>;
pub struct ProtectedEditor {
    pub area: gtk::DrawingArea,
    vault: Rc<RefCell<Vault>>,
    draft: RefCell<Option<EncryptedDraft>>,
    history: RefCell<protected_edit::History>,
    selection: Cell<Selection>,
    viewport: Cell<f64>,
    dirty: Cell<bool>,
    allowed: Cell<bool>,
    revealed: Cell<bool>,
    editable: Cell<bool>,
    im: gtk::IMContextSimple,
    notify: RefCell<Option<ChangeCallback>>,
}
impl ProtectedEditor {
    pub fn new(vault: Rc<RefCell<Vault>>) -> Rc<Self> {
        let area = gtk::DrawingArea::builder()
            .focusable(true)
            .hexpand(true)
            .vexpand(true)
            .content_height(280)
            .build();
        area.add_css_class("card");
        area.update_property(&[gtk::accessible::Property::Label(
            "Protected content. Reveal to edit. Copy and text extraction are disabled.",
        )]);
        area.update_property(&[gtk::accessible::Property::Description(
            "Shift with arrow keys selects text. Control+A selects all. Control with Left/Right or Backspace/Delete moves or removes words. Control+Z undoes a body edit; Control+Shift+Z or Control+Y redoes it. Shift+Tab leaves the editor. Escape hides content.",
        )]);
        let im = gtk::IMContextSimple::new();
        im.set_client_widget(Some(&area));
        im.set_input_purpose(gtk::InputPurpose::Password);
        im.set_input_hints(gtk::InputHints::PRIVATE | gtk::InputHints::NO_SPELLCHECK);
        let this = Rc::new(Self {
            area,
            vault,
            draft: RefCell::new(None),
            history: RefCell::new(protected_edit::History::default()),
            selection: Cell::new(Selection::default()),
            viewport: Cell::new(0.0),
            dirty: Cell::new(false),
            allowed: Cell::new(false),
            revealed: Cell::new(false),
            editable: Cell::new(true),
            im,
            notify: RefCell::new(None),
        });
        let weak = Rc::downgrade(&this);
        this.area.set_draw_func(move |area, cr, width, _| {
            let Some(this) = weak.upgrade() else {
                return;
            };
            let body = if this.authorized() && this.revealed.get() {
                this.draft
                    .borrow()
                    .as_ref()
                    .and_then(|draft| this.vault.borrow_mut().draft_body(draft, false).ok())
            } else {
                None
            };
            let text = body
                .as_ref()
                .and_then(|b| std::str::from_utf8(b).ok())
                .unwrap_or("Content hidden. Unlock and choose Reveal to edit.");
            let layout = body_layout(area, text, width);
            let color = area.color();
            let caret = layout
                .cursor_pos(this.selection.get().head().min(text.len()) as i32)
                .0;
            let offset = if body.is_some() {
                (f64::from(caret.y() / gtk::pango::SCALE) - f64::from(area.height().max(64) - 48))
                    .max(0.0)
            } else {
                0.0
            };
            this.viewport.set(offset);
            if body.is_some() {
                draw_selection(cr, &layout, this.selection.get(), text, offset, &color);
            }
            cr.set_source_rgba(
                color.red().into(),
                color.green().into(),
                color.blue().into(),
                color.alpha().into(),
            );
            cr.move_to(16.0, 16.0 - offset);
            pangocairo::functions::show_layout(cr, &layout);
            if body.is_some() && area.has_focus() {
                cr.rectangle(
                    16.0 + f64::from(caret.x()) / f64::from(gtk::pango::SCALE),
                    16.0 - offset + f64::from(caret.y()) / f64::from(gtk::pango::SCALE),
                    1.5,
                    f64::from(caret.height()) / f64::from(gtk::pango::SCALE),
                );
                let _ = cr.fill();
            }
            layout.set_text(""); // Do not retain a layout between frames.
        });
        let keys = gtk::EventControllerKey::new();
        let weak = Rc::downgrade(&this);
        keys.connect_key_pressed(move |controller, key, _, mods| {
            let Some(this) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if !this.authorized() || !this.revealed.get() {
                return glib::Propagation::Stop;
            }
            if key == gdk::Key::Escape {
                this.reveal(false);
                return glib::Propagation::Stop;
            }
            if key == gdk::Key::Tab && mods.contains(gdk::ModifierType::SHIFT_MASK) {
                return glib::Propagation::Proceed;
            }
            let control = mods.contains(gdk::ModifierType::CONTROL_MASK);
            let extend = mods.contains(gdk::ModifierType::SHIFT_MASK);
            if mods.intersects(gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK) {
                return glib::Propagation::Stop;
            }
            if control && matches!(key, gdk::Key::z | gdk::Key::Z | gdk::Key::y | gdk::Key::Y) {
                this.undo(extend || matches!(key, gdk::Key::y | gdk::Key::Y));
                return glib::Propagation::Stop;
            }
            if control && matches!(key, gdk::Key::a | gdk::Key::A) {
                this.im.reset();
                this.edit(Edit::SelectAll, "", false);
                return glib::Propagation::Stop;
            }
            let edit = match key {
                gdk::Key::BackSpace => Some(if control {
                    Edit::WordBackspace
                } else {
                    Edit::Backspace
                }),
                gdk::Key::Delete => Some(if control {
                    Edit::WordDelete
                } else {
                    Edit::Delete
                }),
                gdk::Key::Left => Some(if control { Edit::WordLeft } else { Edit::Left }),
                gdk::Key::Right => Some(if control {
                    Edit::WordRight
                } else {
                    Edit::Right
                }),
                gdk::Key::Up => Some(Edit::Up),
                gdk::Key::Down => Some(Edit::Down),
                gdk::Key::Home => Some(if control { Edit::Start } else { Edit::Home }),
                gdk::Key::End => Some(if control { Edit::Finish } else { Edit::End }),
                gdk::Key::Return | gdk::Key::KP_Enter if !control => {
                    this.edit(Edit::Insert, "\n", false);
                    return glib::Propagation::Stop;
                }
                gdk::Key::Tab if !control => {
                    this.edit(Edit::Insert, "\t", false);
                    return glib::Propagation::Stop;
                }
                _ => None,
            };
            if let Some(edit) = edit {
                this.im.reset();
                this.edit(edit, "", extend);
            } else if !control
                && !mods.intersects(gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK)
                && let Some(event) = controller.current_event()
            {
                this.im.filter_keypress(event);
            }
            glib::Propagation::Stop
        });
        this.area.add_controller(keys);
        let weak = Rc::downgrade(&this);
        this.im.connect_commit(move |_, text| {
            if let Some(this) = weak.upgrade() {
                this.edit(Edit::Insert, text, false);
            }
        });
        let focus = gtk::EventControllerFocus::new();
        let im = this.im.clone();
        focus.connect_enter(move |_| im.focus_in());
        let im = this.im.clone();
        focus.connect_leave(move |_| {
            im.reset();
            im.focus_out();
        });
        this.area.add_controller(focus);
        let click = gtk::GestureClick::new();
        click.set_button(gdk::BUTTON_PRIMARY);
        let weak = Rc::downgrade(&this);
        click.connect_pressed(move |gesture, _, x, y| {
            if let Some(this) = weak.upgrade() {
                this.area.grab_focus();
                this.place_pointer(
                    x,
                    y,
                    gesture
                        .current_event_state()
                        .contains(gdk::ModifierType::SHIFT_MASK),
                );
            }
        });
        let drag = gtk::GestureDrag::new();
        drag.set_button(gdk::BUTTON_PRIMARY);
        let weak = Rc::downgrade(&this);
        drag.connect_drag_update(move |gesture, x, y| {
            if let Some(this) = weak.upgrade()
                && let Some((start_x, start_y)) = gesture.start_point()
            {
                this.place_pointer(start_x + x, start_y + y, true);
            }
        });
        this.area.add_controller(drag.clone());
        this.area.add_controller(click.clone());
        // Both gestures share the same primary-button sequence; neither exports
        // a native drag payload or selection/clipboard provider.
        drag.group_with(&click);
        this
    }
    fn authorized(&self) -> bool {
        self.allowed.get()
            && self
                .area
                .root()
                .and_then(|root| root.downcast::<gtk::Window>().ok())
                .is_some_and(|w| w.is_active())
    }
    pub fn on_changed(&self, callback: impl Fn(Result<()>) + 'static) {
        *self.notify.borrow_mut() = Some(Box::new(callback));
    }
    fn edit(&self, edit: Edit, insertion: &str, extend: bool) {
        if !self.authorized() || !self.revealed.get() || !self.editable.get() {
            return;
        }
        let result = self.apply(edit, insertion, extend);
        self.area.queue_draw();
        if let Some(notify) = self.notify.borrow().as_ref() {
            notify(result);
        }
    }
    fn apply(&self, edit: Edit, insertion: &str, extend: bool) -> Result<()> {
        let mut draft = self.draft.borrow_mut();
        let draft = draft
            .as_mut()
            .ok_or(Error("Choose a secure snippet first."))?;
        let mut history = self.history.borrow_mut();
        let outcome = history.edit(
            &mut self.vault.borrow_mut(),
            draft,
            self.selection.get(),
            edit,
            insertion,
            extend,
        )?;
        self.dirty.set(history.is_dirty());
        self.selection.set(outcome.selection);
        Ok(())
    }
    pub fn can_undo(&self, redo: bool) -> bool {
        self.authorized()
            && self.revealed.get()
            && self.editable.get()
            && self.history.borrow().can_step(redo)
    }
    pub fn undo(&self, redo: bool) {
        if !self.authorized() || !self.revealed.get() || !self.editable.get() {
            return;
        }
        self.im.reset();
        let result = self.apply_history(redo);
        self.area.queue_draw();
        if let Some(notify) = self.notify.borrow().as_ref() {
            notify(result);
        }
    }
    fn apply_history(&self, redo: bool) -> Result<()> {
        let mut draft = self.draft.borrow_mut();
        let draft = draft
            .as_mut()
            .ok_or(Error("Choose a secure snippet first."))?;
        let mut history = self.history.borrow_mut();
        if let Some(selection) = history.step(
            &mut self.vault.borrow_mut(),
            draft,
            self.selection.get(),
            redo,
        )? {
            self.selection.set(selection);
            self.dirty.set(history.is_dirty());
        }
        Ok(())
    }
    fn place_pointer(&self, x: f64, y: f64, extend: bool) {
        if !self.authorized()
            || !self.revealed.get()
            || !self.editable.get()
            || !x.is_finite()
            || !y.is_finite()
        {
            return;
        }
        let result = (|| {
            let draft = self.draft.borrow();
            let draft = draft
                .as_ref()
                .ok_or(Error("Choose a secure snippet first."))?;
            let body = self.vault.borrow_mut().draft_body(draft, true)?;
            let text = std::str::from_utf8(&body)
                .map_err(|_| Error("The secure body is not supported UTF-8 text."))?;
            let layout = body_layout(&self.area, text, self.area.width());
            let (_, index, trailing) = layout.xy_to_index(
                ((x - 16.0) * f64::from(gtk::pango::SCALE)) as i32,
                ((y - 16.0 + self.viewport.get()) * f64::from(gtk::pango::SCALE)) as i32,
            );
            layout.set_text("");
            if index < 0 || trailing < 0 {
                return Err(Error("The secure cursor is invalid."));
            }
            let selection =
                self.selection
                    .get()
                    .place(&body, index as usize, trailing as usize, extend)?;
            self.selection.set(selection);
            Ok(())
        })();
        if result.is_ok() {
            self.im.reset();
        }
        self.area.queue_draw();
        if let Err(error) = result
            && let Some(notify) = self.notify.borrow().as_ref()
        {
            notify(Err(error));
        }
    }
    #[cfg(test)]
    pub(crate) fn fixture_edit(&self, text: &str) -> Result<()> {
        self.apply(Edit::Insert, text, false)
    }
    #[cfg(test)]
    pub(crate) fn fixture_select_all(&self) -> Result<()> {
        self.apply(Edit::SelectAll, "", false)
    }
    #[cfg(test)]
    pub(crate) fn fixture_undo(&self, redo: bool) -> Result<()> {
        self.apply_history(redo)
    }
    pub fn allow(&self, value: bool) {
        self.allowed.set(value);
        if !value {
            self.reveal(false);
        }
    }
    pub fn reveal(&self, value: bool) {
        self.revealed.set(value && self.allowed.get());
        if !self.revealed.get() {
            self.selection
                .set(Selection::caret(self.selection.get().head()));
        }
        self.im.reset();
        self.area.queue_draw();
    }
    pub fn is_dirty(&self) -> bool {
        self.dirty.get()
    }
    pub(crate) fn accept_legacy_repair(
        &self,
        receipt: &crate::vault::legacy_repair::Receipt,
    ) -> Result<()> {
        if self.is_dirty() {
            return Err(Error(
                "The encrypted draft changed during metadata repair. Reload the saved entry before editing.",
            ));
        }
        if let Some(draft) = self.draft.borrow_mut().as_mut() {
            receipt.adopt(&mut self.vault.borrow_mut(), draft)?;
        }
        self.reveal(false);
        Ok(())
    }
    pub fn metadata(&self) -> Option<Metadata> {
        self.draft.borrow().as_ref().map(|d| d.metadata.clone())
    }
    pub fn is_foreign(&self) -> bool {
        self.draft
            .borrow()
            .as_ref()
            .is_some_and(|draft| self.vault.borrow().draft_is_foreign(draft))
    }
    pub fn prepare_recovery(
        &self,
        metadata: Metadata,
    ) -> Result<crate::vault::DraftRecoveryRequest> {
        let draft = self.draft.borrow();
        self.vault.borrow_mut().prepare_draft_recovery(
            draft
                .as_ref()
                .ok_or(Error("There is no encrypted draft to recover."))?,
            metadata,
        )
    }
    pub fn finish_recovery(&self, prepared: crate::vault::PreparedDraftRecovery) -> Result<()> {
        let mut draft = self.draft.borrow_mut();
        self.vault.borrow_mut().finish_draft_recovery(
            draft.as_mut().ok_or(Error(
                "The encrypted draft changed before recovery finished.",
            ))?,
            prepared,
        )?;
        self.selection.set(Selection::default());
        self.viewport.set(0.0);
        self.history.borrow_mut().reset(false);
        self.dirty.set(true);
        self.reveal(false);
        Ok(())
    }
    pub fn load(&self, id: uuid::Uuid) -> Result<()> {
        let mut vault = self.vault.borrow_mut();
        let body = vault.body(id)?;
        let expected = vault
            .record(id)
            .ok_or(Error("This secure entry no longer exists."))?;
        let draft = vault.protect_draft(expected.metadata.clone(), &body, Some(expected))?;
        *self.draft.borrow_mut() = Some(draft);
        self.history.borrow_mut().reset(true);
        self.editable.set(true);
        self.selection.set(Selection::default());
        self.viewport.set(0.0);
        self.dirty.set(false);
        self.reveal(false);
        Ok(())
    }
    pub fn create(&self) -> Result<()> {
        *self.draft.borrow_mut() = Some(self.vault.borrow_mut().protect_draft(
            Metadata::new(),
            b"",
            None,
        )?);
        self.history.borrow_mut().reset(false);
        self.editable.set(true);
        self.selection.set(Selection::default());
        self.viewport.set(0.0);
        self.dirty.set(true);
        self.reveal(false);
        Ok(())
    }
    pub fn ephemeral(&self, bytes: &[u8]) -> Result<()> {
        *self.draft.borrow_mut() = Some(self.vault.borrow_mut().protect_draft(
            Metadata::new(),
            bytes,
            None,
        )?);
        self.history.borrow_mut().reset(true);
        self.selection.set(Selection::default());
        self.viewport.set(0.0);
        self.dirty.set(false);
        self.editable.set(false);
        self.area.queue_draw();
        Ok(())
    }
    pub fn discard(&self) {
        self.draft.borrow_mut().take();
        self.history.borrow_mut().reset(true);
        self.selection.set(Selection::default());
        self.viewport.set(0.0);
        self.dirty.set(false);
        self.reveal(false);
    }
    pub fn save(&self, library: &Library, metadata: Metadata) -> Result<()> {
        let mut draft = self.draft.borrow_mut();
        let draft = draft
            .as_mut()
            .ok_or(Error("Choose a secure snippet first."))?;
        let mut vault = self.vault.borrow_mut();
        let body = vault.draft_body(draft, true)?;
        vault.save(library, metadata, &body, draft.expected.as_ref())?;
        let saved = vault
            .record(draft.metadata.id)
            .ok_or(Error("Reload the secure snippet before continuing."))?;
        draft.metadata = saved.metadata.clone();
        draft.expected = Some(saved);
        self.history.borrow_mut().mark_saved();
        self.dirty.set(false);
        Ok(())
    }
    pub fn delete(&self, library: &Library) -> Result<()> {
        let draft = self.draft.borrow();
        let draft = draft
            .as_ref()
            .ok_or(Error("Choose a secure snippet first."))?;
        let expected = draft
            .expected
            .as_ref()
            .ok_or(Error("This entry has not been saved yet."))?;
        self.vault
            .borrow_mut()
            .delete(library, draft.metadata.id, expected)
    }
    pub fn rewrap(&self, transition: &crate::vault::DraftRewrap) -> Result<()> {
        if let Some(draft) = self.draft.borrow_mut().as_mut() {
            self.history
                .borrow_mut()
                .rewrap(&mut self.vault.borrow_mut(), draft, transition)?;
        }
        Ok(())
    }
}
