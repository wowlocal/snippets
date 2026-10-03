//! Native consent and fresh vault authentication. Offers/notices contain metadata only.
use crate::{
    control::{
        self, Status,
        server::{Command, Handle, Notice, Offer},
    },
    desktop::{SessionMonitor, SessionState, SessionWitness},
    model::{Error, Result},
    secure_insertion::Authorization,
};
use adw::prelude::*;
use gtk::glib;
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    ffi::CStr,
    path::PathBuf,
    rc::Rc,
    time::Duration,
};
use zeroize::Zeroizing;

pub(crate) struct Service {
    application: adw::Application,
    root: PathBuf,
    server: RefCell<Option<Handle>>,
    desktop: Option<SessionMonitor>,
    busy: Cell<bool>,
    quitting: Cell<bool>,
    active: RefCell<Option<Rc<Active>>>,
    recent: RefCell<VecDeque<Duration>>,
    before: Box<dyn Fn() -> bool>,
    created: Box<dyn Fn()>,
    unlocked: Box<dyn Fn() -> bool>,
}
struct Active {
    window: adw::ApplicationWindow,
    lease: control::Lease,
    witness: SessionWitness,
    dialog: RefCell<Option<(adw::AlertDialog, Option<gtk::PasswordEntry>)>>,
    authorization: RefCell<Option<Authorization>>,
    cancelled: Cell<bool>,
    focused: Cell<bool>,
    started: Cell<Duration>,
    limit: Cell<Duration>,
}
impl Active {
    fn cancel(&self) {
        self.cancelled.set(true);
        if let Some(auth) = self.authorization.borrow_mut().take() {
            auth.cancel();
        }
        let dialog = self.dialog.borrow_mut().take();
        if let Some((dialog, input)) = dialog {
            if let Some(input) = input {
                input.set_text("");
            }
            dialog.force_close();
        }
    }
    fn check(&self) -> Result<()> {
        self.lease.check()?;
        if self.cancelled.get()
            || self.witness.snapshot().0 != SessionState::Unlocked
            || crate::clock::uptime()
                .and_then(|now| now.checked_sub(self.started.get()))
                .is_none_or(|elapsed| elapsed >= self.limit.get())
        {
            return Err(control::CLOSED);
        }
        if let Some(auth) = self.authorization.borrow().as_ref() {
            auth.validate()?;
        }
        Ok(())
    }
}
impl Service {
    pub(crate) fn new(
        application: &adw::Application,
        root: PathBuf,
        before: impl Fn() -> bool + 'static,
        created: impl Fn() + 'static,
        unlocked: impl Fn() -> bool + 'static,
    ) -> Rc<Self> {
        let this = Rc::new(Self {
            application: application.clone(),
            root,
            server: RefCell::new(None),
            desktop: SessionMonitor::new(),
            busy: Cell::new(false),
            quitting: Cell::new(false),
            active: RefCell::new(None),
            recent: RefCell::new(VecDeque::new()),
            before: Box::new(before),
            created: Box::new(created),
            unlocked: Box::new(unlocked),
        });
        this.start();
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_millis(25), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let offers: Vec<_> = this
                .server
                .borrow()
                .as_ref()
                .map(|server| server.receiver.try_iter().collect())
                .unwrap_or_default();
            for offer in offers {
                this.accept(offer);
            }
            if this.server.borrow().as_ref().is_some_and(Handle::finished) && !this.quitting.get() {
                this.server.borrow_mut().take();
                this.start();
            }
            glib::ControlFlow::Continue
        });
        this
    }
    fn start(&self) {
        if self.server.borrow().is_some() || self.quitting.get() {
            return;
        }
        match Handle::start(self.root.clone()) {
            Ok(server) => *self.server.borrow_mut() = Some(server),
            Err(error) => eprintln!("{error}"),
        }
    }
    pub(crate) fn prepare_quit(&self) -> bool {
        self.quitting.set(true);
        if let Some(active) = self.active.borrow().as_ref() {
            active.cancel();
        }
        if let Some(server) = self.server.borrow().as_ref() {
            server.stop();
        }
        !self.busy.get() && self.server.borrow().as_ref().is_none_or(Handle::finished)
    }
    pub(crate) fn cancel_quit(&self) {
        self.quitting.set(false);
        if self.server.borrow().as_ref().is_none_or(Handle::finished) {
            self.server.borrow_mut().take();
            self.start();
        }
    }
    fn accept(self: &Rc<Self>, offer: Offer) {
        if self.quitting.get() || offer.lease.check().is_err() {
            let _ = offer.commands.send(Command::Deny);
            return;
        }
        if offer.header.command == "status" {
            let _ = offer.commands.send(Command::State((self.unlocked)()));
            return;
        }
        let Some(now) = crate::clock::uptime() else {
            let _ = offer.commands.send(Command::Refuse);
            return;
        };
        self.recent.borrow_mut().retain(|old| {
            now.checked_sub(*old)
                .is_some_and(|elapsed| elapsed < Duration::from_secs(60))
        });
        if self.busy.get() || self.recent.borrow().len() >= 5 || !(self.before)() {
            let _ = offer.commands.send(Command::Refuse);
            return;
        }
        self.recent.borrow_mut().push_back(now);
        self.busy.set(true);
        let this = self.clone();
        glib::spawn_future_local(async move {
            this.run(offer).await;
            let active = this.active.borrow_mut().take();
            if let Some(active) = active {
                active.cancel();
                active.window.destroy();
            }
            this.busy.set(false);
        });
    }
    async fn notice(&self, offer: &Offer) -> Result<Notice> {
        loop {
            match offer.notices.try_recv() {
                Ok(notice) => return Ok(notice),
                Err(std::sync::mpsc::TryRecvError::Disconnected) => return Err(control::CLOSED),
                Err(_) => (),
            }
            offer.lease.check()?;
            glib::timeout_future(Duration::from_millis(25)).await;
        }
    }
    async fn run(&self, offer: Offer) {
        if offer.commands.send(Command::Prepare).is_err() {
            return;
        }
        let Ok(notice) = self.notice(&offer).await else {
            return;
        };
        let preview = match notice {
            Notice::Prepared(preview) => preview,
            Notice::Finished { .. } => return,
        };
        let Some(witness) = self.desktop.as_ref().map(SessionMonitor::witness) else {
            let _ = offer.commands.send(Command::Deny);
            return;
        };
        let window = adw::ApplicationWindow::builder()
            .application(&self.application)
            .title("Snippets CLI Request")
            .default_width(560)
            .default_height(340)
            .build();
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 16);
        window.set_content(Some(&layout));
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Command Request",
            "Secure Snippets",
        )));
        layout.append(&header);
        let fields = gtk::Box::new(gtk::Orientation::Vertical, 16);
        fields.set_margin_start(24);
        fields.set_margin_end(24);
        fields.set_margin_bottom(24);
        let caller = gtk::Label::new(Some(&offer.caller));
        caller.set_xalign(0.0);
        caller.set_wrap(true);
        caller.set_max_width_chars(60);
        caller.set_lines(4);
        caller.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        caller.set_tooltip_text(Some(&offer.caller));
        fields.append(&caller);
        let keyword = gtk::Label::new(Some(&format!("\\{}", preview.metadata.keyword)));
        keyword.set_xalign(0.0);
        fields.append(&keyword);
        let status = gtk::Label::new(Some(
            "Review this request before entering vault credentials.",
        ));
        status.set_wrap(true);
        status.set_xalign(0.0);
        fields.append(&status);
        layout.append(&fields);
        let active = Rc::new(Active {
            window,
            lease: offer.lease.clone(),
            witness,
            dialog: RefCell::new(None),
            authorization: RefCell::new(None),
            cancelled: Cell::new(false),
            focused: Cell::new(false),
            started: Cell::new(crate::clock::uptime().unwrap_or(Duration::MAX)),
            limit: Cell::new(Duration::from_secs(30)),
        });
        let weak = Rc::downgrade(&active);
        active.window.connect_is_active_notify(move |window| {
            if let Some(active) = weak.upgrade() {
                if window.is_active() {
                    active.focused.set(true);
                } else if active.focused.get() {
                    active.cancel();
                }
            }
        });
        let weak = Rc::downgrade(&active);
        active.window.connect_close_request(move |_| {
            if let Some(active) = weak.upgrade() {
                active.cancel();
            }
            glib::Propagation::Proceed
        });
        let weak = Rc::downgrade(&active);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(active) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if active.check().is_err() {
                active.cancel();
                return glib::ControlFlow::Break;
            }
            glib::ControlFlow::Continue
        });
        *self.active.borrow_mut() = Some(active.clone());
        active.window.present();
        let saving = offer.header.command == "add-secure";
        let consent = consent_dialog(saving);
        *active.dialog.borrow_mut() = Some((consent.clone(), None));
        let response = consent.choose_future(Some(&active.window)).await;
        active.dialog.borrow_mut().take();
        if response != "approve" || !active.window.is_active() || active.check().is_err() {
            let _ = offer.commands.send(Command::Deny);
            let _ = self.notice(&offer).await;
            return;
        }
        let Ok(authorization) = Authorization::new(active.witness.clone()) else {
            let _ = offer.commands.send(Command::Deny);
            return;
        };
        *active.authorization.borrow_mut() = Some(authorization.clone());
        active
            .started
            .set(crate::clock::uptime().unwrap_or(Duration::MAX));
        active.limit.set(Duration::from_secs(60));
        let (dialog, input, recovery) = credential_dialog(preview.passphrase, preview.recovery);
        *active.dialog.borrow_mut() = Some((dialog.clone(), Some(input.clone())));
        let response = dialog.choose_future(Some(&active.window)).await;
        active.dialog.borrow_mut().take();
        let password = take_secret(&input);
        if response != "authenticate" || !active.window.is_active() || active.check().is_err() {
            active.cancel();
            let _ = offer.commands.send(Command::Deny);
            let _ = self.notice(&offer).await;
            return;
        }
        let Ok(password) = password else {
            let _ = offer.commands.send(Command::Deny);
            return;
        };
        status.set_text("Authenticating and completing the approved request…");
        if offer
            .commands
            .send(Command::Authenticate {
                password,
                recovery: recovery.is_active(),
                authorization,
            })
            .is_err()
        {
            return;
        }
        if let Ok(Notice::Finished {
            status: outcome,
            created,
        }) = self.notice(&offer).await
        {
            status.set_text(outcome.message());
            if outcome == Status::Ok && created.is_some() {
                (self.created)();
            }
        }
    }
}
fn consent_dialog(saving: bool) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::builder().heading(if saving { "Save Submitted Secure Text?" } else { "Send Secure Text to This Command?" })
        .body(if saving { "Save the submitted text encrypted in your vault. Existing entries will not be replaced. Fresh vault authentication is required next." }
            else { "This command will receive plaintext on stdout. Its script, logs or downstream tools may retain it. Fresh vault authentication is required next." }).build();
    dialog.add_responses(&[("cancel", "Deny"), ("approve", "Approve and Authenticate")]);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.set_body_use_markup(false);
    dialog
}
fn credential_dialog(
    passphrase: bool,
    has_recovery: bool,
) -> (adw::AlertDialog, gtk::PasswordEntry, gtk::CheckButton) {
    let input = gtk::PasswordEntry::builder()
        .placeholder_text("Vault passphrase")
        .show_peek_icon(false)
        .build();
    input.update_property(&[gtk::accessible::Property::Label("Fresh vault credential")]);
    let recovery = gtk::CheckButton::with_label("Use recovery key");
    recovery.set_active(!passphrase);
    recovery.set_sensitive(passphrase && has_recovery);
    let fields = gtk::Box::new(gtk::Orientation::Vertical, 12);
    fields.append(&input);
    fields.append(&recovery);
    let dialog = adw::AlertDialog::builder().heading("Authenticate This Request").body("Enter your vault passphrase or recovery key. An open editor does not authorize CLI requests.").extra_child(&fields).build();
    dialog.add_responses(&[("cancel", "Cancel"), ("authenticate", "Authenticate")]);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog.set_response_enabled("authenticate", false);
    let changed = dialog.clone();
    input.connect_changed(move |input| {
        changed.set_response_enabled(
            "authenticate",
            secret_len(input).is_ok_and(|n| (1..=4096).contains(&n)),
        )
    });
    (dialog, input, recovery)
}
fn secret_len(input: &gtk::PasswordEntry) -> Result<usize> {
    use glib::translate::ToGlibPtr;
    let pointer = unsafe {
        gtk::ffi::gtk_editable_get_text(input.upcast_ref::<gtk::Editable>().to_glib_none().0)
    };
    if pointer.is_null() {
        return Err(Error("The credential field is unavailable."));
    }
    Ok(unsafe { CStr::from_ptr(pointer) }.to_bytes().len())
}
fn take_secret(input: &gtk::PasswordEntry) -> Result<Zeroizing<String>> {
    use glib::translate::ToGlibPtr;
    let pointer = unsafe {
        gtk::ffi::gtk_editable_get_text(input.upcast_ref::<gtk::Editable>().to_glib_none().0)
    };
    if pointer.is_null() {
        input.set_text("");
        return Err(control::INVALID);
    }
    let bytes = unsafe { CStr::from_ptr(pointer) }.to_bytes();
    let value = if bytes.is_empty() || bytes.len() > 4096 {
        Err(Error("Enter a vault credential within the 4 KiB limit."))
    } else {
        std::str::from_utf8(bytes)
            .map(|s| Zeroizing::new(s.to_owned()))
            .map_err(|_| control::INVALID)
    };
    input.set_text("");
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a graphical display; public dialog fixture only, no server, library or desktop monitor"]
    fn native_cli_dialogs_keep_deny_default_and_clear_fresh_credentials() {
        adw::init().expect("graphical display");
        for saving in [false, true] {
            let dialog = consent_dialog(saving);
            assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
            assert_eq!(dialog.close_response(), "cancel");
            assert!(!dialog.is_body_use_markup());
        }
        let (dialog, input, recovery) = credential_dialog(true, true);
        assert!(!dialog.is_response_enabled("authenticate"));
        assert!(!input.shows_peek_icon());
        assert!(!recovery.is_active());
        input.set_text("Public fictional credential");
        assert!(dialog.is_response_enabled("authenticate"));
        let value = take_secret(&input).unwrap();
        assert_eq!(&*value, "Public fictional credential");
        assert!(input.text().is_empty());
    }
}
