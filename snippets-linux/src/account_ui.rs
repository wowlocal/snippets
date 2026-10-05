//! Native account and recovery UI. Tokens remain in one serialized worker.
//! Recovery material is drawn only while its revocable lease remains valid;
//! it never enters a GTK text buffer, accessible text or the clipboard.
//! The account key is the exception the account-key contract requires: its
//! display form is selectable text with Copy, cleared when the presentation ends.
use crate::{
    account_key::AccountKey,
    account_worker::{AutomaticStatus, Command, Failure, Handle, Reply, Result},
    auth_store::{AccountKeyDisclosure, creation},
    bootstrap::Invitation,
    cloud::Role,
    desktop::{SessionMonitor, SessionState},
    key_store::{
        self, KitStatus, Outcome, candidate, disclosure::Disclosure, handover, initial_candidate,
        mutations, recipient::RetainedStatus, restoration,
    },
    local_auth::{Gate, Permit, Purpose, Request, Target},
    pairing_ui_state::Countdown,
    recovery_qr::Matrix,
};
use adw::prelude::*;
use gtk::{glib, glib::translate::ToGlibPtr};
use std::{
    cell::{Cell, RefCell},
    ffi::CStr,
    rc::Rc,
    sync::mpsc,
    time::Duration,
};
use zeroize::Zeroizing;

#[path = "recovery_history_ui.rs"]
mod history_view;

#[path = "history_removal_ui.rs"]
mod history_removal_view;

#[path = "restoration_ui.rs"]
mod restoration_view;
#[path = "vault_sync_ui.rs"]
mod vault_sync_view;

fn label(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.set_xalign(0.0);
    label.set_wrap(true);
    label
}

fn secret(entry: &impl IsA<gtk::Editable>) -> Result<Zeroizing<String>> {
    // Borrow GTK's NUL-terminated UTF-8 in place, avoiding another GString copy.
    // GTK/input-method allocations remain outside Rust's erasure guarantee.
    let result = unsafe {
        let pointer = gtk::ffi::gtk_editable_get_text(entry.as_ref().to_glib_none().0);
        let bytes = CStr::from_ptr(pointer).to_bytes();
        if bytes.len() > 4096 {
            Err(Failure::InvalidState)
        } else {
            std::str::from_utf8(bytes)
                .map(|s| Zeroizing::new(s.to_owned()))
                .map_err(|_| Failure::InvalidState)
        }
    };
    entry.set_text("");
    result
}
fn draw_qr(cr: &gtk::cairo::Context, qr: &Matrix, width: i32) -> f64 {
    let modules = qr.width() + 8;
    let scale = (((width - 32).max(1) as usize).min(400) / modules).max(1) as f64;
    let side = modules as f64 * scale;
    let left = ((f64::from(width) - side) / 2.0).floor();
    let _ = cr.save();
    cr.set_antialias(gtk::cairo::Antialias::None);
    cr.set_source_rgb(1.0, 1.0, 1.0);
    cr.rectangle(left, 8.0, side, side);
    let _ = cr.fill();
    cr.set_source_rgb(0.0, 0.0, 0.0);
    for y in 0..qr.width() {
        for x in 0..qr.width() {
            if qr.dark(x, y) {
                cr.rectangle(
                    left + (x + 4) as f64 * scale,
                    8.0 + (y + 4) as f64 * scale,
                    scale,
                    scale,
                );
            }
        }
    }
    let _ = cr.fill();
    let _ = cr.restore();
    side
}
/// A public pairing invitation or device sign-in request: no private key, poll
/// token, account credential or library key is ever part of this payload.
struct PairingPresentation {
    payload: Vec<u8>,
    id: uuid::Uuid,
    qr: Matrix,
    countdown: Option<Countdown>,
}
struct PairingView {
    area: gtk::DrawingArea,
    value: RefCell<Option<PairingPresentation>>,
}
impl PairingView {
    fn new() -> Rc<Self> {
        let area = gtk::DrawingArea::builder()
            .content_width(380)
            .content_height(410)
            .hexpand(true)
            .build();
        area.update_property(&[gtk::accessible::Property::Label(
            "Public device-pairing invitation QR",
        )]);
        let this = Rc::new(Self {
            area,
            value: RefCell::new(None),
        });
        let weak = Rc::downgrade(&this);
        this.area.set_draw_func(move |_, cr, width, _| {
            let Some(this) = weak.upgrade() else {
                return;
            };
            let value = this.value.borrow();
            if let Some(value) = value.as_ref()
                && value
                    .countdown
                    .as_ref()
                    .is_some_and(|c| !c.remaining().is_zero())
            {
                draw_qr(cr, &value.qr, width);
            }
        });
        this
    }
    fn show(&self, invitation: Invitation) -> Result<()> {
        let payload = invitation.encode_qr().map_err(|_| Failure::InvalidState)?;
        self.present(payload.to_vec(), invitation.pairing(), || {
            Countdown::new(&invitation)
        })
    }
    fn show_device(&self, request: &crate::bootstrap::DeviceSignIn) -> Result<()> {
        let payload = request.encode_qr().map_err(|_| Failure::InvalidState)?;
        self.present(payload.to_vec(), request.request(), || {
            Countdown::for_device(request)
        })
    }
    fn present(
        &self,
        payload: Vec<u8>,
        id: uuid::Uuid,
        countdown: impl FnOnce() -> Option<Countdown>,
    ) -> Result<()> {
        let same = self.value.borrow().as_ref().is_some_and(|v| {
            v.payload == payload
                && v.id == id
                && v.countdown.as_ref().is_some_and(|c| c.matches_id(id))
        });
        if same {
            // A status refresh cannot restart this invitation's monotonic timer.
            if let Some(countdown) = self
                .value
                .borrow_mut()
                .as_mut()
                .and_then(|v| v.countdown.as_mut())
            {
                countdown.checked();
            }
            return Ok(());
        }
        let qr = Matrix::new(&payload).map_err(|_| Failure::InvalidState)?;
        let countdown = countdown();
        *self.value.borrow_mut() = Some(PairingPresentation {
            payload,
            id,
            qr,
            countdown,
        });
        self.area.queue_draw();
        Ok(())
    }
    fn clear(&self) {
        self.value.borrow_mut().take();
        self.area.queue_draw();
    }
    fn remaining(&self) -> Duration {
        self.value
            .borrow()
            .as_ref()
            .and_then(|v| v.countdown.as_ref())
            .map_or(Duration::ZERO, Countdown::remaining)
    }
    fn poll_due(&self) -> bool {
        self.value
            .borrow_mut()
            .as_mut()
            .and_then(|v| v.countdown.as_mut())
            .is_some_and(Countdown::poll_due)
    }
    fn defer(&self, delay: Duration) {
        if let Some(countdown) = self
            .value
            .borrow_mut()
            .as_mut()
            .and_then(|v| v.countdown.as_mut())
        {
            countdown.defer(delay);
        }
    }
    fn copy(&self) -> Result<()> {
        if self.remaining().is_zero() {
            return Err(Failure::InvalidState);
        }
        let value = self.value.borrow();
        let payload = &value.as_ref().ok_or(Failure::InvalidState)?.payload;
        // This public payload contains no library key, private key, poll token or
        // recovery capability. It is safe to transfer to the approving device.
        let text = std::str::from_utf8(payload).map_err(|_| Failure::InvalidState)?;
        self.area
            .clipboard()
            .set_content(Some(&crate::ui::internal_clipboard_provider(text)))
            .map_err(|_| Failure::InvalidState)?;
        Ok(())
    }
}
struct Presentation {
    disclosure: Disclosure,
    qr: Matrix,
}
struct RecoveryView {
    area: gtk::DrawingArea,
    value: RefCell<Option<Presentation>>,
}
impl RecoveryView {
    fn new() -> Rc<Self> {
        let area = gtk::DrawingArea::builder()
            .content_width(380)
            .content_height(500)
            .hexpand(true)
            .build();
        area.update_property(&[gtk::accessible::Property::Label(
            "Recovery QR and code. Protected visual content.",
        )]);
        let this = Rc::new(Self {
            area,
            value: RefCell::new(None),
        });
        let weak = Rc::downgrade(&this);
        this.area.set_draw_func(move |area, cr, width, _| {
            let Some(this) = weak.upgrade() else {
                return;
            };
            let value = this.value.borrow();
            let Some(value) = value.as_ref() else {
                return;
            };
            // Never draw a cached matrix after loss of the disclosure lease.
            let Ok(code) = value.disclosure.long_code() else {
                return;
            };
            if value.disclosure.qr_payload().is_err() {
                return;
            }
            let side = draw_qr(cr, &value.qr, width);
            let layout = pangocairo::functions::create_layout(cr);
            layout.set_font_description(Some(&gtk::pango::FontDescription::from_string(
                "monospace 13",
            )));
            layout.set_width((width - 32).max(1) * gtk::pango::SCALE);
            layout.set_wrap(gtk::pango::WrapMode::WordChar);
            layout.set_text(code);
            let color = area.color();
            cr.set_source_rgba(
                color.red().into(),
                color.green().into(),
                color.blue().into(),
                color.alpha().into(),
            );
            cr.move_to(16.0, side + 24.0);
            pangocairo::functions::show_layout(cr, &layout);
            layout.set_text("");
        });
        this
    }
    fn show(&self, disclosure: Disclosure) -> Result<()> {
        let qr = Matrix::new(disclosure.qr_payload()?).map_err(|_| Failure::InvalidState)?;
        disclosure.long_code()?;
        *self.value.borrow_mut() = Some(Presentation { disclosure, qr });
        self.area.queue_draw();
        Ok(())
    }
    fn clear(&self) {
        self.value.borrow_mut().take();
        self.area.queue_draw();
    }
    fn take(&self) -> Option<Disclosure> {
        let value = self.value.borrow_mut().take();
        self.area.queue_draw();
        value.map(|v| v.disclosure)
    }
    fn visible(&self) -> bool {
        self.value.borrow().is_some()
    }
    fn expired(&self) -> bool {
        self.value
            .borrow()
            .as_ref()
            .is_some_and(|v| v.disclosure.long_code().is_err())
    }
}

const CREATED_KEY_MESSAGE: &str = "This key is the only way to sign in to this account on another device. Snippets can't recover it or send it to you. Store it in your password manager.";
const CLIPBOARD_KEY_LIFETIME: Duration = Duration::from_secs(120);
/// The single account-key presentation. A created key is shown once after its
/// session is committed; a disclosed key is readable only under its lease.
enum KeyPresentation {
    Created(AccountKey),
    Disclosed(AccountKeyDisclosure),
}
impl KeyPresentation {
    fn display(&self) -> Result<Zeroizing<String>> {
        match self {
            Self::Created(key) => Ok(key.display()),
            Self::Disclosed(disclosure) => Ok(disclosure.display()?),
        }
    }
}
/// The created presentation's retained continuation: shown after "I've Saved It".
type CreatedNext = (Option<Box<Reply>>, Option<Failure>);
/// Copies the key with the internal history marker and the password-manager hint
/// so clipboard managers skip it, then clears it after two minutes only if the
/// clipboard still holds this exact copy.
fn copy_account_key(widget: &impl IsA<gtk::Widget>, text: &str) -> Result<()> {
    let clipboard = widget.clipboard();
    let provider = gtk::gdk::ContentProvider::new_union(&[
        crate::ui::internal_clipboard_provider(text),
        gtk::gdk::ContentProvider::for_bytes(
            "x-kde-passwordManagerHint",
            &glib::Bytes::from_static(b"secret"),
        ),
    ]);
    clipboard
        .set_content(Some(&provider))
        .map_err(|_| Failure::InvalidState)?;
    glib::timeout_add_local_once(CLIPBOARD_KEY_LIFETIME, move || {
        if clipboard.content().as_ref() == Some(&provider) {
            let _ = clipboard.set_content(None::<&gtk::gdk::ContentProvider>);
        }
    });
    Ok(())
}

pub(crate) struct AccountWindow {
    pub(crate) window: adw::ApplicationWindow,
    worker: Rc<Handle>,
    automatic_button: gtk::Button,
    automatic_status: gtk::Label,
    automatic_pending: Cell<bool>,
    desktop: Option<SessionMonitor>,
    gate: RefCell<Gate>,
    authorization: RefCell<Option<Request>>,
    password_dialog: RefCell<Option<(adw::AlertDialog, gtk::PasswordEntry)>>,
    restoration_dialog: RefCell<Option<(adw::AlertDialog, Vec<gtk::PasswordEntry>)>>,
    restoration_preparation: RefCell<Option<crate::account_worker::restoration_task::Preparation>>,
    vault_sync_authorization: RefCell<Option<crate::account_worker::vault_sync::Authorization>>,
    vault_sync_dialog: RefCell<Option<(adw::AlertDialog, gtk::PasswordEntry)>>,
    restoration_file_choice: RefCell<
        Option<(
            gtk::gio::Cancellable,
            crate::account_worker::restoration_task::Preparation,
        )>,
    >,
    snapshot_dialog: RefCell<Option<adw::AlertDialog>>,
    history_dialog: RefCell<Option<adw::Dialog>>,
    view: Rc<RecoveryView>,
    panel: gtk::Box,
    pages: gtk::Stack,
    server: gtk::Entry,
    account_key_input: gtk::PasswordEntry,
    account_panel: gtk::Box,
    account_id: gtk::Label,
    account_display: RefCell<Option<String>>,
    show_key: gtk::Button,
    key_panel: gtk::Box,
    key_title: gtk::Label,
    key_message: gtk::Label,
    key_label: gtk::Label,
    key_copy: gtk::Button,
    key_done: gtk::Button,
    key_presentation: RefCell<Option<KeyPresentation>>,
    created_next: RefCell<Option<CreatedNext>>,
    sign_out_dialog: RefCell<Option<adw::AlertDialog>>,
    device_view: Rc<PairingView>,
    device_code: gtk::Label,
    device_status: gtk::Label,
    device_copy: gtk::Button,
    device_cancel: gtk::Button,
    device_continue: gtk::Button,
    device_poll: Cell<bool>,
    device_backoff: Cell<u64>,
    libraries: gtk::DropDown,
    create: gtk::Button,
    create_another: gtk::Button,
    creation_state: Cell<Option<creation::State>>,
    creation_status: gtk::Label,
    library_panel: gtk::Box,
    sync: gtk::Button,
    vault_sync: gtk::Button,
    receive: gtk::Button,
    send: gtk::Button,
    review_snapshot: gtk::Button,
    review_deletions: gtk::Button,
    pair: gtk::Button,
    pairing_panel: gtk::Box,
    pairing_view: Rc<PairingView>,
    pairing_code: gtk::Label,
    pairing_status: gtk::Label,
    pairing_copy: gtk::Button,
    pairing_check: gtk::Button,
    pairing_cancel: gtk::Button,
    pairing_poll: Cell<bool>,
    selected_role: Cell<Option<Role>>,
    approval_input: gtk::Entry,
    approval_prepare: gtk::Button,
    replace_recovery: gtk::Button,
    mutation_panel: gtk::Box,
    mutation_status: gtk::Label,
    mutation_code: gtk::Label,
    mutation_matched: gtk::CheckButton,
    mutation_authorize: gtk::Button,
    mutation_resume: gtk::Button,
    mutation_reconcile: gtk::Button,
    mutation_cancel: gtk::Button,
    mutation_target: RefCell<Option<Target>>,
    mutation_state: Cell<Option<(mutations::Kind, mutations::Step)>>,
    recovery_input: gtk::PasswordEntry,
    recovery_panel: gtk::Box,
    suffix: gtk::PasswordEntry,
    recorded: gtk::CheckButton,
    confirm: gtk::Button,
    retry: gtk::Button,
    resume: gtk::Button,
    reconnect: gtk::Button,
    sign_out: gtk::Button,
    status: gtk::Label,
    busy: Cell<bool>,
    loading: Cell<bool>,
    generation: Cell<u64>,
    switch_panel: gtk::Box,
    switch_status: gtk::Label,
    switch_recovery: gtk::PasswordEntry,
    switch_review: gtk::Button,
    switch_resume: gtk::Button,
    switch_cancel: gtk::Button,
    switch_local: gtk::Button,
    history: gtk::Button,
    switch_state: Cell<handover::Status>,
    switch_candidate: Cell<bool>,
    switch_matches: Cell<bool>,
    candidate_pair: gtk::Button,
    candidate_panel: gtk::Box,
    candidate_view: Rc<PairingView>,
    candidate_code: gtk::Label,
    candidate_status: gtk::Label,
    candidate_check: gtk::Button,
    candidate_cancel: gtk::Button,
    candidate_copy: gtk::Button,
    candidate_poll: Cell<bool>,
    bootstrap_create: gtk::Button,
    bootstrap_status: gtk::Label,
    bootstrap_state: Cell<Option<initial_candidate::Status>>,
}
enum SwitchAction {
    Review(Option<Zeroizing<String>>),
    Resume,
    Cancel,
    FinishLocal,
}
impl AccountWindow {
    #[cfg(test)]
    pub(crate) fn fixture(
        application: &adw::Application,
        parent: &adw::ApplicationWindow,
    ) -> Rc<Self> {
        Self::with_worker(application, parent, Handle::fixture(), None).unwrap()
    }
    pub(crate) fn new(
        application: &adw::Application,
        parent: &adw::ApplicationWindow,
        worker: Rc<Handle>,
    ) -> Result<Rc<Self>> {
        Self::with_worker(application, parent, worker, SessionMonitor::new())
    }
    fn with_worker(
        application: &adw::Application,
        parent: &adw::ApplicationWindow,
        worker: impl Into<Rc<Handle>>,
        desktop: Option<SessionMonitor>,
    ) -> Result<Rc<Self>> {
        let worker = worker.into();
        let window = adw::ApplicationWindow::builder()
            .application(application)
            .transient_for(parent)
            .title("Account & Recovery")
            .default_width(560)
            .default_height(700)
            .build();
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 0);
        window.set_content(Some(&layout));
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Account & Recovery",
            "Snippets Cloud",
        )));
        layout.append(&header);
        let panel = gtk::Box::new(gtk::Orientation::Vertical, 16);
        panel.set_margin_start(24);
        panel.set_margin_end(24);
        panel.set_margin_top(24);
        panel.set_margin_bottom(24);
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        layout.append(
            &gtk::ScrolledWindow::builder()
                .child(&content)
                .vexpand(true)
                .hscrollbar_policy(gtk::PolicyType::Never)
                .build(),
        );
        let automatic_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        automatic_panel.set_margin_start(24);
        automatic_panel.set_margin_end(24);
        automatic_panel.set_margin_top(24);
        content.append(&automatic_panel);
        content.append(&panel);
        automatic_panel.append(&label("Connect to your Snippets Cloud server to access library keys. Automatic synchronization is optional and applies only to the library you explicitly enable."));
        let automatic_status = label("Automatic synchronization is off.");
        automatic_panel.append(&automatic_status);
        let automatic_button = gtk::Button::with_label("Enable Automatic Sync for This Library");
        automatic_button.set_sensitive(false);
        automatic_panel.append(&automatic_button);
        automatic_panel.append(&label("While enabled, Snippets checks for changes in the background and reconnects this saved library after restart. Reconnecting, signing out, switching libraries or beginning recovery turns it off. Enable it again after reviewing the library."));
        let status = label("Create an account or sign in with your account key.");
        panel.append(&status);
        let key_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        key_panel.set_visible(false);
        panel.append(&key_panel);
        let key_title = label("Save Your Account Key");
        key_title.add_css_class("title-4");
        key_panel.append(&key_title);
        let key_message = label(CREATED_KEY_MESSAGE);
        key_panel.append(&key_message);
        let key_label = label("");
        key_label.set_selectable(true);
        key_label.add_css_class("monospace");
        key_label.update_property(&[gtk::accessible::Property::Label("Account key")]);
        key_panel.append(&key_label);
        let key_copy = gtk::Button::with_label("Copy");
        key_panel.append(&key_copy);
        let key_done = gtk::Button::with_label("I've Saved It");
        key_done.add_css_class("suggested-action");
        key_panel.append(&key_done);
        let account_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        account_panel.set_visible(false);
        panel.append(&account_panel);
        let account_id = label("");
        account_id.set_selectable(true);
        account_panel.append(&account_id);
        let show_key = gtk::Button::with_label("Show Account Key…");
        account_panel.append(&show_key);
        let history = gtk::Button::with_label("Library Recovery History…");
        panel.append(&history);
        let switch_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        switch_panel.set_visible(false);
        panel.append(&switch_panel);
        let switch_status = label("");
        switch_panel.append(&switch_status);
        let switch_recovery = gtk::PasswordEntry::builder()
            .placeholder_text("Selected library recovery code, if needed")
            .show_peek_icon(false)
            .build();
        switch_recovery.update_property(&[gtk::accessible::Property::Label(
            "Optional recovery code for the selected cloud library",
        )]);
        switch_panel.append(&switch_recovery);
        let switch_review = gtk::Button::with_label("Review Library Switch…");
        let switch_resume = gtk::Button::with_label("Resume Saved Library Switch…");
        let switch_cancel = gtk::Button::with_label("Cancel Saved Library Switch…");
        let switch_local = gtk::Button::with_label("Finish Saved Switch Offline…");
        switch_panel.append(&switch_review);
        switch_panel.append(&switch_resume);
        switch_panel.append(&switch_cancel);
        switch_panel.append(&switch_local);
        let candidate_pair = gtk::Button::with_label("Get Selected Library Key…");
        switch_panel.append(&candidate_pair);
        let candidate_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        candidate_panel.set_visible(false);
        candidate_panel.append(&label("On a device that opens the selected library, choose Add device and scan this QR or paste its public invitation. Compare both confirmation codes before approving. Receiving the key keeps your current library and keys; review the switch separately."));
        let candidate_view = PairingView::new();
        candidate_panel.append(&candidate_view.area);
        let candidate_code = label("");
        candidate_code.set_selectable(true);
        candidate_code.add_css_class("monospace");
        candidate_panel.append(&candidate_code);
        let candidate_status = label("");
        candidate_panel.append(&candidate_status);
        let candidate_copy = gtk::Button::with_label("Copy Public Invitation");
        let candidate_check = gtk::Button::with_label("Check Approval");
        let candidate_cancel = gtk::Button::with_label("Cancel Key Request");
        candidate_panel.append(&candidate_copy);
        candidate_panel.append(&candidate_check);
        candidate_panel.append(&candidate_cancel);
        switch_panel.append(&candidate_panel);
        let bootstrap_create = gtk::Button::with_label("Create First Keys for Empty Library…");
        switch_panel.append(&bootstrap_create);
        let bootstrap_status = label("");
        bootstrap_status.set_visible(false);
        switch_panel.append(&bootstrap_status);
        let pages = gtk::Stack::new();
        panel.append(&pages);
        let login = gtk::Box::new(gtk::Orientation::Vertical, 12);
        let server = gtk::Entry::builder()
            .placeholder_text("HTTPS server address")
            .input_purpose(gtk::InputPurpose::Url)
            .max_length(4096)
            .build();
        server.update_property(&[gtk::accessible::Property::Label(
            "Snippets Cloud HTTPS server",
        )]);
        login.append(&server);
        let create_account = gtk::Button::with_label("Create Account");
        create_account.add_css_class("suggested-action");
        login.append(&create_account);
        let use_key = gtk::Button::with_label("Sign In with Account Key");
        login.append(&use_key);
        let use_device = gtk::Button::with_label("Sign In with Another Device");
        login.append(&use_device);
        pages.add_named(&login, Some("login"));
        let device_page = gtk::Box::new(gtk::Orientation::Vertical, 12);
        device_page.append(&label("On a device that's already signed in to this account and opens its library, choose Add device and scan this code or paste the copied request. Approve only if both devices show the same confirmation code. That device signs this computer in and gives it the library key."));
        let device_view = PairingView::new();
        device_view
            .area
            .update_property(&[gtk::accessible::Property::Label(
                "Public device sign-in request QR",
            )]);
        device_page.append(&device_view.area);
        let device_code = label("");
        device_code.set_selectable(true);
        device_code.add_css_class("monospace");
        device_page.append(&device_code);
        let device_status = label("");
        device_page.append(&device_status);
        let device_copy = gtk::Button::with_label("Copy Sign-In Request");
        device_page.append(&device_copy);
        let device_continue = gtk::Button::with_label("Finish Signing In");
        device_continue.add_css_class("suggested-action");
        device_continue.set_visible(false);
        device_page.append(&device_continue);
        let device_cancel = gtk::Button::with_label("Cancel");
        device_page.append(&device_cancel);
        pages.add_named(&device_page, Some("device"));
        let key_page = gtk::Box::new(gtk::Orientation::Vertical, 12);
        key_page.append(&label(
            "Enter the account key you saved when you created your account.",
        ));
        let account_key_input = gtk::PasswordEntry::builder()
            .placeholder_text("Account key")
            .show_peek_icon(true)
            .build();
        account_key_input.update_property(&[gtk::accessible::Property::Label("Account key")]);
        key_page.append(&account_key_input);
        let sign_in = gtk::Button::with_label("Sign In");
        sign_in.add_css_class("suggested-action");
        key_page.append(&sign_in);
        let back = gtk::Button::with_label("Back");
        key_page.append(&back);
        pages.add_named(&key_page, Some("account-key"));
        // A saved but disconnected account offers Reconnect or Sign Out only.
        pages.add_named(&gtk::Box::new(gtk::Orientation::Vertical, 0), Some("saved"));
        let libraries_page = gtk::Box::new(gtk::Orientation::Vertical, 12);
        libraries_page.append(&label(
            "Select a library or create a new one. Keys remain in your system keyring.",
        ));
        let libraries = gtk::DropDown::from_strings(&[]);
        libraries_page.append(&libraries);
        let create = gtk::Button::with_label("Create New Cloud Library…");
        create.set_sensitive(false);
        libraries_page.append(&create);
        let create_another = gtk::Button::with_label("Create Another Cloud Library…");
        create_another.set_sensitive(false);
        create_another.set_visible(false);
        libraries_page.append(&create_another);
        let creation_status = label("");
        libraries_page.append(&creation_status);
        let library_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        library_panel.set_sensitive(false);
        libraries_page.append(&library_panel);
        let setup = gtk::Button::with_label("Set Up / Resume Library Keys");
        library_panel.append(&setup);
        let sync = gtk::Button::with_label("Sync Now");
        sync.add_css_class("suggested-action");
        sync.set_sensitive(false);
        library_panel.append(&sync);
        let vault_sync = gtk::Button::with_label("Verify Vault and Sync…");
        vault_sync.set_sensitive(false);
        sync.bind_property("sensitive", &vault_sync, "sensitive")
            .sync_create()
            .build();
        library_panel.append(&vault_sync);
        let receive = gtk::Button::with_label("Receive Cloud Changes");
        receive.set_sensitive(false);
        library_panel.append(&receive);
        let send_changes = gtk::Button::with_label("Send Local Changes");
        send_changes.set_sensitive(false);
        library_panel.append(&send_changes);
        let review_snapshot = gtk::Button::with_label("Review Missing Cloud Records…");
        review_snapshot.set_visible(false);
        library_panel.append(&review_snapshot);
        let review_deletions = gtk::Button::with_label("Review Deletions…");
        review_deletions.set_sensitive(false);
        library_panel.append(&review_deletions);
        library_panel.append(&label(
            "Sync Now checks local and cloud changes. Enable automatic synchronization above to keep this library updated while Snippets is running.",
        ));
        let pair = gtk::Button::with_label("Pair This Computer with a Trusted Device");
        library_panel.append(&pair);
        let pairing_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        pairing_panel.set_visible(false);
        library_panel.append(&pairing_panel);
        pairing_panel.append(&label("On a device that already opens this Snippets Cloud library, choose Add device and scan this QR, or paste the copied invitation. Approve only if both devices show the same confirmation code."));
        let pairing_view = PairingView::new();
        pairing_panel.append(&pairing_view.area);
        let pairing_code = label("");
        pairing_code.set_selectable(true);
        pairing_code.add_css_class("monospace");
        pairing_panel.append(&pairing_code);
        let pairing_status = label("");
        pairing_panel.append(&pairing_status);
        let pairing_copy = gtk::Button::with_label("Copy Public Invitation");
        pairing_panel.append(&pairing_copy);
        let pairing_check = gtk::Button::with_label("Check Approval");
        pairing_panel.append(&pairing_check);
        let pairing_cancel = gtk::Button::with_label("Cancel Invitation");
        pairing_panel.append(&pairing_cancel);
        library_panel.append(&label("For an existing library, enter its recovery code or QR payload from your offline copy."));
        let recovery_input = gtk::PasswordEntry::builder()
            .placeholder_text("Recovery code or QR payload")
            .show_peek_icon(false)
            .build();
        library_panel.append(&recovery_input);
        let recover = gtk::Button::with_label("Recover Library Key");
        library_panel.append(&recover);
        let reveal = gtk::Button::with_label("Show Pending Recovery Code…");
        library_panel.append(&reveal);
        library_panel.append(&label("To add another computer or phone to this library, paste its public pairing invitation and compare the confirmation code on both devices."));
        let approval_input = gtk::Entry::builder()
            .placeholder_text("Public invitation from the new device")
            .max_length(4096)
            .build();
        approval_input.update_property(&[gtk::accessible::Property::Label(
            "Public pairing invitation to approve",
        )]);
        library_panel.append(&approval_input);
        let approval_prepare = gtk::Button::with_label("Review Device Invitation");
        library_panel.append(&approval_prepare);
        let replace_recovery = gtk::Button::with_label("Replace Recovery Code…");
        library_panel.append(&replace_recovery);
        let mutation_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        mutation_panel.set_visible(false);
        library_panel.append(&mutation_panel);
        let mutation_status = label("");
        mutation_panel.append(&mutation_status);
        let mutation_code = label("");
        mutation_code.set_selectable(true);
        mutation_code.add_css_class("monospace");
        mutation_panel.append(&mutation_code);
        let mutation_matched =
            gtk::CheckButton::with_label("Both devices show the same confirmation code");
        mutation_panel.append(&mutation_matched);
        let mutation_authorize = gtk::Button::with_label("Authorize…");
        mutation_authorize.set_sensitive(false);
        mutation_panel.append(&mutation_authorize);
        let mutation_resume = gtk::Button::with_label("Review and Authorize Retained Operation");
        mutation_panel.append(&mutation_resume);
        let mutation_reconcile = gtk::Button::with_label("Check Saved Result");
        mutation_panel.append(&mutation_reconcile);
        let mutation_cancel = gtk::Button::with_label("Cancel Unsent Operation");
        mutation_panel.append(&mutation_cancel);
        pages.add_named(&libraries_page, Some("libraries"));
        let recovery_panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
        recovery_panel.set_visible(false);
        panel.append(&recovery_panel);
        recovery_panel.append(&label("Keep this code or QR offline. Anyone holding it can recover this library. It hides when this window loses focus, the desktop locks, or authorization expires."));
        let view = RecoveryView::new();
        recovery_panel.append(&view.area);
        let recorded = gtk::CheckButton::with_label("I saved an offline copy");
        recovery_panel.append(&recorded);
        let suffix = gtk::PasswordEntry::builder()
            .placeholder_text("Last eight characters of the saved code")
            .show_peek_icon(false)
            .build();
        recovery_panel.append(&suffix);
        let confirm = gtk::Button::with_label("Confirm Saved Code");
        confirm.set_sensitive(false);
        recovery_panel.append(&confirm);
        let hide = gtk::Button::with_label("Hide Code");
        recovery_panel.append(&hide);
        let reconnect = gtk::Button::with_label("Reconnect Saved Account");
        reconnect.set_visible(false);
        panel.append(&reconnect);
        let sign_out = gtk::Button::with_label("Sign Out");
        sign_out.set_visible(false);
        panel.append(&sign_out);
        let resume = gtk::Button::with_label("Resume Interrupted Account Operation");
        resume.set_visible(false);
        panel.append(&resume);
        let retry = gtk::Button::with_label("Retry Secure Storage");
        retry.set_visible(false);
        panel.append(&retry);
        let this = Rc::new(Self {
            window,
            worker,
            automatic_button,
            automatic_status,
            automatic_pending: Cell::new(false),
            desktop,
            gate: RefCell::new(Gate::new()),
            authorization: RefCell::new(None),
            password_dialog: RefCell::new(None),
            restoration_dialog: RefCell::new(None),
            restoration_preparation: RefCell::new(None),
            vault_sync_authorization: RefCell::new(None),
            vault_sync_dialog: RefCell::new(None),
            restoration_file_choice: RefCell::new(None),
            snapshot_dialog: RefCell::new(None),
            history_dialog: RefCell::new(None),
            view,
            panel,
            pages,
            server,
            account_key_input,
            account_panel,
            account_id,
            account_display: RefCell::new(None),
            show_key,
            key_panel,
            key_title,
            key_message,
            key_label,
            key_copy,
            key_done,
            key_presentation: RefCell::new(None),
            created_next: RefCell::new(None),
            sign_out_dialog: RefCell::new(None),
            device_view,
            device_code,
            device_status,
            device_copy,
            device_cancel,
            device_continue,
            device_poll: Cell::new(false),
            device_backoff: Cell::new(0),
            libraries,
            create,
            create_another,
            creation_state: Cell::new(None),
            creation_status,
            library_panel,
            sync,
            vault_sync,
            receive,
            send: send_changes,
            review_snapshot,
            review_deletions,
            pair,
            pairing_panel,
            pairing_view,
            pairing_code,
            pairing_status,
            pairing_copy,
            pairing_check,
            pairing_cancel,
            pairing_poll: Cell::new(false),
            selected_role: Cell::new(None),
            approval_input,
            approval_prepare,
            replace_recovery,
            mutation_panel,
            mutation_status,
            mutation_code,
            mutation_matched,
            mutation_authorize,
            mutation_resume,
            mutation_reconcile,
            mutation_cancel,
            mutation_target: RefCell::new(None),
            mutation_state: Cell::new(None),
            recovery_input,
            recovery_panel,
            suffix,
            recorded,
            confirm,
            retry,
            resume,
            reconnect,
            sign_out,
            status,
            busy: Cell::new(false),
            loading: Cell::new(false),
            generation: Cell::new(0),
            switch_panel,
            switch_status,
            switch_recovery,
            switch_review,
            switch_resume,
            switch_cancel,
            switch_local,
            history,
            switch_state: Cell::new(handover::Status::default()),
            switch_candidate: Cell::new(false),
            switch_matches: Cell::new(false),
            candidate_pair,
            candidate_panel,
            candidate_view,
            candidate_code,
            candidate_status,
            candidate_check,
            candidate_cancel,
            candidate_copy,
            candidate_poll: Cell::new(false),
            bootstrap_create,
            bootstrap_status,
            bootstrap_state: Cell::new(None),
        });
        let weak = Rc::downgrade(&this);
        this.automatic_button.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.toggle_automatic();
            }
        });
        let weak = Rc::downgrade(&this);
        create_account.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                let command = Command::CreateAccount {
                    server: Zeroizing::new(this.server.text().to_string()),
                };
                this.library_panel.set_sensitive(false);
                this.run(command);
            }
        });
        let weak = Rc::downgrade(&this);
        use_key.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.cancel_sensitive();
                this.pages.set_visible_child_name("account-key");
                this.status
                    .set_label("Enter your account key to sign in on this computer.");
                this.account_key_input.grab_focus();
            }
        });
        let weak = Rc::downgrade(&this);
        use_device.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                let command = Command::BeginDeviceSignIn {
                    server: Zeroizing::new(this.server.text().to_string()),
                };
                this.run(command);
            }
        });
        let weak = Rc::downgrade(&this);
        this.device_cancel.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.clear_device();
                this.run(Command::CancelDeviceSignIn);
            }
        });
        let weak = Rc::downgrade(&this);
        this.device_continue.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.device_continue.set_visible(false);
                this.run(Command::CheckDeviceSignIn);
            }
        });
        let weak = Rc::downgrade(&this);
        this.device_copy.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade()
                && let Err(e) = this.device_view.copy()
            {
                this.failure(e);
            }
        });
        let weak = Rc::downgrade(&this);
        sign_in.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.sign_in();
            }
        });
        let weak = Rc::downgrade(&this);
        this.account_key_input.connect_activate(move |_| {
            if let Some(this) = weak.upgrade() {
                this.sign_in();
            }
        });
        let weak = Rc::downgrade(&this);
        back.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.cancel_sensitive();
                this.pages.set_visible_child_name("login");
                this.status
                    .set_label("Create an account or sign in with your account key.");
            }
        });
        let weak = Rc::downgrade(&this);
        this.show_key.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.show_account_key();
            }
        });
        let weak = Rc::downgrade(&this);
        this.key_copy.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.copy_key();
            }
        });
        let weak = Rc::downgrade(&this);
        this.key_done.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.end_key_presentation(true);
            }
        });
        let weak = Rc::downgrade(&this);
        this.sign_out.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.confirm_sign_out();
            }
        });
        for (button, make) in [
            (&this.reconnect, (|| Command::Refresh) as fn() -> Command),
            (&this.resume, || Command::Resume),
            (&this.retry, || Command::Retain),
            (&setup, || Command::Setup),
            (&this.sync, || Command::Sync),
            (&this.receive, || Command::Receive),
            (&this.send, || Command::Send),
            (&this.pair, || Command::BeginPairing),
            (&this.pairing_check, || Command::CheckPairing),
            (&this.pairing_cancel, || Command::CancelPairing),
            (&this.candidate_pair, || {
                Command::CandidatePairing(candidate::Action::Begin)
            }),
            (&this.candidate_check, || {
                Command::CandidatePairing(candidate::Action::Check)
            }),
            (&this.candidate_cancel, || {
                Command::CandidatePairing(candidate::Action::Cancel)
            }),
            (&this.replace_recovery, || Command::PrepareRecoveryMutation),
            (&this.mutation_resume, || Command::PrepareMutationResume),
            (&this.mutation_reconcile, || Command::ReconcileMutation),
            (&this.mutation_cancel, || Command::CancelMutation),
        ] {
            let weak = Rc::downgrade(&this);
            button.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.run(make());
                }
            });
        }
        let weak = Rc::downgrade(&this);
        this.pairing_copy.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade()
                && let Err(e) = this.pairing_view.copy()
            {
                this.failure(e);
            }
        });
        let weak = Rc::downgrade(&this);
        this.candidate_copy.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade()
                && let Err(e) = this.candidate_view.copy()
            {
                this.failure(e);
            }
        });
        let weak = Rc::downgrade(&this);
        this.bootstrap_create.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.create_target_keys();
            }
        });
        let weak = Rc::downgrade(&this);
        this.approval_prepare.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                let payload = Zeroizing::new(this.approval_input.text().to_string());
                this.approval_input.set_text("");
                this.review_added_device(payload);
            }
        });
        let weak = Rc::downgrade(&this);
        this.mutation_matched.connect_toggled(move |_| {
            if let Some(this) = weak.upgrade() {
                this.update_mutation_authorize();
            }
        });
        let weak = Rc::downgrade(&this);
        this.mutation_authorize.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.authorize_mutation();
            }
        });
        let weak = Rc::downgrade(&this);
        recover.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                match secret(&this.recovery_input) {
                    Ok(code) => this.run(Command::Recover(code)),
                    Err(e) => this.failure(e),
                }
            }
        });
        let weak = Rc::downgrade(&this);
        this.create.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.create_library();
            }
        });
        let weak = Rc::downgrade(&this);
        this.create_another.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.create_another_library();
            }
        });
        let weak = Rc::downgrade(&this);
        this.review_snapshot.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.review_missing_snapshot();
            }
        });
        let weak = Rc::downgrade(&this);
        this.review_deletions.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.review_saved_deletion();
            }
        });
        let weak = Rc::downgrade(&this);
        this.vault_sync.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.verify_vault_sync();
            }
        });
        let weak = Rc::downgrade(&this);
        this.switch_review.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                match secret(&this.switch_recovery) {
                    Ok(code) => {
                        this.switch_library(SwitchAction::Review(if code.trim().is_empty() {
                            None
                        } else {
                            Some(code)
                        }))
                    }
                    Err(e) => this.failure(e),
                }
            }
        });
        let weak = Rc::downgrade(&this);
        this.switch_resume.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.switch_library(SwitchAction::Resume);
            }
        });
        let weak = Rc::downgrade(&this);
        this.switch_cancel.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.switch_library(SwitchAction::Cancel);
            }
        });
        let weak = Rc::downgrade(&this);
        this.switch_local.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.switch_library(SwitchAction::FinishLocal);
            }
        });
        let weak = Rc::downgrade(&this);
        this.history.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.show_history();
            }
        });
        let weak = Rc::downgrade(&this);
        this.libraries.connect_selected_notify(move |dropdown| {
            if let Some(this) = weak.upgrade()
                && !this.loading.get()
                && !this.busy.get()
            {
                this.library_panel.set_sensitive(false);
                let selected = dropdown.selected();
                if selected == 0 || selected == gtk::INVALID_LIST_POSITION {
                    this.cancel_sensitive();
                    this.clear_pairing();
                    this.clear_candidate_pairing();
                    this.set_mutation(Ok(None));
                    this.selected_role.set(None);
                    this.sync.set_sensitive(false);
                    this.send.set_sensitive(false);
                    this.receive.set_sensitive(false);
                    this.review_snapshot.set_visible(false);
                    this.review_deletions.set_sensitive(false);
                    this.update_automatic();
                } else {
                    this.run(Command::Select((selected - 1) as usize));
                }
            }
        });
        let weak = Rc::downgrade(&this);
        reveal.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.reveal();
            }
        });
        let weak = Rc::downgrade(&this);
        hide.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.cancel_sensitive();
            }
        });
        let weak = Rc::downgrade(&this);
        this.recorded.connect_toggled(move |check| {
            if let Some(this) = weak.upgrade() {
                this.confirm
                    .set_sensitive(check.is_active() && this.view.visible());
            }
        });
        let weak = Rc::downgrade(&this);
        this.confirm.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.confirm_saved();
            }
        });
        let weak = Rc::downgrade(&this);
        this.window.connect_is_active_notify(move |window| {
            if let Some(this) = weak.upgrade() {
                this.gate.borrow_mut().set_foreground(window.is_active());
                // The native file chooser can own focus only after all passwords,
                // preparation keys and write authorization have been relinquished.
                if !window.is_active() && this.restoration_file_choice.borrow().is_none() {
                    this.cancel_sensitive();
                }
            }
        });
        let weak = Rc::downgrade(&this);
        this.window.connect_close_request(move |window| {
            if let Some(this) = weak.upgrade() {
                this.cancel_sensitive();
                // Hiding ends even the creation presentation; the saved key stays
                // available through Show Account Key.
                this.end_key_presentation(false);
            }
            window.set_visible(false);
            glib::Propagation::Stop
        });
        let weak = Rc::downgrade(&this);
        glib::timeout_add_local(Duration::from_millis(100), move || {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            this.update_automatic();
            if this
                .restoration_file_choice
                .borrow()
                .as_ref()
                .is_some_and(|(_, guard)| guard.validate().is_err())
            {
                this.cancel_sensitive();
                this.status
                    .set_label("File selection ended. Review the saved changes again.");
            }
            // A created key stays visible on focus loss so it can be stored in a
            // password manager; an observed desktop lock still ends it.
            if this.created_key_visible()
                && this
                    .desktop
                    .as_ref()
                    .is_some_and(|m| m.snapshot().0 != SessionState::Unlocked)
            {
                this.end_key_presentation(false);
            }
            if this
                .key_presentation
                .borrow()
                .as_ref()
                .is_some_and(|p| matches!(p, KeyPresentation::Disclosed(d) if !d.valid()))
            {
                this.end_key_presentation(false);
            }
            let active_secret = this.view.visible()
                || this.disclosed_key_visible()
                || this.authorization.borrow().is_some()
                || this.password_dialog.borrow().is_some()
                || this.restoration_preparation.borrow().is_some()
                || this.vault_sync_authorization.borrow().is_some();
            let expired = this.view.expired()
                || this
                    .authorization
                    .borrow()
                    .as_ref()
                    .is_some_and(|r| r.check().is_err())
                || this
                    .restoration_preparation
                    .borrow()
                    .as_ref()
                    .is_some_and(|r| r.validate().is_err())
                || this
                    .vault_sync_authorization
                    .borrow()
                    .as_ref()
                    .is_some_and(|r| r.validate().is_err());
            if this.snapshot_dialog.borrow().is_some()
                && (!this.window.is_active()
                    || this
                        .desktop
                        .as_ref()
                        .is_none_or(|m| m.snapshot().0 != SessionState::Unlocked))
            {
                this.cancel_sensitive();
                this.status
                    .set_label("Review cancelled. Review again when the desktop is unlocked.");
            }
            // Read-only history carries no permit or secret presentation. It
            // closes on focus loss or an observed lock; it does not require a
            // session monitor to grant local metadata inspection.
            if this.history_dialog.borrow().is_some()
                && (!this.window.is_active()
                    || this
                        .desktop
                        .as_ref()
                        .is_some_and(|m| m.snapshot().0 != SessionState::Unlocked))
            {
                this.cancel_sensitive();
            }
            if active_secret
                && (expired
                    || !this.window.is_active()
                    || this
                        .desktop
                        .as_ref()
                        .is_none_or(|m| m.snapshot().0 != SessionState::Unlocked))
            {
                this.cancel_sensitive();
                this.status.set_label(
                    "Review or authorization ended. Start again when the desktop is unlocked.",
                );
            }
            if this.pairing_view.value.borrow().is_some() {
                let remaining = this.pairing_view.remaining();
                if remaining.is_zero() {
                    this.pairing_status.set_label(
                        "Invitation expired. Cancel it before creating a new invitation.",
                    );
                } else {
                    this.pairing_status.set_label(&format!(
                        "Waiting for approval · {} seconds left",
                        remaining.as_secs()
                    ));
                }
                this.pairing_copy.set_sensitive(!remaining.is_zero());
                if remaining.is_zero() {
                    this.pairing_view.area.queue_draw();
                    this.pairing_poll.set(false);
                }
            }
            if this.pairing_poll.get()
                && !this.busy.get()
                && !this.worker.retention_required()
                && this.window.is_visible()
                && this.window.is_active()
                && this
                    .desktop
                    .as_ref()
                    .is_some_and(|d| d.snapshot().0 == SessionState::Unlocked)
                && this.pairing_view.poll_due()
            {
                this.run(Command::CheckPairing);
            }
            if this.candidate_view.value.borrow().is_some() {
                let remaining = this.candidate_view.remaining();
                this.candidate_copy.set_sensitive(!remaining.is_zero());
                this.candidate_status.set_label(if remaining.is_zero() {
                    "Invitation expired. Cancel this request before creating another."
                } else {
                    "Waiting for approval from the selected library's trusted device."
                });
                if remaining.is_zero() {
                    this.candidate_view.area.queue_draw();
                    this.candidate_poll.set(false);
                }
            }
            if this.device_view.value.borrow().is_some() {
                let remaining = this.device_view.remaining();
                this.device_copy.set_sensitive(!remaining.is_zero());
                if remaining.is_zero() {
                    this.device_status.set_label(
                        "This request expired. Cancel it, then sign in with another device again.",
                    );
                    this.device_view.area.queue_draw();
                    this.device_poll.set(false);
                } else if this.device_poll.get() {
                    this.device_status.set_label(&format!(
                        "Waiting for approval · {} seconds left",
                        remaining.as_secs()
                    ));
                }
            }
            if this.device_poll.get()
                && !this.busy.get()
                && !this.worker.retention_required()
                && this.window.is_visible()
                && this
                    .desktop
                    .as_ref()
                    .is_some_and(|d| d.snapshot().0 == SessionState::Unlocked)
                && this.device_view.poll_due()
            {
                this.run(Command::CheckDeviceSignIn);
            }
            if this.candidate_poll.get()
                && !this.busy.get()
                && !this.worker.retention_required()
                && this.window.is_visible()
                && this.window.is_active()
                && this
                    .desktop
                    .as_ref()
                    .is_some_and(|d| d.snapshot().0 == SessionState::Unlocked)
                && this.candidate_view.poll_due()
            {
                this.run(Command::CandidatePairing(candidate::Action::Check));
            }
            glib::ControlFlow::Continue
        });
        Ok(this)
    }
    pub(crate) fn present(self: &Rc<Self>) {
        self.window.present();
        // Re-presenting must not replace a new account's unsaved key screen.
        if !self.busy.get() && !self.created_key_visible() {
            self.run(Command::Inspect);
        }
    }
    pub(crate) fn prepare_quit(self: &Rc<Self>) -> bool {
        self.cancel_sensitive();
        self.end_key_presentation(false);
        if self.worker.prepare_quit() {
            return true;
        }
        self.window.present();
        if self.worker.retention_required() {
            self.failure(Failure::RetentionRequired);
        } else {
            self.status
                .set_label("Wait for the account operation to finish before quitting.");
        }
        false
    }
    fn update_automatic(&self) {
        let state = self.worker.automatic();
        self.automatic_button.set_label(if state.enabled {
            "Turn Off Automatic Sync"
        } else {
            "Enable Automatic Sync for This Library"
        });
        self.automatic_button.set_sensitive(
            !self.automatic_pending.get()
                && (state.enabled || (!self.busy.get() && self.sync.is_sensitive())),
        );
        let text = match state.status {
            AutomaticStatus::Off => "Automatic synchronization is off.",
            AutomaticStatus::Scheduled => {
                "Automatic synchronization is enabled for the saved library."
            }
            AutomaticStatus::Current => "Automatic synchronization: up to date.",
            AutomaticStatus::ReceivedCurrent => {
                "Automatic receiving: up to date. This library is read-only; local edits are not uploaded."
            }
            AutomaticStatus::MoreWork => {
                "Automatic synchronization is continuing with the remaining changes."
            }
            AutomaticStatus::Retry => "Automatic synchronization is waiting before trying again.",
            AutomaticStatus::Attention => {
                "Automatic synchronization stopped. Review the account or library below, then enable it again."
            }
        };
        self.automatic_status.set_label(&state.failure.map_or_else(
            || text.to_owned(),
            |failure| format!("{text} {}", failure.message()),
        ));
        self.retry.set_visible(self.worker.retention_required());
    }
    fn toggle_automatic(self: &Rc<Self>) {
        if self.automatic_pending.replace(true) {
            return;
        }
        let enable = !self.worker.automatic().enabled;
        if enable && (self.busy.get() || !self.sync.is_sensitive()) {
            self.automatic_pending.set(false);
            return;
        }
        self.automatic_button.set_sensitive(false);
        // Disable bypasses the window's busy flag. request immediately revokes
        // the active ticket, then queues the durable preference write.
        let receiver = match self.worker.request(Command::Automatic(enable)) {
            Ok(receiver) => receiver,
            Err(failure) => {
                self.automatic_pending.set(false);
                self.failure(failure);
                return;
            }
        };
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = loop {
                match receiver.try_recv() {
                    Ok(result) => break result,
                    Err(mpsc::TryRecvError::Disconnected) => break Err(Failure::WorkerStopped),
                    Err(mpsc::TryRecvError::Empty) => {
                        glib::timeout_future(Duration::from_millis(30)).await
                    }
                }
            };
            this.automatic_pending.set(false);
            if let Err(failure) = result {
                this.failure(failure);
            }
            this.update_automatic();
        });
    }
    pub(crate) fn cancel_sensitive(&self) {
        self.cancel_vault_sync();
        self.gate.borrow_mut().cancel();
        self.generation.set(self.generation.get().wrapping_add(1));
        self.authorization.borrow_mut().take();
        if let Some((cancellation, guard)) = self.restoration_file_choice.borrow_mut().take() {
            guard.cancel();
            cancellation.cancel();
        }
        if let Some(preparation) = self.restoration_preparation.borrow_mut().take() {
            preparation.cancel();
        }
        let restoration_dialog = self.restoration_dialog.borrow_mut().take();
        if let Some((dialog, entries)) = restoration_dialog {
            for entry in entries {
                entry.set_text("");
            }
            dialog.force_close();
        }
        let dialog = self.password_dialog.borrow_mut().take();
        if let Some((dialog, password)) = dialog {
            password.set_text("");
            dialog.force_close();
        }
        let sign_out_dialog = self.sign_out_dialog.borrow_mut().take();
        if let Some(dialog) = sign_out_dialog {
            dialog.force_close();
        }
        if self.disclosed_key_visible() {
            self.end_key_presentation(false);
        }
        let snapshot_dialog = self.snapshot_dialog.borrow_mut().take();
        if let Some(dialog) = snapshot_dialog {
            dialog.force_close();
        }
        let history_dialog = self.history_dialog.borrow_mut().take();
        if let Some(dialog) = history_dialog {
            dialog.force_close();
        }
        self.view.clear();
        self.recovery_panel.set_visible(false);
        self.suffix.set_text("");
        self.recorded.set_active(false);
        self.confirm.set_sensitive(false);
        self.account_key_input.set_text("");
        self.recovery_input.set_text("");
        self.switch_recovery.set_text("");
        self.mutation_target.borrow_mut().take();
        self.mutation_matched.set_active(false);
        self.mutation_authorize.set_sensitive(false);
        self.approval_input.set_text("");
    }
    fn busy(&self, value: bool) {
        if value {
            // Deliver focus-out while the entry and its controllers are still
            // sensitive. Disabling the panel first can leave GtkText's cursor
            // tick alive after its focus controller stops receiving events.
            gtk::prelude::GtkWindowExt::set_focus(&self.window, None::<&gtk::Widget>);
        }
        self.busy.set(value);
        self.panel.set_sensitive(!value);
    }
    fn failure(&self, failure: Failure) {
        self.pairing_poll.set(false);
        self.candidate_poll.set(false);
        self.stop_device_polling();
        self.status.set_label(failure.message());
        self.retry.set_visible(self.worker.retention_required());
    }
    async fn execute(&self, command: Command) -> Result<Reply> {
        let receiver = self.worker.request(command)?;
        loop {
            match receiver.try_recv() {
                Ok(result) => return result,
                Err(mpsc::TryRecvError::Disconnected) => return Err(Failure::WorkerStopped),
                Err(mpsc::TryRecvError::Empty) => {
                    glib::timeout_future(Duration::from_millis(30)).await
                }
            }
        }
    }
    fn run(self: &Rc<Self>, command: Command) {
        if self.busy.get() {
            return;
        }
        if matches!(
            &command,
            Command::Inspect
                | Command::Select(_)
                | Command::Refresh
                | Command::SignOut
                | Command::CreateAccount { .. }
                | Command::SignIn { .. }
                | Command::BeginDeviceSignIn { .. }
                | Command::CancelDeviceSignIn
                | Command::CreateLibrary
                | Command::CreateNewLibrary(_)
        ) {
            self.create_another.set_sensitive(false);
            self.clear_pairing();
            self.set_mutation(Ok(None));
            self.selected_role.set(None);
            self.sync.set_sensitive(false);
            self.receive.set_sensitive(false);
            self.send.set_sensitive(false);
            self.review_snapshot.set_visible(false);
            self.review_deletions.set_sensitive(false);
            self.update_mutation_actions();
            self.switch_candidate.set(false);
            self.switch_matches.set(false);
            self.switch_review.set_sensitive(false);
            self.switch_resume.set_sensitive(false);
            self.clear_candidate_pairing();
            self.candidate_pair.set_sensitive(false);
            self.bootstrap_state.set(None);
            self.bootstrap_create.set_sensitive(false);
            self.bootstrap_status.set_visible(false);
        }
        self.cancel_sensitive();
        self.busy(true);
        self.status.set_label("Working…");
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = this.execute(command).await;
            this.busy(false);
            match result {
                Ok(reply) => this.apply(reply),
                Err(e) => this.failure(e),
            }
        });
    }
    fn apply(&self, reply: Reply) {
        self.retry.set_visible(self.worker.retention_required());
        match reply {
            Reply::Automatic(state) => {
                self.automatic_status.set_label(if state.enabled { "Automatic synchronization enabled." }
                    else { "Automatic synchronization is off." });
                self.update_automatic();
            },
            Reply::History(_) => self.status.set_label("Open Library Recovery History to inspect saved recovery states."),
            Reply::Profile { account,server,interrupted,switching,device } => {
                self.create_another.set_sensitive(false);
                let saved = account.is_some();
                self.pages.set_visible_child_name(if saved { "saved" } else { "login" });
                if device.is_none() { self.clear_device(); }
                if let Some(server)=server { self.server.set_text(server.for_secure_storage()); }
                self.set_account(account);
                self.reconnect.set_visible(saved); self.sign_out.set_visible(saved); self.resume.set_visible(interrupted);
                self.status.set_label(if interrupted {"Resume the retained account operation before signing in."} else if saved {"Account saved. Reconnect to choose a library."} else {"Enter your HTTPS server, then create an account or sign in with your account key."});
                self.set_switching(switching, false, false);
                if let Some(device)=device { self.set_device(Some(device), None, None); }
            }
            Reply::AccountCreated { key,next,failure } => self.show_created_key(key, next, failure),
            Reply::DeviceSignIn { state,retry_after,failure } => self.set_device(state, retry_after, failure),
            Reply::DeviceSignedIn { libraries,library,selected,keys,failure } => {
                self.clear_device();
                // The worker already selected the approved library; show it after
                // the "Select a library…" placeholder row without re-selecting.
                let row = match (&*libraries, library) {
                    (Reply::Libraries { spaces, .. }, Some(id)) => spaces.iter().position(|space| space.id() == id),
                    _ => None,
                };
                self.apply(*libraries);
                if let Some(row)=row { self.loading.set(true); self.libraries.set_selected(row as u32 + 1); self.loading.set(false); }
                if let Some(selected)=selected { self.apply(*selected); }
                let ready = matches!(keys, Some(Ok(Outcome::Ready { .. })));
                if let Some(keys)=keys { self.apply_library(keys); }
                if let Some(failure)=failure { self.failure(failure); }
                else if ready { self.status.set_label("Signed in with another device. This computer received the library key; choose Sync Now to continue."); }
            }
            Reply::Libraries { account,server,spaces,creation,can_create_new,created,switching }=>{
                self.creation_status.set_label(&format!("Account ID {} · {}",account,server.for_secure_storage()));
                self.server.set_text(server.for_secure_storage());
                self.set_creation(creation);
                self.set_new_creation(can_create_new);
                self.set_account(Some(account)); self.reconnect.set_visible(true); self.sign_out.set_visible(true); self.resume.set_visible(false);
                // GtkDropDown's single selection cannot be cleared on a nonempty
                // model. Keep a real first row so the first/only library still
                // requires an explicit change and its notify signal can fire.
                let names=std::iter::once("Select a library…".to_string()).chain(spaces.iter().map(|space|format!("{} · {}",space.id(),match space.role {Role::Owner=>"Owner",Role::Writer=>"Writer",Role::Reader=>"Reader"}))).collect::<Vec<_>>();
                let names=names.iter().map(String::as_str).collect::<Vec<_>>();
                self.loading.set(true); self.libraries.set_model(Some(&gtk::StringList::new(&names))); self.libraries.set_selected(0); self.loading.set(false);
                self.library_panel.set_sensitive(false); self.pages.set_visible_child_name("libraries");
                self.status.set_label(if spaces.is_empty() {"Account connected. Create a cloud library to begin."} else {"Account connected. Select a library to inspect its keys."});
                match creation {
                    Err(e)=>self.status.set_label(Failure::from(e).message()),
                    Ok(creation::State::Requested)=>self.status.set_label("Library creation was interrupted. Resume it to retrieve the same library."),
                    Ok(creation::State::ExistingLibrary)=>self.status.set_label("This installation has saved library state. Select its library or review the account."),
                    _=>(),
                }
                if let Some(id)=created {
                    if let Some(index)=spaces.iter().position(|space|space.id()==id) {self.libraries.set_selected(index as u32 + 1);}
                    else {self.status.set_label("The created library is unavailable. Reconnect to review this account.");}
                }
                self.set_switching(switching, false, false);
            }
            Reply::Library {outcome,can_create_new}=>{
                self.apply_library(outcome);
                self.set_new_creation(can_create_new);
            },
            Reply::Synchronized(progress)=>{
                use crate::sync::Status;
                self.review_snapshot.set_visible(matches!(progress.status,
                    Status::Receiving(crate::receiver::Status::SnapshotReview)|Status::Sending(crate::sender::Status::SnapshotReview)));
                let message=match progress.status {
                    Status::Current=>"Synchronization complete. Cloud changes received and local changes confirmed.",
                    Status::MoreWork(_)=>"Some synchronization work remains. Choose Sync Now again to continue.",
                    Status::Receiving(status)=>match status {
                        crate::receiver::Status::LocalReview=>"A missing local snippet needs review before synchronization can continue.",
                        crate::receiver::Status::DeletionReview=>"A cloud deletion needs review. Your local snippet and the incoming page are preserved.",
                        crate::receiver::Status::SnapshotReview=>"The complete cloud snapshot is missing known records. Review Missing Cloud Records to continue.",
                        crate::receiver::Status::ConflictReview=>"A conflict copy needs review. Local edits and the saved page are preserved.",
                        crate::receiver::Status::VaultLocked=>"An encrypted record or conflict needs your vault before synchronization can continue.",
                        crate::receiver::Status::IncompatibleVault=>"An incoming encrypted record belongs to a different vault. Review is required.",
                        crate::receiver::Status::PrimaryChanged=>"A local edit raced with synchronization. Choose Sync Now again to retry the saved page.",
                        crate::receiver::Status::Current|crate::receiver::Status::MorePages|crate::receiver::Status::SendFirst=>"Choose Sync Now to continue receiving the saved cloud changes.",
                    },
                    Status::Sending(status)=>match status {
                        crate::sender::Status::LocalReview=>"A missing local snippet needs review before synchronization can continue.",
                        crate::sender::Status::DeletionReview=>"A saved deletion needs review. Your local intent is preserved.",
                        crate::sender::Status::SnapshotReview=>"The cloud snapshot needs review before synchronization can continue.",
                        crate::sender::Status::PreservationRequired=>"A conflict needs preservation before its source or later edits can synchronize.",
                        crate::sender::Status::ConflictReview=>"A conflict copy or retained request needs review. Local data and the server response are preserved.",
                        crate::sender::Status::VaultLocked=>"An encrypted conflict needs your vault before synchronization can continue.",
                        crate::sender::Status::IncompatibleVault=>"A cloud record belongs to a different vault. Review is required.",
                        crate::sender::Status::PrimaryChanged=>"A local edit raced with synchronization. Choose Sync Now again to retry the saved response.",
                        crate::sender::Status::ReadOnly=>"This cloud library is read-only. Local edits are kept and have not been uploaded.",
                        crate::sender::Status::ServerDeferred {..}=>"The cloud postponed some local changes. Received and confirmed changes are saved; try Sync Now later.",
                        crate::sender::Status::Settled|crate::sender::Status::MoreBatches|crate::sender::Status::ReceiveFirst=>"Choose Sync Now to continue synchronizing the saved changes.",
                    },
                };
                self.status.set_label(message);
            },
            Reply::VaultSync {..} => self.status.set_label("Verify the current vault to continue synchronization."),
            Reply::Received(progress)=>{
                use crate::receiver::Status;
                self.review_snapshot.set_visible(progress.status == Status::SnapshotReview);
                self.status.set_label(match progress.status {
                    Status::Current=>"Cloud changes received. Local changes have not been sent.",
                    Status::MorePages=>"Received part of the cloud library. Choose Receive Cloud Changes again to continue.",
                    Status::LocalReview=>"A local deletion needs review. The incoming page is saved; it has not restored the deleted snippet.",
                    Status::ConflictReview=>"An edited conflict copy needs review. The saved page and local edits are preserved.",
                    Status::VaultLocked=>"An encrypted record or conflict needs your vault before this saved page can continue.",
                    Status::IncompatibleVault=>"An incoming encrypted record belongs to a different vault. Review is required.",
                    Status::SnapshotReview=>"The complete cloud snapshot is missing previously confirmed records. Receiving is halted for review; local records are preserved.",
                    Status::DeletionReview=>"A cloud deletion needs review. The saved page is retained and your local snippet is preserved.",
                    Status::PrimaryChanged=>"A local edit raced with receiving. Choose Receive Cloud Changes again to retry the saved page.",
                    Status::SendFirst=>"A retained send needs to finish before receiving another page. Choose Send Local Changes to resume it.",
                });
            },
            Reply::Sent(progress)=>{
                use crate::sender::Status;
                self.review_snapshot.set_visible(progress.status == Status::SnapshotReview);
                self.status.set_label(match progress.status {
                    Status::Settled=>"Local changes confirmed by the cloud. Receive Cloud Changes to check other devices.",
                    Status::MoreBatches=>"Sent part of the local changes. Choose Send Local Changes again to continue.",
                    Status::ReceiveFirst=>"Finish receiving the saved cloud snapshot before sending local changes.",
                    Status::LocalReview=>"A local record is missing. Sending is paused for review; local and cloud records are preserved.",
                    Status::SnapshotReview=>"The complete cloud snapshot needs review before sending changes.",
                    Status::PreservationRequired=>"An encrypted conflict needs preservation before its source or later edits can be sent.",
                    Status::ConflictReview=>"A conflict copy or retained offer needs review. Its original data and server response are saved.",
                    Status::VaultLocked=>"An encrypted conflict needs your vault before sending can continue.",
                    Status::IncompatibleVault=>"The server returned a record from a different vault. Sending needs review.",
                    Status::DeletionReview=>"A deletion needs review before it can be sent. The saved local intent is preserved.",
                    Status::PrimaryChanged=>"A local edit raced with applying a cloud conflict. Send Local Changes again to retry the retained response.",
                    Status::ReadOnly=>"This library is read-only. Local edits are kept.",
                    Status::ServerDeferred {..}=>"The server postponed some changes. Confirmed changes are saved; try sending the remaining edits later.",
                });
            },
            Reply::SnapshotReview {..}=>self.status.set_label("Review the missing cloud records before resuming."),
            Reply::SnapshotResumed(summary)=>{
                self.review_snapshot.set_visible(false);
                self.status.set_label(&format!("Cloud review complete. {} local records and {} saved conflict copies are kept. Receive Cloud Changes before sending them.", summary.local_records, summary.preservation_copies));
            },
            Reply::DeletionReview {..}=>self.status.set_label("Review the saved deletion before continuing."),
            Reply::DeletionDecided {kind,choice}=>{
                use crate::deletion_review::{Kind,Choice};
                self.status.set_label(match (kind,choice) {
                    (Kind::CloudDeletion,Choice::Delete)=>"Cloud deletion applied locally. Receive Cloud Changes to continue the saved page.",
                    (Kind::CloudDeletion,Choice::Keep)=>"Local version kept. Finish receiving or the retained send, then Send Local Changes to upload it.",
                    (_,Choice::Delete)=>"Deletion saved. Send Local Changes to apply it to the cloud. Other missing records still need their own review.",
                    (_,Choice::Keep)=>"Retained version restored. Send Local Changes after any earlier request finishes.",
                });
            },
            Reply::Selected {role,can_create_new,keys,pairing,mutation,switching,pending_matches,candidate,bootstrap}=>{
                self.selected_role.set(Some(role));
                self.apply_library(keys);
                self.set_pairing(pairing,None);
                self.set_mutation(mutation);
                if matches!(keys,Ok(Outcome::Ready {..})) {self.pair.set_sensitive(false);}
                self.set_switching(switching, matches!(keys, Err(key_store::Failure::ReviewRequired | key_store::Failure::KeyConflict)), pending_matches);
                self.set_new_creation(can_create_new);
                self.set_candidate_pairing(candidate, None);
                self.set_bootstrap(bootstrap, None);
            }
            Reply::CandidatePairing {state,failure} => self.set_candidate_pairing(state, failure),
            Reply::BootstrapCandidate {state,candidate,failure} => {
                self.set_candidate_pairing(candidate, None);
                self.set_bootstrap(state, failure);
            },
            Reply::HandoverReview {..} => self.status.set_label("Review this library switch before authorizing it."),
            Reply::LocalHandoverReview {..} => self.status.set_label("Review the saved local switch before authorizing it."),
            Reply::RestorationReview {..} => self.status.set_label("Review the saved changes before authorizing restoration."),
            Reply::HistoryRemovalReview {..} => self.status.set_label("Review the saved copy before authorizing removal."),
            Reply::HistoryRemoved => self.status.set_label("The selected history entry and its encrypted recovery files were removed."),
            Reply::RecoveryFilesCleaned => self.status.set_label("The reviewed unused recovery files were removed. Saved history, current records and keys were kept."),
            Reply::NoUnusedRecoveryFiles => self.status.set_label("No unused recovery files were found. Saved history was kept."),
            Reply::RestorationAuthentication {..} => self.status.set_label("Unlock the vaults to review the saved secure changes."),
            Reply::RestorationFile {..} => self.status.set_label("Previous vault file selected. Unlock it to review the saved changes."),
            Reply::RestorationFiles {..} => self.status.set_label("Vault files selected. Unlock each source to review all saved changes."),
            Reply::Restored {failure,cancelled} => {
                self.create_another.set_sensitive(false);
                self.clear_pairing(); self.clear_candidate_pairing(); self.selected_role.set(None);
                self.set_mutation(Ok(None)); self.libraries.set_selected(0);
                self.library_panel.set_sensitive(false); self.sync.set_sensitive(false);
                self.receive.set_sensitive(false); self.send.set_sensitive(false);
                self.review_deletions.set_sensitive(false); self.review_snapshot.set_visible(false);
                self.create.set_sensitive(false);
                if let Some(failure) = failure { self.failure(failure); }
                else { self.status.set_label(if cancelled { "Saved restoration cancelled. Current changes and previous states are kept. Reconnect and select a library before syncing." }
                    else { "Saved changes restored. Current versions and previous keys are kept. Reconnect and select a library before syncing." }); }
            },
            Reply::LocalHandover {switching,failure} => {
                self.create_another.set_sensitive(false);
                self.clear_pairing(); self.clear_candidate_pairing(); self.selected_role.set(None);
                self.set_mutation(Ok(None)); self.libraries.set_selected(0);
                self.library_panel.set_sensitive(false); self.sync.set_sensitive(false);
                self.receive.set_sensitive(false); self.send.set_sensitive(false);
                self.review_deletions.set_sensitive(false); self.review_snapshot.set_visible(false);
                self.create.set_sensitive(false);
                self.set_switching(switching, false, false);
                if !switching.pending { self.status.set_label("Saved switch finished locally. Reconnect and select a library to verify access before syncing. Local changes and previous keys are kept."); }
                if let Some(failure)=failure {self.failure(failure);}
            },
            Reply::Handover {switching,keys,role,cancelled,failure,pending_matches} => {
                self.clear_pairing(); self.set_mutation(Ok(None)); self.selected_role.set(role);
                if let Some(keys)=keys { self.apply_library(Ok(keys)); }
                self.set_switching(switching, keys.is_none() && role.is_some(), pending_matches);
                if cancelled { self.status.set_label("Saved switch cancelled. Local changes and previous keys are kept. Select a library to continue."); }
                else if keys.is_some() { self.status.set_label("Library switch complete. Local records and previous recovery keys are kept. Sync Now to exchange changes with the selected library."); }
                if let Some(failure)=failure { self.failure(failure); }
            },
            Reply::Pairing {state,failure}=>{
                self.pages.set_visible_child_name("libraries");
                self.library_panel.set_sensitive(true);
                let inactive=matches!(&state,Ok(None|Some(RetainedStatus::Inactive)));
                self.set_pairing(state,failure);
                if inactive && failure.is_none() {self.status.set_label("No active pairing invitation. Pair this computer to begin again.");}
            },
            Reply::Saved=>self.status.set_label("Recovery code confirmed. The retained presentation has been retired. Keep your offline copy."),
            Reply::MutationTarget {target,retained}=>{
                self.set_mutation(Ok(Some(retained)));
                if self.window.is_active() && self.window.is_visible() {
                    *self.mutation_target.borrow_mut()=Some(target);
                    self.update_mutation_authorize();
                }
            },
            Reply::Mutation {state,outcome,failure}=>{
                self.set_mutation(state);
                if let Some(outcome)=outcome {
                    if outcome != mutations::Outcome::ReviewRequired {self.pair.set_sensitive(false);}
                    self.status.set_label(match outcome {
                        mutations::Outcome::RecoveryReady=>"Recovery code replaced. Show the pending recovery code and save a new offline copy; the previous copy no longer opens the current recovery envelope.",
                        mutations::Outcome::ApprovalAcknowledged=>"Device approved. Finish key installation on the new device.",
                        mutations::Outcome::DeviceSignedIn=>"The new device is signed in.",
                        mutations::Outcome::ReviewRequired=>"The outcome could not be confirmed. Keep this operation for account review; retry only while its authorization is still accepted by the server.",
                    });
                }
                if let Some(failure)=failure {self.failure(failure);}
            },
            Reply::CreationFailed {state,can_create_new,failure}=>{self.set_creation(state);self.set_new_creation(can_create_new);self.failure(failure);},
            _=>self.failure(Failure::InvalidState),
        }
    }
    fn clear_pairing(&self) {
        self.pairing_poll.set(false);
        self.pairing_view.clear();
        self.pairing_code.set_label("");
        self.pairing_panel.set_visible(false);
    }
    fn update_mutation_actions(&self) {
        let idle = self.mutation_state.get().is_none();
        self.approval_prepare.set_sensitive(
            idle && matches!(self.selected_role.get(), Some(Role::Owner | Role::Writer)),
        );
        self.replace_recovery
            .set_sensitive(idle && self.selected_role.get() == Some(Role::Owner));
    }
    fn update_mutation_authorize(&self) {
        let allowed = self
            .mutation_target
            .borrow()
            .as_ref()
            .is_some_and(|target| match target.purpose() {
                Purpose::ApprovePairing => self.mutation_matched.is_active(),
                Purpose::ReplaceRecovery => true,
                Purpose::RevealRecovery
                | Purpose::RevealAccountKey
                | Purpose::SwitchLibrary
                | Purpose::CancelLibrarySwitch
                | Purpose::FinishLocalLibrarySwitch
                | Purpose::RestoreSavedChanges
                | Purpose::ResumeSavedChanges
                | Purpose::CancelSavedChanges
                | Purpose::RemoveSavedHistory
                | Purpose::ResumeHistoryRemoval
                | Purpose::RemoveUnusedRecoveryFiles
                | Purpose::ResumeRecoveryFileCleanup => false,
            });
        self.mutation_authorize.set_sensitive(allowed);
    }
    fn set_mutation(&self, state: key_store::Result<Option<mutations::Retained>>) {
        self.mutation_target.borrow_mut().take();
        self.mutation_matched.set_active(false);
        self.mutation_authorize.set_sensitive(false);
        self.mutation_state.set(None);
        self.mutation_code.set_label("");
        self.mutation_panel.set_visible(false);
        match state {
            Ok(Some(retained)) => {
                self.mutation_state
                    .set(Some((retained.kind, retained.step)));
                self.mutation_panel.set_visible(true);
                self.mutation_matched
                    .set_visible(retained.kind == mutations::Kind::Approval);
                if let Some(code) = retained.confirmation_code {
                    self.mutation_code
                        .set_label(&format!("Confirmation code: {code}"));
                }
                self.mutation_status.set_label(match (retained.kind, retained.step) {
                    (mutations::Kind::Approval, mutations::Step::Prepared) => "Compare this code with the new device before approving. Only continue if both codes match.",
                    (mutations::Kind::Recovery, mutations::Step::Prepared) => "Replacing the recovery code makes the previous offline copy unable to open the current recovery envelope. Your library key and snippets are kept. Save the new copy after replacement.",
                    (_, mutations::Step::Signed) => "This operation may have reached the server. Check its saved result or authorize a retry of the same operation.",
                    (_, mutations::Step::Acknowledged) => "The server acknowledged this operation. Check its saved result to finish local recovery.",
                });
                self.mutation_authorize
                    .set_label(if retained.kind == mutations::Kind::Approval {
                        "Authorize Device Approval…"
                    } else {
                        "Authorize Recovery Replacement…"
                    });
                self.mutation_resume
                    .set_sensitive(retained.step != mutations::Step::Acknowledged);
                self.mutation_reconcile
                    .set_sensitive(retained.step != mutations::Step::Prepared);
                self.mutation_cancel
                    .set_sensitive(retained.step == mutations::Step::Prepared);
            }
            Err(e) => {
                // Unknown saved state cannot enable a competing operation.
                self.approval_prepare.set_sensitive(false);
                self.replace_recovery.set_sensitive(false);
                self.failure(e.into());
                return;
            }
            Ok(None) => (),
        }
        self.update_mutation_actions();
    }
    fn apply_library(&self, outcome: key_store::Result<Outcome>) {
        // Checkpoint review cannot erase an independently retained recovery kit.
        self.library_panel.set_sensitive(true);
        self.sync
            .set_sensitive(matches!(outcome, Ok(Outcome::Ready { .. })));
        self.send.set_sensitive(
            matches!(outcome, Ok(Outcome::Ready { .. }))
                && self.selected_role.get() != Some(Role::Reader),
        );
        self.receive
            .set_sensitive(matches!(outcome, Ok(Outcome::Ready { .. })));
        self.review_deletions
            .set_sensitive(matches!(outcome, Ok(Outcome::Ready { .. })));
        self.pair
            .set_sensitive(!matches!(outcome, Ok(Outcome::Ready { .. })));
        match outcome {
            Ok(Outcome::NeedsTrustedDeviceOrRecovery)=>self.status.set_label("Pair with a trusted device or enter your recovery code. Set Up creates the first keys only if this server library is empty."),
            Ok(Outcome::Ready {kit})=>{
                self.clear_pairing();
                self.status.set_label(match kit {
                    KitStatus::AwaitingPresentation=>"Library key ready. Authorize to show and record the pending recovery code.",
                    KitStatus::VerifiedCurrent=>"Library key ready. Recovery code already confirmed; keep your offline copy.",
                    KitStatus::Replaced=>"Library key ready. The saved recovery envelope changed; review your recovery copy.",
                    KitStatus::None=>"Library key ready. Keep the recovery copy on your trusted device.",
                });
            }
            Err(e)=>self.failure(e.into()),
        }
    }
    fn set_pairing(
        &self,
        state: key_store::Result<Option<RetainedStatus>>,
        failure: Option<Failure>,
    ) {
        self.pairing_poll.set(false);
        self.pairing_check.set_sensitive(true);
        self.pairing_cancel.set_sensitive(true);
        self.pairing_copy.set_sensitive(false);
        self.pairing_check.set_label("Check Approval");
        self.pair
            .set_sensitive(matches!(state, Ok(None | Some(RetainedStatus::Inactive))));
        match state {
            Ok(None | Some(RetainedStatus::Inactive)) => self.clear_pairing(),
            Ok(Some(RetainedStatus::Waiting {
                invitation,
                received: false,
            })) => {
                self.pairing_code.set_label(&format!(
                    "Confirmation code: {}",
                    invitation.confirmation_code()
                ));
                if let Err(e) = self.pairing_view.show(invitation) {
                    self.clear_pairing();
                    self.failure(e);
                    return;
                }
                self.pairing_view.area.set_visible(true);
                self.pairing_panel.set_visible(true);
                self.pairing_status
                    .set_label("Waiting for approval from your trusted device.");
                self.status.set_label(
                    "Pairing invitation saved. Waiting for approval from your trusted device.",
                );
                self.pairing_copy
                    .set_sensitive(!self.pairing_view.remaining().is_zero());
                self.pairing_poll
                    .set(failure.is_none() && !self.worker.retention_required());
            }
            Ok(Some(RetainedStatus::Waiting { received: true, .. })) => {
                self.pairing_view.clear();
                self.pairing_code.set_label("");
                self.pairing_view.area.set_visible(false);
                self.pairing_panel.set_visible(true);
                self.pairing_check.set_label("Finish Key Installation");
                self.pairing_cancel.set_sensitive(false);
                self.pairing_status.set_label("The approved key is securely retained. Reconnect if needed, then finish installation; the invitation may already have expired.");
                self.status
                    .set_label("Approved key saved. Finish installation or reconnect if needed.");
            }
            Ok(Some(RetainedStatus::Creating | RetainedStatus::Cancelling)) => {
                let creating = matches!(state, Ok(Some(RetainedStatus::Creating)));
                self.pairing_view.clear();
                self.pairing_code.set_label("");
                self.pairing_view.area.set_visible(false);
                self.pairing_panel.set_visible(true);
                self.pairing_check.set_sensitive(!creating);
                self.pairing_check.set_label("Resume Cancellation");
                self.pairing_status.set_label(if creating {"Invitation creation was interrupted. Cancel this attempt before creating a new invitation."} else {"Invitation cancellation was interrupted. Resume it to complete cancellation."});
                self.status.set_label(if creating {"Invitation creation was interrupted. Cancel this attempt before creating a new invitation."} else {"Invitation cancellation is pending. Resume it to finish."});
            }
            Err(e) => {
                self.clear_pairing();
                self.failure(e.into());
            }
        }
        if let Some(failure) = failure {
            self.failure(failure);
        }
    }
    fn set_creation(&self, state: creation::Result<creation::State>) {
        self.creation_state.set(state.ok());
        self.create.set_sensitive(matches!(
            state,
            Ok(creation::State::Available | creation::State::Requested | creation::State::Created)
        ));
        self.create.set_label(match state {
            Ok(creation::State::Available) => "Create New Cloud Library…",
            Ok(creation::State::Requested) => "Resume Library Creation",
            Ok(creation::State::Created) => "Open Created Library",
            _ => "Continue with Saved Library",
        });
    }
    fn set_new_creation(&self, state: creation::Result<bool>) {
        self.create_another.set_sensitive(state == Ok(true));
        self.create_another
            .set_visible(self.creation_state.get() != Some(creation::State::Available));
    }
    fn reveal(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        self.status.set_label("Checking recovery state…");
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = this.authorize_and_reveal(generation).await;
            this.busy(false);
            if generation == this.generation.get() {
                match result {
                    Ok(()) => this.status.set_label(
                        "Record the code offline, then verify the last eight characters.",
                    ),
                    Err(e) => {
                        this.cancel_sensitive();
                        this.failure(e);
                    }
                }
            }
        });
    }
    /// Validates locally first: a key that fails normalization or its check is a
    /// typing error, stays in the field for correction and is never sent.
    fn sign_in(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        let key = match secret(&self.account_key_input) {
            Ok(entered) => match AccountKey::parse_input(&entered) {
                Some(key) => key,
                None => {
                    self.account_key_input.set_text(&entered);
                    self.failure(Failure::InvalidAccountKey);
                    return;
                }
            },
            Err(_) => {
                self.failure(Failure::InvalidAccountKey);
                return;
            }
        };
        self.library_panel.set_sensitive(false);
        self.run(Command::SignIn {
            server: Zeroizing::new(self.server.text().to_string()),
            key,
        });
    }
    fn set_account(&self, account: Option<String>) {
        self.account_panel.set_visible(account.is_some());
        self.account_id.set_label(
            &account
                .as_deref()
                .map_or_else(String::new, |id| format!("Account ID: {id}")),
        );
        *self.account_display.borrow_mut() = account;
    }
    fn created_key_visible(&self) -> bool {
        matches!(
            self.key_presentation.borrow().as_ref(),
            Some(KeyPresentation::Created(_))
        )
    }
    fn disclosed_key_visible(&self) -> bool {
        matches!(
            self.key_presentation.borrow().as_ref(),
            Some(KeyPresentation::Disclosed(_))
        )
    }
    /// Shown once after the new session and its key are committed. Nothing else
    /// continues until the owner explicitly acknowledges saving the key.
    fn show_created_key(
        &self,
        key: AccountKey,
        next: Option<Box<Reply>>,
        failure: Option<Failure>,
    ) {
        self.end_key_presentation(false);
        self.key_label.set_label(&key.display());
        *self.key_presentation.borrow_mut() = Some(KeyPresentation::Created(key));
        *self.created_next.borrow_mut() = Some((next, failure));
        self.key_title.set_label("Save Your Account Key");
        self.key_message.set_label(CREATED_KEY_MESSAGE);
        self.key_done.set_label("I've Saved It");
        self.key_panel.set_visible(true);
        self.pages.set_visible(false);
        self.account_panel.set_visible(false);
        self.reconnect.set_visible(false);
        self.sign_out.set_visible(false);
        self.status
            .set_label("Account created. Save your account key before continuing.");
    }
    fn show_disclosed_key(&self, disclosure: AccountKeyDisclosure) -> Result<()> {
        let display = disclosure.display()?;
        self.end_key_presentation(false);
        self.key_label.set_label(&display);
        drop(display);
        *self.key_presentation.borrow_mut() = Some(KeyPresentation::Disclosed(disclosure));
        self.key_title.set_label("Your Account Key");
        self.key_message.set_label(&format!(
            "{CREATED_KEY_MESSAGE} The key hides when this window loses focus, the desktop locks, or authorization expires."
        ));
        self.key_done.set_label("Hide Key");
        self.key_panel.set_visible(true);
        Ok(())
    }
    /// Ends either presentation. Ending a created key continues with the reply
    /// retained from account creation; without the explicit acknowledgement the
    /// owner is reminded where to find the saved key.
    fn end_key_presentation(&self, acknowledged: bool) {
        let Some(presentation) = self.key_presentation.borrow_mut().take() else {
            return;
        };
        self.key_label.set_label("");
        self.key_panel.set_visible(false);
        self.pages.set_visible(true);
        let created = matches!(presentation, KeyPresentation::Created(_));
        drop(presentation);
        if !created {
            return;
        }
        if let Some((next, failure)) = self.created_next.borrow_mut().take() {
            if let Some(next) = next {
                self.apply(*next);
            }
            if let Some(failure) = failure {
                self.failure(failure);
                return;
            }
        }
        if !acknowledged {
            self.status.set_label("Your account key is saved in this computer's keyring. Choose Show Account Key to save it before you sign in on another device.");
        }
    }
    fn copy_key(&self) {
        let copied = self
            .key_presentation
            .borrow()
            .as_ref()
            .ok_or(Failure::InvalidState)
            .and_then(KeyPresentation::display)
            .and_then(|text| copy_account_key(&self.key_label, &text));
        match copied {
            Ok(()) => self.status.set_label(
                "Account key copied. Snippets clears it from the clipboard after two minutes if it is still there.",
            ),
            Err(failure) => {
                if self.disclosed_key_visible() {
                    self.end_key_presentation(false);
                }
                self.failure(failure);
            }
        }
    }
    /// Gated by the same fresh computer-password authorization as recovery-code
    /// disclosure. The worker rereads the exact saved session before disclosure.
    fn show_account_key(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        self.status.set_label("Checking the saved account…");
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = this.authorize_and_show_key(generation).await;
            this.busy(false);
            if generation == this.generation.get() {
                match result {
                    Ok(()) => this
                        .status
                        .set_label("Store your account key in your password manager."),
                    Err(e) => {
                        this.cancel_sensitive();
                        this.failure(e);
                    }
                }
            }
        });
    }
    async fn authorize_and_show_key(&self, generation: u64) -> Result<()> {
        let Reply::Target(target) = self.execute(Command::PrepareAccountKeyDisclosure).await?
        else {
            return Err(Failure::InvalidState);
        };
        let permit = self.authorize_target(target, generation).await?;
        let Reply::AccountKey(disclosure) = self.execute(Command::RevealAccountKey(permit)).await?
        else {
            return Err(Failure::InvalidState);
        };
        if generation != self.generation.get() || !self.window.is_active() {
            return Err(Failure::Authentication(
                crate::local_auth::Failure::Cancelled,
            ));
        }
        self.show_disclosed_key(disclosure)
    }
    fn confirm_sign_out(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        self.cancel_sensitive();
        let generation = self.generation.get();
        let dialog = adw::AlertDialog::builder()
            .heading("Sign Out?")
            .body("Snippets stops syncing with this account on this computer. Your local snippets stay here. You'll need your account key to sign in again.")
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("sign-out", "Sign Out")]);
        dialog.set_response_appearance("sign-out", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let this = self.clone();
        glib::spawn_future_local(async move {
            if generation != this.generation.get() {
                return;
            }
            *this.sign_out_dialog.borrow_mut() = Some(dialog.clone());
            let response = dialog.clone().choose_future(Some(&this.window)).await;
            let current = this
                .sign_out_dialog
                .borrow()
                .as_ref()
                .is_some_and(|open| *open == dialog);
            if current {
                this.sign_out_dialog.borrow_mut().take();
            }
            if response == "sign-out" && current && generation == this.generation.get() {
                this.run(Command::SignOut);
            }
        });
    }
    /// A hard failure stops automatic claims; the owner checks again explicitly.
    fn stop_device_polling(&self) {
        if self.device_poll.replace(false) && self.device_view.value.borrow().is_some() {
            self.device_continue.set_label("Check Again");
            self.device_continue.set_visible(true);
        }
    }
    fn clear_device(&self) {
        self.device_poll.set(false);
        self.device_view.clear();
        self.device_code.set_label("");
        self.device_status.set_label("");
        self.device_continue.set_visible(false);
    }
    /// The new device's request. Poll failures keep the request on screen; a
    /// server delay or a network backoff postpones the next two-second poll.
    fn set_device(
        &self,
        state: Option<crate::auth_store::device::Status>,
        retry_after: Option<u32>,
        failure: Option<Failure>,
    ) {
        use crate::auth_store::device::Status;
        match state {
            None => {
                self.clear_device();
                self.pages.set_visible_child_name("login");
            }
            Some(Status::Waiting(request)) => {
                if let Err(e) = self.device_view.show_device(&request) {
                    self.clear_device();
                    self.failure(e);
                    return;
                }
                self.pages.set_visible_child_name("device");
                self.device_view.area.set_visible(true);
                self.device_continue.set_visible(false);
                self.device_continue.set_label("Finish Signing In");
                self.device_code.set_label(&format!(
                    "Confirmation code: {}",
                    request.confirmation_code()
                ));
                let live = !self.device_view.remaining().is_zero();
                self.device_copy.set_sensitive(live);
                self.device_poll
                    .set(live && !self.worker.retention_required());
                let network = matches!(
                    failure,
                    Some(Failure::Cloud(crate::cloud::Failure::Network))
                );
                let backoff = if network {
                    (self.device_backoff.get() * 2).clamp(4, 60)
                } else {
                    0
                };
                self.device_backoff.set(backoff);
                let delay = retry_after.map_or(backoff, u64::from).max(backoff);
                if delay > 0 {
                    self.device_view.defer(Duration::from_secs(delay));
                }
                self.status
                    .set_label("Approve this computer from a device that's already signed in.");
                if let Some(failure) = failure {
                    self.device_status.set_label(failure.message());
                    // A definitive refusal ends this request; network trouble retries.
                    if !network
                        && !matches!(
                            failure,
                            Failure::Cloud(crate::cloud::Failure::Server {
                                code: crate::cloud::ErrorCode::RateLimited
                                    | crate::cloud::ErrorCode::DependencyUnavailable
                                    | crate::cloud::ErrorCode::InternalError,
                                ..
                            })
                        )
                    {
                        self.stop_device_polling();
                        self.status.set_label(failure.message());
                    }
                }
            }
            Some(Status::Approved) => {
                self.device_poll.set(false);
                self.device_view.clear();
                self.device_view.area.set_visible(false);
                self.device_code.set_label("");
                self.pages.set_visible_child_name("device");
                self.device_copy.set_sensitive(false);
                self.device_continue.set_label("Finish Signing In");
                self.device_continue.set_visible(true);
                self.device_status.set_label(
                    "Another device approved this computer. Finish signing in to receive the library key.",
                );
                self.status
                    .set_label("Finish signing in with another device.");
                if let Some(failure) = failure {
                    self.failure(failure);
                }
            }
        }
    }
    /// The add-device entry accepts a pairing invitation or a new device's
    /// sign-in request. A sign-in request shows its confirmation code and asks
    /// before any network call; the approval then needs fresh owner authority.
    fn review_added_device(self: &Rc<Self>, payload: Zeroizing<String>) {
        if self.busy.get() {
            return;
        }
        let decoded = crate::bootstrap::AddDevice::decode_qr(
            payload.as_bytes(),
            chrono::Utc::now().timestamp(),
        );
        let request = match decoded {
            Ok(crate::bootstrap::AddDevice::SignIn(request)) => request,
            // Invitations keep the existing review path, including its errors.
            _ => {
                self.run(Command::PrepareApproval(payload));
                return;
            }
        };
        if request.server().for_secure_storage() != self.server.text().as_str() {
            self.failure(Failure::InvalidDeviceRequest);
            return;
        }
        self.cancel_sensitive();
        let generation = self.generation.get();
        let desktop_epoch = self
            .desktop
            .as_ref()
            .map_or(0, |monitor| monitor.snapshot().1);
        if !self.creation_review_active(generation, desktop_epoch) {
            self.failure(Failure::Authentication(
                crate::local_auth::Failure::DesktopUnavailable,
            ));
            return;
        }
        let dialog = adw::AlertDialog::builder()
            .heading("Sign In a New Device?")
            .body(format!(
                "Confirmation code: {}\n\nSign in a new device to this account? It will also receive this library's key. Continue only if this code matches the code on the new device.",
                request.confirmation_code()
            ))
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("continue", "Continue")]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let this = self.clone();
        glib::spawn_future_local(async move {
            *this.snapshot_dialog.borrow_mut() = Some(dialog.clone());
            let response = dialog.clone().choose_future(Some(&this.window)).await;
            this.snapshot_dialog.borrow_mut().take();
            if response != "continue" || !this.creation_review_active(generation, desktop_epoch) {
                return;
            }
            this.busy(true);
            this.status
                .set_label("Checking the library before approval…");
            let result = async {
                let Reply::Target(target) = this
                    .execute(Command::PrepareDeviceApproval(payload))
                    .await?
                else {
                    return Err(Failure::InvalidState);
                };
                let permit = this.authorize_target(target, generation).await?;
                this.status.set_label("Approving the new device…");
                this.execute(Command::ApproveDevice(permit)).await
            }
            .await;
            this.busy(false);
            if generation != this.generation.get() {
                return;
            }
            this.cancel_sensitive();
            match result {
                Ok(reply) => this.apply(reply),
                Err(e) => this.failure(e),
            }
        });
    }
    fn create_library(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        if self.creation_state.get() != Some(creation::State::Available) {
            if matches!(
                self.creation_state.get(),
                Some(creation::State::Requested | creation::State::Created)
            ) {
                self.run(Command::CreateLibrary);
            }
            return;
        }
        self.create_another_library();
    }
    fn creation_review_active(&self, generation: u64, desktop_epoch: u64) -> bool {
        generation == self.generation.get()
            && self.window.is_visible()
            && self.window.is_active()
            && self.desktop.as_ref().is_some_and(|monitor| {
                monitor.snapshot() == (SessionState::Unlocked, desktop_epoch)
            })
    }
    fn create_another_library(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        self.cancel_sensitive();
        let desktop_epoch = self
            .desktop
            .as_ref()
            .map_or(0, |monitor| monitor.snapshot().1);
        if !self.creation_review_active(self.generation.get(), desktop_epoch) {
            self.failure(Failure::Authentication(
                crate::local_auth::Failure::DesktopUnavailable,
            ));
            return;
        }
        self.busy(true);
        self.status.set_label("Checking library creation…");
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let proposal = this.execute(Command::PrepareNewLibrary).await;
            let (token, retained) = match proposal {
                Ok(Reply::NewLibrary { token, retained }) => (token, retained),
                result => {
                    this.busy(false);
                    if generation == this.generation.get() {
                        this.failure(result.err().unwrap_or(Failure::InvalidState));
                    }
                    return;
                }
            };
            if !this.creation_review_active(generation, desktop_epoch) {
                this.busy(false);
                return;
            }
            let dialog=adw::AlertDialog::builder().heading("Create New Cloud Library?")
                .body(format!("Create an empty library for account {} at {}? Your local snippets, current keys and sync history are kept. {retained} earlier creation requests remain saved. Set up new keys and review the switch afterward.", this.account_display.borrow().as_deref().unwrap_or(""), this.server.text())).build();
            dialog.add_responses(&[("cancel", "Cancel"), ("create", "Create Library")]);
            dialog.set_default_response(Some("cancel"));
            dialog.set_close_response("cancel");
            *this.snapshot_dialog.borrow_mut() = Some(dialog.clone());
            let response = dialog.choose_future(Some(&this.window)).await;
            this.snapshot_dialog.borrow_mut().take();
            this.busy(false);
            if response == "create" && this.creation_review_active(generation, desktop_epoch) {
                this.run(Command::CreateNewLibrary(token));
            }
        });
    }
    fn set_switching(&self, state: handover::Status, candidate: bool, matches: bool) {
        self.switch_state.set(state);
        self.switch_candidate.set(candidate);
        self.switch_matches.set(matches);
        self.bootstrap_create.set_visible(
            candidate && !state.pending && self.selected_role.get() == Some(Role::Owner),
        );
        self.bootstrap_create.set_sensitive(
            candidate && !state.pending && self.selected_role.get() == Some(Role::Owner),
        );
        self.bootstrap_status.set_visible(false);
        self.bootstrap_state.set(None);
        self.candidate_pair.set_visible(candidate && !state.pending);
        self.candidate_pair.set_sensitive(
            candidate && !state.pending && self.selected_role.get() != Some(Role::Reader),
        );
        if state.pending || !candidate {
            self.clear_candidate_pairing();
        }
        self.switch_panel.set_visible(state.pending || candidate);
        self.switch_review.set_visible(!state.pending);
        self.switch_review
            .set_sensitive(candidate && !state.pending);
        self.switch_recovery
            .set_visible(candidate && !state.pending);
        self.switch_resume.set_visible(state.pending);
        self.switch_resume.set_sensitive(state.pending && matches);
        self.switch_cancel.set_visible(state.pending);
        self.switch_cancel.set_sensitive(state.pending);
        self.switch_local.set_visible(state.pending);
        self.switch_local.set_sensitive(state.pending);
        self.switch_status.set_label(if state.pending {
            "A saved library switch needs finishing. Reconnect to resume, cancel before it begins, or finish an already started switch offline if the account changed. Local records and previous keys remain saved."
        } else {
            "The selected library needs a reviewed switch. Leave the recovery field empty to check a key saved on this computer, including after an account or library setup change, or enter the selected library's recovery code."
        });
        if state.pending || candidate {
            self.library_panel.set_sensitive(false);
            self.create.set_sensitive(false);
            self.create_another.set_sensitive(false);
            self.sync.set_sensitive(false);
            self.receive.set_sensitive(false);
            self.send.set_sensitive(false);
            self.review_deletions.set_sensitive(false);
            self.review_snapshot.set_visible(false);
            self.clear_pairing();
            self.mutation_target.borrow_mut().take();
            self.mutation_authorize.set_sensitive(false);
        }
    }
    fn clear_candidate_pairing(&self) {
        self.candidate_poll.set(false);
        self.candidate_view.clear();
        self.candidate_code.set_label("");
        self.candidate_panel.set_visible(false);
        self.candidate_copy.set_sensitive(false);
    }
    fn set_bootstrap(
        &self,
        state: key_store::Result<Option<initial_candidate::Status>>,
        failure: Option<Failure>,
    ) {
        self.bootstrap_state.set(state.ok().flatten());
        if !self.switch_candidate.get() || self.switch_state.get().pending {
            self.bootstrap_status.set_visible(false);
            return;
        }
        self.bootstrap_create.set_sensitive(
            self.selected_role.get() == Some(Role::Owner)
                && matches!(
                    state,
                    Ok(None
                        | Some(
                            initial_candidate::Status::Prepared | initial_candidate::Status::Sent
                        ))
                ),
        );
        self.bootstrap_create.set_label(
            if matches!(
                state,
                Ok(Some(
                    initial_candidate::Status::Prepared | initial_candidate::Status::Sent
                ))
            ) {
                "Resume Selected Library Key Setup"
            } else {
                "Create First Keys for Empty Library…"
            },
        );
        self.bootstrap_status
            .set_visible(matches!(state, Ok(Some(_))));
        match state {
            Ok(Some(initial_candidate::Status::Prepared|initial_candidate::Status::Sent))=>{
                self.candidate_pair.set_sensitive(false);
                self.bootstrap_status.set_label("A saved key setup needs finishing. Resume it to check the server using the same key and recovery code. Current local keys are kept.");
            }
            Ok(Some(initial_candidate::Status::Ready {kit}))=>{
                self.candidate_pair.set_sensitive(false);
                self.bootstrap_status.set_label(match kit {
                    KitStatus::Replaced => "The selected key is saved, but its recovery envelope changed. Review the switch and use the current recovery copy from your trusted device.",
                    KitStatus::VerifiedCurrent => "The selected key is saved separately and its saved recovery copy is verified. Review Library Switch to activate it.",
                    _ => "The selected key is saved separately. Review Library Switch, then show and save its recovery code after switching.",
                });
            }
            Ok(Some(initial_candidate::Status::Lost))=>self.bootstrap_status.set_label("Another device initialized this library. Get its key from that device or use its recovery code. The unused candidate is kept in protected history."),
            Ok(None)=>(),
            Err(error)=>self.failure(error.into()),
        }
        if let Some(failure) = failure {
            self.failure(failure);
        }
    }
    fn create_target_keys(self: &Rc<Self>) {
        if self.busy.get() || !self.bootstrap_create.is_sensitive() {
            return;
        }
        if self.bootstrap_state.get().is_some() {
            self.run(Command::BootstrapCandidate);
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let dialog=adw::AlertDialog::builder().heading("Create First Keys for the Selected Library?")
                .body(format!("{}\n{}\n\nCreate keys only if the selected server library is empty? Current local keys and snippets are kept. Review the library switch separately, then show and save the new recovery code.",this.creation_status.label(),this.selected_library_label())).build();
            dialog.add_responses(&[("cancel", "Cancel"), ("create", "Create Keys")]);
            dialog.set_default_response(Some("cancel"));
            dialog.set_close_response("cancel");
            *this.snapshot_dialog.borrow_mut() = Some(dialog.clone());
            let response = dialog.choose_future(Some(&this.window)).await;
            this.snapshot_dialog.borrow_mut().take();
            this.busy(false);
            if response == "create"
                && generation == this.generation.get()
                && this.window.is_active()
            {
                this.run(Command::BootstrapCandidate);
            }
        });
    }
    fn selected_library_label(&self) -> glib::GString {
        self.libraries
            .selected_item()
            .and_downcast::<gtk::StringObject>()
            .map(|value| value.string())
            .unwrap_or_else(|| "Selected cloud library".into())
    }
    fn set_candidate_pairing(
        &self,
        state: key_store::Result<Option<candidate::Status>>,
        failure: Option<Failure>,
    ) {
        self.candidate_poll.set(false);
        if self.switch_state.get().pending || !self.switch_candidate.get() {
            self.clear_candidate_pairing();
            return;
        }
        self.candidate_pair.set_sensitive(
            matches!(state, Ok(None | Some(candidate::Status::Cancelled)))
                && self.selected_role.get() != Some(Role::Reader),
        );
        self.candidate_check.set_sensitive(true);
        self.candidate_check.set_label("Check Approval");
        self.candidate_cancel.set_sensitive(true);
        self.candidate_copy.set_sensitive(false);
        match state {
            Ok(None | Some(candidate::Status::Cancelled)) => self.clear_candidate_pairing(),
            Ok(Some(candidate::Status::Waiting {
                invitation,
                received: false,
            })) => {
                self.candidate_code.set_label(&format!(
                    "Confirmation code: {}",
                    invitation.confirmation_code()
                ));
                if let Err(e) = self.candidate_view.show(invitation) {
                    self.clear_candidate_pairing();
                    self.failure(e);
                    return;
                }
                self.candidate_view.area.set_visible(true);
                self.candidate_panel.set_visible(true);
                self.candidate_copy
                    .set_sensitive(!self.candidate_view.remaining().is_zero());
                self.candidate_poll
                    .set(failure.is_none() && !self.worker.retention_required());
                self.status.set_label(
                    "Key request saved. Approve it on a device that opens the selected library.",
                );
            }
            Ok(Some(candidate::Status::Waiting { received: true, .. })) => {
                self.candidate_view.clear();
                self.candidate_code.set_label("");
                self.candidate_view.area.set_visible(false);
                self.candidate_panel.set_visible(true);
                self.candidate_cancel.set_sensitive(false);
                self.candidate_check.set_label("Finish Key Verification");
                self.candidate_status.set_label("The received key is saved separately. Reconnect if needed, then verify it; the invitation may already have expired.");
            }
            Ok(Some(candidate::Status::Ready)) => {
                self.clear_candidate_pairing();
                self.switch_status.set_label("The selected library key is saved separately. Leave the recovery field empty and review the library switch. Your current library and keys remain active until confirmation.");
                self.status
                    .set_label("Selected library key saved. Review Library Switch to continue.");
            }
            Ok(Some(candidate::Status::Creating | candidate::Status::Cancelling)) => {
                let creating = matches!(state, Ok(Some(candidate::Status::Creating)));
                self.candidate_view.clear();
                self.candidate_code.set_label("");
                self.candidate_view.area.set_visible(false);
                self.candidate_panel.set_visible(true);
                self.candidate_check.set_sensitive(!creating);
                self.candidate_check.set_label("Resume Cancellation");
                self.candidate_status.set_label(if creating { "Invitation creation was interrupted. Cancel this attempt before requesting another." } else { "Cancellation was interrupted. Resume it to finish." });
            }
            Err(e) => {
                self.clear_candidate_pairing();
                self.failure(e.into());
            }
        }
        if let Some(failure) = failure {
            self.failure(failure);
        }
    }
    fn show_history(self: &Rc<Self>) {
        if self.busy.get() {
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = this.execute(Command::InspectHistory).await;
            this.busy(false);
            if generation != this.generation.get() || !this.window.is_active() {
                return;
            }
            match result {
                Ok(Reply::History(history)) => {
                    let weak = Rc::downgrade(&this);
                    let restore = Rc::new(move |selection| {
                        if let Some(this) = weak.upgrade() {
                            this.restore_saved(Some(selection), false);
                        }
                    });
                    let weak = Rc::downgrade(&this);
                    let finish = Rc::new(move |cancel| {
                        if let Some(this) = weak.upgrade() {
                            this.restore_saved(None, cancel);
                        }
                    });
                    let dialog = adw::Dialog::builder()
                        .title("Library Recovery History")
                        .content_width(620)
                        .content_height(640)
                        .child(&history_view::content(
                            &history,
                            restore,
                            finish,
                            {
                                let weak = Rc::downgrade(&this);
                                Rc::new(move |selection| {
                                    if let Some(this) = weak.upgrade() {
                                        this.remove_saved_history(selection);
                                    }
                                })
                            },
                            {
                                let weak = Rc::downgrade(&this);
                                Rc::new(move || {
                                    if let Some(this) = weak.upgrade() {
                                        this.cleanup_recovery_files();
                                    }
                                })
                            },
                        ))
                        .build();
                    let weak = Rc::downgrade(&this);
                    dialog.connect_closed(move |_| {
                        if let Some(this) = weak.upgrade() {
                            this.history_dialog.borrow_mut().take();
                        }
                    });
                    *this.history_dialog.borrow_mut() = Some(dialog.clone());
                    dialog.present(Some(&this.window));
                }
                Ok(_) => this.failure(Failure::InvalidState),
                Err(failure) => this.failure(failure),
            }
        });
    }
    fn switch_library(self: &Rc<Self>, action: SwitchAction) {
        let allowed = match &action {
            SwitchAction::Review(_) => {
                self.switch_candidate.get() && !self.switch_state.get().pending
            }
            SwitchAction::Resume => self.switch_state.get().pending && self.switch_matches.get(),
            SwitchAction::Cancel => self.switch_state.get().pending,
            SwitchAction::FinishLocal => self.switch_state.get().pending,
        };
        if self.busy.get() || !allowed {
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        self.status.set_label("Checking the library switch…");
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = async {
                let (target, token, cancel, local) = match action {
                    SwitchAction::Review(code) => {
                        let Reply::HandoverReview { token, summary, target, reused_local_key } = this.execute(Command::PrepareHandover(code)).await? else { return Err(Failure::InvalidState); };
                        if generation != this.generation.get() || !this.window.is_active() { return Ok(None); }
                        let dialog = adw::AlertDialog::builder().heading("Switch to the Selected Library?")
                            .body(format!("{}\n{}\n\n{}\n\nKeep {} local records and {} saved conflict copies while switching? Previous library keys stay in recovery history. Kept local records can be uploaded to the selected library when you next sync.", this.creation_status.label(), this.selected_library_label(), if reused_local_key { "Use a key saved on this computer and verified for the selected library." } else { "Use the supplied recovery code, verified for the selected library." }, summary.local_records, summary.preservation_copies)).build();
                        dialog.add_responses(&[("back", "Cancel"), ("switch", "Switch Library")]);
                        dialog.set_default_response(Some("back")); dialog.set_close_response("back");
                        *this.snapshot_dialog.borrow_mut() = Some(dialog.clone());
                        let response = dialog.choose_future(Some(&this.window)).await;
                        this.snapshot_dialog.borrow_mut().take();
                        if response != "switch" { return Ok(None); }
                        (target, Some(token), false, false)
                    }
                    SwitchAction::Resume => {
                        let Reply::Target(target) = this.execute(Command::PrepareHandoverResume).await? else { return Err(Failure::InvalidState); };
                        (target, None, false, false)
                    }
                    SwitchAction::Cancel => {
                        let Reply::Target(target) = this.execute(Command::PrepareHandoverCancel).await? else { return Err(Failure::InvalidState); };
                        if generation != this.generation.get() || !this.window.is_active() { return Ok(None); }
                        let dialog = adw::AlertDialog::builder().heading("Cancel the Saved Library Switch?")
                            .body("Local changes and previous keys will be kept. The candidate key stays in recovery history. A switch that has already begun must be finished instead.").build();
                        dialog.add_responses(&[("back", "Keep Saved Switch"), ("cancel-switch", "Cancel Switch")]);
                        dialog.set_default_response(Some("back")); dialog.set_close_response("back");
                        *this.snapshot_dialog.borrow_mut()=Some(dialog.clone());
                        let response=dialog.choose_future(Some(&this.window)).await;
                        this.snapshot_dialog.borrow_mut().take();
                        if response != "cancel-switch" { return Ok(None); }
                        (target, None, true, false)
                    }
                    SwitchAction::FinishLocal => {
                        let Reply::LocalHandoverReview {target,summary} = this.execute(Command::PrepareLocalHandover).await? else {return Err(Failure::InvalidState);};
                        if generation != this.generation.get() || !this.window.is_active() {return Ok(None);}
                        let dialog=adw::AlertDialog::builder().heading("Finish the Saved Switch Offline?")
                            .body(format!("Finish only the switch already started on this computer? Its saved review keeps {} local records and {} conflict copies. Current local changes and previous keys stay saved. No server is contacted. Afterward reconnect and select a library to verify access before syncing.", summary.local_records,summary.preservation_copies)).build();
                        dialog.add_responses(&[("back","Keep Saved Switch"),("finish-local","Finish Locally")]);
                        dialog.set_default_response(Some("back"));dialog.set_close_response("back");
                        *this.snapshot_dialog.borrow_mut()=Some(dialog.clone());
                        let response=dialog.choose_future(Some(&this.window)).await;
                        this.snapshot_dialog.borrow_mut().take();
                        if response!="finish-local" {return Ok(None);}
                        (target,None,false,true)
                    }
                };
                if generation != this.generation.get() || !this.window.is_active() { return Ok(None); }
                let permit = this.authorize_target(target, generation).await?;
                let command = if local {Command::FinishLocalHandover(permit)}
                    else if cancel { Command::CancelHandover(permit) }
                    else if let Some(token) = token { Command::CommitHandover { token, permit } }
                    else { Command::ResumeHandover(permit) };
                this.execute(command).await.map(Some)
            }.await;
            this.busy(false);
            // Completion metadata is safe to apply after focus loss. The worker
            // owns durable state even when the review/password UI was dismissed.
            match result {
                Ok(Some(reply)) => this.apply(reply),
                Ok(None) => this
                    .status
                    .set_label("Library review cancelled. Local records and keys are kept."),
                Err(failure) => this.failure(failure),
            }
        });
    }
    fn review_missing_snapshot(self: &Rc<Self>) {
        if self.busy.get() || !self.review_snapshot.is_visible() {
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        self.status.set_label("Checking the saved cloud snapshot…");
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = async {
                let Reply::SnapshotReview { token, summary } = this.execute(Command::PrepareSnapshotReview).await? else {
                    return Err(Failure::InvalidState);
                };
                if generation != this.generation.get() || !this.window.is_active() {
                    return Ok(None);
                }
                let dialog = adw::AlertDialog::builder().heading("Keep Local Records and Resume?")
                    .body(format!("The cloud library is missing {} previously known records. Keep {} local records and {} saved conflict copies, then read the cloud library again? After receiving, Send Local Changes can upload the kept records.", summary.missing_records, summary.local_records, summary.preservation_copies))
                    .build();
                dialog.add_responses(&[("cancel", "Cancel"), ("resume", "Keep Records and Resume")]);
                dialog.set_default_response(Some("cancel"));
                dialog.set_close_response("cancel");
                *this.snapshot_dialog.borrow_mut() = Some(dialog.clone());
                let response = dialog.choose_future(Some(&this.window)).await;
                this.snapshot_dialog.borrow_mut().take();
                if response != "resume" || generation != this.generation.get() || !this.window.is_active() {
                    return Ok(None);
                }
                this.execute(Command::ResumeSnapshotReview(token)).await.map(Some)
            }.await;
            this.busy(false);
            if generation != this.generation.get() {
                return;
            }
            match result {
                Ok(Some(reply)) => this.apply(reply),
                Ok(None) => this
                    .status
                    .set_label("Snapshot review cancelled. Local and cloud records are kept."),
                Err(failure) => this.failure(failure),
            }
        });
    }
    fn review_saved_deletion(self: &Rc<Self>) {
        if self.busy.get() || !self.review_deletions.is_sensitive() {
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        self.status.set_label("Checking the saved deletion…");
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = async {
                let Reply::DeletionReview {token,summary} = this.execute(Command::PrepareDeletionReview).await? else { return Err(Failure::InvalidState); };
                if generation != this.generation.get() || !this.window.is_active() { return Ok(None); }
                use crate::deletion_review::{Kind,Choice};
                let description = match summary.kind {
                    Kind::LocalAbsence=>"This snippet is missing locally. Keep it deleted and send the deletion, or restore its retained version?",
                    Kind::CloudDeletion=>"The cloud deleted this snippet. Delete it here, or keep this computer's version and upload it after receiving?",
                    Kind::PendingDeletion=>"A saved deletion is waiting to finish. Continue deleting, or restore the retained version? An earlier cloud request may already have completed; a restored version uploads after that request is resolved.",
                };
                let name=summary.name.chars().take(256).collect::<String>();
                let keyword=summary.keyword.chars().take(256).collect::<String>();
                let preservation = if summary.preserved_source_versions > 0 {
                    format!("\n\nThis decision also preserves {} held source versions as disabled conflict copies. Existing copy edits and cloud requests stay intact.", summary.preserved_source_versions)
                } else { String::new() };
                let originals = if summary.restored_conflict_copies > 0 {
                    format!("\n\nRestore {} missing conflict originals as part of this decision. Their saved versions synchronize before the source decision.", summary.restored_conflict_copies)
                } else { String::new() };
                let conflicts = if summary.preserved_conflict_copies > 0 {
                    format!("\n\nConflict originals to preserve: {}. Their contents are kept before your decision is applied.", summary.preserved_conflict_copies)
                } else { String::new() };
                let prerequisite = if summary.prerequisite { "\n\nReview this snippet first so another pending conflict decision can continue. Your choice applies only to this snippet. Review Deletion again afterward for the next decision." } else { "" };
                let body=format!("{}{}\n\n{}{}{}{}{}",name,if keyword.is_empty() {String::new()} else {format!(" · {keyword}")},description,prerequisite,preservation,originals,conflicts);
                let dialog=adw::AlertDialog::builder().heading(if summary.secure {"Review Secure Snippet Deletion"} else {"Review Snippet Deletion"}).body(body).build();
                dialog.add_responses(&[("cancel","Cancel"),("keep",if summary.kind==Kind::CloudDeletion {"Keep Local Version"} else {"Restore Retained Version"}),("delete","Confirm Deletion")]);
                dialog.set_response_enabled("keep",summary.can_keep);
                dialog.set_response_appearance("delete",adw::ResponseAppearance::Destructive);
                dialog.set_default_response(Some("cancel"));
                dialog.set_close_response("cancel");
                *this.snapshot_dialog.borrow_mut()=Some(dialog.clone());
                let response=dialog.choose_future(Some(&this.window)).await;
                this.snapshot_dialog.borrow_mut().take();
                if generation!=this.generation.get() || !this.window.is_active() {return Ok(None);}
                let choice=match response.as_str() {"delete"=>Choice::Delete,"keep" if summary.can_keep=>Choice::Keep,_=>return Ok(None)};
                let credential = if (choice == Choice::Keep && summary.keep_requires_vault)
                    || (choice == Choice::Delete && summary.delete_requires_vault) {
                    let password = gtk::PasswordEntry::builder().show_peek_icon(false).build();
                    let recovery = gtk::CheckButton::with_label("Use the vault recovery key");
                    let fields = gtk::Box::new(gtk::Orientation::Vertical, 10);
                    fields.append(&password); fields.append(&recovery);
                    let dialog = adw::AlertDialog::builder().heading(if choice == Choice::Keep { "Unlock the Vault to Restore This Snippet" } else { "Unlock the Vault to Preserve Conflict Originals" })
                        .body("Enter the matching vault's passphrase or recovery key to verify the retained snippet and its conflict originals before applying your decision.")
                        .extra_child(&fields).build();
                    dialog.add_responses(&[("cancel", "Cancel"), ("restore", if choice == Choice::Keep { "Verify and Restore" } else { "Verify and Delete" })]);
                    dialog.set_default_response(Some("cancel")); dialog.set_close_response("cancel");
                    *this.password_dialog.borrow_mut() = Some((dialog.clone(), password.clone()));
                    let response = dialog.choose_future(Some(&this.window)).await;
                    this.password_dialog.borrow_mut().take();
                    let credential = Zeroizing::new(password.text().to_string());
                    password.set_text("");
                    if response != "restore" || generation != this.generation.get() || !this.window.is_active() { return Ok(None); }
                    Some((credential, recovery.is_active()))
                } else { None };
                this.execute(Command::DecideDeletionReview {token,choice,credential}).await.map(Some)
            }.await;
            this.busy(false);
            if generation != this.generation.get() {
                return;
            }
            match result {
                Ok(Some(reply)) => this.apply(reply),
                Ok(None) => this
                    .status
                    .set_label("Deletion review cancelled. The saved state is kept."),
                Err(failure) => this.failure(failure),
            }
        });
    }
    async fn authorize_and_reveal(&self, generation: u64) -> Result<()> {
        let Reply::Target(target) = self.execute(Command::PrepareDisclosure).await? else {
            return Err(Failure::InvalidState);
        };
        let permit = self.authorize_target(target, generation).await?;
        let Reply::Disclosure(disclosure) = self.execute(Command::Reveal(permit)).await? else {
            return Err(Failure::InvalidState);
        };
        if generation != self.generation.get() || !self.window.is_active() {
            return Err(Failure::Authentication(
                crate::local_auth::Failure::Cancelled,
            ));
        }
        self.view.show(disclosure)?;
        self.recovery_panel.set_visible(true);
        Ok(())
    }
    async fn authorize_target(&self, target: Target, generation: u64) -> Result<Permit> {
        if generation != self.generation.get() || !self.window.is_active() {
            return Err(Failure::Authentication(
                crate::local_auth::Failure::Cancelled,
            ));
        }
        let witness = self
            .desktop
            .as_ref()
            .ok_or(Failure::Authentication(
                crate::local_auth::Failure::DesktopUnavailable,
            ))?
            .witness();
        let purpose = target.purpose();
        let request = self.gate.borrow_mut().begin(target, witness)?;
        *self.authorization.borrow_mut() = Some(request);
        let password = gtk::PasswordEntry::builder()
            .placeholder_text("Computer login password")
            .show_peek_icon(false)
            .build();
        password.update_property(&[gtk::accessible::Property::Label("Computer login password")]);
        let dialog = adw::AlertDialog::builder()
            .heading(match purpose {
                Purpose::RevealRecovery => "Authorize Recovery Code",
                Purpose::ReplaceRecovery => "Authorize Recovery Replacement",
                Purpose::ApprovePairing => "Authorize Device Approval",
                Purpose::SwitchLibrary => "Authorize Library Switch",
                Purpose::CancelLibrarySwitch => "Authorize Switch Cancellation",
                Purpose::FinishLocalLibrarySwitch => "Authorize Local Switch Completion",
                Purpose::RestoreSavedChanges => "Authorize Saved Changes Restoration",
                Purpose::ResumeSavedChanges => "Authorize Restoration Completion",
                Purpose::CancelSavedChanges => "Authorize Restoration Cancellation",
                Purpose::RemoveSavedHistory => "Authorize History Removal",
                Purpose::ResumeHistoryRemoval => "Authorize History Removal Completion",
                Purpose::RemoveUnusedRecoveryFiles => "Authorize Recovery File Cleanup",
                Purpose::ResumeRecoveryFileCleanup => "Authorize Recovery File Cleanup Completion",
                Purpose::RevealAccountKey => "Authorize Account Key",
            })
            .body(match purpose {
                Purpose::RevealRecovery => "Enter your computer login password to show this library's pending recovery code.",
                Purpose::ReplaceRecovery => "Enter your computer login password to replace this library's recovery code. Save a new offline copy after replacement; the previous copy no longer opens the current recovery envelope.",
                Purpose::ApprovePairing => "Enter your computer login password to approve the device whose confirmation code you checked.",
                Purpose::SwitchLibrary => "Enter your computer login password to keep local records and switch to the reviewed cloud library, or finish its saved switch. Previous library keys remain in recovery history.",
                Purpose::CancelLibrarySwitch => "Enter your computer login password to cancel a saved switch before the library changes. Local records, previous keys and the candidate key remain saved.",
                Purpose::FinishLocalLibrarySwitch => "Enter your computer login password to finish only the saved switch already started on this computer. Local changes and previous keys remain saved. Reconnect and select a library to verify access before syncing.",
                Purpose::RestoreSavedChanges => "Enter your computer login password to restore the reviewed saved changes. Current versions remain saved. Synchronization requires a separate reconnect afterward.",
                Purpose::ResumeSavedChanges => "Enter your computer login password to finish the saved restoration on this computer. Current versions remain saved.",
                Purpose::CancelSavedChanges => "Enter your computer login password to cancel a saved restoration before its file update starts. All saved versions remain available.",
                Purpose::RemoveSavedHistory => "Enter your computer login password to permanently remove the reviewed saved entry and its encrypted recovery files.",
                Purpose::ResumeHistoryRemoval => "Enter your computer login password to finish the saved removal of this history entry and its encrypted recovery files.",
                Purpose::RemoveUnusedRecoveryFiles => "Enter your computer login password to discard the reviewed encrypted recovery files that no saved history references. Their previous contents may have no other copy. Saved history, current files and active keys are kept.",
                Purpose::ResumeRecoveryFileCleanup => "Enter your computer login password to finish only the saved recovery-file cleanup. Newly created files and saved history are kept.",
                Purpose::RevealAccountKey => "Enter your computer login password to show this account's key. Anyone with the key can sign in to this account.",
            })
            .extra_child(&password)
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("authorize", "Authorize")]);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        *self.password_dialog.borrow_mut() = Some((dialog.clone(), password.clone()));
        let response = dialog.choose_future(Some(&self.window)).await;
        self.password_dialog.borrow_mut().take();
        let entered = secret(&password)?;
        if response != "authorize" || generation != self.generation.get() {
            return Err(Failure::Authentication(
                crate::local_auth::Failure::Cancelled,
            ));
        }
        let request = self
            .authorization
            .borrow_mut()
            .take()
            .ok_or(Failure::Authentication(
                crate::local_auth::Failure::Cancelled,
            ))?;
        request.check()?;
        self.status.set_label("Authorizing…");
        let password = Zeroizing::new(entered.as_bytes().to_vec());
        drop(entered);
        let Reply::Authenticated(proof) = self
            .execute(Command::Authenticate { request, password })
            .await?
        else {
            return Err(Failure::InvalidState);
        };
        let permit = self.gate.borrow_mut().accept(proof)?;
        if generation != self.generation.get() || !self.window.is_active() {
            return Err(Failure::Authentication(
                crate::local_auth::Failure::Cancelled,
            ));
        }
        Ok(permit)
    }
    fn authorize_mutation(self: &Rc<Self>) {
        if self.busy.get() || !self.mutation_authorize.is_sensitive() {
            return;
        }
        let Some(target) = self.mutation_target.borrow_mut().take() else {
            return;
        };
        if target.purpose() == Purpose::ApprovePairing && !self.mutation_matched.is_active() {
            return;
        }
        self.cancel_sensitive();
        self.busy(true);
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = match this.authorize_target(target, generation).await {
                Ok(permit) => this.execute(Command::Mutate(permit)).await,
                Err(e) => Err(e),
            };
            this.busy(false);
            if generation != this.generation.get() {
                return;
            }
            this.cancel_sensitive();
            match result {
                Ok(reply) => this.apply(reply),
                Err(e) => this.failure(e),
            }
        });
    }
    fn confirm_saved(self: &Rc<Self>) {
        if self.busy.get() || !self.recorded.is_active() {
            return;
        }
        let suffix = match secret(&self.suffix) {
            Ok(suffix) => suffix,
            Err(e) => {
                self.cancel_sensitive();
                self.failure(e);
                return;
            }
        };
        let Some(disclosure) = self.view.take() else {
            return;
        };
        self.recovery_panel.set_visible(false);
        self.recorded.set_active(false);
        self.confirm.set_sensitive(false);
        self.busy(true);
        self.status.set_label("Verifying saved code…");
        let generation = self.generation.get();
        let this = self.clone();
        glib::spawn_future_local(async move {
            let result = this.execute(Command::Confirm { disclosure, suffix }).await;
            this.busy(false);
            if generation != this.generation.get() {
                return;
            }
            this.cancel_sensitive();
            match result {
                Ok(reply) => this.apply(reply),
                Err(e) => this.failure(e),
            }
        });
    }
}

#[cfg(test)]
#[path = "account_live_tests.rs"]
pub(crate) mod live_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        cloud::{Binding, ServerURL},
        desktop::SessionWitness,
        key_store::KeyBinding,
        local_auth::{self, Purpose, Target},
    };

    fn disclosure(window: &AccountWindow) -> Disclosure {
        let target = Target::new(
            KeyBinding::new(
                ServerURL::parse("https://public.example.test").unwrap(),
                uuid::Uuid::from_u128(1),
                uuid::Uuid::from_u128(2),
                (
                    Binding::from_checkpoint([3; 32]),
                    Binding::from_checkpoint([4; 32]),
                ),
                1,
            )
            .unwrap(),
            Purpose::RevealRecovery,
            1,
            [5; 32],
        )
        .unwrap();
        window.gate.borrow_mut().set_foreground(true);
        let request = window
            .gate
            .borrow_mut()
            .begin(
                target.clone(),
                SessionWitness::test(SessionState::Unlocked, 1),
            )
            .unwrap();
        let proof = local_auth::authenticate_fixture(request).unwrap();
        let permit = window.gate.borrow_mut().accept(proof).unwrap();
        Disclosure::fixture(permit, target)
    }
    #[track_caller]
    fn settle_until(finished: impl Fn() -> bool) {
        let started = std::time::Instant::now();
        let context = glib::MainContext::default();
        while !finished() {
            assert!(started.elapsed() < Duration::from_secs(3));
            while context.pending() {
                context.iteration(false);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn press_response(dialog: &adw::AlertDialog, label: &str) {
        let mut widgets = vec![dialog.clone().upcast::<gtk::Widget>()];
        while let Some(widget) = widgets.pop() {
            if let Some(button) = widget.downcast_ref::<gtk::Button>()
                && button.label().as_deref() == Some(label)
            {
                button.emit_clicked();
                return;
            }
            let mut child = widget.first_child();
            while let Some(widget) = child {
                child = widget.next_sibling();
                widgets.push(widget);
            }
        }
        panic!("native response button is missing");
    }
    #[test]
    #[ignore = "requires a graphical display; synthetic worker, no keyring/PAM/network"]
    fn native_automatic_toggle_remains_available_during_account_work() {
        adw::init().expect("graphical display");
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.AutomaticSmoke")
            .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application
            .register(None::<&gtk::gio::Cancellable>)
            .unwrap();
        let parent = adw::ApplicationWindow::builder()
            .application(&application)
            .build();
        let worker = Rc::new(Handle::controlled(|command| match command {
            Command::Automatic(enabled) => (
                Ok(Reply::Automatic(crate::account_worker::Automatic {
                    enabled,
                    status: if enabled {
                        AutomaticStatus::Scheduled
                    } else {
                        AutomaticStatus::Off
                    },
                    failure: None,
                })),
                false,
            ),
            _ => (Err(Failure::InvalidState), false),
        }));
        let window =
            AccountWindow::with_worker(&application, &parent, worker.clone(), None).unwrap();
        window.update_automatic();
        assert!(!window.automatic_button.is_sensitive());
        window.library_panel.set_sensitive(true);
        window.sync.set_sensitive(true);
        window.update_automatic();
        window.automatic_button.emit_clicked();
        settle_until(|| !window.automatic_pending.get());
        assert!(worker.automatic().enabled);
        window.busy(true);
        window.update_automatic();
        assert!(!window.panel.is_sensitive());
        assert!(window.automatic_button.is_sensitive());
        window.automatic_button.emit_clicked();
        settle_until(|| !window.automatic_pending.get());
        assert!(!worker.automatic().enabled);
        assert!(!window.automatic_button.is_sensitive());
        assert!(worker.prepare_quit());
        window.window.close();
        parent.close();
    }
    #[test]
    #[ignore = "requires a graphical display on the host bus; synthetic worker and authorization, no real keyring/PAM/network"]
    fn native_account_cancellation_revokes_drawn_code_and_clears_secret_entries() {
        adw::init().expect("graphical display");
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.AccountSmoke")
            .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application
            .register(None::<&gtk::gio::Cancellable>)
            .unwrap();
        let parent = adw::ApplicationWindow::builder()
            .application(&application)
            .title("Public account fixture")
            .build();
        parent.present();
        settle_until(|| parent.is_active());
        let window =
            AccountWindow::with_worker(&application, &parent, Handle::fixture(), None).unwrap();
        window.present();
        settle_until(|| !window.busy.get());
        assert!(window.pages.visible_child_name().as_deref() == Some("login"));
        assert!(!window.library_panel.is_sensitive());
        assert!(!window.sync.is_sensitive());
        settle_until(|| window.window.is_active());
        window.history.emit_clicked();
        settle_until(|| window.history_dialog.borrow().is_some());
        assert_eq!(
            window.history_dialog.borrow().as_ref().unwrap().title(),
            "Library Recovery History"
        );
        assert!(!window.library_panel.is_sensitive() && !window.sync.is_sensitive());
        window.cancel_sensitive();
        assert!(window.history_dialog.borrow().is_none());
        window.apply(Reply::Selected {
            role: Role::Owner,
            can_create_new: Ok(false),
            keys: Err(key_store::Failure::ReviewRequired),
            pairing: Ok(None),
            mutation: Ok(None),
            switching: handover::Status::default(),
            pending_matches: false,
            candidate: Ok(None),
            bootstrap: Ok(None),
        });
        assert!(window.switch_panel.is_visible() && window.switch_review.is_sensitive());
        assert!(!window.library_panel.is_sensitive() && !window.sync.is_sensitive());
        window
            .switch_recovery
            .set_text("Public candidate recovery fixture");
        window.cancel_sensitive();
        assert!(window.switch_recovery.text().is_empty());
        let pending = handover::Status {
            pending: true,
            retained_libraries: 1,
            summary: Some(crate::account_review::Summary {
                local_records: 1,
                local_intents: 1,
                preservation_copies: 0,
                previous_confirmations: 1,
            }),
        };
        window.set_switching(pending, false, false);
        assert!(window.switch_cancel.is_sensitive() && !window.switch_resume.is_sensitive());
        assert!(window.switch_local.is_visible() && window.switch_local.is_sensitive());
        assert!(!window.switch_review.is_visible() && !window.switch_recovery.is_visible());
        window.set_switching(pending, false, true);
        assert!(window.switch_resume.is_sensitive() && !window.library_panel.is_sensitive());
        window.apply(Reply::Handover {
            switching: handover::Status {
                pending: false,
                ..pending
            },
            keys: Some(Outcome::Ready {
                kit: KitStatus::None,
            }),
            role: Some(Role::Writer),
            cancelled: false,
            failure: None,
            pending_matches: false,
        });
        assert!(
            !window.switch_panel.is_visible()
                && window.library_panel.is_sensitive()
                && window.sync.is_sensitive()
        );
        window.review_deletions.emit_clicked();
        settle_until(|| window.snapshot_dialog.borrow().is_some());
        let dialog = window.snapshot_dialog.borrow().as_ref().unwrap().clone();
        press_response(&dialog, "Restore Retained Version");
        settle_until(|| window.password_dialog.borrow().is_some());
        let (_, password) = window.password_dialog.borrow().as_ref().unwrap().clone();
        password.set_text("Public cancelled vault fixture");
        window.cancel_sensitive();
        settle_until(|| !window.busy.get());
        assert!(password.text().is_empty() && window.password_dialog.borrow().is_none());
        window.review_deletions.emit_clicked();
        settle_until(|| window.snapshot_dialog.borrow().is_some());
        let dialog = window.snapshot_dialog.borrow().as_ref().unwrap().clone();
        press_response(&dialog, "Restore Retained Version");
        settle_until(|| window.password_dialog.borrow().is_some());
        let (dialog, password) = window.password_dialog.borrow().as_ref().unwrap().clone();
        password.set_text("Public vault passphrase fixture");
        press_response(&dialog, "Verify and Restore");
        settle_until(|| !window.busy.get());
        assert!(password.text().is_empty() && window.password_dialog.borrow().is_none());
        assert!(
            window
                .status
                .label()
                .starts_with("Retained version restored")
        );
        window.review_deletions.emit_clicked();
        settle_until(|| window.snapshot_dialog.borrow().is_some());
        let dialog = window.snapshot_dialog.borrow().as_ref().unwrap().clone();
        press_response(&dialog, "Confirm Deletion");
        settle_until(|| window.password_dialog.borrow().is_some());
        let (dialog, password) = window.password_dialog.borrow().as_ref().unwrap().clone();
        password.set_text("Public vault passphrase fixture");
        press_response(&dialog, "Verify and Delete");
        settle_until(|| !window.busy.get());
        assert!(password.text().is_empty() && window.password_dialog.borrow().is_none());
        assert!(window.status.label().starts_with("Deletion saved"));
        window.apply(Reply::LocalHandover {
            switching: handover::Status {
                pending: false,
                ..pending
            },
            failure: None,
        });
        assert!(window.selected_role.get().is_none());
        assert_eq!(window.libraries.selected(), gtk::INVALID_LIST_POSITION);
        assert!(!window.library_panel.is_sensitive() && !window.sync.is_sensitive());
        assert!(!window.send.is_sensitive() && !window.receive.is_sensitive());
        assert!(!window.create.is_sensitive() && !window.switch_local.is_visible());
        window.apply(Reply::LocalHandover {
            switching: pending,
            failure: Some(Failure::InvalidState),
        });
        assert!(window.switch_local.is_sensitive() && !window.switch_resume.is_sensitive());
        assert!(!window.library_panel.is_sensitive() && !window.sync.is_sensitive());
        window.apply(Reply::Handover {
            switching: pending,
            keys: None,
            role: Some(Role::Writer),
            cancelled: false,
            failure: Some(Failure::Secret(crate::secret_store::Failure::Unavailable)),
            pending_matches: true,
        });
        assert!(window.switch_panel.is_visible() && window.switch_resume.is_sensitive());
        assert!(!window.sync.is_sensitive() && !window.library_panel.is_sensitive());
        window.set_switching(handover::Status::default(), false, false);
        window.selected_role.set(None);
        window.set_creation(Ok(creation::State::Available));
        assert!(window.create.is_sensitive());
        window.apply(Reply::CreationFailed {
            state: Ok(creation::State::Requested),
            can_create_new: Ok(false),
            failure: Failure::Cloud(crate::cloud::Failure::Network),
        });
        assert!(window.create.label().as_deref() == Some("Resume Library Creation"));
        window.set_creation(Ok(creation::State::ExistingLibrary));
        assert!(!window.create.is_sensitive());
        window.set_new_creation(Ok(true));
        assert!(window.create_another.is_visible() && window.create_another.is_sensitive());
        window.set_switching(pending, false, false);
        assert!(!window.create_another.is_sensitive());
        window.set_switching(handover::Status::default(), false, false);
        window.set_new_creation(Ok(false));
        assert!(!window.create_another.is_sensitive());
        window.set_pairing(Ok(Some(RetainedStatus::Creating)), None);
        assert!(window.pairing_panel.is_visible() && !window.pairing_check.is_sensitive());
        assert!(!window.pair.is_sensitive());
        let draft = crate::bootstrap::PairingDraft::generate().unwrap();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let invitation = Invitation::new(
            ServerURL::parse("https://public.example.test").unwrap(),
            uuid::Uuid::from_u128(1),
            uuid::Uuid::from_u128(2),
            *draft.nonce(),
            *draft.public_key(),
            now + 300,
            now,
        )
        .unwrap();
        window.selected_role.set(Some(Role::Writer));
        window.set_switching(handover::Status::default(), true, false);
        window.set_bootstrap(Ok(None), None);
        assert!(!window.bootstrap_create.is_sensitive());
        window.selected_role.set(Some(Role::Owner));
        window.set_switching(handover::Status::default(), true, false);
        window.set_bootstrap(Ok(None), None);
        assert!(window.bootstrap_create.is_sensitive() && !window.sync.is_sensitive());
        window.set_candidate_pairing(Ok(None), None);
        window.apply(Reply::BootstrapCandidate {
            state: Ok(Some(initial_candidate::Status::Sent)),
            candidate: Ok(None),
            failure: Some(Failure::Cloud(crate::cloud::Failure::Network)),
        });
        assert!(window.bootstrap_create.is_sensitive() && !window.candidate_pair.is_sensitive());
        assert!(
            window.bootstrap_create.label().as_deref() == Some("Resume Selected Library Key Setup")
        );
        window.apply(Reply::BootstrapCandidate {
            state: Ok(Some(initial_candidate::Status::Lost)),
            candidate: Ok(None),
            failure: None,
        });
        assert!(
            window.candidate_pair.is_sensitive(),
            "A losing first-key candidate must allow requesting the winning key"
        );
        assert!(!window.bootstrap_create.is_sensitive() && !window.sync.is_sensitive());
        assert!(!window.library_panel.is_sensitive() && window.switch_review.is_sensitive());
        for role in [Role::Writer, Role::Reader] {
            window.selected_role.set(Some(role));
            window.apply(Reply::BootstrapCandidate {
                state: Ok(Some(initial_candidate::Status::Sent)),
                candidate: Ok(None),
                failure: None,
            });
            assert!(!window.candidate_pair.is_sensitive());
            window.apply(Reply::BootstrapCandidate {
                state: Ok(Some(initial_candidate::Status::Lost)),
                candidate: Ok(None),
                failure: None,
            });
            assert_eq!(window.candidate_pair.is_sensitive(), role == Role::Writer);
            assert!(!window.sync.is_sensitive() && !window.library_panel.is_sensitive());
        }
        window.selected_role.set(Some(Role::Owner));
        window.apply(Reply::BootstrapCandidate {
            state: Ok(Some(initial_candidate::Status::Lost)),
            candidate: Ok(Some(candidate::Status::Waiting {
                invitation: invitation.clone(),
                received: false,
            })),
            failure: None,
        });
        assert!(window.candidate_panel.is_visible() && !window.candidate_pair.is_sensitive());
        window.apply(Reply::BootstrapCandidate {
            state: Ok(Some(initial_candidate::Status::Lost)),
            candidate: Err(key_store::Failure::InvalidState),
            failure: None,
        });
        assert!(!window.candidate_pair.is_sensitive());
        window.set_candidate_pairing(Ok(None), None);
        window.set_bootstrap(
            Ok(Some(initial_candidate::Status::Ready {
                kit: KitStatus::AwaitingPresentation,
            })),
            None,
        );
        assert!(!window.bootstrap_create.is_sensitive() && window.switch_review.is_sensitive());
        assert!(!window.library_panel.is_sensitive() && !window.sync.is_sensitive());
        window.set_switching(handover::Status::default(), true, false);
        window.selected_role.set(Some(Role::Writer));
        window.set_candidate_pairing(Ok(None), None);
        assert!(window.candidate_pair.is_sensitive());
        window.set_candidate_pairing(
            Ok(Some(candidate::Status::Waiting {
                invitation: invitation.clone(),
                received: false,
            })),
            None,
        );
        assert!(window.candidate_panel.is_visible() && window.candidate_copy.is_sensitive());
        assert!(!window.sync.is_sensitive() && !window.library_panel.is_sensitive());
        let candidate_remaining = window.candidate_view.remaining();
        window.set_candidate_pairing(
            Ok(Some(candidate::Status::Waiting {
                invitation: invitation.clone(),
                received: false,
            })),
            Some(Failure::Cloud(crate::cloud::Failure::Network)),
        );
        assert!(
            !window.candidate_poll.get()
                && window.candidate_view.remaining() <= candidate_remaining
        );
        window.set_candidate_pairing(
            Ok(Some(candidate::Status::Waiting {
                invitation: invitation.clone(),
                received: true,
            })),
            None,
        );
        assert!(!window.candidate_cancel.is_sensitive() && !window.candidate_copy.is_sensitive());
        assert!(window.candidate_check.label().as_deref() == Some("Finish Key Verification"));
        window.set_candidate_pairing(Ok(Some(candidate::Status::Ready)), None);
        assert!(window.switch_review.is_sensitive() && !window.sync.is_sensitive());
        assert!(
            !window.candidate_panel.is_visible() && window.candidate_view.value.borrow().is_none()
        );
        window.selected_role.set(Some(Role::Reader));
        window.set_candidate_pairing(Ok(None), None);
        assert!(!window.candidate_pair.is_sensitive());
        // A selected-library reply restores the current-library controls before
        // applying its pairing state; leave the previous candidate review first.
        window.apply_library(Ok(Outcome::NeedsTrustedDeviceOrRecovery));
        window.set_switching(handover::Status::default(), false, false);
        window.set_pairing(
            Ok(Some(RetainedStatus::Waiting {
                invitation: invitation.clone(),
                received: false,
            })),
            None,
        );
        assert!(
            window.pairing_view.remaining().as_secs() > 0 && window.pairing_copy.is_sensitive()
        );
        assert!(
            window
                .pairing_code
                .label()
                .contains(&invitation.confirmation_code())
        );
        let previous = window.pairing_view.remaining();
        window.set_pairing(
            Ok(Some(RetainedStatus::Waiting {
                invitation: invitation.clone(),
                received: false,
            })),
            Some(Failure::Cloud(crate::cloud::Failure::Network)),
        );
        assert!(!window.pairing_poll.get() && window.pairing_view.remaining() <= previous);
        window.set_pairing(
            Ok(Some(RetainedStatus::Waiting {
                invitation,
                received: true,
            })),
            None,
        );
        assert!(!window.pairing_cancel.is_sensitive() && !window.pairing_copy.is_sensitive());
        assert!(window.pairing_check.label().as_deref() == Some("Finish Key Installation"));
        window.apply_library(Ok(Outcome::Ready {
            kit: KitStatus::None,
        }));
        assert!(window.sync.is_sensitive());
        assert!(!window.pairing_panel.is_visible() && window.pairing_view.value.borrow().is_none());
        window.selected_role.set(Some(Role::Writer));
        window.set_mutation(Ok(None));
        assert!(window.approval_prepare.is_sensitive() && !window.replace_recovery.is_sensitive());
        window.set_mutation(Ok(Some(mutations::Retained {
            kind: mutations::Kind::Approval,
            step: mutations::Step::Prepared,
            confirmation_code: Some("PUBLIC123".into()),
        })));
        assert!(window.mutation_panel.is_visible() && window.mutation_cancel.is_sensitive());
        assert!(
            !window.approval_prepare.is_sensitive() && !window.mutation_reconcile.is_sensitive()
        );
        let target = Target::new(
            KeyBinding::new(
                ServerURL::parse("https://public.example.test").unwrap(),
                uuid::Uuid::from_u128(1),
                uuid::Uuid::from_u128(2),
                (
                    Binding::from_checkpoint([3; 32]),
                    Binding::from_checkpoint([4; 32]),
                ),
                1,
            )
            .unwrap(),
            Purpose::ApprovePairing,
            1,
            [5; 32],
        )
        .unwrap();
        *window.mutation_target.borrow_mut() = Some(target);
        window.update_mutation_authorize();
        assert!(!window.mutation_authorize.is_sensitive());
        window.mutation_matched.set_active(true);
        assert!(window.mutation_authorize.is_sensitive());
        window.cancel_sensitive();
        assert!(
            !window.mutation_matched.is_active()
                && !window.mutation_authorize.is_sensitive()
                && window.mutation_target.borrow().is_none()
        );
        for step in [mutations::Step::Signed, mutations::Step::Acknowledged] {
            window.set_mutation(Ok(Some(mutations::Retained {
                kind: mutations::Kind::Approval,
                step,
                confirmation_code: Some("PUBLIC123".into()),
            })));
            assert!(
                !window.mutation_cancel.is_sensitive() && window.mutation_reconcile.is_sensitive()
            );
            assert!(window.mutation_resume.is_sensitive() == (step == mutations::Step::Signed));
        }
        window.set_mutation(Err(key_store::Failure::ReviewRequired));
        assert!(!window.approval_prepare.is_sensitive() && !window.replace_recovery.is_sensitive());
        window.view.show(disclosure(&window)).unwrap();
        window.recovery_panel.set_visible(true);
        window.suffix.set_text("12345678");
        window
            .account_key_input
            .set_text("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7");
        window
            .recovery_input
            .set_text("public fixture recovery input");
        window
            .switch_recovery
            .set_text("public switch recovery input");
        let held = window.view.take().unwrap();
        window.cancel_sensitive();
        assert!(held.long_code().is_err() && held.qr_payload().is_err());
        assert!(
            window.suffix.text().is_empty()
                && window.account_key_input.text().is_empty()
                && window.recovery_input.text().is_empty()
                && window.switch_recovery.text().is_empty()
        );
        assert!(!window.recovery_panel.is_visible() && !window.view.visible());
        window.view.show(disclosure(&window)).unwrap();
        window.recovery_panel.set_visible(true);
        window.window.close();
        assert!(!window.window.is_visible() && !window.view.visible());
        assert!(window.worker.can_quit());
        window.window.destroy();
        parent.destroy();
        let context = glib::MainContext::default();
        while context.pending() {
            context.iteration(false);
        }
    }
    #[test]
    #[ignore = "requires a graphical display; synthetic worker and authorization, public ADR test key, no keyring/PAM/network"]
    fn native_account_key_screens_validate_locally_require_acknowledgement_and_clear() {
        use std::sync::{Arc, Mutex};
        const KEY: &str = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7";
        const DISPLAY: &str = "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7";
        adw::init().expect("graphical display");
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.AccountKeySmoke")
            .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application
            .register(None::<&gtk::gio::Cancellable>)
            .unwrap();
        let parent = adw::ApplicationWindow::builder()
            .application(&application)
            .title("Public account-key fixture")
            .build();
        let sent = Arc::new(Mutex::new(Vec::<&'static str>::new()));
        let observed = sent.clone();
        let profile = |account: Option<&str>| Reply::Profile {
            account: account.map(Into::into),
            server: Some(ServerURL::parse("https://public.example.test").unwrap()),
            interrupted: false,
            switching: handover::Status::default(),
            device: None,
        };
        let worker = Rc::new(Handle::controlled(move |command| {
            let reply = match command {
                Command::Inspect => Ok(profile(None)),
                Command::SignIn { server, key } => {
                    assert!(server.as_str() == "https://public.example.test");
                    assert!(key.canonical() == KEY);
                    observed.lock().unwrap().push("sign-in");
                    Err(Failure::Cloud(crate::cloud::Failure::Server {
                        code: crate::cloud::ErrorCode::InvalidAccountKey,
                        retry_after: None,
                    }))
                }
                Command::SignOut => {
                    observed.lock().unwrap().push("sign-out");
                    Ok(profile(None))
                }
                _ => Err(Failure::InvalidState),
            };
            (reply, false)
        }));
        let window = AccountWindow::with_worker(&application, &parent, worker, None).unwrap();
        window.present();
        settle_until(|| !window.busy.get());
        assert!(window.pages.visible_child_name().as_deref() == Some("login"));
        assert!(!window.account_panel.is_visible() && !window.key_panel.is_visible());
        // A local typing error stays in the field and is never sent.
        window.pages.set_visible_child_name("account-key");
        window
            .account_key_input
            .set_text("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ8");
        window.sign_in();
        assert!(window.status.label() == "This isn't a valid account key. Check it for typos.");
        assert!(window.account_key_input.text() == "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ8");
        assert!(sent.lock().unwrap().is_empty());
        // Valid input is normalized locally; the refusal has its own copy.
        window
            .account_key_input
            .set_text(" 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-IAQ7 ");
        window.sign_in();
        settle_until(|| !window.busy.get());
        assert!(
            window.status.label() == "That account key wasn't accepted. Check it and try again."
        );
        assert!(window.account_key_input.text().is_empty());
        assert!(*sent.lock().unwrap() == ["sign-in"]);
        // A created key blocks every continuation until explicitly acknowledged.
        window.apply(Reply::AccountCreated {
            key: AccountKey::from_canonical(KEY).unwrap(),
            next: Some(Box::new(profile(Some("1A2B-3C4D")))),
            failure: None,
        });
        assert!(window.key_panel.is_visible() && !window.pages.is_visible());
        assert!(window.key_label.label() == DISPLAY && window.key_label.is_selectable());
        assert!(window.key_label.has_css_class("monospace"));
        assert!(window.key_title.label() == "Save Your Account Key");
        assert!(window.key_message.label() == CREATED_KEY_MESSAGE);
        assert!(window.key_done.label().as_deref() == Some("I've Saved It"));
        assert!(!window.sign_out.is_visible() && !window.account_panel.is_visible());
        // Focus-loss cancellation keeps it for a password manager; quit/close do not.
        window.cancel_sensitive();
        assert!(window.created_key_visible() && window.key_label.label() == DISPLAY);
        window.present();
        assert!(window.created_key_visible() && !window.busy.get());
        window.key_done.emit_clicked();
        assert!(!window.key_panel.is_visible() && window.key_label.label().is_empty());
        assert!(window.pages.is_visible());
        assert!(window.pages.visible_child_name().as_deref() == Some("saved"));
        assert!(window.account_panel.is_visible() && window.sign_out.is_visible());
        assert!(window.account_id.label() == "Account ID: 1A2B-3C4D");
        window.apply(Reply::AccountCreated {
            key: AccountKey::from_canonical(KEY).unwrap(),
            next: None,
            failure: Some(Failure::Cloud(crate::cloud::Failure::Network)),
        });
        assert!(window.created_key_visible());
        window.window.close();
        assert!(!window.created_key_visible() && window.key_label.label().is_empty());
        assert!(window.status.label() == "The server could not be reached. Try again.");
        window.window.present();
        // A disclosed key is readable only while its authorization lease lasts.
        window.gate.borrow_mut().set_foreground(true);
        let target = Target::account_key(1, [7; 32]).unwrap();
        let request = window
            .gate
            .borrow_mut()
            .begin(
                target.clone(),
                SessionWitness::test(SessionState::Unlocked, 1),
            )
            .unwrap();
        let permit = window
            .gate
            .borrow_mut()
            .accept(local_auth::authenticate_fixture(request).unwrap())
            .unwrap();
        window
            .show_disclosed_key(AccountKeyDisclosure::fixture(permit, &target, KEY))
            .unwrap();
        assert!(window.key_panel.is_visible() && window.key_label.label() == DISPLAY);
        assert!(window.key_done.label().as_deref() == Some("Hide Key"));
        window.cancel_sensitive();
        assert!(!window.key_panel.is_visible() && window.key_label.label().is_empty());
        // Sign-out asks first, defaults to Cancel and names the account key.
        window.set_account(Some("1A2B-3C4D".into()));
        window.sign_out.set_visible(true);
        window.sign_out.emit_clicked();
        settle_until(|| window.sign_out_dialog.borrow().is_some());
        let dialog = window.sign_out_dialog.borrow().as_ref().unwrap().clone();
        assert!(
            dialog
                .body()
                .contains("You'll need your account key to sign in again.")
        );
        assert!(dialog.default_response().as_deref() == Some("cancel"));
        press_response(&dialog, "Cancel");
        settle_until(|| window.sign_out_dialog.borrow().is_none());
        assert!(*sent.lock().unwrap() == ["sign-in"]);
        window.sign_out.emit_clicked();
        settle_until(|| window.sign_out_dialog.borrow().is_some());
        let dialog = window.sign_out_dialog.borrow().as_ref().unwrap().clone();
        press_response(&dialog, "Sign Out");
        settle_until(|| sent.lock().unwrap().len() == 2 && !window.busy.get());
        assert!(*sent.lock().unwrap() == ["sign-in", "sign-out"]);
        assert!(!window.account_panel.is_visible() && !window.sign_out.is_visible());
        assert!(window.worker.can_quit());
        window.window.destroy();
        parent.destroy();
        let context = glib::MainContext::default();
        while context.pending() {
            context.iteration(false);
        }
    }
    #[test]
    #[ignore = "requires a graphical display; synthetic worker, public fictional request, no keyring/PAM/network"]
    fn native_device_sign_in_shows_public_request_polls_and_hands_off_to_the_library() {
        use crate::auth_store::device::Status;
        use std::sync::{Arc, Mutex};
        adw::init().expect("graphical display");
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.DeviceSignInSmoke")
            .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application
            .register(None::<&gtk::gio::Cancellable>)
            .unwrap();
        let parent = adw::ApplicationWindow::builder()
            .application(&application)
            .title("Public device sign-in fixture")
            .build();
        let draft = crate::bootstrap::PairingDraft::generate().unwrap();
        let now = chrono::Utc::now().timestamp();
        let request = crate::bootstrap::DeviceSignIn::new(
            ServerURL::parse("https://public.example.test").unwrap(),
            uuid::Uuid::from_u128(0x7a6b5c4d),
            *draft.nonce(),
            *draft.public_key(),
            now + 600,
            now,
        )
        .unwrap();
        let code = request.confirmation_code();
        let sent = Arc::new(Mutex::new(Vec::<&'static str>::new()));
        let observed = sent.clone();
        let shown = request.clone();
        let worker = Rc::new(Handle::controlled(move |command| {
            let waiting = |retry_after, failure| Reply::DeviceSignIn {
                state: Some(Status::Waiting(shown.clone())),
                retry_after,
                failure,
            };
            let reply = match command {
                Command::Inspect => Ok(Reply::Profile {
                    account: None,
                    server: Some(ServerURL::parse("https://public.example.test").unwrap()),
                    interrupted: false,
                    switching: handover::Status::default(),
                    device: None,
                }),
                Command::BeginDeviceSignIn { server } => {
                    assert!(server.as_str() == "https://public.example.test");
                    observed.lock().unwrap().push("begin");
                    Ok(waiting(None, None))
                }
                Command::CheckDeviceSignIn => {
                    let mut calls = observed.lock().unwrap();
                    calls.push("check");
                    if calls.iter().filter(|c| **c == "check").count() == 1 {
                        Ok(waiting(
                            Some(30),
                            Some(Failure::Cloud(crate::cloud::Failure::Server {
                                code: crate::cloud::ErrorCode::RateLimited,
                                retry_after: Some(30),
                            })),
                        ))
                    } else {
                        let space = |id: u128| -> crate::cloud::Space {
                            serde_json::from_value(serde_json::json!({
                                "scope":{"serverInstanceId":uuid::Uuid::from_u128(1),"spaceId":uuid::Uuid::from_u128(id),
                                    "scopeBinding":"public-device-fixture-membership-binding",
                                    "datasetGeneration":uuid::Uuid::from_u128(3),"feedEpoch":uuid::Uuid::from_u128(4)},
                                "role":"writer","keyEpoch":1
                            }))
                            .unwrap()
                        };
                        Ok(Reply::DeviceSignedIn {
                            libraries: Box::new(Reply::Libraries {
                                account: "0F1E-2D3C".into(),
                                server: ServerURL::parse("https://public.example.test").unwrap(),
                                spaces: vec![space(10), space(20)],
                                creation: Ok(creation::State::ExistingLibrary),
                                can_create_new: Ok(false),
                                created: None,
                                switching: handover::Status::default(),
                            }),
                            library: Some(uuid::Uuid::from_u128(20)),
                            selected: None,
                            keys: Some(Ok(Outcome::Ready {
                                kit: KitStatus::None,
                            })),
                            failure: None,
                        })
                    }
                }
                Command::PrepareAccountKeyDisclosure => Err(Failure::Account(
                    crate::auth_store::Failure::AccountKeyUnavailable,
                )),
                Command::PrepareApproval(_) => {
                    observed.lock().unwrap().push("pairing-approval");
                    Err(Failure::InvalidState)
                }
                Command::Select(_) => {
                    observed.lock().unwrap().push("select");
                    Err(Failure::InvalidState)
                }
                _ => Err(Failure::InvalidState),
            };
            (reply, false)
        }));
        let window = AccountWindow::with_worker(&application, &parent, worker, None).unwrap();
        window.present();
        settle_until(|| !window.busy.get());
        // Sign In with Another Device: public request, its code and polling.
        let button = {
            let mut found = None;
            let mut widgets = vec![window.pages.clone().upcast::<gtk::Widget>()];
            while let Some(widget) = widgets.pop() {
                if let Some(button) = widget.downcast_ref::<gtk::Button>()
                    && button.label().as_deref() == Some("Sign In with Another Device")
                {
                    found = Some(button.clone());
                }
                let mut child = widget.first_child();
                while let Some(widget) = child {
                    child = widget.next_sibling();
                    widgets.push(widget);
                }
            }
            found.expect("signed-out device sign-in action")
        };
        button.emit_clicked();
        settle_until(|| !window.busy.get() && !sent.lock().unwrap().is_empty());
        assert!(window.pages.visible_child_name().as_deref() == Some("device"));
        assert!(window.device_code.label() == format!("Confirmation code: {code}"));
        assert!(window.device_code.is_selectable());
        assert!(window.device_copy.is_sensitive() && window.device_poll.get());
        assert!(!window.device_view.remaining().is_zero());
        // The displayed payload is the public request only.
        let payload = window
            .device_view
            .value
            .borrow()
            .as_ref()
            .map(|v| String::from_utf8(v.payload.clone()).unwrap())
            .unwrap();
        assert!(payload.contains("snippets-device-sign-in") && !payload.contains("sn_d_"));
        // A rate-limited poll keeps the request and waits for Retry-After.
        window.run(Command::CheckDeviceSignIn);
        settle_until(|| !window.busy.get());
        assert!(window.device_poll.get() && window.device_view.value.borrow().is_some());
        assert!(!window.device_view.poll_due());
        // Approval hands off to the selected library without a chooser.
        window.run(Command::CheckDeviceSignIn);
        settle_until(|| !window.busy.get());
        assert!(window.pages.visible_child_name().as_deref() == Some("libraries"));
        // The worker-selected library follows the placeholder row; showing it
        // does not ask the worker to select again.
        assert_eq!(window.libraries.selected(), 2);
        assert!(!sent.lock().unwrap().contains(&"select"));
        assert!(!window.device_poll.get() && window.device_view.value.borrow().is_none());
        assert!(
            window
                .status
                .label()
                .starts_with("Signed in with another device")
        );
        assert!(window.account_id.label() == "Account ID: 0F1E-2D3C");
        // This device cannot show the account key.
        window.show_key.emit_clicked();
        settle_until(|| !window.busy.get());
        assert!(
            window.status.label()
                == "This device was signed in by another device. View the account key on a device that has it."
        );
        // Approving side: a request for another server is refused before any
        // network call; a pairing invitation keeps the existing review path.
        let foreign = crate::bootstrap::DeviceSignIn::new(
            ServerURL::parse("https://foreign.example.test").unwrap(),
            uuid::Uuid::from_u128(5),
            *draft.nonce(),
            *draft.public_key(),
            now + 600,
            now,
        )
        .unwrap();
        let before = sent.lock().unwrap().len();
        window.review_added_device(Zeroizing::new(
            String::from_utf8(foreign.encode_qr().unwrap().to_vec()).unwrap(),
        ));
        assert!(
            window
                .status
                .label()
                .starts_with("This sign-in request is invalid")
        );
        // Without a session monitor the confirmation dialog is never offered.
        window.review_added_device(Zeroizing::new(payload));
        assert!(window.snapshot_dialog.borrow().is_none());
        assert!(window.status.label() == "Unlock the desktop before authorizing this action.");
        assert_eq!(sent.lock().unwrap().len(), before);
        let invitation = Invitation::new(
            ServerURL::parse("https://public.example.test").unwrap(),
            uuid::Uuid::from_u128(1),
            uuid::Uuid::from_u128(2),
            *draft.nonce(),
            *draft.public_key(),
            now + 300,
            now,
        )
        .unwrap();
        window.review_added_device(Zeroizing::new(
            String::from_utf8(invitation.encode_qr().unwrap().to_vec()).unwrap(),
        ));
        settle_until(|| !window.busy.get() && sent.lock().unwrap().len() > before);
        assert!(sent.lock().unwrap().last() == Some(&"pairing-approval"));
        assert!(window.worker.can_quit());
        window.window.destroy();
        parent.destroy();
        let context = glib::MainContext::default();
        while context.pending() {
            context.iteration(false);
        }
    }
}
