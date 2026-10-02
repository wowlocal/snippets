//! A secure body never enters a GtkTextBuffer, selection, undo stack, or the
//! accessible text interface. Retained editor state consists only of ciphertext.
//! Cairo/Pango and the compositor necessarily see transient revealed pixels;
//! this is not screenshot prevention or a claim about third-party memory erasure.
use crate::{
    model::{Error, Library, MAX_BODY_BYTES, Result},
    vault::{EncryptedDraft, Metadata, Vault},
};
use gtk::{gdk, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};
use zeroize::Zeroizing;

#[derive(Clone, Copy)]
enum Edit {
    Insert,
    Backspace,
    Delete,
    Left,
    Right,
    Home,
    End,
    Start,
    Finish,
    Up,
    Down,
}
fn edit_text(
    bytes: &[u8],
    cursor: usize,
    edit: Edit,
    insertion: &str,
) -> Result<(Zeroizing<Vec<u8>>, usize)> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| Error("The secure body is not supported UTF-8 text."))?;
    if cursor > bytes.len() || !text.is_char_boundary(cursor) {
        return Err(Error("The secure cursor is invalid."));
    }
    let previous = text[..cursor]
        .char_indices()
        .next_back()
        .map_or(0, |(i, _)| i);
    let next = cursor + text[cursor..].chars().next().map_or(0, char::len_utf8);
    let start = text[..cursor].rfind('\n').map_or(0, |i| i + 1);
    let end = text[cursor..]
        .find('\n')
        .map_or(bytes.len(), |i| cursor + i);
    let mut output = Zeroizing::new(Vec::with_capacity(MAX_BODY_BYTES));
    let mut position = cursor;
    match edit {
        Edit::Insert => {
            if insertion.contains('\0')
                || bytes.len().saturating_add(insertion.len()) > MAX_BODY_BYTES
            {
                return Err(Error(
                    "Secure content exceeds the 256 KiB limit or contains an unsupported character.",
                ));
            }
            output.extend_from_slice(&bytes[..cursor]);
            output.extend_from_slice(insertion.as_bytes());
            output.extend_from_slice(&bytes[cursor..]);
            position += insertion.len();
        }
        Edit::Backspace => {
            output.extend_from_slice(&bytes[..previous]);
            output.extend_from_slice(&bytes[cursor..]);
            position = previous;
        }
        Edit::Delete => {
            output.extend_from_slice(&bytes[..cursor]);
            output.extend_from_slice(&bytes[next..]);
        }
        movement => {
            output.extend_from_slice(bytes);
            position = match movement {
                Edit::Left => previous,
                Edit::Right => next,
                Edit::Home => start,
                Edit::End => end,
                Edit::Start => 0,
                Edit::Finish => bytes.len(),
                Edit::Up | Edit::Down => {
                    let column = text[start..cursor].chars().count();
                    let line = if matches!(movement, Edit::Up) {
                        if start == 0 {
                            0
                        } else {
                            text[..start - 1].rfind('\n').map_or(0, |i| i + 1)
                        }
                    } else if end == bytes.len() {
                        start
                    } else {
                        end + 1
                    };
                    let line_end = text[line..].find('\n').map_or(bytes.len(), |i| line + i);
                    text[line..line_end]
                        .char_indices()
                        .nth(column)
                        .map_or(line_end, |(i, _)| line + i)
                }
                _ => unreachable!(),
            };
        }
    }
    Ok((output, position))
}

type ChangeCallback = Box<dyn Fn(Result<()>)>;
pub struct ProtectedEditor {
    pub area: gtk::DrawingArea,
    vault: Rc<RefCell<Vault>>,
    draft: RefCell<Option<EncryptedDraft>>,
    cursor: Cell<usize>,
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
        let im = gtk::IMContextSimple::new();
        im.set_client_widget(Some(&area));
        im.set_input_purpose(gtk::InputPurpose::Password);
        im.set_input_hints(gtk::InputHints::PRIVATE | gtk::InputHints::NO_SPELLCHECK);
        let this = Rc::new(Self {
            area,
            vault,
            draft: RefCell::new(None),
            cursor: Cell::new(0),
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
            let layout = pangocairo::functions::create_layout(cr);
            layout.set_font_description(Some(&gtk::pango::FontDescription::from_string(
                "monospace 12",
            )));
            layout.set_width((width - 32).max(1) * gtk::pango::SCALE);
            layout.set_wrap(gtk::pango::WrapMode::WordChar);
            layout.set_text(text);
            let color = area.color();
            cr.set_source_rgba(
                color.red().into(),
                color.green().into(),
                color.blue().into(),
                color.alpha().into(),
            );
            let caret = layout
                .cursor_pos(this.cursor.get().min(text.len()) as i32)
                .0;
            let offset = if body.is_some() {
                (f64::from(caret.y() / gtk::pango::SCALE) - f64::from(area.height().max(64) - 48))
                    .max(0.0)
            } else {
                0.0
            };
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
            let edit = match key {
                gdk::Key::BackSpace => Some(Edit::Backspace),
                gdk::Key::Delete => Some(Edit::Delete),
                gdk::Key::Left => Some(Edit::Left),
                gdk::Key::Right => Some(Edit::Right),
                gdk::Key::Up => Some(Edit::Up),
                gdk::Key::Down => Some(Edit::Down),
                gdk::Key::Home => Some(if control { Edit::Start } else { Edit::Home }),
                gdk::Key::End => Some(if control { Edit::Finish } else { Edit::End }),
                gdk::Key::Return | gdk::Key::KP_Enter if !control => {
                    this.edit(Edit::Insert, "\n");
                    return glib::Propagation::Stop;
                }
                gdk::Key::Tab if !control => {
                    this.edit(Edit::Insert, "\t");
                    return glib::Propagation::Stop;
                }
                _ => None,
            };
            if let Some(edit) = edit {
                this.edit(edit, "");
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
                this.edit(Edit::Insert, text);
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
        let weak = Rc::downgrade(&this);
        click.connect_pressed(move |_, _, _, _| {
            if let Some(this) = weak.upgrade() {
                this.area.grab_focus();
            }
        });
        this.area.add_controller(click);
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
    fn edit(&self, edit: Edit, insertion: &str) {
        if !self.authorized() || !self.revealed.get() || !self.editable.get() {
            return;
        }
        let result = self.apply(edit, insertion);
        self.area.queue_draw();
        if let Some(notify) = self.notify.borrow().as_ref() {
            notify(result);
        }
    }
    fn apply(&self, edit: Edit, insertion: &str) -> Result<()> {
        let mut draft = self.draft.borrow_mut();
        let old = draft
            .as_ref()
            .ok_or(Error("Choose a secure snippet first."))?;
        let mut vault = self.vault.borrow_mut();
        let body = vault.draft_body(old, true)?;
        let (body, position) = edit_text(&body, self.cursor.get(), edit, insertion)?;
        if matches!(edit, Edit::Insert | Edit::Backspace | Edit::Delete) {
            *draft =
                Some(vault.protect_draft(old.metadata.clone(), &body, old.expected.clone())?);
            self.dirty.set(true);
        }
        self.cursor.set(position);
        Ok(())
    }
    #[cfg(test)]
    pub(crate) fn fixture_edit(&self, text: &str) -> Result<()> {
        self.apply(Edit::Insert, text)
    }
    pub fn allow(&self, value: bool) {
        self.allowed.set(value);
        if !value {
            self.reveal(false);
        }
    }
    pub fn reveal(&self, value: bool) {
        self.revealed.set(value && self.allowed.get());
        self.im.reset();
        self.area.queue_draw();
    }
    pub fn is_dirty(&self) -> bool {
        self.dirty.get()
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
        self.cursor.set(0);
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
        self.cursor.set(0);
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
        self.cursor.set(0);
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
        self.cursor.set(0);
        self.dirty.set(false);
        self.editable.set(false);
        self.area.queue_draw();
        Ok(())
    }
    pub fn discard(&self) {
        self.draft.borrow_mut().take();
        self.cursor.set(0);
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
            self.vault.borrow_mut().rebind_draft(draft, transition)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_cursor_edits_newlines_and_bounds_preserve_the_body() {
        let (body, cursor) =
            edit_text("Привет 🦀\nsecond".as_bytes(), 0, Edit::Insert, "α").unwrap();
        assert!(std::str::from_utf8(&body).unwrap() == "αПривет 🦀\nsecond" && cursor == 2);
        let (body, cursor) = edit_text(&body, cursor, Edit::Backspace, "").unwrap();
        assert!(std::str::from_utf8(&body).unwrap() == "Привет 🦀\nsecond" && cursor == 0);
        let (body, end) = edit_text(&body, 0, Edit::End, "").unwrap();
        let (body, left) = edit_text(&body, end, Edit::Left, "").unwrap();
        let (body, _) = edit_text(&body, left, Edit::Delete, "").unwrap();
        assert!(std::str::from_utf8(&body).unwrap() == "Привет \nsecond");
        assert!(edit_text(&body, 1, Edit::Insert, "x").is_err());
        assert!(edit_text(&body, 0, Edit::Insert, "\0").is_err());
        let maximum = vec![b'a'; MAX_BODY_BYTES];
        assert!(edit_text(&maximum, 0, Edit::Insert, "x").is_err());
    }
}
