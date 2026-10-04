//! Native clipboard input stays bound to a focused owner and a one-use receipt.
use super::*;
const CANCELLED: Error =
    Error("Paste was cancelled. Reveal and focus the protected editor to try again.");
impl Drop for ProtectedEditor {
    fn drop(&mut self) {
        self.cancel_paste();
    }
}
impl ProtectedEditor {
    pub(crate) fn observe_desktop(&self, witness: Option<crate::desktop::SessionWitness>) {
        self.cancel_paste();
        *self.desktop.borrow_mut() = witness;
    }
    pub(crate) fn cancel_paste(&self) {
        if let Some(request) = self.paste.borrow_mut().take() {
            request.cancel();
        }
        if let Some(task) = self.paste_task.borrow_mut().take() {
            task.abort();
        }
    }
    pub(crate) fn can_paste(&self) -> bool {
        self.authorized()
            && self.revealed.get()
            && self.editable.get()
            && self.paste.borrow().is_none()
            && self.draft.borrow().is_some()
            && self.vault.borrow_mut().is_unlocked()
            && self.desktop.borrow().as_ref().is_some_and(|witness| {
                witness.snapshot().0 == crate::desktop::SessionState::Unlocked
            })
    }
    fn owns_paste(&self, request: &Rc<protected_edit::PasteRequest>) -> bool {
        self.paste
            .borrow()
            .as_ref()
            .is_some_and(|pending| Rc::ptr_eq(pending, request))
    }
    fn validate_paste(&self, request: &Rc<protected_edit::PasteRequest>) -> Result<()> {
        if !self.owns_paste(request)
            || !self.authorized()
            || !self.area.has_focus()
            || !self.revealed.get()
            || !self.editable.get()
        {
            return Err(CANCELLED);
        }
        let draft = self.draft.borrow();
        request.validate(
            &mut self.vault.borrow_mut(),
            draft.as_ref().ok_or(CANCELLED)?,
            self.selection.get(),
        )
    }
    fn apply_paste(&self, request: &protected_edit::PasteRequest, text: &str) -> Result<()> {
        let mut draft = self.draft.borrow_mut();
        let mut history = self.history.borrow_mut();
        let outcome = request.complete(
            &mut self.vault.borrow_mut(),
            draft.as_mut().ok_or(CANCELLED)?,
            &mut history,
            self.selection.get(),
            text,
        )?;
        self.selection.set(outcome.selection);
        self.dirty.set(history.is_dirty());
        Ok(())
    }
    #[cfg(test)]
    pub(crate) fn fixture_paste(&self, text: &str) -> Result<()> {
        let request = protected_edit::PasteRequest::new(
            &mut self.vault.borrow_mut(),
            self.draft.borrow().as_ref().ok_or(CANCELLED)?,
            self.selection.get(),
            crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
        )?;
        self.apply_paste(&request, text)
    }
    pub(crate) fn paste(self: &Rc<Self>) {
        self.cancel_paste();
        if !self.can_paste() {
            return;
        }
        self.im.reset();
        self.area.grab_focus();
        if !self.area.has_focus() {
            return;
        }
        let request = (|| {
            let draft = self.draft.borrow();
            protected_edit::PasteRequest::new(
                &mut self.vault.borrow_mut(),
                draft.as_ref().ok_or(CANCELLED)?,
                self.selection.get(),
                self.desktop.borrow().clone().ok_or(CANCELLED)?,
            )
            .map(Rc::new)
        })();
        let request = match request {
            Ok(request) => request,
            Err(error) => {
                if let Some(notify) = self.notify.borrow().as_ref() {
                    notify(Err(error));
                }
                return;
            }
        };
        *self.paste.borrow_mut() = Some(request.clone());
        if let Some(notify) = self.notify.borrow().as_ref() {
            notify(Ok(()));
        }
        let clipboard = self.area.clipboard();
        let weak = Rc::downgrade(self);
        let task = glib::MainContext::default().spawn_local(async move {
            let text = crate::sensitive_clipboard::read(&clipboard, || {
                weak.upgrade().ok_or(CANCELLED)?.validate_paste(&request)
            })
            .await;
            let Some(this) = weak.upgrade() else {
                request.cancel();
                return;
            };
            // A cancelled or superseded read cannot clear the newer request.
            if !this.owns_paste(&request) {
                request.cancel();
                return;
            }
            let result = text.and_then(|text| {
                this.validate_paste(&request)?;
                this.apply_paste(&request, &text)
            });
            this.paste.borrow_mut().take();
            // Release our handle before notifying: a callback may hide/reload
            // the editor, but must not abort this currently polling future.
            this.paste_task.borrow_mut().take();
            request.cancel();
            this.area.queue_draw();
            if let Some(notify) = this.notify.borrow().as_ref() {
                notify(result);
            }
        });
        *self.paste_task.borrow_mut() = Some(task);
    }
}
