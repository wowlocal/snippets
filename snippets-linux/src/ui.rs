//! Native GTK/libadwaita UI. Mutable library state stays on the GTK thread.
use crate::{
    account_ui::AccountWindow,
    account_worker::Handle as AccountWorker,
    auto_sync::Wake,
    backup_ui::Export as BackupExport,
    desktop::{self, PasteTarget},
    model::{self, Error, Library, Snippet},
    placeholders,
    primary::Readiness,
    secure_ui::Workspace,
};
use adw::prelude::*;
use clap::Parser;
use gtk::{gdk, gio, glib};
use std::{
    cell::{Cell, RefCell},
    rc::{Rc, Weak},
    time::Duration,
};
#[path = "clipboard_history_ui.rs"]
mod history;
#[path = "inline_ui.rs"]
mod inline;

pub(crate) fn internal_clipboard_provider(text: &str) -> gdk::ContentProvider {
    gdk::ContentProvider::new_union(&[
        gdk::ContentProvider::for_value(&text.to_value()),
        gdk::ContentProvider::for_bytes(
            "application/x-snippets-clipboard-history",
            &glib::Bytes::from_static(b"1"),
        ),
    ])
}

#[derive(Parser)]
#[command(
    name = "snippets",
    version,
    about = "Native Snippets desktop app for Omarchy"
)]
struct Options {
    #[arg(long, conflicts_with_all = ["new", "capture", "quit"])]
    picker: bool,
    #[arg(long, conflicts_with_all = ["capture", "quit"])]
    new: bool,
    #[arg(long, conflicts_with = "quit")]
    capture: bool,
    #[arg(long = "clipboard-history", conflicts_with_all = ["picker", "new", "capture", "quit"])]
    history: bool,
    #[arg(long)]
    quit: bool,
}
struct App {
    application: adw::Application,
    library: RefCell<Library>,
    recovery_required: Cell<bool>,
    main: RefCell<Option<Rc<MainWindow>>>,
    picker: RefCell<Option<Rc<Picker>>>,
    secure: RefCell<Option<Rc<Workspace>>>,
    account: RefCell<Option<Rc<AccountWindow>>>,
    account_worker: RefCell<Option<Rc<AccountWorker>>>,
    backup: RefCell<Option<Rc<BackupExport>>>,
    history: RefCell<Option<Rc<history::Service>>>,
    inline: RefCell<Option<Rc<inline::Service>>>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    copy_serial: Cell<u64>,
    css: gtk::CssProvider,
    last_theme: RefCell<String>,
}
fn label(text: &str, class: &str) -> gtk::Label {
    let widget = gtk::Label::new(Some(text));
    widget.set_xalign(0.0);
    if !class.is_empty() {
        widget.add_css_class(class);
    }
    widget
}
fn button(icon: &str, tooltip: &str) -> gtk::Button {
    let widget = gtk::Button::from_icon_name(icon);
    widget.set_tooltip_text(Some(tooltip));
    widget.update_property(&[gtk::accessible::Property::Label(tooltip)]);
    widget
}
fn scrolled(child: &impl IsA<gtk::Widget>) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .child(child)
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build()
}
fn clear_rows(rows: &gtk::ListBox) {
    while let Some(child) = rows.first_child() {
        rows.remove(&child);
    }
}
fn row(snippet: &Snippet, secure: bool) -> gtk::ListBoxRow {
    let content = gtk::Box::new(gtk::Orientation::Vertical, 4);
    content.set_margin_start(16);
    content.set_margin_end(16);
    content.set_margin_top(12);
    content.set_margin_bottom(12);
    let title = label(
        &format!(
            "{}{}{}",
            if secure { "🔒  " } else { "" },
            if snippet.is_pinned { "★  " } else { "" },
            snippet.display_name()
        ),
        "heading",
    );
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    content.append(&title);
    let subtitle = label(
        &format!(
            "{}{}",
            snippet.keyword,
            if snippet.is_enabled {
                ""
            } else {
                "  · Disabled"
            }
        ),
        "dim-label",
    );
    subtitle.set_ellipsize(gtk::pango::EllipsizeMode::End);
    content.append(&subtitle);
    if !snippet.tags.is_empty() {
        let tags = label(&snippet.tags.join(" · "), "caption");
        tags.set_ellipsize(gtk::pango::EllipsizeMode::End);
        content.append(&tags);
    }
    gtk::ListBoxRow::builder().child(&content).build()
}
impl App {
    fn start_inline(&self) {
        if self.inline.borrow().is_none() {
            *self.inline.borrow_mut() =
                Some(inline::Service::new(self.library.borrow().root.clone()));
        }
    }
    fn open_inline(&self) {
        self.start_inline();
        if let Some(service) = self.inline.borrow().as_ref() {
            service.present(&self.application);
        }
    }
    fn start_history(self: &Rc<Self>) {
        if self.history.borrow().is_some() {
            return;
        }
        let weak = Rc::downgrade(self);
        let root = self.library.borrow().root.clone();
        match history::Service::new(root, move |text| {
            if let Some(app) = weak.upgrade()
                && app.ensure_library()
            {
                app.main().new_entry(text);
                app.present();
            }
        }) {
            Ok(service) => *self.history.borrow_mut() = Some(service),
            Err(error) => eprintln!("{error}"),
        }
    }
    fn open_history(self: &Rc<Self>) {
        self.start_history();
        if let Some(history) = self.history.borrow().as_ref() {
            history.present(&self.application);
        }
    }
    fn update_actions(&self) {
        for name in [
            "new", "capture", "search", "save", "copy", "picker", "import", "export", "undo",
            "redo", "secure", "backup",
        ] {
            if let Some(action) = self
                .application
                .lookup_action(name)
                .and_then(|action| action.downcast::<gio::SimpleAction>().ok())
            {
                action.set_enabled(!self.recovery_required.get());
            }
        }
        if let Some(action) = self
            .application
            .lookup_action("restore-backup")
            .and_then(|action| action.downcast::<gio::SimpleAction>().ok())
        {
            action.set_enabled(
                !self.recovery_required.get()
                    || crate::backup::import::pending(&self.library.borrow().root).unwrap_or(false),
            );
        }
    }
    fn ensure_library(self: &Rc<Self>) -> bool {
        let readiness = self.library.borrow().readiness();
        match readiness {
            Ok(Readiness::Ready) if !self.recovery_required.get() => true,
            Ok(_) => {
                self.recovery_required.set(true);
                self.update_actions();
                let main = self.main();
                main.update_recovery();
                main.window.present();
                false
            }
            Err(error) => {
                self.toast(&error.to_string());
                false
            }
        }
    }
    fn open_account(self: &Rc<Self>) {
        if self.account.borrow().is_none() {
            let main = self.main();
            let root = self
                .library
                .borrow()
                .path()
                .parent()
                .map(std::path::Path::to_path_buf);
            let Some(root) = root else {
                return;
            };
            if self.account_worker.borrow().is_none() {
                match AccountWorker::new(root) {
                    Ok(worker) => *self.account_worker.borrow_mut() = Some(Rc::new(worker)),
                    Err(failure) => {
                        self.toast(failure.message());
                        return;
                    }
                }
            }
            let worker = self.account_worker.borrow().as_ref().unwrap().clone();
            match AccountWindow::new(&self.application, &main.window, worker) {
                Ok(window) => *self.account.borrow_mut() = Some(window),
                Err(failure) => {
                    self.toast(failure.message());
                    return;
                }
            }
        }
        if let Some(window) = self.account.borrow().as_ref() {
            window.present();
        }
    }
    fn catalogue(&self) -> model::Result<Vec<Snippet>> {
        if self.recovery_required.get() {
            return Err(Error(
                "Recover the interrupted update before opening the library.",
            ));
        }
        let library = self.library.borrow();
        let (ordinary, secure) = library.catalogue()?;
        Ok(ordinary
            .into_iter()
            .chain(secure.iter().map(|m| m.shell()))
            .collect())
    }
    fn is_secure(&self, id: uuid::Uuid) -> model::Result<bool> {
        if self.recovery_required.get() {
            return Err(Error(
                "Recover the interrupted update before opening the library.",
            ));
        }
        Ok(self
            .library
            .borrow()
            .secure_metadata()?
            .iter()
            .any(|m| m.id == id))
    }
    fn open_secure(self: &Rc<Self>, id: Option<uuid::Uuid>) {
        self.open_secure_target(id, None);
    }
    fn open_secure_target(self: &Rc<Self>, id: Option<uuid::Uuid>, target: Option<PasteTarget>) {
        if !self.ensure_library() {
            return;
        }
        if self.secure.borrow().is_none() {
            let workspace = Workspace::new(&self.application, &self.library.borrow());
            match workspace {
                Ok(workspace) => *self.secure.borrow_mut() = Some(workspace),
                Err(error) => {
                    self.toast(&error.to_string());
                    return;
                }
            }
        }
        if let Some(workspace) = self.secure.borrow().as_ref() {
            if let (Some(id), Some(target)) = (id, target) {
                workspace.present_for_insertion(id, target);
            } else {
                workspace.present(id);
            }
        }
    }
    fn main(self: &Rc<Self>) -> Rc<MainWindow> {
        if let Some(window) = self.main.borrow().as_ref() {
            return window.clone();
        }
        let window = MainWindow::new(self);
        *self.main.borrow_mut() = Some(window.clone());
        window
    }
    fn present(self: &Rc<Self>) {
        self.wake_sync(Wake::Foreground);
        self.main().window.present();
    }
    fn wake_sync(&self, reason: Wake) {
        if let Some(worker) = self.account_worker.borrow().as_ref() {
            worker.wake(reason);
        }
    }
    fn toast(self: &Rc<Self>, message: &str) {
        if let Some(picker) = self
            .picker
            .borrow()
            .as_ref()
            .filter(|p| p.window.is_visible())
        {
            picker.overlay.add_toast(adw::Toast::new(message));
        } else {
            let main = self.main();
            main.window.present();
            main.toast(message);
        }
    }
    fn theme(&self) {
        let text = desktop::theme_path()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_default();
        if *self.last_theme.borrow() == text {
            return;
        }
        let (css, dark) = desktop::theme_css(&text);
        self.css.load_from_string(&css);
        self.application
            .style_manager()
            .set_color_scheme(match dark {
                Some(true) => adw::ColorScheme::ForceDark,
                Some(false) => adw::ColorScheme::ForceLight,
                None => adw::ColorScheme::Default,
            });
        *self.last_theme.borrow_mut() = text;
    }
    fn open_picker(self: &Rc<Self>, target: Option<PasteTarget>) {
        if !self.ensure_library() {
            return;
        }
        // Picker-only activation has no main-window draft. Creating an invisible
        // ApplicationWindow here also hits GTK 4.22's Wayland teardown path for a
        // window with no native surface. Flush only a workspace that exists.
        let saved = self.main.borrow().as_ref().is_none_or(|main| main.save());
        if !saved {
            self.present();
            return;
        }
        if let Err(error) = self.library.borrow_mut().reload() {
            self.toast(&error.to_string());
            return;
        }
        if let Some(previous) = self.picker.borrow_mut().take() {
            previous.window.close();
        }
        let picker = Picker::new(self, target);
        picker.window.present();
        picker.query.grab_focus();
        *self.picker.borrow_mut() = Some(picker);
    }
    fn copy(self: &Rc<Self>, snippet: Snippet, target: Option<PasteTarget>) {
        if !self.ensure_library() {
            return;
        }
        match self.is_secure(snippet.id) {
            Ok(false) => (),
            Ok(true) => {
                self.open_secure(Some(snippet.id));
                return;
            }
            Err(error) => {
                self.toast(&error.to_string());
                return;
            }
        }
        let Some(display) = gdk::Display::default() else {
            return;
        };
        let clipboard = display.clipboard();
        let serial = self.copy_serial.get().wrapping_add(1);
        self.copy_serial.set(serial);
        let app = self.clone();
        glib::spawn_future_local(async move {
            let previous = if clipboard.formats().contains_type(String::static_type()) {
                match clipboard.read_text_future().await {
                    Ok(value) => value,
                    Err(_) => {
                        app.toast("The clipboard could not be read.");
                        return;
                    }
                }
            } else {
                None
            };
            if app.copy_serial.get() != serial {
                return;
            }
            let text = placeholders::resolve(&snippet.content, previous.as_deref().unwrap_or(""));
            let provider = internal_clipboard_provider(&text);
            if clipboard.set_content(Some(&provider)).is_err() {
                app.toast("The clipboard could not be updated.");
                return;
            }
            let Some(target) = target else {
                app.toast("Copied resolved text.");
                return;
            };
            if let Some(picker) = app.picker.borrow().as_ref() {
                picker.window.set_visible(false);
            }
            if !target.focus() {
                app.paste_failed();
                return;
            }
            glib::timeout_future(Duration::from_millis(200)).await;
            if app.copy_serial.get() != serial || clipboard.content().as_ref() != Some(&provider) {
                return;
            }
            if !target.paste() {
                app.paste_failed();
                return;
            }
            glib::timeout_future(Duration::from_millis(1500)).await;
            if app.copy_serial.get() == serial
                && clipboard.content().as_ref() == Some(&provider)
                && let Some(previous) = previous
            {
                let _ = clipboard.set_content(Some(&internal_clipboard_provider(&previous)));
            }
        });
    }
    fn paste_failed(self: &Rc<Self>) {
        if let Some(picker) = self.picker.borrow().as_ref() {
            picker.window.present();
        }
        self.toast("Copied. The original window could not receive the paste.");
    }
    fn capture(self: &Rc<Self>) {
        if !self.ensure_library() {
            return;
        }
        let Some(display) = gdk::Display::default() else {
            return;
        };
        let app = self.clone();
        glib::spawn_future_local(async move {
            match display.clipboard().read_text_future().await {
                Ok(Some(text)) if text.len() <= model::MAX_BODY_BYTES && !text.contains('\0') => {
                    app.main().new_entry(text.as_str());
                    app.present();
                }
                _ => app.toast("The clipboard has no supported text to capture."),
            }
        });
    }
    fn import(self: &Rc<Self>) {
        if !self.ensure_library() {
            return;
        }
        let main = self.main();
        if !main.save() {
            return;
        }
        let app = self.clone();
        glib::spawn_future_local(async move {
            let filter = gtk::FileFilter::new();
            filter.set_name(Some("JSON exports"));
            filter.add_pattern("*.json");
            let dialog = gtk::FileDialog::builder()
                .title("Import Snippets")
                .default_filter(&filter)
                .build();
            let Ok(file) = dialog.open_future(Some(&main.window)).await else {
                return;
            };
            let outcome = file
                .path()
                .ok_or(Error("Choose a local JSON file."))
                .and_then(|path| model::read_regular(&path))
                .and_then(|data| data.ok_or(Error("The input file is unavailable.")))
                .and_then(|data| app.library.borrow_mut().import(&data));
            match outcome {
                Ok((added, skipped)) => {
                    app.wake_sync(Wake::LocalEdit);
                    main.refresh();
                    main.toast(&format!("Imported {added}; skipped {skipped} duplicates."));
                }
                Err(error) => main.toast(&error.to_string()),
            }
        });
    }
    fn export(self: &Rc<Self>) {
        if !self.ensure_library() {
            return;
        }
        let main = self.main();
        if !main.save() {
            return;
        }
        let app = self.clone();
        glib::spawn_future_local(async move {
            let notice = adw::AlertDialog::builder().heading("Export ordinary snippets?")
                .body("The export is plaintext and contains names, keywords, tags, and ordinary snippet bodies. Review it before sharing.").build();
            notice.add_responses(&[("cancel", "Cancel"), ("export", "Export")]);
            notice.set_default_response(Some("cancel"));
            notice.set_close_response("cancel");
            if notice.choose_future(Some(&main.window)).await != "export" {
                return;
            }
            let dialog = gtk::FileDialog::builder()
                .title("Export Snippets")
                .initial_name("snippets-export.json")
                .build();
            let Ok(file) = dialog.save_future(Some(&main.window)).await else {
                return;
            };
            let reloaded = app.library.borrow_mut().reload();
            let outcome = reloaded
                .and_then(|_| model::encode_library(&app.library.borrow().snippets, true))
                .and_then(|data| {
                    file.path()
                        .ok_or(Error("Choose a local export destination."))
                        .and_then(|path| model::atomic_write(&path, &data))
                });
            match outcome {
                Ok(()) => main.toast("Exported ordinary snippets."),
                Err(error) => main.toast(&error.to_string()),
            }
        });
    }
    fn encrypted_backup(self: &Rc<Self>) {
        if !self.ensure_library() {
            return;
        }
        let main = self.main();
        if !main.save() {
            return;
        }
        let exporter = self
            .backup
            .borrow()
            .clone()
            .unwrap_or_else(|| BackupExport::new(&main.window, &self.library.borrow()));
        *self.backup.borrow_mut() = Some(exporter.clone());
        exporter.start(move |result| match result {
            Ok((ordinary, secure)) => main.toast(&format!(
                "Encrypted backup saved: {ordinary} ordinary and {secure} secure snippets."
            )),
            Err(error) => main.toast(&error.to_string()),
        });
    }
    fn quit(self: &Rc<Self>) {
        let inline_idle = self
            .inline
            .borrow()
            .as_ref()
            .is_none_or(|service| service.prepare_quit());
        // Fence automatic admission before checking any other quit barrier.
        let history_idle = self
            .history
            .borrow()
            .as_ref()
            .is_none_or(|history| history.prepare_quit());
        // Revoke foreground credentials even when a busy worker postpones quit.
        if let Some(account) = self.account.borrow().as_ref() {
            account.cancel_sensitive();
        }
        let account_idle = self
            .account_worker
            .borrow()
            .as_ref()
            .is_none_or(|worker| worker.prepare_quit());
        if !inline_idle {
            self.toast("Waiting for inline expansion to stop. Try Quit again shortly.");
            return;
        }
        if !history_idle {
            self.toast("Waiting for clipboard history to stop. Try Quit again shortly.");
            return;
        }
        if self
            .backup
            .borrow()
            .as_ref()
            .is_some_and(|backup| !backup.prepare_quit())
        {
            self.toast("Waiting for backup cancellation to finish. Try Quit again shortly.");
            return;
        }
        if !account_idle {
            self.toast("Waiting for synchronization to stop. Try Quit again shortly.");
            return;
        }
        if self
            .account
            .borrow()
            .as_ref()
            .is_some_and(|account| !account.prepare_quit())
        {
            return;
        }
        if let Some(workspace) = self.secure.borrow().as_ref()
            && !workspace.prepare_quit()
        {
            self.toast("Waiting for the secure operation to stop. Try Quit again shortly.");
            return;
        }
        if let Some(workspace) = self.secure.borrow().as_ref()
            && !workspace.save()
        {
            if let Some(worker) = self.account_worker.borrow().as_ref() {
                worker.cancel_quit();
            }
            if let Some(history) = self.history.borrow().as_ref() {
                history.cancel_quit();
            }
            if let Some(service) = self.inline.borrow().as_ref() {
                service.cancel_quit();
            }
            workspace.present(None);
            return;
        }
        let saved = self.main.borrow().as_ref().is_none_or(|main| main.save());
        if saved {
            if let Some(workspace) = self.secure.borrow().as_ref() {
                workspace.lock();
            }
            self.application.quit();
        } else {
            if let Some(worker) = self.account_worker.borrow().as_ref() {
                worker.cancel_quit();
            }
            if let Some(history) = self.history.borrow().as_ref() {
                history.cancel_quit();
            }
            if let Some(service) = self.inline.borrow().as_ref() {
                service.cancel_quit();
            }
            self.present();
        }
    }
    fn restore_encrypted_backup(self: &Rc<Self>) {
        let recovery = match crate::backup::import::pending(&self.library.borrow().root) {
            Ok(value) => value,
            Err(error) => {
                self.toast(&error.to_string());
                return;
            }
        };
        if !recovery && !self.ensure_library() {
            return;
        }
        let main = self.main();
        if !recovery && !main.save() {
            return;
        }
        let controller = self
            .backup
            .borrow()
            .clone()
            .unwrap_or_else(|| BackupExport::new(&main.window, &self.library.borrow()));
        *self.backup.borrow_mut() = Some(controller.clone());
        let app = self.clone();
        controller.start_import(recovery, move |result| {
            // Poll observes the fence and validates both primary files before
            // exposing an imported or recovered workspace.
            main.poll();
            match result {
                Ok(Some((ordinary, secure))) => main.toast(&format!(
                    "Restored {ordinary} ordinary and {secure} secure snippets."
                )),
                Ok(None) => main.toast("Interrupted backup import recovered."),
                Err(error) => main.toast(&error.to_string()),
            }
            app.update_actions();
        });
    }
    fn actions(self: &Rc<Self>) {
        for name in [
            "new",
            "capture",
            "history",
            "inline",
            "search",
            "save",
            "copy",
            "picker",
            "import",
            "export",
            "undo",
            "redo",
            "quit",
            "about",
            "secure",
            "account",
            "backup",
            "restore-backup",
        ] {
            let action = gio::SimpleAction::new(name, None);
            let weak = Rc::downgrade(self);
            action.connect_activate(move |_, _| {
                if let Some(app) = weak.upgrade() {
                    if ![
                        "quit",
                        "about",
                        "account",
                        "restore-backup",
                        "history",
                        "inline",
                    ]
                    .contains(&name)
                        && !app.ensure_library()
                    {
                        return;
                    }
                    if app
                        .secure
                        .borrow()
                        .as_ref()
                        .is_some_and(|workspace| workspace.handle_action(name))
                    {
                        return;
                    }
                    match name {
                        "account" => app.open_account(),
                        "history" => app.open_history(),
                        "inline" => app.open_inline(),
                        "secure" => app.open_secure(None),
                        "new" => {
                            app.main().new_entry("");
                            app.present();
                        }
                        "capture" => app.capture(),
                        "save" => {
                            app.main().save();
                        }
                        "search" => {
                            if let Some(picker) = app
                                .picker
                                .borrow()
                                .as_ref()
                                .filter(|p| p.window.is_visible())
                            {
                                picker.query.grab_focus();
                            } else {
                                app.present();
                                app.main().query.grab_focus();
                            }
                        }
                        "copy" => {
                            if let Some(picker) = app
                                .picker
                                .borrow()
                                .as_ref()
                                .filter(|p| p.window.is_visible())
                            {
                                picker.choose();
                            } else {
                                app.main().copy();
                            }
                        }
                        "picker" => app.open_picker(None),
                        "import" => app.import(),
                        "export" => app.export(),
                        "backup" => app.encrypted_backup(),
                        "restore-backup" => app.restore_encrypted_backup(),
                        "undo" | "redo" => {
                            let main = app.main();
                            if main.save() {
                                let outcome = app.library.borrow_mut().undo(name == "redo");
                                match outcome {
                                    Ok(()) => {
                                        app.wake_sync(Wake::LocalEdit);
                                        main.reload_current();
                                        main.refresh();
                                    }
                                    Err(error) => main.toast(&error.to_string()),
                                }
                            }
                        }
                        "quit" => app.quit(),
                        "about" => {
                            let dialog = adw::AboutDialog::builder()
                                .application_name("Snippets")
                                .application_icon(desktop::APP_ID)
                                .version(env!("CARGO_PKG_VERSION"))
                                .developer_name("Snippets contributors")
                                .comments("Your library of links, notes, and reusable text.")
                                .license_type(gtk::License::MitX11)
                                .build();
                            dialog.present(Some(&app.main().window));
                        }
                        _ => (),
                    }
                }
            });
            self.application.add_action(&action);
        }
        self.update_actions();
        for (action, shortcut) in [
            ("new", "<Control>n"),
            ("capture", "<Control><Shift>n"),
            ("history", "<Control><Shift>h"),
            ("search", "<Control>f"),
            ("save", "<Control>s"),
            ("copy", "<Control>Return"),
            ("picker", "<Control>k"),
            ("import", "<Control><Shift>i"),
            ("export", "<Control><Shift>e"),
            ("undo", "<Control><Alt>z"),
            ("redo", "<Control><Alt><Shift>z"),
            ("quit", "<Control>q"),
        ] {
            self.application
                .set_accels_for_action(&format!("app.{action}"), &[shortcut]);
        }
    }
}

struct MainWindow {
    app: Weak<App>,
    window: adw::ApplicationWindow,
    overlay: adw::ToastOverlay,
    recovery: adw::Banner,
    workspace: gtk::Paned,
    query: gtk::SearchEntry,
    rows: gtk::ListBox,
    visible: RefCell<Vec<Snippet>>,
    count: gtk::Label,
    tags_box: gtk::Box,
    selected_tags: RefCell<Vec<String>>,
    pinned: gtk::ToggleButton,
    list_stack: gtk::Stack,
    empty: adw::StatusPage,
    editor_stack: gtk::Stack,
    name: gtk::Entry,
    keyword: gtk::Entry,
    tags: gtk::Entry,
    enabled: gtk::CheckButton,
    pin: gtk::CheckButton,
    buffer: gtk::TextBuffer,
    status: gtk::Label,
    current: RefCell<Option<Snippet>>,
    expected: RefCell<Option<Snippet>>,
    loading: Cell<bool>,
    dirty: Cell<bool>,
    autosave: RefCell<Option<glib::SourceId>>,
    read_failed: Cell<bool>,
}
impl MainWindow {
    fn new(app: &Rc<App>) -> Rc<Self> {
        let window = adw::ApplicationWindow::builder()
            .application(&app.application)
            .title("Snippets")
            .default_width(1080)
            .default_height(720)
            .build();
        let overlay = adw::ToastOverlay::new();
        window.set_content(Some(&overlay));
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 0);
        overlay.set_child(Some(&layout));
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Snippets",
            "Your personal library",
        )));
        let new = button("list-add-symbolic", "New snippet · Ctrl+N");
        new.set_action_name(Some("app.new"));
        header.pack_start(&new);
        let picker = button("edit-find-symbolic", "Open picker · Ctrl+K");
        picker.set_action_name(Some("app.picker"));
        header.pack_end(&picker);
        let menu = gio::Menu::new();
        for (title, action) in [
            ("Account & Recovery…", "account"),
            ("Secure Snippets…", "secure"),
            ("Capture Clipboard", "capture"),
            ("Clipboard History…", "history"),
            ("Inline Expansion…", "inline"),
            ("Import…", "import"),
            ("Export…", "export"),
            ("Encrypted Backup…", "backup"),
            ("Restore Encrypted Backup…", "restore-backup"),
            ("Undo Library Change", "undo"),
            ("Redo Library Change", "redo"),
            ("About Snippets", "about"),
            ("Quit", "quit"),
        ] {
            menu.append(Some(title), Some(&format!("app.{action}")));
        }
        header.pack_end(
            &gtk::MenuButton::builder()
                .icon_name("open-menu-symbolic")
                .menu_model(&menu)
                .build(),
        );
        layout.append(&header);
        let recovery = adw::Banner::builder()
            .title("Library recovery required")
            .button_label("Account & Recovery")
            .build();
        layout.append(&recovery);
        let split = gtk::Paned::builder()
            .orientation(gtk::Orientation::Horizontal)
            .position(340)
            .vexpand(true)
            .build();
        split.set_resize_start_child(false);
        split.set_shrink_start_child(false);
        layout.append(&split);
        let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 12);
        sidebar.set_width_request(280);
        sidebar.add_css_class("sidebar");
        split.set_start_child(Some(&sidebar));
        let query = gtk::SearchEntry::builder()
            .placeholder_text("Search snippets")
            .margin_start(16)
            .margin_end(16)
            .margin_top(16)
            .build();
        sidebar.append(&query);
        let filters = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        filters.set_margin_start(16);
        filters.set_margin_end(16);
        let pinned = gtk::ToggleButton::with_label("Pinned");
        filters.append(&pinned);
        let tags_box = gtk::Box::new(gtk::Orientation::Vertical, 4);
        let popover = gtk::Popover::builder().child(&tags_box).build();
        filters.append(
            &gtk::MenuButton::builder()
                .label("Tags")
                .popover(&popover)
                .build(),
        );
        sidebar.append(&filters);
        let rows = gtk::ListBox::new();
        rows.add_css_class("navigation-sidebar");
        rows.set_selection_mode(gtk::SelectionMode::Single);
        let list_stack = gtk::Stack::builder().vexpand(true).build();
        list_stack.add_named(&scrolled(&rows), Some("list"));
        let empty = adw::StatusPage::builder()
            .icon_name("edit-find-symbolic")
            .title("No snippets yet")
            .description("Save links, notes, and text you use every day.")
            .build();
        let create = gtk::Button::with_label("Create a Snippet");
        create.set_action_name(Some("app.new"));
        create.set_halign(gtk::Align::Center);
        create.add_css_class("suggested-action");
        empty.set_child(Some(&create));
        list_stack.add_named(&empty, Some("empty"));
        sidebar.append(&list_stack);
        let count = label("", "dim-label");
        count.set_margin_start(20);
        count.set_margin_bottom(12);
        sidebar.append(&count);
        let editor_stack = gtk::Stack::builder().hexpand(true).vexpand(true).build();
        split.set_end_child(Some(&editor_stack));
        editor_stack.add_named(
            &adw::StatusPage::builder()
                .icon_name("text-x-generic-symbolic")
                .title("Everything you need. Right at hand.")
                .description("Choose a snippet to edit, or press Ctrl+N to create one.")
                .build(),
            Some("empty"),
        );
        editor_stack.add_named(
            &adw::StatusPage::builder()
                .icon_name("dialog-warning-symbolic")
                .title("Finish the interrupted update")
                .description("Open Account & Recovery, reconnect your saved account and library, then choose Sync Now. Your entries stay hidden until recovery finishes.")
                .build(),
            Some("recovery"),
        );
        let editor = gtk::Box::new(gtk::Orientation::Vertical, 16);
        editor.set_margin_start(28);
        editor.set_margin_end(28);
        editor.set_margin_top(20);
        editor.set_margin_bottom(20);
        editor_stack.add_named(&editor, Some("editor"));
        let toolbar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let status = label("Saved locally", "dim-label");
        status.set_hexpand(true);
        toolbar.append(&status);
        let copy = button("edit-copy-symbolic", "Copy resolved text · Ctrl+Return");
        let duplicate = button("edit-copy-symbolic", "Duplicate snippet");
        let reload = button("view-refresh-symbolic", "Reload this snippet from disk");
        let delete = button("user-trash-symbolic", "Delete snippet");
        for widget in [&copy, &duplicate, &reload, &delete] {
            toolbar.append(widget);
        }
        editor.append(&toolbar);
        let name = gtk::Entry::builder()
            .placeholder_text("Name")
            .hexpand(true)
            .build();
        name.add_css_class("title-2");
        name.update_property(&[gtk::accessible::Property::Label("Snippet name")]);
        editor.append(&name);
        let metadata = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let keyword = gtk::Entry::builder()
            .placeholder_text("meet")
            .hexpand(true)
            .build();
        let tags = gtk::Entry::builder()
            .placeholder_text("work, links")
            .hexpand(true)
            .build();
        for (title, field) in [("KEYWORD", &keyword), ("TAGS", &tags)] {
            let group = gtk::Box::new(gtk::Orientation::Vertical, 6);
            group.set_hexpand(true);
            group.append(&label(title, "caption"));
            group.append(field);
            field.update_property(&[gtk::accessible::Property::Label(title)]);
            metadata.append(&group);
        }
        editor.append(&metadata);
        let toggles = gtk::Box::new(gtk::Orientation::Horizontal, 16);
        let enabled = gtk::CheckButton::with_label("Available in picker");
        let pin = gtk::CheckButton::with_label("Pin to top");
        toggles.append(&enabled);
        toggles.append(&pin);
        editor.append(&toggles);
        editor.append(&label("CONTENT", "caption"));
        let content = gtk::TextView::builder()
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .top_margin(16)
            .bottom_margin(16)
            .left_margin(16)
            .right_margin(16)
            .accepts_tab(true)
            .vexpand(true)
            .build();
        content.update_property(&[gtk::accessible::Property::Label("Snippet content")]);
        let buffer = content.buffer();
        buffer.set_enable_undo(true);
        let scroll = scrolled(&content);
        scroll.add_css_class("card");
        editor.append(&scroll);
        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        footer.append(&label("Placeholders", "dim-label"));
        for token in ["{date}", "{time}", "{clipboard}"] {
            let insert = gtk::Button::with_label(token);
            insert.add_css_class("flat");
            let buffer = buffer.clone();
            insert.connect_clicked(move |_| buffer.insert_at_cursor(token));
            footer.append(&insert);
        }
        editor.append(&footer);
        editor.append(&label(
            "Ordinary entries are stored locally as plaintext.",
            "dim-label",
        ));
        let this = Rc::new(Self {
            app: Rc::downgrade(app),
            window,
            overlay,
            recovery,
            workspace: split,
            query,
            rows,
            visible: RefCell::new(vec![]),
            count,
            tags_box,
            selected_tags: RefCell::new(vec![]),
            pinned,
            list_stack,
            empty,
            editor_stack,
            name,
            keyword,
            tags,
            enabled,
            pin,
            buffer,
            status,
            current: RefCell::new(None),
            expected: RefCell::new(None),
            loading: Cell::new(false),
            dirty: Cell::new(false),
            autosave: RefCell::new(None),
            read_failed: Cell::new(false),
        });
        let weak = Rc::downgrade(app);
        this.recovery.connect_button_clicked(move |_| {
            if let Some(app) = weak.upgrade() {
                if crate::backup::import::pending(&app.library.borrow().root).unwrap_or(false) {
                    app.restore_encrypted_backup();
                } else {
                    app.open_account();
                }
            }
        });
        let weak = Rc::downgrade(&this);
        this.query.connect_search_changed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.refresh();
            }
        });
        let weak = Rc::downgrade(&this);
        this.pinned.connect_toggled(move |_| {
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
                let snippet = this.visible.borrow().get(row.index() as usize).cloned();
                if snippet.as_ref().map(|s| s.id) == this.current.borrow().as_ref().map(|s| s.id) {
                    return;
                }
                if this.save() {
                    if let Some(snippet) = snippet.as_ref() {
                        match this.app.upgrade().map(|app| app.is_secure(snippet.id)) {
                            Some(Ok(true)) => {
                                if let Some(app) = this.app.upgrade() {
                                    app.open_secure(Some(snippet.id));
                                }
                                return;
                            }
                            Some(Err(error)) => {
                                this.toast(&error.to_string());
                                return;
                            }
                            _ => (),
                        }
                    }
                    this.show(snippet.clone(), snippet);
                } else {
                    this.refresh();
                }
            }
        });
        for entry in [&this.name, &this.keyword, &this.tags] {
            let weak = Rc::downgrade(&this);
            entry.connect_changed(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.edited();
                }
            });
        }
        for toggle in [&this.enabled, &this.pin] {
            let weak = Rc::downgrade(&this);
            toggle.connect_toggled(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.edited();
                }
            });
        }
        let weak = Rc::downgrade(&this);
        this.buffer.connect_changed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.edited();
            }
        });
        let weak = Rc::downgrade(&this);
        copy.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.copy();
            }
        });
        let weak = Rc::downgrade(&this);
        duplicate.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.duplicate();
            }
        });
        let weak = Rc::downgrade(&this);
        reload.connect_clicked(move |_| {
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
        this.window.connect_close_request(move |window| {
            if let Some(this) = weak.upgrade()
                && this.save()
            {
                window.set_visible(false);
            }
            glib::Propagation::Stop
        });
        let weak = Rc::downgrade(&this);
        glib::timeout_add_seconds_local(2, move || {
            if let Some(this) = weak.upgrade() {
                this.poll();
                glib::ControlFlow::Continue
            } else {
                glib::ControlFlow::Break
            }
        });
        this.update_recovery();
        this.refresh();
        this
    }
    fn update_recovery(&self) {
        let Some(app) = self.app.upgrade() else {
            return;
        };
        let blocked = app.recovery_required.get();
        let backup_recovery =
            crate::backup::import::pending(&app.library.borrow().root).unwrap_or(false);
        self.recovery.set_button_label(Some(if backup_recovery {
            "Resume Backup Import"
        } else {
            "Account & Recovery"
        }));
        if let Some(page) = self
            .editor_stack
            .child_by_name("recovery")
            .and_then(|widget| widget.downcast::<adw::StatusPage>().ok())
        {
            page.set_description(Some(if backup_recovery {
                "Choose Resume Backup Import and enter the password of the backup used for the interrupted import. Your entries stay hidden until both library files are recovered."
            } else {
                "Open Account & Recovery, reconnect your saved account and library, then choose Sync Now. Your entries stay hidden until recovery finishes."
            }));
        }
        if blocked && !self.recovery.is_revealed() {
            if let Some(picker) = app.picker.borrow().as_ref() {
                picker.window.set_visible(false);
            }
            if let Some(workspace) = app.secure.borrow().as_ref() {
                workspace.lock();
            }
        }
        self.recovery.set_revealed(blocked);
        self.workspace.set_sensitive(!blocked);
        if let Some(create) = self.empty.child() {
            create.set_visible(!blocked);
        }
        if blocked {
            if let Some(source) = self.autosave.borrow_mut().take() {
                source.remove();
            }
            self.loading.set(true);
            clear_rows(&self.rows);
            self.visible.borrow_mut().clear();
            self.count.set_label("Library unavailable");
            self.empty.set_title("Library recovery required");
            self.empty.set_description(Some(if backup_recovery {
                "Resume the interrupted import with its backup password."
            } else {
                "Reconnect your saved library to finish the interrupted update."
            }));
            self.list_stack.set_visible_child_name("empty");
            self.editor_stack.set_visible_child_name("recovery");
            self.loading.set(false);
        } else {
            self.editor_stack
                .set_visible_child_name(if self.current.borrow().is_some() {
                    "editor"
                } else {
                    "empty"
                });
        }
    }
    fn toast(&self, text: &str) {
        self.overlay.add_toast(adw::Toast::new(text));
    }
    fn show(&self, snippet: Option<Snippet>, expected: Option<Snippet>) {
        if let Some(source) = self.autosave.borrow_mut().take() {
            source.remove();
        }
        self.loading.set(true);
        self.dirty.set(false);
        *self.expected.borrow_mut() = expected;
        *self.current.borrow_mut() = snippet.clone();
        if let Some(snippet) = snippet {
            self.name.set_text(&snippet.name);
            self.keyword.set_text(&snippet.keyword);
            self.tags.set_text(&snippet.tags.join(", "));
            self.enabled.set_active(snippet.is_enabled);
            self.pin.set_active(snippet.is_pinned);
            self.buffer.set_enable_undo(false);
            self.buffer.set_text(&snippet.content);
            self.buffer.set_enable_undo(true);
            self.status.set_label("Saved locally");
            self.editor_stack.set_visible_child_name("editor");
        } else {
            self.buffer.set_enable_undo(false);
            self.buffer.set_text("");
            self.buffer.set_enable_undo(true);
            self.editor_stack.set_visible_child_name("empty");
        }
        self.loading.set(false);
    }
    fn edited(self: &Rc<Self>) {
        if self.loading.get() || self.current.borrow().is_none() {
            return;
        }
        self.dirty.set(true);
        self.status.set_label("Unsaved changes");
        if let Some(source) = self.autosave.borrow_mut().take() {
            source.remove();
        }
        let weak = Rc::downgrade(self);
        *self.autosave.borrow_mut() = Some(glib::timeout_add_local_once(
            Duration::from_millis(600),
            move || {
                if let Some(this) = weak.upgrade() {
                    this.autosave.borrow_mut().take();
                    this.save();
                }
            },
        ));
    }
    fn draft(&self) -> Option<Snippet> {
        let mut snippet = self.current.borrow().clone()?;
        snippet.name = self.name.text().into();
        snippet.keyword = self.keyword.text().into();
        snippet.tags = self.tags.text().split(',').map(String::from).collect();
        snippet.content = self
            .buffer
            .text(&self.buffer.start_iter(), &self.buffer.end_iter(), true)
            .into();
        snippet.is_enabled = self.enabled.is_active();
        snippet.is_pinned = self.pin.is_active();
        Some(snippet)
    }
    fn save(&self) -> bool {
        if let Some(source) = self.autosave.borrow_mut().take() {
            source.remove();
        }
        if !self.dirty.get() {
            return true;
        }
        let Some(app) = self.app.upgrade() else {
            return false;
        };
        if !app.ensure_library() {
            return false;
        }
        let Some(snippet) = self.draft() else {
            return true;
        };
        let id = snippet.id;
        let result = app
            .library
            .borrow_mut()
            .save(snippet, self.expected.borrow().as_ref());
        match result {
            Ok(()) => {
                let saved = app.library.borrow().get(id);
                *self.current.borrow_mut() = saved.clone();
                *self.expected.borrow_mut() = saved;
                self.dirty.set(false);
                self.status.set_label("Saved locally");
                app.wake_sync(Wake::LocalEdit);
                self.refresh();
                true
            }
            Err(error) => {
                self.status.set_label(&error.to_string());
                false
            }
        }
    }
    fn new_entry(self: &Rc<Self>, content: &str) {
        if !self.app.upgrade().is_some_and(|app| app.ensure_library()) {
            return;
        }
        if !self.save() {
            return;
        }
        self.show(Some(Snippet::new("", content)), None);
        self.edited();
        self.name.grab_focus();
    }
    fn refresh(&self) {
        if self.loading.get() {
            return;
        }
        let Some(app) = self.app.upgrade() else {
            return;
        };
        if app.recovery_required.get() {
            self.update_recovery();
            return;
        }
        self.loading.set(true);
        let catalogue = match app.catalogue() {
            Ok(catalogue) => catalogue,
            Err(error) => {
                self.loading.set(false);
                self.toast(&error.to_string());
                return;
            }
        };
        let ordinary_ids: std::collections::HashSet<_> =
            app.library.borrow().snippets.iter().map(|s| s.id).collect();
        let snippets = model::search(
            &catalogue,
            &self.query.text(),
            &self.selected_tags.borrow(),
            self.pinned.is_active(),
            false,
        );
        let current_id = self.current.borrow().as_ref().map(|s| s.id);
        clear_rows(&self.rows);
        for (index, snippet) in snippets.iter().enumerate() {
            let item = row(snippet, !ordinary_ids.contains(&snippet.id));
            self.rows.append(&item);
            if Some(snippet.id) == current_id {
                self.rows
                    .select_row(self.rows.row_at_index(index as i32).as_ref());
            }
        }
        self.count
            .set_label(&format!("{} snippets", snippets.len()));
        self.list_stack
            .set_visible_child_name(if snippets.is_empty() { "empty" } else { "list" });
        let is_empty = catalogue.is_empty();
        self.empty.set_title(if is_empty {
            "No snippets yet"
        } else {
            "No matching snippets"
        });
        self.empty.set_description(Some(if is_empty {
            "Save links, notes, and text you use every day."
        } else {
            "Try another search or change the filters."
        }));
        *self.visible.borrow_mut() = snippets;
        self.loading.set(false);
        self.refresh_tags();
    }
    fn refresh_tags(&self) {
        let Some(app) = self.app.upgrade() else {
            return;
        };
        while let Some(child) = self.tags_box.first_child() {
            self.tags_box.remove(&child);
        }
        let mut tags: Vec<_> = model::normalize_tags(
            app.catalogue()
                .unwrap_or_default()
                .iter()
                .flat_map(|s| s.tags.clone()),
        )
        .into_iter()
        .collect();
        tags.sort_by_key(|t| model::folded(t));
        // The selected filter remains visible even if its final record is removed.
        for selected in self.selected_tags.borrow().iter() {
            if !tags
                .iter()
                .any(|t| model::folded(t) == model::folded(selected))
            {
                tags.push(selected.clone());
            }
        }
        if tags.is_empty() {
            self.tags_box.append(&label("No tags yet", "dim-label"));
        }
        for tag in tags {
            let toggle = gtk::CheckButton::with_label(&tag);
            toggle.set_active(
                self.selected_tags
                    .borrow()
                    .iter()
                    .any(|v| model::folded(v) == model::folded(&tag)),
            );
            let weak_app = self.app.clone();
            toggle.connect_toggled(move |toggle| {
                if let Some(app) = weak_app.upgrade()
                    && let Some(this) = app.main.borrow().as_ref()
                {
                    let mut selected = this.selected_tags.borrow_mut();
                    selected.retain(|v| model::folded(v) != model::folded(&tag));
                    if toggle.is_active() {
                        selected.push(tag.clone());
                    }
                    drop(selected);
                    this.refresh();
                }
            });
            self.tags_box.append(&toggle);
        }
    }
    fn copy(&self) {
        if self.save()
            && let Some(snippet) = self.current.borrow().clone()
            && let Some(app) = self.app.upgrade()
        {
            app.copy(snippet, None);
        }
    }
    fn duplicate(self: &Rc<Self>) {
        if !self.save() {
            return;
        }
        let original = self.current.borrow().clone();
        if let Some(original) = original {
            let mut snippet = Snippet::new(
                format!("{} Copy", original.display_name()),
                original.content,
            );
            snippet.tags = original.tags;
            snippet.is_enabled = original.is_enabled;
            self.show(Some(snippet), None);
            self.edited();
            self.save();
        }
    }
    fn reload_current(&self) {
        let Some(app) = self.app.upgrade() else {
            return;
        };
        let current = self
            .current
            .borrow()
            .as_ref()
            .and_then(|s| app.library.borrow().get(s.id));
        self.show(current.clone(), current);
    }
    fn discard(self: &Rc<Self>) {
        if !self.app.upgrade().is_some_and(|app| app.ensure_library()) {
            return;
        }
        let this = self.clone();
        glib::spawn_future_local(async move {
            if this.dirty.get() {
                let dialog = adw::AlertDialog::builder()
                    .heading("Discard this draft?")
                    .body("Reload replaces the unsaved draft with the current entry on disk.")
                    .build();
                dialog.add_responses(&[("cancel", "Keep Editing"), ("reload", "Reload")]);
                dialog.set_close_response("cancel");
                dialog.set_response_appearance("reload", adw::ResponseAppearance::Destructive);
                if dialog.choose_future(Some(&this.window)).await != "reload" {
                    return;
                }
            }
            if let Some(app) = this.app.upgrade() {
                let outcome = app.library.borrow_mut().reload();
                match outcome {
                    Ok(_) => {
                        this.reload_current();
                        this.refresh();
                    }
                    Err(error) => this.toast(&error.to_string()),
                }
            }
        });
    }
    fn delete(self: &Rc<Self>) {
        if !self.save() {
            return;
        }
        let Some(snippet) = self.current.borrow().clone() else {
            return;
        };
        let this = self.clone();
        glib::spawn_future_local(async move {
            let dialog = adw::AlertDialog::builder()
                .heading("Delete this snippet?")
                .body("You can undo this library change with Ctrl+Alt+Z.")
                .build();
            dialog.add_responses(&[("cancel", "Cancel"), ("delete", "Delete")]);
            dialog.set_close_response("cancel");
            dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
            if dialog.choose_future(Some(&this.window)).await != "delete" {
                return;
            }
            if let Some(app) = this.app.upgrade() {
                let outcome = app.library.borrow_mut().delete(&snippet);
                match outcome {
                    Ok(()) => {
                        app.wake_sync(Wake::LocalEdit);
                        this.show(None, None);
                        this.refresh();
                    }
                    Err(error) => this.toast(&error.to_string()),
                }
            }
        });
    }
    fn poll(&self) {
        let Some(app) = self.app.upgrade() else {
            return;
        };
        app.theme();
        let readiness = app.library.borrow().readiness();
        match readiness {
            Ok(Readiness::RecoveryRequired) => {
                app.recovery_required.set(true);
                app.update_actions();
                self.update_recovery();
                return;
            }
            Err(error) => {
                if !self.read_failed.replace(true) {
                    self.toast(&error.to_string());
                }
                return;
            }
            Ok(Readiness::Ready) => (),
        }
        let outcome = app.library.borrow_mut().reload_catalogue();
        match outcome {
            Ok(changed) => {
                if changed {
                    app.wake_sync(Wake::LocalEdit);
                }
                self.read_failed.set(false);
                let recovered = app.recovery_required.replace(false);
                app.update_actions();
                if recovered {
                    self.update_recovery();
                    self.toast("Library recovered. Editing is available again.");
                }
                if changed && !self.dirty.get() {
                    self.reload_current();
                }
                self.refresh();
            }
            Err(error) => {
                if !self.read_failed.replace(true) {
                    self.toast(&error.to_string());
                }
            }
        }
    }
}

struct Picker {
    app: Weak<App>,
    window: adw::ApplicationWindow,
    overlay: adw::ToastOverlay,
    query: gtk::SearchEntry,
    rows: gtk::ListBox,
    snippets: RefCell<Vec<Snippet>>,
    target: Option<PasteTarget>,
}
impl Picker {
    fn new(app: &Rc<App>, target: Option<PasteTarget>) -> Rc<Self> {
        let window = adw::ApplicationWindow::builder()
            .application(&app.application)
            .title("Snippets Picker")
            .default_width(620)
            .default_height(520)
            .build();
        let overlay = adw::ToastOverlay::new();
        window.set_content(Some(&overlay));
        let layout = gtk::Box::new(gtk::Orientation::Vertical, 12);
        overlay.set_child(Some(&layout));
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            "Find a snippet",
            if target.is_some() {
                "Return to paste into the original window"
            } else {
                "Return to copy resolved text"
            },
        )));
        layout.append(&header);
        let query = gtk::SearchEntry::builder()
            .placeholder_text("Search snippets")
            .margin_start(16)
            .margin_end(16)
            .build();
        layout.append(&query);
        let rows = gtk::ListBox::new();
        rows.add_css_class("navigation-sidebar");
        layout.append(&scrolled(&rows));
        let hint = label(
            "↑↓ Select   ·   Return Use   ·   Ctrl+1…9   ·   Esc Close",
            "dim-label",
        );
        hint.set_margin_start(16);
        hint.set_margin_bottom(12);
        layout.append(&hint);
        let this = Rc::new(Self {
            app: Rc::downgrade(app),
            window,
            overlay,
            query,
            rows,
            snippets: RefCell::new(vec![]),
            target,
        });
        let weak = Rc::downgrade(&this);
        this.query.connect_search_changed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.refresh();
            }
        });
        let weak = Rc::downgrade(&this);
        this.query.connect_activate(move |_| {
            if let Some(this) = weak.upgrade() {
                this.choose();
            }
        });
        let weak = Rc::downgrade(&this);
        this.rows.connect_row_activated(move |_, _| {
            if let Some(this) = weak.upgrade() {
                this.choose();
            }
        });
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(&this);
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            let Some(this) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            match key {
                gdk::Key::Escape => {
                    this.window.set_visible(false);
                    glib::Propagation::Stop
                }
                gdk::Key::Up | gdk::Key::Down => {
                    let index = this.rows.selected_row().map_or(0, |r| r.index())
                        + if key == gdk::Key::Up { -1 } else { 1 };
                    this.rows.select_row(
                        this.rows
                            .row_at_index(
                                index
                                    .max(0)
                                    .min(this.snippets.borrow().len().saturating_sub(1) as i32),
                            )
                            .as_ref(),
                    );
                    this.query.grab_focus();
                    glib::Propagation::Stop
                }
                _ => {
                    if modifiers.contains(gdk::ModifierType::CONTROL_MASK)
                        && let Some(digit) = key
                            .to_unicode()
                            .and_then(|c| c.to_digit(10))
                            .filter(|d| (1..=9).contains(d))
                    {
                        this.rows
                            .select_row(this.rows.row_at_index(digit as i32 - 1).as_ref());
                        this.choose();
                        glib::Propagation::Stop
                    } else {
                        glib::Propagation::Proceed
                    }
                }
            }
        });
        this.window.add_controller(keys);
        this.refresh();
        this
    }
    fn refresh(&self) {
        let Some(app) = self.app.upgrade() else {
            return;
        };
        let catalogue = match app.catalogue() {
            Ok(catalogue) => catalogue,
            Err(error) => {
                self.overlay.add_toast(adw::Toast::new(&error.to_string()));
                return;
            }
        };
        let ordinary_ids: std::collections::HashSet<_> =
            app.library.borrow().snippets.iter().map(|s| s.id).collect();
        let snippets = model::search(&catalogue, &self.query.text(), &[], false, true);
        clear_rows(&self.rows);
        for snippet in &snippets {
            self.rows
                .append(&row(snippet, !ordinary_ids.contains(&snippet.id)));
        }
        self.rows.select_row(self.rows.row_at_index(0).as_ref());
        *self.snippets.borrow_mut() = snippets;
    }
    fn choose(&self) {
        let Some(selected) = self.rows.selected_row() else {
            return;
        };
        let Some(snippet) = self
            .snippets
            .borrow()
            .get(selected.index() as usize)
            .cloned()
        else {
            return;
        };
        if let Some(app) = self.app.upgrade() {
            if app.is_secure(snippet.id).is_ok_and(|secure| secure) {
                self.window.set_visible(false);
                app.open_secure_target(Some(snippet.id), self.target.clone());
                return;
            }
            app.copy(snippet, self.target.clone());
        }
    }
}

pub fn run() -> glib::ExitCode {
    if let Err(error) = Options::try_parse() {
        let code = if error.use_stderr() {
            glib::ExitCode::FAILURE
        } else {
            glib::ExitCode::SUCCESS
        };
        let _ = error.print();
        return code;
    }
    let (library, readiness) = match model::default_root().and_then(Library::open_recoverable) {
        Ok(opened) => opened,
        Err(error) => {
            eprintln!("{error}");
            return glib::ExitCode::FAILURE;
        }
    };
    if adw::init().is_err() {
        eprintln!("A graphical desktop session is required.");
        return glib::ExitCode::FAILURE;
    }
    let application = adw::Application::builder()
        .application_id(desktop::APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE)
        .build();
    let app = Rc::new(App {
        application: application.clone(),
        library: RefCell::new(library),
        recovery_required: Cell::new(readiness == Readiness::RecoveryRequired),
        main: RefCell::new(None),
        picker: RefCell::new(None),
        secure: RefCell::new(None),
        account: RefCell::new(None),
        account_worker: RefCell::new(None),
        backup: RefCell::new(None),
        history: RefCell::new(None),
        inline: RefCell::new(None),
        hold: RefCell::new(None),
        copy_serial: Cell::new(0),
        css: gtk::CssProvider::new(),
        last_theme: RefCell::new(String::new()),
    });
    let weak = Rc::downgrade(&app);
    application.connect_startup(move |application| {
        if let Some(app) = weak.upgrade() {
            // GApplication emits startup only in the primary process. A
            // secondary --picker/--quit invocation never starts another owner.
            let root = app.library.borrow().root.clone();
            match AccountWorker::new(root) {
                Ok(worker) => *app.account_worker.borrow_mut() = Some(Rc::new(worker)),
                Err(failure) => eprintln!("{}", failure.message()),
            }
            app.start_history();
            app.start_inline();
            *app.hold.borrow_mut() = Some(application.hold());
            app.actions();
            if let Some(display) = gdk::Display::default() {
                gtk::style_context_add_provider_for_display(
                    &display,
                    &app.css,
                    gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
                );
            }
            app.theme();
        }
    });
    let weak = Rc::downgrade(&app);
    application.connect_activate(move |_| {
        if let Some(app) = weak.upgrade() {
            app.present();
        }
    });
    let weak = Rc::downgrade(&app);
    application.connect_command_line(move |_, command| {
        let Some(app) = weak.upgrade() else {
            return glib::ExitCode::FAILURE;
        };
        let Ok(options) = Options::try_parse_from(command.arguments()) else {
            return glib::ExitCode::FAILURE;
        };
        if options.quit {
            app.quit();
        } else if options.picker {
            app.open_picker(PasteTarget::capture());
        } else if options.new {
            app.main().new_entry("");
            app.present();
        } else if options.capture {
            app.capture();
        } else if options.history {
            app.open_history();
        } else {
            app.present();
        }
        glib::ExitCode::SUCCESS
    });
    let result = application.run();
    drop(app);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn drain() {
        let context = glib::MainContext::default();
        while context.pending() {
            context.iteration(false);
        }
    }
    fn settle(duration: Duration) {
        let started = std::time::Instant::now();
        while started.elapsed() < duration {
            drain();
            std::thread::sleep(Duration::from_millis(10));
        }
        drain();
    }
    struct ClipboardRestore {
        clipboard: gdk::Clipboard,
        previous: Option<glib::GString>,
        owned: RefCell<Vec<gdk::ContentProvider>>,
    }
    impl Drop for ClipboardRestore {
        fn drop(&mut self) {
            if self
                .clipboard
                .content()
                .is_some_and(|p| self.owned.borrow().contains(&p))
            {
                if let Some(previous) = &self.previous {
                    self.clipboard.set_text(previous);
                } else {
                    let _ = self.clipboard.set_content(None::<&gdk::ContentProvider>);
                }
            }
        }
    }
    #[test]
    #[ignore = "live Hyprland receiving-field test; briefly opens a fictional target"]
    fn live_paste() {
        assert!(
            desktop::session_state() == desktop::SessionState::Unlocked,
            "Live paste needs an unlocked Hyprland session; no clipboard change or input was attempted."
        );
        adw::init().expect("graphical display");
        let clipboard = gdk::Display::default().unwrap().clipboard();
        assert!(
            clipboard
                .formats()
                .mime_types()
                .iter()
                .all(|mime| mime.starts_with("text/plain")
                    || ["UTF8_STRING", "TEXT", "STRING"].contains(&mime.as_str())),
            "Live paste test requires an empty or plain-text clipboard."
        );
        let previous = if clipboard.formats().contains_type(String::static_type()) {
            glib::MainContext::default()
                .block_on(clipboard.read_text_future())
                .expect("clipboard read")
        } else {
            None
        };
        let restore = ClipboardRestore {
            clipboard: clipboard.clone(),
            previous,
            owned: RefCell::new(vec![]),
        };
        let directory = tempfile::tempdir().unwrap();
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.PasteSmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let app = Rc::new(App {
            application: application.clone(),
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
            copy_serial: Cell::new(0),
            css: gtk::CssProvider::new(),
            last_theme: RefCell::new(String::new()),
        });
        let receiver = gtk::TextView::new();
        let window = adw::ApplicationWindow::builder()
            .application(&application)
            .title("Snippets Smoke Paste Target")
            .default_width(440)
            .default_height(200)
            .content(&receiver)
            .build();
        window.present();
        receiver.grab_focus();
        settle(Duration::from_millis(750));
        let clients = std::process::Command::new("hyprctl")
            .args(["-j", "clients"])
            .output()
            .expect("Hyprland session");
        let clients: serde_json::Value =
            serde_json::from_slice(&clients.stdout).expect("Hyprland JSON");
        let fixture = clients
            .as_array()
            .unwrap()
            .iter()
            .find(|client| {
                client.get("title").and_then(serde_json::Value::as_str)
                    == Some("Snippets Smoke Paste Target")
                    && client.get("pid").and_then(serde_json::Value::as_u64)
                        == Some(std::process::id() as u64)
            })
            .expect("fictional receiving window mapped");
        let target = PasteTarget::from_window(fixture).expect("fixture window");
        assert!(
            target.focus(),
            "The compositor refused focus; no keys were sent."
        );
        settle(Duration::from_millis(250));
        let active = std::process::Command::new("hyprctl")
            .args(["-j", "activewindow"])
            .output()
            .expect("Hyprland session");
        let active: serde_json::Value =
            serde_json::from_slice(&active.stdout).expect("Hyprland JSON");
        assert!(
            active.get("title").and_then(serde_json::Value::as_str)
                == Some("Snippets Smoke Paste Target")
                && active.get("pid").and_then(serde_json::Value::as_u64)
                    == Some(std::process::id() as u64),
            "The fictional receiving window did not gain focus; no keys were sent."
        );
        let provider = gdk::ContentProvider::for_value(&"fictional clipboard fixture".to_value());
        clipboard.set_content(Some(&provider)).unwrap();
        restore.owned.borrow_mut().push(provider);
        app.open_picker(Some(target.clone()));
        assert!(
            app.main.borrow().is_none(),
            "Picker-only activation must stay independent of the editor."
        );
        settle(Duration::from_millis(250));
        app.copy(
            Snippet::new("Fixture", "fictional snippet {clipboard}"),
            Some(target),
        );
        settle(Duration::from_millis(100));
        if let Some(provider) = clipboard.content() {
            restore.owned.borrow_mut().push(provider);
        }
        settle(Duration::from_millis(2300));
        let received = receiver.buffer().text(
            &receiver.buffer().start_iter(),
            &receiver.buffer().end_iter(),
            true,
        );
        let restored = glib::MainContext::default()
            .block_on(clipboard.read_text_future())
            .expect("clipboard read");
        let delivered = received == "fictional snippet fictional clipboard fixture"
            && restored.as_deref() == Some("fictional clipboard fixture");
        // The production lease creates a third provider when it restores the
        // fixture. Include that provider, then restore the user's text *before*
        // GTK teardown, which must not be able to bypass cleanup on an abort.
        if restored.as_deref() == Some("fictional clipboard fixture")
            && let Some(provider) = clipboard.content()
        {
            restore.owned.borrow_mut().push(provider);
        }
        drop(restore);
        if let Some(picker) = app.picker.borrow().as_ref() {
            picker.window.destroy();
        }
        if let Some(main) = app.main.borrow().as_ref() {
            main.window.destroy();
        }
        window.destroy();
        // Neither received text nor the original clipboard can enter failure output.
        assert!(
            delivered,
            "Live paste did not reach the fixture and restore its clipboard."
        );
    }
    #[test]
    #[ignore = "requires a graphical Wayland display; uses an empty temporary library"]
    fn native_picker_without_editor() {
        adw::init().expect("graphical display");
        let directory = tempfile::tempdir().unwrap();
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.PickerSmoke")
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
            copy_serial: Cell::new(0),
            css: gtk::CssProvider::new(),
            last_theme: RefCell::new(String::new()),
        });
        app.open_picker(None);
        settle(Duration::from_millis(250));
        assert!(app.main.borrow().is_none());
        let picker = app.picker.borrow_mut().take().unwrap();
        assert!(picker.snippets.borrow().is_empty() && !app.library.borrow().path().exists());
        picker.window.destroy();
        drain();
    }
    #[test]
    #[ignore = "requires a graphical display; fictional checkpoint/account worker only"]
    fn native_interrupted_startup_reaches_recovery_and_preserves_a_later_draft() {
        use crate::{
            cloud::Binding,
            crypto::RootKey,
            journal::{Checkpoint, Scope},
            primary,
        };
        adw::init().expect("graphical display");
        let directory = tempfile::tempdir().unwrap();
        let mut original = Library::open(directory.path().into()).unwrap();
        original
            .save(
                Snippet::new("Public recovery fixture", "Public recovered body"),
                None,
            )
            .unwrap();
        let key = RootKey::from_bytes(&[0x99; 32]).unwrap();
        let salt = [0xaa; 32];
        let scope = Scope {
            membership: Binding::from_checkpoint([0x33; 32]),
            dataset: Binding::from_checkpoint([0x44; 32]),
        };
        let mut checkpoint = Checkpoint::load(&original, &key, &salt, scope.clone()).unwrap();
        checkpoint.journal.primary_epoch = Some([0x55; 16]);
        checkpoint.save(&original, &key, &salt).unwrap();
        let mut marker = b"SPT1".to_vec();
        marker.extend_from_slice(&[0x55; 16]);
        let marker_path = directory.path().join("Sync/primary.pending");
        model::atomic_write(&marker_path, &marker).unwrap();
        let original_bytes = std::fs::read(original.path()).unwrap();
        let (library, readiness) = Library::open_recoverable(directory.path().into()).unwrap();
        assert_eq!(readiness, Readiness::RecoveryRequired);
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.StartupRecoverySmoke")
            .flags(gio::ApplicationFlags::NON_UNIQUE)
            .build();
        application.register(None::<&gio::Cancellable>).unwrap();
        let app = Rc::new(App {
            application,
            library: RefCell::new(library),
            recovery_required: Cell::new(true),
            main: RefCell::new(None),
            picker: RefCell::new(None),
            secure: RefCell::new(None),
            hold: RefCell::new(None),
            account: RefCell::new(None),
            account_worker: RefCell::new(None),
            backup: RefCell::new(None),
            history: RefCell::new(None),
            inline: RefCell::new(None),
            copy_serial: Cell::new(0),
            css: gtk::CssProvider::new(),
            last_theme: RefCell::new(String::new()),
        });
        app.actions();
        let main = app.main();
        main.window.present();
        let account = AccountWindow::fixture(&app.application, &main.window);
        *app.account.borrow_mut() = Some(account.clone());
        assert!(main.recovery.is_revealed());
        assert!(!main.workspace.is_sensitive());
        assert_eq!(main.count.label(), "Library unavailable");
        assert_eq!(
            main.editor_stack.visible_child_name().as_deref(),
            Some("recovery")
        );
        assert!(main.visible.borrow().is_empty());
        assert!(main.current.borrow().is_none());
        assert!(!app.application.lookup_action("new").unwrap().is_enabled());
        assert!(
            app.application
                .lookup_action("account")
                .unwrap()
                .is_enabled()
        );
        app.application.activate_action("account", None);
        settle(Duration::from_millis(100));
        assert!(account.window.is_visible());
        main.new_entry("Public blocked creation");
        app.capture();
        app.open_picker(None);
        app.open_secure(None);
        app.import();
        app.export();
        app.encrypted_backup();
        app.restore_encrypted_backup();
        assert!(
            !app.application
                .lookup_action("backup")
                .unwrap()
                .is_enabled()
        );
        assert!(app.backup.borrow().is_none());
        assert!(main.current.borrow().is_none());
        assert!(app.picker.borrow().is_none());
        assert!(app.secure.borrow().is_none());
        assert!(std::fs::read(original.path()).unwrap() == original_bytes);
        let wrong_key = RootKey::from_bytes(&[0x12; 32]).unwrap();
        assert!(primary::recover(directory.path(), &wrong_key, &salt, scope.clone()).is_err());
        main.poll();
        assert!(app.recovery_required.get() && main.recovery.is_revealed());
        primary::recover(directory.path(), &key, &salt, scope.clone()).unwrap();
        main.poll();
        assert!(!app.recovery_required.get() && !main.recovery.is_revealed());
        assert!(main.workspace.is_sensitive());
        assert!(app.application.lookup_action("new").unwrap().is_enabled());
        assert_eq!(main.visible.borrow().len(), 1);
        main.new_entry("Public new body");
        assert!(main.save());
        main.buffer.insert_at_cursor(" retained draft");
        let draft = main.draft().unwrap();
        model::atomic_write(&marker_path, &marker).unwrap();
        main.poll();
        assert!(main.dirty.get() && main.autosave.borrow().is_none());
        assert!(main.draft().unwrap() == draft);
        assert!(!main.save());
        primary::recover(directory.path(), &key, &salt, scope).unwrap();
        main.poll();
        assert!(main.dirty.get() && main.draft().unwrap() == draft);
        assert!(main.save());
        let saved = app.library.borrow().get(draft.id).unwrap();
        assert!(saved.content == draft.content && saved.name == draft.name);
        account.window.destroy();
        main.window.destroy();
        drain();
    }

    #[test]
    #[ignore = "requires an available graphical display; run explicitly with one test thread"]
    fn native_lifecycle() {
        adw::init().expect("graphical display");
        let directory = tempfile::tempdir().unwrap();
        let application = adw::Application::builder()
            .application_id("com.khm.snippets.linux.Smoke")
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
            copy_serial: Cell::new(0),
            css: gtk::CssProvider::new(),
            last_theme: RefCell::new(String::new()),
        });
        app.actions();
        let main = app.main();
        main.window.present();
        drain();
        assert!(app.library.borrow().snippets.is_empty());
        assert!(!app.library.borrow().path().exists());
        main.new_entry("Fictional body");
        main.name.set_text("Smoke fixture");
        main.keyword.set_text("smoke");
        main.tags.set_text("work, fixture");
        main.pin.set_active(true);
        assert!(main.save());
        assert_eq!(app.library.borrow().snippets.len(), 1);
        assert_eq!(main.status.label(), "Saved locally");
        main.duplicate();
        assert_eq!(app.library.borrow().snippets.len(), 2);
        let duplicate = main.current.borrow().clone().unwrap();
        assert!(duplicate.keyword.is_empty());
        assert!(!main.buffer.can_undo());
        main.buffer.insert_at_cursor(" draft");
        assert!(main.buffer.can_undo());
        assert!(main.save());
        main.query.set_text("smoke");
        main.refresh();
        assert_eq!(main.visible.borrow().len(), 2);
        app.open_picker(None);
        drain();
        let picker = app.picker.borrow().clone().unwrap();
        assert_eq!(picker.snippets.borrow().len(), 2);
        assert!(
            picker.query.is_focus()
                || gtk::prelude::RootExt::focus(&picker.window)
                    .is_some_and(|w| w.is_ancestor(&picker.query))
        );
        picker.window.destroy();
        app.picker.borrow_mut().take();
        let current = main.current.borrow().clone().unwrap();
        let mut external = Library::open(directory.path().into()).unwrap();
        let mut changed = current.clone();
        changed.content = "External fixture".into();
        external.save(changed, Some(&current)).unwrap();
        main.buffer.insert_at_cursor(" stale");
        assert!(!main.save());
        assert!(main.dirty.get());
        assert!(main.status.label().contains("changed outside"));
        main.dirty.set(false);
        main.poll();
        assert_eq!(
            main.buffer
                .text(&main.buffer.start_iter(), &main.buffer.end_iter(), true),
            "External fixture"
        );
        assert!(!main.buffer.can_undo());
        main.enabled.set_active(false);
        assert!(main.save());
        app.open_picker(None);
        let picker = app.picker.borrow().clone().unwrap();
        assert_eq!(picker.snippets.borrow().len(), 1);
        picker.window.destroy();
        app.picker.borrow_mut().take();
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        std::fs::create_dir(directory.path().join("Vault")).unwrap();
        model::atomic_write(
            &directory.path().join("Vault/vault.json"),
            &serde_json::to_vec(&fixture["document"]).unwrap(),
        )
        .unwrap();
        main.query.set_text("interop");
        main.refresh();
        assert!(main.visible.borrow().len() == 1 && main.visible.borrow()[0].content.is_empty());
        let clipboard = gdk::Display::default().unwrap().clipboard();
        let before = clipboard.content();
        app.open_picker(None);
        let picker = app.picker.borrow().clone().unwrap();
        picker.query.set_text("interop");
        picker.refresh();
        picker.choose();
        assert!(app.secure.borrow().is_some());
        assert!(clipboard.content() == before);
        assert!(main.current.borrow().as_ref().unwrap().id != main.visible.borrow()[0].id);
        assert!(
            !main
                .buffer
                .text(&main.buffer.start_iter(), &main.buffer.end_iter(), true)
                .contains("Fictional secret")
        );
        app.secure.borrow().as_ref().unwrap().window.destroy();
        picker.window.destroy();
        app.picker.borrow_mut().take();
        main.window.destroy();
        drain();
    }
}
